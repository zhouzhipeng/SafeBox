import 'dart:io';

import 'package:path/path.dart' as p;

import '../bytes.dart';
import '../constants.dart';
import '../engine/streaming_container.dart';
import '../errors.dart';
import 'io_hash.dart';

final class JobId {
  JobId(String value)
    : value = RegExp(r'^[0-9a-f]{32}$').hasMatch(value)
          ? value
          : throw ArgumentError.value(value, 'value');

  factory JobId.random() => JobId(hexLower(secureRandomBytes(16)));

  final String value;
}

abstract interface class TemporaryPlaintextStore {
  Future<StagedPlaintext> createForJob(JobId jobId);

  Future<VerifiedTemporaryPlaintext> publishVerified(StagedPlaintext staged);

  Future<void> deleteOne(VerifiedTemporaryPlaintext file);

  Future<TemporaryCleanupReport> clearAll();
}

final class StagedPlaintext {
  StagedPlaintext._({
    required this.jobId,
    required this.file,
    required this._storeRoot,
  });

  final JobId jobId;
  final File file;
  final String _storeRoot;
  VerifiedPlaintext? _verified;
  bool _consumed = false;

  IOSink openSink() {
    if (_consumed || _verified != null) {
      throw StateError('Staged plaintext is no longer writable');
    }
    return file.openWrite(mode: FileMode.writeOnly);
  }

  void accept(VerifiedPlaintext verified) {
    if (_consumed || _verified != null) {
      throw StateError('Staged plaintext already finalized');
    }
    _verified = verified;
  }

  Future<void> discard() async {
    if (_consumed) {
      return;
    }
    _consumed = true;
    if (await file.parent.exists()) {
      await _deleteTreeNoFollow(file.parent);
    }
  }
}

final class VerifiedTemporaryPlaintext {
  const VerifiedTemporaryPlaintext._({
    required this.file,
    required this.metadata,
  });

  final File file;
  final VerifiedPlaintext metadata;
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

final class ManagedTemporaryPlaintextStore implements TemporaryPlaintextStore {
  ManagedTemporaryPlaintextStore._(
    this.root,
    this._canonicalRoot,
    this._cipherRoots,
  );

  static const String markerName = '.sbox-managed-temp';
  static const Set<String> _rootMarkerNames = <String>{markerName, '.nomedia'};

  final Directory root;
  final String _canonicalRoot;
  final List<String> _cipherRoots;

  static Future<ManagedTemporaryPlaintextStore> open({
    required Directory root,
    required Iterable<Directory> cipherRoots,
  }) async {
    final prospectiveRoot = await _prospectiveCanonicalPath(root);
    _rejectBroadRoot(prospectiveRoot);
    final canonicalCipherRoots = <String>[];
    for (final cipherRoot in cipherRoots) {
      final canonical = await _prospectiveCanonicalPath(cipherRoot);
      if (_pathsOverlap(prospectiveRoot, canonical)) {
        throw const SboxException(
          SboxErrorCode.storageOverlap,
          '本地密文目录与临时明文目录不能重叠',
        );
      }
      canonicalCipherRoots.add(canonical);
    }
    await root.create(recursive: true);
    final canonicalRoot = await root.resolveSymbolicLinks();
    _rejectBroadRoot(canonicalRoot);
    if (canonicalCipherRoots.any(
      (cipherRoot) => _pathsOverlap(canonicalRoot, cipherRoot),
    )) {
      throw const SboxException(
        SboxErrorCode.storageOverlap,
        '本地密文目录与临时明文目录不能重叠',
      );
    }
    final marker = File(p.join(canonicalRoot, markerName));
    if (!await marker.exists()) {
      await marker.writeAsString(
        'SBOX managed temporary plaintext root\n',
        flush: true,
      );
    }
    return ManagedTemporaryPlaintextStore._(
      Directory(canonicalRoot),
      canonicalRoot,
      List<String>.unmodifiable(canonicalCipherRoots),
    );
  }

  @override
  Future<StagedPlaintext> createForJob(JobId jobId) async {
    await _validateRoot();
    final directory = Directory(p.join(_canonicalRoot, jobId.value));
    if (await directory.exists()) {
      throw const SboxException(SboxErrorCode.remoteChanged, '临时解密任务目录已存在');
    }
    await directory.create();
    final file = File(p.join(directory.path, 'plaintext.part'));
    return StagedPlaintext._(
      jobId: jobId,
      file: file,
      storeRoot: _canonicalRoot,
    );
  }

  @override
  Future<VerifiedTemporaryPlaintext> publishVerified(
    StagedPlaintext staged,
  ) async {
    await _validateRoot();
    if (staged._storeRoot != _canonicalRoot || staged._consumed) {
      throw const SboxException(SboxErrorCode.storageOverlap, '临时解密发布边界无效');
    }
    final verified = staged._verified;
    if (verified == null) {
      throw StateError('Plaintext has not passed SBOX Final verification');
    }
    if (verified.metadata.contentKind == SboxContentKind.multipartPart) {
      throw const SboxException(
        SboxErrorCode.catalogRequired,
        '这是大文件分片，需要对应的 catalog.sbox',
      );
    }
    if (verified.metadata.contentKind == SboxContentKind.catalog) {
      throw const SboxException(
        SboxErrorCode.catalog,
        'Catalog 明文不能作为普通临时文件发布',
      );
    }
    final jobRoot = p.normalize(p.join(_canonicalRoot, staged.jobId.value));
    final stagedPath = p.normalize(p.absolute(staged.file.path));
    if (!p.isWithin(_canonicalRoot, stagedPath) ||
        p.dirname(stagedPath) != jobRoot ||
        await FileSystemEntity.type(stagedPath, followLinks: false) !=
            FileSystemEntityType.file ||
        await staged.file.length() != verified.plaintextLength) {
      throw const SboxException(SboxErrorCode.integrity, '临时明文发布前校验失败');
    }
    final actualHash = await sha256File(staged.file);
    if (!constantTimeBytesEqual(actualHash, verified.plaintextSha256)) {
      throw const SboxException(SboxErrorCode.integrity, '临时明文发布前摘要校验失败');
    }
    final safeName = _sanitizeFileName(verified.metadata.originalName);
    final target = File(p.join(jobRoot, safeName));
    if (await target.exists()) {
      throw const SboxException(SboxErrorCode.remoteChanged, '临时明文目标已存在');
    }
    await staged.file.rename(target.path);
    staged._consumed = true;
    return VerifiedTemporaryPlaintext._(file: target, metadata: verified);
  }

  @override
  Future<void> deleteOne(VerifiedTemporaryPlaintext file) async {
    await _validateRoot();
    final path = p.normalize(p.absolute(file.file.path));
    if (!p.isWithin(_canonicalRoot, path) ||
        p.dirname(path) == _canonicalRoot) {
      throw const SboxException(SboxErrorCode.temporaryCleanup, '临时文件不在受管理范围内');
    }
    final jobDirectory = Directory(p.dirname(path));
    await _deleteTreeNoFollow(jobDirectory);
  }

  @override
  Future<TemporaryCleanupReport> clearAll() async {
    await _validateRoot();
    var deletedFiles = 0;
    var deletedBytes = 0;
    final failures = <String>[];
    await for (final entity in root.list(followLinks: false)) {
      if (_rootMarkerNames.contains(p.basename(entity.path))) {
        continue;
      }
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type != FileSystemEntityType.directory ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(p.basename(entity.path))) {
        failures.add(entity.path);
        continue;
      }
      try {
        var candidateFiles = 0;
        var candidateBytes = 0;
        await for (final child in Directory(
          entity.path,
        ).list(recursive: true, followLinks: false)) {
          if (await FileSystemEntity.type(child.path, followLinks: false) ==
              FileSystemEntityType.file) {
            candidateFiles++;
            candidateBytes += await File(child.path).length();
          }
        }
        await _deleteTreeNoFollow(Directory(entity.path));
        deletedFiles += candidateFiles;
        deletedBytes += candidateBytes;
      } on FileSystemException {
        failures.add(entity.path);
      }
    }
    return TemporaryCleanupReport(
      deletedFiles: deletedFiles,
      deletedBytes: deletedBytes,
      failedPaths: List<String>.unmodifiable(failures),
    );
  }

  Future<TemporaryPlaintextStats> stats() async {
    await _validateRoot();
    var count = 0;
    var bytes = 0;
    DateTime? earliest;
    DateTime? latest;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (await FileSystemEntity.type(entity.path, followLinks: false) !=
              FileSystemEntityType.file ||
          _rootMarkerNames.contains(p.basename(entity.path)) ||
          entity.path.endsWith('.part')) {
        continue;
      }
      final file = File(entity.path);
      final stat = await file.stat();
      count++;
      bytes += stat.size;
      earliest = earliest == null || stat.modified.isBefore(earliest)
          ? stat.modified
          : earliest;
      latest = latest == null || stat.modified.isAfter(latest)
          ? stat.modified
          : latest;
    }
    return TemporaryPlaintextStats(
      fileCount: count,
      totalBytes: bytes,
      earliest: earliest,
      latest: latest,
    );
  }

  /// Removes only job directories that contain no published file (normally a
  /// `.part` file or an empty crash remnant). Any directory containing a
  /// verified plaintext name is retained for explicit user cleanup.
  Future<int> discardIncompleteJobs() async {
    await _validateRoot();
    var deleted = 0;
    await for (final entity in root.list(followLinks: false)) {
      if (await FileSystemEntity.type(entity.path, followLinks: false) !=
              FileSystemEntityType.directory ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(p.basename(entity.path))) {
        continue;
      }
      var containsPublished = false;
      await for (final child in Directory(
        entity.path,
      ).list(recursive: true, followLinks: false)) {
        final type = await FileSystemEntity.type(
          child.path,
          followLinks: false,
        );
        if (type != FileSystemEntityType.file) continue;
        if (!p.basename(child.path).endsWith('.part')) {
          containsPublished = true;
        }
      }
      if (!containsPublished) {
        await _deleteTreeNoFollow(Directory(entity.path));
        deleted++;
      }
    }
    return deleted;
  }

  /// Deletes one already-published plaintext by path while reusing the same
  /// marker, canonical-boundary and no-follow checks as bulk cleanup.
  Future<void> deletePublishedPath(String publishedPath) async {
    await _validateRoot();
    final path = p.normalize(p.absolute(publishedPath));
    final parent = p.dirname(path);
    if (!p.isWithin(_canonicalRoot, path) ||
        p.dirname(parent) != _canonicalRoot ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(p.basename(parent)) ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw const SboxException(
        SboxErrorCode.temporaryCleanup,
        '临时文件不在受管理的已验证结果范围内',
      );
    }
    await _deleteTreeNoFollow(Directory(parent));
  }

  Future<void> _validateRoot() async {
    _rejectBroadRoot(_canonicalRoot);
    final resolved = await root.resolveSymbolicLinks();
    if (resolved != _canonicalRoot ||
        _cipherRoots.any((cipherRoot) => _pathsOverlap(resolved, cipherRoot)) ||
        !await File(p.join(_canonicalRoot, markerName)).exists()) {
      throw const SboxException(
        SboxErrorCode.temporaryCleanup,
        '临时明文管理标记或目录边界无效',
      );
    }
  }

  static bool _pathsOverlap(String left, String right) {
    final normalizedLeft = p.normalize(p.absolute(left));
    final normalizedRight = p.normalize(p.absolute(right));
    final equal = Platform.isWindows
        ? normalizedLeft.toLowerCase() == normalizedRight.toLowerCase()
        : normalizedLeft == normalizedRight;
    if (equal) {
      return true;
    }
    if (Platform.isWindows) {
      return p.isWithin(
            normalizedLeft.toLowerCase(),
            normalizedRight.toLowerCase(),
          ) ||
          p.isWithin(
            normalizedRight.toLowerCase(),
            normalizedLeft.toLowerCase(),
          );
    }
    return p.isWithin(normalizedLeft, normalizedRight) ||
        p.isWithin(normalizedRight, normalizedLeft);
  }

  static Future<String> _prospectiveCanonicalPath(Directory directory) async {
    final absolute = p.normalize(p.absolute(directory.path));
    var cursor = Directory(absolute);
    final suffix = <String>[];
    while (!await cursor.exists()) {
      final parent = cursor.parent;
      if (parent.path == cursor.path) {
        throw const SboxException(SboxErrorCode.temporaryCleanup, '无法解析存储目录边界');
      }
      suffix.add(p.basename(cursor.path));
      cursor = parent;
    }
    final resolvedParent = await cursor.resolveSymbolicLinks();
    return p.normalize(p.joinAll(<String>[resolvedParent, ...suffix.reversed]));
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
    if (home != null && _pathsOverlapEqualOnly(normalized, home)) {
      throw const SboxException(
        SboxErrorCode.temporaryCleanup,
        '禁止把用户主目录用作临时明文目录',
      );
    }
  }

  static bool _pathsOverlapEqualOnly(String left, String right) {
    final a = p.normalize(p.absolute(left));
    final b = p.normalize(p.absolute(right));
    return Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;
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
    final stem = value.split('.').first.toUpperCase();
    if (reserved.contains(stem)) {
      value = '_$value';
    }
    return value;
  }
}

Future<void> _deleteTreeNoFollow(Directory directory) async {
  final directoryType = await FileSystemEntity.type(
    directory.path,
    followLinks: false,
  );
  if (directoryType == FileSystemEntityType.notFound) {
    return;
  }
  if (directoryType != FileSystemEntityType.directory) {
    if (await FileSystemEntity.isLink(directory.path)) {
      await Link(directory.path).delete();
    } else {
      await File(directory.path).delete();
    }
    return;
  }
  await for (final entity in directory.list(followLinks: false)) {
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await _deleteTreeNoFollow(Directory(entity.path));
    } else if (type == FileSystemEntityType.link) {
      await Link(entity.path).delete();
    } else if (type == FileSystemEntityType.file) {
      await File(entity.path).delete();
    }
  }
  await directory.delete();
}
