part of '../main.dart';

const double _zoomMin = 0.5;
const double _zoomMax = 3.0;
const double _zoomDefault = 1.0;
const double _roiZoomThreshold = 1.05;
const double _swipeThreshold = 120;
const double _tapSlop = kTouchSlop;
const double _scrollStep = 18;
const Duration _tapTimeout = Duration(milliseconds: 240);
const Duration _doubleTapTimeout = kDoubleTapTimeout;
const int _encodingRaw = 0;
const int _encodingCopyRect = 1;
const int _encodingZlib = 6;
const int _encodingTight = 7;
const int _encodingZrle = 16;
const int _encodingCursor = -239;
const int _encodingCompressLevelBase = -256;
const int _encodingQualityLevelBase = -32;
const int _encodingDataSaver = -312;
const int _encodingHighPerf = -313;
const Duration _noFrameTimeout = Duration(seconds: 8);
const Duration _fpsWindow = Duration(milliseconds: 1000);
const double _trackpadMoreButtonWidth = 84;
const double _trackpadMoreButtonHeight = 36;
const double _trackpadMoreButtonMargin = 10;
const Offset _trackpadMoreAnchorDefault = Offset(0.88, 0.1);
const int _calibrationVersion = 2;
const double _calibrationAspectTolerance = 0.02;

class VncSessionScreen extends StatefulWidget {
  const VncSessionScreen({
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
  State<VncSessionScreen> createState() => _VncSessionScreenState();
}

enum VncEncodingPreference {
  zrle,
  tight,
  zlib,
  raw,
}

enum VncViewMode {
  fit,
  fill,
  original,
}

enum VncColorDepth {
  full,
  depth16,
}

class _VncSessionScreenState extends State<VncSessionScreen> {

  late Offset _pointerPosition;
  late Offset _cameraCenter;
  double _zoomValue = _zoomDefault;
  VncEncodingPreference _encodingPreference = VncEncodingPreference.zrle;
  int _tightCompressionLevel = 6;
  int _tightQualityLevel = 6;
  bool _tightJpegEnabled = false;
  bool _lowLatencyEnabled = true;
  VncColorDepth _colorDepth = VncColorDepth.full;
  bool _dataSaverEnabled = false;
  bool _highPerfEnabled = false;
  int _highPerfIntervalMs = 10;
  VncViewMode _viewMode = VncViewMode.fit;
  bool _isConnecting = false;
  bool _isResizing = false;
  String? _connectionError;
  Timer? _clickTimer;
  Timer? _focusTimer;
  Timer? _pinchCommitTimer;
  bool _showFocusPulse = false;
  bool _showClickPulse = false;
  double _swipeDistance = 0;
  Offset? _lastHoverPosition;
  late DateTime _lastUpdatedAt;
  http.Client? _httpClient;
  AgentCommandClient? _agentClient;
  VncRfbClient? _vncClient;
  VncSessionInfo? _lastVncSessionInfo;
  RoiClient _roiClient = RoiNoopClient();
  RoiSessionInfo? _roiSession;
  StreamSubscription<RoiTilePayload>? _roiSubscription;
  final Map<RoiTileKey, ui.Image> _roiImages = {};
  final Map<RoiTileKey, ui.Image> _roiPendingImages = {};
  final Map<RoiTileKey, int> _roiPendingSizes = {};
  final Map<RoiTileKey, int> _roiTileFrameIds = {};
  int _roiPendingCount = 0;
  int _roiPendingBytes = 0;
  Timer? _roiBatchTimer;
  RoiRenderer? _roiRenderer;
  Timer? _roiRequestTimer;
  Timer? _roiReconnectTimer;
  Timer? _roiResyncTimer;
  Size? _roiPendingResyncSize;
  double _devicePixelRatio = 1.0;
  DateTime? _roiLastTileAt;
  bool _roiConnecting = false;
  bool _roiConnected = false;
  DateTime? _roiConnectedAt;
  DateTime? _roiLastRequestAt;
  int _roiTileCount = 0;
  int _roiTileBytes = 0;
  String? _roiLastError;
  String? _roiHost;
  String? _roiDisabledReason;
  int _roiReconnectAttempts = 0;
  int _roiRevision = 0;
  bool _debugPanelOpen = false;
  bool _debugPanelVisible = false;
  ui.Image? _frameImage;
  ui.Image? _cursorImage;
  Size _cursorSize = Size.zero;
  Offset _cursorHotspot = Offset.zero;
  Size _frameSize = const Size(720, 1280);
  bool _isDecoding = false;
  VncFrame? _pendingFrame;
  DateTime? _streamStartedAt;
  DateTime? _lastFrameAt;
  Timer? _noFrameTimer;
  final List<int> _frameTimestamps = [];
  double _streamFps = 0;
  int? _streamLatencyMs;
  DateTime? _lastInputAt;
  bool _controlsSheetOpen = false;
  int _buttonMask = 0;
  bool _isDragging = false;
  Size _lastViewSize = Size.zero;
  Size _lastTrackpadSize = Size.zero;
  bool _directDragActive = false;
  final Map<int, Offset> _activePointers = {};
  Offset? _primaryDownPosition;
  DateTime? _primaryDownTime;
  Offset? _lastPrimaryPosition;
  Offset? _lastMultiFingerPosition;
  DateTime? _lastTapTime;
  Offset? _lastTapPosition;
  bool _isFullscreen = false;
  double _inputScaleX = 1;
  double _inputScaleY = 1;
  double _inputOffsetX = 0;
  double _inputOffsetY = 0;
  bool _directInputEnabled = false;
  bool _showLocalCursor = false;
  bool _cursorDebugEnabled = false;
  final List<String> _cursorDebugLog = [];
  DateTime? _lastCursorDebugLoggedAt;
  Offset? _lastCursorDebugPointer;
  DateTime? _lastGestureDoubleTapAt;
  bool? _directInputBackup;
  int? _selectedDisplayIndex;
  List<VncDisplayInfo> _availableDisplays = const [];
  bool _isAutoCalibrating = false;
  int _calibrationStep = 0;
  List<Offset> _calibrationTargets = const [];
  final List<Offset> _calibrationSamples = [];
  Timer? _calibrationSaveTimer;
  Timer? _autoResizeTimer;
  bool _autoSizedOnce = false;
  bool _pendingFullFrameRequest = false;
  double? _calibrationBackupScaleX;
  double? _calibrationBackupScaleY;
  double? _calibrationBackupOffsetX;
  double? _calibrationBackupOffsetY;
  double? _calibrationAspectRatio;
  bool _calibrationNormalized = true;
  bool _hasStreamInfo = false;
  bool _isDisposed = false;
  Offset _trackpadMoreAnchor = _trackpadMoreAnchorDefault;
  bool _trackpadMoreRepositioning = false;
  Timer? _layoutRecalibrationTimer;
  bool _pendingLayoutRecalibration = false;
  DateTime? _lastRecalibrationAt;
  Size _lastLayoutSize = Size.zero;
  bool? _lastLayoutLandscape;
  bool _lastLayoutFullscreen = false;
  bool _pendingPointerReset = false;
  double _scrollAccumulator = 0;
  double _scrollAccumulatorX = 0;

  void _updateState(VoidCallback fn) {
    setState(fn);
  }

  @override
  void initState() {
    super.initState();
    _pointerPosition = Offset(
      _frameSize.width / 2,
      _frameSize.height / 2,
    );
    _cameraCenter = _applyInputCalibration(_pointerPosition);
    _autoSizedOnce = false;
    _lastUpdatedAt = widget.event.createdAt;
    _configureAgentClient();
    _configureRoiClient();
    _hydrateFromPayload();
    unawaited(_loadDisplaySelection());
    unawaited(_loadLocalCursorPreference());
    unawaited(_loadDebugPanelPreference());
    unawaited(_loadCalibration());
    unawaited(_fetchDisplays());
    unawaited(_startStream());
  }

  @override
  void dispose() {
    _isDisposed = true;
    _clickTimer?.cancel();
    _focusTimer?.cancel();
    _pinchCommitTimer?.cancel();
    _calibrationSaveTimer?.cancel();
    _autoResizeTimer?.cancel();
    _noFrameTimer?.cancel();
    _layoutRecalibrationTimer?.cancel();
    unawaited(_stopRoiSession());
    _vncClient?.close();
    _frameImage?.dispose();
    _cursorImage?.dispose();
    _httpClient?.close();
    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  void _configureAgentClient() {
    final baseUrl = widget.agentBaseUrl?.trim();
    if (baseUrl == null || baseUrl.isEmpty) {
      _agentClient = null;
      return;
    }
    _httpClient = http.Client();
    _agentClient = AgentCommandClient(
      baseUrl: baseUrl,
      client: _httpClient!,
      authToken: widget.authToken,
      clientId: widget.clientId,
      clientName: widget.clientName,
    );
  }

  double _recordFrameFps(int nowMs) {
    _frameTimestamps.add(nowMs);
    final cutoff = nowMs - _fpsWindow.inMilliseconds;
    while (_frameTimestamps.length > 1 && _frameTimestamps.first < cutoff) {
      _frameTimestamps.removeAt(0);
    }
    final spanMs = _frameTimestamps.length > 1
        ? nowMs - _frameTimestamps.first
        : _fpsWindow.inMilliseconds;
    if (spanMs <= 0) {
      return _frameTimestamps.length.toDouble();
    }
    final fps = _frameTimestamps.length * 1000 / spanMs;
    return fps.clamp(0, 120).toDouble();
  }

  int? _resolveLatencyMs(VncFrame frame, int nowMs) {
    final lastInputAt = _lastInputAt;
    if (lastInputAt == null) {
      final requestLatency = frame.latencyMs;
      if (requestLatency == null || requestLatency > 1000) {
        return null;
      }
      return requestLatency;
    }
    final delta = nowMs - lastInputAt.millisecondsSinceEpoch;
    if (delta < 0 || delta > 5000) {
      final requestLatency = frame.latencyMs;
      if (requestLatency == null || requestLatency > 1000) {
        return null;
      }
      return requestLatency;
    }
    return delta;
  }

  void _hydrateFromPayload() {
    final status = widget.event.payload['status']?.toString().toLowerCase();
    if (status == 'failed' || status == 'error') {
      _connectionError =
          widget.event.payload['error']?.toString() ??
              'VNC stream failed. Retry to reconnect.';
    }
    final updatedAt = widget.event.payload['updated_at']?.toString();
    if (updatedAt != null) {
      final parsed = DateTime.tryParse(updatedAt);
      if (parsed != null) {
        _lastUpdatedAt = parsed;
      }
    }
    final zoomValue = widget.event.payload['zoom'];
    if (zoomValue is num) {
      _zoomValue = _clampZoom(zoomValue.toDouble());
    }
  }

  double? _currentAspectRatio() {
    if (_frameSize.width <= 0 || _frameSize.height <= 0) {
      return null;
    }
    return _frameSize.width / _frameSize.height;
  }

  bool _isAspectRatioCompatible(double? stored, Size size) {
    if (stored == null || size.width <= 0 || size.height <= 0) {
      return true;
    }
    final ratio = size.width / size.height;
    return (ratio - stored).abs() <= _calibrationAspectTolerance;
  }

  bool _isDefaultCalibration() {
    return (_inputScaleX - 1).abs() < 0.0001 &&
        (_inputScaleY - 1).abs() < 0.0001 &&
        _inputOffsetX.abs() < 0.0001 &&
        _inputOffsetY.abs() < 0.0001;
  }

  void _applyCalibrationDefaults({bool sendPointer = true}) {
    if (!mounted) {
      return;
    }
    setState(() {
      _inputScaleX = 1;
      _inputScaleY = 1;
      _inputOffsetX = 0;
      _inputOffsetY = 0;
      _calibrationAspectRatio = null;
      _calibrationNormalized = true;
      _cameraCenter = _applyInputCalibration(_pointerPosition);
    });
    if (sendPointer) {
      _sendPointerEvent();
    }
  }

  void _maybeInvalidateCalibrationForFrameSize() {
    if (!_hasStreamInfo || !_calibrationNormalized) {
      return;
    }
    if (_isDefaultCalibration()) {
      return;
    }
    if (!_isAspectRatioCompatible(_calibrationAspectRatio, _frameSize)) {
      unawaited(_resetCalibration());
    }
  }

  String _calibrationStorageKey() {
    final agentId = widget.session.agentId ?? widget.session.id;
    final displayIndex = _selectedDisplayIndex ?? 0;
    return 'vnc_calibration:$agentId:$displayIndex';
  }

  Future<void> _loadCalibration() async {
    final raw = await widget.storage.readKeyValue(_calibrationStorageKey());
    if (!mounted) {
      return;
    }
    if (raw == null || raw.trim().isEmpty) {
      _applyCalibrationDefaults();
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        await widget.storage.deleteKeyValue(_calibrationStorageKey());
        _applyCalibrationDefaults();
        return;
      }
      final version = (decoded['version'] as num?)?.toInt() ?? 1;
      final normalized = decoded['normalized'] == true;
      final scaleX = (decoded['scaleX'] as num?)?.toDouble();
      final scaleY = (decoded['scaleY'] as num?)?.toDouble();
      final offsetX = (decoded['offsetX'] as num?)?.toDouble();
      final offsetY = (decoded['offsetY'] as num?)?.toDouble();
      final aspectRatio = (decoded['aspectRatio'] as num?)?.toDouble();
      if (!normalized ||
          version != _calibrationVersion ||
          scaleX == null ||
          scaleY == null ||
          offsetX == null ||
          offsetY == null) {
        await widget.storage.deleteKeyValue(_calibrationStorageKey());
        _applyCalibrationDefaults();
        return;
      }
      setState(() {
        _inputScaleX = scaleX;
        _inputScaleY = scaleY;
        _inputOffsetX = offsetX;
        _inputOffsetY = offsetY;
        _calibrationAspectRatio = aspectRatio;
        _calibrationNormalized = true;
        _cameraCenter = _applyInputCalibration(_pointerPosition);
      });
      _sendPointerEvent();
      _maybeInvalidateCalibrationForFrameSize();
    } catch (_) {
      await widget.storage.deleteKeyValue(_calibrationStorageKey());
      _applyCalibrationDefaults();
      return;
    }
  }

  void _scheduleCalibrationSave() {
    _calibrationSaveTimer?.cancel();
    _calibrationSaveTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(_persistCalibration());
    });
  }

  Future<void> _persistCalibration() async {
    final aspectRatio = _currentAspectRatio();
    final payload = jsonEncode({
      'version': _calibrationVersion,
      'normalized': true,
      'scaleX': _inputScaleX,
      'scaleY': _inputScaleY,
      'offsetX': _inputOffsetX,
      'offsetY': _inputOffsetY,
      'aspectRatio': aspectRatio,
    });
    await widget.storage.writeKeyValue(_calibrationStorageKey(), payload);
  }

  Future<void> _resetCalibration() async {
    _applyCalibrationDefaults();
    await widget.storage.deleteKeyValue(_calibrationStorageKey());
  }

  String _displayStorageKey() {
    final agentId = widget.session.agentId ?? widget.session.id;
    return 'vnc_display:$agentId';
  }

  String _localCursorStorageKey() {
    final agentId = widget.session.agentId ?? widget.session.id;
    return 'vnc_local_cursor:$agentId';
  }

  String _debugPanelStorageKey() {
    final agentId = widget.session.agentId ?? widget.session.id;
    return 'vnc_debug_panel:$agentId';
  }

  String _agentLogId() {
    return widget.session.agentId ?? widget.session.id;
  }

  Future<void> _loadDisplaySelection() async {
    final raw = await widget.storage.readKeyValue(_displayStorageKey());
    if (!mounted || raw == null || raw.trim().isEmpty) {
      return;
    }
    final parsed = int.tryParse(raw);
    if (parsed == null) {
      return;
    }
    setState(() {
      _selectedDisplayIndex = parsed;
    });
  }

  Future<void> _persistDisplaySelection(int? index) async {
    if (index == null) {
      await widget.storage.deleteKeyValue(_displayStorageKey());
      return;
    }
    await widget.storage.writeKeyValue(_displayStorageKey(), index.toString());
  }

  Future<void> _loadLocalCursorPreference() async {
    final raw = await widget.storage.readKeyValue(_localCursorStorageKey());
    if (!mounted || raw == null || raw.trim().isEmpty) {
      return;
    }
    final normalized = raw.trim().toLowerCase();
    final nextValue = normalized == '1' || normalized == 'true';
    setState(() {
      _showLocalCursor = nextValue;
    });
  }

  Future<void> _persistLocalCursorPreference(bool value) async {
    await widget.storage.writeKeyValue(
      _localCursorStorageKey(),
      value ? '1' : '0',
    );
  }

  Future<void> _loadDebugPanelPreference() async {
    final raw = await widget.storage.readKeyValue(_debugPanelStorageKey());
    if (!mounted || raw == null || raw.trim().isEmpty) {
      return;
    }
    final normalized = raw.trim().toLowerCase();
    final nextValue = normalized == '1' || normalized == 'true';
    setState(() {
      _debugPanelVisible = nextValue;
    });
  }

  Future<void> _persistDebugPanelPreference(bool value) async {
    await widget.storage.writeKeyValue(
      _debugPanelStorageKey(),
      value ? '1' : '0',
    );
  }

  Future<void> _logAgentEvent(
    String type, {
    String level = 'info',
    Map<String, Object?>? data,
  }) async {
    try {
      final entry = <String, Object?>{
        't': DateTime.now().toIso8601String(),
        'type': type,
        'level': level,
        if (data != null) 'data': data,
      };
      final payload = jsonEncode(entry);
      final sizeBytes = utf8.encode(payload).length;
      await widget.storage.insertAgentLog(
        AgentLogEntry(
          id: createStorageId(),
          agentId: _agentLogId(),
          level: level,
          message: payload,
          createdAt: DateTime.now(),
          sizeBytes: sizeBytes,
        ),
      );
    } catch (_) {
      // Avoid breaking the UI on log failures.
    }
  }

  Future<void> _copyAgentLogs() async {
    final logs = await widget.storage.fetchAgentLogs(_agentLogId());
    if (logs.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无日志')),
      );
      return;
    }
    final totalBytes = logs.fold<int>(0, (sum, entry) => sum + entry.sizeBytes);
    final text = logs.map((entry) => entry.message).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制 ${logs.length} 条日志（${_formatBytes(totalBytes)}）'),
      ),
    );
  }

  Future<void> _clearAgentLogs() async {
    await widget.storage.deleteAgentLogs(_agentLogId());
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已清空日志')),
    );
  }

  void _logCursorDebug(String type, Map<String, Object?> payload,
      {bool force = false}) {
    if (!_cursorDebugEnabled) {
      return;
    }
    final now = DateTime.now();
    if (!force && _lastCursorDebugLoggedAt != null) {
      final delta = now.difference(_lastCursorDebugLoggedAt!);
      if (delta < const Duration(milliseconds: 40)) {
        return;
      }
    }
    _lastCursorDebugLoggedAt = now;
    final entry = <String, Object?>{
      't': now.toIso8601String(),
      'type': type,
      ...payload,
    };
    _cursorDebugLog.add(jsonEncode(entry));
    if (_cursorDebugLog.length > 1200) {
      _cursorDebugLog.removeRange(0, _cursorDebugLog.length - 1000);
    }
  }

  void _copyCursorDebugLog() {
    if (_cursorDebugLog.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可复制的光标调试日志')),
      );
      return;
    }
    final header = jsonEncode({
      't': DateTime.now().toIso8601String(),
      'type': 'header',
      'sessionId': widget.session.id,
      'frameSize': {'w': _frameSize.width, 'h': _frameSize.height},
      'trackpadSize': {
        'w': _lastTrackpadSize.width,
        'h': _lastTrackpadSize.height,
      },
      'viewMode': _viewMode.name,
      'zoom': _zoom,
      'localCursor': _showLocalCursor,
    });
    final text = ([header, ..._cursorDebugLog]).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${_cursorDebugLog.length} 条光标日志')),
    );
  }

  void _clearCursorDebugLog() {
    _cursorDebugLog.clear();
    _lastCursorDebugPointer = null;
    _lastCursorDebugLoggedAt = null;
  }

  void _logPointerSample(String source, Offset pointer) {
    if (_lastViewSize.width <= 0 || _lastViewSize.height <= 0) {
      return;
    }
    final effective = _applyInputCalibration(pointer);
    final scale = _baseScale(_lastViewSize) * _zoom;
    final translation = _calculateTranslation(_lastViewSize);
    final screen = translation + effective * scale;
    _logCursorDebug('pointer', {
      'source': source,
      'frame': {'x': pointer.dx, 'y': pointer.dy},
      'effective': {'x': effective.dx, 'y': effective.dy},
      'screen': {'x': screen.dx, 'y': screen.dy},
      'view': {'w': _lastViewSize.width, 'h': _lastViewSize.height},
      'frameSize': {'w': _frameSize.width, 'h': _frameSize.height},
      'viewMode': _viewMode.name,
      'zoom': _zoom,
      'calibration': {
        'scaleX': _inputScaleX,
        'scaleY': _inputScaleY,
        'offsetX': _inputOffsetX,
        'offsetY': _inputOffsetY,
        'normalized': _calibrationNormalized,
      },
    });
  }

  Future<void> _fetchDisplays() async {
    final agentClient = _agentClient;
    if (agentClient == null) {
      return;
    }
    try {
      final displays = await agentClient.fetchVncDisplays();
      if (!mounted) {
        return;
      }
      final previousIndex = _selectedDisplayIndex;
      int? nextIndex = previousIndex;
      if (displays.isNotEmpty) {
        if (previousIndex == null ||
            !displays.any((display) => display.index == previousIndex)) {
          nextIndex = displays.first.index;
        }
      }
      setState(() {
        _availableDisplays = displays;
        _selectedDisplayIndex = nextIndex;
      });
    if (nextIndex != previousIndex) {
      unawaited(_persistDisplaySelection(nextIndex));
      unawaited(_loadCalibration());
      _autoSizedOnce = false;
    }
    } catch (_) {
      return;
    }
  }

  String get _resolutionLabel =>
      '${_frameSize.width.toInt()}x${_frameSize.height.toInt()}';

  double get _zoom => _zoomValue;

  double _clampZoom(double value) {
    return value.clamp(_zoomMin, _zoomMax);
  }

  Uri _buildVncWebsocketUri(VncSessionInfo info) {
    final baseUri = Uri.parse(widget.agentBaseUrl!);
    final scheme = baseUri.scheme == 'https' ? 'wss' : 'ws';
    var basePath = baseUri.path;
    if (basePath.isNotEmpty && !basePath.endsWith('/')) {
      basePath = '$basePath/';
    }
    final wsPath = info.wsPath.startsWith('/') ? info.wsPath.substring(1) : info.wsPath;
    final mergedPath = basePath.isEmpty ? '/$wsPath' : '$basePath$wsPath';
    final queryParameters = Map<String, String>.from(baseUri.queryParameters);
    queryParameters['token'] = info.token;
    final authToken = widget.authToken?.trim();
    if (authToken != null && authToken.isNotEmpty) {
      queryParameters['auth_token'] = authToken;
    }
    final clientId = widget.clientId?.trim();
    if (clientId != null && clientId.isNotEmpty) {
      queryParameters['client_id'] = clientId;
    }
    final clientName = widget.clientName?.trim();
    if (clientName != null && clientName.isNotEmpty) {
      queryParameters['client_name'] = clientName;
    }
    return baseUri.replace(
      scheme: scheme,
      path: mergedPath,
      queryParameters: queryParameters,
    );
  }

  void _handleFrame(VncFrame frame) {
    if (!mounted || _isDisposed) {
      return;
    }
    _lastFrameAt = DateTime.now();
    _noFrameTimer?.cancel();
    if (_isDecoding) {
      _pendingFrame = frame;
      return;
    }
    if (frame.width <= 0 || frame.height <= 0) {
      return;
    }
    _isDecoding = true;
    _pendingFrame = null;
    final pixels = frame.pixels;
    final expectedLength = frame.width * frame.height * 4;
    final safePixels = Uint8List(expectedLength);
    if (pixels.length >= expectedLength) {
      safePixels.setRange(0, expectedLength, pixels);
    } else {
      safePixels.setRange(0, pixels.length, pixels);
    }
    ui.decodeImageFromPixels(
      safePixels,
      frame.width,
      frame.height,
      frame.format,
      (image) {
        if (!mounted || _isDisposed) {
          image.dispose();
          _isDecoding = false;
          return;
        }
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final fps = _recordFrameFps(nowMs);
        final latencyMs = _resolveLatencyMs(frame, nowMs);
        final newSize = Size(
          frame.width.toDouble(),
          frame.height.toDouble(),
        );
        final sizeChanged = newSize != _frameSize;
        setState(() {
          _frameImage?.dispose();
          _frameImage = image;
          _streamFps = fps;
          _streamLatencyMs = latencyMs;
          _roiRenderer ??= RoiRenderer(framebufferSize: newSize);
          if (sizeChanged) {
            // Scale pointer position proportionally when frame size changes.
            // This ensures the cursor stays at the same relative position.
            final oldWidth = _frameSize.width > 0 ? _frameSize.width : newSize.width;
            final oldHeight = _frameSize.height > 0 ? _frameSize.height : newSize.height;
            final scaleX = newSize.width / oldWidth;
            final scaleY = newSize.height / oldHeight;
            _frameSize = newSize;
            _pointerPosition = Offset(
              (_pointerPosition.dx * scaleX).clamp(0, _frameSize.width),
              (_pointerPosition.dy * scaleY).clamp(0, _frameSize.height),
            );
            _cameraCenter = _applyInputCalibration(_pointerPosition);
            for (final image in _roiImages.values) {
              image.dispose();
            }
            _roiImages.clear();
            _roiTileFrameIds.clear();
            _roiRenderer = RoiRenderer(framebufferSize: newSize);
            _roiRevision += 1;
          }
        });
        if (sizeChanged) {
          _maybeInvalidateCalibrationForFrameSize();
          // Sync cursor position to desktop when frame size changes.
          // This ensures coordinates stay aligned after dynamic resizing.
          _sendPointerEvent();
          _maybeResyncRoiForFrame(newSize);
        }
        _isDecoding = false;
        final pending = _pendingFrame;
        _pendingFrame = null;
        if (pending != null) {
          _handleFrame(pending);
        }
      },
      rowBytes: frame.width * 4,
    );
  }

  void _handleCursor(VncCursor? cursor) {
    if (!mounted || _isDisposed) {
      return;
    }
    if (cursor == null || cursor.width <= 0 || cursor.height <= 0) {
      _logCursorDebug('cursor_clear', {
        'reason': 'null_or_empty',
      });
      setState(() {
        _resetCursorState();
      });
      return;
    }
    _logCursorDebug('cursor_update', {
      'w': cursor.width,
      'h': cursor.height,
      'hotX': cursor.hotX,
      'hotY': cursor.hotY,
      'len': cursor.pixels.length,
    });
    final expectedLength = cursor.width * cursor.height * 4;
    final safePixels = cursor.pixels.length >= expectedLength
        ? cursor.pixels.sublist(0, expectedLength)
        : Uint8List.fromList(cursor.pixels);
    ui.decodeImageFromPixels(
      safePixels,
      cursor.width,
      cursor.height,
      cursor.format,
      (image) {
        if (!mounted || _isDisposed) {
          image.dispose();
          return;
        }
        setState(() {
          _cursorImage?.dispose();
          _cursorImage = image;
          _cursorSize = Size(
            cursor.width.toDouble(),
            cursor.height.toDouble(),
          );
          _cursorHotspot = Offset(
            cursor.hotX.toDouble(),
            cursor.hotY.toDouble(),
          );
        });
      },
      rowBytes: cursor.width * 4,
    );
  }

  Future<void> _startStream({
    Size? requestedSize,
    bool preserveExisting = false,
    bool silentFailure = false,
  }) async {
    if (_isConnecting || _isResizing || _isDisposed) {
      return;
    }
    if (preserveExisting) {
      _isResizing = true;
    } else {
      setState(() {
        _isConnecting = true;
        _connectionError = null;
        _resetCursorState();
        _resetStreamStats();
      });
      unawaited(_stopRoiSession());
      await _updateSession(status: 'connecting');
    }

    final agentClient = _agentClient;
    if (agentClient == null) {
      if (!preserveExisting) {
        await _setStreamFailure(
          'Connect to the desktop agent to start streaming.',
        );
      }
      _isResizing = false;
      return;
    }

    VncRfbClient? candidate;
    final previousClient = _vncClient;
    final previousFrameSize = _frameSize;
    try {
      if (!preserveExisting) {
        _streamStartedAt = DateTime.now();
        _lastFrameAt = null;
      }
      final desired = requestedSize ?? _preferredStreamSize();
      unawaited(_logAgentEvent(
        'vnc_start',
        data: {
          'requested': {
            'width': desired?.width.round(),
            'height': desired?.height.round(),
          },
          'display_index': _selectedDisplayIndex,
          'preserve_existing': preserveExisting,
        },
      ));
      final sessionInfo = await agentClient.sendVncCommand(
        action: 'start',
        sessionId: widget.session.id,
        width: (desired?.width ?? _frameSize.width).round(),
        height: (desired?.height ?? _frameSize.height).round(),
        displayIndex: _selectedDisplayIndex,
        highPerfIntervalMs: _highPerfEnabled ? _highPerfIntervalMs : null,
      );
      _lastVncSessionInfo = sessionInfo;
      if (_cursorDebugEnabled) {
        _logCursorDebug('session_info', {
          'width': sessionInfo.width,
          'height': sessionInfo.height,
          'display': sessionInfo.displayIndex,
          'input': {
            'width': sessionInfo.inputWidth,
            'height': sessionInfo.inputHeight,
            'originX': sessionInfo.inputOriginX,
            'originY': sessionInfo.inputOriginY,
            'scaleX': sessionInfo.inputScaleX,
            'scaleY': sessionInfo.inputScaleY,
          },
          'screen': {
            'width': sessionInfo.screenWidth,
            'height': sessionInfo.screenHeight,
          },
        }, force: true);
      }
      final wsUri = _buildVncWebsocketUri(sessionInfo);
      final quicPort = sessionInfo.quicPort ?? 0;
      final baseUrl = widget.agentBaseUrl?.trim() ?? '';
      var quicHost = Uri.tryParse(baseUrl)?.host ?? '';
      if (quicHost.isEmpty && baseUrl.isNotEmpty) {
        quicHost = Uri.parse('http://$baseUrl').host;
      }
      final preferQuic = !kIsWeb && quicPort > 0 && quicHost.isNotEmpty;
      final authToken = widget.authToken?.trim();
      final clientId = widget.clientId?.trim();
      final clientName = widget.clientName?.trim();
      VncTransport transport = preferQuic
          ? VncQuicTransport(
              host: quicHost,
              port: quicPort,
              sessionId: sessionInfo.sessionId,
              token: sessionInfo.token,
              authToken: authToken != null && authToken.isNotEmpty ? authToken : null,
              clientId: clientId != null && clientId.isNotEmpty ? clientId : null,
              clientName: clientName != null && clientName.isNotEmpty ? clientName : null,
            )
          : WebSocketVncTransport(uri: wsUri);
      candidate = VncRfbClient(
        transport: transport,
        onFrame: _handleFrame,
        onCursor: _handleCursor,
        onError: (message) {
          if (!mounted || _isDisposed) {
            return;
          }
          if (_vncClient != candidate) {
            return;
          }
          unawaited(_setStreamFailure(message));
        },
        preferredEncodings: _buildEncodingList(),
      );
      try {
        await candidate.connect();
      } catch (error) {
        if (preferQuic) {
          candidate.close();
          transport = WebSocketVncTransport(uri: wsUri);
          candidate = VncRfbClient(
            transport: transport,
            onFrame: _handleFrame,
            onCursor: _handleCursor,
            onError: (message) {
              if (!mounted || _isDisposed) {
                return;
              }
              if (_vncClient != candidate) {
                return;
              }
              unawaited(_setStreamFailure(message));
            },
            preferredEncodings: _buildEncodingList(),
          );
          await candidate.connect();
        } else {
          rethrow;
        }
      }
      if (!mounted || _isDisposed) {
        return;
      }
      unawaited(_startRoiSession(sessionInfo));
      final shouldResetCalibration = !preserveExisting &&
          sessionInfo.inputWidth != null &&
          sessionInfo.inputHeight != null;
      final nextFrameSize = Size(
        sessionInfo.width.toDouble(),
        sessionInfo.height.toDouble(),
      );
      final shouldPreservePointer = preserveExisting &&
          previousFrameSize.width > 0 &&
          previousFrameSize.height > 0;
      final nextPointer = shouldPreservePointer
          ? Offset(
              (_pointerPosition.dx * nextFrameSize.width / previousFrameSize.width)
                  .clamp(0, nextFrameSize.width),
              (_pointerPosition.dy * nextFrameSize.height / previousFrameSize.height)
                  .clamp(0, nextFrameSize.height),
            )
          : Offset(
              nextFrameSize.width / 2,
              nextFrameSize.height / 2,
            );
      setState(() {
        if (!preserveExisting) {
          _isConnecting = false;
        }
        _connectionError = null;
        if (!preserveExisting) {
          _resetCursorState();
        }
        _frameSize = nextFrameSize;
        _pointerPosition = nextPointer;
        _cameraCenter = _applyInputCalibration(nextPointer);
        _hasStreamInfo = true;
        if (sessionInfo.displayIndex != null) {
          _selectedDisplayIndex = sessionInfo.displayIndex;
        }
      });
      if (shouldResetCalibration) {
        _applyCalibrationDefaults(sendPointer: false);
        unawaited(widget.storage.deleteKeyValue(_calibrationStorageKey()));
      }
      _maybeInvalidateCalibrationForFrameSize();
      _vncClient = candidate;
      _applyEncodingPreferences();
      _applyPixelFormatPreference();
      // Sync the cursor position to the desktop after session creation.
      // This ensures mobile and desktop cursors are aligned after zoom changes.
      _sendPointerEvent();
      previousClient?.close();
      if (sessionInfo.displayIndex != null) {
        unawaited(_persistDisplaySelection(sessionInfo.displayIndex));
      }
      await _updateSession(status: 'connected');
      unawaited(_logAgentEvent(
        'vnc_connected',
        data: {
          'width': sessionInfo.width,
          'height': sessionInfo.height,
          'display_index': sessionInfo.displayIndex,
        },
      ));
      _vncClient?.requestFullFrame();
      _maybeAutoResizeStream();
      if (!preserveExisting) {
        _armNoFrameTimeout();
      }
    } on AgentCommandFailure catch (error) {
      final presentation = _presentAgentFailure(
        error,
        fallbackMessage: 'VNC session failed to connect.',
      );
      _logErrorDetails('vnc_session', presentation);
      final message = _formatErrorMessage(presentation);
      if (!preserveExisting) {
        await _setStreamFailure(message);
      } else if (!silentFailure && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } catch (error) {
      final presentation = _presentUnexpectedFailure(
        error,
        fallbackMessage: 'VNC stream failed.',
      );
      _logErrorDetails('vnc_session', presentation);
      final message = _formatErrorMessage(presentation);
      if (!preserveExisting) {
        await _setStreamFailure(message);
      } else if (!silentFailure && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
          ),
        );
      }
    } finally {
      if (preserveExisting) {
        _isResizing = false;
      }
    }
  }

  Future<void> _setStreamFailure(String message) async {
    if (!mounted || _isDisposed) {
      return;
    }
    setState(() {
      _isConnecting = false;
      _connectionError = message;
      _hasStreamInfo = false;
      _resetCursorState();
    });
    unawaited(_logAgentEvent(
      'vnc_error',
      level: 'error',
      data: {
        'message': message,
      },
    ));
    _noFrameTimer?.cancel();
    _vncClient?.close();
    unawaited(_stopRoiSession());
    await _updateSession(status: 'failed', errorMessage: message);
  }

  void _armNoFrameTimeout() {
    _noFrameTimer?.cancel();
    _noFrameTimer = Timer(_noFrameTimeout, () {
      if (!mounted || _isDisposed) {
        return;
      }
      if (_connectionError != null || _isConnecting) {
        return;
      }
      final startedAt = _streamStartedAt;
      final lastFrameAt = _lastFrameAt;
      if (startedAt == null) {
        return;
      }
      if (lastFrameAt != null && lastFrameAt.isAfter(startedAt)) {
        return;
      }
      unawaited(_setStreamFailure(
        'No frames received from the desktop agent. Check Screen Recording permission and ensure the agent is running.',
      ));
    });
  }

  Future<void> _updateSession({
    required String status,
    String? errorMessage,
  }) async {
    if (!mounted || _isDisposed) {
      return;
    }
    setState(() {
      _lastUpdatedAt = DateTime.now();
    });
    final updatedSession = ToolSession(
      id: widget.session.id,
      type: widget.session.type,
      label: widget.session.label,
      status: status,
      createdAt: widget.session.createdAt,
    );
    final payload = Map<String, dynamic>.from(widget.event.payload);
    payload['status'] = status;
    payload['resolution'] = _resolutionLabel;
    payload['zoom'] = _zoom;
    payload['updated_at'] = DateTime.now().toIso8601String();
    if (errorMessage != null) {
      payload['error'] = errorMessage;
    } else {
      payload.remove('error');
    }

    final updatedEvent = TimelineEvent(
      id: widget.event.id,
      sessionId: widget.event.sessionId,
      type: widget.event.type,
      title: widget.event.title,
      payload: payload,
      createdAt: widget.event.createdAt,
    );
    try {
      await widget.storage.insertToolSession(updatedSession);
      await widget.storage.insertTimelineEvent(updatedEvent);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to save VNC state: ${error.toString()}',
          ),
        ),
      );
    }
  }

  void _updateZoomValue(double value, {bool commit = false}) {
    var clamped = _clampZoom(value);
    if ((clamped - _zoomDefault).abs() <= 0.05) {
      clamped = _zoomDefault;
    }
    if (clamped == _zoomValue) {
      return;
    }
    final focus = _effectivePointerPosition();
    setState(() {
      _zoomValue = clamped;
      _cameraCenter = focus;
    });
    _scheduleRoiRequest();
    if (_cursorDebugEnabled) {
      _logCursorDebug('zoom_change', {'zoom': _zoom}, force: true);
    }
    _triggerFocusPulse();
    if (commit) {
      unawaited(_updateSession(status: _currentStatusLabel));
    }
  }

  void _commitZoomValue(double value) {
    final before = _zoomValue;
    _updateZoomValue(value, commit: true);
    if (before != _zoomValue) {
      _requestStreamRefresh(resetAutoResize: true);
      if (_isFullscreen) {
        _schedulePointerReset();
      }
      _applyRoiZoomPolicy();
    }
  }

  void _resetZoom() {
    _commitZoomValue(_zoomDefault);
  }

  String get _currentStatusLabel {
    if (_connectionError != null) {
      return 'failed';
    }
    if (_isConnecting) {
      return 'connecting';
    }
    return 'connected';
  }

  void _triggerClickPulse() {
    _clickTimer?.cancel();
    setState(() {
      _showClickPulse = true;
    });
    _clickTimer = Timer(const Duration(milliseconds: 220), () {
      if (mounted) {
        setState(() {
          _showClickPulse = false;
        });
      }
    });
  }

  void _triggerFocusPulse() {
    _focusTimer?.cancel();
    setState(() {
      _showFocusPulse = true;
    });
    _focusTimer = Timer(const Duration(milliseconds: 220), () {
      if (mounted) {
        setState(() {
          _showFocusPulse = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final safePadding = MediaQuery.of(context).padding;
    final screenSize = MediaQuery.of(context).size;
    final target = widget.event.payload['target']?.toString();
    final targetLabel =
        target == null || target.trim().isEmpty ? 'Remote desktop' : target;
    final statusText = _connectionError != null
        ? 'Stream offline'
        : _isConnecting
            ? 'Connecting'
            : 'Streaming';
    final statusColor = _connectionError != null
        ? const Color(0xFFFEE2E2)
        : _isConnecting
            ? const Color(0xFFFEF3C7)
            : const Color(0xFFDCFCE7);
    final statusTextColor = _connectionError != null
        ? const Color(0xFF991B1B)
        : _isConnecting
            ? const Color(0xFF92400E)
            : const Color(0xFF166534);
    final isInteractive =
        _connectionError == null && !_isConnecting && _vncClient != null;
    final displayLabel = _selectedDisplayIndex == null
        ? null
        : _availableDisplays
            .firstWhere(
              (display) => display.index == _selectedDisplayIndex,
              orElse: () => VncDisplayInfo(
                index: _selectedDisplayIndex ?? 0,
                width: _frameSize.width.toInt(),
                height: _frameSize.height.toInt(),
                isPrimary: false,
              ),
            )
            .label;

    if (_isFullscreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: isLandscape
              ? _buildFullscreenLandscape(
                  theme: theme,
                  isInteractive: isInteractive,
                  safePadding: safePadding,
                  screenSize: screenSize,
                )
              : _buildFullscreenPortrait(
                  theme: theme,
                  isInteractive: isInteractive,
                  safePadding: safePadding,
                  screenSize: screenSize,
                ),
        ),
      );
    }

    return _TimelineDetailScaffold(
      title: 'VNC Viewer',
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: GestureDetector(
                onVerticalDragUpdate: _handleSwipeUpdate,
                onVerticalDragEnd: _handleSwipeEnd,
                child: Column(
                  children: [
                    Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE2E8F0),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Swipe down to exit',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF94A3B8),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              widget.session.label,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Requested ${_formatTimestamp(widget.event.createdAt)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF64748B),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          statusText,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: statusTextColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _resolutionLabel,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF64748B),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _KeyValueRow(label: 'Target', value: targetLabel),
                  if (displayLabel != null)
                    _KeyValueRow(label: 'Display', value: displayLabel),
                  _KeyValueRow(
                    label: 'Last update',
                    value: _formatTimestamp(_lastUpdatedAt),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_connectionError != null) ...[
              _VncRecoveryCard(
                message: _connectionError!,
                onRetry: _startStream,
              ),
              const SizedBox(height: 16),
            ] else if (_isConnecting) ...[
              _InlineStatus(
                message: 'Connecting to the VNC stream...',
              ),
              const SizedBox(height: 16),
            ],
            _ContextSectionCard(
              title: 'VNC view',
              subtitle: isLandscape
                  ? 'Landscape stream with hidden controls. Tap the floating button to open trackpad and zoom.'
                  : 'Portrait stream with vertical zoom and a full-width trackpad.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildVncCanvas(
                    theme: theme,
                    isInteractive: isInteractive,
                    isLandscape: isLandscape,
                    safePadding: safePadding,
                    screenSize: screenSize,
                    isFullscreen: false,
                  ),
                  if (!isLandscape) ...[
                    const SizedBox(height: 12),
                    _buildTrackpadControls(isInteractive: isInteractive),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
