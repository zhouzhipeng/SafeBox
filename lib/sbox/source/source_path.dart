import '../errors.dart';

/// An untrusted data-source path reduced to one canonical ASCII basename.
final class SourcePath {
  SourcePath(String value) : value = _validate(value);

  final String value;

  List<String> get segments => <String>[value];

  @override
  bool operator ==(Object other) => other is SourcePath && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;

  static String _validate(String input) {
    if (input.isEmpty ||
        input.length > 255 ||
        input.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e) ||
        RegExp(r'[<>:"|?*]').hasMatch(input) ||
        input.contains('/') ||
        input.contains('\\') ||
        input.contains('\u0000') ||
        input.contains('%') ||
        input.endsWith('.') ||
        input.endsWith(' ') ||
        input == '.' ||
        input == '..') {
      throw const SboxException(SboxErrorCode.invalidHeader, '数据源对象路径无效');
    }
    return input;
  }
}
