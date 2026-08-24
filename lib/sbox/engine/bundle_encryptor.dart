import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show kIsWeb;

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

  /// Takes ownership of [bytes]. The caller must not mutate it until
  /// [dispose] is called after the operation completes.
  MemoryBundleInput.owned(Uint8List bytes) : _bytes = bytes;

  MemoryBundleInput._owned(this._bytes);

  final Uint8List _bytes;

  /// Returns a copy that can be handed to a background isolate.
  Uint8List get bytes => Uint8List.fromList(_bytes);

  @override
  Future<int> length() async => _bytes.length;

  @override
  Stream<List<int>> openRange(int start, int length) async* {
    if (start < 0 || length < 0 || start > _bytes.length - length) {
      throw ArgumentError('Invalid input range');
    }
    const transportChunk = 64 * 1024;
    final end = start + length;
    for (var offset = start; offset < end; offset += transportChunk) {
      final chunkEnd = (offset + transportChunk).clamp(0, end).toInt();
      // Yield one owned transport chunk at a time. The previous
      // Stream.fromIterable implementation eagerly materialised a complete
      // second copy of the selected file, which is particularly expensive in
      // a browser tab.
      yield Uint8List.fromList(Uint8List.sublistView(_bytes, offset, chunkEnd));
    }
  }

  /// Returns an owned copy of a range that can be transferred to a worker
  /// isolate without exposing the complete in-memory input.
  Uint8List copyRange(int start, int length) {
    if (start < 0 || length < 0 || start > _bytes.length - length) {
      throw ArgumentError('Invalid input range');
    }
    return Uint8List.fromList(_bytes.sublist(start, start + length));
  }

  void dispose() => _bytes.fillRange(0, _bytes.length, 0);
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

enum BundleEncryptionStage { splitting, encrypting }

final class BundleEncryptionProgress {
  const BundleEncryptionProgress({
    required this.stage,
    required this.processedBytes,
    required this.totalBytes,
    required this.completedShards,
    required this.totalShards,
    this.currentShardIndex,
    this.currentShardBytes = 0,
    this.currentShardLength = 0,
  });

  final BundleEncryptionStage stage;
  final int processedBytes;
  final int totalBytes;
  final int completedShards;
  final int totalShards;
  final int? currentShardIndex;
  final int currentShardBytes;
  final int currentShardLength;

  double get fraction => totalBytes <= 0
      ? (completedShards >= totalShards ? 1 : 0)
      : (processedBytes / totalBytes).clamp(0, 1).toDouble();
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
    : _records = records ?? BundleRecordCodec(),
      _canUseShardIsolates = records == null;

  final BundleRecordCodec _records;
  final bool _canUseShardIsolates;

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
    void Function(BundleEncryptionProgress progress)? onProgress,
  }) async {
    final plan = await _preflight(
      input: input,
      declaredLength: declaredLength,
      options: options,
    );
    _emitProgress(
      onProgress,
      BundleEncryptionProgress(
        stage: BundleEncryptionStage.splitting,
        processedBytes: 0,
        totalBytes: declaredLength,
        completedShards: 0,
        totalShards: plan.shardCount,
      ),
    );
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
    try {
      // The validation pass runs while independent shard workers are
      // encrypting. SHA-256 cannot be combined from per-shard digests, so the
      // ordered input pass remains the Bundle-level integrity check.
      late final List<dynamic> values;
      if (_canUseShardIsolates && _supportsParallelInput(input)) {
        values = await Future.wait<dynamic>(<Future<dynamic>>[
          _hashRange(input, 0, declaredLength),
          _encryptShards(
            input: input,
            shards: plan.shards,
            prepared: prepared,
            onProgress: onProgress,
          ),
        ], eagerError: false);
      } else {
        final results = await _encryptShards(
          input: input,
          shards: plan.shards,
          prepared: prepared,
          onProgress: onProgress,
        );
        values = <dynamic>[await _hashRange(input, 0, declaredLength), results];
      }
      final secondPass = values[0] as _HashedRange;
      final results = values[1] as List<_ShardEncryptionResult>;
      try {
        if (secondPass.length != declaredLength ||
            !constantTimeBytesEqual(secondPass.sha256, firstPass.sha256) ||
            await input.length() != declaredLength) {
          throw const SboxException(
            SboxErrorCode.inputChanged,
            'Input changed during encryption',
          );
        }
      } finally {
        secondPass.sha256.fillRange(0, secondPass.sha256.length, 0);
        secondPass.md5.fillRange(0, secondPass.md5.length, 0);
      }
      final objects = <EncryptedBundleObject>[];
      for (final result in results) {
        final bytes = result.bytes!;
        if (options.maxObjectBytes != null &&
            bytes.length > options.maxObjectBytes!) {
          throw const SboxException(
            SboxErrorCode.sourceLimit,
            'Encrypted object exceeds the source limit',
          );
        }
        objects.add(
          EncryptedBundleObject(
            basename: result.header.canonicalBasename,
            header: result.header,
            bytes: bytes,
            sha256: result.ciphertextSha256,
          ),
        );
      }
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
    void Function(BundleEncryptionProgress progress)? onProgress,
  }) async {
    final plan = await _preflight(
      input: input,
      declaredLength: declaredLength,
      options: options,
    );
    final canonicalRoot = await _prepareRoot(root);
    _emitProgress(
      onProgress,
      BundleEncryptionProgress(
        stage: BundleEncryptionStage.splitting,
        processedBytes: 0,
        totalBytes: declaredLength,
        completedShards: 0,
        totalShards: plan.shardCount,
        currentShardIndex: plan.shards.first.index,
        currentShardLength: plan.shards.first.length,
      ),
    );
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
    final stageJobs = <_ShardFileJob>[];
    final staged = <_StagedShard>[];
    try {
      for (final shard in plan.shards) {
        final header = prepared.headerFor(shard.index, shard.length);
        stageJobs.add(
          _ShardFileJob(
            shard: shard,
            header: header,
            stage: File(
              '${canonicalRoot.path}${Platform.pathSeparator}.${header.canonicalBasename}.${hexLower(secureRandomBytes(8))}.part',
            ),
          ),
        );
      }
      late final List<dynamic> values;
      if (_canUseShardIsolates && _supportsParallelInput(input)) {
        values = await Future.wait<dynamic>(<Future<dynamic>>[
          _hashRange(input, 0, declaredLength),
          _encryptShardFiles(
            input: input,
            jobs: stageJobs,
            prepared: prepared,
            totalBytes: declaredLength,
            onProgress: onProgress,
          ),
        ], eagerError: false);
      } else {
        final results = await _encryptShardFiles(
          input: input,
          jobs: stageJobs,
          prepared: prepared,
          totalBytes: declaredLength,
          onProgress: onProgress,
        );
        values = <dynamic>[await _hashRange(input, 0, declaredLength), results];
      }
      final secondPass = values[0] as _HashedRange;
      final results = values[1] as List<_ShardEncryptionResult>;
      try {
        if (secondPass.length != declaredLength ||
            !constantTimeBytesEqual(secondPass.sha256, firstPass.sha256) ||
            await input.length() != declaredLength) {
          throw const SboxException(
            SboxErrorCode.inputChanged,
            'Input changed during encryption',
          );
        }
      } finally {
        secondPass.sha256.fillRange(0, secondPass.sha256.length, 0);
        secondPass.md5.fillRange(0, secondPass.md5.length, 0);
      }
      for (var index = 0; index < results.length; index++) {
        final result = results[index];
        final job = stageJobs[index];
        if (options.maxObjectBytes != null &&
            result.ciphertextLength > options.maxObjectBytes!) {
          throw const SboxException(
            SboxErrorCode.sourceLimit,
            'Encrypted object exceeds the source limit',
          );
        }
        staged.add(
          _StagedShard(
            basename: job.header.canonicalBasename,
            stage: job.stage,
            isRoot: job.header.isRoot,
            sha256: result.ciphertextSha256,
            shardIndex: job.shard.index,
          ),
        );
      }
      _emitProgress(
        onProgress,
        BundleEncryptionProgress(
          stage: BundleEncryptionStage.encrypting,
          processedBytes: declaredLength,
          totalBytes: declaredLength,
          completedShards: plan.shardCount,
          totalShards: plan.shardCount,
        ),
      );
      final ordered = List<_StagedShard>.of(staged)
        ..sort((left, right) => left.shardIndex.compareTo(right.shardIndex));
      final committed = <String>[];
      for (final shard in ordered.where((item) => !item.isRoot)) {
        await _commitImmutable(
          shard.stage,
          File(
            '${canonicalRoot.path}${Platform.pathSeparator}${shard.basename}',
          ),
          shard.sha256,
        );
        committed.add(shard.basename);
      }
      final rootObject = ordered.singleWhere((item) => item.isRoot);
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
      for (final job in stageJobs) {
        if (await job.stage.exists()) await job.stage.delete();
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

  /// Encrypts independent shards in a bounded isolate pool. The result list
  /// stays in plan order even when workers finish out of order.
  Future<List<_ShardEncryptionResult>> _encryptShards({
    required BundleInput input,
    required List<BundleShardPlan> shards,
    required _PreparedBundle prepared,
    void Function(BundleEncryptionProgress progress)? onProgress,
  }) async {
    if (shards.isEmpty) return <_ShardEncryptionResult>[];
    final results = List<_ShardEncryptionResult?>.filled(shards.length, null);
    final useIsolates =
        !kIsWeb && _canUseShardIsolates && _supportsParallelInput(input);
    final workerCount = useIsolates ? _shardWorkerCount(shards.length) : 1;
    var nextIndex = 0;
    var completedShards = 0;
    var processedBytes = 0;
    final totalBytes = shards.fold<int>(
      0,
      (total, value) => total + value.length,
    );

    Future<void> worker() async {
      while (true) {
        if (nextIndex >= shards.length) return;
        final position = nextIndex++;
        final shard = shards[position];
        final header = prepared.headerFor(shard.index, shard.length);
        final result = useIsolates
            ? await _encryptShardInIsolate(
                input: input,
                shard: shard,
                header: header,
                bundleDek: prepared.randomness.bundleDek,
              )
            : await _encryptShard(
                input: input,
                shard: shard,
                header: header,
                bundleDek: prepared.randomness.bundleDek,
              );
        results[position] = result;
        completedShards++;
        processedBytes += result.plaintextLength;
        _emitProgress(
          onProgress,
          BundleEncryptionProgress(
            stage: BundleEncryptionStage.encrypting,
            processedBytes: processedBytes,
            totalBytes: totalBytes,
            completedShards: completedShards,
            totalShards: shards.length,
            currentShardIndex: shard.index,
            currentShardBytes: result.plaintextLength,
            currentShardLength: shard.length,
          ),
        );
      }
    }

    try {
      await Future.wait<void>(<Future<void>>[
        for (var index = 0; index < workerCount; index++) worker(),
      ], eagerError: false);
      return <_ShardEncryptionResult>[for (final result in results) result!];
    } catch (_) {
      for (final result in results) {
        result?.dispose();
      }
      rethrow;
    }
  }

  Future<List<_ShardEncryptionResult>> _encryptShardFiles({
    required BundleInput input,
    required List<_ShardFileJob> jobs,
    required _PreparedBundle prepared,
    required int totalBytes,
    void Function(BundleEncryptionProgress progress)? onProgress,
  }) async {
    if (jobs.isEmpty) return <_ShardEncryptionResult>[];
    final results = List<_ShardEncryptionResult?>.filled(jobs.length, null);
    final useIsolates =
        !kIsWeb && _canUseShardIsolates && _supportsParallelInput(input);
    final workerCount = useIsolates ? _shardWorkerCount(jobs.length) : 1;
    var nextIndex = 0;
    var completedShards = 0;
    var processedBytes = 0;

    Future<void> worker() async {
      while (true) {
        if (nextIndex >= jobs.length) return;
        final position = nextIndex++;
        final job = jobs[position];
        final result = useIsolates
            ? await _encryptShardInIsolate(
                input: input,
                shard: job.shard,
                header: job.header,
                bundleDek: prepared.randomness.bundleDek,
                stagePath: job.stage.path,
              )
            : await _encryptShardToFile(
                input: input,
                shard: job.shard,
                header: job.header,
                bundleDek: prepared.randomness.bundleDek,
                stage: job.stage,
              );
        results[position] = result;
        completedShards++;
        processedBytes += result.plaintextLength;
        _emitProgress(
          onProgress,
          BundleEncryptionProgress(
            stage: BundleEncryptionStage.encrypting,
            processedBytes: processedBytes,
            totalBytes: totalBytes,
            completedShards: completedShards,
            totalShards: jobs.length,
            currentShardIndex: job.shard.index,
            currentShardBytes: result.plaintextLength,
            currentShardLength: job.shard.length,
          ),
        );
      }
    }

    try {
      await Future.wait<void>(<Future<void>>[
        for (var index = 0; index < workerCount; index++) worker(),
      ], eagerError: false);
      return <_ShardEncryptionResult>[for (final result in results) result!];
    } catch (_) {
      for (final result in results) {
        result?.dispose();
      }
      rethrow;
    }
  }

  Future<_ShardEncryptionResult> _encryptShardInIsolate({
    required BundleInput input,
    required BundleShardPlan shard,
    required BundleHeader header,
    required List<int> bundleDek,
    String? stagePath,
  }) async {
    final inputRequest = _ShardInputRequest.fromInput(input, shard);
    if (inputRequest == null) {
      throw UnsupportedError('Input cannot be sent to a shard isolate');
    }
    final request = _ShardEncryptionRequest(
      input: inputRequest,
      shardIndex: shard.index,
      shardOffset: inputRequest.memory == null ? shard.offset : 0,
      shardLength: shard.length,
      headerBytes: header.encode(),
      bundleDek: Uint8List.fromList(bundleDek),
      stagePath: stagePath,
    );
    try {
      final response = await Isolate.run<_TransferredShardEncryption>(
        () => _encryptShardWorker(request),
        debugName: 'safebox-encrypt-shard-${shard.index}',
      );
      if (response.plaintextLength != shard.length ||
          response.ciphertextSha256.length != 32) {
        if (response.bytes != null) {
          final invalid = response.bytes!.materialize().asUint8List();
          invalid.fillRange(0, invalid.length, 0);
        }
        throw const SboxException(
          SboxErrorCode.integrity,
          'Encrypted shard worker returned invalid metadata',
        );
      }
      Uint8List? bytes;
      if (stagePath == null) {
        final transferred = response.bytes;
        if (transferred == null) {
          throw const SboxException(
            SboxErrorCode.integrity,
            'Encrypted shard worker returned no bytes',
          );
        }
        bytes = transferred.materialize().asUint8List();
        if (bytes.length != response.ciphertextLength) {
          bytes.fillRange(0, bytes.length, 0);
          throw const SboxException(
            SboxErrorCode.integrity,
            'Encrypted shard length is invalid',
          );
        }
      } else if (response.bytes != null) {
        final unexpected = response.bytes!.materialize().asUint8List();
        unexpected.fillRange(0, unexpected.length, 0);
        throw const SboxException(
          SboxErrorCode.integrity,
          'File shard worker returned bytes',
        );
      }
      return _ShardEncryptionResult(
        header: header,
        bytes: bytes,
        plaintextLength: response.plaintextLength,
        ciphertextLength: response.ciphertextLength,
        ciphertextSha256: response.ciphertextSha256,
      );
    } finally {
      request.bundleDek.fillRange(0, request.bundleDek.length, 0);
      request.headerBytes.fillRange(0, request.headerBytes.length, 0);
    }
  }

  Future<_ShardEncryptionResult> _encryptShardToFile({
    required BundleInput input,
    required BundleShardPlan shard,
    required BundleHeader header,
    required List<int> bundleDek,
    required File stage,
  }) async {
    IOSink? output;
    try {
      final sink = stage.openWrite();
      output = sink;
      final headerBytes = header.encode();
      final headerHash = sha256Bytes(headerBytes);
      final shardKey = ShardKdf.derive(
        bundleDek: bundleDek,
        bundleId: header.bundleId,
        recipientKeyId: header.recipientKeyId,
        shardIndex: header.shardIndex,
      );
      try {
        sink.add(headerBytes);
        await sink.flush();
        final plaintextLength = await _writeShardRecords(
          input: input,
          shard: shard,
          header: header,
          headerHash: headerHash,
          shardKey: shardKey,
          output: sink,
        );
        await sink.flush();
        await sink.close();
        output = null;
        final ciphertextLength = await stage.length();
        return _ShardEncryptionResult(
          header: header,
          plaintextLength: plaintextLength,
          ciphertextLength: ciphertextLength,
          ciphertextSha256: await sha256File(stage),
        );
      } finally {
        shardKey.fillRange(0, shardKey.length, 0);
        headerHash.fillRange(0, headerHash.length, 0);
        headerBytes.fillRange(0, headerBytes.length, 0);
      }
    } finally {
      await output?.close();
    }
  }

  static bool _supportsParallelInput(BundleInput input) =>
      !kIsWeb && (input is FileBundleInput || input is MemoryBundleInput);

  static int _shardWorkerCount(int shardCount) {
    final processorCount = Platform.numberOfProcessors;
    final parallelism = processorCount < 2
        ? 1
        : processorCount > 4
        ? 4
        : processorCount;
    return parallelism > shardCount ? shardCount : parallelism;
  }

  Future<_ShardEncryptionResult> _encryptShard({
    required BundleInput input,
    required BundleShardPlan shard,
    required BundleHeader header,
    required List<int> bundleDek,
  }) async {
    final headerBytes = header.encode();
    final headerHash = sha256Bytes(headerBytes);
    final shardKey = ShardKdf.derive(
      bundleDek: bundleDek,
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
      } finally {
        finalPlaintext.fillRange(0, finalPlaintext.length, 0);
        shardDigest.fillRange(0, shardDigest.length, 0);
      }
      final bytes = output.takeBytes();
      return _ShardEncryptionResult(
        header: header,
        bytes: bytes,
        plaintextLength: shardLength,
        ciphertextLength: bytes.length,
        ciphertextSha256: sha256Bytes(bytes),
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

  static void _emitProgress(
    void Function(BundleEncryptionProgress progress)? onProgress,
    BundleEncryptionProgress progress,
  ) {
    try {
      onProgress?.call(progress);
    } on Object {
      // Progress listeners must never be able to interrupt encryption.
    }
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

final class _ShardFileJob {
  const _ShardFileJob({
    required this.shard,
    required this.header,
    required this.stage,
  });

  final BundleShardPlan shard;
  final BundleHeader header;
  final File stage;
}

final class _ShardEncryptionResult {
  _ShardEncryptionResult({
    required this.header,
    required this.plaintextLength,
    required this.ciphertextLength,
    required List<int> ciphertextSha256,
    this.bytes,
  }) : ciphertextSha256 = Uint8List.fromList(ciphertextSha256);

  final BundleHeader header;
  final Uint8List? bytes;
  final int plaintextLength;
  final int ciphertextLength;
  final Uint8List ciphertextSha256;

  void dispose() {
    final value = bytes;
    if (value != null) value.fillRange(0, value.length, 0);
    ciphertextSha256.fillRange(0, ciphertextSha256.length, 0);
  }
}

final class _ShardInputRequest {
  _ShardInputRequest.file(this.filePath) : memory = null;

  _ShardInputRequest.memory(Uint8List bytes)
    : filePath = null,
      memory = TransferableTypedData.fromList(<TypedData>[bytes]);

  final String? filePath;
  final TransferableTypedData? memory;

  static _ShardInputRequest? fromInput(
    BundleInput input,
    BundleShardPlan shard,
  ) {
    if (input is FileBundleInput) {
      return _ShardInputRequest.file(input.file.path);
    }
    if (input is MemoryBundleInput) {
      return _ShardInputRequest.memory(
        input.copyRange(shard.offset, shard.length),
      );
    }
    return null;
  }

  BundleInput open() {
    final path = filePath;
    if (path != null) return FileBundleInput(File(path));
    return MemoryBundleInput._owned(memory!.materialize().asUint8List());
  }
}

final class _ShardEncryptionRequest {
  _ShardEncryptionRequest({
    required this.input,
    required this.shardIndex,
    required this.shardOffset,
    required this.shardLength,
    required this.headerBytes,
    required this.bundleDek,
    required this.stagePath,
  });

  final _ShardInputRequest input;
  final int shardIndex;
  final int shardOffset;
  final int shardLength;
  final Uint8List headerBytes;
  final Uint8List bundleDek;
  final String? stagePath;
}

final class _TransferredShardEncryption {
  const _TransferredShardEncryption({
    required this.bytes,
    required this.plaintextLength,
    required this.ciphertextLength,
    required this.ciphertextSha256,
  });

  final TransferableTypedData? bytes;
  final int plaintextLength;
  final int ciphertextLength;
  final Uint8List ciphertextSha256;
}

Future<_TransferredShardEncryption> _encryptShardWorker(
  _ShardEncryptionRequest request,
) async {
  BundleInput? openedInput;
  try {
    final input = request.input.open();
    openedInput = input;
    final shard = BundleShardPlan(
      index: request.shardIndex,
      offset: request.shardOffset,
      length: request.shardLength,
    );
    final header = BundleHeader.parse(request.headerBytes);
    final encryptor = BundleEncryptor();
    final result = request.stagePath == null
        ? await encryptor._encryptShard(
            input: input,
            shard: shard,
            header: header,
            bundleDek: request.bundleDek,
          )
        : await encryptor._encryptShardToFile(
            input: input,
            shard: shard,
            header: header,
            bundleDek: request.bundleDek,
            stage: File(request.stagePath!),
          );
    final transferred = result.bytes == null
        ? null
        : TransferableTypedData.fromList(<TypedData>[result.bytes!]);
    final response = _TransferredShardEncryption(
      bytes: transferred,
      plaintextLength: result.plaintextLength,
      ciphertextLength: result.ciphertextLength,
      ciphertextSha256: Uint8List.fromList(result.ciphertextSha256),
    );
    result.dispose();
    return response;
  } finally {
    if (openedInput is MemoryBundleInput) openedInput.dispose();
    request.bundleDek.fillRange(0, request.bundleDek.length, 0);
    request.headerBytes.fillRange(0, request.headerBytes.length, 0);
  }
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
