import 'dart:ui' as ui;

import 'roi_models.dart';

class RoiRenderer {
  RoiRenderer({required this.framebufferSize});

  final ui.Size framebufferSize;

  void paintTile({
    required ui.Canvas canvas,
    required RoiTileKey tile,
    required ui.Image image,
    required double scale,
    required ui.Offset translation,
  }) {
    final rect = ui.Rect.fromLTWH(
      tile.x.toDouble(),
      tile.y.toDouble(),
      tile.width.toDouble(),
      tile.height.toDouble(),
    );
    final target = ui.Rect.fromLTWH(
      translation.dx + rect.left * scale,
      translation.dy + rect.top * scale,
      rect.width * scale,
      rect.height * scale,
    );
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      target,
      ui.Paint(),
    );
  }
}
