import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../bytes.dart';
import '../constants.dart';
import '../crypto/metadata_cipher.dart';
import '../crypto/metadata_kdf.dart';
import '../crypto/rsa_oaep.dart';
import '../crypto/shard_kdf.dart';
import '../errors.dart';
import '../format/bundle_header.dart';
import '../format/bundle_manifest.dart';
import '../format/bundle_preview.dart';
import '../format/bundle_record.dart';
import '../format/metadata_block.dart';
import '../format/sbox_version.dart';
import '../../platform/preview_generation_result.dart';
import '../identity/der.dart';
import '../identity/rsa_models.dart';
import '../storage/io_hash.dart';
import 'bundle_planner.dart';

abstract interface class BundleInput {
  Future<int> length();

  Stream<List<int>> openRange(int start, int length);
}

final class MemoryBundleInput implements BundleInput {
  MemoryBundleInput(List<int> bytes) : _bytes = Uint8List.fromList(bytes);

  final Uint8List _bytes;

  /// Returns a copy that can be handed to a background isolate.
  Uint8List get bytes => Uint8List.fromList(_bytes);

  @override
  Future<int> length() async => _bytes.length;

  @override
  Stream<List<int>> openRange(int start, int length) {
    if (start < 0 || length < 0 || start > _bytes.length - length) {
      throw ArgumentError('Invalid input range');
    }
    const transportChunk = 64 * 1024;
    return Stream<List<int>>.fromIterable(<List<int>>[
      for (
        var offset = start;
        offset < start + length;
        offset += transportChunk
      )
        _bytes.sublist(
          offset,
          (offset + transportChunk).clamp(0, start + length),
        ),
    ]);
  }
}

final class FileBundleInput implements BundleInput {
  const FileBundleInput(this.file);

  final File file;

  @override
  Future<int> length() => file.length();

  @override
  Stream<List<int>> openRange(int start, int length) {
    if (start < 0 || length < 0) throw ArgumentError('Invalid input range');
    return file.openRead(start, start + length);
  }
}

final class BundleEncryptionRandomness {
  BundleEncryptionRandomness({
    required List<int> bundleId,
    required List<int> bundleDek,
    required Iterable<List<int>> noncePrefixes,
    required List<int> oaepSeed,
    List<int>? metadataSalt,
    List<int>? metadataNonce,
  }) : bundleId = Uint8List.fromList(bundleId),
       bundleDek = Uint8List.fromList(bundleDek),
       noncePrefixes = List<Uint8List>.unmodifiable(
         noncePrefixes.map(Uint8List.fromList),
       ),
       oaepSeed = Uint8List.fromList(oaepSeed),
       metadataSalt = Uint8List.fromList(
         metadataSalt ?? secureRandomBytes(SboxProtocol.metadataSaltLength),
       ),
       metadataNonce = Uint8List.fromList(
         metadataNonce ?? secureRandomBytes(SboxProtocol.metadataNonceLength),
       ) {
    if (this.bundleId.length != SboxProtocol.bundleIdLength ||
        this.bundleDek.length != SboxProtocol.bundleDekLength ||
        this.oaepSeed.length != 32 ||
        this.metadataSalt.length != SboxProtocol.metadataSaltLength ||
        this.metadataNonce.length != SboxProtocol.metadataNonceLength ||
        this.noncePrefixes.isEmpty ||
        this.noncePrefixes.any(
          (prefix) => prefix.length != SboxProtocol.noncePrefixLength,
        )) {
      throw ArgumentError('Invalid bundle randomness');
    }
  }

  factory BundleEncryptionRandomness.secure(
    int shardCount, {
    required List<int> bundleId,
  }) {
    if (shardCount < 1 || shardCount > SboxProtocol.maxShardCount) {
      throw ArgumentError.value(shardCount, 'shardCount');
    }
    return BundleEncryptionRandomness(
      bundleId: bundleId,
      bundleDek: secureRandomBytes(SboxProtocol.bundleDekLength),
      noncePrefixes: <List<int>>[
        for (var index = 0; index < shardCount; index++)
          secureRandomBytes(SboxProtocol.noncePrefixLength),
      ],
      oaepSeed: secureRandomBytes(32),
      metadataSalt: secureRandomBytes(SboxProtocol.metadataSaltLength),
      metadataNonce: secureRandomBytes(SboxProtocol.metadataNonceLength),
    );
  }

  final Uint8List bundleId;
  final Uint8List bundleDek;
  final List<Uint8List> noncePrefixes;
  final Uint8List oaepSeed;
  final Uint8List metadataSalt;
  final Uint8List metadataNonce;

  void dispose() {
    bundleId.fillRange(0, bundleId.length, 0);
    bundleDek.fillRange(0, bundleDek.length, 0);
    oaepSeed.fillRange(0, oaepSeed.length, 0);
    metadataSalt.fillRange(0, metadataSalt.length, 0);
    metadataNonce.fillRange(0, metadataNonce.length, 0);
    for (final prefix in noncePrefixes) {
      prefix.fillRange(0, prefix.length, 0);
    }
  }
}

final class BundleEncryptionOptions {
  const BundleEncryptionOptions({
    required this.recipient,
    required this.contentKind,
    required this.originalName,
    required this.mediaType,
    this.title,
    this.description = '',
    this.tags = const <String>[],
    this.createdAt,
    this.targetNominalShardPlaintextSize =
        SboxProtocol.defaultNominalShardPlaintextSize,
    this.maxObjectBytes,
    this.preview,
    this.previewRequested = false,
    this.previewUnavailableReason,
    this.randomness,
  });

  final PublicIdentity recipient;
  final SboxContentKind contentKind;
  final String originalName;
  final String mediaType;
  final String? title;
  final String description;
  final List<String> tags;
  final String? createdAt;
  final int targetNominalShardPlaintextSize;
  final int? maxObjectBytes;
  final BundlePreview? preview;
  final bool previewRequested;
  final PreviewUnavailableReason? previewUnavailableReason;
  final BundleEncryptionRandomness? randomness;

  bool get wantsPreview => previewRequested || preview != null;
}

final class EncryptedBundleObject {
  EncryptedBundleObject({
    required this.basename,
    required this.header,
    required List<int> bytes,
    required List<int> sha256,
  }) : bytes = Uint8List.fromList(bytes),
       sha256 = Uint8List.fromList(sha256);

  final String basename;
  final BundleHeader header;
  final Uint8List bytes;
  final Uint8List sha256;
}

final class EncryptedBundle {
  EncryptedBundle({
    required this.manifest,
    required this.objects,
    required List<int> plaintextSha256,
    this.preview,
    this.previewRequested = false,
    this.previewEmbedded = false,
  }) : plaintextSha256 = Uint8List.fromList(plaintextSha256);

  final BundleManifest manifest;
  final List<EncryptedBundleObject> objects;
  final Uint8List plaintextSha256;
  final BundlePreview? preview;
  final bool previewRequested;
  final bool previewEmbedded;

  EncryptedBundleObject get root =>
      objects.firstWhere((object) => object.header.isRoot);
}

/// One unified v3 writer for empty, small and multipart Bundles.
final class BundleEncryptor {
  BundleEncryptor({BundleRecordCodec? records})
    : _records = records ?? BundleRecordCodec();

  final BundleRecordCodec _records;

  Future<EncryptedBundle> encryptBytes({
    required List<int> plaintext,
    required BundleEncryptionOptions options,
  }) => encrypt(
    input: MemoryBundleInput(plaintext),
    declaredLength: plaintext.length,
    options: options,
  );

  /// Returns the MD5 of the original bytes used as the public Bundle ID.
  Future<Uint8List> md5ForInput({
    required BundleInput input,
    required int declaredLength,
    bool validateUtf8 = false,
  }) async {
    if (declaredLength < 0 || await input.length() != declaredLength) {
      throw const SboxException(
        SboxErrorCode.inputChanged,
        'Input length does not match its declaration',
      );
    }
    final hashed = await _hashRange(
      input,
      0,
      declaredLength,
      validateUtf8: validateUtf8,
    );
    return Uint8List.fromList(hashed.md5);
  }

  Future<EncryptedBundle> encrypt({
    required BundleInput input,
    required int declaredLength,
    required BundleEncryptionOptions options,
  }) async {
    final plan = await _preflight(
      input: input,
      declaredLength: declaredLength,
      options: options,
    );
    final firstPass = await _hashRange(
      input,
      0,
      declaredLength,
      validateUtf8: options.contentKind == SboxContentKind.text,
    );
    if (firstPass.length != declaredLength) {
      throw const SboxException(SboxErrorCode.inputChanged, '输入长度与声明不一致');
    }

    final prepared = await _prepare(
      options: options,
      plan: plan,
      firstPass: firstPass,
    );
    final secondAccumulator = HashDigestSink();
    final secondHashSink = crypto.sha256.startChunkedConversion(
      secondAccumulator,
    );
    var secondLength = 0;
    final objects = <EncryptedBundleObject>[];
    try {
      for (final shard in plan.shards) {
        final result = await _encryptShard(
          input: input,
          shard: shard,
          prepared: prepared,
          overallHashSink: secondHashSink,
        );
        secondLength += result.plaintextLength;
        if (options.maxObjectBytes != null &&
            result.bytes.length > options.maxObjectBytes!) {
          throw const SboxException(SboxErrorCode.sourceLimit, '对象超过数据源上限');
        }
        objects.add(
          EncryptedBundleObject(
            basename: result.header.canonicalBasename,
            header: result.header,
            bytes: result.bytes,
            sha256: sha256Bytes(result.bytes),
          ),
        );
      }
      secondHashSink.close();
      final secondDigest = Uint8List.fromList(secondAccumulator.value.bytes);
      try {
        if (secondLength != declaredLength ||
            !constantTimeBytesEqual(secondDigest, firstPass.sha256) ||
            await input.length() != declaredLength) {
          throw const SboxException(SboxErrorCode.inputChanged, '输入在加密期间发生变化');
        }
      } finally {
        secondDigest.fillRange(0, secondDigest.length, 0);
      }
      objects.sort(
        (left, right) =>
            left.header.shardIndex.compareTo(right.header.shardIndex),
      );
      return EncryptedBundle(
        manifest: prepared.manifest,
        objects: List<EncryptedBundleObject>.unmodifiable(objects),
        plaintextSha256: firstPass.sha256,
        preview: prepared.preview?.copy(),
        previewRequested: prepared.previewRequested,
        previewEmbedded: prepared.previewEmbedded,
      );
    } finally {
      prepared.dispose();
    }
  }

  Future<List<String>> encryptToDirectory({
    required BundleInput input,
    required int declaredLength,
    required BundleEncryptionOptions options,
    required Directory root,
  }) async {
    final plan = await _preflight(
      input: input,
      declaredLength: declaredLength,
      options: options,
    );
    final canonicalRoot = await _prepareRoot(root);
    final firstPass = await _hashRange(
      input,
      0,
      declaredLength,
      validateUtf8: options.contentKind == SboxContentKind.text,
    );
    if (firstPass.length != declaredLength) {
      throw const SboxException(
        SboxErrorCode.inputChanged,
        'Input length does not match its declaration',
      );
    }

    final prepared = await _prepare(
      options: options,
      plan: plan,
      firstPass: firstPass,
    );
    final staged = <_StagedShard>[];
    final secondAccumulator = HashDigestSink();
    final secondHashSink = crypto.sha256.startChunkedConversion(
      secondAccumulator,
    );
    var secondLength = 0;
    try {
      for (final shard in plan.shards) {
        final header = prepared.headerFor(shard.index, shard.length);
        final stage = File(
          '${canonicalRoot.path}${Platform.pathSeparator}.${header.canonicalBasename}.${hexLower(secureRandomBytes(8))}.part',
        );
        IOSink? output;
        var stagedSuccessfully = false;
        try {
          output = stage.openWrite();
          final headerBytes = header.encode();
          output.add(headerBytes);
          await output.flush();
          final headerHash = sha256Bytes(headerBytes);
          final shardKey = ShardKdf.derive(
            bundleDek: prepared.randomness.bundleDek,
            bundleId: header.bundleId,
            recipientKeyId: header.recipientKeyId,
            shardIndex: header.shardIndex,
          );
          try {
            final shardResult = await _writeShardRecords(
              input: input,
              shard: shard,
              header: header,
              headerHash: headerHash,
              shardKey: shardKey,
              output: output,
              overallHashSink: secondHashSink,
            );
            secondLength += shardResult;
          } finally {
            shardKey.fillRange(0, shardKey.length, 0);
            headerHash.fillRange(0, headerHash.length, 0);
            headerBytes.fillRange(0, headerBytes.length, 0);
          }
          await output.flush();
          await output.close();
          output = null;
          final length = await stage.length();
          if (options.maxObjectBytes != null &&
              length > options.maxObjectBytes!) {
            throw const SboxException(
              SboxErrorCode.sourceLimit,
              'Encrypted object exceeds the source limit',
            );
          }
          staged.add(
            _StagedShard(
              basename: header.canonicalBasename,
              stage: stage,
              isRoot: header.isRoot,
              sha256: await sha256File(stage),
              shardIndex: header.shardIndex,
            ),
          );
          stagedSuccessfully = true;
        } finally {
          await output?.close();
          if (!stagedSuccessfully && await stage.exists()) {
            await stage.delete();
          }
        }
      }
      secondHashSink.close();
      final secondDigest = Uint8List.fromList(secondAccumulator.value.bytes);
      try {
        if (secondLength != declaredLength ||
            !constantTimeBytesEqual(secondDigest, firstPass.sha256) ||
            await input.length() != declaredLength) {
          throw const SboxException(
            SboxErrorCode.inputChanged,
            'Input changed during encryption',
          );
        }
      } finally {
        secondDigest.fillRange(0, secondDigest.length, 0);
      }

      final committed = <String>[];
      for (final shard in staged.where((item) => !item.isRoot)) {
        await _commitImmutable(
          shard.stage,
          File(
            '${canonicalRoot.path}${Platform.pathSeparator}${shard.basename}',
          ),
          shard.sha256,
        );
        committed.add(shard.basename);
      }
      final rootObject = staged.singleWhere((item) => item.isRoot);
      await _commitImmutable(
        rootObject.stage,
        File(
          '${canonicalRoot.path}${Platform.pathSeparator}${rootObject.basename}',
        ),
        rootObject.sha256,
      );
      committed.add(rootObject.basename);
      return List<String>.unmodifiable(committed);
    } finally {
      prepared.dispose();
      for (final shard in staged) {
        if (await shard.stage.exists()) await shard.stage.delete();
      }
    }
  }

  Future<BundlePlan> _preflight({
    required BundleInput input,
    required int declaredLength,
    required BundleEncryptionOptions options,
  }) async {
    if (declaredLength < 0) {
      throw const SboxException(SboxErrorCode.sourceLimit, '输入长度无效');
    }
    if (await input.length() != declaredLength) {
      throw const SboxException(SboxErrorCode.inputChanged, '输入在加密前发生变化');
    }
    _validateRecipient(options.recipient);
    final plan = BundlePlanner.plan(
      logicalLength: declaredLength,
      targetNominalShardPlaintextSize: options.targetNominalShardPlaintextSize,
      maxObjectBytes: options.maxObjectBytes,
    );
    // Validate all user metadata before allocating encrypted objects.
    BundleManifest(
      bundleId: '0' * 32,
      recipientKeyId: hexLower(options.recipient.recipientKeyId),
      contentKind: options.contentKind,
      originalName: options.originalName,
      mediaType: options.mediaType,
      title: options.title ?? options.originalName,
      description: options.description,
      tags: options.tags,
      createdAt: options.createdAt ?? _utcSeconds(DateTime.now().toUtc()),
      logicalPlaintextSize: BigInt.from(declaredLength),
      logicalPlaintextSha256: Uint8List(32),
      nominalShardPlaintextSize: plan.nominalShardPlaintextSize,
      shardCount: plan.shardCount,
    );
    return plan;
  }

  Future<_PreparedBundle> _prepare({
    required BundleEncryptionOptions options,
    required BundlePlan plan,
    required _HashedRange firstPass,
  }) async {
    final randomness =
        options.randomness ??
        BundleEncryptionRandomness.secure(
          plan.shardCount,
          bundleId: firstPass.md5,
        );
    final ownsRandomness = options.randomness == null;
    Uint8List? manifestBytes;
    Uint8List? manifestBlock;
    Uint8List? wrapped;
    Uint8List? metadataKey;
    MetadataCiphertext? encryptedMetadata;
    BundlePreview? embeddedPreview;
    try {
      if (!constantTimeBytesEqual(randomness.bundleId, firstPass.md5) ||
          randomness.noncePrefixes.length != plan.shardCount) {
        throw const SboxException(
          SboxErrorCode.inputChanged,
          '随机材料与输入 Bundle 不匹配',
        );
      }
      final manifest = BundleManifest(
        bundleId: hexLower(firstPass.md5),
        recipientKeyId: hexLower(options.recipient.recipientKeyId),
        contentKind: options.contentKind,
        originalName: options.originalName,
        mediaType: options.mediaType,
        title: options.title ?? options.originalName,
        description: options.description,
        tags: options.tags,
        createdAt: options.createdAt ?? _utcSeconds(DateTime.now().toUtc()),
        logicalPlaintextSize: BigInt.from(firstPass.length),
        logicalPlaintextSha256: firstPass.sha256,
        nominalShardPlaintextSize: plan.nominalShardPlaintextSize,
        shardCount: plan.shardCount,
      );
      // This is the only protocol Manifest serialization performed by the
      // generator. The block is also constructed exactly once.
      manifestBytes = manifest.encode();
      final requestedPreview = options.preview;
      if (requestedPreview != null) {
        MetadataBlockCodec.validatePreview(requestedPreview);
        final previewCapacity = MetadataBlockCodec.previewCapacity(
          manifestBytes.length,
        );
        if (requestedPreview.encodedLength <= previewCapacity) {
          embeddedPreview = requestedPreview.copy();
        }
      }
      manifestBlock = MetadataBlockCodec.packV2(
        manifestBytes,
        preview: embeddedPreview,
      );
      wrapped = RsaOaepSha256().encrypt(
        message: randomness.bundleDek,
        publicKey: options.recipient.rsaPublicKey,
        label: RsaOaepSha256.buildBundleDekLabel(
          bundleId: firstPass.md5,
          recipientKeyId: options.recipient.recipientKeyId,
        ),
        seed: randomness.oaepSeed,
      );
      final placeholderRoot = BundleHeader.root(
        version: SboxVersion.v31,
        bundleId: firstPass.md5,
        shardCount: plan.shardCount,
        shardPlaintextSize: BigInt.from(plan.shards.first.length),
        recipientKeyId: options.recipient.recipientKeyId,
        noncePrefix: randomness.noncePrefixes.first,
        wrappedBundleDek: wrapped,
        metadataSalt: randomness.metadataSalt,
        metadataNonce: randomness.metadataNonce,
        metadataCiphertext: Uint8List(SboxProtocol.metadataCiphertextLength),
        metadataTag: Uint8List(SboxProtocol.gcmTagLength),
      );
      final placeholderBytes = placeholderRoot.encode();
      metadataKey = MetadataKdf.derive(
        spkiDer: options.recipient.spkiDer,
        metadataSalt: randomness.metadataSalt,
        bundleId: firstPass.md5,
        recipientKeyId: options.recipient.recipientKeyId,
        formatId: SboxProtocol.metadataFormatIdV31,
      );
      encryptedMetadata = await MetadataCipher().encrypt(
        key: metadataKey,
        nonce: randomness.metadataNonce,
        plaintext: manifestBlock,
        aad: MetadataCipher.buildAad(
          placeholderBytes.sublist(0, SboxProtocol.metadataAadHeaderLength),
        ),
      );
      final rootHeader = BundleHeader.root(
        version: SboxVersion.v31,
        bundleId: firstPass.md5,
        shardCount: plan.shardCount,
        shardPlaintextSize: BigInt.from(plan.shards.first.length),
        recipientKeyId: options.recipient.recipientKeyId,
        noncePrefix: randomness.noncePrefixes.first,
        wrappedBundleDek: wrapped,
        metadataSalt: randomness.metadataSalt,
        metadataNonce: randomness.metadataNonce,
        metadataCiphertext: encryptedMetadata.ciphertext,
        metadataTag: encryptedMetadata.tag,
      );
      return _PreparedBundle(
        manifest: manifest,
        randomness: randomness,
        ownsRandomness: ownsRandomness,
        rootHeader: rootHeader,
        manifestBytes: manifestBytes,
        wrapped: wrapped,
        preview: embeddedPreview,
        previewRequested: options.wantsPreview,
        previewEmbedded: embeddedPreview != null,
      );
    } catch (_) {
      manifestBytes?.fillRange(0, manifestBytes.length, 0);
      manifestBlock?.fillRange(0, manifestBlock.length, 0);
      wrapped?.fillRange(0, wrapped.length, 0);
      metadataKey?.fillRange(0, metadataKey.length, 0);
      encryptedMetadata?.dispose();
      embeddedPreview?.dispose();
      if (ownsRandomness) randomness.dispose();
      rethrow;
    } finally {
      manifestBytes?.fillRange(0, manifestBytes.length, 0);
      manifestBlock?.fillRange(0, manifestBlock.length, 0);
      wrapped?.fillRange(0, wrapped.length, 0);
      metadataKey?.fillRange(0, metadataKey.length, 0);
      encryptedMetadata?.dispose();
    }
  }

  Future<_EncryptedShard> _encryptShard({
    required BundleInput input,
    required BundleShardPlan shard,
    required _PreparedBundle prepared,
    required ByteConversionSink overallHashSink,
  }) async {
    final header = prepared.headerFor(shard.index, shard.length);
    final headerBytes = header.encode();
    final headerHash = sha256Bytes(headerBytes);
    final shardKey = ShardKdf.derive(
      bundleDek: prepared.randomness.bundleDek,
      bundleId: header.bundleId,
      recipientKeyId: header.recipientKeyId,
      shardIndex: header.shardIndex,
    );
    final output = BytesBuilder(copy: false)..add(headerBytes);
    final shardAccumulator = HashDigestSink();
    final shardHashSink = crypto.sha256.startChunkedConversion(
      shardAccumulator,
    );
    var shardLength = 0;
    var dataCount = 0;
    try {
      await for (final plainChunk in _rangeChunks(
        input,
        start: shard.offset,
        length: shard.length,
        chunkSize: SboxProtocol.chunkSize,
      )) {
        try {
          shardHashSink.add(plainChunk);
          overallHashSink.add(plainChunk);
          final record = await _records.encrypt(
            type: BundleRecordType.data,
            index: BigInt.from(dataCount + 1),
            plaintext: plainChunk,
            shardKey: shardKey,
            noncePrefix: header.noncePrefix,
            headerHash: headerHash,
          );
          output.add(record);
          shardLength += plainChunk.length;
          dataCount++;
        } finally {
          plainChunk.fillRange(0, plainChunk.length, 0);
        }
      }
      shardHashSink.close();
      if (shardLength != shard.length ||
          (shard.length == 0 && dataCount != 0)) {
        throw const SboxException(SboxErrorCode.inputChanged, '输入在加密期间发生变化');
      }
      final shardDigest = Uint8List.fromList(shardAccumulator.value.bytes);
      final finalPlaintext = BundleFinalRecord(
        totalDataLength: BigInt.from(shardLength),
        dataRecordCount: BigInt.from(dataCount),
        dataSha256: shardDigest,
      ).encode();
      try {
        final record = await _records.encrypt(
          type: BundleRecordType.finalRecord,
          index: BigInt.from(dataCount + 1),
          plaintext: finalPlaintext,
          shardKey: shardKey,
          noncePrefix: header.noncePrefix,
          headerHash: headerHash,
        );
        output.add(record);
      } finally {
        finalPlaintext.fillRange(0, finalPlaintext.length, 0);
        shardDigest.fillRange(0, shardDigest.length, 0);
      }
      return _EncryptedShard(
        header: header,
        bytes: output.takeBytes(),
        plaintextLength: shardLength,
      );
    } finally {
      shardKey.fillRange(0, shardKey.length, 0);
      headerHash.fillRange(0, headerHash.length, 0);
    }
  }

  Future<int> _writeShardRecords({
    required BundleInput input,
    required BundleShardPlan shard,
    required BundleHeader header,
    required List<int> headerHash,
    required List<int> shardKey,
    required IOSink output,
    required ByteConversionSink overallHashSink,
  }) async {
    final shardAccumulator = HashDigestSink();
    final shardHashSink = crypto.sha256.startChunkedConversion(
      shardAccumulator,
    );
    var shardLength = 0;
    var dataCount = 0;
    await for (final plainChunk in _rangeChunks(
      input,
      start: shard.offset,
      length: shard.length,
      chunkSize: SboxProtocol.chunkSize,
    )) {
      try {
        shardHashSink.add(plainChunk);
        overallHashSink.add(plainChunk);
        final record = await _records.encrypt(
          type: BundleRecordType.data,
          index: BigInt.from(dataCount + 1),
          plaintext: plainChunk,
          shardKey: shardKey,
          noncePrefix: header.noncePrefix,
          headerHash: headerHash,
        );
        output.add(record);
        await output.flush();
        record.fillRange(0, record.length, 0);
        shardLength += plainChunk.length;
        dataCount++;
      } finally {
        plainChunk.fillRange(0, plainChunk.length, 0);
      }
    }
    shardHashSink.close();
    if (shardLength != shard.length || (shard.length == 0 && dataCount != 0)) {
      throw const SboxException(
        SboxErrorCode.inputChanged,
        'Input changed during encryption',
      );
    }
    final shardDigest = Uint8List.fromList(shardAccumulator.value.bytes);
    final finalPlaintext = BundleFinalRecord(
      totalDataLength: BigInt.from(shardLength),
      dataRecordCount: BigInt.from(dataCount),
      dataSha256: shardDigest,
    ).encode();
    try {
      final record = await _records.encrypt(
        type: BundleRecordType.finalRecord,
        index: BigInt.from(dataCount + 1),
        plaintext: finalPlaintext,
        shardKey: shardKey,
        noncePrefix: header.noncePrefix,
        headerHash: headerHash,
      );
      output.add(record);
      await output.flush();
      record.fillRange(0, record.length, 0);
    } finally {
      finalPlaintext.fillRange(0, finalPlaintext.length, 0);
      shardDigest.fillRange(0, shardDigest.length, 0);
    }
    return shardLength;
  }

  static void _validateRecipient(PublicIdentity identity) {
    if (identity.rsaPublicKey.modulus.bitLength != SboxProtocol.rsaBits ||
        identity.rsaPublicKey.exponent !=
            BigInt.from(SboxProtocol.rsaPublicExponent)) {
      throw const SboxException(SboxErrorCode.keyMismatch, '接收者 RSA 公钥参数无效');
    }
    try {
      final parsed = parseRsaSubjectPublicKeyInfo(identity.spkiDer);
      if (parsed.modulus != identity.rsaPublicKey.modulus ||
          parsed.exponent != identity.rsaPublicKey.exponent ||
          !constantTimeBytesEqual(
            sha256Bytes(identity.spkiDer),
            identity.recipientKeyId,
          )) {
        throw const FormatException('Public identity mismatch');
      }
    } on FormatException {
      throw const SboxException(SboxErrorCode.keyMismatch, '接收者 RSA 公共身份无效');
    }
  }

  static Future<Directory> _prepareRoot(Directory root) async {
    await root.create(recursive: true);
    final canonical = await root.resolveSymbolicLinks();
    if (await FileSystemEntity.type(canonical, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const SboxException(SboxErrorCode.remoteChanged, '数据源根目录无效');
    }
    return Directory(canonical);
  }

  static Future<void> _commitImmutable(
    File staged,
    File target,
    List<int> expectedHash,
  ) async {
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type == FileSystemEntityType.link ||
        type == FileSystemEntityType.directory) {
      throw const SboxException(SboxErrorCode.storageOverlap, '数据源目标不是安全文件');
    }
    if (type == FileSystemEntityType.file) {
      final existing = await target.readAsBytes();
      if (!constantTimeBytesEqual(sha256Bytes(existing), expectedHash)) {
        throw const SboxException(
          SboxErrorCode.immutableConflict,
          '规范对象已存在且内容不同',
        );
      }
      return;
    }
    await staged.rename(target.path);
  }

  static Future<_HashedRange> _hashRange(
    BundleInput input,
    int start,
    int length, {
    bool validateUtf8 = false,
  }) async {
    final accumulator = HashDigestSink();
    final sink = crypto.sha256.startChunkedConversion(accumulator);
    final md5Accumulator = HashDigestSink();
    final md5Sink = crypto.md5.startChunkedConversion(md5Accumulator);
    final utf8Validator = validateUtf8
        ? utf8.decoder.startChunkedConversion(_DiscardStringSink())
        : null;
    var count = 0;
    await for (final chunk in input.openRange(start, length)) {
      count += chunk.length;
      if (count > length) {
        throw const SboxException(SboxErrorCode.inputChanged, '输入范围超过声明长度');
      }
      sink.add(chunk);
      md5Sink.add(chunk);
      try {
        utf8Validator?.add(chunk);
      } on FormatException {
        throw const SboxException(SboxErrorCode.integrity, '文本输入不是严格 UTF-8');
      }
    }
    sink.close();
    md5Sink.close();
    try {
      utf8Validator?.close();
    } on FormatException {
      throw const SboxException(SboxErrorCode.integrity, '文本输入不是严格 UTF-8');
    }
    if (count != length) {
      throw const SboxException(SboxErrorCode.inputChanged, '输入范围提前结束');
    }
    return _HashedRange(
      length: count,
      sha256: Uint8List.fromList(accumulator.value.bytes),
      md5: Uint8List.fromList(md5Accumulator.value.bytes),
    );
  }

  static Stream<List<int>> _rangeChunks(
    BundleInput input, {
    required int start,
    required int length,
    required int chunkSize,
  }) async* {
    var remaining = length;
    var pending = Uint8List(0);
    await for (final source in input.openRange(start, length)) {
      if (source.isEmpty) continue;
      final combined = Uint8List(pending.length + source.length)
        ..setRange(0, pending.length, pending)
        ..setRange(pending.length, pending.length + source.length, source);
      pending.fillRange(0, pending.length, 0);
      var offset = 0;
      while (combined.length - offset >= chunkSize) {
        final chunk = Uint8List.fromList(
          combined.sublist(offset, offset + chunkSize),
        );
        yield chunk;
        offset += chunkSize;
        remaining -= chunkSize;
      }
      pending = Uint8List.fromList(combined.sublist(offset));
      combined.fillRange(0, combined.length, 0);
    }
    if (pending.isNotEmpty) {
      if (pending.length > remaining || pending.length > chunkSize) {
        throw const SboxException(SboxErrorCode.inputChanged, '输入分片长度无效');
      }
      remaining -= pending.length;
      yield pending;
    }
    if (remaining != 0) {
      throw const SboxException(SboxErrorCode.inputChanged, '输入分片提前结束');
    }
  }

  static String _utcSeconds(DateTime value) => DateTime.utc(
    value.toUtc().year,
    value.toUtc().month,
    value.toUtc().day,
    value.toUtc().hour,
    value.toUtc().minute,
    value.toUtc().second,
  ).toIso8601String().replaceFirst('.000Z', 'Z');
}

final class _PreparedBundle {
  _PreparedBundle({
    required this.manifest,
    required this.randomness,
    required this.ownsRandomness,
    required this.rootHeader,
    required List<int> manifestBytes,
    required List<int> wrapped,
    required this.preview,
    required this.previewRequested,
    required this.previewEmbedded,
  }) : manifestBytes = Uint8List.fromList(manifestBytes),
       wrapped = Uint8List.fromList(wrapped);

  final BundleManifest manifest;
  final BundleEncryptionRandomness randomness;
  final bool ownsRandomness;
  final BundleHeader rootHeader;
  final Uint8List manifestBytes;
  final Uint8List wrapped;
  final BundlePreview? preview;
  final bool previewRequested;
  final bool previewEmbedded;

  BundleHeader headerFor(int shardIndex, int shardLength) {
    if (shardIndex == 0) return rootHeader;
    return BundleHeader.continuation(
      bundleId: rootHeader.bundleId,
      shardIndex: shardIndex,
      shardCount: rootHeader.shardCount,
      shardPlaintextSize: BigInt.from(shardLength),
      recipientKeyId: rootHeader.recipientKeyId,
      noncePrefix: randomness.noncePrefixes[shardIndex],
      version: rootHeader.version,
    );
  }

  void dispose() {
    manifestBytes.fillRange(0, manifestBytes.length, 0);
    wrapped.fillRange(0, wrapped.length, 0);
    preview?.dispose();
    if (ownsRandomness) randomness.dispose();
  }
}

final class _EncryptedShard {
  const _EncryptedShard({
    required this.header,
    required this.bytes,
    required this.plaintextLength,
  });

  final BundleHeader header;
  final Uint8List bytes;
  final int plaintextLength;
}

final class _HashedRange {
  const _HashedRange({
    required this.length,
    required this.sha256,
    required this.md5,
  });

  final int length;
  final Uint8List sha256;
  final Uint8List md5;
}

final class _StagedShard {
  const _StagedShard({
    required this.basename,
    required this.stage,
    required this.isRoot,
    required this.sha256,
    required this.shardIndex,
  });

  final String basename;
  final File stage;
  final bool isRoot;
  final Uint8List sha256;
  final int shardIndex;
}

final class _DiscardStringSink implements Sink<String> {
  @override
  void add(String value) {}

  @override
  void close() {}
}
