import 'package:flutter/foundation.dart';

class ZoomController extends ChangeNotifier {
  ZoomController({double initialZoom = 1}) : _zoom = initialZoom;

  double _zoom;

  double get zoom => _zoom;

  void updateZoom(double value) {
    if (value == _zoom) {
      return;
    }
    _zoom = value;
    notifyListeners();
  }
}
