part of '../main.dart';

class RustdeskVideoView extends StatefulWidget {
  const RustdeskVideoView({
    super.key,
    required this.sessionId,
    required this.token,
    this.onFirstFrame,
    this.onDisplaySize,
    this.zoom = _rustdeskZoomDefault,
    this.cursor,
    this.input,
    this.showRemoteCursor = false,
    this.showLocalCursor = true,
    this.allowInput = false,
    this.cornerRadius = 16,
    this.backgroundColor = Colors.transparent,
  });

  final String sessionId;
  final String token;
  final VoidCallback? onFirstFrame;
  final ValueChanged<Size>? onDisplaySize;
  final double zoom;
  final Offset? cursor;
  final RustdeskInputController? input;
  final bool showRemoteCursor;
  final bool showLocalCursor;
  final bool allowInput;
  final double cornerRadius;
  final Color backgroundColor;

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
  Size _baseSize = Size.zero;
  Offset _translation = Offset.zero;
  double _appliedZoom = _rustdeskZoomDefault;
  bool _decoding = false;
  bool _rightDown = false;
  DateTime _lastKick = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastRemoteCursorAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _notifiedFirstFrame = false;
  Size? _lastDisplaySize;
  Listenable? _cursorListenable;
  Offset? _remoteCursor;
  String? _remoteCursorSession;

  @override
  void initState() {
    super.initState();
    _appliedZoom = widget.zoom.clamp(_rustdeskZoomMin, _rustdeskZoomMax);
    _attachCursorListener(widget.input);
    _ensureRemoteCursorOption();
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
      _lastDisplaySize = null;
      _translation = Offset.zero;
      _remoteCursor = null;
      _remoteCursorSession = null;
    }
    if (oldWidget.input != widget.input) {
      _attachCursorListener(widget.input);
    }
    if (oldWidget.showRemoteCursor != widget.showRemoteCursor ||
        oldWidget.sessionId != widget.sessionId) {
      _ensureRemoteCursorOption();
    }
    if (oldWidget.zoom != widget.zoom) {
      _applyZoom(widget.zoom, anchor: _zoomAnchor);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _image?.dispose();
    _image = null;
    _attachCursorListener(null);
    super.dispose();
  }

  Future<void> _tick() async {
    if (_decoding) {
      return;
    }
    _decoding = true;
    try {
      _ensureRemoteCursorOption();
      final bridge = RustdeskBridge.instance;
      final displaySize = bridge.getDisplaySize(widget.sessionId, 0);
      final nextRemoteCursor =
          widget.showRemoteCursor ? bridge.getCursorPosition(widget.sessionId) : null;
      if (displaySize == null ||
          displaySize.width <= 0 ||
          displaySize.height <= 0) {
        _kickstartSession();
        if (_remoteCursor != nextRemoteCursor && mounted) {
          setState(() {
            _remoteCursor = nextRemoteCursor;
          });
        }
        return;
      }
      if (_lastDisplaySize != displaySize) {
        _lastDisplaySize = displaySize;
        widget.onDisplaySize?.call(displaySize);
      }
      final bytes = bridge.copyRgba(widget.sessionId, 0);
      if (bytes == null || bytes.isEmpty) {
        _kickstartSession();
        if (_remoteCursor != nextRemoteCursor && mounted) {
          setState(() {
            _remoteCursor = nextRemoteCursor;
          });
        }
        return;
      }
      final expected = displaySize.width.toInt() * displaySize.height.toInt() * 4;
      if (bytes.length < expected) {
        _kickstartSession();
        if (_remoteCursor != nextRemoteCursor && mounted) {
          setState(() {
            _remoteCursor = nextRemoteCursor;
          });
        }
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
        if (_imageSize != displaySize) {
          _imageSize = displaySize;
          _recomputeBaseSize();
          _translation = _clampTranslation(_translation, _appliedZoom);
        }
        _remoteCursor = nextRemoteCursor;
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
    ui.decodeImageFromPixels(
      bytes,
      size.width.toInt(),
      size.height.toInt(),
      ui.PixelFormat.bgra8888,
      completer.complete,
    );
    return completer.future;
  }

  void _applyZoom(double zoom, {Offset? anchor}) {
    final nextZoom = zoom.clamp(_rustdeskZoomMin, _rustdeskZoomMax);
    if (_imageSize == null || _viewportSize.isEmpty || _baseSize.isEmpty) {
      _appliedZoom = nextZoom;
      return;
    }
    if (anchor != null) {
      final anchorScreen = _remoteToScreen(anchor, _appliedZoom, _translation);
      final anchorBase = _remoteToBase(anchor);
      final desiredTranslation = anchorScreen - anchorBase * nextZoom;
      _translation = _clampTranslation(desiredTranslation, nextZoom);
    } else {
      _translation = _clampTranslation(_translation, nextZoom);
    }
    _appliedZoom = nextZoom;
  }

  Offset? get _cursor {
    final local = widget.cursor ?? widget.input?.cursor;
    if (widget.showRemoteCursor) {
      return _remoteCursor ?? (widget.showLocalCursor ? local : null);
    }
    return widget.showLocalCursor ? local : null;
  }

  Offset? get _zoomAnchor {
    return _remoteCursor ?? widget.cursor ?? widget.input?.cursor;
  }

  void _attachCursorListener(Listenable? listenable) {
    if (_cursorListenable == listenable) {
      return;
    }
    _cursorListenable?.removeListener(_onCursorChanged);
    _cursorListenable = listenable;
    _cursorListenable?.addListener(_onCursorChanged);
  }

  void _onCursorChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _ensureRemoteCursorOption() {
    if (!widget.showRemoteCursor) {
      return;
    }
    final sessionId = widget.sessionId;
    if (sessionId.isEmpty) {
      return;
    }
    if (_remoteCursorSession == sessionId) {
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastRemoteCursorAttempt) < const Duration(seconds: 1)) {
      return;
    }
    _lastRemoteCursorAttempt = now;
    final ok = RustdeskBridge.instance.setToggleOption(
      sessionId,
      'show-remote-cursor',
      true,
    );
    if (ok) {
      _remoteCursorSession = sessionId;
    }
  }

  void _recomputeBaseSize() {
    final imageSize = _imageSize;
    if (imageSize == null || _viewportSize.isEmpty) {
      _baseSize = Size.zero;
      return;
    }
    final fitted = applyBoxFit(BoxFit.contain, imageSize, _viewportSize);
    _baseSize = fitted.destination;
  }

  Offset _remoteToBase(Offset remote) {
    final imageSize = _imageSize;
    if (imageSize == null || imageSize.isEmpty || _baseSize.isEmpty) {
      return Offset.zero;
    }
    final nx = remote.dx / imageSize.width;
    final ny = remote.dy / imageSize.height;
    return Offset(nx * _baseSize.width, ny * _baseSize.height);
  }

  Offset _remoteToScreen(Offset remote, double zoom, Offset translation) {
    final base = _remoteToBase(remote);
    return translation + base * zoom;
  }

  Offset _clampTranslation(Offset translation, double zoom) {
    if (_baseSize.isEmpty || _viewportSize.isEmpty) {
      return translation;
    }
    final displaySize = Size(
      _baseSize.width * zoom,
      _baseSize.height * zoom,
    );
    final minX = displaySize.width <= _viewportSize.width
        ? (_viewportSize.width - displaySize.width) / 2
        : _viewportSize.width - displaySize.width;
    final maxX = displaySize.width <= _viewportSize.width
        ? minX
        : 0.0;
    final minY = displaySize.height <= _viewportSize.height
        ? (_viewportSize.height - displaySize.height) / 2
        : _viewportSize.height - displaySize.height;
    final maxY = displaySize.height <= _viewportSize.height
        ? minY
        : 0.0;
    return Offset(
      translation.dx.clamp(minX, maxX),
      translation.dy.clamp(minY, maxY),
    );
  }

  Offset? _mapToRemote(Offset local) {
    final imageSize = _imageSize;
    if (imageSize == null ||
        imageSize.width <= 0 ||
        imageSize.height <= 0 ||
        _baseSize.isEmpty) {
      return null;
    }
    final displaySize = Size(
      _baseSize.width * _appliedZoom,
      _baseSize.height * _appliedZoom,
    );
    final left = _translation.dx;
    final top = _translation.dy;
    if (local.dx < left ||
        local.dx > left + displaySize.width ||
        local.dy < top ||
        local.dy > top + displaySize.height) {
      return null;
    }
    final baseX = (local.dx - left) / _appliedZoom;
    final baseY = (local.dy - top) / _appliedZoom;
    final nx = baseX / _baseSize.width;
    final ny = baseY / _baseSize.height;
    final x = (nx * imageSize.width).clamp(0, imageSize.width - 1).toDouble();
    final y = (ny * imageSize.height).clamp(0, imageSize.height - 1).toDouble();
    return Offset(x, y);
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
    final allowInput = widget.allowInput;
    final cursor = _cursor;
    return LayoutBuilder(
      builder: (context, constraints) {
        final nextViewport = Size(constraints.maxWidth, constraints.maxHeight);
        if (nextViewport != _viewportSize) {
          _viewportSize = nextViewport;
          _recomputeBaseSize();
          _translation = _clampTranslation(_translation, _appliedZoom);
          if (_viewportSize.width > 0 && _viewportSize.height > 0) {
            RustdeskBridge.instance.setDisplaySize(widget.sessionId, 0, _viewportSize);
          }
        }
        final displaySize = Size(
          _baseSize.width * _appliedZoom,
          _baseSize.height * _appliedZoom,
        );
        final cursorOffset = (cursor == null || _imageSize == null || _baseSize.isEmpty)
            ? null
            : _remoteToScreen(cursor, _appliedZoom, _translation);
        return GestureDetector(
          onTapDown: allowInput ? _handleTapDown : null,
          onTapUp: allowInput ? _handleTapUp : null,
          onTapCancel: allowInput ? () => _sendClick('up', button: 'left') : null,
          onLongPressStart: allowInput ? _handleLongPressStart : null,
          onLongPressEnd: allowInput ? _handleLongPressEnd : null,
          onScaleUpdate: allowInput ? _handleScaleUpdate : null,
          behavior: HitTestBehavior.opaque,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.cornerRadius),
            child: Container(
              color: widget.backgroundColor,
              alignment: Alignment.center,
              child: image == null
                  ? const _InlineStatus(
                      message: 'Waiting for RustDesk frames...',
                    )
                  : Stack(
                      children: [
                        Positioned(
                          left: _translation.dx,
                          top: _translation.dy,
                          width: displaySize.width,
                          height: displaySize.height,
                          child: RawImage(
                            image: image,
                            fit: BoxFit.fill,
                            filterQuality: _appliedZoom > 1.05
                                ? FilterQuality.none
                                : FilterQuality.low,
                          ),
                        ),
                        if (cursorOffset != null &&
                            cursorOffset.dx >= 0 &&
                            cursorOffset.dy >= 0 &&
                            cursorOffset.dx <= _viewportSize.width &&
                            cursorOffset.dy <= _viewportSize.height)
                          Positioned(
                            left: cursorOffset.dx - 6,
                            top: cursorOffset.dy - 6,
                            child: IgnorePointer(
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.black,
                                    width: 1,
                                  ),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Colors.black26,
                                      blurRadius: 2,
                                      offset: Offset(0, 1),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }
}
