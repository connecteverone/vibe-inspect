import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/remote/cursor_motion_filter.dart';

void main() {
  group('CursorMotionFilter', () {
    test('initial sample sets raw and visual cursor', () {
      final filter = CursorMotionFilter();
      final changed = filter.update(const Offset(100, 80));

      expect(changed, isTrue);
      expect(filter.raw, const Offset(100, 80));
      expect(filter.visual, const Offset(100, 80));
    });

    test('suppresses sub-pixel jitter updates', () {
      final filter = CursorMotionFilter(jitterRadius: 1.0);
      final t0 = DateTime.utc(2026, 2, 7, 9, 0, 0);
      filter.update(const Offset(200, 200), now: t0);

      final changed = filter.update(
        const Offset(200.5, 200.4),
        now: t0.add(const Duration(milliseconds: 16)),
      );

      expect(changed, isFalse);
      expect(filter.visual, const Offset(200, 200));
    });

    test('drops one-off large jump and accepts confirmed jump', () {
      final filter = CursorMotionFilter(
        outlierDistance: 120,
        outlierConfirmRadius: 24,
      );
      final t0 = DateTime.utc(2026, 2, 7, 9, 0, 0);
      filter.update(const Offset(300, 300), now: t0);

      final firstJump = filter.update(
        const Offset(560, 580),
        now: t0.add(const Duration(milliseconds: 16)),
      );
      expect(firstJump, isFalse);
      expect(filter.visual, const Offset(300, 300));

      final confirmedJump = filter.update(
        const Offset(565, 584),
        now: t0.add(const Duration(milliseconds: 32)),
      );
      expect(confirmedJump, isTrue);
      expect(filter.visual, isNot(const Offset(300, 300)));
      expect(filter.visual!.dx, greaterThan(500));
    });

    test('ignores bounce-back outlier inside smooth movement', () {
      final filter = CursorMotionFilter(
        outlierDistance: 80,
        snapDistance: 999,
        smoothFactor: 1,
      );
      final t0 = DateTime.utc(2026, 2, 7, 9, 0, 0);
      filter.update(const Offset(100, 100), now: t0);
      filter.update(
        const Offset(110, 108),
        now: t0.add(const Duration(milliseconds: 16)),
      );

      final outlierIgnored = filter.update(
        const Offset(400, 420),
        now: t0.add(const Duration(milliseconds: 32)),
      );
      expect(outlierIgnored, isFalse);
      expect(filter.visual, const Offset(110, 108));

      final resumed = filter.update(
        const Offset(116, 114),
        now: t0.add(const Duration(milliseconds: 48)),
      );
      expect(resumed, isTrue);
      expect(filter.visual, const Offset(116, 114));
    });

    test('clear removes raw and visual cursor state', () {
      final filter = CursorMotionFilter();
      filter.update(const Offset(60, 40));

      final cleared = filter.clear();

      expect(cleared, isTrue);
      expect(filter.raw, isNull);
      expect(filter.visual, isNull);
    });
  });
}
