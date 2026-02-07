import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/remote/trackpad_motion_engine.dart';

void main() {
  group('TrackpadMotionEngine', () {
    test('single pointer uses delta-based relative move', () {
      final engine = TrackpadMotionEngine();
      engine.onPointerDown(1, const Offset(10, 10));

      final actions = engine.onPointerMove(
        1,
        const Offset(12, 13),
        const Offset(2, 3),
      );

      expect(actions.length, 1);
      final move = actions.single as TrackpadMoveAction;
      expect(move.delta.dx, closeTo(2.6, 0.001));
      expect(move.delta.dy, closeTo(3.9, 0.001));
    });

    test('single pointer ignores abnormal jump delta', () {
      final engine = TrackpadMotionEngine();
      engine.onPointerDown(1, const Offset(10, 10));

      final actions = engine.onPointerMove(
        1,
        const Offset(500, 500),
        const Offset(500, 500),
      );

      expect(actions, isEmpty);
    });

    test('single pointer clamps delta to maxRelativeDelta', () {
      final engine = TrackpadMotionEngine(maxPointerJump: 200, maxRelativeDelta: 64);
      engine.onPointerDown(1, const Offset(10, 10));

      final actions = engine.onPointerMove(
        1,
        const Offset(70, 70),
        const Offset(60, 60),
      );

      expect(actions.length, 1);
      final move = actions.single as TrackpadMoveAction;
      expect(move.delta.dx, 64);
      expect(move.delta.dy, 64);
    });

    test('two pointers generate scroll steps with accumulator', () {
      final engine = TrackpadMotionEngine(scrollStep: 12);
      engine.onPointerDown(1, const Offset(0, 0));
      engine.onPointerDown(2, const Offset(0, 10));

      final first = engine.onPointerMove(
        1,
        const Offset(0, 20),
        const Offset(0, 20),
      );
      final second = engine.onPointerMove(
        2,
        const Offset(0, 30),
        const Offset(0, 20),
      );

      expect(first, isEmpty);
      expect(second.length, 1);
      final scroll = second.single as TrackpadScrollAction;
      expect(scroll.deltaY, -12);
    });

    test('retouch does not inherit stale absolute position', () {
      final engine = TrackpadMotionEngine();
      engine.onPointerDown(1, const Offset(0, 0));
      engine.onPointerDown(2, const Offset(0, 10));
      engine.onPointerUp(2);

      final actions = engine.onPointerMove(
        1,
        const Offset(500, 500),
        const Offset(1, 1),
      );

      expect(actions.length, 1);
      final move = actions.single as TrackpadMoveAction;
      expect(move.delta.dx, closeTo(1.3, 0.001));
      expect(move.delta.dy, closeTo(1.3, 0.001));
    });
  });
}
