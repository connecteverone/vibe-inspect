part of '../main.dart';

const double _rustdeskZoomMin = 0.7;
const double _rustdeskZoomMax = 3.0;
const double _rustdeskZoomDefault = 1.0;
const double _rustdeskZoomBarWidth = 48;
const double _rustdeskTrackpadHeightPortrait = 180;
const double _rustdeskMouseButtonHeight = 48;
const double _rustdeskControlGap = 12;
const double _rustdeskButtonGap = 8;
const double _rustdeskPortraitControlsHeight =
    _rustdeskTrackpadHeightPortrait +
    _rustdeskMouseButtonHeight +
    _rustdeskButtonGap;
const double _rustdeskZoomSnapRange = 0.05;
const double _rustdeskKeyboardPanelMinHeight = 220;
const double _rustdeskKeyboardPanelMaxHeight = 340;
const double _rustdeskKeyboardPanelHeightFactor = 0.34;

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
      final portFromSession = port != null && port > 0;
      if (port == null || port <= 0) {
        final identity = await client.fetchIdentity();
        port = _parsePort(identity['roi_quic_port']);
      }
      if (port == null || port <= 0) {
        throw StateError('ROI QUIC port missing from identity response.');
      }
      final host = _extractHost(agentBaseUrl ?? '');
      if (kDebugMode) {
        debugPrint(
          '[remote] QUIC connect: host=$host port=$port source=${portFromSession ? 'session' : 'identity'} '
          'session=${info.sessionId} backend=${info.backend} display=${info.displayIndex ?? 0} '
          'tokenLen=${token.length} authToken=${authToken != null}',
        );
      }
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
      rustdesk.setToggleOption(rustdeskSessionId, 'show-remote-cursor', true);
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
      if (kDebugMode) {
        debugPrint('[remote] QUIC connect failed: $error');
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
  late final RustdeskInputController _inputController;
  bool _isFullscreen = false;
  bool _trackpadInteracting = false;
  bool _overlayOnDarkBackground = true;
  double _zoomValue = _rustdeskZoomDefault;
  Size _displaySize = Size.zero;
  bool? _hostNaturalScroll;
  bool _showPortraitKeyboardPanel = false;
  late final TextEditingController _keyboardTextController;

  @override
  void initState() {
    super.initState();
    _controller = RemoteSessionController(
      agentBaseUrl: widget.agentBaseUrl,
      authToken: widget.authToken,
      clientId: widget.clientId,
      clientName: widget.clientName,
    );
    _inputController = RustdeskInputController(bridge: RustdeskBridge.instance);
    _inputController.setTrackpadScrollBehavior(const TrackpadScrollBehavior());
    _keyboardTextController = TextEditingController();
    _controller.addListener(_handleControllerUpdate);
    _bootstrap();
  }

  Future<void> _bootstrap() => _controller.bootstrap();

  Future<void> _startRemote() => _controller.startRemote();

  Future<void> _stopRemote() => _controller.stopRemote();

  Future<void> _connectQuic(RemoteSessionInfo info) =>
      _controller.connectQuic(info);

  void _syncTrackpadScrollBehavior() {
    final hostNaturalScroll =
        _controller.sessionInfo?.inputPreferences?.naturalScroll;
    if (_hostNaturalScroll == hostNaturalScroll) {
      return;
    }
    _hostNaturalScroll = hostNaturalScroll;
    _inputController.setTrackpadScrollBehavior(
      TrackpadScrollBehavior(
        mode: TrackpadScrollMode.followHost,
        hostNaturalScroll: hostNaturalScroll,
      ),
    );
  }

  void _handleControllerUpdate() {
    _syncTrackpadScrollBehavior();
    if (!mounted) return;
    setState(() {});
  }

  void _handleDisplaySize(Size size) {
    _inputController.updateDisplaySize(size);
    if (!mounted) {
      return;
    }
    if (size != _displaySize) {
      setState(() {
        _displaySize = size;
      });
    }
  }

  void _handleFrameLuma(double luma) {
    final next = luma < 0.57
        ? true
        : (luma > 0.63 ? false : _overlayOnDarkBackground);
    if (next == _overlayOnDarkBackground || !mounted) {
      return;
    }
    setState(() {
      _overlayOnDarkBackground = next;
    });
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

  double _normalizeZoomValue(double value) {
    final clamped = value.clamp(_rustdeskZoomMin, _rustdeskZoomMax).toDouble();
    if ((clamped - _rustdeskZoomDefault).abs() <= _rustdeskZoomSnapRange) {
      return _rustdeskZoomDefault;
    }
    return clamped;
  }

  void _handleTrackpadInteractionChanged(bool active) {
    if (_trackpadInteracting == active || !mounted) {
      return;
    }
    setState(() {
      _trackpadInteracting = active;
    });
  }

  void _updateZoomValue(double value) {
    final clamped = _normalizeZoomValue(value);
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

  void _togglePortraitKeyboardPanel() {
    if (!mounted) {
      return;
    }
    setState(() {
      _showPortraitKeyboardPanel = !_showPortraitKeyboardPanel;
    });
  }

  void _hidePortraitKeyboardPanel() {
    if (!_showPortraitKeyboardPanel || !mounted) {
      return;
    }
    setState(() {
      _showPortraitKeyboardPanel = false;
    });
  }

  @override
  void dispose() {
    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _inputController.leftUp();
    _inputController.rightUp();
    _keyboardTextController.dispose();
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
        physics: _trackpadInteracting
            ? const NeverScrollableScrollPhysics()
            : null,
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
                    'QUIC-only RustDesk stream. Use the trackpad below to move, double-tap to click.',
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
                        label: const Text('Start session'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _controller.isStopping ? null : _stopRemote,
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop session'),
                      ),
                      OutlinedButton.icon(
                        onPressed:
                            _controller.isQuicConnecting || sessionInfo == null
                            ? null
                            : () => _connectQuic(sessionInfo),
                        icon: const Icon(Icons.bolt),
                        label: const Text('Reconnect stream'),
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
            sliver: SliverToBoxAdapter(child: _buildRemoteView(sessionInfo)),
          ),
        ],
      ),
    );
  }
}

extension on _RemoteSessionScreenState {
  Widget _buildFullscreenView(RemoteSessionInfo? sessionInfo) {
    final orientation = MediaQuery.of(context).orientation;
    if (orientation == Orientation.landscape) {
      return _buildFullscreenLandscape(sessionInfo);
    }
    return _buildFullscreenPortrait(sessionInfo);
  }

  Widget _buildFullscreenPortrait(RemoteSessionInfo? sessionInfo) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          return;
        }
        if (_isFullscreen) {
          unawaited(_setFullscreen(false));
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF8FAFC),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: _buildPortraitSession(sessionInfo, fullscreen: true),
          ),
        ),
      ),
    );
  }

  Widget _buildFullscreenLandscape(RemoteSessionInfo? sessionInfo) {
    final rustdeskSessionId = _controller.rustdeskSessionId;
    if (rustdeskSessionId == null) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            return;
          }
          if (_isFullscreen) {
            unawaited(_setFullscreen(false));
          }
        },
        child: const Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: _InlineStatus(message: 'RustDesk stream not connected.'),
          ),
        ),
      );
    }
    _inputController.attachSession(rustdeskSessionId);
    final token = sessionInfo?.token ?? '';
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          return;
        }
        if (_isFullscreen) {
          unawaited(_setFullscreen(false));
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: _buildRustdeskView(
                sessionId: rustdeskSessionId,
                token: token,
                backgroundColor: Colors.black,
                cornerRadius: 0,
                monitorLuma: true,
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final leftPaneWidth = constraints.maxWidth * 0.5;
                    final rightPaneWidth = constraints.maxWidth - leftPaneWidth;
                    final buttonLeftInset =
                        _rustdeskZoomBarWidth + _rustdeskControlGap;
                    return Stack(
                      children: [
                        Row(
                          children: [
                            SizedBox(
                              width: leftPaneWidth,
                              child: Stack(
                                children: [
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: SizedBox(
                                      width: _rustdeskZoomBarWidth,
                                      height: constraints.maxHeight,
                                      child: RustdeskZoomBar(
                                        value: _zoomValue,
                                        min: _rustdeskZoomMin,
                                        max: _rustdeskZoomMax,
                                        enabled: true,
                                        glassStyle: true,
                                        darkBackground:
                                            _overlayOnDarkBackground,
                                        onValueChanged: _updateZoomValue,
                                        onValueCommitted: _commitZoomValue,
                                        onReset: _resetZoom,
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    left: buttonLeftInset,
                                    right: _rustdeskControlGap,
                                    bottom: 0,
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: RustdeskMouseButton(
                                            label: 'Left click',
                                            onDown: _inputController.leftDown,
                                            onUp: _inputController.leftUp,
                                            glassStyle: true,
                                            darkBackground:
                                                _overlayOnDarkBackground,
                                          ),
                                        ),
                                        const SizedBox(
                                          width: _rustdeskButtonGap,
                                        ),
                                        Expanded(
                                          child: RustdeskMouseButton(
                                            label: 'Right click',
                                            onDown: _inputController.rightDown,
                                            onUp: _inputController.rightUp,
                                            glassStyle: true,
                                            darkBackground:
                                                _overlayOnDarkBackground,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(
                              width: rightPaneWidth,
                              child: RustdeskTrackpadSurface(
                                input: _inputController,
                                height: constraints.maxHeight,
                                glassStyle: true,
                                darkBackground: _overlayOnDarkBackground,
                                showLabel: false,
                                onInteractionChanged:
                                    _handleTrackpadInteractionChanged,
                              ),
                            ),
                          ],
                        ),
                        Align(
                          alignment: Alignment.topRight,
                          child: RustdeskMoreMenuButton(
                            onKeyboard: _showKeyboardPanel,
                            onExitFullscreen: _toggleFullscreen,
                            darkBackground: _overlayOnDarkBackground,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRemoteView(RemoteSessionInfo? sessionInfo) {
    return _buildPortraitSession(sessionInfo, fullscreen: false);
  }

  Widget _buildPortraitSession(
    RemoteSessionInfo? sessionInfo, {
    required bool fullscreen,
  }) {
    final rustdeskSessionId = _controller.rustdeskSessionId;
    if (rustdeskSessionId == null) {
      return const _InlineStatus(message: 'RustDesk stream not connected.');
    }
    _inputController.attachSession(rustdeskSessionId);
    final token = sessionInfo?.token ?? '';
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final display = _displaySize;
        final aspect = display.width > 0 && display.height > 0
            ? display.width / display.height
            : (16 / 9);
        final desiredHeight = maxWidth / aspect;
        final mediaQuery = MediaQuery.of(context);
        final supportsInlineKeyboard =
            mediaQuery.orientation == Orientation.portrait;
        final adaptiveInlineKeyboardHeight =
            (mediaQuery.size.height * _rustdeskKeyboardPanelHeightFactor)
                .clamp(
                  _rustdeskKeyboardPanelMinHeight,
                  _rustdeskKeyboardPanelMaxHeight,
                )
                .toDouble();
        final baseInlineKeyboardHeight =
            supportsInlineKeyboard && _showPortraitKeyboardPanel
            ? adaptiveInlineKeyboardHeight
            : 0.0;
        final inlineKeyboardHeight = fullscreen
            ? math.min(
                baseInlineKeyboardHeight,
                math.max(0.0, constraints.maxHeight - _rustdeskControlGap),
              )
            : baseInlineKeyboardHeight;
        final showInlineKeyboard = inlineKeyboardHeight > 0;
        final inlineKeyboardGap = showInlineKeyboard
            ? _rustdeskControlGap
            : 0.0;
        final rawMaxHeight = fullscreen
            ? constraints.maxHeight -
                  _rustdeskControlGap -
                  inlineKeyboardGap -
                  inlineKeyboardHeight
            : desiredHeight;
        final maxHeight = fullscreen
            ? math.max(0.0, rawMaxHeight)
            : rawMaxHeight;
        final minRemoteHeight = fullscreen
            ? math.min(160.0, maxHeight)
            : desiredHeight;
        final remoteHeight = fullscreen
            ? desiredHeight.clamp(minRemoteHeight, maxHeight).toDouble()
            : desiredHeight;
        final controlsHeight = fullscreen
            ? math.max(
                0.0,
                constraints.maxHeight -
                    remoteHeight -
                    _rustdeskControlGap -
                    inlineKeyboardGap -
                    inlineKeyboardHeight,
              )
            : _rustdeskPortraitControlsHeight;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Stack(
              children: [
                SizedBox(
                  height: remoteHeight,
                  child: _buildRustdeskView(
                    sessionId: rustdeskSessionId,
                    token: token,
                    backgroundColor: Colors.transparent,
                    cornerRadius: fullscreen ? 0 : 16,
                    monitorLuma: fullscreen,
                  ),
                ),
                Positioned(
                  top: 12,
                  right: 12,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RustdeskIconButton(
                        icon: _showPortraitKeyboardPanel
                            ? Icons.keyboard_hide
                            : Icons.keyboard,
                        onPressed: _showKeyboardPanel,
                        tooltip: _showPortraitKeyboardPanel
                            ? 'Hide keyboard input'
                            : 'Keyboard input',
                        glassStyle: fullscreen,
                        darkBackground: _overlayOnDarkBackground,
                      ),
                      const SizedBox(width: 8),
                      RustdeskIconButton(
                        icon: fullscreen
                            ? Icons.fullscreen_exit
                            : Icons.fullscreen,
                        onPressed: _toggleFullscreen,
                        tooltip: fullscreen
                            ? 'Leave fullscreen'
                            : 'Enter fullscreen',
                        glassStyle: fullscreen,
                        darkBackground: _overlayOnDarkBackground,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (showInlineKeyboard) ...[
              const SizedBox(height: _rustdeskControlGap),
              SizedBox(
                height: inlineKeyboardHeight,
                child: RustdeskKeyboardPanel(
                  input: _inputController,
                  controller: _keyboardTextController,
                  closeLabel: 'Hide',
                  onClose: _hidePortraitKeyboardPanel,
                ),
              ),
            ],
            const SizedBox(height: _rustdeskControlGap),
            _buildPortraitControls(
              glassStyle: false,
              darkBackground: _overlayOnDarkBackground,
              controlsHeight: controlsHeight,
            ),
          ],
        );
      },
    );
  }

  Widget _buildPortraitControls({
    required bool glassStyle,
    required bool darkBackground,
    required double controlsHeight,
  }) {
    final trackpadHeight = math.max(
      0.0,
      controlsHeight - _rustdeskMouseButtonHeight - _rustdeskButtonGap,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: _rustdeskZoomBarWidth,
          height: controlsHeight,
          child: RustdeskZoomBar(
            value: _zoomValue,
            min: _rustdeskZoomMin,
            max: _rustdeskZoomMax,
            enabled: true,
            glassStyle: glassStyle,
            darkBackground: darkBackground,
            onValueChanged: _updateZoomValue,
            onValueCommitted: _commitZoomValue,
            onReset: _resetZoom,
          ),
        ),
        const SizedBox(width: _rustdeskControlGap),
        Expanded(
          child: Column(
            children: [
              RustdeskTrackpadSurface(
                input: _inputController,
                height: trackpadHeight,
                glassStyle: glassStyle,
                darkBackground: darkBackground,
                showLabel: false,
                onInteractionChanged: _handleTrackpadInteractionChanged,
              ),
              const SizedBox(height: _rustdeskButtonGap),
              Row(
                children: [
                  Expanded(
                    child: RustdeskMouseButton(
                      label: 'Left click',
                      onDown: _inputController.leftDown,
                      onUp: _inputController.leftUp,
                      glassStyle: glassStyle,
                      darkBackground: darkBackground,
                    ),
                  ),
                  const SizedBox(width: _rustdeskButtonGap),
                  Expanded(
                    child: RustdeskMouseButton(
                      label: 'Right click',
                      onDown: _inputController.rightDown,
                      onUp: _inputController.rightUp,
                      glassStyle: glassStyle,
                      darkBackground: darkBackground,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRustdeskView({
    required String sessionId,
    required String token,
    required Color backgroundColor,
    required double cornerRadius,
    bool monitorLuma = false,
  }) {
    return RustdeskVideoView(
      sessionId: sessionId,
      token: token,
      onFirstFrame: _controller.markFrameReceived,
      onFrameLuma: monitorLuma ? _handleFrameLuma : null,
      zoom: _zoomValue,
      input: _inputController,
      showRemoteCursor: true,
      showLocalCursor: false,
      allowInput: false,
      cornerRadius: cornerRadius,
      backgroundColor: backgroundColor,
      onDisplaySize: _handleDisplaySize,
    );
  }

  void _showKeyboardPanel() {
    final orientation = MediaQuery.of(context).orientation;
    if (orientation == Orientation.portrait) {
      _togglePortraitKeyboardPanel();
      return;
    }
    showRustdeskKeyboardSheet(context, _inputController);
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
          if (info.token != null) _InfoRow(label: 'Token', value: info.token!),
          if (info.codecPreference != null)
            _InfoRow(label: 'Codec pref', value: info.codecPreference!),
          if (info.hwcodecEnabled != null)
            _InfoRow(
              label: 'HW codec',
              value: info.hwcodecEnabled! ? 'Enabled' : 'Disabled',
            ),
          if (info.capabilities != null)
            _InfoRow(label: 'Caps', value: info.capabilities!.summary),
          if (info.inputPreferences?.naturalScroll != null)
            _InfoRow(
              label: 'Natural scroll',
              value: info.inputPreferences!.naturalScroll! ? 'On' : 'Off',
            ),
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
                _InfoRow(label: 'Port', value: port?.toString() ?? '-'),
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
