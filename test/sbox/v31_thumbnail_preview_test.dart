import 'dart:convert';
import 'dart:typed_data';

import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/crypto/metadata_cipher.dart';
import 'package:safebox/sbox/crypto/metadata_kdf.dart';
import 'package:safebox/sbox/format/bundle_header.dart';
import 'package:safebox/sbox/format/bundle_manifest.dart';
import 'package:safebox/sbox/format/bundle_preview.dart';
import 'package:safebox/sbox/format/metadata_block.dart';
import 'package:safebox/sbox/format/sbox_version.dart';
import 'package:test/test.dart';

void main() {
  test('v3.1 encrypted preview fixed vector', () async {
    const encodedSpki =
        'MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAuuLMXcnG7m37vzI1006K27P077n8a7rS5BKwP4E60rXTjHedUcDRlg_4O0CQgFCjnaB3VEtKk7VZJX0ucD76N-agPrjGOuV5T0WQ4uw3g9914tSPJol8G9AkXZlYgU8RVCTnkgYNCkuR3TRsaP_5oW80ELOskT52PZ_OEKFusm8eBU0yDLpNkgRKNIqLmxL1saBtGGbY4v-sfcNwNT6XKLX505WqEzA3Ig6XQs6a7wR3KFP9uKettKLBiLlC3WO0WJF9BpRrNNtSo-UE8xA8Y6uYLQYuDlXYf2tzsIv6jh3aC1-UQW9HX1ljRsB7qUrmpf55QfRzUt_cdIBWTf8M7utQHGZhv30mQilNcwwNdnaLH4vdqHjH1bqJQrIhPzAqmbDjarZ-CCc1QpamATcoY9rN9-g1_qDd-DqfYPVm3vdhA2hc5jKQgf99LEP3Lbv6sPc8g6GmzX7n6yffyy0JyCDqAaxNRKokr1ZjDpKZDR4DGeX89UH18-CP857_w0XHAgMBAAE';
    final spki = Uint8List.fromList(
      base64Url.decode(base64Url.normalize(encodedSpki)),
    );
    final keyId = decodeHex(
      '9549c41744d3b469c512aa2c845677940937fd20685220fb0eb00f15082b04ae',
    );
    final manifest = BundleManifest(
      bundleId: 'a0a1a2a3a4a5a6a7a8a9aaabacadaeaf',
      contentKind: SboxContentKind.file,
      createdAt: '2026-08-18T02:30:00Z',
      description: '固定缩略图向量',
      logicalPlaintextSha256: decodeHex(
        '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
      ),
      logicalPlaintextSize: BigInt.from(12345),
      mediaType: 'image/jpeg',
      nominalShardPlaintextSize: 16777216,
      originalName: '预览.jpg',
      recipientKeyId: hexLower(keyId),
      shardCount: 1,
      tags: const <String>['image', '测试'],
      title: '预览向量',
    );
    final manifestBytes = manifest.encode();
    expect(manifestBytes.length, 546);
    expect(
      hexLower(sha256Bytes(manifestBytes)),
      '85cb14f4f0c3382ee287f52e9a5aecfa41d0ad96dc19ddfd18b742f58a485f7f',
    );
    final badJpeg = base64Decode(
      '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8lJCIfIiEmKzcvJik0KSEiMEExNDk7Pj4+JS5ESUM8SDc9Pjv/2wBDAQoLCw4NDhwQEBw7KCIoOzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozv/wAARCAAJABADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDntP8AB/T93+ldRp/g/p+7/StnTu1dTp/aow1eZw5NnGI01P/Z',
    );
    // Keep the fixture compact in this source file while using the frozen
    // 660-byte vector from the specification.
    final jpeg = Uint8List.fromList(<int>[
      ...badJpeg.sublist(0, 158),
      ...badJpeg.sublist(251),
    ]);
    badJpeg.fillRange(0, badJpeg.length, 0);
    final preview = BundlePreview(
      codec: BundlePreviewCodec.baselineJpeg,
      width: 16,
      height: 9,
      encodedBytes: jpeg,
    );
    final block = MetadataBlockCodec.packV2(
      manifestBytes,
      preview: preview,
    );
    expect(
      hexLower(sha256Bytes(block)),
      '5b0373f598149c300112960cb0dd1ac95b3c21af7beaa463df75261f79768204',
    );
    final decoded = MetadataBlockCodec.unpackV2(block);
    expect(decoded.manifest.toJson(), manifest.toJson());
    expect(decoded.preview?.width, 16);
    expect(decoded.preview?.height, 9);
    expect(decoded.preview?.encodedLength, 660);

    final root = BundleHeader.root(
      version: SboxVersion.v31,
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
    final metadataKey = MetadataKdf.derive(
      spkiDer: spki,
      metadataSalt: root.metadataSalt,
      bundleId: root.bundleId,
      recipientKeyId: keyId,
      formatId: 2,
    );
    expect(
      hexLower(metadataKey),
      'd23d95f7e18c515fc3850cfc7b7d326f0562169a7f38382c7de5fbd661f044b8',
    );
    final cipher = await MetadataCipher().encrypt(
      key: metadataKey,
      nonce: root.metadataNonce,
      plaintext: block,
      aad: MetadataCipher.buildAad(root.rawBytes.sublist(0, 576)),
    );
    expect(
      hexLower(sha256Bytes(MetadataCipher.buildAad(root.rawBytes.sublist(0, 576)))),
      '7d3906954dcbab672543c0608860c307e86fce0194ed653ad03bb834dabf4736',
    );
    expect(
      hexLower(sha256Bytes(cipher.ciphertext)),
      '69ec08e599dfc17c19b0881b9e3814a0e07059041455e8db717fcd0d9bcd82c2',
    );
    expect(hexLower(cipher.tag), 'bb0ee4bc1566639d64ef8c7b31811736');
    final finalRoot = BundleHeader.root(
      version: SboxVersion.v31,
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
      '135b04ae5b2199a7fa99fde8b996c39d3cc4d50730a74008bc6db621976177ff',
    );
  });
}
