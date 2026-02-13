class TerminalOutputSanitizer {
  static const int _esc = 0x1B;
  static const int _csiIntroducer = 0x5B;
  static const int _singleByteCsi = 0x9B;

  String _carry = '';

  String sanitize(String chunk) {
    if (chunk.isEmpty && _carry.isEmpty) {
      return '';
    }
    final merged = _carry + chunk;
    _carry = '';

    final output = StringBuffer();
    var index = 0;

    while (index < merged.length) {
      final char = merged.codeUnitAt(index);

      if (char == _singleByteCsi) {
        final parsed = _parseCsiBody(merged, index + 1);
        if (!parsed.isComplete) {
          _carry = merged.substring(index);
          break;
        }
        if (!_shouldDropSequence(parsed)) {
          output.write(merged.substring(index, parsed.endIndex));
        }
        index = parsed.endIndex;
        continue;
      }

      if (char != _esc) {
        output.writeCharCode(char);
        index += 1;
        continue;
      }

      if (index + 1 >= merged.length) {
        _carry = merged.substring(index);
        break;
      }

      final next = merged.codeUnitAt(index + 1);
      if (next != _csiIntroducer) {
        output.writeCharCode(char);
        index += 1;
        continue;
      }

      final parsed = _parseCsiBody(merged, index + 2);
      if (!parsed.isComplete) {
        _carry = merged.substring(index);
        break;
      }

      if (!_shouldDropSequence(parsed)) {
        output.write(merged.substring(index, parsed.endIndex));
      }
      index = parsed.endIndex;
    }

    return output.toString();
  }

  void reset() {
    _carry = '';
  }

  _CsiParseResult _parseCsiBody(String source, int bodyStartIndex) {
    var cursor = bodyStartIndex;
    var hasPrivatePrefix = false;

    if (cursor >= source.length) {
      return _CsiParseResult.incomplete();
    }

    final first = source.codeUnitAt(cursor);
    if (_isPrivatePrefix(first)) {
      hasPrivatePrefix = true;
      cursor += 1;
    }

    while (cursor < source.length) {
      final code = source.codeUnitAt(cursor);
      if (code >= 0x40 && code <= 0x7E) {
        return _CsiParseResult(
          isComplete: true,
          endIndex: cursor + 1,
          hasPrivatePrefix: hasPrivatePrefix,
          finalByte: code,
        );
      }
      cursor += 1;
    }

    return _CsiParseResult.incomplete();
  }

  bool _shouldDropSequence(_CsiParseResult parsed) {
    if (!parsed.isComplete) {
      return false;
    }
    final isSgr = parsed.finalByte == 0x6D;
    return isSgr && parsed.hasPrivatePrefix;
  }

  bool _isPrivatePrefix(int code) {
    return code == 0x3C || code == 0x3D || code == 0x3E || code == 0x3F;
  }
}

class _CsiParseResult {
  const _CsiParseResult({
    required this.isComplete,
    this.endIndex = 0,
    this.hasPrivatePrefix = false,
    this.finalByte,
  });

  const _CsiParseResult.incomplete()
    : isComplete = false,
      endIndex = 0,
      hasPrivatePrefix = false,
      finalByte = null;

  final bool isComplete;
  final int endIndex;
  final bool hasPrivatePrefix;
  final int? finalByte;
}
