import 'dart:typed_data';

import '../bytes.dart';
import '../constants.dart';
import '../crypto/metadata_cipher.dart';
import '../crypto/metadata_kdf.dart';
import '../errors.dart';
import '../format/bundle_header.dart';
import '../format/bundle_manifest.dart';
import '../format/bundle_path.dart';
import '../format/bundle_preview.dart';
import '../format/metadata_block.dart';
import '../identity/rsa_models.dart';

enum BundleTrustStatus { headerOnly, metadataReadable, rootAuthenticated, complete }

final class BundleProbeResult {
  const BundleProbeResult({
    required this.basename,
    required this.header,
    this.manifest,
    this.metadata,
    this.status = BundleTrustStatus.headerOnly,
  });

  final String basename;
  final BundleHeader header;
  final BundleManifest? manifest;
  final BundleMetadata? metadata;
  final BundleTrustStatus status;

  BundlePreview? get preview => metadata?.preview;

  bool get manifestAuthenticated =>
      status.index >= BundleTrustStatus.metadataReadable.index;

  bool get metadataReadable =>
      status.index >= BundleTrustStatus.metadataReadable.index;

  BundleTrustStatus get trustStatus => status;
}

/// Public-header and fast-Manifest operations. This module intentionally has
/// no mnemonic, BIP39 or RSA-private-key dependency.
abstract final class BundleProbe {
  static BundleProbeResult probe({
    required String basename,
    required List<int> objectPrefix,
  }) {
    final path = parseCanonicalBundleBasename(basename);
    final header = BundleHeader.parse(Uint8List.fromList(objectPrefix));
    validateBundlePathAgainstHeader(basename, header);
    if (path.shardIndex == 0 && !header.isRoot) {
      throw const SboxException(SboxErrorCode.shardMismatch, '根对象角色无效');
    }
    return BundleProbeResult(basename: basename, header: header);
  }

  /// Reads the only persistent Manifest from a complete root header using a
  /// persisted public identity. No file records, RSA private operation or
  /// mnemonic are required.
  static Future<BundleProbeResult> readMetadata({
    required String basename,
    required List<int> objectPrefix,
    required PublicIdentity identity,
  }) async {
    final result = probe(basename: basename, objectPrefix: objectPrefix);
    if (!result.header.isRoot) {
      throw const SboxException(
        SboxErrorCode.rootRequired,
        'Manifest 仅存在于根分片',
      );
    }
    final identityKeyId = sha256Bytes(identity.spkiDer);
    if (!constantTimeBytesEqual(identityKeyId, identity.recipientKeyId) ||
        !constantTimeBytesEqual(identityKeyId, result.header.recipientKeyId)) {
      identityKeyId.fillRange(0, identityKeyId.length, 0);
      throw const SboxException(SboxErrorCode.keyMismatch, 'RSA 公共身份不匹配');
    }
    identityKeyId.fillRange(0, identityKeyId.length, 0);

    Uint8List? metadataKey;
    Uint8List? block;
    try {
      metadataKey = MetadataKdf.derive(
        spkiDer: identity.spkiDer,
        metadataSalt: result.header.metadataSalt,
        bundleId: result.header.bundleId,
        recipientKeyId: result.header.recipientKeyId,
        formatId: result.header.metadataFormatId,
      );
      block = await MetadataCipher().decrypt(
        key: metadataKey,
        nonce: result.header.metadataNonce,
        ciphertext: result.header.metadataCiphertext,
        tag: result.header.metadataTag,
        aad: MetadataCipher.buildAad(
          result.header.rawBytes.sublist(0, SboxProtocol.metadataAadHeaderLength),
        ),
      );
      final metadata = MetadataBlockCodec.unpack(
        block,
        formatId: result.header.metadataFormatId,
      );
      final manifest = metadata.manifest;
      manifest.validateAgainstHeader(result.header);
      return BundleProbeResult(
        basename: basename,
        header: result.header,
        manifest: manifest,
        metadata: metadata,
        status: BundleTrustStatus.metadataReadable,
      );
    } finally {
      metadataKey?.fillRange(0, metadataKey.length, 0);
      block?.fillRange(0, block.length, 0);
    }
  }

  static Future<BundleProbeResult> readManifest({
    required String basename,
    required List<int> objectPrefix,
    required PublicIdentity identity,
  }) => readMetadata(
    basename: basename,
    objectPrefix: objectPrefix,
    identity: identity,
  );

  static Future<BundleProbeResult> readFastManifest({
    required String basename,
    required List<int> objectPrefix,
    required PublicIdentity identity,
  }) => readMetadata(
    basename: basename,
    objectPrefix: objectPrefix,
    identity: identity,
  );

  static Future<BundleProbeResult> authenticateManifest({
    required String basename,
    required List<int> objectPrefix,
    required PublicIdentity identity,
  }) => readMetadata(
    basename: basename,
    objectPrefix: objectPrefix,
    identity: identity,
  );
}
