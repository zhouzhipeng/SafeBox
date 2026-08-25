import 'dart:io';

import 'package:flutter/services.dart';

/// Opens files and directories with the operating system's default app.
abstract final class FileOpener {
  static const MethodChannel _windowsShellChannel = MethodChannel(
    'com.zhouzhipeng.safebox/windows_shell',
  );

  static Future<void> _startDetached(
    String executable,
    List<String> arguments,
  ) async {
    await Process.start(executable, arguments, mode: ProcessStartMode.detached);
  }

  static Future<void> _openWithWindowsShell(String path) async {
    await _windowsShellChannel.invokeMethod<void>('openPath', <String, Object?>{
      'path': path,
    });
  }

  static Future<void> open(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FileSystemException('找不到待打开的临时明文文件');
    }
    final path = file.absolute.path;
    if (Platform.isWindows) {
      await _openWithWindowsShell(path);
      return;
    }
    if (Platform.isMacOS) {
      await _startDetached('open', <String>[path]);
      return;
    }
    if (Platform.isLinux) {
      await _startDetached('xdg-open', <String>[path]);
      return;
    }
    throw UnsupportedError('当前平台不支持直接打开临时文件');
  }

  static Future<void> openDirectory(Directory directory) async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FileSystemException('找不到待打开的目录');
    }
    final path = directory.absolute.path;
    if (Platform.isWindows) {
      await _openWithWindowsShell(path);
      return;
    }
    if (Platform.isMacOS) {
      await _startDetached('open', <String>[path]);
      return;
    }
    if (Platform.isLinux) {
      await _startDetached('xdg-open', <String>[path]);
      return;
    }
    throw UnsupportedError('当前平台不支持直接打开目录');
  }
}
