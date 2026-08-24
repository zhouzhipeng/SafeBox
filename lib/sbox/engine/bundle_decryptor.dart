import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show kIsWeb;

import '../bytes.dart';
import '../constants.dart';
import '../crypto/rsa_oaep.dart';
import '../crypto/shard_kdf.dart';
import '../errors.dart';
import '../format/bundle_header.dart';
import '../format/bundle_manifest.dart';
import '../format/bundle_path.dart';
import '../format/bundle_record.dart';
import '../format/bundle_preview.dart';
import '../identity/bip39_identity.dart';
import '../identity/rsa_models.dart';
import 'bundle_probe.dart';

final class DecryptedBundle {
  DecryptedBundle({
    required this.manifest,
    required this.rootHeader,
    required List<int> plaintext,
    this.preview,
    this.status = BundleTrustStatus.complete,
  }) : plaintext = Uint8List.fromList(plaintext);

  final BundleManifest manifest;
  final BundleHeader rootHeader;
  final Uint8List plaintext;
  final BundlePreview? preview;
  final BundleTrustStatus status;

  bool get rootAuthenticated =>
      status.index >= BundleTrustStatus.rootAuthenticated.index;

  bool get complete => status == BundleTrustStatus.complete;
}

enum BundleDecryptionStage { decrypting, merging }

final class BundleDecryptionProgress {
  const BundleDecryptionProgress({
    required this.stage,
    required this.processedBytes,
    required this.totalBytes,
    required this.completedShards,
    required this.totalShards,
    this.currentShardIndex,
  });

  final BundleDecryptionStage stage;
  final int processedBytes;
  final int totalBytes;
  final int completedShards;
  final int totalShards;
  final int? currentShardIndex;

  double? get fraction => totalBytes <= 0
      ? (processedBytes == totalBytes ? 1 : null)
      : (processedBytes / totalBytes).clamp(0, 1).toDouble();
}

final class BundleDecryptor {
  BundleDecryptor({BundleRecordCodec? records})
    : _records = records ?? BundleRecordCodec(),
      _canUseShardIsolates = records == null;

  final BundleRecordCodec _records;
  final bool _canUseShardIsolates;

  /// Authenticates the root records and the Header Manifest without
  /// downloading or exposing continuation plaintext. This is the explicit
  /// transition from metadataReadable to rootAuthenticated.
  Future<BundleProbeResult> authenticateRoot({
    required Map<String, List<int>> objects,
    required String mnemonic,
    PublicIdentity? expectedIdentity,
  }) async {
    if (objects.isEmpty) {
      throw const SboxException(SboxErrorCode.rootRequired, '需要对应的 SBOX 根分片');
    }
    _ParsedObject? root;
    for (final entry in objects.entries) {
      final candidate = _parseObject(entry.key, entry.value);
      if (candidate.header.isRoot) {
        if (root != null) {
          throw const SboxException(
            SboxErrorCode.shardConflict,
            'Bundle 存在多个根分片',
          );
        }
        root = candidate;
      }
    }
    if (root == null) {
      throw const SboxException(SboxErrorCode.rootRequired, '需要对应的 SBOX 根分片');
    }
    return _authenticateRootObject(
      root,
      mnemonic: mnemonic,
      expectedIdentity: expectedIdentity,
    );
  }

  Future<BundleProbeResult> authenticateRootObject({
    required String basename,
    required List<int> rootBytes,
    required String mnemonic,
    PublicIdentity? expectedIdentity,
  }) async {
    final root = _parseObject(basename, rootBytes);
    if (!root.header.isRoot) {
      throw const SboxException(SboxErrorCode.rootRequired, '需要对应的 SBOX 根分片');
    }
    return _authenticateRootObject(
      root,
      mnemonic: mnemonic,
      expectedIdentity: expectedIdentity,
    );
  }

  /// [objects] must contain the original relative basename for every object.
  /// The root object is the only discovery and submission entry point.
  Future<DecryptedBundle> decrypt({
    required Map<String, List<int>> objects,
    required String mnemonic,
    PublicIdentity? expectedIdentity,
    void Function(BundleDecryptionProgress progress)? onProgress,
  }) async {
    final parsed = _parseObjects(objects);
    final root = parsed.root;
    EphemeralIdentity? identity;
    Uint8List? bundleDek;
    try {
      final deriver = SboxIdentityDeriver();
      identity = kIsWeb
          ? await deriver.deriveIdentityCooperatively(mnemonic)
          : await deriver.deriveIdentity(mnemonic);
      if (expectedIdentity != null &&
          !constantTimeBytesEqual(
            identity.publicIdentity.spkiDer,
            expectedIdentity.spkiDer,
          )) {
        throw const SboxException(SboxErrorCode.keyMismatch, '助记词与公共身份不匹配');
      }
      if (!constantTimeBytesEqual(
        identity.publicIdentity.recipientKeyId,
        root.header.recipientKeyId,
      )) {
        throw const SboxException(
          SboxErrorCode.keyMismatch,
          '助记词与 Bundle 身份不匹配',
        );
      }

      final identityForMetadata = expectedIdentity ?? identity.publicIdentity;
      final fast = await BundleProbe.readMetadata(
        basename: root.basename,
        objectPrefix: root.bytes.sublist(0, root.header.headerLength),
        identity: identityForMetadata,
      );
      final manifest = fast.manifest!;
      _validateManifestAgainstBundle(manifest, parsed);
      final totalPlaintextBytes = manifest.logicalPlaintextSize.toInt();
      _emitProgress(
        onProgress,
        BundleDecryptionProgress(
          stage: BundleDecryptionStage.decrypting,
          processedBytes: 0,
          totalBytes: totalPlaintextBytes,
          completedShards: 0,
          totalShards: root.header.shardCount,
        ),
      );

      try {
        bundleDek = RsaOaepSha256().decrypt(
          ciphertext: root.header.wrappedBundleDek,
          privateKey: identity.rsaPrivateKey,
          label: RsaOaepSha256.buildBundleDekLabel(
            bundleId: root.header.bundleId,
            recipientKeyId: root.header.recipientKeyId,
          ),
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

      final output = BytesBuilder(copy: false);
      final overallAccumulator = HashDigestSink();
      final overallHashSink = crypto.sha256.startChunkedConversion(
        overallAccumulator,
      );
      var overallLength = 0;
      final shardPlaintexts = await _decryptShards(
        parsed.objects,
        bundleDek,
        totalPlaintextBytes: totalPlaintextBytes,
        onProgress: onProgress,
      );
      final heldShardPlaintexts = <Uint8List>[
        for (final shardPlaintext in shardPlaintexts) shardPlaintext.bytes,
      ];
      try {
        for (var index = 0; index < root.header.shardCount; index++) {
          final result = shardPlaintexts[index];
          overallHashSink.add(result.bytes);
          output.add(result.bytes);
          overallLength += result.length;
        }
      } catch (_) {
        for (final shardPlaintext in heldShardPlaintexts) {
          shardPlaintext.fillRange(0, shardPlaintext.length, 0);
        }
        rethrow;
      }
      try {
        overallHashSink.close();
      } catch (_) {
        for (final shardPlaintext in heldShardPlaintexts) {
          shardPlaintext.fillRange(0, shardPlaintext.length, 0);
        }
        rethrow;
      }
      final digest = Uint8List.fromList(overallAccumulator.value.bytes);
      try {
        if (BigInt.from(overallLength) != manifest.logicalPlaintextSize ||
            !constantTimeBytesEqual(digest, manifest.logicalPlaintextSha256)) {
          throw const SboxException(
            SboxErrorCode.integrity,
            'Bundle 整体完整性校验失败',
          );
        }
      } catch (_) {
        for (final shardPlaintext in heldShardPlaintexts) {
          shardPlaintext.fillRange(0, shardPlaintext.length, 0);
        }
        rethrow;
      } finally {
        digest.fillRange(0, digest.length, 0);
      }
      final plaintext = output.takeBytes();
      if (manifest.contentKind == SboxContentKind.text) {
        try {
          utf8.decode(plaintext, allowMalformed: false);
        } on FormatException {
          plaintext.fillRange(0, plaintext.length, 0);
          for (final shardPlaintext in heldShardPlaintexts) {
            shardPlaintext.fillRange(0, shardPlaintext.length, 0);
          }
          throw const SboxException(SboxErrorCode.integrity, '文本明文不是严格 UTF-8');
        }
      }
      _emitProgress(
        onProgress,
        BundleDecryptionProgress(
          stage: BundleDecryptionStage.decrypting,
          processedBytes: totalPlaintextBytes,
          totalBytes: totalPlaintextBytes,
          completedShards: root.header.shardCount,
          totalShards: root.header.shardCount,
        ),
      );
      final decrypted = DecryptedBundle(
        manifest: manifest,
        rootHeader: root.header,
        plaintext: plaintext,
        preview: fast.preview,
        status: BundleTrustStatus.complete,
      );
      plaintext.fillRange(0, plaintext.length, 0);
      for (final shardPlaintext in heldShardPlaintexts) {
        shardPlaintext.fillRange(0, shardPlaintext.length, 0);
      }
      return decrypted;
    } on SboxException {
      rethrow;
    } catch (_) {
      throw const SboxException(SboxErrorCode.authentication, 'Bundle 认证失败');
    } finally {
      identity?.disposeControlledSecrets();
      bundleDek?.fillRange(0, bundleDek.length, 0);
    }
  }

  Future<DecryptedBundle> decryptBytes({
    required List<List<int>> shardBytes,
    required String mnemonic,
    PublicIdentity? expectedIdentity,
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
    return decrypt(
      objects: objects,
      mnemonic: mnemonic,
      expectedIdentity: expectedIdentity,
    );
  }

  /// Publishes plaintext only after every root and continuation record has
  /// authenticated. The destination is never overwritten.
  Future<void> decryptToFile({
    required Map<String, List<int>> objects,
    required String mnemonic,
    required File destination,
    PublicIdentity? expectedIdentity,
    void Function(BundleDecryptionProgress progress)? onProgress,
  }) async {
    final decrypted = await decrypt(
      objects: objects,
      mnemonic: mnemonic,
      expectedIdentity: expectedIdentity,
      onProgress: onProgress,
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
        '明文目标已存在且不允许覆盖',
      );
    }
    final stage = File(
      '${parent.path}${Platform.pathSeparator}.sbox-plaintext-${hexLower(secureRandomBytes(8))}.part',
    );
    var renamed = false;
    IOSink? output;
    try {
      final plaintext = decrypted.plaintext;
      _emitProgress(
        onProgress,
        BundleDecryptionProgress(
          stage: BundleDecryptionStage.merging,
          processedBytes: 0,
          totalBytes: plaintext.length,
          completedShards: 0,
          totalShards: 1,
        ),
      );
      output = stage.openWrite();
      var offset = 0;
      while (offset < plaintext.length) {
        final end = offset + SboxProtocol.chunkSize < plaintext.length
            ? offset + SboxProtocol.chunkSize
            : plaintext.length;
        output.add(Uint8List.sublistView(plaintext, offset, end));
        await output.flush();
        offset = end;
        _emitProgress(
          onProgress,
          BundleDecryptionProgress(
            stage: BundleDecryptionStage.merging,
            processedBytes: offset,
            totalBytes: plaintext.length,
            completedShards: 1,
            totalShards: 1,
          ),
        );
      }
      await output.flush();
      _emitProgress(
        onProgress,
        BundleDecryptionProgress(
          stage: BundleDecryptionStage.merging,
          processedBytes: plaintext.length,
          totalBytes: plaintext.length,
          completedShards: 1,
          totalShards: 1,
        ),
      );
      await output.close();
      output = null;
      await stage.rename(destination.path);
      renamed = true;
    } on FileSystemException {
      throw const SboxException(SboxErrorCode.temporaryCleanup, '明文发布失败');
    } finally {
      await output?.close();
      decrypted.plaintext.fillRange(0, decrypted.plaintext.length, 0);
      if (!renamed && await stage.exists()) await stage.delete();
    }
  }

  _ParsedBundle _parseObjects(Map<String, List<int>> objects) {
    if (objects.isEmpty) {
      throw const SboxException(SboxErrorCode.rootRequired, '需要对应的 SBOX 根分片');
    }
    final parsed = <_ParsedObject>[];
    for (final entry in objects.entries) {
      parsed.add(_parseObject(entry.key, entry.value));
    }
    parsed.sort(
      (left, right) =>
          left.header.shardIndex.compareTo(right.header.shardIndex),
    );
    final roots = parsed.where((object) => object.header.isRoot).toList();
    if (roots.isEmpty) {
      throw const SboxException(SboxErrorCode.rootRequired, '需要对应的 SBOX 根分片');
    }
    if (roots.length != 1) {
      throw const SboxException(SboxErrorCode.shardConflict, 'Bundle 存在多个根分片');
    }
    final root = roots.single;
    final byIndex = <int, _ParsedObject>{};
    for (final object in parsed) {
      final header = object.header;
      if (header.version != root.header.version) {
        throw const SboxException(
          SboxErrorCode.shardMismatch,
          'Bundle 分片版本不一致',
        );
      }
      if (!constantTimeBytesEqual(header.bundleId, root.header.bundleId) ||
          !constantTimeBytesEqual(
            header.recipientKeyId,
            root.header.recipientKeyId,
          ) ||
          header.shardCount != root.header.shardCount ||
          byIndex.containsKey(header.shardIndex)) {
        throw const SboxException(
          SboxErrorCode.shardConflict,
          'Bundle 分片身份或索引冲突',
        );
      }
      byIndex[header.shardIndex] = object;
    }
    if (byIndex.length != root.header.shardCount ||
        List<int>.generate(
          root.header.shardCount,
          (index) => index,
        ).any((index) => !byIndex.containsKey(index))) {
      throw const SboxException(SboxErrorCode.shardMissing, 'Bundle 缺少必要分片');
    }
    return _ParsedBundle(
      root: root,
      byIndex: byIndex,
      objects: List<_ParsedObject>.unmodifiable(parsed),
    );
  }

  Future<BundleProbeResult> _authenticateRootObject(
    _ParsedObject root, {
    required String mnemonic,
    required PublicIdentity? expectedIdentity,
  }) async {
    EphemeralIdentity? identity;
    Uint8List? bundleDek;
    try {
      final deriver = SboxIdentityDeriver();
      identity = kIsWeb
          ? await deriver.deriveIdentityCooperatively(mnemonic)
          : await deriver.deriveIdentity(mnemonic);
      if (expectedIdentity != null &&
          !constantTimeBytesEqual(
            identity.publicIdentity.spkiDer,
            expectedIdentity.spkiDer,
          )) {
        throw const SboxException(SboxErrorCode.keyMismatch, '助记词与公共身份不匹配');
      }
      if (!constantTimeBytesEqual(
        identity.publicIdentity.recipientKeyId,
        root.header.recipientKeyId,
      )) {
        throw const SboxException(
          SboxErrorCode.keyMismatch,
          '助记词与 Bundle 身份不匹配',
        );
      }
      final fast = await BundleProbe.readMetadata(
        basename: root.basename,
        objectPrefix: root.bytes.sublist(0, root.header.headerLength),
        identity: expectedIdentity ?? identity.publicIdentity,
      );
      try {
        bundleDek = RsaOaepSha256().decrypt(
          ciphertext: root.header.wrappedBundleDek,
          privateKey: identity.rsaPrivateKey,
          label: RsaOaepSha256.buildBundleDekLabel(
            bundleId: root.header.bundleId,
            recipientKeyId: root.header.recipientKeyId,
          ),
        );
      } on SboxException {
        throw const SboxException(SboxErrorCode.authentication, '密钥解封或密文认证失败');
      } finally {
        identity.disposeControlledSecrets();
        identity = null;
      }
      final plaintext = await _decryptShard(root, bundleDek);
      plaintext.bytes.fillRange(0, plaintext.bytes.length, 0);
      return BundleProbeResult(
        basename: fast.basename,
        header: fast.header,
        manifest: fast.manifest,
        metadata: fast.metadata,
        status: BundleTrustStatus.rootAuthenticated,
      );
    } on SboxException {
      rethrow;
    } catch (_) {
      throw const SboxException(SboxErrorCode.authentication, '根分片认证失败');
    } finally {
      identity?.disposeControlledSecrets();
      bundleDek?.fillRange(0, bundleDek.length, 0);
    }
  }

  _ParsedObject _parseObject(String basename, List<int> bytes) {
    final path = parseCanonicalBundleBasename(basename);
    final copy = Uint8List.fromList(bytes);
    final header = BundleHeader.parse(copy);
    validateBundlePathAgainstHeader(basename, header);
    return _ParsedObject(basename, copy, header, path);
  }

  static void _validateManifestAgainstBundle(
    BundleManifest manifest,
    _ParsedBundle parsed,
  ) {
    manifest.validateAgainstHeader(parsed.root.header);
    for (final object in parsed.objects) {
      if (manifest.expectedShardPlaintextSize(object.header.shardIndex) !=
          object.header.shardPlaintextSize) {
        throw const SboxException(
          SboxErrorCode.shardMismatch,
          '分片长度与 Manifest 不一致',
        );
      }
    }
  }

  /// Decrypts independent shards concurrently, but leaves the overall hash
  /// and plaintext publication to the caller so they can remain ordered.
  Future<List<_ShardPlaintext>> _decryptShards(
    List<_ParsedObject> objects,
    List<int> bundleDek, {
    required int totalPlaintextBytes,
    void Function(BundleDecryptionProgress progress)? onProgress,
  }) async {
    if (objects.isEmpty) return <_ShardPlaintext>[];
    final results = List<_ShardPlaintext?>.filled(objects.length, null);
    final workerCount = _shardWorkerCount(objects.length);
    var nextIndex = 0;
    var completedShards = 0;
    var processedBytes = 0;

    Future<void> worker() async {
      while (true) {
        if (nextIndex >= objects.length) return;
        final index = nextIndex++;
        final object = objects[index];
        final result = _canUseShardIsolates && !kIsWeb
            ? await _decryptShardInIsolate(object, bundleDek)
            : await _decryptShard(object, bundleDek);
        results[index] = result;
        completedShards++;
        processedBytes += result.length;
        _emitProgress(
          onProgress,
          BundleDecryptionProgress(
            stage: BundleDecryptionStage.decrypting,
            processedBytes: processedBytes,
            totalBytes: totalPlaintextBytes,
            completedShards: completedShards,
            totalShards: objects.length,
            currentShardIndex: object.header.shardIndex,
          ),
        );
      }
    }

    try {
      await Future.wait(<Future<void>>[
        for (var index = 0; index < workerCount; index++) worker(),
      ]);
      return <_ShardPlaintext>[for (final result in results) result!];
    } catch (_) {
      _wipeNullableShardPlaintexts(results);
      rethrow;
    }
  }

  int _shardWorkerCount(int shardCount) {
    if (kIsWeb) return 1;
    final processorCount = Platform.numberOfProcessors;
    final parallelism = processorCount < 2
        ? 1
        : processorCount > 4
        ? 4
        : processorCount;
    return parallelism > shardCount ? shardCount : parallelism;
  }

  Future<_ShardPlaintext> _decryptShardInIsolate(
    _ParsedObject object,
    List<int> bundleDek,
  ) async {
    final request = _ShardDecryptRequest(
      basename: object.basename,
      bytes: TransferableTypedData.fromList(<TypedData>[object.bytes]),
      bundleDek: Uint8List.fromList(bundleDek),
    );
    final response = await Isolate.run<_TransferredShardPlaintext>(
      () => _decryptShardWorker(request),
      debugName: 'safebox-decrypt-shard-${object.header.shardIndex}',
    );
    final bytes = response.bytes.materialize().asUint8List();
    if (bytes.length != response.length) {
      bytes.fillRange(0, bytes.length, 0);
      throw const SboxException(
        SboxErrorCode.authentication,
        'Bundle 鍒嗙墖瑙ｅ瘑缁撴灉鏃犳晥',
      );
    }
    return _ShardPlaintext(bytes: bytes, length: response.length);
  }

  Future<_ShardPlaintext> _decryptShard(
    _ParsedObject object,
    List<int> bundleDek,
  ) async {
    final header = object.header;
    final headerHash = sha256Bytes(header.rawBytes);
    final shardKey = ShardKdf.derive(
      bundleDek: bundleDek,
      bundleId: header.bundleId,
      recipientKeyId: header.recipientKeyId,
      shardIndex: header.shardIndex,
    );
    final output = BytesBuilder(copy: false);
    final heldChunks = <Uint8List>[];
    final shardAccumulator = HashDigestSink();
    final shardHashSink = crypto.sha256.startChunkedConversion(
      shardAccumulator,
    );
    var offset = header.headerLength;
    var expectedIndex = BigInt.one;
    var dataCount = 0;
    var dataLength = 0;
    var sawShort = false;
    try {
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
          try {
            if (record.nextOffset != object.bytes.length ||
                (header.shardIndex > 0 && dataCount == 0) ||
                (header.shardPlaintextSize == BigInt.zero && dataCount != 0) ||
                finalRecord.totalDataLength != BigInt.from(dataLength) ||
                finalRecord.dataRecordCount != BigInt.from(dataCount) ||
                finalRecord.totalDataLength != header.shardPlaintextSize ||
                !constantTimeBytesEqual(finalRecord.dataSha256, shardDigest)) {
              throw const SboxException(
                SboxErrorCode.integrity,
                '分片 Final 完整性校验失败',
              );
            }
          } finally {
            shardDigest.fillRange(0, shardDigest.length, 0);
          }
          return _ShardPlaintext(bytes: output.takeBytes(), length: dataLength);
        }
        if (record.type != BundleRecordType.data ||
            record.plaintextLength == 0 ||
            sawShort ||
            header.shardPlaintextSize == BigInt.zero) {
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
        try {
          if (plaintext.length != record.plaintextLength ||
              plaintext.length > SboxProtocol.chunkSize) {
            throw const SboxException(
              SboxErrorCode.invalidRecord,
              'Data 记录长度不一致',
            );
          }
          shardHashSink.add(plaintext);
          final verifiedChunk = Uint8List.fromList(plaintext);
          heldChunks.add(verifiedChunk);
          output.add(verifiedChunk);
          dataLength += plaintext.length;
          dataCount++;
          sawShort = plaintext.length < SboxProtocol.chunkSize;
        } finally {
          plaintext.fillRange(0, plaintext.length, 0);
        }
        expectedIndex += BigInt.one;
        offset = record.nextOffset;
      }
    } catch (_) {
      for (final chunk in heldChunks) {
        chunk.fillRange(0, chunk.length, 0);
      }
      rethrow;
    } finally {
      shardKey.fillRange(0, shardKey.length, 0);
      headerHash.fillRange(0, headerHash.length, 0);
    }
  }

  static void _emitProgress(
    void Function(BundleDecryptionProgress progress)? onProgress,
    BundleDecryptionProgress progress,
  ) {
    try {
      onProgress?.call(progress);
    } on Object {
      // Progress listeners must never be able to interrupt decryption.
    }
  }
}

final class _ShardDecryptRequest {
  const _ShardDecryptRequest({
    required this.basename,
    required this.bytes,
    required this.bundleDek,
  });

  final String basename;
  final TransferableTypedData bytes;
  final Uint8List bundleDek;
}

final class _TransferredShardPlaintext {
  const _TransferredShardPlaintext({required this.bytes, required this.length});

  final TransferableTypedData bytes;
  final int length;
}

Future<_TransferredShardPlaintext> _decryptShardWorker(
  _ShardDecryptRequest request,
) async {
  final shardBytes = request.bytes.materialize().asUint8List();
  try {
    final header = BundleHeader.parse(shardBytes);
    final parsed = _ParsedObject(
      request.basename,
      shardBytes,
      header,
      parseCanonicalBundleBasename(request.basename),
    );
    final plaintext = await BundleDecryptor()._decryptShard(
      parsed,
      request.bundleDek,
    );
    final transferred = TransferableTypedData.fromList(<TypedData>[
      plaintext.bytes,
    ]);
    final length = plaintext.length;
    plaintext.bytes.fillRange(0, plaintext.bytes.length, 0);
    return _TransferredShardPlaintext(bytes: transferred, length: length);
  } finally {
    shardBytes.fillRange(0, shardBytes.length, 0);
    request.bundleDek.fillRange(0, request.bundleDek.length, 0);
  }
}

void _wipeNullableShardPlaintexts(List<_ShardPlaintext?> values) {
  for (final value in values) {
    value?.bytes.fillRange(0, value.bytes.length, 0);
  }
}

final class _ParsedBundle {
  const _ParsedBundle({
    required this.root,
    required this.byIndex,
    required this.objects,
  });

  final _ParsedObject root;
  final Map<int, _ParsedObject> byIndex;
  final List<_ParsedObject> objects;
}

final class _ParsedObject {
  const _ParsedObject(this.basename, this.bytes, this.header, this.path);

  final String basename;
  final Uint8List bytes;
  final BundleHeader header;
  final BundlePathInfo path;
}

final class _ShardPlaintext {
  const _ShardPlaintext({required this.bytes, required this.length});

  final Uint8List bytes;
  final int length;
}
