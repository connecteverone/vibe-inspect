part of '../main.dart';

class MediaV2VideoView extends StatefulWidget {
  const MediaV2VideoView({
    super.key,
    required this.client,
  });

  final RemoteQuicClient client;

  @override
  State<MediaV2VideoView> createState() => _MediaV2VideoViewState();
}

class _MediaV2VideoViewState extends State<MediaV2VideoView> {
  StreamSubscription<RemoteVideoFrame>? _subscription;
  ui.Image? _image;
  Size? _imageSize;
  Size _viewportSize = Size.zero;
  RemoteVideoFrame? _pending;
  bool _decoding = false;
  bool _rightDown = false;

  @override
  void initState() {
    super.initState();
    _subscription = widget.client.frames.listen(_onFrame);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _image?.dispose();
    _image = null;
    super.dispose();
  }

  void _onFrame(RemoteVideoFrame frame) {
    _pending = frame;
    if (!_decoding) {
      _decodePending();
    }
  }

  Future<void> _decodePending() async {
    if (_decoding) return;
    final frame = _pending;
    if (frame == null) return;
    _pending = null;
    _decoding = true;
    try {
      if (frame.header.codec != VideoCodec.rawRgba) {
        return;
      }
      final width = frame.header.width;
      final height = frame.header.height;
      if (width <= 0 || height <= 0) {
        return;
      }
      final expected = width * height * 4;
      Uint8List payload;
      if (frame.header.isZlib) {
        try {
          payload = Uint8List.fromList(ZLibDecoder().decodeBytes(frame.payload));
        } catch (_) {
          return;
        }
      } else {
        payload = frame.payload;
      }
      if (payload.length < expected) {
        return;
      }
      final image = await _decode(payload, Size(width.toDouble(), height.toDouble()));
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = image;
        _imageSize = Size(width.toDouble(), height.toDouble());
      });
    } finally {
      _decoding = false;
      if (_pending != null) {
        _decodePending();
      }
    }
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

  Offset? _mapToRemote(Offset local) {
    final imageSize = _imageSize;
    if (imageSize == null || imageSize.width <= 0 || imageSize.height <= 0) {
      return null;
    }
    final fitted = applyBoxFit(BoxFit.contain, imageSize, _viewportSize);
    final dest = fitted.destination;
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
    widget.client.sendDataControl({
      'type': 'mouse',
      'action': 'move',
      'x': remote.dx.round(),
      'y': remote.dy.round(),
    });
  }

  void _sendClick(String action, {required String button, Offset? remote}) {
    final payload = <String, Object>{
      'type': 'mouse',
      'action': action,
      'button': button,
    };
    if (remote != null) {
      payload['x'] = remote.dx.round();
      payload['y'] = remote.dy.round();
    }
    widget.client.sendDataControl(payload);
  }

  void _handleTapDown(TapDownDetails details) {
    final remote = _mapToRemote(details.localPosition);
    if (remote == null) return;
    _sendMove(remote);
    _sendClick('down', button: 'left', remote: remote);
  }

  void _handleTapUp(TapUpDetails details) {
    _sendClick('up', button: 'left');
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    final remote = _mapToRemote(details.localPosition);
    if (remote == null) return;
    _sendMove(remote);
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

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          onTapDown: _handleTapDown,
          onTapUp: _handleTapUp,
          onTapCancel: () => _sendClick('up', button: 'left'),
          onPanUpdate: _handlePanUpdate,
          onLongPressStart: _handleLongPressStart,
          onLongPressEnd: _handleLongPressEnd,
          behavior: HitTestBehavior.opaque,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(16),
            ),
            alignment: Alignment.center,
            child: image == null
                ? const _InlineStatus(message: 'Waiting for media frames...')
                : FittedBox(
                    fit: BoxFit.contain,
                    child: SizedBox(
                      width: image.width.toDouble(),
                      height: image.height.toDouble(),
                      child: RawImage(
                        image: image,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.low,
                      ),
                    ),
                  ),
          ),
        );
      },
    );
  }
}
