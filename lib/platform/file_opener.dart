import 'dart:io';

/// Opens files and directories with the operating system's default app.
abstract final class FileOpener {
  static Future<void> open(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FileSystemException('找不到待打开的临时明文文件');
    }
    final path = file.absolute.path;
    if (Platform.isWindows) {
      await Process.start('explorer.exe', <String>[path]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.start('open', <String>[path]);
      return;
    }
    if (Platform.isLinux) {
      await Process.start('xdg-open', <String>[path]);
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
      await Process.start('explorer.exe', <String>[path]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.start('open', <String>[path]);
      return;
    }
    if (Platform.isLinux) {
      await Process.start('xdg-open', <String>[path]);
      return;
    }
    throw UnsupportedError('当前平台不支持直接打开目录');
  }
}
