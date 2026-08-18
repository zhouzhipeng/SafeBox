import 'dart:typed_data';

import '../bytes.dart';
import '../constants.dart';
import '../errors.dart';
import 'baseline_jpeg_inspector.dart';
import 'bundle_manifest.dart';
import 'bundle_preview.dart';
import 'manifest_block.dart';

/// The fixed-size encrypted Metadata Block codecs.
abstract final class MetadataBlockCodec {
  static final Uint8List magic = asciiBytes('SBOXMETA');
  static final Uint8List previewMagic = asciiBytes('SBOXPRVW');

  static Uint8List packV1(List<int> manifestBytes) {
    _validateManifestBytes(manifestBytes);
    return ManifestBlock.pack(manifestBytes);
  }

  static Uint8List packV2(
    List<int> manifestBytes, {
    BundlePreview? preview,
  }) {
    _validateManifestBytes(manifestBytes);
    final block = Uint8List(SboxProtocol.metadataBlockLength);
    block.setRange(0, magic.length, magic);
    writeUint32BigEndian(block, 8, manifestBytes.length);
    block.setRange(12, 12 + manifestBytes.length, manifestBytes);
    if (preview == null) return block;

    validatePreview(preview);
    final previewBytes = preview.encodedBytes;
    try {
      final previewOffset = 12 + manifestBytes.length;
      final previewEnd = previewOffset +
          SboxProtocol.previewDescriptorLength +
          previewBytes.length;
      if (previewEnd < previewOffset ||
          previewEnd > SboxProtocol.metadataBlockLength) {
        throw const SboxException(
          SboxErrorCode.invalidManifest,
          'Preview 超出 Metadata 容量',
        );
      }
      block.setRange(previewOffset, previewOffset + 8, previewMagic);
      writeUint16BigEndian(
        block,
        previewOffset + 8,
        SboxProtocol.previewRecordVersion,
      );
      writeUint16BigEndian(
        block,
        previewOffset + 10,
        preview.codec.wireId,
      );
      writeUint16BigEndian(block, previewOffset + 12, 0);
      writeUint16BigEndian(block, previewOffset + 14, preview.width);
      writeUint16BigEndian(block, previewOffset + 16, preview.height);
      writeUint16BigEndian(block, previewOffset + 18, 0);
      writeUint32BigEndian(block, previewOffset + 20, previewBytes.length);
      block.setRange(
        previewOffset + SboxProtocol.previewDescriptorLength,
        previewEnd,
        previewBytes,
      );
    } finally {
      previewBytes.fillRange(0, previewBytes.length, 0);
    }
    return block;
  }

  static Uint8List pack(
    List<int> manifestBytes, {
    required int formatId,
    BundlePreview? preview,
  }) {
    return switch (formatId) {
      SboxProtocol.metadataFormatIdV30 => packV1(manifestBytes),
      SboxProtocol.metadataFormatIdV31 =>
        packV2(manifestBytes, preview: preview),
      _ => throw const SboxException(
        SboxErrorCode.invalidHeader,
        'Metadata 格式不受支持',
      ),
    };
  }

  static BundleMetadata unpackV2(List<int> block) {
    if (block.length != SboxProtocol.metadataBlockLength ||
        !constantTimeBytesEqual(block.sublist(0, magic.length), magic)) {
      throw _invalidBlock();
    }
    final manifestLength = readUint32BigEndian(block, 8);
    if (manifestLength < 1 ||
        manifestLength > SboxProtocol.maxManifestBytes) {
      throw _invalidBlock();
    }
    final manifestEnd = 12 + manifestLength;
    if (manifestEnd < 12 || manifestEnd > block.length) throw _invalidBlock();
    final manifestBytes = block.sublist(12, manifestEnd);
    final manifest = _parseManifest(manifestBytes);
    final tail = block.sublist(manifestEnd);
    if (tail.every((value) => value == 0)) {
      return BundleMetadata(manifest: manifest);
    }
    if (tail.length < SboxProtocol.previewDescriptorLength ||
        !constantTimeBytesEqual(
          tail.sublist(0, previewMagic.length),
          previewMagic,
        )) {
      throw _invalidBlock();
    }
    final previewOffset = manifestEnd;
    final version = readUint16BigEndian(block, previewOffset + 8);
    final codecId = readUint16BigEndian(block, previewOffset + 10);
    final flags = readUint16BigEndian(block, previewOffset + 12);
    final width = readUint16BigEndian(block, previewOffset + 14);
    final height = readUint16BigEndian(block, previewOffset + 16);
    final reserved = readUint16BigEndian(block, previewOffset + 18);
    final dataLength = readUint32BigEndian(block, previewOffset + 20);
    if (version != SboxProtocol.previewRecordVersion ||
        codecId != SboxProtocol.previewCodecBaselineJpeg ||
        flags != 0 ||
        reserved != 0 ||
        width < 1 ||
        width > SboxProtocol.maxPreviewDimension ||
        height < 1 ||
        height > SboxProtocol.maxPreviewDimension ||
        width > SboxProtocol.maxPreviewPixels ~/ height ||
        dataLength < 1 ||
        dataLength > SboxProtocol.maxPreviewBytes) {
      throw _invalidBlock();
    }
    final dataStart = previewOffset + SboxProtocol.previewDescriptorLength;
    final previewEnd = dataStart + dataLength;
    if (dataStart < previewOffset ||
        previewEnd < dataStart ||
        previewEnd > block.length ||
        block.sublist(previewEnd).any((value) => value != 0)) {
      throw _invalidBlock();
    }
    final bytes = Uint8List.fromList(block.sublist(dataStart, previewEnd));
    try {
      BaselineJpegInspector.validate(bytes, width: width, height: height);
      return BundleMetadata(
        manifest: manifest,
        preview: BundlePreview(
          codec: BundlePreviewCodec.baselineJpeg,
          width: width,
          height: height,
          encodedBytes: bytes,
        ),
      );
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  static BundleMetadata unpackV1(List<int> block) {
    final manifest = BundleManifest.parse(ManifestBlock.unpack(block));
    return BundleMetadata(manifest: manifest);
  }

  static BundleMetadata unpack(List<int> block, {required int formatId}) {
    return switch (formatId) {
      SboxProtocol.metadataFormatIdV30 => unpackV1(block),
      SboxProtocol.metadataFormatIdV31 => unpackV2(block),
      _ => throw const SboxException(
        SboxErrorCode.invalidHeader,
        'Metadata 格式不受支持',
      ),
    };
  }

  static int previewCapacity(int manifestLength) {
    if (manifestLength < 1 || manifestLength > SboxProtocol.maxManifestBytes) {
      throw const SboxException(
        SboxErrorCode.invalidManifest,
        'Manifest 长度无效',
      );
    }
    final remaining = SboxProtocol.metadataBlockLength -
        12 -
        SboxProtocol.previewDescriptorLength -
        manifestLength;
    return remaining < SboxProtocol.maxPreviewBytes
        ? remaining
        : SboxProtocol.maxPreviewBytes;
  }

  static BundleManifest _parseManifest(List<int> bytes) {
    try {
      final manifest = BundleManifest.parse(bytes);
      final canonical = manifest.encode();
      if (!constantTimeBytesEqual(canonical, bytes)) throw _invalidBlock();
      return manifest;
    } on SboxException {
      rethrow;
    } on Object {
      throw _invalidBlock();
    }
  }

  static void _validateManifestBytes(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > SboxProtocol.maxManifestBytes) {
      throw _invalidBlock();
    }
    _parseManifest(bytes);
  }

  static void validatePreview(BundlePreview preview) {
    if (preview.codec != BundlePreviewCodec.baselineJpeg ||
        preview.width < 1 ||
        preview.width > SboxProtocol.maxPreviewDimension ||
        preview.height < 1 ||
        preview.height > SboxProtocol.maxPreviewDimension ||
        preview.width > SboxProtocol.maxPreviewPixels ~/ preview.height ||
        preview.encodedLength < 1 ||
        preview.encodedLength > SboxProtocol.maxPreviewBytes) {
      throw _invalidBlock();
    }
    final bytes = preview.encodedBytes;
    try {
      BaselineJpegInspector.validate(
        bytes,
        width: preview.width,
        height: preview.height,
      );
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  static SboxException _invalidBlock() => const SboxException(
    SboxErrorCode.invalidManifest,
    'Metadata Manifest 块无效',
  );
}
