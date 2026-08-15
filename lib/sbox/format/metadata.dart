import 'dart:convert';
import 'dart:typed_data';

import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../bytes.dart';
import '../constants.dart';
import '../errors.dart';

final class MultipartMetadata {
  MultipartMetadata({
    required List<int> multipartId,
    required this.partIndex,
    required this.partCount,
    required this.plaintextOffset,
    required this.logicalPlaintextSize,
  }) : multipartId = Uint8List.fromList(multipartId) {
    if (this.multipartId.length != 16 ||
        partCount < 2 ||
        partCount > 10000 ||
        partIndex < 0 ||
        partIndex >= partCount ||
        plaintextOffset.isNegative ||
        logicalPlaintextSize <= BigInt.zero) {
      throw _invalidMetadata();
    }
  }

  final Uint8List multipartId;
  final int partIndex;
  final int partCount;
  final BigInt plaintextOffset;
  final BigInt logicalPlaintextSize;
}

final class SboxMetadata {
  SboxMetadata({
    required this.contentKind,
    required this.originalSize,
    required String originalName,
    required this.mediaType,
    this.multipart,
  }) : originalName = unorm.nfc(originalName) {
    _validate();
  }

  final SboxContentKind contentKind;
  final BigInt originalSize;
  final String originalName;
  final String mediaType;
  final MultipartMetadata? multipart;

  Uint8List encode() {
    _validate();
    final nameBytes = utf8Bytes(originalName);
    final mediaTypeBytes = utf8Bytes(mediaType);
    final extensionLength = multipart == null ? 0 : 40;
    final bytes = Uint8List(
      16 + nameBytes.length + mediaTypeBytes.length + extensionLength,
    );
    bytes[0] = 1;
    bytes[1] = contentKind.wireValue;
    bytes[2] = 0;
    bytes[3] = 0;
    writeUint64BigEndian(bytes, 4, originalSize);
    writeUint16BigEndian(bytes, 12, nameBytes.length);
    writeUint16BigEndian(bytes, 14, mediaTypeBytes.length);
    var offset = 16;
    bytes.setRange(offset, offset + nameBytes.length, nameBytes);
    offset += nameBytes.length;
    bytes.setRange(offset, offset + mediaTypeBytes.length, mediaTypeBytes);
    offset += mediaTypeBytes.length;
    final part = multipart;
    if (part != null) {
      bytes.setRange(offset, offset + 16, part.multipartId);
      writeUint32BigEndian(bytes, offset + 16, part.partIndex);
      writeUint32BigEndian(bytes, offset + 20, part.partCount);
      writeUint64BigEndian(bytes, offset + 24, part.plaintextOffset);
      writeUint64BigEndian(bytes, offset + 32, part.logicalPlaintextSize);
    }
    if (bytes.length > 4096) {
      throw _invalidMetadata();
    }
    return bytes;
  }

  static SboxMetadata parse(List<int> input) {
    if (input.length < 16 || input.length > 4096) {
      throw _invalidMetadata();
    }
    if (input[0] != 1 || input[2] != 0 || input[3] != 0) {
      throw _invalidMetadata();
    }
    late final SboxContentKind contentKind;
    try {
      contentKind = SboxContentKind.fromWireValue(input[1]);
    } on ArgumentError {
      throw _invalidMetadata();
    }
    final originalSize = readUint64BigEndian(input, 4);
    final nameLength = readUint16BigEndian(input, 12);
    final mediaTypeLength = readUint16BigEndian(input, 14);
    if (nameLength == 0 || nameLength > 1024 || mediaTypeLength > 255) {
      throw _invalidMetadata();
    }
    final baseEnd = 16 + nameLength + mediaTypeLength;
    final expectedLength =
        baseEnd + (contentKind == SboxContentKind.multipartPart ? 40 : 0);
    if (input.length != expectedLength) {
      throw _invalidMetadata();
    }

    late final String originalName;
    late final String mediaType;
    try {
      originalName = utf8.decode(
        input.sublist(16, 16 + nameLength),
        allowMalformed: false,
      );
      mediaType = utf8.decode(
        input.sublist(16 + nameLength, baseEnd),
        allowMalformed: false,
      );
    } on FormatException {
      throw _invalidMetadata();
    }
    if (unorm.nfc(originalName) != originalName) {
      throw _invalidMetadata();
    }

    MultipartMetadata? multipart;
    if (contentKind == SboxContentKind.multipartPart) {
      multipart = MultipartMetadata(
        multipartId: input.sublist(baseEnd, baseEnd + 16),
        partIndex: readUint32BigEndian(input, baseEnd + 16),
        partCount: readUint32BigEndian(input, baseEnd + 20),
        plaintextOffset: readUint64BigEndian(input, baseEnd + 24),
        logicalPlaintextSize: readUint64BigEndian(input, baseEnd + 32),
      );
    }
    return SboxMetadata(
      contentKind: contentKind,
      originalSize: originalSize,
      originalName: originalName,
      mediaType: mediaType,
      multipart: multipart,
    );
  }

  void _validate() {
    final nameBytes = utf8Bytes(originalName);
    final mediaTypeBytes = utf8Bytes(mediaType);
    if (originalSize.isNegative ||
        originalSize.bitLength > 64 ||
        originalName.isEmpty ||
        nameBytes.length > 1024 ||
        mediaTypeBytes.length > 255 ||
        originalName.contains('\u0000') ||
        originalName.contains('/') ||
        originalName.contains('\\') ||
        originalName == '.' ||
        originalName == '..') {
      throw _invalidMetadata();
    }
    if (contentKind == SboxContentKind.catalog &&
        (originalName != 'catalog.json' ||
            mediaType != 'application/vnd.sbox.catalog+json')) {
      throw _invalidMetadata();
    }
    if (contentKind == SboxContentKind.multipartPart) {
      final part = multipart;
      if (part == null ||
          originalSize <= BigInt.zero ||
          part.plaintextOffset + originalSize > part.logicalPlaintextSize ||
          (part.partIndex == 0 && part.plaintextOffset != BigInt.zero)) {
        throw _invalidMetadata();
      }
    } else if (multipart != null) {
      throw _invalidMetadata();
    }
    if (16 +
            nameBytes.length +
            mediaTypeBytes.length +
            (multipart == null ? 0 : 40) >
        4096) {
      throw _invalidMetadata();
    }
  }

  static SboxException _invalidMetadata() =>
      const SboxException(SboxErrorCode.invalidRecord, 'SBOX 加密元数据无效');
}

final class SboxFinalRecord {
  SboxFinalRecord({
    required this.totalDataLength,
    required this.dataRecordCount,
    required List<int> dataSha256,
  }) : dataSha256 = Uint8List.fromList(dataSha256) {
    if (totalDataLength.isNegative ||
        totalDataLength.bitLength > 64 ||
        dataRecordCount.isNegative ||
        dataRecordCount.bitLength > 64 ||
        this.dataSha256.length != 32) {
      throw _invalidMetadata();
    }
  }

  final BigInt totalDataLength;
  final BigInt dataRecordCount;
  final Uint8List dataSha256;

  Uint8List encode() {
    final bytes = Uint8List(48);
    writeUint64BigEndian(bytes, 0, totalDataLength);
    writeUint64BigEndian(bytes, 8, dataRecordCount);
    bytes.setRange(16, 48, dataSha256);
    return bytes;
  }

  static SboxFinalRecord parse(List<int> input) {
    if (input.length != 48) {
      throw _invalidMetadata();
    }
    return SboxFinalRecord(
      totalDataLength: readUint64BigEndian(input, 0),
      dataRecordCount: readUint64BigEndian(input, 8),
      dataSha256: input.sublist(16, 48),
    );
  }
}

SboxException _invalidMetadata() =>
    const SboxException(SboxErrorCode.invalidRecord, 'SBOX 认证记录内容无效');
