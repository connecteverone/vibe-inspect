import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/remote/trackpad_scroll_behavior.dart';

void main() {
  group('TrackpadScrollBehavior', () {
    test('followHost uses host natural scroll when available', () {
      const natural = TrackpadScrollBehavior(
        mode: TrackpadScrollMode.followHost,
        hostNaturalScroll: true,
      );
      const classic = TrackpadScrollBehavior(
        mode: TrackpadScrollMode.followHost,
        hostNaturalScroll: false,
      );

      expect(natural.transformDeltaY(12), -12);
      expect(classic.transformDeltaY(12), 12);
    });

    test('natural and classic force direction explicitly', () {
      const natural = TrackpadScrollBehavior(mode: TrackpadScrollMode.natural);
      const classic = TrackpadScrollBehavior(mode: TrackpadScrollMode.classic);

      expect(natural.transformDeltaY(-8), 8);
      expect(classic.transformDeltaY(-8), -8);
    });
  });
}
