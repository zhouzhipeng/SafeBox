import 'dart:typed_data';

import '../bytes.dart';
import '../constants.dart';
import '../crypto/rsa_oaep.dart';
import '../errors.dart';
import '../format/header.dart';
import '../format/metadata.dart';
import '../format/record.dart';
import '../identity/der.dart';
import '../identity/rsa_models.dart';

final class SboxEncryptionRandomness {
  SboxEncryptionRandomness({
    required List<int> dek,
    required List<int> fileId,
    required List<int> noncePrefix,
    List<int>? oaepSeed,
  }) : dek = Uint8List.fromList(dek),
       fileId = Uint8List.fromList(fileId),
       noncePrefix = Uint8List.fromList(noncePrefix),
       oaepSeed = oaepSeed == null ? null : Uint8List.fromList(oaepSeed) {
    if (this.dek.length != SboxV1.dekLength ||
        this.fileId.length != SboxV1.fileIdLength ||
        this.noncePrefix.length != SboxV1.noncePrefixLength ||
        (this.oaepSeed != null && this.oaepSeed!.length != 32)) {
      throw ArgumentError('Invalid SBOX encryption randomness');
    }
  }

  final Uint8List dek;
  final Uint8List fileId;
  final Uint8List noncePrefix;
  final Uint8List? oaepSeed;

  factory SboxEncryptionRandomness.secure() => SboxEncryptionRandomness(
    dek: secureRandomBytes(SboxV1.dekLength),
    fileId: secureRandomBytes(SboxV1.fileIdLength),
    noncePrefix: secureRandomBytes(SboxV1.noncePrefixLength),
  );

  void dispose() {
    dek.fillRange(0, dek.length, 0);
    oaepSeed?.fillRange(0, oaepSeed!.length, 0);
  }
}

final class VerifiedContainer {
  VerifiedContainer({
    required this.header,
    required this.metadata,
    required List<int> data,
  }) : data = Uint8List.fromList(data);

  final SboxHeader header;
  final SboxMetadata metadata;
  final Uint8List data;
}

final class SboxContainerCodec {
  SboxContainerCodec({RsaOaepSha256? rsaOaep})
    : _rsaOaep = rsaOaep ?? RsaOaepSha256(),
      _records = SboxRecordCodec();

  final RsaOaepSha256 _rsaOaep;
  final SboxRecordCodec _records;

  Future<Uint8List> encryptBytes({
    required PublicIdentity recipient,
    required SboxContentKind contentKind,
    required String originalName,
    required String mediaType,
    required List<int> data,
    MultipartMetadata? multipart,
    SboxEncryptionRandomness? randomness,
  }) async {
    final material = randomness ?? SboxEncryptionRandomness.secure();
    final ownsMaterial = randomness == null;
    try {
      final label = RsaOaepSha256.buildDekLabel(
        fileId: material.fileId,
        recipientKeyId: recipient.recipientKeyId,
      );
      final wrappedDek = _rsaOaep.encrypt(
        message: material.dek,
        publicKey: recipient.rsaPublicKey,
        label: label,
        seed: material.oaepSeed,
      );
      final header = SboxHeader(
        fileId: material.fileId,
        recipientKeyId: recipient.recipientKeyId,
        noncePrefix: material.noncePrefix,
        wrappedDek: wrappedDek,
      );
      final headerBytes = header.encode();
      final headerHash = sha256Bytes(headerBytes);
      final metadata = SboxMetadata(
        contentKind: contentKind,
        originalSize: BigInt.from(data.length),
        originalName: originalName,
        mediaType: mediaType,
        multipart: multipart,
      );

      final output = BytesBuilder(copy: false)..add(headerBytes);
      var recordIndex = BigInt.zero;
      output.add(
        await _records.encrypt(
          type: SboxRecordType.metadata,
          index: recordIndex,
          plaintext: metadata.encode(),
          dek: material.dek,
          noncePrefix: material.noncePrefix,
          headerHash: headerHash,
        ),
      );

      var dataRecordCount = 0;
      for (var offset = 0; offset < data.length; offset += header.chunkSize) {
        final end = (offset + header.chunkSize).clamp(0, data.length);
        recordIndex += BigInt.one;
        output.add(
          await _records.encrypt(
            type: SboxRecordType.data,
            index: recordIndex,
            plaintext: data.sublist(offset, end),
            dek: material.dek,
            noncePrefix: material.noncePrefix,
            headerHash: headerHash,
          ),
        );
        dataRecordCount++;
      }

      recordIndex += BigInt.one;
      final finalRecord = SboxFinalRecord(
        totalDataLength: BigInt.from(data.length),
        dataRecordCount: BigInt.from(dataRecordCount),
        dataSha256: sha256Bytes(data),
      );
      output.add(
        await _records.encrypt(
          type: SboxRecordType.finalRecord,
          index: recordIndex,
          plaintext: finalRecord.encode(),
          dek: material.dek,
          noncePrefix: material.noncePrefix,
          headerHash: headerHash,
        ),
      );
      return output.takeBytes();
    } finally {
      if (ownsMaterial) {
        material.dispose();
      }
    }
  }

  Future<VerifiedContainer> decryptBytes({
    required List<int> container,
    required SboxRsaPrivateKey privateKey,
    required List<int> expectedRecipientKeyId,
  }) async {
    final header = SboxHeader.parse(container);
    final derivedKeyId = sha256Bytes(
      encodeRsaSubjectPublicKeyInfo(privateKey.publicKey),
    );
    if (!constantTimeBytesEqual(
          header.recipientKeyId,
          expectedRecipientKeyId,
        ) ||
        !constantTimeBytesEqual(derivedKeyId, expectedRecipientKeyId) ||
        privateKey.publicKey.modulus.bitLength != SboxV1.rsaBits) {
      derivedKeyId.fillRange(0, derivedKeyId.length, 0);
      throw const SboxException(SboxErrorCode.keyMismatch, '此 SBOX 不属于当前身份');
    }
    derivedKeyId.fillRange(0, derivedKeyId.length, 0);

    final label = RsaOaepSha256.buildDekLabel(
      fileId: header.fileId,
      recipientKeyId: header.recipientKeyId,
    );
    final dek = _rsaOaep.decrypt(
      ciphertext: header.wrappedDek,
      privateKey: privateKey,
      label: label,
    );
    if (dek.length != SboxV1.dekLength) {
      dek.fillRange(0, dek.length, 0);
      throw const SboxException(SboxErrorCode.authentication, '密钥解封或密文认证失败');
    }

    try {
      final headerHash = sha256Bytes(container.sublist(0, SboxV1.headerLength));
      var offset = SboxV1.headerLength;
      var expectedIndex = BigInt.zero;
      final metadataRecord = _records.parseAt(
        container,
        offset,
        maximumPlaintextLength: 4096,
      );
      if (metadataRecord.type != SboxRecordType.metadata ||
          metadataRecord.index != expectedIndex) {
        throw _invalidSequence();
      }
      final metadataPlaintext = await _records.decrypt(
        record: metadataRecord,
        dek: dek,
        noncePrefix: header.noncePrefix,
        headerHash: headerHash,
      );
      final metadata = SboxMetadata.parse(metadataPlaintext);
      metadataPlaintext.fillRange(0, metadataPlaintext.length, 0);
      offset = metadataRecord.nextOffset;

      final output = BytesBuilder(copy: false);
      var dataLength = 0;
      var dataRecordCount = 0;
      var sawShortDataRecord = false;
      while (true) {
        expectedIndex += BigInt.one;
        final record = _records.parseAt(
          container,
          offset,
          maximumPlaintextLength: header.chunkSize,
        );
        if (record.index != expectedIndex) {
          throw _invalidSequence();
        }
        if (record.type == SboxRecordType.finalRecord) {
          if (record.plaintextLength != 48) {
            throw _invalidSequence();
          }
          final finalPlaintext = await _records.decrypt(
            record: record,
            dek: dek,
            noncePrefix: header.noncePrefix,
            headerHash: headerHash,
          );
          final finalRecord = SboxFinalRecord.parse(finalPlaintext);
          finalPlaintext.fillRange(0, finalPlaintext.length, 0);
          final data = output.takeBytes();
          if (record.nextOffset != container.length) {
            data.fillRange(0, data.length, 0);
            throw const SboxException(
              SboxErrorCode.trailingData,
              'SBOX Final 记录后存在尾随数据',
            );
          }
          if (finalRecord.totalDataLength != BigInt.from(dataLength) ||
              finalRecord.dataRecordCount != BigInt.from(dataRecordCount) ||
              metadata.originalSize != BigInt.from(dataLength) ||
              !constantTimeBytesEqual(
                finalRecord.dataSha256,
                sha256Bytes(data),
              )) {
            data.fillRange(0, data.length, 0);
            throw const SboxException(
              SboxErrorCode.integrity,
              'SBOX 最终完整性校验失败',
            );
          }
          return VerifiedContainer(
            header: header,
            metadata: metadata,
            data: data,
          );
        }
        if (record.type != SboxRecordType.data ||
            record.plaintextLength == 0 ||
            sawShortDataRecord) {
          throw _invalidSequence();
        }
        final plaintext = await _records.decrypt(
          record: record,
          dek: dek,
          noncePrefix: header.noncePrefix,
          headerHash: headerHash,
        );
        output.add(plaintext);
        dataLength += plaintext.length;
        dataRecordCount++;
        sawShortDataRecord = plaintext.length < header.chunkSize;
        offset = record.nextOffset;
      }
    } finally {
      dek.fillRange(0, dek.length, 0);
    }
  }

  static SboxException _invalidSequence() =>
      const SboxException(SboxErrorCode.invalidRecord, 'SBOX 记录顺序或长度无效');
}
