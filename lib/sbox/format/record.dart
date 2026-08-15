import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import '../bytes.dart';
import '../constants.dart';
import '../errors.dart';

final class SboxEncryptedRecord {
  SboxEncryptedRecord({
    required this.type,
    required this.index,
    required List<int> recordHeader,
    required List<int> ciphertext,
    required List<int> tag,
    required this.nextOffset,
  }) : recordHeader = Uint8List.fromList(recordHeader),
       ciphertext = Uint8List.fromList(ciphertext),
       tag = Uint8List.fromList(tag);

  final SboxRecordType type;
  final BigInt index;
  final Uint8List recordHeader;
  final Uint8List ciphertext;
  final Uint8List tag;
  final int nextOffset;

  int get plaintextLength => ciphertext.length;
}

final class SboxRecordCodec {
  SboxRecordCodec() : _aesGcm = DartAesGcm.with256bits(nonceLength: 12);

  final DartAesGcm _aesGcm;

  Future<Uint8List> encrypt({
    required SboxRecordType type,
    required BigInt index,
    required List<int> plaintext,
    required List<int> dek,
    required List<int> noncePrefix,
    required List<int> headerHash,
  }) async {
    _validateCommon(dek, noncePrefix, headerHash, index);
    final recordHeader = _buildRecordHeader(type, index, plaintext.length);
    final nonce = _nonce(noncePrefix, index);
    final aad = _aad(headerHash, recordHeader);
    final box = await _aesGcm.encrypt(
      plaintext,
      secretKey: SecretKey(dek),
      nonce: nonce,
      aad: aad,
    );
    return concatBytes(<List<int>>[
      recordHeader,
      box.cipherText,
      box.mac.bytes,
    ]);
  }

  Future<Uint8List> decrypt({
    required SboxEncryptedRecord record,
    required List<int> dek,
    required List<int> noncePrefix,
    required List<int> headerHash,
  }) async {
    _validateCommon(dek, noncePrefix, headerHash, record.index);
    final nonce = _nonce(noncePrefix, record.index);
    final aad = _aad(headerHash, record.recordHeader);
    try {
      final plaintext = await _aesGcm.decrypt(
        SecretBox(record.ciphertext, nonce: nonce, mac: Mac(record.tag)),
        secretKey: SecretKey(dek),
        aad: aad,
      );
      return Uint8List.fromList(plaintext);
    } catch (_) {
      throw const SboxException(SboxErrorCode.authentication, 'SBOX 记录认证失败');
    }
  }

  SboxEncryptedRecord parseAt(
    List<int> container,
    int offset, {
    required int maximumPlaintextLength,
  }) {
    if (offset < 0 ||
        offset > container.length ||
        container.length - offset < SboxV1.recordHeaderLength) {
      throw const SboxException(SboxErrorCode.truncated, 'SBOX 记录头不完整');
    }
    final recordHeader = Uint8List.fromList(
      container.sublist(offset, offset + SboxV1.recordHeaderLength),
    );
    late final SboxRecordType type;
    try {
      type = SboxRecordType.fromWireValue(recordHeader[0]);
    } on ArgumentError {
      throw const SboxException(SboxErrorCode.invalidRecord, 'SBOX 记录类型无效');
    }
    final index = readUint64BigEndian(recordHeader, 1);
    final plaintextLength = readUint32BigEndian(recordHeader, 9);
    if (plaintextLength > maximumPlaintextLength) {
      throw const SboxException(SboxErrorCode.limits, 'SBOX 记录超过安全上限');
    }
    final nextOffset =
        offset +
        SboxV1.recordHeaderLength +
        plaintextLength +
        SboxV1.gcmTagLength;
    if (nextOffset > container.length) {
      throw const SboxException(SboxErrorCode.truncated, 'SBOX 记录内容不完整');
    }
    final ciphertextStart = offset + SboxV1.recordHeaderLength;
    final tagStart = ciphertextStart + plaintextLength;
    return SboxEncryptedRecord(
      type: type,
      index: index,
      recordHeader: recordHeader,
      ciphertext: container.sublist(ciphertextStart, tagStart),
      tag: container.sublist(tagStart, nextOffset),
      nextOffset: nextOffset,
    );
  }

  static Uint8List _buildRecordHeader(
    SboxRecordType type,
    BigInt index,
    int plaintextLength,
  ) {
    if (index.isNegative || index.bitLength > 64 || plaintextLength < 0) {
      throw ArgumentError('Invalid SBOX record dimensions');
    }
    final bytes = Uint8List(SboxV1.recordHeaderLength);
    bytes[0] = type.wireValue;
    writeUint64BigEndian(bytes, 1, index);
    writeUint32BigEndian(bytes, 9, plaintextLength);
    return bytes;
  }

  static Uint8List _nonce(List<int> prefix, BigInt index) =>
      concatBytes(<List<int>>[prefix, bigIntToFixedBytes(index, 8)]);

  static Uint8List _aad(List<int> headerHash, List<int> recordHeader) =>
      concatBytes(<List<int>>[
        asciiBytes(SboxV1.recordAadPrefix),
        headerHash,
        recordHeader,
      ]);

  static void _validateCommon(
    List<int> dek,
    List<int> noncePrefix,
    List<int> headerHash,
    BigInt index,
  ) {
    if (dek.length != SboxV1.dekLength ||
        noncePrefix.length != SboxV1.noncePrefixLength ||
        headerHash.length != 32 ||
        index.isNegative ||
        index.bitLength > 64) {
      throw ArgumentError('Invalid SBOX record cryptographic parameters');
    }
  }
}
