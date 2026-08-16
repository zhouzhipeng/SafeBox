import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;

import '../bytes.dart';
import '../catalog/catalog_models.dart';
import '../catalog/catalog_signature.dart';
import '../constants.dart';
import '../crypto/rsa_oaep.dart';
import '../errors.dart';
import '../format/header.dart';
import '../format/metadata.dart';
import '../format/record.dart';
import '../identity/bip39_identity.dart';
import '../identity/ephemeral_mnemonic.dart';
import '../identity/rsa_models.dart';
import '../source/source_path.dart';
import '../storage/local_cipher_store.dart';
import '../storage/temporary_plaintext_store.dart';
import 'job_control.dart';
import 'streaming_container.dart';

Future<VerifiedTemporaryPlaintext> decryptCatalogEntry({
  required VerifiedCatalogEntry entry,
  required LocalCipherStore cipherStore,
  required TemporaryPlaintextStore plaintextStore,
  required EphemeralMnemonic mnemonic,
  required PublicIdentity expectedIdentity,
  required JobControl control,
}) async {
  final payload = entry.entry.payload;
  final located = <_LocatedPart>[];
  StagedPlaintext? staged;
  try {
    // Verify every immutable ciphertext object before any RSA operation.
    for (final part in payload.parts) {
      control.checkCancelled();
      final object = await cipherStore.find(
        SourcePath(part.objectPath),
        decodeHex(part.sboxSha256),
      );
      if (object == null) {
        throw const SboxException(
          SboxErrorCode.multipartMissing,
          '分片不完整，请继续同步',
        );
      }
      if (BigInt.from(object.length) != part.sboxSize) {
        throw const SboxException(
          SboxErrorCode.integrity,
          'SBOX 分片大小与已认证目录不一致',
        );
      }
      final file = await object.file.open(mode: FileMode.read);
      late final SboxHeader header;
      try {
        header = SboxHeader.parse(
          await _readExactFile(file, SboxV1.headerLength),
        );
      } finally {
        await file.close();
      }
      if (hexLower(header.fileId) != part.fileId ||
          !constantTimeBytesEqual(
            header.recipientKeyId,
            expectedIdentity.recipientKeyId,
          )) {
        throw const SboxException(
          SboxErrorCode.integrity,
          'SBOX 分片头部与已认证目录不一致',
        );
      }
      located.add(
        _LocatedPart(
          manifest: part,
          object: object,
          header: header,
          headerHash: sha256Bytes(header.encode()),
        ),
      );
    }

    staged = await plaintextStore.createForJob(JobId.random());
    if (payload.mode == CatalogPayloadMode.single) {
      final verified = await decryptSingleContainerWithMnemonic(
        input: located.single.object.file.openRead(),
        stagedPlaintext: staged.openSink(),
        mnemonic: mnemonic,
        expectedIdentity: expectedIdentity,
        control: control,
      );
      if ((verified.metadata.contentKind != SboxContentKind.file &&
              verified.metadata.contentKind != SboxContentKind.text) ||
          verified.metadata.originalName != entry.entry.originalName ||
          verified.metadata.mediaType != entry.entry.mediaType ||
          BigInt.from(verified.plaintextLength) != payload.plaintextSize ||
          hexLower(verified.plaintextSha256) != payload.plaintextSha256) {
        throw const SboxException(SboxErrorCode.catalog, 'SBOX 内容与已认证目录不一致');
      }
      staged.accept(verified);
      return await plaintextStore.publishVerified(staged);
    }

    return await _decryptMultipartEntry(
      entry: entry.entry,
      located: located,
      staged: staged,
      plaintextStore: plaintextStore,
      mnemonic: mnemonic,
      expectedIdentity: expectedIdentity,
      control: control,
    );
  } catch (_) {
    await staged?.discard();
    rethrow;
  } finally {
    mnemonic.dispose();
  }
}

Future<VerifiedTemporaryPlaintext> _decryptMultipartEntry({
  required CatalogEntry entry,
  required List<_LocatedPart> located,
  required StagedPlaintext staged,
  required TemporaryPlaintextStore plaintextStore,
  required EphemeralMnemonic mnemonic,
  required PublicIdentity expectedIdentity,
  required JobControl control,
}) async {
  final payload = entry.payload;
  final records = SboxRecordCodec();
  final oaep = RsaOaepSha256();
  EphemeralIdentity? ephemeral;
  final contexts = <_PartDecryptionContext>[];
  IOSink? output;
  try {
    ephemeral = await SboxIdentityDeriver().deriveIdentity(
      mnemonic.revealForDerivation(),
    );
    if (!constantTimeBytesEqual(
          ephemeral.publicIdentity.recipientKeyId,
          expectedIdentity.recipientKeyId,
        ) ||
        !constantTimeBytesEqual(
          ephemeral.publicIdentity.catalogSignerKeyId,
          expectedIdentity.catalogSignerKeyId,
        )) {
      throw const SboxException(SboxErrorCode.keyMismatch, '助记词与当前身份不匹配');
    }

    for (var index = 0; index < located.length; index++) {
      control.checkCancelled();
      final locatedPart = located[index];
      final label = RsaOaepSha256.buildDekLabel(
        fileId: locatedPart.header.fileId,
        recipientKeyId: locatedPart.header.recipientKeyId,
      );
      final dek = oaep.decrypt(
        ciphertext: locatedPart.header.wrappedDek,
        privateKey: ephemeral.rsaPrivateKey,
        label: label,
      );
      if (dek.length != SboxV1.dekLength) {
        dek.fillRange(0, dek.length, 0);
        throw const SboxException(SboxErrorCode.authentication, '密钥解封或密文认证失败');
      }

      final file = await locatedPart.object.file.open(mode: FileMode.read);
      try {
        await file.setPosition(SboxV1.headerLength);
        final metadataRecord = await _readFileRecord(
          file,
          records,
          maximumPlaintextLength: 4096,
        );
        if (metadataRecord.type != SboxRecordType.metadata ||
            metadataRecord.index != BigInt.zero) {
          throw _multipartError();
        }
        final metadataPlaintext = await records.decrypt(
          record: metadataRecord,
          dek: dek,
          noncePrefix: locatedPart.header.noncePrefix,
          headerHash: locatedPart.headerHash,
        );
        final metadata = SboxMetadata.parse(metadataPlaintext);
        metadataPlaintext.fillRange(0, metadataPlaintext.length, 0);
        _validatePartMetadata(
          metadata: metadata,
          entry: entry,
          manifest: locatedPart.manifest,
          partCount: located.length,
        );
        contexts.add(
          _PartDecryptionContext(
            located: locatedPart,
            metadata: metadata,
            dek: dek,
            dataOffset: await file.position(),
          ),
        );
      } catch (_) {
        dek.fillRange(0, dek.length, 0);
        rethrow;
      } finally {
        await file.close();
      }
      control.report(
        SboxJobProgress(
          phase: SboxJobPhase.authenticatingParts,
          processedBytes: index + 1,
          totalBytes: located.length,
          partIndex: index,
          partCount: located.length,
        ),
      );
    }

    // All OAEP and Metadata checks are complete. Retain only the bounded DEK
    // array, and drop application references to RSA and signing seed material.
    ephemeral.disposeControlledSecrets();
    ephemeral = null;
    mnemonic.dispose();

    final outputSink = staged.openSink();
    output = outputSink;
    final logicalAccumulator = AccumulatorSink<crypto.Digest>();
    final logicalHashSink = crypto.sha256.startChunkedConversion(
      logicalAccumulator,
    );
    var logicalLength = 0;
    for (var partIndex = 0; partIndex < contexts.length; partIndex++) {
      final context = contexts[partIndex];
      final partAccumulator = AccumulatorSink<crypto.Digest>();
      final partHashSink = crypto.sha256.startChunkedConversion(
        partAccumulator,
      );
      final file = await context.located.object.file.open(mode: FileMode.read);
      var partLength = 0;
      var dataRecordCount = 0;
      var sawShortRecord = false;
      try {
        await file.setPosition(context.dataOffset);
        var expectedIndex = BigInt.one;
        while (true) {
          control.checkCancelled();
          final record = await _readFileRecord(
            file,
            records,
            maximumPlaintextLength: context.located.header.chunkSize,
          );
          if (record.index != expectedIndex) {
            throw _multipartError();
          }
          if (record.type == SboxRecordType.finalRecord) {
            if (record.plaintextLength != 48) {
              throw _multipartError();
            }
            final finalPlaintext = await records.decrypt(
              record: record,
              dek: context.dek,
              noncePrefix: context.located.header.noncePrefix,
              headerHash: context.located.headerHash,
            );
            final finalRecord = SboxFinalRecord.parse(finalPlaintext);
            finalPlaintext.fillRange(0, finalPlaintext.length, 0);
            if (await file.position() != await file.length()) {
              throw const SboxException(
                SboxErrorCode.trailingData,
                'SBOX Final 记录后存在尾随数据',
              );
            }
            partHashSink.close();
            final partSha256 = Uint8List.fromList(
              partAccumulator.events.single.bytes,
            );
            if (finalRecord.totalDataLength != BigInt.from(partLength) ||
                finalRecord.dataRecordCount != BigInt.from(dataRecordCount) ||
                context.metadata.originalSize != BigInt.from(partLength) ||
                BigInt.from(partLength) !=
                    context.located.manifest.plaintextSize ||
                !constantTimeBytesEqual(finalRecord.dataSha256, partSha256) ||
                hexLower(partSha256) !=
                    context.located.manifest.plaintextSha256) {
              throw const SboxException(
                SboxErrorCode.integrity,
                'SBOX 分片 Final 校验失败',
              );
            }
            break;
          }
          if (record.type != SboxRecordType.data ||
              record.plaintextLength == 0 ||
              sawShortRecord) {
            throw _multipartError();
          }
          final plaintext = await records.decrypt(
            record: record,
            dek: context.dek,
            noncePrefix: context.located.header.noncePrefix,
            headerHash: context.located.headerHash,
          );
          partHashSink.add(plaintext);
          logicalHashSink.add(plaintext);
          outputSink.add(plaintext);
          await outputSink.flush();
          partLength += plaintext.length;
          logicalLength += plaintext.length;
          dataRecordCount++;
          sawShortRecord = plaintext.length < context.located.header.chunkSize;
          plaintext.fillRange(0, plaintext.length, 0);
          expectedIndex += BigInt.one;
        }
      } finally {
        context.dek.fillRange(0, context.dek.length, 0);
        await file.close();
      }
      control.report(
        SboxJobProgress(
          phase: SboxJobPhase.reassembling,
          processedBytes: logicalLength,
          totalBytes: payload.plaintextSize.toInt(),
          partIndex: partIndex,
          partCount: contexts.length,
        ),
      );
    }
    logicalHashSink.close();
    final logicalSha256 = Uint8List.fromList(
      logicalAccumulator.events.single.bytes,
    );
    if (BigInt.from(logicalLength) != payload.plaintextSize ||
        hexLower(logicalSha256) != payload.plaintextSha256) {
      throw const SboxException(
        SboxErrorCode.integrity,
        'multipart 重组后的完整摘要不匹配',
      );
    }
    await outputSink.flush();
    await outputSink.close();
    output = null;

    final logicalMetadata = SboxMetadata(
      contentKind: SboxContentKind.file,
      originalSize: BigInt.from(logicalLength),
      originalName: entry.originalName,
      mediaType: entry.mediaType,
    );
    final verified = VerifiedPlaintext.reassembled(
      firstPartHeader: contexts.first.located.header,
      logicalMetadata: logicalMetadata,
      plaintextLength: logicalLength,
      plaintextSha256: logicalSha256,
    );
    staged.accept(verified);
    return await plaintextStore.publishVerified(staged);
  } finally {
    ephemeral?.disposeControlledSecrets();
    for (final context in contexts) {
      context.dek.fillRange(0, context.dek.length, 0);
    }
    if (output != null) {
      await output.close();
    }
  }
}

void _validatePartMetadata({
  required SboxMetadata metadata,
  required CatalogEntry entry,
  required CatalogPart manifest,
  required int partCount,
}) {
  final extension = metadata.multipart;
  if (metadata.contentKind != SboxContentKind.multipartPart ||
      extension == null ||
      metadata.originalName != entry.originalName ||
      metadata.mediaType != entry.mediaType ||
      metadata.originalSize != manifest.plaintextSize ||
      hexLower(extension.multipartId) != entry.payload.multipartId ||
      extension.partIndex != manifest.index ||
      extension.partCount != partCount ||
      extension.plaintextOffset != manifest.plaintextOffset ||
      extension.logicalPlaintextSize != entry.payload.plaintextSize) {
    throw _multipartError();
  }
}

Future<SboxEncryptedRecord> _readFileRecord(
  RandomAccessFile file,
  SboxRecordCodec codec, {
  required int maximumPlaintextLength,
}) async {
  final header = await _readExactFile(file, SboxV1.recordHeaderLength);
  final plaintextLength = readUint32BigEndian(header, 9);
  if (plaintextLength > maximumPlaintextLength) {
    throw const SboxException(SboxErrorCode.limits, 'SBOX 记录超过安全上限');
  }
  final body = await _readExactFile(
    file,
    plaintextLength + SboxV1.gcmTagLength,
  );
  return codec.parseAt(
    concatBytes(<List<int>>[header, body]),
    0,
    maximumPlaintextLength: maximumPlaintextLength,
  );
}

Future<Uint8List> _readExactFile(RandomAccessFile file, int length) async {
  final result = Uint8List(length);
  var offset = 0;
  while (offset < length) {
    final count = await file.readInto(result, offset, length);
    if (count == 0) {
      throw const SboxException(SboxErrorCode.truncated, 'SBOX 文件提前结束');
    }
    offset += count;
  }
  return result;
}

final class _LocatedPart {
  const _LocatedPart({
    required this.manifest,
    required this.object,
    required this.header,
    required this.headerHash,
  });

  final CatalogPart manifest;
  final CiphertextObject object;
  final SboxHeader header;
  final Uint8List headerHash;
}

final class _PartDecryptionContext {
  const _PartDecryptionContext({
    required this.located,
    required this.metadata,
    required this.dek,
    required this.dataOffset,
  });

  final _LocatedPart located;
  final SboxMetadata metadata;
  final Uint8List dek;
  final int dataOffset;
}

SboxException _multipartError() =>
    const SboxException(SboxErrorCode.multipartManifest, '大文件分片清单无效，已停止处理');
