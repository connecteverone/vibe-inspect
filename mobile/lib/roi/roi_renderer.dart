import 'dart:ui' as ui;

import 'roi_models.dart';

class RoiRenderer {
  RoiRenderer({
    required this.framebufferSize,
    required this.logicalSize,
  });

  final ui.Size framebufferSize;
  final ui.Size logicalSize;
  final ui.Paint _nearestPaint = ui.Paint()
    ..filterQuality = ui.FilterQuality.none
    ..isAntiAlias = false;
  final ui.Paint _linearPaint = ui.Paint()
    ..filterQuality = ui.FilterQuality.medium
    ..isAntiAlias = false;

  void paintTile({
    required ui.Canvas canvas,
    required RoiTileKey tile,
    required ui.Image image,
    required double scale,
    required ui.Offset translation,
  }) {
    final rect = _mapLogicalToFramebuffer(tile);
    final target = ui.Rect.fromLTWH(
      translation.dx + rect.left * scale,
      translation.dy + rect.top * scale,
      rect.width * scale,
      rect.height * scale,
    );
    final needsNearest = scale > 1.01 ||
        image.width != tile.width ||
        image.height != tile.height;
    final paint = needsNearest ? _nearestPaint : _linearPaint;
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      target,
      paint,
    );
  }

  ui.Rect _mapLogicalToFramebuffer(RoiTileKey tile) {
    final logicalW = logicalSize.width.round();
    final logicalH = logicalSize.height.round();
    final fbW = framebufferSize.width.round();
    final fbH = framebufferSize.height.round();
    if (logicalW <= 0 || logicalH <= 0 || fbW <= 0 || fbH <= 0) {
      return ui.Rect.fromLTWH(
        tile.x.toDouble(),
        tile.y.toDouble(),
        tile.width.toDouble(),
        tile.height.toDouble(),
      );
    }
    final left = _mapCoord(tile.x, logicalW, fbW);
    final right = _mapCoord(tile.x + tile.width, logicalW, fbW);
    final top = _mapCoord(tile.y, logicalH, fbH);
    final bottom = _mapCoord(tile.y + tile.height, logicalH, fbH);
    final width = (right - left).clamp(1, fbW);
    final height = (bottom - top).clamp(1, fbH);
    return ui.Rect.fromLTWH(
      left.toDouble(),
      top.toDouble(),
      width.toDouble(),
      height.toDouble(),
    );
  }

  int _mapCoord(int value, int logical, int framebuffer) {
    if (logical <= 0) {
      return value;
    }
    final scaled = (value * framebuffer + logical - 1) ~/ logical;
    return scaled.clamp(0, framebuffer).toInt();
  }
}
