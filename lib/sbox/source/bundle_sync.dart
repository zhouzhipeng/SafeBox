import 'dart:io';
import 'dart:typed_data';

import '../bytes.dart';
import '../errors.dart';
import '../engine/bundle_decryptor.dart';
import '../engine/bundle_encryptor.dart';
import '../format/bundle_header.dart';
import '../format/bundle_path.dart';
import 'data_source.dart';
import 'source_path.dart';

abstract final class BundleSync {
  static Future<DecryptedBundle> fetchAndDecrypt({
    required DataSource source,
    required SourcePath rootPath,
    required String mnemonic,
  }) async {
    if (!source.capabilities.canRead) {
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        '褰撳墠鏁版嵁婧愪笉鏀寔璇诲彇',
      );
    }
    final rootRead = await source.get(rootPath);
    final rootBytes = await _readObject(source, rootRead);
    final rootHeader = BundleHeader.parse(rootBytes);
    validateBundlePathAgainstHeader(rootPath.value, rootHeader);
    if (!rootHeader.isRoot) {
      throw const SboxException(SboxErrorCode.rootRequired, '闇€瑕佹彁渚涙牴鍒嗙墖');
    }
    final objects = <String, List<int>>{rootPath.value: rootBytes};
    for (var index = 1; index < rootHeader.shardCount; index++) {
      final path = SourcePath(
        canonicalBundleBasename(
          bundleId: rootHeader.bundleId,
          shardIndex: index,
          shardCount: rootHeader.shardCount,
        ),
      );
      try {
        final read = await source.get(path);
        objects[path.value] = await _readObject(source, read);
      } on SboxException catch (error) {
        if (error.code == SboxErrorCode.sourceNotFound) {
          throw const SboxException(
            SboxErrorCode.shardMissing,
            'Bundle 缂哄皯蹇呰鍒嗙墖',
          );
        }
        rethrow;
      }
    }
    return BundleDecryptor().decrypt(objects: objects, mnemonic: mnemonic);
  }

  static Future<void> fetchAndDecryptToFile({
    required DataSource source,
    required SourcePath rootPath,
    required String mnemonic,
    required File destination,
  }) async {
    final decrypted = await fetchAndDecrypt(
      source: source,
      rootPath: rootPath,
      mnemonic: mnemonic,
    );
    final parent = destination.parent;
    await parent.create(recursive: true);
    final destinationType = await FileSystemEntity.type(
      destination.path,
      followLinks: false,
    );
    if (destinationType != FileSystemEntityType.notFound) {
      decrypted.plaintext.fillRange(0, decrypted.plaintext.length, 0);
      throw const SboxException(
        SboxErrorCode.immutableConflict,
        'Destination already exists and will not be overwritten',
      );
    }
    final stage = File(
      '${parent.path}${Platform.pathSeparator}.sbox-plaintext-${hexLower(secureRandomBytes(8))}.part',
    );
    try {
      await stage.writeAsBytes(decrypted.plaintext, flush: true);
      await stage.rename(destination.path);
    } on FileSystemException {
      throw const SboxException(
        SboxErrorCode.temporaryCleanup,
        'Unable to publish the verified plaintext',
      );
    } finally {
      decrypted.plaintext.fillRange(0, decrypted.plaintext.length, 0);
      if (await stage.exists()) await stage.delete();
    }
  }

  /// Downloads ciphertext objects into managed memory and delegates plaintext
  /// publication to the streaming decryptor. Plaintext is never returned to
  /// this source layer.
  static Future<void> fetchAndDecryptToFileStreaming({
    required DataSource source,
    required SourcePath rootPath,
    required String mnemonic,
    required File destination,
  }) async {
    if (!source.capabilities.canRead) {
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        'Source is not readable',
      );
    }
    final rootRead = await source.get(rootPath);
    final rootBytes = await _readObject(source, rootRead);
    final rootHeader = BundleHeader.parse(rootBytes);
    validateBundlePathAgainstHeader(rootPath.value, rootHeader);
    if (!rootHeader.isRoot) {
      throw const SboxException(
        SboxErrorCode.rootRequired,
        'A root shard is required',
      );
    }
    final objects = <String, List<int>>{rootPath.value: rootBytes};
    for (var index = 1; index < rootHeader.shardCount; index++) {
      final path = SourcePath(
        canonicalBundleBasename(
          bundleId: rootHeader.bundleId,
          shardIndex: index,
          shardCount: rootHeader.shardCount,
        ),
      );
      try {
        final read = await source.get(path);
        objects[path.value] = await _readObject(source, read);
      } on SboxException catch (error) {
        if (error.code == SboxErrorCode.sourceNotFound) {
          throw const SboxException(
            SboxErrorCode.shardMissing,
            'Bundle is missing a continuation shard',
          );
        }
        rethrow;
      }
    }
    await BundleDecryptor().decryptToFile(
      objects: objects,
      mnemonic: mnemonic,
      destination: destination,
    );
  }

  static Future<List<RevisionToken>> publish(
    DataSource source,
    EncryptedBundle bundle,
  ) async {
    if (!source.capabilities.canWrite) {
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        '当前数据源不允许写入',
      );
    }
    if (source.capabilities.maxObjectBytes != null &&
        bundle.objects.any(
          (object) => object.bytes.length > source.capabilities.maxObjectBytes!,
        )) {
      throw const SboxException(SboxErrorCode.sourceLimit, '对象超过数据源上限');
    }
    final revisions = <RevisionToken>[];
    final continuation = bundle.objects
        .where((object) => !object.header.isRoot)
        .toList();
    continuation.sort(
      (left, right) =>
          left.header.shardIndex.compareTo(right.header.shardIndex),
    );
    for (final object in continuation) {
      revisions.add(await _put(source, object));
    }
    revisions.add(await _put(source, bundle.root));
    return List<RevisionToken>.unmodifiable(revisions);
  }

  static Future<void> delete(
    DataSource source,
    Iterable<({SourcePath path, RevisionToken revision, bool isRoot})> objects,
  ) async {
    final list = objects.toList(growable: false);
    final roots = list.where((object) => object.isRoot).toList(growable: false);
    if (roots.length != 1) {
      throw const SboxException(
        SboxErrorCode.rootRequired,
        '删除 Bundle 需要唯一根对象',
      );
    }
    await source.deleteIfMatch(roots.single.path, roots.single.revision);
    for (final object in list.where((object) => !object.isRoot)) {
      await source.deleteIfMatch(object.path, object.revision);
    }
  }

  static Future<RevisionToken> _put(
    DataSource source,
    EncryptedBundleObject object,
  ) => source.putNew(
    SourcePath(object.basename),
    Stream<List<int>>.value(object.bytes),
    length: object.bytes.length,
    sha256: object.sha256,
  );

  static Future<Uint8List> _readObject(
    DataSource source,
    SourceRead read,
  ) async {
    if (read.notModified ||
        read.length < 0 ||
        (source.capabilities.maxObjectBytes != null &&
            read.length > source.capabilities.maxObjectBytes!)) {
      throw const SboxException(SboxErrorCode.remoteChanged, '鏁版嵁婧愯繑鍥炰簡鏃犳晥瀵硅薄');
    }
    final output = BytesBuilder(copy: false);
    var count = 0;
    await for (final chunk in read.body) {
      count += chunk.length;
      if (count > read.length) {
        throw const SboxException(
          SboxErrorCode.remoteChanged,
          '鏁版嵁婧愯繑鍥炰簡杩囬暱瀵硅薄',
        );
      }
      output.add(chunk);
    }
    if (count != read.length) {
      throw const SboxException(SboxErrorCode.remoteChanged, '鏁版嵁婧愯繑鍥炰簡涓嶅畬瀵硅薄');
    }
    return output.takeBytes();
  }
}
