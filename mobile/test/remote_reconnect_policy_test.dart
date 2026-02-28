import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/remote/remote_reconnect_policy.dart';

void main() {
  group('RemoteReconnectPolicy', () {
    test('returns null when no background marker exists', () {
      final policy = RemoteReconnectPolicy();
      final duration = policy.consumeBackgroundDuration(DateTime(2026, 2, 28));
      expect(duration, isNull);
    });

    test('tracks elapsed background duration', () {
      final policy = RemoteReconnectPolicy();
      final start = DateTime(2026, 2, 28, 10, 0, 0);
      final resume = DateTime(2026, 2, 28, 10, 0, 7);

      policy.markBackgrounded(start);
      final duration = policy.consumeBackgroundDuration(resume);

      expect(duration, const Duration(seconds: 7));
    });

    test('reconnect requires minimum background duration', () {
      final policy = RemoteReconnectPolicy(
        minBackgroundDuration: const Duration(seconds: 4),
      );
      final now = DateTime(2026, 2, 28, 10, 0, 0);

      expect(
        policy.shouldReconnectOnResume(
          backgroundDuration: const Duration(seconds: 3),
          now: now,
        ),
        isFalse,
      );
      expect(
        policy.shouldReconnectOnResume(
          backgroundDuration: const Duration(seconds: 4),
          now: now,
        ),
        isTrue,
      );
    });

    test('reconnect attempts are throttled by minimum interval', () {
      final policy = RemoteReconnectPolicy(
        minBackgroundDuration: const Duration(seconds: 2),
        minReconnectInterval: const Duration(seconds: 8),
      );
      final first = DateTime(2026, 2, 28, 10, 0, 0);
      final second = first.add(const Duration(seconds: 5));
      final third = first.add(const Duration(seconds: 9));

      expect(
        policy.shouldReconnectOnResume(
          backgroundDuration: const Duration(seconds: 3),
          now: first,
        ),
        isTrue,
      );
      policy.markReconnectAttempt(first);

      expect(
        policy.shouldReconnectOnResume(
          backgroundDuration: const Duration(seconds: 3),
          now: second,
        ),
        isFalse,
      );
      expect(
        policy.shouldReconnectOnResume(
          backgroundDuration: const Duration(seconds: 3),
          now: third,
        ),
        isTrue,
      );
    });
  });
}
