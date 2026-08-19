import 'dart:io';

import 'package:path/path.dart' as p;

import '../errors.dart';
import '../format/bundle_manifest.dart';

/// The application-owned directory for plaintext that has passed a complete
/// Bundle verification. It deliberately lives below the operating system
/// temporary directory and is never used for ciphertext storage.
final class TemporaryPlaintextStore {
  TemporaryPlaintextStore({Directory? root})
    : root =
          root ??
          Directory(
            p.join(
              Directory.systemTemp.path,
              defaultDirectoryName,
              'plaintext',
            ),
          );

  static const String markerName = '.sbox-managed-temp-v3';
  static const String defaultDirectoryName = 'SafeBox';

  final Directory root;

  String get path => p.normalize(p.absolute(root.path));

  /// Ensures that the managed cache root exists and returns its canonical path.
  Future<Directory> ensureRoot() async => Directory(await _ensureReady());

  /// Deletes the entire application-owned plaintext cache root.
  ///
  /// The root must already carry a SafeBox management marker and remain below
  /// the operating system temporary directory. A missing root is a no-op.
  Future<void> deleteRoot() async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    final canonicalRoot = await _ensureReady();
    await _deleteTreeNoFollow(Directory(canonicalRoot));
  }

  Future<File> fileFor(BundleManifest manifest) async {
    final canonicalRoot = await _ensureReady();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(manifest.bundleId)) {
      throw const SboxException(SboxErrorCode.temporaryCleanup, '临时明文目标标识无效');
    }
    final bundleDirectory = Directory(p.join(canonicalRoot, manifest.bundleId));
    final directoryType = await FileSystemEntity.type(
      bundleDirectory.path,
      followLinks: false,
    );
    if (directoryType == FileSystemEntityType.notFound) {
      await bundleDirectory.create(recursive: true);
    } else if (directoryType != FileSystemEntityType.directory ||
        !_samePath(
          p.normalize(await bundleDirectory.resolveSymbolicLinks()),
          bundleDirectory.path,
        )) {
      throw const SboxException(
        SboxErrorCode.temporaryCleanup,
        '临时明文 Bundle 目录无效',
      );
    }
    final file = File(
      p.join(bundleDirectory.path, _sanitizeFileName(manifest.originalName)),
    );
    _validateManagedFilePath(file.path, canonicalRoot);
    return file;
  }

  /// Returns whether [file] is an available managed plaintext cache entry.
  ///
  /// This deliberately checks only the managed path, file type and expected
  /// length. Cached plaintext is never hashed during startup or before open.
  Future<bool> isAvailable(File file, BundleManifest manifest) async {
    final canonicalRoot = await _ensureReady();
    _validateManagedFilePath(file.path, canonicalRoot);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    try {
      if (BigInt.from(await file.length()) != manifest.logicalPlaintextSize) {
        return false;
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Deletes one regular cached file, but never follows or deletes a link.
  Future<void> deleteFile(File file) async {
    final canonicalRoot = await _ensureReady();
    _validateManagedFilePath(file.path, canonicalRoot);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) {
      throw const SboxException(SboxErrorCode.temporaryCleanup, '临时明文目标不是普通文件');
    }
    await file.delete();
  }

  Future<TemporaryPlaintextStats> stats() async {
    final canonicalRoot = await _ensureReady();
    var fileCount = 0;
    var totalBytes = 0;
    DateTime? earliest;
    DateTime? latest;
    final rootDirectory = Directory(canonicalRoot);
    await for (final entity in rootDirectory.list(
      followLinks: false,
      recursive: true,
    )) {
      if (p.basename(entity.path) == markerName ||
          p.basename(entity.path).endsWith('.part') ||
          await FileSystemEntity.type(entity.path, followLinks: false) !=
              FileSystemEntityType.file) {
        continue;
      }
      final parent = p.dirname(entity.path);
      if (!_isBundleDirectory(parent, canonicalRoot)) continue;
      final file = File(entity.path);
      final stat = await file.stat();
      fileCount++;
      totalBytes += stat.size;
      earliest = earliest == null || stat.modified.isBefore(earliest)
          ? stat.modified
          : earliest;
      latest = latest == null || stat.modified.isAfter(latest)
          ? stat.modified
          : latest;
    }
    return TemporaryPlaintextStats(
      fileCount: fileCount,
      totalBytes: totalBytes,
      earliest: earliest,
      latest: latest,
    );
  }

  Future<TemporaryCleanupReport> clearAll() async {
    final canonicalRoot = await _ensureReady();
    var deletedFiles = 0;
    var deletedBytes = 0;
    final failedPaths = <String>[];
    final rootDirectory = Directory(canonicalRoot);
    await for (final entity in rootDirectory.list(followLinks: false)) {
      if (p.basename(entity.path) == markerName) continue;
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type != FileSystemEntityType.directory ||
          !_isBundleDirectory(entity.path, canonicalRoot)) {
        failedPaths.add(entity.path);
        continue;
      }
      try {
        final counts = await _countRegularFiles(Directory(entity.path));
        await _deleteTreeNoFollow(Directory(entity.path));
        deletedFiles += counts.fileCount;
        deletedBytes += counts.totalBytes;
      } on FileSystemException {
        failedPaths.add(entity.path);
      }
    }
    return TemporaryCleanupReport(
      deletedFiles: deletedFiles,
      deletedBytes: deletedBytes,
      failedPaths: List<String>.unmodifiable(failedPaths),
    );
  }

  Future<String> _ensureReady() async {
    final expected = path;
    final initialType = await FileSystemEntity.type(
      expected,
      followLinks: false,
    );
    if (initialType == FileSystemEntityType.link) {
      throw const SboxException(
        SboxErrorCode.temporaryCleanup,
        '临时明文目录不能是符号链接',
      );
    }
    final prospective = await _prospectiveCanonicalPath(root);
    _rejectBroadRoot(prospective);
    final systemTemp = p.normalize(
      await Directory.systemTemp.resolveSymbolicLinks(),
    );
    if (_samePath(systemTemp, prospective) ||
        !_isWithin(systemTemp, prospective)) {
      throw const SboxException(
        SboxErrorCode.temporaryCleanup,
        '临时明文目录必须位于系统临时目录内',
      );
    }
    await root.create(recursive: true);
    if (await FileSystemEntity.type(expected, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const SboxException(SboxErrorCode.temporaryCleanup, '临时明文目录不是普通目录');
    }
    final resolved = p.normalize(await root.resolveSymbolicLinks());
    if (!_samePath(resolved, prospective)) {
      throw const SboxException(SboxErrorCode.temporaryCleanup, '临时明文目录边界发生变化');
    }
    final marker = File(p.join(resolved, markerName));
    final markerType = await FileSystemEntity.type(
      marker.path,
      followLinks: false,
    );
    if (markerType == FileSystemEntityType.notFound) {
      await marker.writeAsString(
        'SafeBox managed temporary plaintext directory\n',
        flush: true,
      );
    } else if (markerType != FileSystemEntityType.file) {
      throw const SboxException(SboxErrorCode.temporaryCleanup, '临时明文目录标记无效');
    }
    return resolved;
  }

  static Future<String> _prospectiveCanonicalPath(Directory directory) async {
    final absolute = p.normalize(p.absolute(directory.path));
    var cursor = Directory(absolute);
    final suffix = <String>[];
    while (!await cursor.exists()) {
      final parent = cursor.parent;
      if (_samePath(parent.path, cursor.path)) {
        throw const SboxException(
          SboxErrorCode.temporaryCleanup,
          '无法解析临时明文目录边界',
        );
      }
      suffix.add(p.basename(cursor.path));
      cursor = parent;
    }
    final resolvedParent = await cursor.resolveSymbolicLinks();
    return p.normalize(p.joinAll(<String>[resolvedParent, ...suffix.reversed]));
  }

  void _validateManagedFilePath(String value, String canonicalRoot) {
    final normalized = p.normalize(p.absolute(value));
    final parent = p.dirname(normalized);
    if (!_isWithin(canonicalRoot, normalized) ||
        !_isBundleDirectory(parent, canonicalRoot)) {
      throw const SboxException(
        SboxErrorCode.temporaryCleanup,
        '临时明文文件不在受管理目录内',
      );
    }
  }

  static bool _isBundleDirectory(String value, String canonicalRoot) {
    final normalized = p.normalize(p.absolute(value));
    return _samePath(p.dirname(normalized), canonicalRoot) &&
        RegExp(r'^[0-9a-f]{32}$').hasMatch(p.basename(normalized));
  }

  static bool _isWithin(String root, String value) {
    final normalizedRoot = p.normalize(p.absolute(root));
    final normalizedValue = p.normalize(p.absolute(value));
    if (Platform.isWindows) {
      return p.isWithin(
        normalizedRoot.toLowerCase(),
        normalizedValue.toLowerCase(),
      );
    }
    return p.isWithin(normalizedRoot, normalizedValue);
  }

  static bool _samePath(String left, String right) {
    final normalizedLeft = p.normalize(p.absolute(left));
    final normalizedRight = p.normalize(p.absolute(right));
    return Platform.isWindows
        ? normalizedLeft.toLowerCase() == normalizedRight.toLowerCase()
        : normalizedLeft == normalizedRight;
  }

  static void _rejectBroadRoot(String value) {
    final normalized = p.normalize(p.absolute(value));
    if (p.dirname(normalized) == normalized) {
      throw const SboxException(
        SboxErrorCode.temporaryCleanup,
        '禁止把磁盘根目录用作临时明文目录',
      );
    }
    final home =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (home != null && _samePath(normalized, home)) {
      throw const SboxException(
        SboxErrorCode.temporaryCleanup,
        '禁止把用户主目录用作临时明文目录',
      );
    }
  }

  static String _sanitizeFileName(String original) {
    var value = original
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (value.isEmpty || value == '.' || value == '..') {
      value = 'decrypted-file';
    }
    const reserved = <String>{
      'CON',
      'PRN',
      'AUX',
      'NUL',
      'COM1',
      'COM2',
      'COM3',
      'COM4',
      'COM5',
      'COM6',
      'COM7',
      'COM8',
      'COM9',
      'LPT1',
      'LPT2',
      'LPT3',
      'LPT4',
      'LPT5',
      'LPT6',
      'LPT7',
      'LPT8',
      'LPT9',
    };
    if (reserved.contains(value.split('.').first.toUpperCase())) {
      value = '_$value';
    }
    final runes = value.runes.toList(growable: false);
    if (runes.length > 180) {
      value = String.fromCharCodes(runes.take(180));
    }
    return value;
  }
}

final class TemporaryPlaintextStats {
  const TemporaryPlaintextStats({
    required this.fileCount,
    required this.totalBytes,
    this.earliest,
    this.latest,
  });

  final int fileCount;
  final int totalBytes;
  final DateTime? earliest;
  final DateTime? latest;
}

final class TemporaryCleanupReport {
  const TemporaryCleanupReport({
    required this.deletedFiles,
    required this.deletedBytes,
    required this.failedPaths,
  });

  final int deletedFiles;
  final int deletedBytes;
  final List<String> failedPaths;

  bool get isComplete => failedPaths.isEmpty;
}

final class _FileCounts {
  const _FileCounts(this.fileCount, this.totalBytes);

  final int fileCount;
  final int totalBytes;
}

Future<_FileCounts> _countRegularFiles(Directory directory) async {
  var fileCount = 0;
  var totalBytes = 0;
  await for (final entity in directory.list(
    followLinks: false,
    recursive: true,
  )) {
    if (await FileSystemEntity.type(entity.path, followLinks: false) !=
        FileSystemEntityType.file) {
      continue;
    }
    fileCount++;
    totalBytes += await File(entity.path).length();
  }
  return _FileCounts(fileCount, totalBytes);
}

Future<void> _deleteTreeNoFollow(Directory directory) async {
  final type = await FileSystemEntity.type(directory.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return;
  if (type != FileSystemEntityType.directory) {
    if (await FileSystemEntity.isLink(directory.path)) {
      await Link(directory.path).delete();
    } else {
      await File(directory.path).delete();
    }
    return;
  }
  await for (final entity in directory.list(followLinks: false)) {
    final childType = await FileSystemEntity.type(
      entity.path,
      followLinks: false,
    );
    if (childType == FileSystemEntityType.directory) {
      await _deleteTreeNoFollow(Directory(entity.path));
    } else if (childType == FileSystemEntityType.link) {
      await Link(entity.path).delete();
    } else if (childType == FileSystemEntityType.file) {
      await File(entity.path).delete();
    }
  }
  await directory.delete();
}
