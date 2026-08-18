import 'dart:typed_data';

import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/engine/bundle_decryptor.dart';
import 'package:safebox/sbox/engine/bundle_encryptor.dart';
import 'package:safebox/sbox/engine/bundle_probe.dart';
import 'package:safebox/sbox/format/bundle_record.dart';
import 'package:safebox/sbox/identity/bip39_identity.dart';
import 'package:test/test.dart';

void main() {
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon about';
  test('v3 empty, single and multipart Bundles round-trip', () async {
    final identity = await SboxIdentityDeriver().deriveIdentity(mnemonic);
    try {
      for (final bytes in <List<int>>[
        const <int>[],
        const <int>[1, 2, 3],
        Uint8List(1024 * 1024 + 1),
      ]) {
        final encrypted = await BundleEncryptor().encryptBytes(
          plaintext: bytes,
          options: BundleEncryptionOptions(
            recipient: identity.publicIdentity,
            contentKind: SboxContentKind.file,
            originalName: 'sample.bin',
            mediaType: 'application/octet-stream',
            description: '上传时填写的附加信息\n支持多行内容',
            createdAt: '2026-08-18T02:30:00Z',
            targetNominalShardPlaintextSize: bytes.length > 3
                ? 1024 * 1024
                : SboxProtocol.defaultNominalShardPlaintextSize,
          ),
        );
        expect(encrypted.root.header.headerLength, 16992);
        expect(encrypted.root.bytes.length, greaterThanOrEqualTo(17069));
        final fast = await BundleProbe.readManifest(
          basename: encrypted.root.basename,
          objectPrefix: encrypted.root.bytes.sublist(0, 16992),
          identity: identity.publicIdentity,
        );
        expect(fast.status, BundleTrustStatus.metadataReadable);
        final rootAuthenticated = await BundleDecryptor()
            .authenticateRootObject(
              basename: encrypted.root.basename,
              rootBytes: encrypted.root.bytes,
              mnemonic: mnemonic,
              expectedIdentity: identity.publicIdentity,
            );
        expect(rootAuthenticated.status, BundleTrustStatus.rootAuthenticated);
        final first = BundleRecordCodec().parseAt(
          encrypted.root.bytes,
          16992,
          maximumPlaintextLength: SboxProtocol.chunkSize,
        );
        expect(
          first.type,
          bytes.isEmpty ? BundleRecordType.finalRecord : BundleRecordType.data,
        );
        final decrypted = await BundleDecryptor().decryptBytes(
          shardBytes: encrypted.objects.map((object) => object.bytes).toList(),
          mnemonic: mnemonic,
          expectedIdentity: identity.publicIdentity,
        );
        expect(decrypted.plaintext, bytes);
        expect(decrypted.manifest.description, '上传时填写的附加信息\n支持多行内容');
        expect(decrypted.status, BundleTrustStatus.complete);
        decrypted.plaintext.fillRange(0, decrypted.plaintext.length, 0);
      }
    } finally {
      identity.disposeControlledSecrets();
    }
  });
}
