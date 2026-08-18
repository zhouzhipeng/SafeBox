import 'dart:io';

import 'package:flutter/services.dart';

/// Applies the native privacy flags available on mobile and macOS. Desktop
/// platforms keep the directory below the per-user system temp directory.
abstract final class TemporaryPlaintextPlatform {
  static const MethodChannel _channel = MethodChannel(
    'com.zhouzhipeng.safebox/authorized_directory',
  );

  static Future<void> protectRoot(String path) async {
    if (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS) return;
    await _channel.invokeMethod<void>(
      'protectTemporaryPlaintext',
      <String, Object?>{'path': path},
    );
  }
}
