import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;

import '../bytes.dart';
import '../catalog/catalog_models.dart';
import '../constants.dart';
import '../errors.dart';
import '../format/metadata.dart';
import '../source/data_source.dart';
import '../source/source_path.dart';
import '../storage/local_cipher_store.dart';
import 'container_codec.dart';
import 'job_control.dart';
import 'streaming_container.dart';

abstract interface class ReadableInputRef {
  Future<int> length();

  Stream<List<int>> openRange(int start, int length);
}

final class FileReadableInputRef implements ReadableInputRef {
  FileReadableInputRef(this.file);

  final File file;

  @override
  Future<int> length() => file.length();

  @override
  Stream<List<int>> openRange(int start, int length) {
    if (start < 0 || length < 0) {
      throw ArgumentError('Invalid input range');
    }
    return file.openRead(start, start + length);
  }
}

final class MemoryReadableInputRef implements ReadableInputRef {
  MemoryReadableInputRef(List<int> bytes) : _bytes = Uint8List.fromList(bytes);

  final Uint8List _bytes;

  @override
  Future<int> length() async => _bytes.length;

  @override
  Stream<List<int>> openRange(int start, int length) {
    if (start < 0 || length < 0 || start + length > _bytes.length) {
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

final class MultipartPartPlan {
  const MultipartPartPlan({
    required this.index,
    required this.offset,
    required this.length,
  });

  final int index;
  final int offset;
  final int length;
}

final class MultipartPlan {
  const MultipartPlan({
    required this.logicalLength,
    required this.effectivePartPlaintextSize,
    required this.parts,
  });

  final int logicalLength;
  final int effectivePartPlaintextSize;
  final List<MultipartPartPlan> parts;

  bool get isMultipart => parts.length > 1;
}

abstract final class MultipartPlanner {
  static BigInt sboxSizeUpperBound(BigInt plaintextLength) {
    if (plaintextLength.isNegative) {
      throw ArgumentError.value(plaintextLength, 'plaintextLength');
    }
    final chunk = BigInt.from(SboxV1.internalChunkSize);
    final recordCount = plaintextLength == BigInt.zero
        ? BigInt.zero
        : (plaintextLength + chunk - BigInt.one) ~/ chunk;
    return plaintextLength + BigInt.from(4670) + BigInt.from(29) * recordCount;
  }

  static MultipartPlan plan({
    required int logicalLength,
    required SourceCapabilities target,
    int targetPartPlaintextSize = SboxV1.defaultPartPlaintextSize,
    bool forceMultipart = false,
  }) {
    const unit = 1024 * 1024;
    if (logicalLength < 0 ||
        targetPartPlaintextSize < SboxV1.minPartPlaintextSize ||
        targetPartPlaintextSize > SboxV1.maxPartPlaintextSize ||
        targetPartPlaintextSize % unit != 0) {
      throw const SboxException(
        SboxErrorCode.sourceLimit,
        '分片大小必须是 1 MiB..512 MiB 的整数 MiB',
      );
    }

    var effective = targetPartPlaintextSize;
    final maximum = target.maxObjectBytes;
    if (maximum != null) {
      while (effective >= SboxV1.minPartPlaintextSize &&
          sboxSizeUpperBound(BigInt.from(effective)) > maximum) {
        effective -= unit;
      }
      if (effective < SboxV1.minPartPlaintextSize) {
        throw const SboxException(
          SboxErrorCode.sourceLimit,
          '数据源无法容纳最小 1 MiB SBOX 分片',
        );
      }
    }

    if (forceMultipart && logicalLength <= effective) {
      if (logicalLength <= SboxV1.minPartPlaintextSize) {
        throw const SboxException(
          SboxErrorCode.multipartManifest,
          '此文件过小，无法生成至少两个规范分片',
        );
      }
      effective = ((logicalLength - 1) ~/ unit) * unit;
      effective = effective.clamp(SboxV1.minPartPlaintextSize, effective);
    }

    final count = logicalLength == 0
        ? 1
        : (logicalLength + effective - 1) ~/ effective;
    if (count > 10000 || (forceMultipart && count < 2)) {
      throw const SboxException(
        SboxErrorCode.multipartManifest,
        '分片数量不在 SBOX v1 允许范围内',
      );
    }
    final parts = <MultipartPartPlan>[];
    for (var index = 0; index < count; index++) {
      final offset = index * effective;
      final length = (logicalLength - offset).clamp(0, effective);
      parts.add(
        MultipartPartPlan(index: index, offset: offset, length: length),
      );
    }
    return MultipartPlan(
      logicalLength: logicalLength,
      effectivePartPlaintextSize: effective,
      parts: List<MultipartPartPlan>.unmodifiable(parts),
    );
  }
}

final class PreparedPayload {
  PreparedPayload._({
    required this.catalogPayload,
    required this.objects,
    required this.multipartId,
  });

  final CatalogPayload catalogPayload;
  final List<CiphertextObject> objects;
  final Uint8List? multipartId;
}

Future<PreparedPayload> encryptLogicalFile({
  required ReadableInputRef input,
  required int inputLength,
  required SourceCapabilities target,
  required LocalCipherStore cipherStore,
  required EncryptOptions options,
  required JobControl control,
  int targetPartPlaintextSize = SboxV1.defaultPartPlaintextSize,
  bool forceMultipart = false,
}) async {
  if (await input.length() != inputLength) {
    throw const SboxException(SboxErrorCode.integrity, '输入长度在加密前发生变化');
  }
  if (options.multipart != null ||
      options.contentKind == SboxContentKind.catalog ||
      options.contentKind == SboxContentKind.multipartPart) {
    throw ArgumentError('encryptLogicalFile expects a file or text input');
  }
  final plan = MultipartPlanner.plan(
    logicalLength: inputLength,
    target: target,
    targetPartPlaintextSize: targetPartPlaintextSize,
    forceMultipart: forceMultipart,
  );
  control.report(
    SboxJobProgress(
      phase: SboxJobPhase.planningParts,
      processedBytes: 0,
      totalBytes: inputLength,
      partCount: plan.parts.length,
    ),
  );

  final multipartId = plan.isMultipart ? secureRandomBytes(16) : null;
  final logicalAccumulator = AccumulatorSink<crypto.Digest>();
  final logicalHashSink = crypto.sha256.startChunkedConversion(
    logicalAccumulator,
  );
  final stagedItems = <_PreparedStagedPart>[];
  var committedCount = 0;
  try {
    for (final part in plan.parts) {
      control.checkCancelled();
      final randomness = SboxEncryptionRandomness.secure();
      final fileIdHex = hexLower(randomness.fileId);
      final objectPath = SourcePath(
        'objects/${fileIdHex.substring(0, 2)}/$fileIdHex.sbox',
      );
      final staged = await cipherStore.createStaging(objectPath);
      try {
        final partStream = input.openRange(part.offset, part.length).map((
          chunk,
        ) {
          logicalHashSink.add(chunk);
          return chunk;
        });
        final artifact = await encryptContainer(
          input: partStream,
          inputLength: part.length,
          stagedOutput: staged.openSink(),
          options: EncryptOptions(
            recipient: options.recipient,
            contentKind: plan.isMultipart
                ? SboxContentKind.multipartPart
                : options.contentKind,
            originalName: options.originalName,
            mediaType: options.mediaType,
            multipart: plan.isMultipart
                ? MultipartMetadata(
                    multipartId: multipartId!,
                    partIndex: part.index,
                    partCount: plan.parts.length,
                    plaintextOffset: BigInt.from(part.offset),
                    logicalPlaintextSize: BigInt.from(inputLength),
                  )
                : null,
            randomness: randomness,
          ),
          control: control,
        );
        if (target.maxObjectBytes != null &&
            BigInt.from(artifact.sboxLength) > target.maxObjectBytes!) {
          throw const SboxException(
            SboxErrorCode.sourceLimit,
            '生成的 SBOX 分片超过数据源单对象上限',
          );
        }
        staged.accept(artifact);
        stagedItems.add(
          _PreparedStagedPart(
            plan: part,
            objectPath: objectPath,
            staged: staged,
            artifact: artifact,
          ),
        );
      } catch (_) {
        await staged.discard();
        rethrow;
      } finally {
        randomness.dispose();
      }
    }
    logicalHashSink.close();
    final logicalSha256 = Uint8List.fromList(
      logicalAccumulator.events.single.bytes,
    );

    final objects = <CiphertextObject>[];
    for (final item in stagedItems) {
      control.report(
        SboxJobProgress(
          phase: SboxJobPhase.committingLocalCiphertext,
          processedBytes: item.plan.offset + item.plan.length,
          totalBytes: inputLength,
          partIndex: item.plan.index,
          partCount: stagedItems.length,
        ),
      );
      objects.add(await cipherStore.commitVerified(item.staged));
      committedCount++;
    }

    final catalogParts = stagedItems
        .map(
          (item) => CatalogPart(
            index: item.plan.index,
            objectPath: item.objectPath.value,
            fileId: hexLower(item.artifact.header.fileId),
            plaintextOffset: BigInt.from(item.plan.offset),
            plaintextSize: BigInt.from(item.plan.length),
            plaintextSha256: hexLower(item.artifact.plaintextSha256),
            sboxSize: BigInt.from(item.artifact.sboxLength),
            sboxSha256: hexLower(item.artifact.sboxSha256),
          ),
        )
        .toList(growable: false);
    final payload = CatalogPayload(
      mode: plan.isMultipart
          ? CatalogPayloadMode.multipart
          : CatalogPayloadMode.single,
      multipartId: multipartId == null ? null : hexLower(multipartId),
      plaintextSize: BigInt.from(inputLength),
      plaintextSha256: hexLower(logicalSha256),
      partPlaintextSize: plan.isMultipart
          ? BigInt.from(plan.effectivePartPlaintextSize)
          : null,
      parts: catalogParts,
    );
    return PreparedPayload._(
      catalogPayload: payload,
      objects: List<CiphertextObject>.unmodifiable(objects),
      multipartId: multipartId,
    );
  } finally {
    for (var index = committedCount; index < stagedItems.length; index++) {
      await stagedItems[index].staged.discard();
    }
  }
}

final class _PreparedStagedPart {
  const _PreparedStagedPart({
    required this.plan,
    required this.objectPath,
    required this.staged,
    required this.artifact,
  });

  final MultipartPartPlan plan;
  final SourcePath objectPath;
  final StagedCiphertext staged;
  final EncryptedArtifact artifact;
}
