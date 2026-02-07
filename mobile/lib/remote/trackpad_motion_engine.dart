import 'dart:ui';

abstract class TrackpadAction {
  const TrackpadAction();
}

class TrackpadMoveAction extends TrackpadAction {
  const TrackpadMoveAction(this.delta);

  final Offset delta;
}

class TrackpadScrollAction extends TrackpadAction {
  const TrackpadScrollAction(this.deltaY);

  final double deltaY;
}

class TrackpadMotionEngine {
  TrackpadMotionEngine({
    this.moveScale = 1.3,
    this.scrollStep = 12,
    this.maxPointerJump = 128,
    this.maxRelativeDelta = 64,
  });

  final double moveScale;
  final double scrollStep;
  final double maxPointerJump;
  final double maxRelativeDelta;

  final Map<int, Offset> _pointers = <int, Offset>{};
  Offset? _lastMultiFinger;
  double _scrollAccumulator = 0;

  void onPointerDown(int pointer, Offset localPosition) {
    _pointers[pointer] = localPosition;
    if (_pointers.length == 1) {
      _lastMultiFinger = null;
      _scrollAccumulator = 0;
    } else if (_pointers.length >= 2) {
      _lastMultiFinger = _averagePointerPosition();
    }
  }

  List<TrackpadAction> onPointerMove(
    int pointer,
    Offset localPosition,
    Offset delta,
  ) {
    if (!_pointers.containsKey(pointer)) {
      return const <TrackpadAction>[];
    }
    _pointers[pointer] = localPosition;

    if (_pointers.length >= 2) {
      final average = _averagePointerPosition();
      final last = _lastMultiFinger;
      _lastMultiFinger = average;
      if (last == null) {
        return const <TrackpadAction>[];
      }
      final averageDelta = average - last;
      if (averageDelta.distance > maxPointerJump || averageDelta.dy == 0) {
        return const <TrackpadAction>[];
      }
      _scrollAccumulator += -averageDelta.dy;
      final actions = <TrackpadAction>[];
      while (_scrollAccumulator.abs() >= scrollStep) {
        final direction = _scrollAccumulator.isNegative ? -1.0 : 1.0;
        actions.add(TrackpadScrollAction(direction * scrollStep));
        _scrollAccumulator -= direction * scrollStep;
      }
      return actions;
    }

    if (_pointers.length == 1) {
      if (delta.distance == 0 || delta.distance > maxPointerJump) {
        return const <TrackpadAction>[];
      }
      final scaled = delta * moveScale;
      final clamped = Offset(
        scaled.dx.clamp(-maxRelativeDelta, maxRelativeDelta).toDouble(),
        scaled.dy.clamp(-maxRelativeDelta, maxRelativeDelta).toDouble(),
      );
      if (clamped == Offset.zero) {
        return const <TrackpadAction>[];
      }
      return <TrackpadAction>[TrackpadMoveAction(clamped)];
    }

    return const <TrackpadAction>[];
  }

  void onPointerUp(int pointer) {
    _pointers.remove(pointer);
    if (_pointers.length <= 1) {
      _lastMultiFinger = null;
      return;
    }
    _lastMultiFinger = _averagePointerPosition();
  }

  void onPointerCancel(int pointer) {
    _pointers.remove(pointer);
    if (_pointers.length <= 1) {
      _lastMultiFinger = null;
      return;
    }
    _lastMultiFinger = _averagePointerPosition();
  }

  void reset() {
    _pointers.clear();
    _lastMultiFinger = null;
    _scrollAccumulator = 0;
  }

  Offset _averagePointerPosition() {
    if (_pointers.isEmpty) {
      return Offset.zero;
    }
    var sum = Offset.zero;
    for (final position in _pointers.values) {
      sum += position;
    }
    return sum / _pointers.length.toDouble();
  }
}
