import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../bytes.dart';
import '../errors.dart';
import '../storage/io_hash.dart';
import 'data_source.dart';
import 'source_path.dart';

enum LocalDirectoryMode { canonicalCatalog, looseReadOnly }

final class LocalDirectoryDataSource implements DataSource {
  LocalDirectoryDataSource._({
    required this.root,
    required this.mode,
    required this.readOnly,
    required this._canonicalRoot,
  });

  final Directory root;
  final LocalDirectoryMode mode;
  final bool readOnly;
  final String _canonicalRoot;

  static Future<LocalDirectoryDataSource> attach({
    required Directory root,
    required LocalDirectoryMode mode,
    required bool requestWrite,
  }) async {
    if (!await root.exists()) {
      if (!requestWrite || mode == LocalDirectoryMode.looseReadOnly) {
        throw const SboxException(SboxErrorCode.sourceNetwork, '所选本地目录不存在');
      }
      await root.create(recursive: true);
    }
    final canonicalRoot = await root.resolveSymbolicLinks();
    if (await FileSystemEntity.type(canonicalRoot, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw _pathError();
    }
    final canWrite =
        requestWrite &&
        mode == LocalDirectoryMode.canonicalCatalog &&
        await _probeWrite(Directory(canonicalRoot));
    return LocalDirectoryDataSource._(
      root: Directory(canonicalRoot),
      mode: mode,
      readOnly: !canWrite,
      canonicalRoot: canonicalRoot,
    );
  }

  @override
  SourceCapabilities get capabilities => SourceCapabilities(
    canRead: true,
    canWrite: !readOnly,
    canDelete: !readOnly,
    conditionalWrite: !readOnly,
    history: false,
    maxObjectBytes: null,
    maxRequestBodyBytes: null,
    uploadEncoding: UploadEncoding.binary,
    maxParallelObjectTransfers: 4,
    supportsStreamingDownload: true,
    supportsResumableObjectDownload: true,
  );

  @override
  Future<SourceRead> get(SourcePath path, {RevisionToken? ifNoneMatch}) async {
    final file = await _resolveFile(path, mustExist: true);
    final hash = await sha256File(file);
    final revision = RevisionToken(hash);
    if (ifNoneMatch != null && revision.matches(ifNoneMatch)) {
      return SourceRead(
        body: const Stream<List<int>>.empty(),
        length: 0,
        revision: revision,
        notModified: true,
      );
    }
    return SourceRead(
      body: file.openRead(),
      length: await file.length(),
      revision: revision,
    );
  }

  @override
  Future<RevisionToken> putNew(
    SourcePath path,
    Stream<List<int>> body, {
    required int length,
    required Uint8List sha256,
  }) async {
    _requireWrite();
    final target = await _resolveFile(path, mustExist: false);
    if (await target.exists()) {
      if (path.value == 'catalog.sbox') {
        throw _changed();
      }
      if (await FileSystemEntity.type(target.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw _changed();
      }
      final existingHash = await sha256File(target);
      if (!constantTimeBytesEqual(existingHash, sha256)) {
        throw _changed();
      }
      return RevisionToken(existingHash);
    }
    final staged = await _writeStaged(
      target: target,
      body: body,
      expectedLength: length,
      expectedHash: sha256,
    );
    try {
      if (await target.exists()) {
        throw _changed();
      }
      await staged.rename(target.path);
      return RevisionToken(sha256);
    } finally {
      if (await staged.exists()) {
        await staged.delete();
      }
    }
  }

  @override
  Future<RevisionToken> compareAndSwap(
    SourcePath path,
    RevisionToken expected,
    Stream<List<int>> body, {
    required int length,
  }) async {
    _requireWrite();
    if (path.value != 'catalog.sbox') {
      throw ArgumentError('compareAndSwap is reserved for catalog.sbox');
    }
    final lockDirectory = Directory(p.join(_canonicalRoot, '.sbox-staging'));
    await lockDirectory.create(recursive: true);
    final lockFile = File(p.join(lockDirectory.path, 'catalog.lock'));
    final lock = await lockFile.open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
      final target = await _resolveFile(path, mustExist: true);
      final currentHash = await sha256File(target);
      if (!constantTimeBytesEqual(currentHash, expected.bytes)) {
        throw _syncConflict();
      }
      final staged = await _writeStaged(
        target: target,
        body: body,
        expectedLength: length,
      );
      try {
        final newHash = await sha256File(staged);
        // Recheck while the cross-process lock is still held. Cloud-sync tools
        // may not honor the lock, so the hash remains authoritative.
        if (!constantTimeBytesEqual(await sha256File(target), expected.bytes)) {
          throw _syncConflict();
        }
        await staged.rename(target.path);
        return RevisionToken(newHash);
      } finally {
        if (await staged.exists()) {
          await staged.delete();
        }
      }
    } finally {
      try {
        await lock.unlock();
      } on FileSystemException {
        // The primary operation result is preserved; close releases the lock.
      }
      await lock.close();
    }
  }

  @override
  Future<void> deleteIfMatch(SourcePath path, RevisionToken expected) async {
    _requireWrite();
    final file = await _resolveFile(path, mustExist: true);
    if (!constantTimeBytesEqual(await sha256File(file), expected.bytes)) {
      throw _syncConflict();
    }
    await file.delete();
  }

  Future<File> _writeStaged({
    required File target,
    required Stream<List<int>> body,
    required int expectedLength,
    Uint8List? expectedHash,
  }) async {
    if (expectedLength < 0) {
      throw ArgumentError.value(expectedLength, 'expectedLength');
    }
    await target.parent.create(recursive: true);
    final randomName =
        '.${p.basename(target.path)}.'
        '${hexLower(secureRandomBytes(16))}.part';
    final staged = File(p.join(target.parent.path, randomName));
    final output = staged.openWrite(mode: FileMode.writeOnly);
    final accumulator = AccumulatorSink<crypto.Digest>();
    final hashSink = crypto.sha256.startChunkedConversion(accumulator);
    var written = 0;
    try {
      await for (final chunk in body) {
        written += chunk.length;
        if (written > expectedLength) {
          throw const SboxException(SboxErrorCode.integrity, '数据源写入流超过声明长度');
        }
        output.add(chunk);
        hashSink.add(chunk);
      }
      if (written != expectedLength) {
        throw const SboxException(SboxErrorCode.truncated, '数据源写入流提前结束');
      }
      hashSink.close();
      final actualHash = accumulator.events.single.bytes;
      if (expectedHash != null &&
          !constantTimeBytesEqual(actualHash, expectedHash)) {
        throw const SboxException(SboxErrorCode.integrity, '数据源写入摘要不匹配');
      }
      await output.flush();
      await output.close();
      return staged;
    } catch (_) {
      await output.close();
      if (await staged.exists()) {
        await staged.delete();
      }
      rethrow;
    }
  }

  Future<File> _resolveFile(SourcePath path, {required bool mustExist}) async {
    final candidate = p.normalize(
      p.joinAll(<String>[_canonicalRoot, ...path.segments]),
    );
    if (!p.isWithin(_canonicalRoot, candidate)) {
      throw _pathError();
    }
    var ancestor = Directory(p.dirname(candidate));
    while (!await ancestor.exists()) {
      if (ancestor.parent.path == ancestor.path) {
        throw _pathError();
      }
      ancestor = ancestor.parent;
    }
    final resolvedAncestor = await ancestor.resolveSymbolicLinks();
    if (resolvedAncestor != _canonicalRoot &&
        !p.isWithin(_canonicalRoot, resolvedAncestor)) {
      throw _pathError();
    }
    final file = File(candidate);
    if (mustExist) {
      if (await FileSystemEntity.type(candidate, followLinks: false) !=
          FileSystemEntityType.file) {
        throw _pathError();
      }
    }
    return file;
  }

  void _requireWrite() {
    if (readOnly || mode != LocalDirectoryMode.canonicalCatalog) {
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        '此本地数据源仅可读取',
      );
    }
  }

  static Future<bool> _probeWrite(Directory root) async {
    final probe = File(
      p.join(root.path, '.sbox-write-probe-${hexLower(secureRandomBytes(8))}'),
    );
    try {
      await probe.writeAsBytes(const <int>[0], flush: true);
      await probe.delete();
      return true;
    } on FileSystemException {
      if (await probe.exists()) {
        try {
          await probe.delete();
        } on FileSystemException {
          // Read-only downgrade still wins over probe cleanup failure.
        }
      }
      return false;
    }
  }

  static SboxException _pathError() =>
      const SboxException(SboxErrorCode.remoteChanged, '本地数据源路径边界无效');

  static SboxException _changed() =>
      const SboxException(SboxErrorCode.remoteChanged, '目标对象已存在且不能覆盖');

  static SboxException _syncConflict() =>
      const SboxException(SboxErrorCode.syncConflict, '本地 Catalog 已变化，请处理同步冲突');
}
