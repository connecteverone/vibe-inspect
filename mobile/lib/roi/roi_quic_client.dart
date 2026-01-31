import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_quic/flutter_quic.dart';

import 'roi_client.dart';
import 'roi_models.dart';

class RoiQuicClient implements RoiClient {
  RoiQuicClient({required this.host, this.serverName = 'vibe-inspect'});

  final String host;
  final String serverName;
  final StreamController<RoiTilePayload> _controller =
      StreamController<RoiTilePayload>.broadcast();
  final RoiTileAssembler _assembler = RoiTileAssembler();

  QuicEndpoint? _endpoint;
  QuicConnection? _connection;
  QuicSendStream? _sendStream;
  QuicRecvStream? _recvStream;
  bool _running = false;

  static bool _initialized = false;

  @override
  Stream<RoiTilePayload> get tiles => _controller.stream;

  @override
  Future<void> connect(RoiSessionInfo sessionInfo) async {
    await disconnect();
    if (kIsWeb) {
      return;
    }
    await _ensureInitialized();
    final endpoint = _endpoint ?? await createClientEndpoint();
    final hostAddress = _formatHost(host);
    try {
      final result = await endpointConnect(
        endpoint: endpoint,
        addr: '$hostAddress:${sessionInfo.quicPort}',
        serverName: serverName,
      );
      _endpoint = result.$1;
      _connection = result.$2;
    } catch (_) {
      _endpoint = null;
      rethrow;
    }

    final streams = await connectionOpenBi(connection: _connection!);
    _connection = streams.$1;
    _sendStream = streams.$2;
    _recvStream = streams.$3;

    await _sendControl({
      'session_id': sessionInfo.sessionId,
      'token': sessionInfo.token,
    });
    await _readReady();

    _running = true;
    unawaited(_readDatagrams());
  }

  @override
  Future<void> disconnect() async {
    _running = false;
    final sendStream = _sendStream;
    if (sendStream != null) {
      try {
        await sendStreamFinish(stream: sendStream);
      } catch (_) {}
    }
    _sendStream = null;
    _recvStream = null;
    _connection = null;
    _endpoint = null;
  }

  @override
  Future<void> requestRoi({
    required double centerX,
    required double centerY,
    required double zoom,
    required double viewportWidth,
    required double viewportHeight,
    required double prefetchRadius,
  }) async {
    await _sendControl({
      'center_x': centerX,
      'center_y': centerY,
      'zoom': zoom,
      'viewport_width': viewportWidth,
      'viewport_height': viewportHeight,
      'prefetch_radius': prefetchRadius,
    });
  }

  static Future<void> _ensureInitialized() async {
    if (_initialized) {
      return;
    }
    await RustLib.init();
    _initialized = true;
  }

  Future<void> _sendControl(Map<String, dynamic> payload) async {
    final stream = _sendStream;
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
    _sendStream = updated;
  }

  Future<void> _readReady() async {
    final lengthBytes = await _readExact(4);
    if (lengthBytes.length != 4) {
      return;
    }
    final length = ByteData.sublistView(lengthBytes).getUint32(0, Endian.big);
    if (length == 0) {
      return;
    }
    await _readExact(length);
  }

  Future<Uint8List> _readExact(int size) async {
    var remaining = size;
    final chunks = <int>[];
    var stream = _recvStream;
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
    _recvStream = stream;
    return Uint8List.fromList(chunks);
  }

  Future<void> _readDatagrams() async {
    while (_running) {
      final connection = _connection;
      if (connection == null) {
        break;
      }
      try {
        final result = await connectionReadDatagram(connection: connection);
        _connection = result.$1;
        final data = result.$2;
        if (data == null || data.isEmpty) {
          await Future.delayed(const Duration(milliseconds: 4));
          continue;
        }
        final payload = _assembler.addDatagram(data);
        if (payload != null) {
          _controller.add(payload);
        }
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
    }
  }

  String _formatHost(String input) {
    if (input.contains(':') && !input.startsWith('[')) {
      return '[$input]';
    }
    return input;
  }
}
