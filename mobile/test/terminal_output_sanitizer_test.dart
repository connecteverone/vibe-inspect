import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/terminal_output_sanitizer.dart';

void main() {
  group('TerminalOutputSanitizer', () {
    test('strips private-prefixed SGR sequences', () {
      final sanitizer = TerminalOutputSanitizer();
      final raw = 'before\x1b[>4;1mafter\x1b[>4mend';

      final sanitized = sanitizer.sanitize(raw);

      expect(sanitized, 'beforeafterend');
    });

    test('keeps regular SGR sequences intact', () {
      final sanitizer = TerminalOutputSanitizer();
      final raw = 'x\x1b[31mred\x1b[0my';

      final sanitized = sanitizer.sanitize(raw);

      expect(sanitized, raw);
    });

    test('keeps delimiter-led SGR sequences intact', () {
      final sanitizer = TerminalOutputSanitizer();
      final raw = 'x\x1b[;31mred\x1b[0my';

      final sanitized = sanitizer.sanitize(raw);

      expect(sanitized, raw);
    });

    test('handles split private-prefixed SGR sequence across chunks', () {
      final sanitizer = TerminalOutputSanitizer();

      final first = sanitizer.sanitize('left\x1b[>4;');
      final second = sanitizer.sanitize('1mright');

      expect(first, 'left');
      expect(second, 'right');
    });

    test('strips question-prefixed SGR sequences', () {
      final sanitizer = TerminalOutputSanitizer();
      final raw = 'a\x1b[?1mb';

      final sanitized = sanitizer.sanitize(raw);

      expect(sanitized, 'ab');
    });

    test('strips less-than-prefixed SGR sequences', () {
      final sanitizer = TerminalOutputSanitizer();
      final raw = 'a\x1b[<1mb';

      final sanitized = sanitizer.sanitize(raw);

      expect(sanitized, 'ab');
    });

    test('keeps split non-SGR private CSI sequences', () {
      final sanitizer = TerminalOutputSanitizer();

      final first = sanitizer.sanitize('a\x1b[?200');
      final second = sanitizer.sanitize('4hb');

      expect(first, 'a');
      expect(second, '\x1b[?2004hb');
    });

    test('strips single-byte CSI private SGR sequences', () {
      final sanitizer = TerminalOutputSanitizer();
      final raw = 'a\u009b>4;1mb';

      final sanitized = sanitizer.sanitize(raw);

      expect(sanitized, 'ab');
    });

    test('keeps private-prefixed non-SGR CSI sequences', () {
      final sanitizer = TerminalOutputSanitizer();
      final raw = 'a\x1b[?2004hb\x1b[>1uc';

      final sanitized = sanitizer.sanitize(raw);

      expect(sanitized, raw);
    });
  });
}
