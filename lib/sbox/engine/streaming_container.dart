import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;

import '../bytes.dart';
import '../constants.dart';
import '../crypto/rsa_oaep.dart';
import '../errors.dart';
import '../format/header.dart';
import '../format/metadata.dart';
import '../format/record.dart';
import '../identity/bip39_identity.dart';
import '../identity/ephemeral_mnemonic.dart';
import '../identity/rsa_models.dart';
import 'container_codec.dart';
import 'job_control.dart';

final class EncryptOptions {
  const EncryptOptions({
    required this.recipient,
    required this.contentKind,
    required this.originalName,
    required this.mediaType,
    this.multipart,
    this.randomness,
  });

  final PublicIdentity recipient;
  final SboxContentKind contentKind;
  final String originalName;
  final String mediaType;
  final MultipartMetadata? multipart;
  final SboxEncryptionRandomness? randomness;
}

final class EncryptedArtifact {
  EncryptedArtifact._({
    required this.header,
    required this.plaintextLength,
    required List<int> plaintextSha256,
    required this.sboxLength,
    required List<int> sboxSha256,
  }) : plaintextSha256 = Uint8List.fromList(plaintextSha256),
       sboxSha256 = Uint8List.fromList(sboxSha256);

  final SboxHeader header;
  final int plaintextLength;
  final Uint8List plaintextSha256;
  final int sboxLength;
  final Uint8List sboxSha256;
}

final class VerifiedPlaintext {
  VerifiedPlaintext._({
    required this.header,
    required this.metadata,
    required this.plaintextLength,
    required List<int> plaintextSha256,
  }) : plaintextSha256 = Uint8List.fromList(plaintextSha256);

  /// Core-only constructor for a logical multipart plaintext after every part
  /// Final record and the Catalog-wide digest have been verified.
  factory VerifiedPlaintext.reassembled({
    required SboxHeader firstPartHeader,
    required SboxMetadata logicalMetadata,
    required int plaintextLength,
    required List<int> plaintextSha256,
  }) {
    if (logicalMetadata.contentKind == SboxContentKind.multipartPart ||
        logicalMetadata.contentKind == SboxContentKind.catalog ||
        logicalMetadata.originalSize != BigInt.from(plaintextLength) ||
        plaintextSha256.length != 32) {
      throw ArgumentError('Invalid verified multipart result');
    }
    return VerifiedPlaintext._(
      header: firstPartHeader,
      metadata: logicalMetadata,
      plaintextLength: plaintextLength,
      plaintextSha256: plaintextSha256,
    );
  }

  final SboxHeader header;
  final SboxMetadata metadata;
  final int plaintextLength;
  final Uint8List plaintextSha256;
}

Future<EncryptedArtifact> encryptContainer({
  required Stream<List<int>> input,
  required int inputLength,
  required IOSink stagedOutput,
  required EncryptOptions options,
  required JobControl control,
}) async {
  if (inputLength < 0 || BigInt.from(inputLength).bitLength > 64) {
    throw const SboxException(SboxErrorCode.limits, '输入长度无效或超过 SBOX v1 上限');
  }
  control.report(
    SboxJobProgress(
      phase: SboxJobPhase.preparing,
      processedBytes: 0,
      totalBytes: inputLength,
    ),
  );

  final randomness = options.randomness ?? SboxEncryptionRandomness.secure();
  final ownsRandomness = options.randomness == null;
  final rsaOaep = RsaOaepSha256();
  final records = SboxRecordCodec();
  final inputReader = _ByteStreamReader(input);
  final plaintextAccumulator = AccumulatorSink<crypto.Digest>();
  final plaintextHashSink = crypto.sha256.startChunkedConversion(
    plaintextAccumulator,
  );
  final sboxAccumulator = AccumulatorSink<crypto.Digest>();
  final sboxHashSink = crypto.sha256.startChunkedConversion(sboxAccumulator);
  var sboxLength = 0;
  var outputClosed = false;

  void writeCiphertext(List<int> bytes) {
    stagedOutput.add(bytes);
    sboxHashSink.add(bytes);
    sboxLength += bytes.length;
  }

  try {
    final label = RsaOaepSha256.buildDekLabel(
      fileId: randomness.fileId,
      recipientKeyId: options.recipient.recipientKeyId,
    );
    final wrappedDek = rsaOaep.encrypt(
      message: randomness.dek,
      publicKey: options.recipient.rsaPublicKey,
      label: label,
      seed: randomness.oaepSeed,
    );
    final header = SboxHeader(
      fileId: randomness.fileId,
      recipientKeyId: options.recipient.recipientKeyId,
      noncePrefix: randomness.noncePrefix,
      wrappedDek: wrappedDek,
    );
    final headerBytes = header.encode();
    final headerHash = sha256Bytes(headerBytes);
    writeCiphertext(headerBytes);

    final metadata = SboxMetadata(
      contentKind: options.contentKind,
      originalSize: BigInt.from(inputLength),
      originalName: options.originalName,
      mediaType: options.mediaType,
      multipart: options.multipart,
    );
    final metadataBytes = metadata.encode();
    writeCiphertext(
      await records.encrypt(
        type: SboxRecordType.metadata,
        index: BigInt.zero,
        plaintext: metadataBytes,
        dek: randomness.dek,
        noncePrefix: randomness.noncePrefix,
        headerHash: headerHash,
      ),
    );
    metadataBytes.fillRange(0, metadataBytes.length, 0);

    var processed = 0;
    var recordIndex = BigInt.zero;
    var dataRecordCount = 0;
    while (processed < inputLength) {
      control.checkCancelled();
      final requested = (inputLength - processed).clamp(0, header.chunkSize);
      final plaintext = await inputReader.readExact(requested);
      plaintextHashSink.add(plaintext);
      recordIndex += BigInt.one;
      final encrypted = await records.encrypt(
        type: SboxRecordType.data,
        index: recordIndex,
        plaintext: plaintext,
        dek: randomness.dek,
        noncePrefix: randomness.noncePrefix,
        headerHash: headerHash,
      );
      plaintext.fillRange(0, plaintext.length, 0);
      writeCiphertext(encrypted);
      processed += requested;
      dataRecordCount++;
      control.report(
        SboxJobProgress(
          phase: SboxJobPhase.encryptingPart,
          processedBytes: processed,
          totalBytes: inputLength,
        ),
      );
    }
    await inputReader.ensureEof();
    plaintextHashSink.close();
    final plaintextSha256 = Uint8List.fromList(
      plaintextAccumulator.events.single.bytes,
    );

    recordIndex += BigInt.one;
    final finalPlaintext = SboxFinalRecord(
      totalDataLength: BigInt.from(inputLength),
      dataRecordCount: BigInt.from(dataRecordCount),
      dataSha256: plaintextSha256,
    ).encode();
    writeCiphertext(
      await records.encrypt(
        type: SboxRecordType.finalRecord,
        index: recordIndex,
        plaintext: finalPlaintext,
        dek: randomness.dek,
        noncePrefix: randomness.noncePrefix,
        headerHash: headerHash,
      ),
    );
    finalPlaintext.fillRange(0, finalPlaintext.length, 0);
    await stagedOutput.flush();
    await stagedOutput.close();
    outputClosed = true;
    sboxHashSink.close();
    final sboxSha256 = Uint8List.fromList(sboxAccumulator.events.single.bytes);
    control.report(
      SboxJobProgress(
        phase: SboxJobPhase.committingLocalCiphertext,
        processedBytes: inputLength,
        totalBytes: inputLength,
      ),
    );
    return EncryptedArtifact._(
      header: header,
      plaintextLength: inputLength,
      plaintextSha256: plaintextSha256,
      sboxLength: sboxLength,
      sboxSha256: sboxSha256,
    );
  } finally {
    if (!outputClosed) {
      await stagedOutput.close();
    }
    await inputReader.cancel();
    if (ownsRandomness) {
      randomness.dispose();
    }
  }
}

Future<VerifiedPlaintext> decryptSingleContainerWithMnemonic({
  required Stream<List<int>> input,
  required IOSink stagedPlaintext,
  required EphemeralMnemonic mnemonic,
  required PublicIdentity expectedIdentity,
  required JobControl control,
}) async {
  final reader = _ByteStreamReader(input);
  final records = SboxRecordCodec();
  final rsaOaep = RsaOaepSha256();
  final plaintextAccumulator = AccumulatorSink<crypto.Digest>();
  final plaintextHashSink = crypto.sha256.startChunkedConversion(
    plaintextAccumulator,
  );
  EphemeralIdentity? ephemeralIdentity;
  Uint8List? dek;
  var outputClosed = false;
  try {
    control.report(
      const SboxJobProgress(phase: SboxJobPhase.preparing, processedBytes: 0),
    );
    final headerBytes = await reader.readExact(SboxV1.headerLength);
    final header = SboxHeader.parse(headerBytes);
    if (!constantTimeBytesEqual(
      header.recipientKeyId,
      expectedIdentity.recipientKeyId,
    )) {
      throw const SboxException(SboxErrorCode.keyMismatch, '此 SBOX 不属于当前身份');
    }

    ephemeralIdentity = await SboxIdentityDeriver().deriveIdentity(
      mnemonic.revealForDerivation(),
    );
    if (!constantTimeBytesEqual(
          ephemeralIdentity.publicIdentity.recipientKeyId,
          expectedIdentity.recipientKeyId,
        ) ||
        !constantTimeBytesEqual(
          ephemeralIdentity.publicIdentity.catalogSignerKeyId,
          expectedIdentity.catalogSignerKeyId,
        )) {
      throw const SboxException(SboxErrorCode.keyMismatch, '助记词与当前身份不匹配');
    }
    final label = RsaOaepSha256.buildDekLabel(
      fileId: header.fileId,
      recipientKeyId: header.recipientKeyId,
    );
    dek = rsaOaep.decrypt(
      ciphertext: header.wrappedDek,
      privateKey: ephemeralIdentity.rsaPrivateKey,
      label: label,
    );
    if (dek.length != SboxV1.dekLength) {
      throw const SboxException(SboxErrorCode.authentication, '密钥解封或密文认证失败');
    }
    // Drop application references to all private-key material immediately
    // after the single OAEP operation. The enclosing worker isolate provides
    // the final heap-lifetime boundary.
    ephemeralIdentity.disposeControlledSecrets();
    ephemeralIdentity = null;
    mnemonic.dispose();

    final headerHash = sha256Bytes(headerBytes);
    var expectedIndex = BigInt.zero;
    final metadataRecord = await _readRecord(
      reader,
      records,
      maximumPlaintextLength: 4096,
    );
    if (metadataRecord.type != SboxRecordType.metadata ||
        metadataRecord.index != expectedIndex) {
      throw _invalidSequence();
    }
    final metadataPlaintext = await records.decrypt(
      record: metadataRecord,
      dek: dek,
      noncePrefix: header.noncePrefix,
      headerHash: headerHash,
    );
    final metadata = SboxMetadata.parse(metadataPlaintext);
    metadataPlaintext.fillRange(0, metadataPlaintext.length, 0);

    var totalDataLength = 0;
    var dataRecordCount = 0;
    var sawShortDataRecord = false;
    while (true) {
      control.checkCancelled();
      expectedIndex += BigInt.one;
      final record = await _readRecord(
        reader,
        records,
        maximumPlaintextLength: header.chunkSize,
      );
      if (record.index != expectedIndex) {
        throw _invalidSequence();
      }
      if (record.type == SboxRecordType.finalRecord) {
        if (record.plaintextLength != 48) {
          throw _invalidSequence();
        }
        final finalPlaintext = await records.decrypt(
          record: record,
          dek: dek,
          noncePrefix: header.noncePrefix,
          headerHash: headerHash,
        );
        final finalRecord = SboxFinalRecord.parse(finalPlaintext);
        finalPlaintext.fillRange(0, finalPlaintext.length, 0);
        await reader.ensureEof();
        plaintextHashSink.close();
        final plaintextSha256 = Uint8List.fromList(
          plaintextAccumulator.events.single.bytes,
        );
        if (finalRecord.totalDataLength != BigInt.from(totalDataLength) ||
            finalRecord.dataRecordCount != BigInt.from(dataRecordCount) ||
            metadata.originalSize != BigInt.from(totalDataLength) ||
            !constantTimeBytesEqual(finalRecord.dataSha256, plaintextSha256)) {
          throw const SboxException(SboxErrorCode.integrity, 'SBOX 最终完整性校验失败');
        }
        await stagedPlaintext.flush();
        await stagedPlaintext.close();
        outputClosed = true;
        control.report(
          SboxJobProgress(
            phase: SboxJobPhase.publishing,
            processedBytes: totalDataLength,
            totalBytes: totalDataLength,
          ),
        );
        return VerifiedPlaintext._(
          header: header,
          metadata: metadata,
          plaintextLength: totalDataLength,
          plaintextSha256: plaintextSha256,
        );
      }
      if (record.type != SboxRecordType.data ||
          record.plaintextLength == 0 ||
          sawShortDataRecord) {
        throw _invalidSequence();
      }
      final plaintext = await records.decrypt(
        record: record,
        dek: dek,
        noncePrefix: header.noncePrefix,
        headerHash: headerHash,
      );
      plaintextHashSink.add(plaintext);
      stagedPlaintext.add(plaintext);
      await stagedPlaintext.flush();
      totalDataLength += plaintext.length;
      dataRecordCount++;
      sawShortDataRecord = plaintext.length < header.chunkSize;
      plaintext.fillRange(0, plaintext.length, 0);
      control.report(
        SboxJobProgress(
          phase: SboxJobPhase.authenticatingParts,
          processedBytes: totalDataLength,
          totalBytes: metadata.originalSize.toInt(),
        ),
      );
    }
  } finally {
    ephemeralIdentity?.disposeControlledSecrets();
    mnemonic.dispose();
    dek?.fillRange(0, dek.length, 0);
    if (!outputClosed) {
      await stagedPlaintext.close();
    }
    await reader.cancel();
  }
}

Future<SboxEncryptedRecord> _readRecord(
  _ByteStreamReader reader,
  SboxRecordCodec codec, {
  required int maximumPlaintextLength,
}) async {
  final header = await reader.readExact(SboxV1.recordHeaderLength);
  final plaintextLength = readUint32BigEndian(header, 9);
  if (plaintextLength > maximumPlaintextLength) {
    throw const SboxException(SboxErrorCode.limits, 'SBOX 记录超过安全上限');
  }
  final body = await reader.readExact(plaintextLength + SboxV1.gcmTagLength);
  final bytes = concatBytes(<List<int>>[header, body]);
  return codec.parseAt(
    bytes,
    0,
    maximumPlaintextLength: maximumPlaintextLength,
  );
}

SboxException _invalidSequence() =>
    const SboxException(SboxErrorCode.invalidRecord, 'SBOX 记录顺序或长度无效');

final class _ByteStreamReader {
  _ByteStreamReader(Stream<List<int>> stream)
    : _iterator = StreamIterator<List<int>>(stream);

  final StreamIterator<List<int>> _iterator;
  Uint8List _current = Uint8List(0);
  int _offset = 0;
  bool _ended = false;

  Future<Uint8List> readExact(int length) async {
    if (length < 0) {
      throw ArgumentError.value(length, 'length');
    }
    final result = Uint8List(length);
    var written = 0;
    while (written < length) {
      if (_offset >= _current.length) {
        if (!await _moveNextNonEmpty()) {
          throw const SboxException(SboxErrorCode.truncated, 'SBOX 或输入流提前结束');
        }
      }
      final available = _current.length - _offset;
      final take = (length - written).clamp(0, available);
      result.setRange(written, written + take, _current, _offset);
      written += take;
      _offset += take;
    }
    return result;
  }

  Future<void> ensureEof() async {
    if (_offset < _current.length) {
      throw const SboxException(SboxErrorCode.trailingData, '输入流包含超出声明长度的数据');
    }
    if (await _moveNextNonEmpty()) {
      throw const SboxException(
        SboxErrorCode.trailingData,
        'SBOX Final 记录后存在尾随数据',
      );
    }
  }

  Future<bool> _moveNextNonEmpty() async {
    if (_ended) {
      return false;
    }
    while (await _iterator.moveNext()) {
      final next = _iterator.current;
      if (next.isEmpty) {
        continue;
      }
      _current = Uint8List.fromList(next);
      _offset = 0;
      return true;
    }
    _ended = true;
    _current = Uint8List(0);
    _offset = 0;
    return false;
  }

  Future<void> cancel() => _iterator.cancel();
}
