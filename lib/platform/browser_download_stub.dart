import 'dart:typed_data';

abstract final class BrowserDownload {
  static Future<void> save({
    required Uint8List bytes,
    required String name,
    String? mediaType,
  }) => throw UnsupportedError('Browser downloads are available on Web only');
}
