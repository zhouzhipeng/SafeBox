/// A bounded JSON parser that rejects duplicate object keys and malformed
/// Unicode before any Catalog domain object is constructed.
final class StrictJsonParser {
  StrictJsonParser(
    this.source, {
    this.maximumDepth = 16,
    this.maximumStringCodeUnits = 16 * 1024 * 1024,
  });

  final String source;
  final int maximumDepth;
  final int maximumStringCodeUnits;
  int _offset = 0;

  Object? parse() {
    _skipWhitespace();
    final result = _parseValue(0);
    _skipWhitespace();
    if (_offset != source.length) {
      throw const FormatException('Trailing JSON content');
    }
    return result;
  }

  Object? _parseValue(int depth) {
    if (depth > maximumDepth || _offset >= source.length) {
      throw const FormatException('Invalid JSON value');
    }
    return switch (source.codeUnitAt(_offset)) {
      0x7b => _parseObject(depth + 1),
      0x5b => _parseArray(depth + 1),
      0x22 => _parseString(),
      0x74 => _parseLiteral('true', true),
      0x66 => _parseLiteral('false', false),
      0x6e => _parseLiteral('null', null),
      _ => _parseNumber(),
    };
  }

  Map<String, Object?> _parseObject(int depth) {
    _offset++;
    _skipWhitespace();
    final result = <String, Object?>{};
    if (_consumeIf(0x7d)) {
      return result;
    }
    while (true) {
      if (_offset >= source.length || source.codeUnitAt(_offset) != 0x22) {
        throw const FormatException('Expected JSON object key');
      }
      final key = _parseString();
      if (result.containsKey(key)) {
        throw const FormatException('Duplicate JSON object key');
      }
      _skipWhitespace();
      _expect(0x3a);
      _skipWhitespace();
      result[key] = _parseValue(depth);
      _skipWhitespace();
      if (_consumeIf(0x7d)) {
        return result;
      }
      _expect(0x2c);
      _skipWhitespace();
    }
  }

  List<Object?> _parseArray(int depth) {
    _offset++;
    _skipWhitespace();
    final result = <Object?>[];
    if (_consumeIf(0x5d)) {
      return result;
    }
    while (true) {
      result.add(_parseValue(depth));
      _skipWhitespace();
      if (_consumeIf(0x5d)) {
        return result;
      }
      _expect(0x2c);
      _skipWhitespace();
    }
  }

  String _parseString() {
    _expect(0x22);
    final result = StringBuffer();
    var written = 0;
    while (_offset < source.length) {
      final codeUnit = source.codeUnitAt(_offset++);
      if (codeUnit == 0x22) {
        return result.toString();
      }
      if (codeUnit < 0x20) {
        throw const FormatException('Unescaped JSON control character');
      }
      if (codeUnit == 0x5c) {
        if (_offset >= source.length) {
          throw const FormatException('Incomplete JSON escape');
        }
        final escape = source.codeUnitAt(_offset++);
        switch (escape) {
          case 0x22:
          case 0x2f:
          case 0x5c:
            result.writeCharCode(escape);
          case 0x62:
            result.writeCharCode(0x08);
          case 0x66:
            result.writeCharCode(0x0c);
          case 0x6e:
            result.writeCharCode(0x0a);
          case 0x72:
            result.writeCharCode(0x0d);
          case 0x74:
            result.writeCharCode(0x09);
          case 0x75:
            final first = _parseHexCodeUnit();
            if (_isHighSurrogate(first)) {
              if (_offset + 1 >= source.length ||
                  source.codeUnitAt(_offset) != 0x5c ||
                  source.codeUnitAt(_offset + 1) != 0x75) {
                throw const FormatException('Unpaired JSON surrogate');
              }
              _offset += 2;
              final second = _parseHexCodeUnit();
              if (!_isLowSurrogate(second)) {
                throw const FormatException('Unpaired JSON surrogate');
              }
              result
                ..writeCharCode(first)
                ..writeCharCode(second);
              written += 2;
              continue;
            }
            if (_isLowSurrogate(first)) {
              throw const FormatException('Unpaired JSON surrogate');
            }
            result.writeCharCode(first);
          default:
            throw const FormatException('Invalid JSON escape');
        }
      } else {
        if (_isHighSurrogate(codeUnit)) {
          if (_offset >= source.length ||
              !_isLowSurrogate(source.codeUnitAt(_offset))) {
            throw const FormatException('Unpaired Unicode surrogate');
          }
          result
            ..writeCharCode(codeUnit)
            ..writeCharCode(source.codeUnitAt(_offset++));
          written += 2;
          continue;
        }
        if (_isLowSurrogate(codeUnit)) {
          throw const FormatException('Unpaired Unicode surrogate');
        }
        result.writeCharCode(codeUnit);
      }
      written++;
      if (written > maximumStringCodeUnits) {
        throw const FormatException('JSON string exceeds limit');
      }
    }
    throw const FormatException('Unterminated JSON string');
  }

  int _parseHexCodeUnit() {
    if (_offset + 4 > source.length) {
      throw const FormatException('Incomplete Unicode escape');
    }
    var value = 0;
    for (var index = 0; index < 4; index++) {
      final codeUnit = source.codeUnitAt(_offset++);
      final digit = switch (codeUnit) {
        >= 0x30 && <= 0x39 => codeUnit - 0x30,
        >= 0x41 && <= 0x46 => codeUnit - 0x41 + 10,
        >= 0x61 && <= 0x66 => codeUnit - 0x61 + 10,
        _ => -1,
      };
      if (digit < 0) {
        throw const FormatException('Invalid Unicode escape');
      }
      value = (value << 4) | digit;
    }
    return value;
  }

  Object? _parseLiteral(String token, Object? value) {
    if (!source.startsWith(token, _offset)) {
      throw const FormatException('Invalid JSON literal');
    }
    _offset += token.length;
    return value;
  }

  num _parseNumber() {
    final start = _offset;
    _consumeIf(0x2d);
    if (_offset >= source.length) {
      throw const FormatException('Invalid JSON number');
    }
    if (_consumeIf(0x30)) {
      if (_offset < source.length && _isDigit(source.codeUnitAt(_offset))) {
        throw const FormatException('Leading zero in JSON number');
      }
    } else {
      if (!_isDigitOneToNine(source.codeUnitAt(_offset))) {
        throw const FormatException('Invalid JSON number');
      }
      while (_offset < source.length && _isDigit(source.codeUnitAt(_offset))) {
        _offset++;
      }
    }
    var isInteger = true;
    if (_consumeIf(0x2e)) {
      isInteger = false;
      if (_offset >= source.length || !_isDigit(source.codeUnitAt(_offset))) {
        throw const FormatException('Invalid JSON fraction');
      }
      while (_offset < source.length && _isDigit(source.codeUnitAt(_offset))) {
        _offset++;
      }
    }
    if (_offset < source.length &&
        (source.codeUnitAt(_offset) == 0x65 ||
            source.codeUnitAt(_offset) == 0x45)) {
      isInteger = false;
      _offset++;
      if (_offset < source.length &&
          (source.codeUnitAt(_offset) == 0x2b ||
              source.codeUnitAt(_offset) == 0x2d)) {
        _offset++;
      }
      if (_offset >= source.length || !_isDigit(source.codeUnitAt(_offset))) {
        throw const FormatException('Invalid JSON exponent');
      }
      while (_offset < source.length && _isDigit(source.codeUnitAt(_offset))) {
        _offset++;
      }
    }
    final token = source.substring(start, _offset);
    if (token.length > 64) {
      throw const FormatException('JSON number exceeds limit');
    }
    if (isInteger) {
      return int.parse(token);
    }
    final value = double.parse(token);
    if (!value.isFinite) {
      throw const FormatException('Non-finite JSON number');
    }
    return value;
  }

  void _skipWhitespace() {
    while (_offset < source.length) {
      final codeUnit = source.codeUnitAt(_offset);
      if (codeUnit == 0x20 ||
          codeUnit == 0x09 ||
          codeUnit == 0x0a ||
          codeUnit == 0x0d) {
        _offset++;
      } else {
        return;
      }
    }
  }

  void _expect(int codeUnit) {
    if (!_consumeIf(codeUnit)) {
      throw const FormatException('Unexpected JSON token');
    }
  }

  bool _consumeIf(int codeUnit) {
    if (_offset < source.length && source.codeUnitAt(_offset) == codeUnit) {
      _offset++;
      return true;
    }
    return false;
  }

  static bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

  static bool _isDigitOneToNine(int codeUnit) =>
      codeUnit >= 0x31 && codeUnit <= 0x39;

  static bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xd800 && codeUnit <= 0xdbff;

  static bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xdc00 && codeUnit <= 0xdfff;
}
