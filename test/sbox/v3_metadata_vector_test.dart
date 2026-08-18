import 'dart:convert';
import 'dart:typed_data';

import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/crypto/metadata_cipher.dart';
import 'package:safebox/sbox/crypto/metadata_kdf.dart';
import 'package:safebox/sbox/format/bundle_header.dart';
import 'package:safebox/sbox/format/bundle_manifest.dart';
import 'package:safebox/sbox/format/manifest_block.dart';
import 'package:safebox/sbox/identity/der.dart';
import 'package:test/test.dart';

void main() {
  test('v3 Metadata fixed vector', () async {
    final encodedSpki =
        'MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAuuLMXcnG7m37vzI1006K27P077n8a7rS5BKwP4E60rXTjHedUcDRlg_4O0CQgFCjnaB3VEtKk7VZJX0ucD76N-agPrjGOuV5T0WQ4uw3g9914tSPJol8G9AkXZlYgU8RVCTnkgYNCkuR3TRsaP_5oW80ELOskT52PZ_OEKFusm8eBU0yDLpNkgRKNIqLmxL1saBtGGbY4v-sfcNwNT6XKLX505WqEzA3Ig6XQs6a7wR3KFP9uKettKLBiLlC3WO0WJF9BpRrNNtSo-UE8xA8Y6uYLQYuDlXYf2tzsIv6jh3aC1-UQW9HX1ljRsB7qUrmpf55QfRzUt_cdIBWTf8M7utQHGZhv30mQilNcwwNdnaLH4vdqHjH1bqJQrIhPzAqmbDjarZ-CCc1QpamATcoY9rN9-g1_qDd-DqfYPVm3vdhA2hc5jKQgf99LEP3Lbv6sPc8g6GmzX7n6yffyy0JyCDqAaxNRKokr1ZjDpKZDR4DGeX89UH18-CP857_w0XHAgMBAAE';
    final spki = Uint8List.fromList(base64Url.decode(base64Url.normalize(encodedSpki)));
    parseRsaSubjectPublicKeyInfo(spki);
    final keyId = decodeHex(
      '9549c41744d3b469c512aa2c845677940937fd20685220fb0eb00f15082b04ae',
    );
    final manifest = BundleManifest(
      bundleId: 'a0a1a2a3a4a5a6a7a8a9aaabacadaeaf',
      contentKind: SboxContentKind.file,
      createdAt: '2026-08-18T02:30:00Z',
      description: '',
      logicalPlaintextSha256: decodeHex(
        '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
      ),
      logicalPlaintextSize: BigInt.from(12345),
      mediaType: 'application/pdf',
      nominalShardPlaintextSize: 16777216,
      originalName: '报告.pdf',
      recipientKeyId: hexLower(keyId),
      shardCount: 1,
      tags: const <String>['archive', '报告'],
      title: '年度报告',
    );
    final manifestBytes = manifest.encode();
    expect(manifestBytes.length, 532);
    expect(
      hexLower(sha256Bytes(manifestBytes)),
      'd871d24b5e8d29a657e5fd61451303611e8cdee672c164d02e2cf17d216fc02c',
    );
    final block = ManifestBlock.pack(manifestBytes);
    expect(
      hexLower(sha256Bytes(block)),
      '1b3cad3851adf15a0a884688e932bca2a74d7050406374984e4fdf9ff4148332',
    );
    final root = BundleHeader.root(
      bundleId: decodeHex('a0a1a2a3a4a5a6a7a8a9aaabacadaeaf'),
      shardCount: 1,
      shardPlaintextSize: BigInt.from(12345),
      recipientKeyId: keyId,
      noncePrefix: decodeHex('a0a1a2a3'),
      wrappedBundleDek: List<int>.filled(384, 0x55),
      metadataSalt: decodeHex(
        '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
      ),
      metadataNonce: decodeHex('202122232425262728292a2b'),
      metadataCiphertext: Uint8List(16400),
      metadataTag: Uint8List(16),
    );
    final rootBytes = root.encode();
    final metadataKey = MetadataKdf.derive(
      spkiDer: spki,
      metadataSalt: root.metadataSalt,
      bundleId: root.bundleId,
      recipientKeyId: keyId,
      formatId: 1,
    );
    expect(
      hexLower(metadataKey),
      'a71cf966c2d3fa3d24208547744ae0c954e4520d32875d318baaaeb4cbf640cf',
    );
    final cipher = await MetadataCipher().encrypt(
      key: metadataKey,
      nonce: root.metadataNonce,
      plaintext: block,
      aad: MetadataCipher.buildAad(rootBytes.sublist(0, 576)),
    );
    expect(
      hexLower(sha256Bytes(MetadataCipher.buildAad(rootBytes.sublist(0, 576)))),
      '447d8dafe8682c43ee6a7167c0b3547c4906d85f9ac8de85091b33887e0bab8a',
    );
    expect(
      hexLower(sha256Bytes(cipher.ciphertext)),
      'c3cdebb4884045c47a7090158a71255d3ea13296212b1793e77a58723e89f1d9',
    );
    expect(
      hexLower(cipher.ciphertext.sublist(0, 64)),
      'ef16d9992d5e3691ff65bb706c89a2a25682cb6854cd9916e7a03587906c2d48837fdbf60c6e81ebaea02270853fc18f7a8b0c7fc3663631558acc628873c021',
    );
    expect(
      hexLower(cipher.ciphertext.sublist(cipher.ciphertext.length - 64)),
      'be31263dcec8f4a7778a6f3ccdf95bb9c8aa26a0b33e667dea0544948a223006f00e911bbfe596f5e9b3f29658692453815fd68b1b4601309dfad97125bec34e',
    );
    expect(hexLower(cipher.tag), 'b7db6863c4307b75c0caf65a59c9caa6');
    final finalRoot = BundleHeader.root(
      bundleId: root.bundleId,
      shardCount: root.shardCount,
      shardPlaintextSize: root.shardPlaintextSize,
      recipientKeyId: root.recipientKeyId,
      noncePrefix: root.noncePrefix,
      wrappedBundleDek: root.wrappedBundleDek,
      metadataSalt: root.metadataSalt,
      metadataNonce: root.metadataNonce,
      metadataCiphertext: cipher.ciphertext,
      metadataTag: cipher.tag,
    );
    expect(
      hexLower(sha256Bytes(finalRoot.encode())),
      '83d445f2b9ce12ea7f5938260955019feac1b508a80e0d38fafe69d8992e52d3',
    );
  });
}
