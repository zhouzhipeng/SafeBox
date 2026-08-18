import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../bytes.dart';
import '../errors.dart';
import '../storage/io_hash.dart';
import 'data_source.dart';
import 'source_path.dart';

enum LocalDirectoryMode { readOnly, readWrite }

final class LocalDirectoryDataSource
    implements EnumerableDataSource, RangeReadableDataSource {
  LocalDirectoryDataSource._({
    required this.root,
    required this.mode,
    required this.canonicalRoot,
  });

  final Directory root;
  final LocalDirectoryMode mode;
  final String canonicalRoot;

  bool get readOnly => mode == LocalDirectoryMode.readOnly;

  static Future<LocalDirectoryDataSource> attach({
    required Directory root,
    LocalDirectoryMode mode = LocalDirectoryMode.readWrite,
    bool requestWrite = true,
  }) async {
    if (!await root.exists()) {
      if (!requestWrite || mode == LocalDirectoryMode.readOnly) {
        throw const SboxException(SboxErrorCode.sourceNotFound, '所选数据源目录不存在');
      }
      await root.create(recursive: true);
    }
    final canonical = await root.resolveSymbolicLinks();
    if (await FileSystemEntity.type(canonical, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const SboxException(SboxErrorCode.remoteChanged, '数据源根目录无效');
    }
    final effectiveMode = requestWrite && mode == LocalDirectoryMode.readWrite
        ? mode
        : LocalDirectoryMode.readOnly;
    return LocalDirectoryDataSource._(
      root: Directory(canonical),
      mode: effectiveMode,
      canonicalRoot: canonical,
    );
  }

  @override
  SourceCapabilities get capabilities => SourceCapabilities(
    canRead: true,
    canWrite: !readOnly,
    canDelete: !readOnly,
    canListObjects: true,
    supportsRangeRead: true,
    maxObjectBytes: null,
    maxParallelTransfers: SboxProtocolDefaults.maxParallelTransfers,
  );

  @override
  Future<SourceRead> get(SourcePath path, {RevisionToken? ifNoneMatch}) async {
    final file = await _resolve(path, mustExist: true);
    final revision = RevisionToken(await sha256File(file));
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
  Future<SourceRead> getRange(
    SourcePath path, {
    required int start,
    required int endExclusive,
    SourceObjectInfo? objectInfo,
  }) async {
    if (start < 0 || endExclusive < start) {
      throw const SboxException(SboxErrorCode.invalidHeader, '范围读取边界无效');
    }
    final file = await _resolve(path, mustExist: true);
    final length = await file.length();
    if (endExclusive > length) {
      throw const SboxException(SboxErrorCode.truncated, '范围读取超过对象长度');
    }
    return SourceRead(
      body: file.openRead(start, endExclusive),
      length: endExclusive - start,
      revision: RevisionToken(await sha256File(file)),
    );
  }

  @override
  Future<SourceListPage> listObjects({
    String? cursor,
    int pageSize = 1000,
  }) async {
    if (pageSize < 1 || pageSize > 1000) {
      throw const SboxException(SboxErrorCode.sourceLimit, '列举分页大小无效');
    }
    var entries = <File>[];
    await for (final entity in root.list(followLinks: false)) {
      if (await FileSystemEntity.type(entity.path, followLinks: false) !=
              FileSystemEntityType.file ||
          p.dirname(entity.path) != canonicalRoot) {
        continue;
      }
      final basename = p.basename(entity.path);
      if (!basename.endsWith('.sbox')) continue;
      entries.add(File(entity.path));
      if (entries.length > 100000) {
        throw const SboxException(SboxErrorCode.sourceLimit, '数据源对象数量超过上限');
      }
    }
    entries.sort(
      (left, right) => p.basename(left.path).compareTo(p.basename(right.path)),
    );
    final start = int.tryParse(cursor ?? '0') ?? 0;
    if (start < 0 || start > entries.length) {
      throw const SboxException(SboxErrorCode.invalidHeader, '列举游标无效');
    }
    final page = entries.skip(start).take(pageSize).toList(growable: false);
    final objects = <SourceObjectInfo>[];
    for (final file in page) {
      final path = SourcePath(p.basename(file.path));
      objects.add(
        SourceObjectInfo(
          path: path,
          length: await file.length(),
          revision: RevisionToken(await sha256File(file)),
        ),
      );
    }
    final next = start + page.length < entries.length
        ? (start + page.length).toString()
        : null;
    return SourceListPage(
      objects: List.unmodifiable(objects),
      nextCursor: next,
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
    if (length < 0 || sha256.length != 32) {
      throw ArgumentError('Invalid object dimensions');
    }
    final target = await _resolve(path, mustExist: false);
    if (await target.exists()) {
      final existingHash = await sha256File(target);
      if (constantTimeBytesEqual(existingHash, sha256)) {
        return RevisionToken(existingHash);
      }
      throw const SboxException(
        SboxErrorCode.immutableConflict,
        '规范对象已存在且内容不同',
      );
    }
    final stage = File(
      p.join(
        canonicalRoot,
        '.${path.value}.${hexLower(secureRandomBytes(8))}.part',
      ),
    );
    final output = stage.openWrite();
    var count = 0;
    final accumulator = HashDigestSink();
    final hashSink = crypto.sha256.startChunkedConversion(accumulator);
    try {
      await for (final chunk in body) {
        count += chunk.length;
        if (count > length) {
          throw const SboxException(SboxErrorCode.integrity, '对象超过声明长度');
        }
        output.add(chunk);
        hashSink.add(chunk);
      }
      hashSink.close();
      if (count != length ||
          !constantTimeBytesEqual(accumulator.value.bytes, sha256)) {
        throw const SboxException(SboxErrorCode.integrity, '对象摘要或长度不匹配');
      }
      await output.flush();
      await output.close();
      if (await target.exists()) {
        throw const SboxException(SboxErrorCode.immutableConflict, '规范对象已存在');
      }
      await stage.rename(target.path);
      return RevisionToken(sha256);
    } finally {
      await output.close();
      if (await stage.exists()) await stage.delete();
    }
  }

  @override
  Future<void> deleteIfMatch(SourcePath path, RevisionToken expected) async {
    _requireWrite();
    final target = await _resolve(path, mustExist: true);
    if (!constantTimeBytesEqual(await sha256File(target), expected.bytes)) {
      throw const SboxException(SboxErrorCode.shardConflict, '对象在删除前发生变化');
    }
    await target.delete();
  }

  Future<File> _resolve(SourcePath path, {required bool mustExist}) async {
    final candidate = p.join(canonicalRoot, path.value);
    if (p.dirname(candidate) != canonicalRoot ||
        !p.isWithin(canonicalRoot, candidate)) {
      throw const SboxException(SboxErrorCode.invalidHeader, '数据源路径越界');
    }
    final type = await FileSystemEntity.type(candidate, followLinks: false);
    if (mustExist && type != FileSystemEntityType.file) {
      throw const SboxException(SboxErrorCode.sourceNotFound, '数据源对象不存在');
    }
    if (type == FileSystemEntityType.link) {
      throw const SboxException(SboxErrorCode.invalidHeader, '数据源对象不能是符号链接');
    }
    return File(candidate);
  }

  void _requireWrite() {
    if (readOnly) {
      throw const SboxException(SboxErrorCode.sourceAuthentication, '当前数据源为只读');
    }
  }
}

abstract final class SboxProtocolDefaults {
  static const int maxParallelTransfers = 4;
}
