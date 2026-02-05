import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_quic/flutter_quic.dart';
import 'package:mobile/remote/media_protocol.dart';

class RemoteQuicHandshake {
  const RemoteQuicHandshake({
    required this.handshakeMs,
    required this.dataStreamOpened,
  });

  final int handshakeMs;
  final bool dataStreamOpened;
}

class RemoteQuicStats {
  const RemoteQuicStats({
    required this.bytesReceived,
    required this.lastDataAt,
  });

  final int bytesReceived;
  final DateTime? lastDataAt;

  static const empty = RemoteQuicStats(bytesReceived: 0, lastDataAt: null);
}

class RemoteVideoFrame {
  const RemoteVideoFrame({
    required this.header,
    required this.payload,
  });

  final VideoFrameHeader header;
  final Uint8List payload;
}

class RemoteQuicClient {
  RemoteQuicClient({
    required this.host,
    required this.port,
    this.serverName = 'vibe-inspect',
  });

  final String host;
  final int port;
  final String serverName;

  QuicEndpoint? _endpoint;
  QuicConnection? _connection;
  QuicSendStream? _controlSend;
  QuicRecvStream? _controlRecv;
  QuicSendStream? _dataSend;
  QuicRecvStream? _dataRecv;
  bool _running = false;
  bool _dataRunning = false;

  final StreamController<RemoteQuicStats> _statsController =
      StreamController<RemoteQuicStats>.broadcast();
  final StreamController<RemoteVideoFrame> _frameController =
      StreamController<RemoteVideoFrame>.broadcast();
  RemoteQuicStats _stats = RemoteQuicStats.empty;
  Uint8List _dataBuffer = Uint8List(0);

  static bool _initialized = false;

  Stream<RemoteQuicStats> get stats => _statsController.stream;
  Stream<RemoteVideoFrame> get frames => _frameController.stream;
  RemoteQuicStats get currentStats => _stats;

  Future<RemoteQuicHandshake> connect({
    required String sessionId,
    required String token,
    String? authToken,
    String? clientId,
    String? clientName,
    bool openDataStream = true,
  }) async {
    await disconnect();
    if (kIsWeb) {
      return const RemoteQuicHandshake(handshakeMs: 0, dataStreamOpened: false);
    }
    await _ensureInitialized();
    final endpoint = _endpoint ?? await createClientEndpoint();
    final hostAddress = _formatHost(host);
    final startedAt = DateTime.now();
    try {
      final result = await endpointConnect(
        endpoint: endpoint,
        addr: '$hostAddress:$port',
        serverName: serverName,
      );
      _endpoint = result.$1;
      _connection = result.$2;
    } catch (_) {
      _endpoint = null;
      rethrow;
    }

    final control = await connectionOpenBi(connection: _connection!);
    _connection = control.$1;
    _controlSend = control.$2;
    _controlRecv = control.$3;

    await _sendControl({
      'type': 'remote',
      'session_id': sessionId,
      'token': token,
      'auth_token': authToken,
      'client_id': clientId,
      'client_name': clientName,
    });
    await _readReady();

    var dataOpened = false;
    if (openDataStream) {
      final data = await connectionOpenBi(connection: _connection!);
      _connection = data.$1;
      _dataSend = data.$2;
      _dataRecv = data.$3;
      dataOpened = true;
    }

    _running = true;
    if (dataOpened) {
      _dataRunning = true;
      unawaited(_readData());
    }

    final handshakeMs = DateTime.now().difference(startedAt).inMilliseconds;
    return RemoteQuicHandshake(
      handshakeMs: handshakeMs,
      dataStreamOpened: dataOpened,
    );
  }

  Future<void> disconnect() async {
    _running = false;
    _dataRunning = false;
    final sendStream = _controlSend;
    if (sendStream != null) {
      try {
        await sendStreamFinish(stream: sendStream);
      } catch (_) {}
    }
    final dataSend = _dataSend;
    if (dataSend != null) {
      try {
        await sendStreamFinish(stream: dataSend);
      } catch (_) {}
    }
    _controlSend = null;
    _controlRecv = null;
    _dataSend = null;
    _dataRecv = null;
    _connection = null;
    _endpoint = null;
    _stats = RemoteQuicStats.empty;
    _dataBuffer = Uint8List(0);
  }

  Future<void> _sendControl(Map<String, dynamic> payload) async {
    final stream = _controlSend;
    if (stream == null) {
      return;
    }
    final data = utf8.encode(jsonEncode(payload));
    final length = data.length;
    final header = ByteData(4)..setUint32(0, length, Endian.big);
    final buffer = Uint8List(4 + length);
    buffer.setAll(0, header.buffer.asUint8List());
    buffer.setAll(4, data);
    final updated = await sendStreamWriteAll(stream: stream, data: buffer);
    _controlSend = updated;
  }

  Future<void> sendDataControl(Map<String, dynamic> payload) async {
    final stream = _dataSend;
    if (stream == null) {
      return;
    }
    final data = utf8.encode(jsonEncode(payload));
    final length = data.length;
    final header = ByteData(4)..setUint32(0, length, Endian.big);
    final buffer = Uint8List(4 + length);
    buffer.setAll(0, header.buffer.asUint8List());
    buffer.setAll(4, data);
    final updated = await sendStreamWriteAll(stream: stream, data: buffer);
    _dataSend = updated;
  }

  Future<String> _readReady() async {
    final lengthBytes = await _readExact(4);
    if (lengthBytes.length != 4) {
      return '';
    }
    final length = ByteData.sublistView(lengthBytes).getUint32(0, Endian.big);
    if (length == 0) {
      return '';
    }
    final payload = await _readExact(length);
    if (payload.isEmpty) {
      return '';
    }
    try {
      final ready = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
      return ready['data_stream']?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<Uint8List> _readExact(int size) async {
    var remaining = size;
    final chunks = <int>[];
    var stream = _controlRecv;
    while (remaining > 0 && stream != null) {
      final result = await recvStreamRead(
        stream: stream,
        maxLength: BigInt.from(remaining),
      );
      stream = result.$1;
      final data = result.$2;
      if (data == null || data.isEmpty) {
        break;
      }
      chunks.addAll(data);
      remaining = size - chunks.length;
    }
    _controlRecv = stream;
    return Uint8List.fromList(chunks);
  }

  Future<void> _readData() async {
    while (_running && _dataRunning) {
      var stream = _dataRecv;
      if (stream == null) {
        break;
      }
      try {
        final result = await recvStreamRead(
          stream: stream,
          maxLength: BigInt.from(64 * 1024),
        );
        stream = result.$1;
        final data = result.$2;
        _dataRecv = stream;
        if (data == null || data.isEmpty) {
          await Future.delayed(const Duration(milliseconds: 8));
          continue;
        }
        _stats = RemoteQuicStats(
          bytesReceived: _stats.bytesReceived + data.length,
          lastDataAt: DateTime.now(),
        );
        _statsController.add(_stats);
        _ingestFrames(data);
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
    }
  }

  void _ingestFrames(Uint8List data) {
    if (data.isEmpty) {
      return;
    }
    if (_dataBuffer.isEmpty) {
      _dataBuffer = data;
    } else {
      final combined = Uint8List(_dataBuffer.length + data.length);
      combined.setAll(0, _dataBuffer);
      combined.setAll(_dataBuffer.length, data);
      _dataBuffer = combined;
    }
    while (_dataBuffer.length >= VideoFrameHeader.size) {
      final header = VideoFrameHeader.tryParse(_dataBuffer);
      if (header == null) {
        _dataBuffer = _dataBuffer.sublist(1);
        continue;
      }
      final total = VideoFrameHeader.size + header.payloadLen;
      if (_dataBuffer.length < total) {
        break;
      }
      final payload = Uint8List.sublistView(
        _dataBuffer,
        VideoFrameHeader.size,
        total,
      );
      _frameController.add(
        RemoteVideoFrame(
          header: header,
          payload: Uint8List.fromList(payload),
        ),
      );
      _dataBuffer = _dataBuffer.sublist(total);
    }
  }

  static Future<void> _ensureInitialized() async {
    if (_initialized) {
      return;
    }
    await RustLib.init();
    _initialized = true;
  }

  String _formatHost(String input) {
    if (input.contains(':') && !input.startsWith('[')) {
      return '[$input]';
    }
    return input;
  }
}
