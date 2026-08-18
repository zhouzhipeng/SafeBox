import 'errors.dart';

/// Logging contract shared by the platform-independent SBOX code.
///
/// The core must not depend on Flutter so protocol and provider tests can run
/// with the Dart VM on every CI platform.
abstract interface class SboxLogger {
  void info(String title, {String? detail});

  void warning(String title, {String? detail});

  void error(
    Object error, {
    String operation = 'Operation failed',
    String? context,
  });
}

const int maximumSboxLogFieldLength = 600;

/// Removes credentials and strips URLs down to their host before a message
/// is handed to a logger.
String sanitizeSboxLog(
  String value, {
  int maximumLength = maximumSboxLogFieldLength,
}) {
  var result = value.replaceAll('\r', ' ').replaceAll('\n', ' ').trim();
  result = result.replaceAllMapped(
    RegExp(
      r'authorization\s*[:=]\s*(?:bearer|token)\s+[^\s,;]+',
      caseSensitive: false,
    ),
    (_) => 'Authorization=<已隐藏>',
  );
  result = result.replaceAllMapped(
    RegExp(
      r'(mnemonic|seed|bundle[_-]?dek)\s*[:=]\s*[^,;]+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}=<已隐藏>',
  );
  result = result.replaceAllMapped(
    RegExp(
      r'(authorization|token|access[_-]?token|password|secret)\s*[:=]\s*[^\s,;]+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}=<已隐藏>',
  );
  result = result.replaceAllMapped(
    RegExp(r'\bbearer\s+[^\s,;]+', caseSensitive: false),
    (_) => 'Bearer <已隐藏>',
  );
  result = result.replaceAllMapped(
    RegExp(r'https?://[^\s,;]+', caseSensitive: false),
    (match) {
      final uri = Uri.tryParse(match.group(0)!);
      if (uri == null || uri.host.isEmpty) return '<URL 已隐藏>';
      final port = uri.hasPort ? ':${uri.port}' : '';
      return '${uri.scheme}://${uri.host}$port';
    },
  );
  if (result.length > maximumLength) {
    result = '${result.substring(0, maximumLength - 1)}…';
  }
  return result.isEmpty ? '（无附加信息）' : result;
}

/// Describes an error before it is handed to a concrete logger.
///
/// The result is safe for both the Flutter logger and non-UI logger
/// implementations.
String describeSboxError(Object error) {
  if (error is SboxException) {
    return '${error.code.value}: ${sanitizeSboxLog(error.message)}';
  }
  final detail = sanitizeSboxLog(error.toString());
  final type = error.runtimeType.toString();
  return detail == type ? type : '$type: $detail';
}
