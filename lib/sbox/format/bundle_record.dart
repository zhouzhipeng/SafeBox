import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import '../bytes.dart';
import '../constants.dart';
import '../errors.dart';

final class BundleEncryptedRecord {
  BundleEncryptedRecord({
    required this.type,
    required this.index,
    required List<int> recordHeader,
    required List<int> ciphertext,
    required List<int> tag,
    required this.nextOffset,
  }) : recordHeader = Uint8List.fromList(recordHeader),
       ciphertext = Uint8List.fromList(ciphertext),
       tag = Uint8List.fromList(tag);

  final BundleRecordType type;
  final BigInt index;
  final Uint8List recordHeader;
  final Uint8List ciphertext;
  final Uint8List tag;
  final int nextOffset;

  int get plaintextLength => ciphertext.length;
}

final class BundleFinalRecord {
  BundleFinalRecord({
    required this.totalDataLength,
    required this.dataRecordCount,
    required List<int> dataSha256,
  }) : dataSha256 = Uint8List.fromList(dataSha256) {
    if (totalDataLength.isNegative ||
        totalDataLength.bitLength > 64 ||
        dataRecordCount.isNegative ||
        dataRecordCount.bitLength > 64 ||
        this.dataSha256.length != 32) {
      throw const SboxException(SboxErrorCode.invalidRecord, 'Final 记录内容无效');
    }
  }

  final BigInt totalDataLength;
  final BigInt dataRecordCount;
  final Uint8List dataSha256;

  Uint8List encode() {
    final bytes = Uint8List(SboxProtocol.finalPlaintextLength);
    writeUint64BigEndian(bytes, 0, totalDataLength);
    writeUint64BigEndian(bytes, 8, dataRecordCount);
    bytes.setRange(16, 48, dataSha256);
    return bytes;
  }

  static BundleFinalRecord parse(List<int> input) {
    if (input.length != SboxProtocol.finalPlaintextLength) {
      throw const SboxException(SboxErrorCode.invalidRecord, 'Final 记录长度无效');
    }
    return BundleFinalRecord(
      totalDataLength: readUint64BigEndian(input, 0),
      dataRecordCount: readUint64BigEndian(input, 8),
      dataSha256: input.sublist(16, 48),
    );
  }
}

/// Encodes and authenticates the v3 Data/Final record format.
final class BundleRecordCodec {
  BundleRecordCodec() : _aesGcm = DartAesGcm.with256bits(nonceLength: 12);

  final DartAesGcm _aesGcm;

  Future<Uint8List> encrypt({
    required BundleRecordType type,
    required BigInt index,
    required List<int> plaintext,
    required List<int> shardKey,
    required List<int> noncePrefix,
    required List<int> headerHash,
  }) async {
    _validateCommon(shardKey, noncePrefix, headerHash, index);
    _validatePlaintextLength(type, plaintext.length);
    final recordHeader = _buildRecordHeader(type, index, plaintext.length);
    final box = await _aesGcm.encrypt(
      plaintext,
      secretKey: SecretKey(shardKey),
      nonce: _nonce(noncePrefix, index),
      aad: _aad(headerHash, recordHeader),
    );
    return concatBytes(<List<int>>[
      recordHeader,
      box.cipherText,
      box.mac.bytes,
    ]);
  }

  Future<Uint8List> decrypt({
    required BundleEncryptedRecord record,
    required List<int> shardKey,
    required List<int> noncePrefix,
    required List<int> headerHash,
  }) async {
    _validateCommon(shardKey, noncePrefix, headerHash, record.index);
    try {
      final plaintext = await _aesGcm.decrypt(
        SecretBox(
          record.ciphertext,
          nonce: _nonce(noncePrefix, record.index),
          mac: Mac(record.tag),
        ),
        secretKey: SecretKey(shardKey),
        aad: _aad(headerHash, record.recordHeader),
      );
      return Uint8List.fromList(plaintext);
    } catch (_) {
      throw const SboxException(SboxErrorCode.authentication, '密钥解封或密文认证失败');
    }
  }

  BundleEncryptedRecord parseAt(
    List<int> container,
    int offset, {
    required int maximumPlaintextLength,
  }) {
    if (maximumPlaintextLength < 0 ||
        offset < 0 ||
        offset > container.length ||
        container.length - offset < SboxProtocol.recordHeaderLength) {
      throw const SboxException(SboxErrorCode.truncated, 'SBOX 记录头不完整');
    }
    final recordHeader = Uint8List.fromList(
      container.sublist(offset, offset + SboxProtocol.recordHeaderLength),
    );
    late final BundleRecordType type;
    try {
      type = BundleRecordType.fromWireValue(recordHeader[0]);
    } on ArgumentError {
      throw const SboxException(SboxErrorCode.invalidRecord, 'SBOX 记录类型无效');
    }
    final index = readUint64BigEndian(recordHeader, 1);
    if (index == BigInt.zero) {
      throw const SboxException(SboxErrorCode.invalidRecord, 'SBOX 记录索引无效');
    }
    final plaintextLength = readUint32BigEndian(recordHeader, 9);
    if (plaintextLength > maximumPlaintextLength ||
        (type == BundleRecordType.data &&
            (plaintextLength < 1 || plaintextLength > SboxProtocol.chunkSize)) ||
        (type == BundleRecordType.finalRecord &&
            plaintextLength != SboxProtocol.finalPlaintextLength)) {
      throw const SboxException(SboxErrorCode.invalidRecord, 'SBOX 记录长度超过上限');
    }
    final remaining = container.length - offset - SboxProtocol.recordHeaderLength;
    if (plaintextLength > remaining - SboxProtocol.gcmTagLength) {
      throw const SboxException(SboxErrorCode.truncated, 'SBOX 记录内容不完整');
    }
    final ciphertextStart = offset + SboxProtocol.recordHeaderLength;
    final tagStart = ciphertextStart + plaintextLength;
    final nextOffset = tagStart + SboxProtocol.gcmTagLength;
    return BundleEncryptedRecord(
      type: type,
      index: index,
      recordHeader: recordHeader,
      ciphertext: container.sublist(ciphertextStart, tagStart),
      tag: container.sublist(tagStart, nextOffset),
      nextOffset: nextOffset,
    );
  }

  static Uint8List _buildRecordHeader(
    BundleRecordType type,
    BigInt index,
    int plaintextLength,
  ) {
    if (index <= BigInt.zero ||
        index.bitLength > 64 ||
        plaintextLength < 0 ||
        plaintextLength > 0xffffffff) {
      throw ArgumentError('Invalid SBOX record dimensions');
    }
    final bytes = Uint8List(SboxProtocol.recordHeaderLength);
    bytes[0] = type.wireValue;
    writeUint64BigEndian(bytes, 1, index);
    writeUint32BigEndian(bytes, 9, plaintextLength);
    return bytes;
  }

  static Uint8List _nonce(List<int> prefix, BigInt index) =>
      concatBytes(<List<int>>[prefix, bigIntToFixedBytes(index, 8)]);

  static Uint8List _aad(List<int> headerHash, List<int> recordHeader) =>
      concatBytes(<List<int>>[
        asciiBytes('SBOX-v3-record'),
        const <int>[0],
        headerHash,
        recordHeader,
      ]);

  static void _validateCommon(
    List<int> shardKey,
    List<int> noncePrefix,
    List<int> headerHash,
    BigInt index,
  ) {
    if (shardKey.length != SboxProtocol.bundleDekLength ||
        noncePrefix.length != SboxProtocol.noncePrefixLength ||
        headerHash.length != 32 ||
        index <= BigInt.zero ||
        index.bitLength > 64) {
      throw ArgumentError('Invalid SBOX record cryptographic parameters');
    }
  }

  static void _validatePlaintextLength(BundleRecordType type, int length) {
    switch (type) {
      case BundleRecordType.data:
        if (length < 1 || length > SboxProtocol.chunkSize) {
          throw const SboxException(SboxErrorCode.invalidRecord, 'Data 记录长度无效');
        }
      case BundleRecordType.finalRecord:
        if (length != SboxProtocol.finalPlaintextLength) {
          throw const SboxException(SboxErrorCode.invalidRecord, 'Final 记录长度无效');
        }
    }
  }
}
