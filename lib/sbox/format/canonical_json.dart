import 'dart:convert';
import 'dart:typed_data';

/// Small RFC 8785-compatible canonical JSON writer for the integer-only
/// manifest domain.
abstract final class CanonicalJson {
  static String encode(Object? value) {
    final output = StringBuffer();
    _writeValue(output, value);
    return output.toString();
  }

  static Uint8List encodeUtf8(Object? value) =>
      Uint8List.fromList(utf8.encode(encode(value)));

  static void _writeValue(StringBuffer output, Object? value) {
    switch (value) {
      case null:
        output.write('null');
      case bool():
        output.write(value ? 'true' : 'false');
      case int():
        output.write(value.toString());
      case String():
        _writeString(output, value);
      case List<Object?>():
        output.write('[');
        for (var index = 0; index < value.length; index++) {
          if (index != 0) output.write(',');
          _writeValue(output, value[index]);
        }
        output.write(']');
      case Map<String, Object?>():
        final keys = value.keys.toList()..sort(_compareUtf16);
        output.write('{');
        for (var index = 0; index < keys.length; index++) {
          if (index != 0) output.write(',');
          final key = keys[index];
          _writeString(output, key);
          output.write(':');
          _writeValue(output, value[key]);
        }
        output.write('}');
      default:
        throw const FormatException('Unsupported JSON value');
    }
  }

  static void _writeString(StringBuffer output, String value) {
    output.write('"');
    for (final rune in value.runes) {
      switch (rune) {
        case 0x08:
          output.write(r'\b');
        case 0x09:
          output.write(r'\t');
        case 0x0a:
          output.write(r'\n');
        case 0x0c:
          output.write(r'\f');
        case 0x0d:
          output.write(r'\r');
        case 0x22:
          output.write(r'\"');
        case 0x5c:
          output.write(r'\\');
        default:
          if (rune < 0x20) {
            output
              ..write(r'\u00')
              ..write(rune.toRadixString(16).padLeft(2, '0'));
          } else {
            output.writeCharCode(rune);
          }
      }
    }
    output.write('"');
  }

  static int _compareUtf16(String left, String right) {
    final a = left.codeUnits;
    final b = right.codeUnits;
    final length = a.length < b.length ? a.length : b.length;
    for (var index = 0; index < length; index++) {
      final comparison = a[index].compareTo(b[index]);
      if (comparison != 0) return comparison;
    }
    return a.length.compareTo(b.length);
  }
}
