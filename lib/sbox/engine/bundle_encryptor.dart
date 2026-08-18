import 'dart:async';
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
import '../format/bundle_record.dart';
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
  }) : bundleId = Uint8List.fromList(bundleId),
       bundleDek = Uint8List.fromList(bundleDek),
       noncePrefixes = List<Uint8List>.unmodifiable(
         noncePrefixes.map(Uint8List.fromList),
       ),
       oaepSeed = Uint8List.fromList(oaepSeed) {
    if (this.bundleId.length != SboxProtocol.bundleIdLength ||
        this.bundleDek.length != SboxProtocol.bundleDekLength ||
        this.oaepSeed.length != 32 ||
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
    );
  }

  final Uint8List bundleId;
  final Uint8List bundleDek;
  final List<Uint8List> noncePrefixes;
  final Uint8List oaepSeed;

  void dispose() {
    bundleId.fillRange(0, bundleId.length, 0);
    bundleDek.fillRange(0, bundleDek.length, 0);
    oaepSeed.fillRange(0, oaepSeed.length, 0);
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
  final BundleEncryptionRandomness? randomness;
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
  }) : plaintextSha256 = Uint8List.fromList(plaintextSha256);

  final BundleManifest manifest;
  final List<EncryptedBundleObject> objects;
  final Uint8List plaintextSha256;

  EncryptedBundleObject get root =>
      objects.firstWhere((object) => object.header.isRoot);
}

/// One unified writer for empty, small and multipart Bundles.
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
  ///
  /// MD5 is used here only as a content address for de-duplication. The
  /// encrypted Bundle still uses SHA-256 and authenticated encryption for
  /// integrity and confidentiality.
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
    if (declaredLength < 0) {
      throw const SboxException(SboxErrorCode.sourceLimit, '输入长度无效');
    }
    final actualDeclaredLength = await input.length();
    if (actualDeclaredLength != declaredLength) {
      throw const SboxException(SboxErrorCode.inputChanged, '输入在加密前发生变化');
    }
    final plan = BundlePlanner.plan(
      logicalLength: declaredLength,
      targetNominalShardPlaintextSize: options.targetNominalShardPlaintextSize,
      maxObjectBytes: options.maxObjectBytes,
    );
    _validateStreamingOptions(
      options,
      logicalLength: declaredLength,
      plan: plan,
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

    final preflightRandomness =
        options.randomness ??
        BundleEncryptionRandomness.secure(
          plan.shardCount,
          bundleId: firstPass.md5,
        );
    final preflightOwnsRandomness = options.randomness == null;

    final randomness = preflightRandomness;
    final ownsRandomness = preflightOwnsRandomness;
    if (randomness.noncePrefixes.length != plan.shardCount) {
      if (ownsRandomness) randomness.dispose();
      throw const SboxException(SboxErrorCode.sourceLimit, '随机材料与分片数量不一致');
    }

    Uint8List? manifestBytes;
    Uint8List? wrapped;
    try {
      if (options.recipient.rsaPublicKey.modulus.bitLength !=
              SboxProtocol.rsaBits ||
          options.recipient.rsaPublicKey.exponent !=
              BigInt.from(SboxProtocol.rsaPublicExponent)) {
        throw const SboxException(SboxErrorCode.keyMismatch, '接收者 RSA 公钥参数无效');
      }
      final manifest = BundleManifest(
        bundleId: hexLower(randomness.bundleId),
        recipientKeyId: hexLower(options.recipient.recipientKeyId),
        contentKind: options.contentKind,
        originalName: options.originalName,
        mediaType: options.mediaType,
        title: options.title ?? options.originalName,
        description: options.description,
        tags: options.tags,
        createdAt: options.createdAt ?? _utcSeconds(DateTime.now().toUtc()),
        logicalPlaintextSize: BigInt.from(declaredLength),
        logicalPlaintextSha256: firstPass.sha256,
        nominalShardPlaintextSize: plan.nominalShardPlaintextSize,
        shardCount: plan.shardCount,
      );
      manifestBytes = manifest.encode();
      final manifestData = manifestBytes;
      final label = RsaOaepSha256.buildBundleDekLabel(
        bundleId: randomness.bundleId,
        recipientKeyId: options.recipient.recipientKeyId,
      );
      wrapped = RsaOaepSha256().encrypt(
        message: randomness.bundleDek,
        publicKey: options.recipient.rsaPublicKey,
        label: label,
        seed: randomness.oaepSeed,
      );
      final wrappedData = wrapped;
      final objects = <EncryptedBundleObject>[];
      // DigestSink is kept separately so the sink can be finalized after
      // all data records, without retaining plaintext bytes.
      final secondAccumulator = HashDigestSink();
      final secondHashSink = crypto.sha256.startChunkedConversion(
        secondAccumulator,
      );
      var secondLength = 0;
      for (final shard in plan.shards) {
        final isRoot = shard.index == 0;
        final header = isRoot
            ? BundleHeader.root(
                bundleId: randomness.bundleId,
                shardCount: plan.shardCount,
                shardPlaintextSize: BigInt.from(shard.length),
                recipientKeyId: options.recipient.recipientKeyId,
                noncePrefix: randomness.noncePrefixes[shard.index],
                wrappedBundleDek: wrappedData,
              )
            : BundleHeader.continuation(
                bundleId: randomness.bundleId,
                shardIndex: shard.index,
                shardCount: plan.shardCount,
                shardPlaintextSize: BigInt.from(shard.length),
                recipientKeyId: options.recipient.recipientKeyId,
                noncePrefix: randomness.noncePrefixes[shard.index],
              );
        final headerBytes = header.encode();
        final headerHash = sha256Bytes(headerBytes);
        final shardKey = ShardKdf.derive(
          bundleDek: randomness.bundleDek,
          bundleId: randomness.bundleId,
          recipientKeyId: options.recipient.recipientKeyId,
          shardIndex: shard.index,
        );
        final output = BytesBuilder(copy: false)..add(headerBytes);
        if (isRoot) {
          output.add(
            await _records.encrypt(
              type: BundleRecordType.manifest,
              index: BigInt.zero,
              plaintext: manifestData,
              shardKey: shardKey,
              noncePrefix: header.noncePrefix,
              headerHash: headerHash,
            ),
          );
        }
        final shardAccumulator = HashDigestSink();
        final shardHashSink = crypto.sha256.startChunkedConversion(
          shardAccumulator,
        );
        var shardDataLength = 0;
        var dataRecordCount = 0;
        await for (final plainChunk in _rangeChunks(
          input,
          start: shard.offset,
          length: shard.length,
          chunkSize: SboxProtocol.chunkSize,
        )) {
          shardHashSink.add(plainChunk);
          secondHashSink.add(plainChunk);
          secondLength += plainChunk.length;
          final recordIndex = BigInt.from(dataRecordCount + (isRoot ? 1 : 1));
          output.add(
            await _records.encrypt(
              type: BundleRecordType.data,
              index: recordIndex,
              plaintext: plainChunk,
              shardKey: shardKey,
              noncePrefix: header.noncePrefix,
              headerHash: headerHash,
            ),
          );
          shardDataLength += plainChunk.length;
          dataRecordCount++;
        }
        shardHashSink.close();
        if (shardDataLength != shard.length) {
          throw const SboxException(SboxErrorCode.inputChanged, '输入在加密期间发生变化');
        }
        final shardHash = Uint8List.fromList(shardAccumulator.value.bytes);
        final finalPlaintext = Uint8List(SboxProtocol.finalPlaintextLength);
        writeUint64BigEndian(finalPlaintext, 0, BigInt.from(shardDataLength));
        writeUint64BigEndian(finalPlaintext, 8, BigInt.from(dataRecordCount));
        finalPlaintext.setRange(16, 48, shardHash);
        output.add(
          await _records.encrypt(
            type: BundleRecordType.finalRecord,
            index: BigInt.from(dataRecordCount + 1),
            plaintext: finalPlaintext,
            shardKey: shardKey,
            noncePrefix: header.noncePrefix,
            headerHash: headerHash,
          ),
        );
        finalPlaintext.fillRange(0, finalPlaintext.length, 0);
        shardHash.fillRange(0, shardHash.length, 0);
        shardKey.fillRange(0, shardKey.length, 0);
        final objectBytes = output.takeBytes();
        if (options.maxObjectBytes != null &&
            objectBytes.length > options.maxObjectBytes!) {
          throw const SboxException(SboxErrorCode.sourceLimit, '对象超过数据源上限');
        }
        objects.add(
          EncryptedBundleObject(
            basename: header.canonicalBasename,
            header: header,
            bytes: objectBytes,
            sha256: sha256Bytes(objectBytes),
          ),
        );
      }
      secondHashSink.close();
      final secondDigest = Uint8List.fromList(secondAccumulator.value.bytes);
      if (secondLength != declaredLength ||
          !constantTimeBytesEqual(secondDigest, firstPass.sha256) ||
          await input.length() != declaredLength) {
        throw const SboxException(SboxErrorCode.inputChanged, '输入在加密期间发生变化');
      }
      objects.sort(
        (left, right) =>
            left.header.shardIndex.compareTo(right.header.shardIndex),
      );
      return EncryptedBundle(
        manifest: manifest,
        objects: List<EncryptedBundleObject>.unmodifiable(objects),
        plaintextSha256: firstPass.sha256,
      );
    } finally {
      if (ownsRandomness) randomness.dispose();
      final wrappedSecret = wrapped;
      if (wrappedSecret != null) {
        wrappedSecret.fillRange(0, wrappedSecret.length, 0);
      }
      final manifestSecret = manifestBytes;
      if (manifestSecret != null) {
        manifestSecret.fillRange(0, manifestSecret.length, 0);
      }
    }
  }

  Future<List<String>> encryptToDirectory({
    required BundleInput input,
    required int declaredLength,
    required BundleEncryptionOptions options,
    required Directory root,
  }) async {
    if (declaredLength < 0) {
      throw const SboxException(
        SboxErrorCode.sourceLimit,
        'Input length is invalid',
      );
    }
    if (await input.length() != declaredLength) {
      throw const SboxException(
        SboxErrorCode.inputChanged,
        'Input changed before encryption',
      );
    }
    final plan = BundlePlanner.plan(
      logicalLength: declaredLength,
      targetNominalShardPlaintextSize: options.targetNominalShardPlaintextSize,
      maxObjectBytes: options.maxObjectBytes,
    );
    _validateStreamingOptions(
      options,
      logicalLength: declaredLength,
      plan: plan,
    );
    final canonicalRoot = await _prepareRoot(root);
    final staged = <_StagedShard>[];
    Uint8List? manifestBytes;
    Uint8List? wrapped;
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
    final randomness =
        options.randomness ??
        BundleEncryptionRandomness.secure(
          plan.shardCount,
          bundleId: firstPass.md5,
        );
    final ownsRandomness = options.randomness == null;
    try {
      final createdAt =
          options.createdAt ?? _utcSeconds(DateTime.now().toUtc());
      final manifest = BundleManifest(
        bundleId: hexLower(randomness.bundleId),
        recipientKeyId: hexLower(options.recipient.recipientKeyId),
        contentKind: options.contentKind,
        originalName: options.originalName,
        mediaType: options.mediaType,
        title: options.title ?? options.originalName,
        description: options.description,
        tags: options.tags,
        createdAt: createdAt,
        logicalPlaintextSize: BigInt.from(declaredLength),
        logicalPlaintextSha256: firstPass.sha256,
        nominalShardPlaintextSize: plan.nominalShardPlaintextSize,
        shardCount: plan.shardCount,
      );
      manifestBytes = manifest.encode();
      wrapped = RsaOaepSha256().encrypt(
        message: randomness.bundleDek,
        publicKey: options.recipient.rsaPublicKey,
        label: RsaOaepSha256.buildBundleDekLabel(
          bundleId: randomness.bundleId,
          recipientKeyId: options.recipient.recipientKeyId,
        ),
        seed: randomness.oaepSeed,
      );

      final secondAccumulator = HashDigestSink();
      final secondHashSink = crypto.sha256.startChunkedConversion(
        secondAccumulator,
      );
      var secondLength = 0;
      for (final shard in plan.shards) {
        final isRoot = shard.index == 0;
        final header = isRoot
            ? BundleHeader.root(
                bundleId: randomness.bundleId,
                shardCount: plan.shardCount,
                shardPlaintextSize: BigInt.from(shard.length),
                recipientKeyId: options.recipient.recipientKeyId,
                noncePrefix: randomness.noncePrefixes[shard.index],
                wrappedBundleDek: wrapped,
              )
            : BundleHeader.continuation(
                bundleId: randomness.bundleId,
                shardIndex: shard.index,
                shardCount: plan.shardCount,
                shardPlaintextSize: BigInt.from(shard.length),
                recipientKeyId: options.recipient.recipientKeyId,
                noncePrefix: randomness.noncePrefixes[shard.index],
              );
        final headerBytes = header.encode();
        final headerHash = sha256Bytes(headerBytes);
        final shardKey = ShardKdf.derive(
          bundleDek: randomness.bundleDek,
          bundleId: randomness.bundleId,
          recipientKeyId: options.recipient.recipientKeyId,
          shardIndex: shard.index,
        );
        final stage = File(
          '${canonicalRoot.path}${Platform.pathSeparator}.${header.canonicalBasename}.${hexLower(secureRandomBytes(8))}.part',
        );
        final output = stage.openWrite();
        try {
          output.add(headerBytes);
          await output.flush();
          if (isRoot) {
            final record = await _records.encrypt(
              type: BundleRecordType.manifest,
              index: BigInt.zero,
              plaintext: manifestBytes,
              shardKey: shardKey,
              noncePrefix: header.noncePrefix,
              headerHash: headerHash,
            );
            output.add(record);
            await output.flush();
            record.fillRange(0, record.length, 0);
          }

          final shardAccumulator = HashDigestSink();
          final shardHashSink = crypto.sha256.startChunkedConversion(
            shardAccumulator,
          );
          var shardDataLength = 0;
          var dataRecordCount = 0;
          await for (final plainChunk in _rangeChunks(
            input,
            start: shard.offset,
            length: shard.length,
            chunkSize: SboxProtocol.chunkSize,
          )) {
            try {
              shardHashSink.add(plainChunk);
              secondHashSink.add(plainChunk);
              secondLength += plainChunk.length;
              final record = await _records.encrypt(
                type: BundleRecordType.data,
                index: BigInt.from(dataRecordCount + 1),
                plaintext: plainChunk,
                shardKey: shardKey,
                noncePrefix: header.noncePrefix,
                headerHash: headerHash,
              );
              output.add(record);
              await output.flush();
              record.fillRange(0, record.length, 0);
              shardDataLength += plainChunk.length;
              dataRecordCount++;
            } finally {
              plainChunk.fillRange(0, plainChunk.length, 0);
            }
          }
          shardHashSink.close();
          if (shardDataLength != shard.length) {
            throw const SboxException(
              SboxErrorCode.inputChanged,
              'Input changed during encryption',
            );
          }
          final shardDigest = Uint8List.fromList(shardAccumulator.value.bytes);
          final finalPlaintext = Uint8List(SboxProtocol.finalPlaintextLength);
          writeUint64BigEndian(finalPlaintext, 0, BigInt.from(shardDataLength));
          writeUint64BigEndian(finalPlaintext, 8, BigInt.from(dataRecordCount));
          finalPlaintext.setRange(16, 48, shardDigest);
          try {
            final record = await _records.encrypt(
              type: BundleRecordType.finalRecord,
              index: BigInt.from(dataRecordCount + 1),
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
          await output.close();
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
        } finally {
          shardKey.fillRange(0, shardKey.length, 0);
          await output.close();
          if (await stage.exists() &&
              !staged.any((item) => item.stage.path == stage.path)) {
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
      if (ownsRandomness) randomness.dispose();
      final manifestSecret = manifestBytes;
      if (manifestSecret != null) {
        manifestSecret.fillRange(0, manifestSecret.length, 0);
      }
      final wrappedSecret = wrapped;
      if (wrappedSecret != null) {
        wrappedSecret.fillRange(0, wrappedSecret.length, 0);
      }
      for (final shard in staged) {
        if (await shard.stage.exists()) await shard.stage.delete();
      }
    }
  }

  static void _validateStreamingOptions(
    BundleEncryptionOptions options, {
    required int logicalLength,
    required BundlePlan plan,
  }) {
    if (options.recipient.rsaPublicKey.modulus.bitLength !=
            SboxProtocol.rsaBits ||
        options.recipient.rsaPublicKey.exponent !=
            BigInt.from(SboxProtocol.rsaPublicExponent)) {
      throw const SboxException(
        SboxErrorCode.keyMismatch,
        'Recipient RSA parameters are invalid',
      );
    }
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
      logicalPlaintextSize: BigInt.from(logicalLength),
      logicalPlaintextSha256: Uint8List(32),
      nominalShardPlaintextSize: plan.nominalShardPlaintextSize,
      shardCount: plan.shardCount,
    );
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
      throw const SboxException(
        SboxErrorCode.storageOverlap,
        '鏁版嵁婧愮洰鏍囦笉鏄畨鍏ㄦ枃浠?',
      );
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
        sink.close();
        md5Sink.close();
        throw const SboxException(SboxErrorCode.inputChanged, '输入范围超过声明长度');
      }
      sink.add(chunk);
      md5Sink.add(chunk);
      try {
        utf8Validator?.add(chunk);
      } on FormatException {
        throw const SboxException(
          SboxErrorCode.integrity,
          '鏂囨湰杈撳叆涓嶆槸涓ユ牸 UTF-8',
        );
      }
    }
    sink.close();
    md5Sink.close();
    try {
      utf8Validator?.close();
    } on FormatException {
      throw const SboxException(SboxErrorCode.integrity, '鏂囨湰杈撳叆涓嶆槸涓ユ牸 UTF-8');
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
