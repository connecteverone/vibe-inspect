part of '../main.dart';

class RustdeskInputController extends ChangeNotifier {
  RustdeskInputController({required RustdeskBridge bridge}) : _bridge = bridge;

  static const int _maxRelativeDelta = 64;

  final RustdeskBridge _bridge;
  String? _sessionId;
  Size _displaySize = Size.zero;
  Offset _cursor = Offset.zero;
  bool _cursorReady = false;
  bool _leftDown = false;
  bool _rightDown = false;
  TrackpadScrollBehavior _scrollBehavior = const TrackpadScrollBehavior();

  Size get displaySize => _displaySize;
  Offset? get cursor => _cursorReady ? _cursor : null;

  void setTrackpadScrollBehavior(TrackpadScrollBehavior behavior) {
    _scrollBehavior = behavior;
  }

  void attachSession(String sessionId) {
    _sessionId = sessionId;
  }

  void updateDisplaySize(Size size) {
    if (size == _displaySize) {
      return;
    }
    _displaySize = size;
    if (size.width <= 0 || size.height <= 0) {
      return;
    }
    if (!_cursorReady) {
      _setCursor(Offset(size.width / 2, size.height / 2));
      return;
    }
    _setCursor(
      Offset(
        _cursor.dx.clamp(0, size.width - 1),
        _cursor.dy.clamp(0, size.height - 1),
      ),
    );
  }

  void moveRelative(Offset delta) {
    final sessionId = _sessionId;
    if (sessionId == null) {
      return;
    }
    final dx = delta.dx.round().clamp(-_maxRelativeDelta, _maxRelativeDelta);
    final dy = delta.dy.round().clamp(-_maxRelativeDelta, _maxRelativeDelta);
    if (dx == 0 && dy == 0) {
      return;
    }
    _bridge.sendMouse(sessionId, {
      'type': 'move_relative',
      'x': '$dx',
      'y': '$dy',
    });
    _updateCursorBy(Offset(dx.toDouble(), dy.toDouble()));
  }

  void moveAbsolute(Offset remote) {
    final sessionId = _sessionId;
    if (sessionId == null) {
      return;
    }
    final x = remote.dx.round();
    final y = remote.dy.round();
    _bridge.sendMouse(sessionId, {'x': '$x', 'y': '$y'});
    _updateCursorTo(remote);
  }

  void scrollVertical(double dy) {
    final sessionId = _sessionId;
    if (sessionId == null) {
      return;
    }
    final adjustedDy = _scrollBehavior.transformDeltaY(dy);
    final value = adjustedDy.round();
    if (value == 0) {
      return;
    }
    _bridge.sendMouse(sessionId, {'type': 'wheel', 'y': '$value'});
  }

  void leftDown() {
    if (_leftDown) {
      return;
    }
    _leftDown = true;
    _sendButton('down', 'left');
  }

  void leftUp() {
    if (!_leftDown) {
      return;
    }
    _leftDown = false;
    _sendButton('up', 'left');
  }

  void rightDown() {
    if (_rightDown) {
      return;
    }
    _rightDown = true;
    _sendButton('down', 'right');
  }

  void rightUp() {
    if (!_rightDown) {
      return;
    }
    _rightDown = false;
    _sendButton('up', 'right');
  }

  void clickLeft() {
    leftDown();
    leftUp();
  }

  void inputKey(String name) {
    final sessionId = _sessionId;
    if (sessionId == null) {
      return;
    }
    _bridge.sessionInputKey(sessionId, name: name, press: true);
  }

  void inputString(String value) {
    final sessionId = _sessionId;
    if (sessionId == null) {
      return;
    }
    if (value.trim().isEmpty) {
      return;
    }
    _bridge.sessionInputString(sessionId, value);
  }

  void _sendButton(String type, String button) {
    final sessionId = _sessionId;
    if (sessionId == null) {
      return;
    }
    _bridge.sendMouse(sessionId, {'type': type, 'buttons': button});
  }

  void _updateCursorBy(Offset delta) {
    if (!_cursorReady || _displaySize.isEmpty) {
      return;
    }
    _setCursor(
      Offset(
        (_cursor.dx + delta.dx).clamp(0, _displaySize.width - 1),
        (_cursor.dy + delta.dy).clamp(0, _displaySize.height - 1),
      ),
    );
  }

  void _updateCursorTo(Offset position) {
    if (_displaySize.isEmpty) {
      _setCursor(position);
      return;
    }
    _setCursor(
      Offset(
        position.dx.clamp(0, _displaySize.width - 1),
        position.dy.clamp(0, _displaySize.height - 1),
      ),
    );
  }

  void _setCursor(Offset next) {
    final changed = !_cursorReady || _cursor != next;
    _cursor = next;
    _cursorReady = true;
    if (changed) {
      notifyListeners();
    }
  }
}
