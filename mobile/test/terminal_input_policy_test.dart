import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/terminal_input_policy.dart';

KeyDownEvent _keyDown({
  required PhysicalKeyboardKey physicalKey,
  required LogicalKeyboardKey logicalKey,
  String? character,
}) {
  return KeyDownEvent(
    timeStamp: Duration.zero,
    physicalKey: physicalKey,
    logicalKey: logicalKey,
    character: character,
  );
}

KeyUpEvent _keyUp({
  required PhysicalKeyboardKey physicalKey,
  required LogicalKeyboardKey logicalKey,
}) {
  return KeyUpEvent(
    timeStamp: Duration.zero,
    physicalKey: physicalKey,
    logicalKey: logicalKey,
  );
}

void main() {
  group('shouldDeferTerminalHardwareKeyToTextInput', () {
    test('defers plain printable ASCII key', () {
      final event = _keyDown(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        character: 'a',
      );

      final shouldDefer = shouldDeferTerminalHardwareKeyToTextInput(
        event,
        ctrlPressed: false,
        altPressed: false,
        metaPressed: false,
      );

      expect(shouldDefer, isTrue);
    });

    test('defers printable CJK key', () {
      final event = _keyDown(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        character: '你',
      );

      final shouldDefer = shouldDeferTerminalHardwareKeyToTextInput(
        event,
        ctrlPressed: false,
        altPressed: false,
        metaPressed: false,
      );

      expect(shouldDefer, isTrue);
    });

    test('does not defer Enter key', () {
      final event = _keyDown(
        physicalKey: PhysicalKeyboardKey.enter,
        logicalKey: LogicalKeyboardKey.enter,
        character: '\n',
      );

      final shouldDefer = shouldDeferTerminalHardwareKeyToTextInput(
        event,
        ctrlPressed: false,
        altPressed: false,
        metaPressed: false,
      );

      expect(shouldDefer, isFalse);
    });

    test('does not defer Ctrl shortcut key', () {
      final event = _keyDown(
        physicalKey: PhysicalKeyboardKey.keyC,
        logicalKey: LogicalKeyboardKey.keyC,
        character: 'c',
      );

      final shouldDefer = shouldDeferTerminalHardwareKeyToTextInput(
        event,
        ctrlPressed: true,
        altPressed: false,
        metaPressed: false,
      );

      expect(shouldDefer, isFalse);
    });

    test('does not defer Alt ASCII shortcut key', () {
      final event = _keyDown(
        physicalKey: PhysicalKeyboardKey.keyB,
        logicalKey: LogicalKeyboardKey.keyB,
        character: 'b',
      );

      final shouldDefer = shouldDeferTerminalHardwareKeyToTextInput(
        event,
        ctrlPressed: false,
        altPressed: true,
        metaPressed: false,
      );

      expect(shouldDefer, isFalse);
    });

    test('defers Alt non-ASCII printable key', () {
      final event = _keyDown(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        character: '你',
      );

      final shouldDefer = shouldDeferTerminalHardwareKeyToTextInput(
        event,
        ctrlPressed: false,
        altPressed: true,
        metaPressed: false,
      );

      expect(shouldDefer, isTrue);
    });

    test('does not defer key up events', () {
      final event = _keyUp(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
      );

      final shouldDefer = shouldDeferTerminalHardwareKeyToTextInput(
        event,
        ctrlPressed: false,
        altPressed: false,
        metaPressed: false,
      );

      expect(shouldDefer, isFalse);
    });
  });
}
