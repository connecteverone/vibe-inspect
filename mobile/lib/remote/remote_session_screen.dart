part of '../main.dart';

const double _rustdeskZoomMin = 0.7;
const double _rustdeskZoomMax = 3.0;
const double _rustdeskZoomDefault = 1.0;

class RemoteSessionScreen extends StatefulWidget {
  const RemoteSessionScreen({
    super.key,
    required this.event,
    required this.session,
    required this.storage,
    required this.agentBaseUrl,
    required this.authToken,
    required this.clientId,
    required this.clientName,
  });

  final TimelineEvent event;
  final ToolSession session;
  final StorageRepository storage;
  final String? agentBaseUrl;
  final String? authToken;
  final String? clientId;
  final String? clientName;

  @override
  State<RemoteSessionScreen> createState() => _RemoteSessionScreenState();
}

class RemoteSessionController extends ChangeNotifier {
  RemoteSessionController({
    required this.agentBaseUrl,
    required this.authToken,
    required this.clientId,
    required this.clientName,
  });

  final String? agentBaseUrl;
  final String? authToken;
  final String? clientId;
  final String? clientName;

  AgentCommandClient? _agentClient;
  bool _disposed = false;

  bool _isStarting = false;
  bool _isStopping = false;
  bool _isQuicConnecting = false;
  String? _error;
  String? _quicError;
  RemoteSessionInfo? _sessionInfo;
  RemoteQuicHandshake? _quicHandshake;
  RemoteQuicStats _quicStats = RemoteQuicStats.empty;
  int? _quicPort;
  String? _rustdeskSessionId;
  Timer? _firstFrameTimer;
  bool _hasFrame = false;

  bool get isStarting => _isStarting;
  bool get isStopping => _isStopping;
  bool get isQuicConnecting => _isQuicConnecting;
  String? get error => _error;
  String? get quicError => _quicError;
  RemoteSessionInfo? get sessionInfo => _sessionInfo;
  RemoteQuicHandshake? get quicHandshake => _quicHandshake;
  RemoteQuicStats get quicStats => _quicStats;
  int? get quicPort => _quicPort;
  String? get rustdeskSessionId => _rustdeskSessionId;

  void _update(VoidCallback fn) {
    if (_disposed) return;
    fn();
    if (_disposed) return;
    notifyListeners();
  }

  Future<void> bootstrap() async {
    final baseUrl = agentBaseUrl;
    if (baseUrl == null || baseUrl.isEmpty) {
      _update(() {
        _error = 'Agent URL missing. Re-pair to enable remote control.';
      });
      return;
    }
    _agentClient = AgentCommandClient(
      baseUrl: baseUrl,
      authToken: authToken,
      clientId: clientId,
      clientName: clientName,
    );
    await startRemote();
  }

  Future<void> startRemote() async {
    final client = _agentClient;
    if (client == null || _disposed) {
      return;
    }
    _update(() {
      _isStarting = true;
      _error = null;
    });
    try {
      final info = await client.sendRemoteCommand(action: 'start');
      if (_disposed) {
        return;
      }
      _update(() {
        _sessionInfo = info;
      });
      await connectQuic(info);
    } catch (error) {
      if (_disposed) {
        return;
      }
      _update(() {
        _error = error.toString();
      });
    } finally {
      if (!_disposed) {
        _update(() {
          _isStarting = false;
        });
      }
    }
  }

  Future<void> stopRemote() async {
    final client = _agentClient;
    if (client == null || _disposed) {
      return;
    }
    _update(() {
      _isStopping = true;
      _error = null;
    });
    try {
      await disconnectQuic(notify: false);
      await client.sendRemoteCommand(
        action: 'stop',
        sessionId: _sessionInfo?.sessionId,
      );
      if (_disposed) {
        return;
      }
      _update(() {
        _sessionInfo = null;
      });
    } catch (error) {
      if (_disposed) {
        return;
      }
      _update(() {
        _error = error.toString();
      });
    } finally {
      if (!_disposed) {
        _update(() {
          _isStopping = false;
        });
      }
    }
  }

  Future<void> connectQuic(RemoteSessionInfo info) async {
    final client = _agentClient;
    if (client == null || _disposed) {
      return;
    }
    await disconnectQuic(notify: false);
    if (_disposed) {
      return;
    }
    final token = info.token;
    if (token == null || token.isEmpty) {
      _update(() {
        _quicError = 'Remote token missing. Reconnect to refresh session.';
      });
      return;
    }
    if (info.hwcodecEnabled == false) {
      _update(() {
        _quicError = 'Hardware encoding is disabled on the host.';
      });
      return;
    }
    final caps = info.capabilities;
    if (caps != null && !(caps.h264 || caps.h265)) {
      _update(() {
        _quicError = 'Host does not advertise H264/H265 support.';
      });
      return;
    }
    _update(() {
      _isQuicConnecting = true;
      _quicError = null;
      _quicHandshake = null;
      _quicStats = RemoteQuicStats.empty;
      _hasFrame = false;
    });
    String? rustdeskSessionId;
    try {
      var port = info.quicPort;
      if (port == null || port <= 0) {
        final identity = await client.fetchIdentity();
        port = _parsePort(identity['roi_quic_port']);
      }
      if (port == null || port <= 0) {
        throw StateError('ROI QUIC port missing from identity response.');
      }
      final host = _extractHost(agentBaseUrl ?? '');
      final startedAt = DateTime.now();
      final backend = info.backend.toLowerCase();
      if (backend != 'rustdesk') {
        throw StateError('Unsupported remote backend: ${info.backend}');
      }
      final rustdesk = RustdeskBridge.instance;
      rustdesk.ensureInitialized();
      final connected = rustdesk.connectQuic(
        host: host,
        port: port,
        remoteSessionId: info.sessionId,
        token: token,
        authToken: authToken,
        clientId: clientId,
        clientName: clientName,
      );
      if (!connected) {
        throw StateError('RustDesk QUIC connect failed.');
      }
      final peerId = _extractRustdeskId(info.connectUri);
      if (peerId == null || peerId.isEmpty) {
        throw StateError('RustDesk peer id missing from connect URI.');
      }
      rustdeskSessionId = const Uuid().v4();
      final added = rustdesk.sessionAdd(
        sessionId: rustdeskSessionId,
        peerId: peerId,
        password: token,
      );
      if (!added) {
        throw StateError('RustDesk session add failed.');
      }
      final started = rustdesk.sessionStart(rustdeskSessionId);
      if (!started) {
        rustdesk.sessionClose(rustdeskSessionId);
        throw StateError('RustDesk session start failed.');
      }
      final displayIndex = info.displayIndex ?? 0;
      rustdesk.sessionBootstrap(rustdeskSessionId, token, displayIndex);
      final handshake = RemoteQuicHandshake(
        handshakeMs: DateTime.now().difference(startedAt).inMilliseconds,
        dataStreamOpened: true,
      );
      if (_disposed) {
        rustdesk.sessionClose(rustdeskSessionId);
        rustdesk.disconnectQuic();
        return;
      }
      _update(() {
        _rustdeskSessionId = rustdeskSessionId;
        _quicHandshake = handshake;
        _quicPort = port;
      });
      _armFirstFrameTimer();
    } catch (error) {
      if (rustdeskSessionId != null) {
        RustdeskBridge.instance.sessionClose(rustdeskSessionId);
      }
      RustdeskBridge.instance.disconnectQuic();
      if (_disposed) {
        return;
      }
      _update(() {
        _quicError = error.toString();
      });
    } finally {
      if (!_disposed) {
        _update(() {
          _isQuicConnecting = false;
        });
      }
    }
  }

  Future<void> stopRemoteSilently() async {
    final client = _agentClient;
    final sessionId = _sessionInfo?.sessionId;
    await disconnectQuic(notify: false);
    if (client == null || sessionId == null || sessionId.isEmpty) {
      return;
    }
    try {
      await client.sendRemoteCommand(action: 'stop', sessionId: sessionId);
    } catch (_) {}
  }

  Future<void> disconnectQuic({bool notify = true}) async {
    final rustdesk = RustdeskBridge.instance;
    final rustdeskSessionId = _rustdeskSessionId;
    _rustdeskSessionId = null;
    _quicHandshake = null;
    _quicPort = null;
    _quicStats = RemoteQuicStats.empty;
    _quicError = null;
    _isQuicConnecting = false;
    _hasFrame = false;
    _firstFrameTimer?.cancel();
    _firstFrameTimer = null;
    if (notify && !_disposed) {
      notifyListeners();
    }
    if (rustdeskSessionId != null) {
      rustdesk.sessionClose(rustdeskSessionId);
    }
    rustdesk.disconnectQuic();
  }

  String? _extractRustdeskId(String? connectUri) {
    if (connectUri == null || connectUri.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(connectUri);
    if (uri == null) {
      return null;
    }
    if (uri.host.isNotEmpty) {
      return uri.host;
    }
    if (uri.path.isNotEmpty) {
      return uri.path;
    }
    return null;
  }

  String _extractHost(String baseUrl) {
    if (baseUrl.isEmpty) {
      return baseUrl;
    }
    var uri = Uri.tryParse(baseUrl);
    if (uri == null || uri.host.isEmpty) {
      uri = Uri.tryParse('http://$baseUrl');
    }
    return uri?.host ?? baseUrl;
  }

  int? _parsePort(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is String && value.trim().isNotEmpty) {
      return int.tryParse(value.trim());
    }
    return null;
  }

  void _armFirstFrameTimer() {
    _firstFrameTimer?.cancel();
    _firstFrameTimer = Timer(const Duration(seconds: 10), () {
      if (_disposed || _hasFrame) {
        return;
      }
      _update(() {
        _quicError = 'No frames received. Try reconnecting.';
      });
    });
  }

  void markFrameReceived() {
    if (_hasFrame) return;
    _hasFrame = true;
    _firstFrameTimer?.cancel();
    _firstFrameTimer = null;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stopRemoteSilently());
    _firstFrameTimer?.cancel();
    _firstFrameTimer = null;
    super.dispose();
  }
}

class _RemoteSessionScreenState extends State<RemoteSessionScreen> {
  late final RemoteSessionController _controller;
  bool _isFullscreen = false;
  bool _trackpadEnabled = false;
  double _zoomValue = _rustdeskZoomDefault;

  final Map<int, Offset> _trackpadPointers = <int, Offset>{};
  Offset? _trackpadPrimaryDownPosition;
  Offset? _trackpadLastPrimaryPosition;
  Offset? _trackpadLastMultiFingerPosition;
  DateTime? _trackpadPrimaryDownTime;
  double _trackpadScrollAccumulator = 0;

  static const Duration _trackpadTapTimeout = Duration(milliseconds: 220);
  static const double _trackpadTapSlop = 10;
  static const double _trackpadScrollStep = 12;
  static const double _trackpadMoveScale = 1.3;

  @override
  void initState() {
    super.initState();
    _controller = RemoteSessionController(
      agentBaseUrl: widget.agentBaseUrl,
      authToken: widget.authToken,
      clientId: widget.clientId,
      clientName: widget.clientName,
    );
    _controller.addListener(_handleControllerUpdate);
    _bootstrap();
  }

  Future<void> _bootstrap() => _controller.bootstrap();

  Future<void> _startRemote() => _controller.startRemote();

  Future<void> _stopRemote() => _controller.stopRemote();

  Future<void> _connectQuic(RemoteSessionInfo info) => _controller.connectQuic(info);

  void _handleControllerUpdate() {
    if (!mounted) return;
    setState(() {});
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    final kb = bytes / 1024;
    if (kb < 1024) {
      return '${kb.toStringAsFixed(1)} KB';
    }
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(1)} MB';
  }

  String _formatLastData(DateTime? at) {
    if (at == null) {
      return 'No data yet';
    }
    final delta = DateTime.now().difference(at);
    if (delta.inSeconds < 1) {
      return 'Just now';
    }
    if (delta.inSeconds < 60) {
      return '${delta.inSeconds}s ago';
    }
    return '${delta.inMinutes}m ago';
  }

  Future<void> _setFullscreen(bool value) async {
    if (!mounted || _isFullscreen == value) {
      return;
    }
    setState(() {
      _isFullscreen = value;
    });
    if (value) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  void _toggleFullscreen() {
    _setFullscreen(!_isFullscreen);
  }

  void _toggleTrackpad() {
    setState(() {
      _trackpadEnabled = !_trackpadEnabled;
      _resetTrackpadState();
    });
  }

  void _updateZoomValue(double value) {
    final clamped = value.clamp(_rustdeskZoomMin, _rustdeskZoomMax);
    if (clamped == _zoomValue) {
      return;
    }
    setState(() {
      _zoomValue = clamped;
    });
  }

  void _commitZoomValue(double value) {
    _updateZoomValue(value);
  }

  void _resetZoom() {
    _updateZoomValue(_rustdeskZoomDefault);
  }

  void _resetTrackpadState() {
    _trackpadPointers.clear();
    _trackpadPrimaryDownPosition = null;
    _trackpadLastPrimaryPosition = null;
    _trackpadLastMultiFingerPosition = null;
    _trackpadPrimaryDownTime = null;
    _trackpadScrollAccumulator = 0;
  }

  Offset _trackpadAveragePointerPosition() {
    if (_trackpadPointers.isEmpty) {
      return Offset.zero;
    }
    var sum = Offset.zero;
    for (final position in _trackpadPointers.values) {
      sum += position;
    }
    return sum / _trackpadPointers.length.toDouble();
  }

  bool _isTrackpadTapCandidate(DateTime now) {
    if (_trackpadPrimaryDownTime == null || _trackpadPrimaryDownPosition == null) {
      return false;
    }
    if (now.difference(_trackpadPrimaryDownTime!) > _trackpadTapTimeout) {
      return false;
    }
    final last = _trackpadLastPrimaryPosition ?? _trackpadPrimaryDownPosition!;
    return (last - _trackpadPrimaryDownPosition!).distance <= _trackpadTapSlop;
  }

  void _sendTrackpadMove(Offset delta) {
    final sessionId = _controller.rustdeskSessionId;
    if (sessionId == null) {
      return;
    }
    final scaled = delta * _trackpadMoveScale;
    final dx = scaled.dx.round();
    final dy = scaled.dy.round();
    if (dx == 0 && dy == 0) {
      return;
    }
    RustdeskBridge.instance.sendMouse(sessionId, {
      'type': 'move_relative',
      'x': '$dx',
      'y': '$dy',
    });
  }

  void _sendTrackpadScroll(Offset delta) {
    final sessionId = _controller.rustdeskSessionId;
    if (sessionId == null) {
      return;
    }
    if (delta.dy != 0) {
      _trackpadScrollAccumulator += -delta.dy;
      while (_trackpadScrollAccumulator.abs() >= _trackpadScrollStep) {
        final direction = _trackpadScrollAccumulator.isNegative ? -1 : 1;
        RustdeskBridge.instance.sendMouse(sessionId, {
          'type': 'wheel',
          'y': '${direction * _trackpadScrollStep}',
        });
        _trackpadScrollAccumulator -= direction * _trackpadScrollStep;
      }
    }
  }

  void _sendTrackpadClick({int count = 1}) {
    final sessionId = _controller.rustdeskSessionId;
    if (sessionId == null) {
      return;
    }
    for (var i = 0; i < count; i += 1) {
      RustdeskBridge.instance.sendMouse(sessionId, {
        'type': 'down',
        'buttons': 'left',
      });
      RustdeskBridge.instance.sendMouse(sessionId, {
        'type': 'up',
        'buttons': 'left',
      });
    }
  }

  void _handleTrackpadPointerDown(PointerDownEvent event) {
    if (!_trackpadEnabled) {
      return;
    }
    _trackpadPointers[event.pointer] = event.position;
    if (_trackpadPointers.length == 1) {
      _trackpadPrimaryDownPosition = event.position;
      _trackpadPrimaryDownTime = DateTime.now();
      _trackpadLastPrimaryPosition = event.position;
      _trackpadLastMultiFingerPosition = null;
    } else if (_trackpadPointers.length >= 2) {
      _trackpadLastMultiFingerPosition = _trackpadAveragePointerPosition();
    }
  }

  void _handleTrackpadPointerMove(PointerMoveEvent event) {
    if (!_trackpadPointers.containsKey(event.pointer)) {
      return;
    }
    _trackpadPointers[event.pointer] = event.position;
    if (_trackpadPointers.length >= 2) {
      final average = _trackpadAveragePointerPosition();
      final last = _trackpadLastMultiFingerPosition;
      if (last != null) {
        final delta = average - last;
        if (delta.distance != 0) {
          _sendTrackpadScroll(delta);
        }
      }
      _trackpadLastMultiFingerPosition = average;
      return;
    }
    if (_trackpadPointers.length == 1) {
      final last = _trackpadLastPrimaryPosition ?? event.position;
      final delta = event.position - last;
      if (delta.distance != 0) {
        _sendTrackpadMove(delta);
      }
      _trackpadLastPrimaryPosition = event.position;
    }
  }

  void _handleTrackpadPointerUp(PointerUpEvent event) {
    if (!_trackpadPointers.containsKey(event.pointer)) {
      return;
    }
    final wasMultiFinger = _trackpadPointers.length >= 2;
    _trackpadPointers.remove(event.pointer);
    if (_trackpadPointers.isEmpty) {
      final now = DateTime.now();
      if (!wasMultiFinger && _isTrackpadTapCandidate(now)) {
        _sendTrackpadClick();
      }
      _trackpadPrimaryDownPosition = null;
      _trackpadPrimaryDownTime = null;
      _trackpadLastPrimaryPosition = null;
      _trackpadLastMultiFingerPosition = null;
    } else if (_trackpadPointers.length == 1) {
      final remaining = _trackpadPointers.values.first;
      _trackpadPrimaryDownPosition = remaining;
      _trackpadPrimaryDownTime = DateTime.now();
      _trackpadLastPrimaryPosition = remaining;
      _trackpadLastMultiFingerPosition = null;
    } else {
      _trackpadLastMultiFingerPosition = _trackpadAveragePointerPosition();
    }
  }

  void _handleTrackpadPointerCancel(PointerCancelEvent event) {
    _trackpadPointers.remove(event.pointer);
    _trackpadPrimaryDownPosition = null;
    _trackpadPrimaryDownTime = null;
    _trackpadLastPrimaryPosition = null;
    _trackpadLastMultiFingerPosition = null;
  }

  @override
  void dispose() {
    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _controller.removeListener(_handleControllerUpdate);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessionInfo = _controller.sessionInfo;
    if (_isFullscreen) {
      return _buildFullscreenView(sessionInfo);
    }
    return _TimelineDetailScaffold(
      title: 'Remote Control',
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'RustDesk backend',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'QUIC-only RustDesk stream. Use touch to move and tap to click once frames arrive.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF64748B),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_controller.error != null)
                    _InlineStatus(message: _controller.error!, isError: true)
                  else if (_controller.isStarting)
                    const _InlineStatus(message: 'Starting remote session...')
                  else if (sessionInfo == null)
                    const _InlineStatus(message: 'Remote session not started.')
                  else
                    _RemoteSessionCard(info: sessionInfo),
                  if (sessionInfo != null) ...[
                    const SizedBox(height: 16),
                    _RemoteQuicCard(
                      handshake: _controller.quicHandshake,
                      port: _controller.quicPort,
                      stats: _controller.quicStats,
                      isConnecting: _controller.isQuicConnecting,
                      error: _controller.quicError,
                      formatBytes: _formatBytes,
                      formatLastData: _formatLastData,
                    ),
                  ],
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed: _controller.isStarting || sessionInfo != null
                            ? null
                            : _startRemote,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Start'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _controller.isStopping ? null : _stopRemote,
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _controller.isQuicConnecting || sessionInfo == null
                            ? null
                            : () => _connectQuic(sessionInfo),
                        icon: const Icon(Icons.bolt),
                        label: const Text('Reconnect QUIC'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            sliver: SliverFillRemaining(
              hasScrollBody: true,
              child: _buildRemoteView(sessionInfo),
            ),
          ),
        ],
      ),
    );
  }
}

extension on _RemoteSessionScreenState {
  Widget _buildFullscreenView(RemoteSessionInfo? sessionInfo) {
    final rustdeskSessionId = _controller.rustdeskSessionId;
    final token = sessionInfo?.token ?? '';
    return WillPopScope(
      onWillPop: () async {
        if (_isFullscreen) {
          await _setFullscreen(false);
          return false;
        }
        return true;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            if (rustdeskSessionId == null)
              const Center(
                child: _InlineStatus(message: 'RustDesk stream not connected.'),
              )
            else
              Positioned.fill(
                child: _buildRustdeskCanvas(
                  sessionId: rustdeskSessionId,
                  token: token,
                  glassStyle: true,
                  cornerRadius: 0,
                ),
              ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: _RustdeskControlBar(
                    isFullscreen: _isFullscreen,
                    trackpadEnabled: _trackpadEnabled,
                    onToggleFullscreen: _toggleFullscreen,
                    onToggleTrackpad: _toggleTrackpad,
                    onResetZoom: _resetZoom,
                    glassStyle: true,
                  ),
                ),
              ),
            ),
            if (_trackpadEnabled && rustdeskSessionId != null)
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: _RustdeskTrackpadSurface(
                      enabled: true,
                      glassStyle: true,
                      height: 140,
                      showLabel: false,
                      onPointerDown: _handleTrackpadPointerDown,
                      onPointerMove: _handleTrackpadPointerMove,
                      onPointerUp: _handleTrackpadPointerUp,
                      onPointerCancel: _handleTrackpadPointerCancel,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRemoteView(RemoteSessionInfo? sessionInfo) {
    final rustdeskSessionId = _controller.rustdeskSessionId;
    if (rustdeskSessionId == null) {
      return const _InlineStatus(message: 'RustDesk stream not connected.');
    }
    final token = sessionInfo?.token ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RustdeskControlBar(
          isFullscreen: _isFullscreen,
          trackpadEnabled: _trackpadEnabled,
          onToggleFullscreen: _toggleFullscreen,
          onToggleTrackpad: _toggleTrackpad,
          onResetZoom: _resetZoom,
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _buildRustdeskCanvas(
            sessionId: rustdeskSessionId,
            token: token,
            glassStyle: false,
            cornerRadius: 16,
          ),
        ),
        if (_trackpadEnabled) ...[
          const SizedBox(height: 12),
          _RustdeskTrackpadSurface(
            enabled: true,
            height: 140,
            onPointerDown: _handleTrackpadPointerDown,
            onPointerMove: _handleTrackpadPointerMove,
            onPointerUp: _handleTrackpadPointerUp,
            onPointerCancel: _handleTrackpadPointerCancel,
          ),
        ],
      ],
    );
  }

  Widget _buildRustdeskCanvas({
    required String sessionId,
    required String token,
    required bool glassStyle,
    required double cornerRadius,
  }) {
    return Stack(
      children: [
        Positioned.fill(
          child: RustdeskVideoView(
            sessionId: sessionId,
            token: token,
            onFirstFrame: _controller.markFrameReceived,
            zoom: _zoomValue,
            directInput: !_trackpadEnabled,
            cornerRadius: cornerRadius,
          ),
        ),
        Positioned(
          right: glassStyle ? 12 : 8,
          top: 12,
          bottom: 12,
          child: _RustdeskZoomBar(
            value: _zoomValue,
            min: _rustdeskZoomMin,
            max: _rustdeskZoomMax,
            enabled: true,
            glassStyle: glassStyle,
            onValueChanged: _updateZoomValue,
            onValueCommitted: _commitZoomValue,
            onReset: _resetZoom,
          ),
        ),
      ],
    );
  }
}

class _RemoteSessionCard extends StatelessWidget {
  const _RemoteSessionCard({required this.info});

  final RemoteSessionInfo info;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoRow(label: 'Session', value: info.sessionId),
          _InfoRow(label: 'Backend', value: info.backend),
          if (info.connectUri != null)
            _InfoRow(label: 'Connect URI', value: info.connectUri!),
          if (info.token != null)
            _InfoRow(label: 'Token', value: info.token!),
          if (info.codecPreference != null)
            _InfoRow(label: 'Codec pref', value: info.codecPreference!),
          if (info.hwcodecEnabled != null)
            _InfoRow(
              label: 'HW codec',
              value: info.hwcodecEnabled! ? 'Enabled' : 'Disabled',
            ),
          if (info.capabilities != null)
            _InfoRow(label: 'Caps', value: info.capabilities!.summary),
        ],
      ),
    );
  }
}

class _RemoteQuicCard extends StatelessWidget {
  const _RemoteQuicCard({
    required this.handshake,
    required this.port,
    required this.stats,
    required this.isConnecting,
    required this.error,
    required this.formatBytes,
    required this.formatLastData,
  });

  final RemoteQuicHandshake? handshake;
  final int? port;
  final RemoteQuicStats stats;
  final bool isConnecting;
  final String? error;
  final String Function(int) formatBytes;
  final String Function(DateTime?) formatLastData;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'QUIC transport',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: const Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 8),
          if (error != null)
            _InlineStatus(message: error!, isError: true)
          else if (isConnecting)
            const _InlineStatus(message: 'Connecting to QUIC...')
          else if (handshake == null)
            const _InlineStatus(message: 'QUIC not connected.')
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _InfoRow(
                  label: 'Port',
                  value: port?.toString() ?? '-',
                ),
                _InfoRow(
                  label: 'Handshake',
                  value: '${handshake!.handshakeMs} ms',
                ),
                _InfoRow(
                  label: 'Data stream',
                  value: handshake!.dataStreamOpened ? 'Opened' : 'Pending',
                ),
                _InfoRow(
                  label: 'Bytes in',
                  value: formatBytes(stats.bytesReceived),
                ),
                _InfoRow(
                  label: 'Last data',
                  value: formatLastData(stats.lastDataAt),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: const Color(0xFF64748B),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF0F172A),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class RustdeskVideoView extends StatefulWidget {
  const RustdeskVideoView({
    super.key,
    required this.sessionId,
    required this.token,
    this.onFirstFrame,
    this.zoom = _rustdeskZoomDefault,
    this.directInput = true,
    this.cornerRadius = 16,
  });

  final String sessionId;
  final String token;
  final VoidCallback? onFirstFrame;
  final double zoom;
  final bool directInput;
  final double cornerRadius;

  @override
  State<RustdeskVideoView> createState() => _RustdeskVideoViewState();
}

class _RustdeskVideoViewState extends State<RustdeskVideoView> {
  static const _frameInterval = Duration(milliseconds: 33);
  static const _kickInterval = Duration(seconds: 1);

  Timer? _timer;
  ui.Image? _image;
  Size? _imageSize;
  Size _viewportSize = Size.zero;
  bool _decoding = false;
  bool _rightDown = false;
  DateTime _lastKick = DateTime.fromMillisecondsSinceEpoch(0);
  bool _notifiedFirstFrame = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_frameInterval, (_) => _tick());
  }

  @override
  void didUpdateWidget(covariant RustdeskVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      _notifiedFirstFrame = false;
      _image?.dispose();
      _image = null;
      _imageSize = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _image?.dispose();
    _image = null;
    super.dispose();
  }

  Future<void> _tick() async {
    if (_decoding) {
      return;
    }
    _decoding = true;
    try {
      final bridge = RustdeskBridge.instance;
      final displaySize = bridge.getDisplaySize(widget.sessionId, 0);
      if (displaySize == null ||
          displaySize.width <= 0 ||
          displaySize.height <= 0) {
        _kickstartSession();
        return;
      }
      final bytes = bridge.copyRgba(widget.sessionId, 0);
      if (bytes == null || bytes.isEmpty) {
        _kickstartSession();
        return;
      }
      final expected = displaySize.width.toInt() * displaySize.height.toInt() * 4;
      if (bytes.length < expected) {
        _kickstartSession();
        return;
      }
      final image = await _decode(bytes, displaySize);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = image;
        _imageSize = displaySize;
      });
      if (!_notifiedFirstFrame) {
        _notifiedFirstFrame = true;
        widget.onFirstFrame?.call();
      }
    } finally {
      _decoding = false;
    }
  }

  void _kickstartSession() {
    final now = DateTime.now();
    if (now.difference(_lastKick) < _kickInterval) {
      return;
    }
    _lastKick = now;
    if (widget.token.isNotEmpty) {
      RustdeskBridge.instance.sessionLogin(widget.sessionId, widget.token);
    }
    RustdeskBridge.instance.sessionSwitchDisplay(widget.sessionId, 0);
  }

  Future<ui.Image> _decode(Uint8List bytes, Size size) {
    final completer = Completer<ui.Image>();
    // RustDesk sends ARGB on iOS; in little-endian that maps to BGRA bytes.
    ui.decodeImageFromPixels(
      bytes,
      size.width.toInt(),
      size.height.toInt(),
      ui.PixelFormat.bgra8888,
      completer.complete,
    );
    return completer.future;
  }

  void _handleTapDown(TapDownDetails details) {
    final remote = _mapToRemote(details.localPosition);
    if (remote == null) {
      return;
    }
    _sendMove(remote);
    _sendClick('down', button: 'left');
  }

  void _handleTapUp(TapUpDetails details) {
    _sendClick('up', button: 'left');
  }

  void _handleLongPressStart(LongPressStartDetails details) {
    _rightDown = true;
    _sendClick('down', button: 'right');
  }

  void _handleLongPressEnd(LongPressEndDetails details) {
    if (_rightDown) {
      _sendClick('up', button: 'right');
      _rightDown = false;
    }
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount == 1) {
      final remote = _mapToRemote(details.localFocalPoint);
      if (remote == null) {
        return;
      }
      _sendMove(remote);
      return;
    }
    if (details.pointerCount >= 2) {
      final dy = details.focalPointDelta.dy;
      if (dy.abs() < 0.5) {
        return;
      }
      final value = dy.round();
      RustdeskBridge.instance.sendMouse(widget.sessionId, {
        'type': 'wheel',
        'y': '$value',
      });
    }
  }

  Offset? _mapToRemote(Offset local) {
    final imageSize = _imageSize;
    if (imageSize == null ||
        imageSize.width <= 0 ||
        imageSize.height <= 0 ||
        _viewportSize.isEmpty) {
      return null;
    }
    final fitted = applyBoxFit(BoxFit.contain, imageSize, _viewportSize);
    final baseDest = fitted.destination;
    final zoom = widget.zoom.clamp(_rustdeskZoomMin, _rustdeskZoomMax);
    final dest = Size(baseDest.width * zoom, baseDest.height * zoom);
    final dx = (_viewportSize.width - dest.width) / 2;
    final dy = (_viewportSize.height - dest.height) / 2;
    if (local.dx < dx ||
        local.dx > dx + dest.width ||
        local.dy < dy ||
        local.dy > dy + dest.height) {
      return null;
    }
    final nx = (local.dx - dx) / dest.width;
    final ny = (local.dy - dy) / dest.height;
    final x = (nx * imageSize.width).clamp(0, imageSize.width - 1).toDouble();
    final y = (ny * imageSize.height).clamp(0, imageSize.height - 1).toDouble();
    return Offset(x, y);
  }

  void _sendMove(Offset remote) {
    final x = remote.dx.round();
    final y = remote.dy.round();
    RustdeskBridge.instance.sendMouse(widget.sessionId, {
      'x': '$x',
      'y': '$y',
    });
  }

  void _sendClick(String type, {required String button}) {
    RustdeskBridge.instance.sendMouse(widget.sessionId, {
      'type': type,
      'buttons': button,
    });
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final allowInput = widget.directInput;
    return LayoutBuilder(
      builder: (context, constraints) {
        final nextViewport = Size(constraints.maxWidth, constraints.maxHeight);
        if (nextViewport != _viewportSize) {
          _viewportSize = nextViewport;
          if (_viewportSize.width > 0 && _viewportSize.height > 0) {
            RustdeskBridge.instance.setDisplaySize(widget.sessionId, 0, _viewportSize);
          }
        }
        return GestureDetector(
          onTapDown: allowInput ? _handleTapDown : null,
          onTapUp: allowInput ? _handleTapUp : null,
          onTapCancel: allowInput ? () => _sendClick('up', button: 'left') : null,
          onLongPressStart: allowInput ? _handleLongPressStart : null,
          onLongPressEnd: allowInput ? _handleLongPressEnd : null,
          onScaleUpdate: allowInput ? _handleScaleUpdate : null,
          behavior: HitTestBehavior.opaque,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(widget.cornerRadius),
            ),
            clipBehavior: Clip.antiAlias,
            alignment: Alignment.center,
            child: image == null
                ? const _InlineStatus(
                    message: 'Waiting for RustDesk frames...',
                  )
                : Transform.scale(
                    scale: widget.zoom.clamp(_rustdeskZoomMin, _rustdeskZoomMax),
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: SizedBox(
                        width: image.width.toDouble(),
                        height: image.height.toDouble(),
                        child: RawImage(
                          image: image,
                          fit: BoxFit.contain,
                          filterQuality:
                              widget.zoom > 1.05 ? FilterQuality.none : FilterQuality.low,
                        ),
                      ),
                    ),
                  ),
          ),
        );
      },
    );
  }
}

class _RustdeskControlBar extends StatelessWidget {
  const _RustdeskControlBar({
    required this.isFullscreen,
    required this.trackpadEnabled,
    required this.onToggleFullscreen,
    required this.onToggleTrackpad,
    required this.onResetZoom,
    this.glassStyle = false,
  });

  final bool isFullscreen;
  final bool trackpadEnabled;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onToggleTrackpad;
  final VoidCallback onResetZoom;
  final bool glassStyle;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      children: [
        _RustdeskControlAction(
          icon: trackpadEnabled ? Icons.touch_app : Icons.touch_app_outlined,
          label: trackpadEnabled ? 'Trackpad on' : 'Trackpad',
          onPressed: onToggleTrackpad,
          glassStyle: glassStyle,
        ),
        _RustdeskControlAction(
          icon: isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
          label: isFullscreen ? 'Exit full' : 'Fullscreen',
          onPressed: onToggleFullscreen,
          glassStyle: glassStyle,
        ),
        _RustdeskControlAction(
          icon: Icons.zoom_out_map,
          label: 'Reset zoom',
          onPressed: onResetZoom,
          glassStyle: glassStyle,
        ),
      ],
    );
  }
}

class _RustdeskControlAction extends StatelessWidget {
  const _RustdeskControlAction({
    required this.icon,
    required this.label,
    this.onPressed,
    this.glassStyle = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool glassStyle;

  @override
  Widget build(BuildContext context) {
    final isEnabled = onPressed != null;
    final foreground = glassStyle
        ? (isEnabled ? Colors.white : Colors.white54)
        : (isEnabled ? const Color(0xFF0F172A) : const Color(0xFF94A3B8));
    final background = glassStyle
        ? Colors.white.withAlpha(isEnabled ? 30 : 12)
        : (isEnabled ? const Color(0xFFE0F2FE) : const Color(0xFFF1F5F9));
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: foreground),
              const SizedBox(width: 6),
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RustdeskZoomBar extends StatefulWidget {
  const _RustdeskZoomBar({
    required this.value,
    required this.min,
    required this.max,
    required this.enabled,
    this.glassStyle = false,
    required this.onValueChanged,
    required this.onValueCommitted,
    required this.onReset,
  });

  final double value;
  final double min;
  final double max;
  final bool enabled;
  final bool glassStyle;
  final ValueChanged<double> onValueChanged;
  final ValueChanged<double> onValueCommitted;
  final VoidCallback onReset;

  @override
  State<_RustdeskZoomBar> createState() => _RustdeskZoomBarState();
}

class _RustdeskZoomBarState extends State<_RustdeskZoomBar> {
  late double _lastValue;

  @override
  void initState() {
    super.initState();
    _lastValue = widget.value;
  }

  @override
  void didUpdateWidget(covariant _RustdeskZoomBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _lastValue = widget.value;
  }

  double _valueForPosition(double localY, double height) {
    if (height <= 0) {
      return widget.value;
    }
    final trackTop = 20.0;
    final trackBottom = height - 20.0;
    final clamped = localY.clamp(trackTop, trackBottom);
    final t = 1 - ((clamped - trackTop) / (trackBottom - trackTop));
    final next = widget.min + (widget.max - widget.min) * t;
    return next.clamp(widget.min, widget.max);
  }

  void _setValue(double value) {
    _lastValue = value;
    widget.onValueChanged(value);
  }

  void _commitValue([double? value]) {
    widget.onValueCommitted(value ?? _lastValue);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final trackTop = 20.0;
        final trackBottom = height - 20.0;
        final clamped = widget.value.clamp(widget.min, widget.max);
        final range = (widget.max - widget.min).abs();
        final t = range <= 0
            ? 0.5
            : ((clamped - widget.min) / range).clamp(0.0, 1.0);
        final knobY = trackBottom - (trackBottom - trackTop) * t;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onDoubleTap: widget.enabled ? widget.onReset : null,
          onTapDown: widget.enabled
              ? (details) {
                  final nextValue =
                      _valueForPosition(details.localPosition.dy, height);
                  _setValue(nextValue);
                  _commitValue(nextValue);
                }
              : null,
          onVerticalDragUpdate: widget.enabled
              ? (details) =>
                  _setValue(_valueForPosition(details.localPosition.dy, height))
              : null,
          onVerticalDragEnd: widget.enabled ? (_) => _commitValue() : null,
          child: Container(
            width: 44,
            decoration: BoxDecoration(
              color: widget.glassStyle
                  ? Colors.white.withAlpha(40)
                  : Colors.black.withAlpha(120),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: widget.glassStyle
                    ? Colors.white.withAlpha(80)
                    : Colors.white.withAlpha(40),
              ),
            ),
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 6,
                  child: Text(
                    '${widget.max.toStringAsFixed(1)}x',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: widget.glassStyle
                              ? Colors.white
                              : Colors.white70,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 6,
                  child: Text(
                    '${widget.min.toStringAsFixed(1)}x',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: widget.glassStyle
                              ? Colors.white
                              : Colors.white70,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: trackTop,
                  bottom: trackTop,
                  child: Center(
                    child: Container(
                      width: 2,
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(
                          widget.glassStyle ? 160 : 90,
                        ),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 4,
                  right: 4,
                  top: knobY - 16,
                  child: Container(
                    height: 32,
                    decoration: BoxDecoration(
                      color: widget.enabled
                          ? (widget.glassStyle
                              ? Colors.white.withAlpha(160)
                              : const Color(0xFF38BDF8))
                          : Colors.white24,
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(80),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        '${(clamped * 100).round()}%',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: widget.glassStyle
                                  ? const Color(0xFF0F172A)
                                  : Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RustdeskTrackpadSurface extends StatelessWidget {
  const _RustdeskTrackpadSurface({
    required this.enabled,
    this.glassStyle = false,
    this.height,
    this.showLabel = true,
    this.disabledMessage,
    required this.onPointerDown,
    required this.onPointerMove,
    required this.onPointerUp,
    required this.onPointerCancel,
  });

  final bool enabled;
  final bool glassStyle;
  final double? height;
  final bool showLabel;
  final String? disabledMessage;
  final ValueChanged<PointerDownEvent> onPointerDown;
  final ValueChanged<PointerMoveEvent> onPointerMove;
  final ValueChanged<PointerUpEvent> onPointerUp;
  final ValueChanged<PointerCancelEvent> onPointerCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = glassStyle
        ? Colors.white.withAlpha(enabled ? 30 : 12)
        : (enabled ? const Color(0xFFF1F5F9) : const Color(0xFFE2E8F0));
    final borderColor = glassStyle
        ? Colors.white.withAlpha(enabled ? 120 : 60)
        : (enabled ? const Color(0xFFCBD5F5) : const Color(0xFFE2E8F0));
    final iconColor = glassStyle
        ? (enabled ? Colors.white : Colors.white54)
        : (enabled ? const Color(0xFF475569) : const Color(0xFF94A3B8));
    final textColor = glassStyle
        ? (enabled ? Colors.white : Colors.white54)
        : (enabled ? const Color(0xFF475569) : const Color(0xFF94A3B8));
    return GestureDetector(
      onPanStart: enabled ? (_) {} : null,
      onPanUpdate: enabled ? (_) {} : null,
      behavior: HitTestBehavior.opaque,
      child: Listener(
        onPointerDown: enabled ? onPointerDown : null,
        onPointerMove: enabled ? onPointerMove : null,
        onPointerUp: enabled ? onPointerUp : null,
        onPointerCancel: enabled ? onPointerCancel : null,
        child: Container(
          height: height ?? 120,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor),
          ),
          child: Center(
            child: showLabel
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.touch_app,
                        color: iconColor,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        enabled
                            ? 'Trackpad ready'
                            : (disabledMessage ?? 'Connect to enable input'),
                        style: theme.textTheme.bodySmall?.copyWith(
                              color: textColor,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
