class RemoteReconnectPolicy {
  RemoteReconnectPolicy({
    this.minBackgroundDuration = const Duration(seconds: 4),
    this.minReconnectInterval = const Duration(seconds: 8),
  });

  final Duration minBackgroundDuration;
  final Duration minReconnectInterval;

  DateTime? _backgroundedAt;
  DateTime? _lastReconnectAt;

  void markBackgrounded(DateTime now) {
    _backgroundedAt ??= now;
  }

  Duration? consumeBackgroundDuration(DateTime now) {
    final backgroundedAt = _backgroundedAt;
    _backgroundedAt = null;
    if (backgroundedAt == null) {
      return null;
    }
    final elapsed = now.difference(backgroundedAt);
    if (elapsed.isNegative) {
      return Duration.zero;
    }
    return elapsed;
  }

  bool shouldReconnectOnResume({
    required Duration backgroundDuration,
    required DateTime now,
  }) {
    if (backgroundDuration < minBackgroundDuration) {
      return false;
    }
    final lastReconnectAt = _lastReconnectAt;
    if (lastReconnectAt == null) {
      return true;
    }
    return now.difference(lastReconnectAt) >= minReconnectInterval;
  }

  void markReconnectAttempt(DateTime now) {
    _lastReconnectAt = now;
  }
}
