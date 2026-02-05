part of '../main.dart';

extension _VncSessionRoi on _VncSessionScreenState {
  void _configureRoiClient() {
    _roiDisabledReason = null;
    _roiHost = null;
    if (kIsWeb) {
      _roiClient = RoiNoopClient();
      _roiDisabledReason = 'web';
      return;
    }
    final baseUrl = widget.agentBaseUrl?.trim();
    if (baseUrl == null || baseUrl.isEmpty) {
      _roiClient = RoiNoopClient();
      _roiDisabledReason = 'no-agent';
      return;
    }
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || uri.host.isEmpty) {
      _roiClient = RoiNoopClient();
      _roiDisabledReason = 'invalid-url';
      return;
    }
    _roiHost = uri.host;
    _roiClient = RoiQuicClient(host: uri.host);
  }

  void _applyRoiZoomPolicy() {
    if (_roiClient is RoiNoopClient) {
      return;
    }
    final sessionInfo = _lastVncSessionInfo;
    if (sessionInfo == null) {
      return;
    }
    if (_zoom > _roiZoomThreshold) {
      if (_roiSession == null && !_roiConnecting) {
        unawaited(_startRoiSession(sessionInfo));
      }
    } else {
      if (_roiSession != null || _roiConnecting) {
        unawaited(_stopRoiSession());
      }
    }
  }

  Size _roiLogicalSize() {
    final session = _roiSession;
    if (session == null) {
      return _frameSize;
    }
    final width = session.screenWidth > 0 ? session.screenWidth.toDouble() : _frameSize.width;
    final height = session.screenHeight > 0 ? session.screenHeight.toDouble() : _frameSize.height;
    if (width <= 0 || height <= 0) {
      return _frameSize;
    }
    return Size(width, height);
  }

  void _resetCursorState() {
    _cursorImage?.dispose();
    _cursorImage = null;
    _cursorSize = Size.zero;
    _cursorHotspot = Offset.zero;
  }

  void _resetStreamStats() {
    _frameTimestamps.clear();
    _streamFps = 0;
    _streamLatencyMs = null;
    _lastInputAt = null;
  }

  void _resetRoiState() {
    _roiRequestTimer?.cancel();
    _roiRequestTimer = null;
    _roiReconnectTimer?.cancel();
    _roiReconnectTimer = null;
    _roiResyncTimer?.cancel();
    _roiResyncTimer = null;
    _roiBatchTimer?.cancel();
    _roiBatchTimer = null;
    _roiPendingResyncSize = null;
    _roiSession = null;
    _roiLastTileAt = null;
    _roiConnected = false;
    _roiConnectedAt = null;
    _roiLastRequestAt = null;
    _roiTileCount = 0;
    _roiTileBytes = 0;
    _roiLastError = null;
    _roiConnecting = false;
    _roiReconnectAttempts = 0;
    _roiSubscription?.cancel();
    _roiSubscription = null;
    for (final image in _roiPendingImages.values) {
      image.dispose();
    }
    _roiPendingImages.clear();
    _roiPendingSizes.clear();
    _roiPendingCount = 0;
    _roiPendingBytes = 0;
    for (final image in _roiImages.values) {
      image.dispose();
    }
    _roiImages.clear();
    _roiTileFrameIds.clear();
    _roiRenderer = null;
    _roiRevision = 0;
  }

  Future<void> _startRoiSession(VncSessionInfo sessionInfo) async {
    final agentClient = _agentClient;
    if (agentClient == null || _roiClient is RoiNoopClient) {
      return;
    }
    if (_roiConnecting) {
      return;
    }
    final screenWidth = sessionInfo.screenWidth ?? sessionInfo.width;
    final screenHeight = sessionInfo.screenHeight ?? sessionInfo.height;
    if (screenWidth <= 0 || screenHeight <= 0) {
      return;
    }
    _roiConnecting = true;
    _roiConnected = false;
    _roiLastError = null;
    if (mounted && !_isDisposed) {
      _updateState(() {});
    }
    try {
      final roiInfo = await agentClient.sendRoiCommand(
        action: 'start',
        sessionId: '${sessionInfo.sessionId}-roi',
        vncSessionId: sessionInfo.sessionId,
        framebufferWidth: sessionInfo.width,
        framebufferHeight: sessionInfo.height,
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        displayIndex: sessionInfo.displayIndex,
      );
      if (!mounted || _isDisposed) {
        return;
      }
      _roiSession = roiInfo;
      final logicalWidth =
          roiInfo.screenWidth > 0 ? roiInfo.screenWidth : roiInfo.framebufferWidth;
      final logicalHeight =
          roiInfo.screenHeight > 0 ? roiInfo.screenHeight : roiInfo.framebufferHeight;
      final logicalSize = Size(
        logicalWidth.toDouble(),
        logicalHeight.toDouble(),
      );
      _roiRenderer = RoiRenderer(
        framebufferSize: logicalSize,
        logicalSize: logicalSize,
      );
      _roiRevision += 1;
      await _roiClient.connect(roiInfo);
      _roiSubscription?.cancel();
      _roiSubscription = _roiClient.tiles.listen(_handleRoiTile);
      _scheduleRoiRequest();
      _roiReconnectAttempts = 0;
      _roiConnecting = false;
      _roiConnected = true;
      _roiConnectedAt = DateTime.now();
      if (mounted && !_isDisposed) {
        _updateState(() {});
      }
      unawaited(_logAgentEvent(
        'roi_connected',
        data: {
          'port': roiInfo.quicPort,
          'framebuffer': {
            'width': roiInfo.framebufferWidth,
            'height': roiInfo.framebufferHeight,
          },
        },
      ));
      _sendRoiRequest();
    } on AgentCommandFailure catch (error) {
      final presentation = _presentAgentFailure(
        error,
        fallbackMessage: 'ROI stream unavailable.',
      );
      _logErrorDetails('roi_session', presentation);
      unawaited(_logAgentEvent(
        'roi_error',
        level: 'error',
        data: {
          'message': _formatErrorMessage(presentation),
        },
      ));
      _roiConnecting = false;
      _roiConnected = false;
      _roiLastError = _formatErrorMessage(presentation);
      if (mounted && !_isDisposed) {
        _updateState(() {});
      }
      _scheduleRoiReconnect(sessionInfo);
    } catch (error) {
      final presentation = _presentUnexpectedFailure(
        error,
        fallbackMessage: 'ROI stream unavailable.',
      );
      _logErrorDetails('roi_session', presentation);
      unawaited(_logAgentEvent(
        'roi_error',
        level: 'error',
        data: {
          'message': _formatErrorMessage(presentation),
        },
      ));
      _roiConnecting = false;
      _roiConnected = false;
      _roiLastError = _formatErrorMessage(presentation);
      if (mounted && !_isDisposed) {
        _updateState(() {});
      }
      _scheduleRoiReconnect(sessionInfo);
    }
  }

  Future<void> _stopRoiSession() async {
    if (_roiClient is RoiNoopClient) {
      _resetRoiState();
      return;
    }
    try {
      await _roiClient.disconnect();
    } catch (_) {}
    _resetRoiState();
  }

  void _scheduleRoiReconnect(VncSessionInfo sessionInfo) {
    if (_roiClient is RoiNoopClient) {
      return;
    }
    if (_roiReconnectTimer != null) {
      return;
    }
    if (_vncClient == null || _connectionError != null) {
      return;
    }
    _roiReconnectAttempts = (_roiReconnectAttempts + 1).clamp(0, 5);
    unawaited(_logAgentEvent(
      'roi_reconnect_scheduled',
      data: {
        'attempt': _roiReconnectAttempts,
      },
    ));
    final delay = Duration(milliseconds: 1200 + _roiReconnectAttempts * 800);
    _roiReconnectTimer = Timer(delay, () {
      _roiReconnectTimer = null;
      if (!mounted || _isDisposed) {
        return;
      }
      if (_vncClient == null || _connectionError != null) {
        return;
      }
      _applyRoiZoomPolicy();
    });
  }

  void _scheduleRoiRequest() {
    if (_roiSession == null) {
      return;
    }
    if (_roiRequestTimer != null) {
      return;
    }
    _roiRequestTimer = Timer(const Duration(milliseconds: 60), () {
      _roiRequestTimer = null;
      _sendRoiRequest();
    });
  }

  void _sendRoiRequest() {
    final roiSession = _roiSession;
    if (roiSession == null) {
      return;
    }
    final now = DateTime.now();
    _roiLastRequestAt = now;
    var viewSize = _lastViewSize;
    if (viewSize.width <= 0 || viewSize.height <= 0) {
      final fallback = _frameSize;
      if (fallback.width <= 0 || fallback.height <= 0) {
        return;
      }
      viewSize = fallback;
    }
    final center = _effectivePointerPosition();
    final roiLogicalSize = _roiLogicalSize();
    if (_frameSize.width <= 0 || _frameSize.height <= 0) {
      return;
    }
    final scaleX = roiLogicalSize.width / _frameSize.width;
    final scaleY = roiLogicalSize.height / _frameSize.height;
    if (!scaleX.isFinite ||
        !scaleY.isFinite ||
        scaleX <= 0 ||
        scaleY <= 0) {
      return;
    }
    final scale = _baseScale(viewSize, contentSize: _displaySize()) * _zoom;
    if (scale <= 0) {
      return;
    }
    final centerLogical = Offset(
      (center.dx * scaleX).clamp(0, roiLogicalSize.width),
      (center.dy * scaleY).clamp(0, roiLogicalSize.height),
    );
    final viewportWidth = (viewSize.width / scale) * scaleX;
    final viewportHeight = (viewSize.height / scale) * scaleY;
    final prefetchRadius = (viewportWidth < viewportHeight
            ? viewportWidth
            : viewportHeight) *
        0.6;
    unawaited(_roiClient.requestRoi(
      centerX: centerLogical.dx,
      centerY: centerLogical.dy,
      zoom: _zoom,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      prefetchRadius: prefetchRadius,
    ));
    final lastTileAt = _roiLastTileAt;
    if (lastTileAt == null) {
      final connectedAt = _roiConnectedAt;
      if (connectedAt != null &&
          now.difference(connectedAt) > const Duration(seconds: 4)) {
        final info = _lastVncSessionInfo;
        if (info != null && !_roiConnecting) {
          _scheduleRoiReconnect(info);
        }
      }
      return;
    }
    if (now.difference(lastTileAt) > const Duration(seconds: 4)) {
      final info = _lastVncSessionInfo;
      if (info != null && !_roiConnecting) {
        _scheduleRoiReconnect(info);
      }
    }
  }

  void _scheduleRoiBatchFlush() {
    if (_roiBatchTimer != null) {
      return;
    }
    _roiBatchTimer = Timer(const Duration(milliseconds: 16), _flushRoiBatch);
  }

  void _flushRoiBatch() {
    _roiBatchTimer = null;
    if (_roiPendingImages.isEmpty) {
      return;
    }
    if (!mounted || _isDisposed) {
      for (final image in _roiPendingImages.values) {
        image.dispose();
      }
      _roiPendingImages.clear();
      _roiPendingSizes.clear();
      _roiPendingCount = 0;
      _roiPendingBytes = 0;
      return;
    }
    final pendingImages = Map<RoiTileKey, ui.Image>.from(_roiPendingImages);
    final pendingCount = _roiPendingCount;
    final pendingBytes = _roiPendingBytes;
    _roiPendingImages.clear();
    _roiPendingSizes.clear();
    _roiPendingCount = 0;
    _roiPendingBytes = 0;
    _updateState(() {
      _roiTileCount += pendingCount;
      _roiTileBytes += pendingBytes;
      if (_roiTileCount > 1000000) {
        _roiTileCount = 0;
        _roiTileBytes = 0;
      }
      for (final entry in pendingImages.entries) {
        _roiImages.remove(entry.key)?.dispose();
        _roiImages[entry.key] = entry.value;
      }
      _roiRevision += 1;
      _trimRoiCache();
    });
  }

  int _roiCacheLimit() {
    if (_zoom >= 2.0) {
      return 640;
    }
    if (_zoom >= 1.5) {
      return 480;
    }
    if (_zoom >= 1.2) {
      return 320;
    }
    return 256;
  }

  void _trimRoiCache() {
    final limit = _roiCacheLimit();
    if (_roiImages.length <= limit) {
      return;
    }
    final overflow = _roiImages.length - limit;
    for (var i = 0; i < overflow; i += 1) {
      if (_roiImages.isEmpty) {
        break;
      }
      final firstKey = _roiImages.keys.first;
      _roiImages.remove(firstKey)?.dispose();
    }
  }

  void _handleRoiTile(RoiTilePayload payload) {
    if (!mounted || _isDisposed) {
      return;
    }
    if (_roiSession == null || _zoom <= _roiZoomThreshold) {
      return;
    }
    final receivedAt = DateTime.now();
    _roiLastTileAt = receivedAt;
    final reconnectTimer = _roiReconnectTimer;
    if (reconnectTimer != null) {
      reconnectTimer.cancel();
      _roiReconnectTimer = null;
      _roiReconnectAttempts = 0;
    }
    if (payload.pixelWidth <= 0 || payload.pixelHeight <= 0) {
      return;
    }
    final expected = payload.pixelWidth * payload.pixelHeight * 4;
    if (payload.pixels.length < expected) {
      return;
    }
    final lastFrameId = _roiTileFrameIds[payload.key];
    if (lastFrameId != null && payload.frameId <= lastFrameId) {
      return;
    }
    final pixels = payload.pixels.length == expected
        ? payload.pixels
        : Uint8List.sublistView(payload.pixels, 0, expected);
    ui.decodeImageFromPixels(
      pixels,
      payload.pixelWidth,
      payload.pixelHeight,
      ui.PixelFormat.bgra8888,
      (image) {
        if (!mounted || _isDisposed) {
          image.dispose();
          return;
        }
        if (_roiSession == null || _zoom <= _roiZoomThreshold) {
          image.dispose();
          return;
        }
        final key = payload.key;
        final currentFrameId = _roiTileFrameIds[key];
        if (currentFrameId != null && payload.frameId <= currentFrameId) {
          image.dispose();
          return;
        }
        _roiTileFrameIds[key] = payload.frameId;
        final existing = _roiPendingImages.remove(key);
        if (existing != null) {
          existing.dispose();
          final prevSize = _roiPendingSizes.remove(key) ?? 0;
          _roiPendingBytes -= prevSize;
          if (_roiPendingBytes < 0) {
            _roiPendingBytes = 0;
          }
          _roiPendingCount -= 1;
          if (_roiPendingCount < 0) {
            _roiPendingCount = 0;
          }
        }
        _roiPendingImages[key] = image;
        _roiPendingSizes[key] = payload.pixels.length;
        _roiPendingCount += 1;
        _roiPendingBytes += payload.pixels.length;
        _scheduleRoiBatchFlush();
      },
      rowBytes: payload.pixelWidth * 4,
    );
  }

  void _maybeResyncRoiForFrame(Size newSize) {
    final roiSession = _roiSession;
    if (roiSession == null || _roiConnecting) {
      return;
    }
    final nextWidth = newSize.width.round();
    final nextHeight = newSize.height.round();
    if (roiSession.framebufferWidth == nextWidth &&
        roiSession.framebufferHeight == nextHeight) {
      _roiPendingResyncSize = null;
      return;
    }
    _roiPendingResyncSize = Size(
      nextWidth.toDouble(),
      nextHeight.toDouble(),
    );
    if (_roiResyncTimer != null) {
      return;
    }
    _roiResyncTimer = Timer(const Duration(milliseconds: 320), () {
      _roiResyncTimer = null;
      if (!mounted || _isDisposed) {
        return;
      }
      final sessionInfo = _lastVncSessionInfo;
      final pendingSize = _roiPendingResyncSize;
      _roiPendingResyncSize = null;
      if (sessionInfo == null || pendingSize == null) {
        return;
      }
      final pendingWidth = pendingSize.width.round();
      final pendingHeight = pendingSize.height.round();
      final activeSession = _roiSession;
      if (activeSession == null ||
          activeSession.framebufferWidth == pendingWidth &&
              activeSession.framebufferHeight == pendingHeight) {
        return;
      }
      unawaited(_resyncRoiSession(sessionInfo, pendingWidth, pendingHeight));
    });
  }

  Future<void> _resyncRoiSession(
    VncSessionInfo sessionInfo,
    int framebufferWidth,
    int framebufferHeight,
  ) async {
    if (_roiConnecting || _roiClient is RoiNoopClient) {
      return;
    }
    final updated = VncSessionInfo(
      sessionId: sessionInfo.sessionId,
      token: sessionInfo.token,
      wsPath: sessionInfo.wsPath,
      width: framebufferWidth,
      height: framebufferHeight,
      displayIndex: sessionInfo.displayIndex,
      inputWidth: sessionInfo.inputWidth,
      inputHeight: sessionInfo.inputHeight,
      inputOriginX: sessionInfo.inputOriginX,
      inputOriginY: sessionInfo.inputOriginY,
      inputScaleX: sessionInfo.inputScaleX,
      inputScaleY: sessionInfo.inputScaleY,
      screenWidth: sessionInfo.screenWidth,
      screenHeight: sessionInfo.screenHeight,
    );
    await _stopRoiSession();
    await _startRoiSession(updated);
  }

  void _markInputActivity() {
    _lastInputAt = DateTime.now();
  }

  String _formatSince(DateTime? value) {
    if (value == null) {
      return 'never';
    }
    final delta = DateTime.now().difference(value);
    if (delta.inMilliseconds < 1000) {
      return '${delta.inMilliseconds}ms';
    }
    if (delta.inSeconds < 60) {
      return '${delta.inSeconds}s';
    }
    if (delta.inMinutes < 60) {
      return '${delta.inMinutes}m';
    }
    return '${delta.inHours}h';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '${bytes}B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)}KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }

  String _roiStatusLabel() {
    if (_roiClient is RoiNoopClient) {
      switch (_roiDisabledReason) {
        case 'web':
          return '禁用(Web)';
        case 'no-agent':
          return '禁用(无Agent)';
        case 'invalid-url':
          return '禁用(URL异常)';
      }
      return '禁用';
    }
    if (_roiConnecting) {
      return '连接中';
    }
    if (_roiConnected) {
      return '已连接';
    }
    return '待机';
  }

}
