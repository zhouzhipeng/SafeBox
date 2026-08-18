import 'dart:typed_data';

import '../bytes.dart';
import '../constants.dart';
import '../errors.dart';

/// Packs and unpacks the single fixed-size v3 Header Manifest block.
abstract final class ManifestBlock {
  static final Uint8List magic = asciiBytes('SBOXMETA');

  static Uint8List pack(List<int> manifestBytes) {
    if (manifestBytes.isEmpty ||
        manifestBytes.length > SboxProtocol.maxManifestBytes) {
      throw const SboxException(SboxErrorCode.invalidManifest, 'Manifest 长度无效');
    }
    final block = Uint8List(SboxProtocol.metadataBlockLength);
    block.setRange(0, magic.length, magic);
    writeUint32BigEndian(block, 8, manifestBytes.length);
    block.setRange(12, 12 + manifestBytes.length, manifestBytes);
    return block;
  }

  static Uint8List unpack(List<int> block) {
    if (block.length != SboxProtocol.metadataBlockLength ||
        !constantTimeBytesEqual(block.sublist(0, magic.length), magic)) {
      throw const SboxException(
        SboxErrorCode.invalidManifest,
        'Metadata Manifest 块无效',
      );
    }
    final length = readUint32BigEndian(block, 8);
    if (length < 1 || length > SboxProtocol.maxManifestBytes) {
      throw const SboxException(
        SboxErrorCode.invalidManifest,
        'Metadata Manifest 长度无效',
      );
    }
    final end = 12 + length;
    if (end > block.length || block.sublist(end).any((value) => value != 0)) {
      throw const SboxException(
        SboxErrorCode.invalidManifest,
        'Metadata Manifest 填充无效',
      );
    }
    return Uint8List.fromList(block.sublist(12, end));
  }
}
