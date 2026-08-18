import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../bytes.dart';
import '../constants.dart';
import '../crypto/rsa_oaep.dart';
import '../crypto/shard_kdf.dart';
import '../errors.dart';
import '../format/bundle_header.dart';
import '../format/bundle_manifest.dart';
import '../format/bundle_path.dart';
import '../format/bundle_record.dart';
import '../identity/bip39_identity.dart';
import '../identity/rsa_models.dart';

final class DecryptedBundle {
  DecryptedBundle({
    required this.manifest,
    required this.rootHeader,
    required List<int> plaintext,
  }) : plaintext = Uint8List.fromList(plaintext);

  final BundleManifest manifest;
  final BundleHeader rootHeader;
  final Uint8List plaintext;
}

final class BundleDecryptor {
  BundleDecryptor({BundleRecordCodec? records})
    : _records = records ?? BundleRecordCodec();

  final BundleRecordCodec _records;

  /// [objects] must contain the original relative basename for every object.
  /// Only a root object is a valid entry point; continuation-only input is
  /// deliberately rejected before any attempt to derive a key.
  Future<DecryptedBundle> decrypt({
    required Map<String, List<int>> objects,
    required String mnemonic,
    PublicIdentity? expectedIdentity,
  }) async {
    if (objects.isEmpty) {
      throw const SboxException(SboxErrorCode.rootRequired, '需要对应的 SBOX 根分片');
    }
    final parsed = <_ParsedObject>[];
    for (final entry in objects.entries) {
      final path = parseCanonicalBundleBasename(entry.key);
      final bytes = Uint8List.fromList(entry.value);
      final header = BundleHeader.parse(bytes);
      validateBundlePathAgainstHeader(entry.key, header);
      parsed.add(_ParsedObject(entry.key, bytes, header, path));
    }
    parsed.sort(
      (left, right) =>
          left.header.shardIndex.compareTo(right.header.shardIndex),
    );
    final roots = parsed
        .where((object) => object.header.isRoot)
        .toList(growable: false);
    if (roots.isEmpty) {
      throw const SboxException(SboxErrorCode.rootRequired, '需要对应的 SBOX 根分片');
    }
    if (roots.length != 1) {
      throw const SboxException(SboxErrorCode.shardConflict, 'Bundle 存在多个根分片');
    }
    final root = roots.single;
    final rootHeader = root.header;
    final rootId = hexLower(rootHeader.bundleId);
    final recipientId = hexLower(rootHeader.recipientKeyId);
    final byIndex = <int, _ParsedObject>{};
    for (final object in parsed) {
      final header = object.header;
      if (hexLower(header.bundleId) != rootId ||
          hexLower(header.recipientKeyId) != recipientId ||
          header.shardCount != rootHeader.shardCount ||
          byIndex.containsKey(header.shardIndex)) {
        throw const SboxException(
          SboxErrorCode.shardConflict,
          'Bundle 分片身份或索引冲突',
        );
      }
      byIndex[header.shardIndex] = object;
    }
    if (byIndex.length != rootHeader.shardCount ||
        List<int>.generate(
          rootHeader.shardCount,
          (index) => index,
        ).any((index) => !byIndex.containsKey(index))) {
      throw const SboxException(SboxErrorCode.shardMissing, 'Bundle 缺少必要分片');
    }

    EphemeralIdentity? identity;
    Uint8List? bundleDek;
    try {
      identity = await SboxIdentityDeriver().deriveIdentity(mnemonic);
      if (expectedIdentity != null &&
          !constantTimeBytesEqual(
            identity.publicIdentity.recipientKeyId,
            expectedIdentity.recipientKeyId,
          )) {
        throw const SboxException(SboxErrorCode.keyMismatch, '助记词与当前身份不匹配');
      }
      if (!constantTimeBytesEqual(
        identity.publicIdentity.recipientKeyId,
        rootHeader.recipientKeyId,
      )) {
        throw const SboxException(
          SboxErrorCode.keyMismatch,
          '助记词与 Bundle 身份不匹配',
        );
      }
      final label = RsaOaepSha256.buildBundleDekLabel(
        bundleId: rootHeader.bundleId,
        recipientKeyId: rootHeader.recipientKeyId,
      );
      try {
        bundleDek = RsaOaepSha256().decrypt(
          ciphertext: rootHeader.wrappedBundleDek,
          privateKey: identity.rsaPrivateKey,
          label: label,
        );
      } on SboxException {
        throw const SboxException(SboxErrorCode.authentication, '密钥解封或密文认证失败');
      } finally {
        identity.disposeControlledSecrets();
        identity = null;
      }
      if (bundleDek.length != SboxProtocol.bundleDekLength) {
        throw const SboxException(SboxErrorCode.authentication, '密钥解封或密文认证失败');
      }

      final rootHeaderHash = sha256Bytes(
        root.bytes.sublist(0, rootHeader.headerLength),
      );
      final rootManifestRecord = _records.parseAt(
        root.bytes,
        rootHeader.headerLength,
        maximumPlaintextLength: SboxProtocol.maxManifestBytes,
      );
      if (rootManifestRecord.type != BundleRecordType.manifest ||
          rootManifestRecord.index != BigInt.zero ||
          rootManifestRecord.plaintextLength < 1) {
        throw const SboxException(
          SboxErrorCode.invalidManifest,
          '根分片缺少 Manifest',
        );
      }
      final rootKey = ShardKdf.derive(
        bundleDek: bundleDek,
        bundleId: rootHeader.bundleId,
        recipientKeyId: rootHeader.recipientKeyId,
        shardIndex: 0,
      );
      final manifestBytes = await _records.decrypt(
        record: rootManifestRecord,
        shardKey: rootKey,
        noncePrefix: rootHeader.noncePrefix,
        headerHash: rootHeaderHash,
      );
      rootKey.fillRange(0, rootKey.length, 0);
      final manifest = BundleManifest.parse(manifestBytes);
      manifestBytes.fillRange(0, manifestBytes.length, 0);
      manifest.validateAgainstHeader(rootHeader);
      for (final object in parsed) {
        if (manifest.expectedShardPlaintextSize(object.header.shardIndex) !=
            object.header.shardPlaintextSize) {
          throw const SboxException(
            SboxErrorCode.shardMismatch,
            '分片长度与 Manifest 不一致',
          );
        }
      }

      final output = BytesBuilder(copy: false);
      final overallAccumulator = HashDigestSink();
      final overallHashSink = crypto.sha256.startChunkedConversion(
        overallAccumulator,
      );
      var overallLength = 0;
      for (var index = 0; index < rootHeader.shardCount; index++) {
        final object = byIndex[index]!;
        final result = await _decryptShard(
          object,
          manifest,
          bundleDek,
          overallHashSink,
        );
        output.add(result.bytes);
        overallLength += result.length;
      }
      overallHashSink.close();
      final digest = Uint8List.fromList(overallAccumulator.value.bytes);
      if (overallLength != manifest.logicalPlaintextSize.toInt() ||
          !constantTimeBytesEqual(digest, manifest.logicalPlaintextSha256)) {
        throw const SboxException(SboxErrorCode.integrity, 'Bundle 整体完整性校验失败');
      }
      final plaintext = output.takeBytes();
      if (manifest.contentKind == SboxContentKind.text) {
        try {
          utf8.decode(plaintext, allowMalformed: false);
        } on FormatException {
          plaintext.fillRange(0, plaintext.length, 0);
          throw const SboxException(SboxErrorCode.integrity, '文本明文不是严格 UTF-8');
        }
      }
      return DecryptedBundle(
        manifest: manifest,
        rootHeader: rootHeader,
        plaintext: plaintext,
      );
    } on SboxException {
      rethrow;
    } catch (_) {
      throw const SboxException(SboxErrorCode.authentication, '密钥解封或密文认证失败');
    } finally {
      identity?.disposeControlledSecrets();
      bundleDek?.fillRange(0, bundleDek.length, 0);
    }
  }

  Future<DecryptedBundle> decryptBytes({
    required List<List<int>> shardBytes,
    required String mnemonic,
  }) async {
    final objects = <String, List<int>>{};
    for (final bytes in shardBytes) {
      final header = BundleHeader.parse(bytes);
      final basename = header.canonicalBasename;
      if (objects.containsKey(basename)) {
        throw const SboxException(SboxErrorCode.shardConflict, 'Bundle 分片路径重复');
      }
      objects[basename] = bytes;
    }
    return decrypt(objects: objects, mnemonic: mnemonic);
  }

  /// Publishes plaintext only after [decrypt] has authenticated every object.
  /// The temporary file is created beside the destination so the final rename
  /// stays on one filesystem. Existing destinations are never overwritten.
  Future<void> decryptToFile({
    required Map<String, List<int>> objects,
    required String mnemonic,
    required File destination,
  }) async {
    return _decryptToFileStreaming(
      objects: objects,
      mnemonic: mnemonic,
      destination: destination,
    );
    /*
    final decrypted = await decrypt(objects: objects, mnemonic: mnemonic);
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
        '鏄庢枃鐩殑宸插瓨鍦ㄤ笖涓嶅厑璁告 覆盖',
      );
    }
    final stage = File(
      '${parent.path}${Platform.pathSeparator}.sbox-plaintext-${hexLower(secureRandomBytes(8))}.part',
    );
    try {
      await stage.writeAsBytes(decrypted.plaintext, flush: true);
      await stage.rename(destination.path);
    } on FileSystemException {
      throw const SboxException(SboxErrorCode.temporaryCleanup, '鏄庢枃鍙戝竷澶辫触');
    } finally {
      decrypted.plaintext.fillRange(0, decrypted.plaintext.length, 0);
      if (await stage.exists()) await stage.delete();
    }
    */
  }

  Future<void> _decryptToFileStreaming({
    required Map<String, List<int>> objects,
    required String mnemonic,
    required File destination,
  }) async {
    if (objects.isEmpty) {
      throw const SboxException(
        SboxErrorCode.rootRequired,
        'A root SBOX shard is required',
      );
    }
    final parsed = <_ParsedObject>[];
    for (final entry in objects.entries) {
      final path = parseCanonicalBundleBasename(entry.key);
      final bytes = Uint8List.fromList(entry.value);
      final header = BundleHeader.parse(bytes);
      validateBundlePathAgainstHeader(entry.key, header);
      parsed.add(_ParsedObject(entry.key, bytes, header, path));
    }
    parsed.sort(
      (left, right) =>
          left.header.shardIndex.compareTo(right.header.shardIndex),
    );
    final roots = parsed
        .where((object) => object.header.isRoot)
        .toList(growable: false);
    if (roots.length != 1) {
      throw SboxException(
        roots.isEmpty
            ? SboxErrorCode.rootRequired
            : SboxErrorCode.shardConflict,
        roots.isEmpty
            ? 'A root SBOX shard is required'
            : 'Multiple root shards were supplied',
      );
    }
    final root = roots.single;
    final rootHeader = root.header;
    final byIndex = <int, _ParsedObject>{};
    for (final object in parsed) {
      final header = object.header;
      if (!constantTimeBytesEqual(header.bundleId, rootHeader.bundleId) ||
          !constantTimeBytesEqual(
            header.recipientKeyId,
            rootHeader.recipientKeyId,
          ) ||
          header.shardCount != rootHeader.shardCount ||
          byIndex.containsKey(header.shardIndex)) {
        throw const SboxException(
          SboxErrorCode.shardConflict,
          'Bundle shard identity or index conflict',
        );
      }
      byIndex[header.shardIndex] = object;
    }
    if (byIndex.length != rootHeader.shardCount ||
        List<int>.generate(
          rootHeader.shardCount,
          (index) => index,
        ).any((index) => !byIndex.containsKey(index))) {
      throw const SboxException(
        SboxErrorCode.shardMissing,
        'Bundle is missing a required shard',
      );
    }

    EphemeralIdentity? identity;
    Uint8List? bundleDek;
    try {
      identity = await SboxIdentityDeriver().deriveIdentity(mnemonic);
      if (!constantTimeBytesEqual(
        identity.publicIdentity.recipientKeyId,
        rootHeader.recipientKeyId,
      )) {
        throw const SboxException(
          SboxErrorCode.keyMismatch,
          'Mnemonic does not match the Bundle identity',
        );
      }
      try {
        bundleDek = RsaOaepSha256().decrypt(
          ciphertext: rootHeader.wrappedBundleDek,
          privateKey: identity.rsaPrivateKey,
          label: RsaOaepSha256.buildBundleDekLabel(
            bundleId: rootHeader.bundleId,
            recipientKeyId: rootHeader.recipientKeyId,
          ),
        );
      } on SboxException {
        throw const SboxException(
          SboxErrorCode.authentication,
          'Bundle key authentication failed',
        );
      } finally {
        identity.disposeControlledSecrets();
        identity = null;
      }

      final rootManifestRecord = _records.parseAt(
        root.bytes,
        rootHeader.headerLength,
        maximumPlaintextLength: SboxProtocol.maxManifestBytes,
      );
      if (rootManifestRecord.type != BundleRecordType.manifest ||
          rootManifestRecord.index != BigInt.zero ||
          rootManifestRecord.plaintextLength < 1) {
        throw const SboxException(
          SboxErrorCode.invalidManifest,
          'Root shard does not start with a valid Manifest record',
        );
      }
      final rootKey = ShardKdf.derive(
        bundleDek: bundleDek,
        bundleId: rootHeader.bundleId,
        recipientKeyId: rootHeader.recipientKeyId,
        shardIndex: 0,
      );
      Uint8List manifestBytes;
      try {
        manifestBytes = await _records.decrypt(
          record: rootManifestRecord,
          shardKey: rootKey,
          noncePrefix: rootHeader.noncePrefix,
          headerHash: sha256Bytes(
            root.bytes.sublist(0, rootHeader.headerLength),
          ),
        );
      } finally {
        rootKey.fillRange(0, rootKey.length, 0);
      }
      final manifest = BundleManifest.parse(manifestBytes);
      manifestBytes.fillRange(0, manifestBytes.length, 0);
      manifest.validateAgainstHeader(rootHeader);
      for (final object in parsed) {
        if (manifest.expectedShardPlaintextSize(object.header.shardIndex) !=
            object.header.shardPlaintextSize) {
          throw const SboxException(
            SboxErrorCode.shardMismatch,
            'Shard length does not match the Manifest',
          );
        }
      }

      final parent = destination.parent;
      await parent.create(recursive: true);
      if (await FileSystemEntity.type(destination.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const SboxException(
          SboxErrorCode.immutableConflict,
          'Destination already exists and will not be overwritten',
        );
      }
      final stage = File(
        '${parent.path}${Platform.pathSeparator}.sbox-plaintext-${hexLower(secureRandomBytes(8))}.part',
      );
      IOSink? output;
      var renamed = false;
      try {
        output = stage.openWrite();
        final overallAccumulator = HashDigestSink();
        final overallHashSink = crypto.sha256.startChunkedConversion(
          overallAccumulator,
        );
        final textSink = manifest.contentKind == SboxContentKind.text
            ? utf8.decoder.startChunkedConversion(_DiscardStringSink())
            : null;
        var overallLength = 0;
        for (var index = 0; index < rootHeader.shardCount; index++) {
          final result = await _decryptShard(
            byIndex[index]!,
            manifest,
            bundleDek,
            overallHashSink,
            plaintextSink: output,
            textSink: textSink,
          );
          overallLength += result.length;
          result.bytes.fillRange(0, result.bytes.length, 0);
        }
        overallHashSink.close();
        final digest = Uint8List.fromList(overallAccumulator.value.bytes);
        try {
          if (BigInt.from(overallLength) != manifest.logicalPlaintextSize ||
              !constantTimeBytesEqual(
                digest,
                manifest.logicalPlaintextSha256,
              )) {
            throw const SboxException(
              SboxErrorCode.integrity,
              'Overall plaintext verification failed',
            );
          }
        } finally {
          digest.fillRange(0, digest.length, 0);
        }
        try {
          textSink?.close();
        } on FormatException {
          throw const SboxException(
            SboxErrorCode.integrity,
            'Plaintext is not strict UTF-8',
          );
        }
        await output.flush();
        await output.close();
        output = null;
        await stage.rename(destination.path);
        renamed = true;
      } on FileSystemException {
        throw const SboxException(
          SboxErrorCode.temporaryCleanup,
          'Unable to publish the verified plaintext',
        );
      } finally {
        await output?.close();
        if (!renamed && await stage.exists()) await stage.delete();
      }
    } on SboxException {
      rethrow;
    } catch (_) {
      throw const SboxException(
        SboxErrorCode.authentication,
        'Bundle authentication failed',
      );
    } finally {
      identity?.disposeControlledSecrets();
      bundleDek?.fillRange(0, bundleDek.length, 0);
    }
  }

  Future<_ShardPlaintext> _decryptShard(
    _ParsedObject object,
    BundleManifest manifest,
    List<int> bundleDek,
    ByteConversionSink overallHashSink, {
    IOSink? plaintextSink,
    Sink<List<int>>? textSink,
  }) async {
    final header = object.header;
    final headerHash = sha256Bytes(
      object.bytes.sublist(0, header.headerLength),
    );
    var offset = header.headerLength;
    var expectedIndex = BigInt.one;
    var dataCount = 0;
    var dataLength = 0;
    var sawShort = false;
    final shardOutput = plaintextSink == null
        ? BytesBuilder(copy: false)
        : null;
    final shardAccumulator = HashDigestSink();
    final shardHashSink = crypto.sha256.startChunkedConversion(
      shardAccumulator,
    );
    final shardKey = ShardKdf.derive(
      bundleDek: bundleDek,
      bundleId: header.bundleId,
      recipientKeyId: header.recipientKeyId,
      shardIndex: header.shardIndex,
    );
    try {
      if (header.isRoot) {
        final manifestRecord = _records.parseAt(
          object.bytes,
          offset,
          maximumPlaintextLength: SboxProtocol.maxManifestBytes,
        );
        if (manifestRecord.type != BundleRecordType.manifest ||
            manifestRecord.index != BigInt.zero) {
          throw const SboxException(SboxErrorCode.invalidRecord, '根记录顺序无效');
        }
        // Re-authenticate the Manifest while processing the root in order to
        // avoid treating a prefix probe as full Bundle verification.
        final authenticated = await _records.decrypt(
          record: manifestRecord,
          shardKey: shardKey,
          noncePrefix: header.noncePrefix,
          headerHash: headerHash,
        );
        final rechecked = BundleManifest.parse(authenticated);
        authenticated.fillRange(0, authenticated.length, 0);
        if (rechecked.encode().length != manifest.encode().length ||
            !constantTimeBytesEqual(rechecked.encode(), manifest.encode())) {
          throw const SboxException(
            SboxErrorCode.shardMismatch,
            'Manifest 重认证不一致',
          );
        }
        offset = manifestRecord.nextOffset;
      }
      while (true) {
        final record = _records.parseAt(
          object.bytes,
          offset,
          maximumPlaintextLength: SboxProtocol.chunkSize,
        );
        if (record.index != expectedIndex) {
          throw const SboxException(
            SboxErrorCode.invalidRecord,
            'SBOX 记录索引不连续',
          );
        }
        if (record.type == BundleRecordType.finalRecord) {
          if (record.plaintextLength != SboxProtocol.finalPlaintextLength) {
            throw const SboxException(
              SboxErrorCode.invalidRecord,
              'Final 记录长度无效',
            );
          }
          final finalBytes = await _records.decrypt(
            record: record,
            shardKey: shardKey,
            noncePrefix: header.noncePrefix,
            headerHash: headerHash,
          );
          final finalRecord = BundleFinalRecord.parse(finalBytes);
          finalBytes.fillRange(0, finalBytes.length, 0);
          shardHashSink.close();
          final shardDigest = Uint8List.fromList(shardAccumulator.value.bytes);
          if (record.nextOffset != object.bytes.length ||
              (header.shardIndex > 0 && dataCount == 0) ||
              finalRecord.totalDataLength != BigInt.from(dataLength) ||
              finalRecord.dataRecordCount != BigInt.from(dataCount) ||
              finalRecord.totalDataLength != header.shardPlaintextSize ||
              !constantTimeBytesEqual(finalRecord.dataSha256, shardDigest)) {
            throw const SboxException(
              SboxErrorCode.integrity,
              '分片 Final 完整性校验失败',
            );
          }
          shardDigest.fillRange(0, shardDigest.length, 0);
          return _ShardPlaintext(
            bytes: plaintextSink == null
                ? shardOutput!.takeBytes()
                : Uint8List(0),
            length: dataLength,
          );
        }
        if (record.type != BundleRecordType.data ||
            record.plaintextLength == 0 ||
            sawShort) {
          throw const SboxException(
            SboxErrorCode.invalidRecord,
            'Data 记录顺序或长度无效',
          );
        }
        final plaintext = await _records.decrypt(
          record: record,
          shardKey: shardKey,
          noncePrefix: header.noncePrefix,
          headerHash: headerHash,
        );
        if (plaintext.length != record.plaintextLength ||
            plaintext.length > SboxProtocol.chunkSize) {
          throw const SboxException(SboxErrorCode.integrity, 'Data 记录长度不一致');
        }
        shardHashSink.add(plaintext);
        overallHashSink.add(plaintext);
        try {
          textSink?.add(plaintext);
        } on FormatException {
          throw const SboxException(
            SboxErrorCode.integrity,
            'Plaintext is not strict UTF-8',
          );
        }
        // The plaintext buffer is wiped immediately below; copy it into the
        // verified output before that wipe because BytesBuilder(copy:false)
        // may retain the supplied buffer.
        if (plaintextSink == null) {
          shardOutput!.add(Uint8List.fromList(plaintext));
        } else {
          plaintextSink.add(plaintext);
          await plaintextSink.flush();
        }
        dataLength += plaintext.length;
        dataCount++;
        sawShort = plaintext.length < SboxProtocol.chunkSize;
        plaintext.fillRange(0, plaintext.length, 0);
        expectedIndex += BigInt.one;
        offset = record.nextOffset;
      }
    } finally {
      shardKey.fillRange(0, shardKey.length, 0);
    }
  }
}

final class _ShardPlaintext {
  const _ShardPlaintext({required this.bytes, required this.length});

  final Uint8List bytes;
  final int length;
}

final class _DiscardStringSink implements Sink<String> {
  @override
  void add(String value) {}

  @override
  void close() {}
}

final class _ParsedObject {
  const _ParsedObject(this.basename, this.bytes, this.header, this.path);

  final String basename;
  final Uint8List bytes;
  final BundleHeader header;
  final BundlePathInfo path;
}
