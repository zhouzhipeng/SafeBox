import 'package:path/path.dart' as p;

import '../errors.dart';

/// A validated, NFC-independent ASCII protocol path relative to a data-source
/// root. It can never represent an absolute path or traversal.
final class SourcePath {
  SourcePath(String value) : value = _validate(value);

  final String value;

  List<String> get segments => value.split('/');

  @override
  bool operator ==(Object other) => other is SourcePath && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;

  static String _validate(String input) {
    var containsEncodedBypass = true;
    try {
      containsEncodedBypass = Uri.decodeComponent(input) != input;
    } on FormatException {
      containsEncodedBypass = true;
    }
    if (input.isEmpty ||
        input.startsWith('/') ||
        input.endsWith('/') ||
        input.contains('\\') ||
        input.contains('\u0000') ||
        containsEncodedBypass) {
      throw _pathError();
    }
    final segments = input.split('/');
    if (segments.any(
      (segment) => segment.isEmpty || segment == '.' || segment == '..',
    )) {
      throw _pathError();
    }
    final platformNormalized = p.posix.normalize(input);
    if (platformNormalized != input || p.posix.isAbsolute(input)) {
      throw _pathError();
    }
    return input;
  }

  static SboxException _pathError() =>
      const SboxException(SboxErrorCode.catalog, '数据源相对路径无效');
}
