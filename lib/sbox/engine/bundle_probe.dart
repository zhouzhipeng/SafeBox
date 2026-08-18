import 'dart:typed_data';

import '../bytes.dart';
import '../constants.dart';
import '../crypto/rsa_oaep.dart';
import '../crypto/shard_kdf.dart';
import '../errors.dart';
import '../format/bundle_header.dart';
import '../format/bundle_manifest.dart';
import '../format/bundle_path.dart';
import '../format/bundle_record.dart';
import '../identity/bip39_identity.dart';
import '../identity/rsa_models.dart';

final class BundleProbeResult {
  const BundleProbeResult({
    required this.basename,
    required this.header,
    this.manifest,
  });

  final String basename;
  final BundleHeader header;
  final BundleManifest? manifest;

  bool get manifestAuthenticated => manifest != null;
}

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

  static Future<BundleProbeResult> authenticateManifest({
    required String basename,
    required List<int> objectPrefix,
    required String mnemonic,
  }) async {
    final result = probe(basename: basename, objectPrefix: objectPrefix);
    if (!result.header.isRoot) {
      throw const SboxException(
        SboxErrorCode.rootRequired,
        'Manifest 鍙瓨鍦ㄦ牴鍒嗙墖',
      );
    }
    final records = BundleRecordCodec();
    final record = records.parseAt(
      objectPrefix,
      result.header.headerLength,
      maximumPlaintextLength: SboxProtocol.maxManifestBytes,
    );
    if (record.type != BundleRecordType.manifest ||
        record.index != BigInt.zero ||
        record.nextOffset > objectPrefix.length) {
      throw const SboxException(SboxErrorCode.invalidManifest, 'Manifest 前缀无效');
    }
    EphemeralIdentity? identity;
    Uint8List? bundleDek;
    Uint8List? shardKey;
    try {
      identity = await SboxIdentityDeriver().deriveIdentity(mnemonic);
      if (!constantTimeBytesEqual(
        identity.publicIdentity.recipientKeyId,
        result.header.recipientKeyId,
      )) {
        throw const SboxException(
          SboxErrorCode.keyMismatch,
          '助记词与 Bundle 身份不匹配',
        );
      }
      bundleDek = RsaOaepSha256().decrypt(
        ciphertext: result.header.wrappedBundleDek,
        privateKey: identity.rsaPrivateKey,
        label: RsaOaepSha256.buildBundleDekLabel(
          bundleId: result.header.bundleId,
          recipientKeyId: result.header.recipientKeyId,
        ),
      );
      identity.disposeControlledSecrets();
      identity = null;
      shardKey = ShardKdf.derive(
        bundleDek: bundleDek,
        bundleId: result.header.bundleId,
        recipientKeyId: result.header.recipientKeyId,
        shardIndex: 0,
      );
      final plaintext = await records.decrypt(
        record: record,
        shardKey: shardKey,
        noncePrefix: result.header.noncePrefix,
        headerHash: sha256Bytes(
          objectPrefix.sublist(0, result.header.headerLength),
        ),
      );
      try {
        final manifest = BundleManifest.parse(plaintext);
        manifest.validateAgainstHeader(result.header);
        return BundleProbeResult(
          basename: basename,
          header: result.header,
          manifest: manifest,
        );
      } finally {
        plaintext.fillRange(0, plaintext.length, 0);
      }
    } on SboxException {
      rethrow;
    } catch (_) {
      throw const SboxException(SboxErrorCode.authentication, 'Manifest 鉴证失败');
    } finally {
      identity?.disposeControlledSecrets();
      bundleDek?.fillRange(0, bundleDek.length, 0);
      shardKey?.fillRange(0, shardKey.length, 0);
    }
  }
}
