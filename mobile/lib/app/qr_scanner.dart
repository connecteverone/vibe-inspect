part of '../main.dart';

class _QrScannerScreen extends StatefulWidget {
  const _QrScannerScreen();

  @override
  State<_QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<_QrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
  );
  bool _isHandling = false;
  String? _errorMessage;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleDetect(BarcodeCapture capture) {
    if (_isHandling) {
      return;
    }
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.trim().isEmpty) {
        continue;
      }
      if (PairingPayload.tryParse(raw) == null) {
        setState(() {
          _errorMessage = 'Unrecognized QR code. Try again or paste the token.';
        });
        return;
      }
      _isHandling = true;
      _controller.stop();
      Navigator.of(context).pop(raw);
      return;
    }
  }

  Future<void> _openManualEntry() async {
    final controller = TextEditingController();
    final payload = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Enter pairing token'),
          content: TextField(
            key: const Key('qrPayloadField'),
            controller: controller,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText: 'Paste QR payload JSON or vibeinspect:// URL',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('applyQrButton'),
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Use token'),
            ),
          ],
        );
      },
    );
    if (!mounted || payload == null) {
      return;
    }
    final trimmed = payload.trim();
    if (trimmed.isEmpty) {
      return;
    }
    Navigator.of(context).pop(trimmed);
  }

  String _describeScannerError(MobileScannerException error) {
    switch (error.errorCode) {
      case MobileScannerErrorCode.permissionDenied:
        return 'Camera permission denied. Enable it or paste the token.';
      case MobileScannerErrorCode.unsupported:
        return 'Camera not available on this device.';
      case MobileScannerErrorCode.controllerUninitialized:
        return 'Camera not ready yet.';
      case MobileScannerErrorCode.genericError:
      default:
        return 'Unable to start the camera.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan pairing QR'),
        actions: [
          IconButton(
            tooltip: 'Paste token',
            onPressed: _openManualEntry,
            icon: const Icon(Icons.edit),
          ),
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controller,
            builder: (context, state, _) {
              final torchState = state.torchState;
              final hasTorch = torchState != TorchState.unavailable;
              return IconButton(
                tooltip: 'Toggle torch',
                onPressed: hasTorch ? _controller.toggleTorch : null,
                icon: Icon(
                  torchState == TorchState.on
                      ? Icons.flash_on
                      : Icons.flash_off,
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Switch camera',
            onPressed: _controller.switchCamera,
            icon: const Icon(Icons.cameraswitch),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final scanSize = size.shortestSide * 0.7;
          final scanWindow = Rect.fromCenter(
            center: size.center(Offset.zero),
            width: scanSize,
            height: scanSize,
          );
          return Stack(
            children: [
              MobileScanner(
                controller: _controller,
                onDetect: _handleDetect,
                scanWindow: scanWindow,
                tapToFocus: true,
                errorBuilder: (context, error) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.camera_alt_outlined,
                            size: 48,
                            color: Color(0xFF64748B),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _describeScannerError(error),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: const Color(0xFF475569),
                            ),
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: _openManualEntry,
                            child: const Text('Paste token'),
                          ),
                        ],
                      ),
                    ),
                  );
                },
                overlayBuilder: (context, constraints) {
                  return CustomPaint(
                    painter: _ScannerOverlayPainter(scanWindow),
                    child: const SizedBox.expand(),
                  );
                },
              ),
              if (_errorMessage != null)
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 32,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: const Color.fromARGB(217, 15, 23, 42),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: Color(0xFFFCA5A5),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ScannerOverlayPainter extends CustomPainter {
  _ScannerOverlayPainter(this.scanWindow);

  final Rect scanWindow;

  @override
  void paint(Canvas canvas, Size size) {
    final overlay = Paint()
      ..color = const Color(0x99000000)
      ..style = PaintingStyle.fill;
    final border = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(RRect.fromRectXY(scanWindow, 16, 16));
    canvas.drawPath(path, overlay);
    canvas.drawRRect(RRect.fromRectXY(scanWindow, 16, 16), border);
  }

  @override
  bool shouldRepaint(covariant _ScannerOverlayPainter oldDelegate) {
    return oldDelegate.scanWindow != scanWindow;
  }
}

class _RoiTilePainter extends CustomPainter {
  _RoiTilePainter({
    required this.tiles,
    required this.renderer,
    required this.translation,
    required this.scale,
    required this.revision,
  });

  final Map<RoiTileKey, ui.Image> tiles;
  final RoiRenderer renderer;
  final Offset translation;
  final double scale;
  final int revision;

  @override
  void paint(Canvas canvas, Size size) {
    for (final entry in tiles.entries) {
      renderer.paintTile(
        canvas: canvas,
        tile: entry.key,
        image: entry.value,
        scale: scale,
        translation: translation,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RoiTilePainter oldDelegate) {
    return oldDelegate.revision != revision ||
        oldDelegate.scale != scale ||
        oldDelegate.translation != translation ||
        !mapEquals(oldDelegate.tiles, tiles);
  }
}

