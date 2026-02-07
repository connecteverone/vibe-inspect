import 'dart:ui';

class CursorMotionFilter {
  CursorMotionFilter({
    this.jitterRadius = 0.9,
    this.snapDistance = 72.0,
    this.smoothFactor = 0.55,
    this.minVisualDelta = 0.15,
    this.outlierDistance = 320.0,
    this.outlierConfirmRadius = 36.0,
    this.outlierConfirmWindow = const Duration(milliseconds: 220),
  });

  final double jitterRadius;
  final double snapDistance;
  final double smoothFactor;
  final double minVisualDelta;
  final double outlierDistance;
  final double outlierConfirmRadius;
  final Duration outlierConfirmWindow;

  Offset? _raw;
  Offset? _visual;
  Offset? _pendingOutlier;
  DateTime? _pendingOutlierAt;

  Offset? get raw => _raw;
  Offset? get visual => _visual;

  bool clear() {
    final changed = _raw != null || _visual != null || _pendingOutlier != null;
    _raw = null;
    _visual = null;
    _pendingOutlier = null;
    _pendingOutlierAt = null;
    return changed;
  }

  bool update(Offset? nextRaw, {Size? bounds, DateTime? now}) {
    if (nextRaw == null) {
      return clear();
    }
    final clampedRaw = _clamp(nextRaw, bounds);
    final currentRaw = _raw;
    if (currentRaw == null || _visual == null) {
      _raw = clampedRaw;
      _visual = clampedRaw;
      _pendingOutlier = null;
      _pendingOutlierAt = null;
      return true;
    }

    final timestamp = now ?? DateTime.now();
    if (_shouldIgnoreOutlier(currentRaw, clampedRaw, timestamp)) {
      return false;
    }

    _raw = clampedRaw;
    final currentVisual = _visual!;
    final delta = clampedRaw - currentVisual;
    final distance = delta.distance;
    if (distance <= jitterRadius) {
      return false;
    }

    final nextVisual = distance >= snapDistance
        ? clampedRaw
        : _clamp(currentVisual + delta * smoothFactor, bounds);
    if ((nextVisual - currentVisual).distance < minVisualDelta) {
      return false;
    }

    _visual = nextVisual;
    return true;
  }

  Offset _clamp(Offset value, Size? bounds) {
    if (bounds == null || bounds.isEmpty) {
      return value;
    }
    return Offset(
      value.dx.clamp(0, bounds.width - 1).toDouble(),
      value.dy.clamp(0, bounds.height - 1).toDouble(),
    );
  }

  bool _shouldIgnoreOutlier(Offset previous, Offset candidate, DateTime now) {
    final jump = (candidate - previous).distance;
    if (jump < outlierDistance) {
      _pendingOutlier = null;
      _pendingOutlierAt = null;
      return false;
    }

    final pending = _pendingOutlier;
    final pendingAt = _pendingOutlierAt;
    if (pending == null || pendingAt == null) {
      _pendingOutlier = candidate;
      _pendingOutlierAt = now;
      return true;
    }

    final withinWindow = now.difference(pendingAt) <= outlierConfirmWindow;
    final closeToPending =
        (candidate - pending).distance <= outlierConfirmRadius;
    final sameDirection = _isSameDirection(previous, pending, candidate);
    if (withinWindow && (closeToPending || sameDirection)) {
      _pendingOutlier = null;
      _pendingOutlierAt = null;
      return false;
    }

    _pendingOutlier = candidate;
    _pendingOutlierAt = now;
    return true;
  }

  bool _isSameDirection(Offset origin, Offset a, Offset b) {
    final va = a - origin;
    final vb = b - origin;
    final ma = va.distance;
    final mb = vb.distance;
    if (ma < 1 || mb < 1) {
      return false;
    }
    final cosine = (va.dx * vb.dx + va.dy * vb.dy) / (ma * mb);
    return cosine >= 0.7;
  }
}
