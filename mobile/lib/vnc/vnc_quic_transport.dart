import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_quic/flutter_quic.dart';

import 'package:mobile/vnc_client.dart';
import 'package:mobile/vnc/vnc_datagram.dart';

class VncQuicTransport implements VncTransport {
  VncQuicTransport({
    required this.host,
    required this.port,
    required this.sessionId,
    required this.token,
    this.authToken,
    this.clientId,
    this.clientName,
    this.serverName = 'vibe-inspect',
  });

  final String host;
  final int port;
  final String sessionId;
  final String token;
  final String? authToken;
  final String? clientId;
  final String? clientName;
  final String serverName;

  final StreamController<Uint8List> _controller =
      StreamController<Uint8List>.broadcast();
  final VncDatagramAssembler _datagramAssembler = VncDatagramAssembler();

  QuicEndpoint? _endpoint;
  QuicConnection? _connection;
  QuicSendStream? _sendStream;
  QuicRecvStream? _recvStream;
  bool _running = false;
  final List<Uint8List> _sendQueue = [];
  Uint8List? _pendingPointerMove;
  bool _sendLoopRunning = false;

  static bool _initialized = false;

  @override
  Stream<Uint8List> get stream => _controller.stream;

  @override
  Future<void> connect() async {
    _running = false;
    if (kIsWeb) {
      throw Exception('QUIC is not supported on web.');
    }
    if (port <= 0) {
      throw Exception('QUIC port is unavailable.');
    }
    await _ensureInitialized();
    final endpoint = _endpoint ?? await createClientEndpoint();
    final hostAddress = _formatHost(host);
    final result = await endpointConnect(
      endpoint: endpoint,
      addr: '$hostAddress:$port',
      serverName: serverName,
    );
    _endpoint = result.$1;
    _connection = result.$2;

    final streams = await connectionOpenBi(connection: _connection!);
    _connection = streams.$1;
    _sendStream = streams.$2;
    _recvStream = streams.$3;

    await _sendControl({
      'type': 'vnc',
      'session_id': sessionId,
      'token': token,
      if (authToken != null) 'auth_token': authToken,
      if (clientId != null) 'client_id': clientId,
      if (clientName != null) 'client_name': clientName,
    });
    await _readReady();

    _running = true;
    unawaited(_readStreamLoop());
    unawaited(_readDatagrams());
  }

  @override
  void send(Uint8List data) {
    if (!_running) {
      return;
    }
    if (_isPointerMove(data)) {
      _pendingPointerMove = data;
      _drainSendQueue();
      return;
    }
    if (_pendingPointerMove != null) {
      _sendQueue.add(_pendingPointerMove!);
      _pendingPointerMove = null;
    }
    _enqueueSend(data);
  }

  bool _isPointerMove(Uint8List data) {
    if (data.length < 2 || data[0] != 5) {
      return false;
    }
    final mask = data[1];
    final hasButtons = (mask & 0x07) != 0;
    final hasScroll = (mask & 0xF0) != 0;
    return !hasButtons && !hasScroll;
  }

  void _enqueueSend(Uint8List data) {
    _sendQueue.add(data);
    _drainSendQueue();
  }

  void _drainSendQueue() {
    if (_sendLoopRunning) {
      return;
    }
    _sendLoopRunning = true;
    unawaited(_runSendLoop());
  }

  Future<void> _runSendLoop() async {
    while (_running) {
      Uint8List? next;
      if (_sendQueue.isNotEmpty) {
        next = _sendQueue.removeAt(0);
      } else if (_pendingPointerMove != null) {
        next = _pendingPointerMove;
        _pendingPointerMove = null;
      } else {
        break;
      }
      if (next == null) {
        continue;
      }
      final stream = _sendStream;
      if (stream == null) {
        break;
      }
      try {
        _sendStream = await sendStreamWriteAll(stream: stream, data: next);
      } catch (_) {
        break;
      }
    }
    _sendLoopRunning = false;
  }

  @override
  Future<void> close() async {
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
    _sendQueue.clear();
    _pendingPointerMove = null;
    if (!_controller.isClosed) {
      await _controller.close();
    }
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
    final header = ByteData(4)..setUint32(0, data.length, Endian.big);
    final buffer = Uint8List(4 + data.length);
    buffer.setAll(0, header.buffer.asUint8List());
    buffer.setAll(4, data);
    _sendStream = await sendStreamWriteAll(stream: stream, data: buffer);
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
    final payload = await _readExact(length);
    if (payload.isEmpty) {
      return;
    }
    final decoded = jsonDecode(utf8.decode(payload));
    if (decoded is Map<String, dynamic>) {
      final status = decoded['status']?.toString();
      if (status == 'error') {
        final message =
            decoded['message']?.toString() ?? 'VNC QUIC handshake failed.';
        throw Exception(message);
      }
    }
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

  Future<void> _readStreamLoop() async {
    while (_running) {
      final connection = _connection;
      if (connection == null) {
        break;
      }
      final recvStream = _recvStream;
      if (recvStream == null) {
        break;
      }
      try {
        final result = await recvStreamRead(
          stream: recvStream,
          maxLength: BigInt.from(16 * 1024),
        );
        _recvStream = result.$1;
        final data = result.$2;
        if (data == null || data.isEmpty) {
          await Future.delayed(const Duration(milliseconds: 4));
          continue;
        }
        if (_controller.isClosed || !_running) {
          return;
        }
        _controller.add(data);
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
    }
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
        final payload = _datagramAssembler.addDatagram(data);
        if (payload != null && !_controller.isClosed && _running) {
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
