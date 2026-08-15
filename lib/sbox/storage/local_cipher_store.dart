import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../bytes.dart';
import '../engine/streaming_container.dart';
import '../errors.dart';
import '../source/source_path.dart';
import 'io_hash.dart';

abstract interface class LocalCipherStore {
  Future<CiphertextObject?> find(SourcePath path, Uint8List expectedSha256);

  Future<StagedCiphertext> createStaging(SourcePath path);

  Future<CiphertextObject> commitVerified(StagedCiphertext staged);

  Future<CiphertextObject> commitDownloaded(
    StagedCiphertext staged, {
    required int expectedLength,
    required Uint8List expectedSha256,
  });

  Future<CiphertextObject> replaceDownloadedCatalog(
    StagedCiphertext staged, {
    required int expectedLength,
    required Uint8List expectedSha256,
    Uint8List? expectedCurrentSha256,
  });

  Stream<CiphertextObject> listPermanentObjects();
}

final class CiphertextObject {
  const CiphertextObject._({
    required this.path,
    required this.file,
    required this.length,
    required this.sha256,
  });

  final SourcePath path;
  final File file;
  final int length;
  final Uint8List sha256;
}

final class StagedCiphertext {
  StagedCiphertext._({
    required this.path,
    required this.file,
    required this._storeRoot,
  });

  final SourcePath path;
  final File file;
  final String _storeRoot;
  EncryptedArtifact? _artifact;
  bool _consumed = false;

  IOSink openSink() {
    if (_consumed || _artifact != null) {
      throw StateError('Staged ciphertext is no longer writable');
    }
    return file.openWrite(mode: FileMode.writeOnly);
  }

  void accept(EncryptedArtifact artifact) {
    if (_consumed || _artifact != null) {
      throw StateError('Staged ciphertext already finalized');
    }
    _artifact = artifact;
  }

  Future<void> discard() async {
    if (_consumed) {
      return;
    }
    _consumed = true;
    if (await file.exists()) {
      await file.delete();
    }
  }
}

final class FileSystemLocalCipherStore implements LocalCipherStore {
  FileSystemLocalCipherStore._(this.root, this._canonicalRoot);

  final Directory root;
  final String _canonicalRoot;

  static Future<FileSystemLocalCipherStore> open(Directory root) async {
    await root.create(recursive: true);
    final canonical = await root.resolveSymbolicLinks();
    final type = await FileSystemEntity.type(canonical, followLinks: false);
    if (type != FileSystemEntityType.directory) {
      throw const SboxException(SboxErrorCode.invalidHeader, '本地密文根目录无效');
    }
    final staging = Directory(p.join(canonical, '.sbox-staging'));
    await staging.create(recursive: true);
    return FileSystemLocalCipherStore._(Directory(canonical), canonical);
  }

  @override
  Future<CiphertextObject?> find(
    SourcePath path,
    Uint8List expectedSha256,
  ) async {
    final file = await _permanentFile(path, mustExist: false);
    if (!await file.exists()) {
      return null;
    }
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw _conflict();
    }
    final actualHash = await sha256File(file);
    if (!constantTimeBytesEqual(actualHash, expectedSha256)) {
      throw _conflict();
    }
    return CiphertextObject._(
      path: path,
      file: file,
      length: await file.length(),
      sha256: actualHash,
    );
  }

  @override
  Future<StagedCiphertext> createStaging(SourcePath path) async {
    final id = hexLower(secureRandomBytes(16));
    final jobDirectory = Directory(p.join(_canonicalRoot, '.sbox-staging', id));
    await jobDirectory.create(recursive: true);
    final file = File(p.join(jobDirectory.path, '$id.part'));
    if (await file.exists()) {
      throw _conflict();
    }
    return StagedCiphertext._(
      path: path,
      file: file,
      storeRoot: _canonicalRoot,
    );
  }

  @override
  Future<CiphertextObject> commitVerified(StagedCiphertext staged) async {
    if (staged._storeRoot != _canonicalRoot || staged._consumed) {
      throw _conflict();
    }
    final artifact = staged._artifact;
    if (artifact == null) {
      throw StateError('Ciphertext was not produced by the verified engine');
    }
    return _commitImmutable(
      staged,
      expectedLength: artifact.sboxLength,
      expectedSha256: artifact.sboxSha256,
    );
  }

  @override
  Future<CiphertextObject> commitDownloaded(
    StagedCiphertext staged, {
    required int expectedLength,
    required Uint8List expectedSha256,
  }) {
    return _commitImmutable(
      staged,
      expectedLength: expectedLength,
      expectedSha256: expectedSha256,
    );
  }

  @override
  Future<CiphertextObject> replaceDownloadedCatalog(
    StagedCiphertext staged, {
    required int expectedLength,
    required Uint8List expectedSha256,
    Uint8List? expectedCurrentSha256,
  }) async {
    if (staged.path.value != 'catalog.sbox') {
      throw ArgumentError('Only catalog.sbox can be atomically replaced');
    }
    final verified = await _verifyStaged(
      staged,
      expectedLength: expectedLength,
      expectedSha256: expectedSha256,
    );
    final stagingDirectory = Directory(p.join(_canonicalRoot, '.sbox-staging'));
    final lock = await File(p.join(stagingDirectory.path, 'catalog.lock'))
        .open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
      final target = await _permanentFile(staged.path, mustExist: false);
      if (await target.exists()) {
        if (await FileSystemEntity.type(target.path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw _conflict();
        }
        final currentHash = await sha256File(target);
        if (constantTimeBytesEqual(currentHash, verified.sha256)) {
          await staged.discard();
          return CiphertextObject._(
            path: staged.path,
            file: target,
            length: await target.length(),
            sha256: currentHash,
          );
        }
        if (expectedCurrentSha256 == null ||
            !constantTimeBytesEqual(currentHash, expectedCurrentSha256)) {
          throw const SboxException(
            SboxErrorCode.syncConflict,
            '本地 catalog.sbox 已变化',
          );
        }
      } else if (expectedCurrentSha256 != null) {
        throw const SboxException(
          SboxErrorCode.syncConflict,
          '本地 catalog.sbox 已被删除',
        );
      }
      await target.parent.create(recursive: true);
      await staged.file.rename(target.path);
      staged._consumed = true;
      await _removeEmptyStagingParent(staged);
      return CiphertextObject._(
        path: staged.path,
        file: target,
        length: verified.length,
        sha256: verified.sha256,
      );
    } finally {
      try {
        await lock.unlock();
      } on FileSystemException {
        // Closing the handle still releases a platform lock.
      }
      await lock.close();
    }
  }

  Future<CiphertextObject> _commitImmutable(
    StagedCiphertext staged, {
    required int expectedLength,
    required Uint8List expectedSha256,
  }) async {
    final verified = await _verifyStaged(
      staged,
      expectedLength: expectedLength,
      expectedSha256: expectedSha256,
    );
    final actualLength = verified.length;
    final actualHash = verified.sha256;

    final target = await _permanentFile(staged.path, mustExist: false);
    await target.parent.create(recursive: true);
    if (await target.exists()) {
      if (await FileSystemEntity.type(target.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw _conflict();
      }
      final existingHash = await sha256File(target);
      if (!constantTimeBytesEqual(existingHash, actualHash)) {
        throw _conflict();
      }
      await staged.discard();
      return CiphertextObject._(
        path: staged.path,
        file: target,
        length: await target.length(),
        sha256: existingHash,
      );
    }

    try {
      await staged.file.rename(target.path);
    } on FileSystemException {
      if (!await target.exists()) {
        rethrow;
      }
      if (await FileSystemEntity.type(target.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw _conflict();
      }
      final existingHash = await sha256File(target);
      if (!constantTimeBytesEqual(existingHash, actualHash)) {
        throw _conflict();
      }
      await staged.discard();
    }
    staged._consumed = true;
    await _removeEmptyStagingParent(staged);
    return CiphertextObject._(
      path: staged.path,
      file: target,
      length: actualLength,
      sha256: actualHash,
    );
  }

  Future<_VerifiedStaging> _verifyStaged(
    StagedCiphertext staged, {
    required int expectedLength,
    required Uint8List expectedSha256,
  }) async {
    if (staged._storeRoot != _canonicalRoot ||
        staged._consumed ||
        expectedLength < 0 ||
        expectedSha256.length != 32) {
      throw _conflict();
    }
    final stagingPath = p.normalize(p.absolute(staged.file.path));
    final stagingRoot = p.normalize(p.join(_canonicalRoot, '.sbox-staging'));
    if (!p.isWithin(stagingRoot, stagingPath) ||
        await FileSystemEntity.type(stagingPath, followLinks: false) !=
            FileSystemEntityType.file) {
      throw _conflict();
    }
    final actualLength = await staged.file.length();
    final actualHash = await sha256File(staged.file);
    if (actualLength != expectedLength ||
        !constantTimeBytesEqual(actualHash, expectedSha256)) {
      throw _conflict();
    }
    return _VerifiedStaging(length: actualLength, sha256: actualHash);
  }

  Future<void> _removeEmptyStagingParent(StagedCiphertext staged) async {
    final parent = staged.file.parent;
    if (await parent.exists()) {
      try {
        await parent.delete();
      } on FileSystemException {
        // Empty staging-directory cleanup is best effort and never affects the
        // now permanent ciphertext object.
      }
    }
  }

  @override
  Stream<CiphertextObject> listPermanentObjects() async* {
    final objects = Directory(p.join(_canonicalRoot, 'objects'));
    if (!await objects.exists()) {
      return;
    }
    var count = 0;
    await for (final entity in objects.list(
      recursive: true,
      followLinks: false,
    )) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type != FileSystemEntityType.file ||
          !entity.path.toLowerCase().endsWith('.sbox')) {
        continue;
      }
      count++;
      if (count > 100000) {
        throw const SboxException(SboxErrorCode.limits, '本地 SBOX 对象数量超过扫描上限');
      }
      final relative = p
          .relative(entity.path, from: _canonicalRoot)
          .replaceAll(p.separator, '/');
      final path = SourcePath(relative);
      final file = File(entity.path);
      final hash = await sha256File(file);
      yield CiphertextObject._(
        path: path,
        file: file,
        length: await file.length(),
        sha256: hash,
      );
    }
  }

  /// Deletes only incomplete transaction state below `.sbox-staging`.
  /// Permanent catalog.sbox and objects/ entries are outside this boundary and
  /// are never touched. Call only during startup or after sensitive isolates
  /// have been terminated.
  Future<int> discardIncompleteStaging() async {
    if (await root.resolveSymbolicLinks() != _canonicalRoot) {
      throw _conflict();
    }
    final staging = Directory(p.join(_canonicalRoot, '.sbox-staging'));
    if (await FileSystemEntity.type(staging.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw _conflict();
    }
    var deleted = 0;
    await for (final entity in staging.list(followLinks: false)) {
      if (p.basename(entity.path) == 'catalog.lock') continue;
      await _deleteCipherStagingEntityNoFollow(entity.path);
      deleted++;
    }
    return deleted;
  }

  Future<File> _permanentFile(
    SourcePath sourcePath, {
    required bool mustExist,
  }) async {
    final candidate = p.normalize(
      p.joinAll(<String>[_canonicalRoot, ...sourcePath.segments]),
    );
    if (!p.isWithin(_canonicalRoot, candidate)) {
      throw _conflict();
    }
    final parent = Directory(p.dirname(candidate));
    Directory existingParent = parent;
    while (!await existingParent.exists()) {
      final next = existingParent.parent;
      if (next.path == existingParent.path) {
        throw _conflict();
      }
      existingParent = next;
    }
    final resolvedParent = await existingParent.resolveSymbolicLinks();
    if (resolvedParent != _canonicalRoot &&
        !p.isWithin(_canonicalRoot, resolvedParent)) {
      throw _conflict();
    }
    final file = File(candidate);
    if (mustExist && !await file.exists()) {
      throw _conflict();
    }
    return file;
  }

  static SboxException _conflict() =>
      const SboxException(SboxErrorCode.remoteChanged, '本地密文对象冲突或路径边界无效');
}

Future<void> _deleteCipherStagingEntityNoFollow(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  switch (type) {
    case FileSystemEntityType.notFound:
      return;
    case FileSystemEntityType.file:
      await File(path).delete();
    case FileSystemEntityType.link:
      await Link(path).delete();
    case FileSystemEntityType.directory:
      await for (final child in Directory(path).list(followLinks: false)) {
        await _deleteCipherStagingEntityNoFollow(child.path);
      }
      await Directory(path).delete();
    default:
      throw const SboxException(
        SboxErrorCode.storageOverlap,
        '密文暂存目录包含不支持的文件系统对象',
      );
  }
}

final class _VerifiedStaging {
  const _VerifiedStaging({required this.length, required this.sha256});

  final int length;
  final Uint8List sha256;
}
