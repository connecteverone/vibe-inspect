import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

enum VncViewMode { fit, fill, original }

class VncCanvasProbe extends StatelessWidget {
  const VncCanvasProbe({
    super.key,
    required this.frameImage,
    required this.cursorImage,
    required this.frameSize,
    required this.pointerPosition,
    required this.cursorHotspot,
    required this.viewMode,
    required this.zoom,
    required this.showLocalCursor,
  });

  final ui.Image frameImage;
  final ui.Image cursorImage;
  final Size frameSize;
  final Offset pointerPosition;
  final Offset cursorHotspot;
  final VncViewMode viewMode;
  final double zoom;
  final bool showLocalCursor;
  static const double markerSize = 12;
  static const double localCursorSize = 42;
  static const double localCursorOffset = 10;

  double _baseScale(Size viewSize) {
    if (frameSize.width == 0 || frameSize.height == 0) {
      return 1;
    }
    final scaleX = viewSize.width / frameSize.width;
    final scaleY = viewSize.height / frameSize.height;
    switch (viewMode) {
      case VncViewMode.fit:
        return scaleX < scaleY ? scaleX : scaleY;
      case VncViewMode.fill:
        return scaleX > scaleY ? scaleX : scaleY;
      case VncViewMode.original:
        return 1;
    }
  }

  Offset _clampedCameraCenter(Size viewSize) {
    if (frameSize.width == 0 || frameSize.height == 0) {
      return pointerPosition;
    }
    final scale = _baseScale(viewSize) * zoom;
    if (scale <= 0) {
      return pointerPosition;
    }
    final visibleWidth = viewSize.width / scale;
    final visibleHeight = viewSize.height / scale;
    final minX = visibleWidth >= frameSize.width
        ? frameSize.width / 2
        : visibleWidth / 2;
    final maxX = visibleWidth >= frameSize.width
        ? frameSize.width / 2
        : frameSize.width - visibleWidth / 2;
    final minY = visibleHeight >= frameSize.height
        ? frameSize.height / 2
        : visibleHeight / 2;
    final maxY = visibleHeight >= frameSize.height
        ? frameSize.height / 2
        : frameSize.height - visibleHeight / 2;
    return Offset(
      pointerPosition.dx.clamp(minX, maxX),
      pointerPosition.dy.clamp(minY, maxY),
    );
  }

  Offset _calculateTranslation(Size viewSize) {
    final center = Offset(viewSize.width / 2, viewSize.height / 2);
    final scale = _baseScale(viewSize) * zoom;
    final camera = _clampedCameraCenter(viewSize);
    return center - camera * scale;
  }

  Offset _pointerToScreen(Size viewSize) {
    final scale = _baseScale(viewSize) * zoom;
    final translation = _calculateTranslation(viewSize);
    return translation + pointerPosition * scale;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewSize = Size(constraints.maxWidth, constraints.maxHeight);
        final translation = _calculateTranslation(viewSize);
        final scale = _baseScale(viewSize) * zoom;
        final pointerScreen = _pointerToScreen(viewSize);
        return RepaintBoundary(
          key: const Key('probe-boundary'),
          child: ClipRect(
            child: Stack(
              children: [
                Positioned.fill(
                  child: OverflowBox(
                    minWidth: 0,
                    minHeight: 0,
                    maxWidth: double.infinity,
                    maxHeight: double.infinity,
                    alignment: Alignment.topLeft,
                    child: Transform(
                      alignment: Alignment.topLeft,
                      transform: Matrix4.translationValues(
                        translation.dx,
                        translation.dy,
                        0,
                      )..multiply(Matrix4.diagonal3Values(scale, scale, 1)),
                      child: SizedBox(
                        width: frameSize.width,
                        height: frameSize.height,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: RawImage(
                                key: const Key('probe-frame'),
                                image: frameImage,
                                fit: BoxFit.fill,
                                filterQuality: FilterQuality.medium,
                              ),
                            ),
                            Positioned(
                              left: pointerPosition.dx - markerSize / 2,
                              top: pointerPosition.dy - markerSize / 2,
                              child: SizedBox(
                                width: markerSize,
                                height: markerSize,
                                child: DecoratedBox(
                                  key: const Key('probe-marker'),
                                  decoration: BoxDecoration(
                                    color: Colors.red,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: pointerScreen.dx - cursorHotspot.dx * scale,
                  top: pointerScreen.dy - cursorHotspot.dy * scale,
                  child: SizedBox(
                    width: cursorImage.width.toDouble() * scale,
                    height: cursorImage.height.toDouble() * scale,
                    child: RawImage(
                      key: const Key('probe-cursor'),
                      image: cursorImage,
                      fit: BoxFit.fill,
                      filterQuality: FilterQuality.none,
                    ),
                  ),
                ),
                Positioned(
                  left: pointerScreen.dx - 2,
                  top: pointerScreen.dy - 2,
                  child: const SizedBox(
                    key: Key('probe-pointer-dot'),
                    width: 4,
                    height: 4,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: Colors.blue),
                    ),
                  ),
                ),
                if (showLocalCursor)
                  Positioned(
                    left: pointerScreen.dx - localCursorOffset,
                    top: pointerScreen.dy - localCursorOffset,
                    child: const SizedBox(
                      key: Key('probe-local-cursor'),
                      width: localCursorSize,
                      height: localCursorSize,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white12,
                          border: Border.fromBorderSide(
                            BorderSide(color: Colors.white30),
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

Future<ui.Image> _makeFrameImage(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final paint = Paint()..color = const Color(0xFF101010);
  canvas.drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), paint);
  final picture = recorder.endRecording();
  return picture.toImage(width, height);
}

Future<ui.Image> _makeCursorImage(int size) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final paint = Paint()..color = const Color(0xFF00FF00);
  canvas.drawRect(Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()), paint);
  final picture = recorder.endRecording();
  return picture.toImage(size, size);
}

Rect _rect(WidgetTester tester, Key key) => tester.getRect(find.byKey(key));

Future<Offset> _measureLocalOffset({
  required WidgetTester tester,
  required Size viewSize,
  required Size frameSize,
  required Offset pointer,
  required VncViewMode viewMode,
  required double zoom,
}) async {
  final frameImage = await _makeFrameImage(frameSize.width.toInt(), frameSize.height.toInt());
  final cursorImage = await _makeCursorImage(9);
  await tester.binding.setSurfaceSize(viewSize);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: SizedBox(
            width: viewSize.width,
            height: viewSize.height,
            child: AspectRatio(
              aspectRatio: frameSize.width / frameSize.height,
              child: VncCanvasProbe(
                frameImage: frameImage,
                cursorImage: cursorImage,
                frameSize: frameSize,
                pointerPosition: pointer,
                cursorHotspot: const Offset(4, 4),
                viewMode: viewMode,
                zoom: zoom,
                showLocalCursor: true,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  final dotRect = _rect(tester, const Key('probe-pointer-dot'));
  final localRect = _rect(tester, const Key('probe-local-cursor'));
  return localRect.center - dotRect.center;
}

Future<Offset> _measureRemoteOffset({
  required WidgetTester tester,
  required Size viewSize,
  required Size frameSize,
  required Offset pointer,
  required VncViewMode viewMode,
  required double zoom,
}) async {
  final frameImage =
      await _makeFrameImage(frameSize.width.toInt(), frameSize.height.toInt());
  final cursorImage = await _makeCursorImage(9);
  await tester.binding.setSurfaceSize(viewSize);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: SizedBox(
            width: viewSize.width,
            height: viewSize.height,
            child: AspectRatio(
              aspectRatio: frameSize.width / frameSize.height,
              child: VncCanvasProbe(
                frameImage: frameImage,
                cursorImage: cursorImage,
                frameSize: frameSize,
                pointerPosition: pointer,
                cursorHotspot: const Offset(4, 4),
                viewMode: viewMode,
                zoom: zoom,
                showLocalCursor: false,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  final markerBox = _rect(tester, const Key('probe-marker'));
  final cursorRect = _rect(tester, const Key('probe-cursor'));
  final scale = cursorRect.width / 9;
  final hotspot = Offset(4 * scale, 4 * scale);
  final cursorHotspotPos = cursorRect.topLeft + hotspot;
  final markerCenter = markerBox.center;
  return cursorHotspotPos - markerCenter;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('small view offset stays near zero', (tester) async {
    const frameWidth = 800;
    const frameHeight = 500;
    const cursorSize = 9;
    const viewSize = Size(320, 240);
    const pointer = Offset(200, 120);
    final frameImage = await _makeFrameImage(frameWidth, frameHeight);
    final cursorImage = await _makeCursorImage(cursorSize);

    await tester.binding.setSurfaceSize(viewSize);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: SizedBox(
              width: viewSize.width,
              height: viewSize.height,
              child: AspectRatio(
                aspectRatio: frameWidth / frameHeight,
                child: VncCanvasProbe(
                  frameImage: frameImage,
                  cursorImage: cursorImage,
                  frameSize: Size(frameWidth.toDouble(), frameHeight.toDouble()),
                  pointerPosition: pointer,
                  cursorHotspot: const Offset(4, 4),
                  viewMode: VncViewMode.fit,
                  zoom: 1.5,
                  showLocalCursor: false,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final markerBox = _rect(tester, const Key('probe-marker'));
    final cursorRect = _rect(tester, const Key('probe-cursor'));
    final scale = cursorRect.width / cursorSize;
    final hotspot = Offset(4 * scale, 4 * scale);
    final cursorHotspotPos = cursorRect.topLeft + hotspot;
    final markerCenter = markerBox.center;
    final dx = (cursorHotspotPos.dx - markerCenter.dx).abs();
    final dy = (cursorHotspotPos.dy - markerCenter.dy).abs();
    expect(dx <= 1.5 && dy <= 1.5, true, reason: 'offset too large: ($dx, $dy)');
  });

  testWidgets('small view offset with fill mode', (tester) async {
    const frameWidth = 800;
    const frameHeight = 500;
    const cursorSize = 9;
    const viewSize = Size(320, 240);
    const pointer = Offset(620, 360);
    final frameImage = await _makeFrameImage(frameWidth, frameHeight);
    final cursorImage = await _makeCursorImage(cursorSize);

    await tester.binding.setSurfaceSize(viewSize);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: SizedBox(
              width: viewSize.width,
              height: viewSize.height,
              child: AspectRatio(
                aspectRatio: frameWidth / frameHeight,
                child: VncCanvasProbe(
                  frameImage: frameImage,
                  cursorImage: cursorImage,
                  frameSize: Size(frameWidth.toDouble(), frameHeight.toDouble()),
                  pointerPosition: pointer,
                  cursorHotspot: const Offset(4, 4),
                  viewMode: VncViewMode.fill,
                  zoom: 1.0,
                  showLocalCursor: false,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final markerBox = _rect(tester, const Key('probe-marker'));
    final cursorRect = _rect(tester, const Key('probe-cursor'));
    final scale = cursorRect.width / cursorSize;
    final hotspot = Offset(4 * scale, 4 * scale);
    final cursorHotspotPos = cursorRect.topLeft + hotspot;
    final markerCenter = markerBox.center;
    final dx = (cursorHotspotPos.dx - markerCenter.dx).abs();
    final dy = (cursorHotspotPos.dy - markerCenter.dy).abs();
    expect(dx <= 1.5 && dy <= 1.5, true, reason: 'offset too large: ($dx, $dy)');
  });

  testWidgets('local cursor offset small view path', (tester) async {
    const frame = Size(800, 500);
    const view = Size(320, 240);
    const points = <Offset>[
      Offset(0, 0),
      Offset(100, 60),
      Offset(200, 120),
      Offset(300, 200),
      Offset(400, 250),
      Offset(600, 350),
      Offset(799, 499),
    ];
    final offsets = <Offset>[];
    for (final point in points) {
      offsets.add(
        await _measureLocalOffset(
          tester: tester,
          viewSize: view,
          frameSize: frame,
          pointer: point,
          viewMode: VncViewMode.fit,
          zoom: 1.5,
        ),
      );
    }
    final base = offsets.first;
    var maxDx = 0.0;
    var maxDy = 0.0;
    for (final offset in offsets) {
      maxDx = math.max(maxDx, (offset.dx - base.dx).abs());
      maxDy = math.max(maxDy, (offset.dy - base.dy).abs());
    }
    debugPrint('local cursor small view offsets: $offsets');
    expect(maxDx <= 0.5 && maxDy <= 0.5, true, reason: 'local cursor drifted');
  });

  testWidgets('local cursor offset original view path', (tester) async {
    const frame = Size(800, 500);
    const view = Size(800, 500);
    const points = <Offset>[
      Offset(0, 0),
      Offset(200, 120),
      Offset(400, 250),
      Offset(600, 380),
      Offset(799, 499),
    ];
    final offsets = <Offset>[];
    for (final point in points) {
      offsets.add(
        await _measureLocalOffset(
          tester: tester,
          viewSize: view,
          frameSize: frame,
          pointer: point,
          viewMode: VncViewMode.original,
          zoom: 1.0,
        ),
      );
    }
    final base = offsets.first;
    var maxDx = 0.0;
    var maxDy = 0.0;
    for (final offset in offsets) {
      maxDx = math.max(maxDx, (offset.dx - base.dx).abs());
      maxDy = math.max(maxDy, (offset.dy - base.dy).abs());
    }
    debugPrint('local cursor original view offsets: $offsets');
    expect(maxDx <= 0.5 && maxDy <= 0.5, true, reason: 'local cursor drifted');
  });

  testWidgets('raw 320x240 remote cursor path', (tester) async {
    const frame = Size(320, 240);
    const view = Size(320, 240);
    const points = <Offset>[
      Offset(0, 0),
      Offset(40, 30),
      Offset(80, 60),
      Offset(160, 120),
      Offset(240, 180),
      Offset(319, 239),
    ];
    var maxDx = 0.0;
    var maxDy = 0.0;
    for (final point in points) {
      final delta = await _measureRemoteOffset(
        tester: tester,
        viewSize: view,
        frameSize: frame,
        pointer: point,
        viewMode: VncViewMode.original,
        zoom: 1.0,
      );
      maxDx = math.max(maxDx, delta.dx.abs());
      maxDy = math.max(maxDy, delta.dy.abs());
      debugPrint('raw 320x240 remote delta at $point = $delta');
    }
    expect(maxDx <= 1.5 && maxDy <= 1.5, true,
        reason: 'remote cursor offset too large: ($maxDx, $maxDy)');
  });

  testWidgets('raw 320x240 local cursor path', (tester) async {
    const frame = Size(320, 240);
    const view = Size(320, 240);
    const points = <Offset>[
      Offset(0, 0),
      Offset(40, 30),
      Offset(80, 60),
      Offset(160, 120),
      Offset(240, 180),
      Offset(319, 239),
    ];
    final offsets = <Offset>[];
    for (final point in points) {
      offsets.add(
        await _measureLocalOffset(
          tester: tester,
          viewSize: view,
          frameSize: frame,
          pointer: point,
          viewMode: VncViewMode.original,
          zoom: 1.0,
        ),
      );
    }
    final base = offsets.first;
    var maxDx = 0.0;
    var maxDy = 0.0;
    for (final offset in offsets) {
      maxDx = math.max(maxDx, (offset.dx - base.dx).abs());
      maxDy = math.max(maxDy, (offset.dy - base.dy).abs());
    }
    debugPrint('raw 320x240 local offsets: $offsets');
    expect(maxDx <= 0.5 && maxDy <= 0.5, true, reason: 'local cursor drifted');
  });
}
