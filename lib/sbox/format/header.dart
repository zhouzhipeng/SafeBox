import 'dart:typed_data';

import '../bytes.dart';
import '../constants.dart';
import '../errors.dart';

final class SboxHeader {
  SboxHeader({
    required List<int> fileId,
    required List<int> recipientKeyId,
    required List<int> noncePrefix,
    required List<int> wrappedDek,
    this.chunkSize = SboxV1.internalChunkSize,
  }) : fileId = Uint8List.fromList(fileId),
       recipientKeyId = Uint8List.fromList(recipientKeyId),
       noncePrefix = Uint8List.fromList(noncePrefix),
       wrappedDek = Uint8List.fromList(wrappedDek) {
    _validateFields();
  }

  final int chunkSize;
  final Uint8List fileId;
  final Uint8List recipientKeyId;
  final Uint8List noncePrefix;
  final Uint8List wrappedDek;

  String get canonicalFileName => '${hexLower(fileId)}.sbox';

  Uint8List encode() {
    _validateFields();
    final bytes = Uint8List(SboxV1.headerLength);
    bytes.setRange(0, 8, SboxV1.magic);
    bytes[8] = SboxV1.versionMajor;
    bytes[9] = SboxV1.versionMinor;
    writeUint16BigEndian(bytes, 10, SboxV1.headerLength);
    writeUint32BigEndian(bytes, 12, 0);
    writeUint16BigEndian(bytes, 16, SboxV1.keyProfileId);
    writeUint16BigEndian(bytes, 18, SboxV1.keyWrapAlgorithm);
    writeUint16BigEndian(bytes, 20, SboxV1.payloadAlgorithm);
    writeUint16BigEndian(bytes, 22, 0);
    writeUint32BigEndian(bytes, 24, chunkSize);
    bytes.setRange(28, 44, fileId);
    bytes.setRange(44, 76, recipientKeyId);
    bytes.setRange(76, 80, noncePrefix);
    writeUint16BigEndian(bytes, 80, SboxV1.wrappedDekLength);
    writeUint16BigEndian(bytes, 82, 0);
    bytes.setRange(84, SboxV1.headerLength, wrappedDek);
    return bytes;
  }

  Uint8List get hash => sha256Bytes(encode());

  static SboxHeader parse(List<int> input) {
    if (input.length < SboxV1.headerLength) {
      throw const SboxException(SboxErrorCode.truncated, 'SBOX 固定头部不完整');
    }
    final bytes = Uint8List.fromList(input.sublist(0, SboxV1.headerLength));
    if (!constantTimeBytesEqual(bytes.sublist(0, 8), SboxV1.magic)) {
      throw _invalidHeader();
    }
    if (bytes[8] != SboxV1.versionMajor || bytes[9] != SboxV1.versionMinor) {
      throw const SboxException(
        SboxErrorCode.unsupportedVersion,
        '不支持此 SBOX 协议版本',
      );
    }
    if (readUint16BigEndian(bytes, 10) != SboxV1.headerLength ||
        readUint32BigEndian(bytes, 12) != 0 ||
        readUint16BigEndian(bytes, 16) != SboxV1.keyProfileId ||
        readUint16BigEndian(bytes, 18) != SboxV1.keyWrapAlgorithm ||
        readUint16BigEndian(bytes, 20) != SboxV1.payloadAlgorithm ||
        readUint16BigEndian(bytes, 22) != 0 ||
        readUint16BigEndian(bytes, 80) != SboxV1.wrappedDekLength ||
        readUint16BigEndian(bytes, 82) != 0) {
      throw _invalidHeader();
    }
    final chunkSize = readUint32BigEndian(bytes, 24);
    if (!_isCompatibleChunkSize(chunkSize)) {
      throw _invalidHeader();
    }
    return SboxHeader(
      fileId: bytes.sublist(28, 44),
      recipientKeyId: bytes.sublist(44, 76),
      noncePrefix: bytes.sublist(76, 80),
      wrappedDek: bytes.sublist(84, SboxV1.headerLength),
      chunkSize: chunkSize,
    );
  }

  void _validateFields() {
    if (fileId.length != SboxV1.fileIdLength ||
        recipientKeyId.length != SboxV1.recipientKeyIdLength ||
        noncePrefix.length != SboxV1.noncePrefixLength ||
        wrappedDek.length != SboxV1.wrappedDekLength ||
        !_isCompatibleChunkSize(chunkSize)) {
      throw _invalidHeader();
    }
  }

  static bool _isCompatibleChunkSize(int value) {
    const minimum = 64 * 1024;
    const maximum = 16 * 1024 * 1024;
    return value >= minimum && value <= maximum && value & (value - 1) == 0;
  }

  static SboxException _invalidHeader() =>
      const SboxException(SboxErrorCode.invalidHeader, 'SBOX 固定头部无效');
}
