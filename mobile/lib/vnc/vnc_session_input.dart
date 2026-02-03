part of '../main.dart';

extension _VncSessionInput on _VncSessionScreenState {
  Offset _applyTrackpadAcceleration(Offset delta, {double scale = 1}) {
    final safeScale = scale <= 0 ? 1 : scale;
    final distance = delta.distance / safeScale;
    if (distance == 0) {
      return delta;
    }
    final boost = (distance / 22).clamp(0.0, 2.5);
    final factor = 1 + boost;
    return delta * factor;
  }

  void _updateTrackpadSize(Size size, {required String source}) {
    if (size.width <= 0 || size.height <= 0) {
      return;
    }
    if (_lastTrackpadSize == size) {
      return;
    }
    _lastTrackpadSize = size;
    if (_cursorDebugEnabled) {
      _logCursorDebug('trackpad_size', {
        'source': source,
        'w': size.width,
        'h': size.height,
      }, force: true);
    }
  }

  double _trackpadBaseScale(Size trackpadSize) {
    if (_frameSize.width <= 0 || _frameSize.height <= 0) {
      return 1;
    }
    final scaleX = trackpadSize.width / _frameSize.width;
    final scaleY = trackpadSize.height / _frameSize.height;
    if (!scaleX.isFinite || !scaleY.isFinite) {
      return 1;
    }
    return (scaleX + scaleY) / 2;
  }

  void _movePointerBy(Offset delta) {
    final rawTrackpadSize = _lastTrackpadSize;
    final viewSize = _lastViewSize;
    final hasViewSize = viewSize.width > 0 && viewSize.height > 0;
    final trackpadSize = (rawTrackpadSize.width > 0 &&
            rawTrackpadSize.height > 0)
        ? rawTrackpadSize
        : (hasViewSize ? viewSize : rawTrackpadSize);
    final hasTrackpadSize = trackpadSize.width > 0 && trackpadSize.height > 0;
    if (!hasTrackpadSize && !hasViewSize) {
      final accelerated = _applyTrackpadAcceleration(delta);
      _setPointerPosition(_pointerPosition + accelerated / _zoom);
      return;
    }
    final surfaceSize = hasViewSize ? viewSize : trackpadSize;
    if (surfaceSize.width <= 0 || surfaceSize.height <= 0) {
      return;
    }
    final viewScale = hasViewSize
        ? _baseScale(viewSize)
        : (hasTrackpadSize ? _trackpadBaseScale(trackpadSize) : 1.0);
    if (!viewScale.isFinite || viewScale <= 0) {
      return;
    }
    final normalizedDelta = (hasViewSize && hasTrackpadSize)
        ? Offset(
            delta.dx * (viewSize.width / trackpadSize.width),
            delta.dy * (viewSize.height / trackpadSize.height),
          )
        : delta;
    final scaledBase = viewScale * _zoom;
    final accelerated =
        _applyTrackpadAcceleration(normalizedDelta, scale: scaledBase);
    final scaled = accelerated / scaledBase;
    _setPointerPosition(_pointerPosition + scaled);
  }

  void _setPointerPosition(Offset position) {
    final clamped = Offset(
      position.dx.clamp(0, _frameSize.width),
      position.dy.clamp(0, _frameSize.height),
    );
    final adjusted = _applyInputCalibration(clamped);
    _updateState(() {
      _pointerPosition = clamped;
      _cameraCenter = adjusted;
    });
    if (_cursorDebugEnabled) {
      final last = _lastCursorDebugPointer;
      if (last == null || (clamped - last).distance >= 1) {
        _lastCursorDebugPointer = clamped;
        _logPointerSample('set_pointer', clamped);
      }
    }
    _sendPointerEvent();
    _scheduleRoiRequest();
  }

  Offset _applyInputCalibration(Offset position) {
    if (!_calibrationNormalized) {
      final scaled = Offset(
        position.dx * _inputScaleX + _inputOffsetX,
        position.dy * _inputScaleY + _inputOffsetY,
      );
      return Offset(
        scaled.dx.clamp(0, _frameSize.width),
        scaled.dy.clamp(0, _frameSize.height),
      );
    }
    final width = _frameSize.width;
    final height = _frameSize.height;
    if (width <= 0 || height <= 0) {
      return position;
    }
    final normalized = Offset(position.dx / width, position.dy / height);
    final adjusted = Offset(
      normalized.dx * _inputScaleX + _inputOffsetX,
      normalized.dy * _inputScaleY + _inputOffsetY,
    );
    final scaled = Offset(adjusted.dx * width, adjusted.dy * height);
    return Offset(
      scaled.dx.clamp(0, width),
      scaled.dy.clamp(0, height),
    );
  }

  Offset _removeInputCalibration(Offset position) {
    if (!_calibrationNormalized) {
      final scaleX = _inputScaleX == 0 ? 1 : _inputScaleX;
      final scaleY = _inputScaleY == 0 ? 1 : _inputScaleY;
      final raw = Offset(
        (position.dx - _inputOffsetX) / scaleX,
        (position.dy - _inputOffsetY) / scaleY,
      );
      return Offset(
        raw.dx.clamp(0, _frameSize.width),
        raw.dy.clamp(0, _frameSize.height),
      );
    }
    final width = _frameSize.width;
    final height = _frameSize.height;
    if (width <= 0 || height <= 0) {
      return position;
    }
    final scaleX = _inputScaleX == 0 ? 1 : _inputScaleX;
    final scaleY = _inputScaleY == 0 ? 1 : _inputScaleY;
    final normalized = Offset(position.dx / width, position.dy / height);
    final rawNormalized = Offset(
      (normalized.dx - _inputOffsetX) / scaleX,
      (normalized.dy - _inputOffsetY) / scaleY,
    );
    final raw = Offset(rawNormalized.dx * width, rawNormalized.dy * height);
    return Offset(
      raw.dx.clamp(0, width),
      raw.dy.clamp(0, height),
    );
  }

  Offset _effectivePointerPosition() {
    return _applyInputCalibration(_pointerPosition);
  }

  double _baseScale(Size viewSize) {
    if (_frameSize.width == 0 || _frameSize.height == 0) {
      return 1;
    }
    final scaleX = viewSize.width / _frameSize.width;
    final scaleY = viewSize.height / _frameSize.height;
    switch (_viewMode) {
      case VncViewMode.fit:
        return scaleX < scaleY ? scaleX : scaleY;
      case VncViewMode.fill:
        return scaleX > scaleY ? scaleX : scaleY;
      case VncViewMode.original:
        return 1;
    }
  }

  Offset _clampedCameraCenter(Size viewSize) {
    if (_frameSize.width == 0 || _frameSize.height == 0) {
      return _cameraCenter;
    }
    final scale = _baseScale(viewSize) * _zoom;
    if (scale <= 0) {
      return _cameraCenter;
    }
    final visibleWidth = viewSize.width / scale;
    final visibleHeight = viewSize.height / scale;
    final minX = visibleWidth >= _frameSize.width
        ? _frameSize.width / 2
        : visibleWidth / 2;
    final maxX = visibleWidth >= _frameSize.width
        ? _frameSize.width / 2
        : _frameSize.width - visibleWidth / 2;
    final minY = visibleHeight >= _frameSize.height
        ? _frameSize.height / 2
        : visibleHeight / 2;
    final maxY = visibleHeight >= _frameSize.height
        ? _frameSize.height / 2
        : _frameSize.height - visibleHeight / 2;
    return Offset(
      _cameraCenter.dx.clamp(minX, maxX),
      _cameraCenter.dy.clamp(minY, maxY),
    );
  }

  Offset _calculateTranslation(Size viewSize) {
    final center = Offset(viewSize.width / 2, viewSize.height / 2);
    final scale = _baseScale(viewSize) * _zoom;
    final camera = _clampedCameraCenter(viewSize);
    var translation = center - camera * scale;
    if (_zoom > 1.01 && _devicePixelRatio > 0) {
      final snappedX = (translation.dx * _devicePixelRatio).round() / _devicePixelRatio;
      final snappedY = (translation.dy * _devicePixelRatio).round() / _devicePixelRatio;
      translation = Offset(snappedX, snappedY);
    }
    return translation;
  }

  Offset _pointerToScreen(Size viewSize) {
    final scale = _baseScale(viewSize) * _zoom;
    final translation = _calculateTranslation(viewSize);
    return translation + _effectivePointerPosition() * scale;
  }

  Offset _frameToScreen(Offset framePosition, Size viewSize) {
    final scale = _baseScale(viewSize) * _zoom;
    final translation = _calculateTranslation(viewSize);
    return translation + framePosition * scale;
  }

  Offset _screenToFrame(Offset screenPosition, Size viewSize) {
    final scale = _baseScale(viewSize) * _zoom;
    final translation = _calculateTranslation(viewSize);
    if (scale == 0) {
      return Offset.zero;
    }
    final raw = (screenPosition - translation) / scale;
    return Offset(
      raw.dx.clamp(0, _frameSize.width),
      raw.dy.clamp(0, _frameSize.height),
    );
  }

  void _sendPointerEvent() {
    final client = _vncClient;
    if (client == null || _connectionError != null || _isConnecting) {
      return;
    }
    _markInputActivity();
    final adjusted = _applyInputCalibration(_pointerPosition);
    final maxX = _maxPointerX();
    final maxY = _maxPointerY();
    final x = adjusted.dx.round().clamp(0, maxX);
    final y = adjusted.dy.round().clamp(0, maxY);
    if (_cursorDebugEnabled) {
      _logCursorDebug('send_pointer', {
        'x': x,
        'y': y,
        'maxX': maxX,
        'maxY': maxY,
        'server': {
          'w': client.serverWidth,
          'h': client.serverHeight,
        },
      });
    }
    client.sendPointer(x: x, y: y, mask: _buttonMask);
    client.requestIncrementalFrame();
  }

  List<int> _buildEncodingList() {
    final ordered = <int>[];
    if (_lowLatencyEnabled) {
      ordered.add(_encodingZlib);
    } else {
      switch (_encodingPreference) {
        case VncEncodingPreference.zrle:
          ordered.add(_encodingZrle);
          break;
        case VncEncodingPreference.tight:
          ordered.add(_encodingTight);
          break;
        case VncEncodingPreference.zlib:
          ordered.add(_encodingZlib);
          break;
        case VncEncodingPreference.raw:
          ordered.add(_encodingRaw);
          break;
      }
    }
    const fallback = [
      _encodingZrle,
      _encodingTight,
      _encodingZlib,
      _encodingRaw,
    ];
    for (final encoding in fallback) {
      if (!ordered.contains(encoding)) {
        ordered.add(encoding);
      }
    }
    if (_highPerfEnabled) {
      ordered.add(_encodingHighPerf);
    } else if (_dataSaverEnabled) {
      ordered.add(_encodingDataSaver);
    }
    if (_colorDepth == VncColorDepth.depth16) {
      ordered.removeWhere(
        (encoding) => encoding == _encodingZrle || encoding == _encodingTight,
      );
    }
    if (!ordered.contains(_encodingCopyRect)) {
      ordered.add(_encodingCopyRect);
    }
    if (!ordered.contains(_encodingCursor)) {
      ordered.add(_encodingCursor);
    }
    if (ordered.contains(_encodingTight)) {
      ordered.add(_encodingCompressLevelBase + _tightCompressionLevel);
      if (_tightJpegEnabled) {
        ordered.add(_encodingQualityLevelBase + _tightQualityLevel);
      }
    }
    return ordered;
  }

  void _applyEncodingPreferences() {
    final client = _vncClient;
    if (client == null || _connectionError != null || _isConnecting) {
      return;
    }
    client.setEncodings(_buildEncodingList());
  }

  void _applyPixelFormatPreference() {
    final client = _vncClient;
    if (client == null || _connectionError != null || _isConnecting) {
      return;
    }
    client.setPixelFormat(use16Bit: _colorDepth == VncColorDepth.depth16);
  }

  void _setLowLatencyMode(bool enabled) {
    _updateState(() {
      _lowLatencyEnabled = enabled;
      if (enabled) {
        _encodingPreference = VncEncodingPreference.zlib;
        _tightCompressionLevel = 1;
        _tightJpegEnabled = false;
      }
    });
    _applyEncodingPreferences();
    _applyPixelFormatPreference();
    _requestStreamRefresh(resetAutoResize: true);
  }

  void _setDataSaverMode(bool enabled) {
    _updateState(() {
      _dataSaverEnabled = enabled;
      if (enabled) {
        _highPerfEnabled = false;
      }
    });
    _applyEncodingPreferences();
    _requestStreamRefresh(resetAutoResize: true);
  }

  void _setHighPerfMode(bool enabled) {
    _updateState(() {
      _highPerfEnabled = enabled;
      if (enabled) {
        _dataSaverEnabled = false;
      }
    });
    _applyEncodingPreferences();
    if (enabled) {
      unawaited(_startStream(preserveExisting: true));
    } else {
      _requestStreamRefresh(resetAutoResize: true);
    }
  }

  double _viewAspectRatio(Size screenSize) {
    final frameAspect = _frameSize.height == 0
        ? 1
        : _frameSize.width / _frameSize.height;
    if (_viewMode == VncViewMode.fill) {
      return screenSize.width / screenSize.height.toDouble();
    }
    return frameAspect.toDouble();
  }

  int _maxStreamPixels(bool isLandscape) {
    if (_dataSaverEnabled) {
      return isLandscape ? 1400000 : 1800000;
    }
    if (_isFullscreen && isLandscape) {
      return 1800000;
    }
    if (_isFullscreen) {
      return 2400000;
    }
    return 3200000;
  }

  double _effectiveStreamDpr(double dpr, bool isLandscape) {
    if (!_isFullscreen) {
      return dpr;
    }
    final cap = isLandscape ? 2.0 : 2.5;
    return dpr > cap ? cap : dpr;
  }

  Size? _preferredStreamSize() {
    if (!mounted) {
      return null;
    }
    if (_lastViewSize.width <= 0 || _lastViewSize.height <= 0) {
      return null;
    }
    double aspect = _frameSize.width > 0 && _frameSize.height > 0
        ? _frameSize.width / _frameSize.height
        : 1;
    if (_selectedDisplayIndex != null && _availableDisplays.isNotEmpty) {
      final display = _availableDisplays.firstWhere(
        (item) => item.index == _selectedDisplayIndex,
        orElse: () => _availableDisplays.first,
      );
      if (display.width > 0 && display.height > 0) {
        aspect = display.width / display.height;
      }
    }
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;
    final dpr = _effectiveStreamDpr(
      MediaQuery.of(context).devicePixelRatio,
      isLandscape,
    );
    final zoomFactor = _zoom.clamp(0.7, _zoomMax);
    final display = _availableDisplays.isNotEmpty
        ? _availableDisplays.firstWhere(
            (item) => item.index == _selectedDisplayIndex,
            orElse: () => _availableDisplays.first,
          )
        : null;
    final maxDisplayWidth =
        (display?.width ?? 4096) > 0 ? (display?.width ?? 4096) : 4096;
    final maxDisplayHeight =
        (display?.height ?? 4096) > 0 ? (display?.height ?? 4096) : 4096;
    final maxPixels = _maxStreamPixels(isLandscape);
    final displayPixels = display == null
        ? 0
        : (display.width > 0 && display.height > 0)
            ? display.width * display.height
            : 0;
    final preferNative = _zoom > 1.05 &&
        display != null &&
        display.width > 0 &&
        display.height > 0 &&
        displayPixels > 0 &&
        displayPixels <= maxPixels;
    final nativeWidth = display?.width ?? 0;
    final nativeHeight = display?.height ?? 0;
    var targetWidth = preferNative
        ? nativeWidth
        : (_lastViewSize.width * dpr * zoomFactor)
            .round()
            .clamp(1, maxDisplayWidth);
    var targetHeight = preferNative
        ? nativeHeight
        : (targetWidth / aspect).round().clamp(1, maxDisplayHeight);
    final viewMaxHeight = (_lastViewSize.height * dpr).round();
    if (zoomFactor <= 1.05 && viewMaxHeight > 0 && targetHeight > viewMaxHeight) {
      targetHeight = viewMaxHeight;
      targetWidth =
          (targetHeight * aspect).round().clamp(1, maxDisplayWidth);
    }
    final currentPixels = targetWidth * targetHeight;
    if (currentPixels > maxPixels && currentPixels > 0) {
      final scale = math.sqrt(maxPixels / currentPixels);
      targetWidth = (targetWidth * scale).round().clamp(1, maxDisplayWidth);
      targetHeight = (targetHeight * scale).round().clamp(1, maxDisplayHeight);
    }
    return Size(targetWidth.toDouble(), targetHeight.toDouble());
  }

  void _maybeAutoResizeStream() {
    if (!mounted || _isDisposed) {
      return;
    }
    if (_autoSizedOnce ||
        _isResizing ||
        _isConnecting ||
        _vncClient == null ||
        _viewMode == VncViewMode.original) {
      return;
    }
    final desired = _preferredStreamSize();
    if (desired == null) {
      return;
    }
    final delta = (desired.width - _frameSize.width).abs() +
        (desired.height - _frameSize.height).abs();
    if (delta < 40) {
      _autoSizedOnce = true;
      return;
    }
    _autoSizedOnce = true;
    _autoResizeTimer?.cancel();
    _autoResizeTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted || _isDisposed) {
        return;
      }
      unawaited(
        _startStream(
          requestedSize: desired,
          preserveExisting: true,
          silentFailure: true,
        ),
      );
    });
  }

  void _sendClick(int mask) {
    final client = _vncClient;
    if (client == null || _connectionError != null || _isConnecting) {
      return;
    }
    _markInputActivity();
    final adjusted = _applyInputCalibration(_pointerPosition);
    final maxX = _maxPointerX();
    final maxY = _maxPointerY();
    final x = adjusted.dx.round().clamp(0, maxX).toInt();
    final y = adjusted.dy.round().clamp(0, maxY).toInt();
    final previousMask = _buttonMask;
    final downMask = previousMask | mask;
    client.sendPointer(x: x, y: y, mask: downMask);
    client.sendPointer(x: x, y: y, mask: previousMask);
    client.requestIncrementalFrame();
    _triggerClickPulse();
  }

  void _sendScrollStep({double dx = 0, double dy = 0}) {
    final client = _vncClient;
    if (client == null || _connectionError != null || _isConnecting) {
      return;
    }
    if (dx == 0 && dy == 0) {
      return;
    }
    _markInputActivity();
    final adjusted = _applyInputCalibration(_pointerPosition);
    final maxX = _maxPointerX();
    final maxY = _maxPointerY();
    final x = adjusted.dx.round().clamp(0, maxX).toInt();
    final y = adjusted.dy.round().clamp(0, maxY).toInt();
    final stepX = dx == 0 ? 0 : (dx.isNegative ? -1 : 1);
    final stepY = dy == 0 ? 0 : (dy.isNegative ? -1 : 1);
    client.sendScroll(x: x, y: y, deltaX: stepX, deltaY: stepY);
    client.requestIncrementalFrame();
  }

  void _handleScrollDelta(Offset delta) {
    if (delta == Offset.zero) {
      return;
    }
    if (delta.dy != 0) {
      _scrollAccumulator += -delta.dy;
      while (_scrollAccumulator.abs() >= _scrollStep) {
        final direction = _scrollAccumulator.isNegative ? -1 : 1;
        _sendScrollStep(dy: direction.toDouble());
        _scrollAccumulator -= direction * _scrollStep;
      }
    }
    if (delta.dx != 0) {
      _scrollAccumulatorX += -delta.dx;
      while (_scrollAccumulatorX.abs() >= _scrollStep) {
        final direction = _scrollAccumulatorX.isNegative ? -1 : 1;
        _sendScrollStep(dx: direction.toDouble());
        _scrollAccumulatorX -= direction * _scrollStep;
      }
    }
  }

  void _handleTrackpadPointerSignal(PointerSignalEvent event) {
    if (_connectionError != null || _isConnecting) {
      return;
    }
    if (event is PointerScrollEvent) {
      _handleScrollDelta(event.scrollDelta);
    }
  }

  void _handleTrackpadPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (_connectionError != null || _isConnecting) {
      return;
    }
    if (event.panDelta != Offset.zero) {
      _handleScrollDelta(event.panDelta);
    }
    if (event.scale != 1.0) {
      final nextZoom = _clampZoom(_zoom * event.scale);
      if (nextZoom != _zoom) {
        _updateZoomValue(nextZoom);
        _pinchCommitTimer?.cancel();
        _pinchCommitTimer = Timer(const Duration(milliseconds: 160), () {
          if (!mounted || _isDisposed) {
            return;
          }
          _commitZoomValue(_zoom);
        });
      }
    }
  }

  int _maxPointerX() {
    final max = _frameSize.width.floor() - 1;
    return max < 0 ? 0 : max;
  }

  int _maxPointerY() {
    final max = _frameSize.height.floor() - 1;
    return max < 0 ? 0 : max;
  }

  void _holdButton(int mask) {
    if (_buttonMask & mask != 0) {
      return;
    }
    _buttonMask |= mask;
    _sendPointerEvent();
  }

  void _releaseButton(int mask) {
    if (_buttonMask & mask == 0) {
      return;
    }
    _buttonMask &= ~mask;
    _sendPointerEvent();
  }

  void _endDrag() {
    if (!_isDragging) {
      return;
    }
    _isDragging = false;
    _releaseButton(1);
  }

  Offset _averagePointerPosition() {
    if (_activePointers.isEmpty) {
      return Offset.zero;
    }
    var sum = Offset.zero;
    for (final position in _activePointers.values) {
      sum += position;
    }
    return sum / _activePointers.length.toDouble();
  }

  bool _isTapCandidate(DateTime now) {
    if (_primaryDownTime == null || _primaryDownPosition == null) {
      return false;
    }
    if (now.difference(_primaryDownTime!) > _tapTimeout) {
      return false;
    }
    final last = _lastPrimaryPosition ?? _primaryDownPosition!;
    return (last - _primaryDownPosition!).distance <= _tapSlop;
  }

  void _resetPointerTracking() {
    _primaryDownPosition = null;
    _primaryDownTime = null;
    _lastPrimaryPosition = null;
    _lastMultiFingerPosition = null;
  }

  void _clearPointerState({bool sendPointer = true}) {
    final shouldRelease = _isDragging || _buttonMask != 0;
    _updateState(() {
      _activePointers.clear();
      _resetPointerTracking();
      _lastTapTime = null;
      _lastTapPosition = null;
      _directDragActive = false;
      _isDragging = false;
      _buttonMask = 0;
      _scrollAccumulator = 0;
      _scrollAccumulatorX = 0;
      _lastHoverPosition = null;
    });
    if (sendPointer && shouldRelease) {
      _sendPointerEvent();
    }
  }

  void _schedulePointerReset() {
    if (_pendingPointerReset) {
      return;
    }
    _pendingPointerReset = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isDisposed) {
        return;
      }
      if (!_pendingPointerReset) {
        return;
      }
      _pendingPointerReset = false;
      _clearPointerState();
    });
  }

  void _handleTrackpadPointerDown(PointerDownEvent event) {
    if (_connectionError != null || _isConnecting) {
      return;
    }
    _lastHoverPosition = null;
    _activePointers[event.pointer] = event.position;
    if (_activePointers.length == 1) {
      _primaryDownPosition = event.position;
      _primaryDownTime = DateTime.now();
      _lastPrimaryPosition = event.position;
      _lastMultiFingerPosition = null;
    } else if (_activePointers.length >= 2) {
      _lastMultiFingerPosition = _averagePointerPosition();
    }
  }

  void _handleTrackpadDoubleTapDown(TapDownDetails _) {
    _lastGestureDoubleTapAt = DateTime.now();
  }

  void _handleTrackpadDoubleTap() {
    _lastGestureDoubleTapAt = DateTime.now();
    _sendClick(1);
  }

  void _handleTrackpadPointerMove(PointerMoveEvent event) {
    if (_connectionError != null || _isConnecting) {
      return;
    }
    if (!_activePointers.containsKey(event.pointer)) {
      if (event.kind != PointerDeviceKind.touch) {
        return;
      }
      _clearPointerState();
      _activePointers[event.pointer] = event.position;
      _primaryDownPosition = event.position;
      _primaryDownTime = DateTime.now();
      _lastPrimaryPosition = event.position;
      _lastMultiFingerPosition = null;
    }
    _activePointers[event.pointer] = event.position;
    if (_activePointers.length >= 2) {
      final average = _averagePointerPosition();
      final last = _lastMultiFingerPosition;
      if (last != null) {
        final delta = average - last;
        if (delta.distance != 0) {
          _handleScrollDelta(delta);
        }
      }
      _lastMultiFingerPosition = average;
      return;
    }
    if (_activePointers.length == 1) {
      final last = _lastPrimaryPosition ?? event.position;
      final delta = event.position - last;
      if (delta.distance != 0) {
        _movePointerBy(delta);
      }
      _lastPrimaryPosition = event.position;
    } else {
      // Multi-finger gestures are handled by the OS, do not intercept.
    }
  }

  void _handleTrackpadPointerUp(PointerUpEvent event) {
    if (!_activePointers.containsKey(event.pointer)) {
      return;
    }
    final wasMultiFinger = _activePointers.length >= 2;
    _activePointers.remove(event.pointer);
    if (_activePointers.isEmpty) {
      final now = DateTime.now();
      final lastGestureTap = _lastGestureDoubleTapAt;
      if (lastGestureTap != null &&
          now.difference(lastGestureTap) <= _doubleTapTimeout) {
        _lastGestureDoubleTapAt = null;
        _resetPointerTracking();
        return;
      }
      if (_isDragging) {
        _endDrag();
      } else if (!wasMultiFinger && _isTapCandidate(now)) {
        final lastTap = _lastTapTime;
        final lastPos = _lastTapPosition;
        if (lastTap != null &&
            now.difference(lastTap) <= _doubleTapTimeout &&
            lastPos != null &&
            (_primaryDownPosition == null ||
                (_primaryDownPosition! - lastPos).distance <= _tapSlop)) {
          _sendClick(1);
          _lastTapTime = null;
          _lastTapPosition = null;
        } else {
          _lastTapTime = now;
          _lastTapPosition = _primaryDownPosition;
        }
      }
      _resetPointerTracking();
    } else if (_activePointers.length == 1) {
      final remaining = _activePointers.values.first;
      _primaryDownPosition = remaining;
      _primaryDownTime = DateTime.now();
      _lastPrimaryPosition = remaining;
      _lastMultiFingerPosition = null;
    } else {
      _lastMultiFingerPosition = _averagePointerPosition();
    }
    _lastHoverPosition = null;
  }

  void _handleTrackpadPointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    _endDrag();
    _resetPointerTracking();
    _lastHoverPosition = null;
  }

  void _handleTrackpadPointerHover(PointerHoverEvent event) {
    if (_connectionError != null || _isConnecting) {
      return;
    }
    final last = _lastHoverPosition;
    _lastHoverPosition = event.position;
    if (last == null) {
      return;
    }
    final delta = event.position - last;
    if (delta.distance != 0) {
      _movePointerBy(delta);
    }
  }

  void _sendKeyPress(int keysym) {
    final client = _vncClient;
    if (client == null || _connectionError != null || _isConnecting) {
      return;
    }
    _markInputActivity();
    client.sendKey(down: true, keysym: keysym);
    client.sendKey(down: false, keysym: keysym);
    client.requestIncrementalFrame();
  }

}
