import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart';

/// Publishes an in-memory plaintext as a short-lived Blob download.
abstract final class BrowserDownload {
  static Future<void> save({
    required Uint8List bytes,
    required String name,
    String? mediaType,
  }) async {
    final blob = Blob(
      <JSUint8Array>[bytes.toJS].toJS,
      BlobPropertyBag(type: mediaType ?? 'application/octet-stream'),
    );
    final objectUrl = URL.createObjectURL(blob);
    final anchor = HTMLAnchorElement()
      ..href = objectUrl
      ..download = _safeFileName(name)
      ..style.display = 'none';
    document.body?.appendChild(anchor);
    anchor.click();
    anchor.remove();

    // Blob construction owns its byte snapshot. Revoke the temporary URL
    // after the click has reached the browser download manager.
    unawaited(
      Future<void>.delayed(
        const Duration(seconds: 1),
        () => URL.revokeObjectURL(objectUrl),
      ),
    );
  }

  static String _safeFileName(String value) {
    final leaf = value.replaceAll('\\', '/').split('/').last.trim();
    final sanitized = leaf.replaceAll(
      RegExp(r'[\u0000-\u001f<>:"/\\|?*]'),
      '_',
    );
    return sanitized.isEmpty ? 'safebox-download.bin' : sanitized;
  }
}
