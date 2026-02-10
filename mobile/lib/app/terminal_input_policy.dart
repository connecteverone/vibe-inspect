import 'package:flutter/services.dart';

final Set<LogicalKeyboardKey> _imeHardHandledKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.tab,
  LogicalKeyboardKey.escape,
  LogicalKeyboardKey.backspace,
  LogicalKeyboardKey.delete,
  LogicalKeyboardKey.insert,
  LogicalKeyboardKey.home,
  LogicalKeyboardKey.end,
  LogicalKeyboardKey.pageUp,
  LogicalKeyboardKey.pageDown,
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
};

bool shouldDeferTerminalHardwareKeyToTextInput(
  KeyEvent event, {
  required bool ctrlPressed,
  required bool altPressed,
  required bool metaPressed,
}) {
  if (event is KeyUpEvent) {
    return false;
  }
  final key = event.logicalKey;
  if (_imeHardHandledKeys.contains(key)) {
    return false;
  }

  final character = event.character;
  if (!_containsInsertableRune(character)) {
    return false;
  }

  if (ctrlPressed || metaPressed) {
    return false;
  }

  if (altPressed && !_containsNonAsciiInsertableRune(character!)) {
    return false;
  }

  return true;
}

bool _containsInsertableRune(String? text) {
  if (text == null || text.isEmpty) {
    return false;
  }
  for (final rune in text.runes) {
    if (_isIgnorableJoinerOrVariationSelector(rune)) {
      continue;
    }
    if (_isControlRune(rune)) {
      continue;
    }
    return true;
  }
  return false;
}

bool _containsNonAsciiInsertableRune(String text) {
  for (final rune in text.runes) {
    if (_isIgnorableJoinerOrVariationSelector(rune)) {
      continue;
    }
    if (_isControlRune(rune)) {
      continue;
    }
    if (rune > 0x7F) {
      return true;
    }
  }
  return false;
}

bool _isControlRune(int rune) {
  return rune < 0x20 || rune == 0x7F;
}

bool _isIgnorableJoinerOrVariationSelector(int rune) {
  return rune == 0x200D || (rune >= 0xFE00 && rune <= 0xFE0F);
}
