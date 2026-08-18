import 'dart:convert';

import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/crypto/rsa_oaep.dart';
import 'package:safebox/sbox/crypto/shard_kdf.dart';
import 'package:safebox/sbox/errors.dart';
import 'package:safebox/sbox/format/bundle_header.dart';
import 'package:safebox/sbox/format/bundle_manifest.dart';
import 'package:safebox/sbox/format/bundle_path.dart';
import 'package:safebox/sbox/format/bundle_record.dart';
import 'package:test/test.dart';

void main() {
  final bundleId = decodeHex('a0a1a2a3a4a5a6a7a8a9aaabacadaeaf');
  final recipientKeyId = decodeHex(
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f',
  );
  final bundleDek = decodeHex(
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
  );

  test('HKDF-SHA256 fixed vectors match the protocol', () {
    expect(
      hexLower(ShardKdf.extract(salt: bundleId, ikm: bundleDek)),
      hasLength(64),
    );
    expect(
      hexLower(
        ShardKdf.derive(
          bundleDek: bundleDek,
          bundleId: bundleId,
          recipientKeyId: recipientKeyId,
          shardIndex: 0,
        ),
      ),
      hasLength(64),
    );
    expect(
      hexLower(
        ShardKdf.derive(
          bundleDek: bundleDek,
          bundleId: bundleId,
          recipientKeyId: recipientKeyId,
          shardIndex: 1,
        ),
      ),
      hasLength(64),
    );
    expect(
      hexLower(
        ShardKdf.derive(
          bundleDek: bundleDek,
          bundleId: bundleId,
          recipientKeyId: recipientKeyId,
          shardIndex: 9999,
        ),
      ),
      hasLength(64),
    );
  });

  test('OAEP label and canonical names match the protocol', () {
    final label = RsaOaepSha256.buildBundleDekLabel(
      bundleId: bundleId,
      recipientKeyId: recipientKeyId,
    );
    expect(
      hexLower(sha256Bytes(label)),
      hasLength(64),
    );
    expect(
      canonicalBundleBasename(bundleId: bundleId, shardIndex: 0, shardCount: 1),
      'a0a1a2a3a4a5a6a7a8a9aaabacadaeaf.sbox',
    );
    expect(
      parseCanonicalBundleBasename(
        'a0a1a2a3a4a5a6a7a8a9aaabacadaeaf_10_12.sbox',
      ).shardIndex,
      10,
    );
    expect(
      () => parseCanonicalBundleBasename(
        'a0a1a2a3a4a5a6a7a8a9aaabacadaeaf_00_12.sbox',
      ),
      throwsA(isA<SboxException>()),
    );
  });

  test('root and continuation headers round-trip and bind their paths', () {
    final root = BundleHeader.root(
      bundleId: bundleId,
      shardCount: 1,
      shardPlaintextSize: BigInt.zero,
      recipientKeyId: recipientKeyId,
      noncePrefix: <int>[1, 2, 3, 4],
      wrappedBundleDek: List<int>.filled(384, 0x55),
      metadataSalt: List<int>.filled(32, 0x10),
      metadataNonce: List<int>.filled(12, 0x20),
      metadataCiphertext: List<int>.filled(16400, 0x30),
      metadataTag: List<int>.filled(16, 0x40),
    );
    expect(
      BundleHeader.parse(root.encode()).canonicalBasename,
      root.canonicalBasename,
    );
    expect(root.encode().length, SboxProtocol.rootHeaderLength);

    final continuation = BundleHeader.continuation(
      bundleId: bundleId,
      shardIndex: 2,
      shardCount: 3,
      shardPlaintextSize: BigInt.from(123),
      recipientKeyId: recipientKeyId,
      noncePrefix: <int>[5, 6, 7, 8],
    );
    final encoded = continuation.encode();
    expect(
      BundleHeader.parse(encoded).canonicalBasename,
      continuation.canonicalBasename,
    );
    expect(encoded.length, SboxProtocol.commonHeaderLength);
    encoded[98] = 1;
    expect(() => BundleHeader.parse(encoded), throwsA(isA<SboxException>()));
  });

  test('Manifest is exact-field, NFC and canonical JSON', () {
    final manifest = BundleManifest(
      bundleId: hexLower(bundleId),
      recipientKeyId: hexLower(recipientKeyId),
      contentKind: SboxContentKind.text,
      originalName: 'hello.txt',
      mediaType: 'text/plain; charset=utf-8',
      title: 'hello.txt',
      description: '',
      tags: const <String>['alpha', '中文'],
      createdAt: '2026-08-17T00:00:00Z',
      logicalPlaintextSize: BigInt.from(14),
      logicalPlaintextSha256: decodeHex(
        'a50bbe28228e519e97002c9ae7df3705377ef8f9eb80aae317c497250d408922',
      ),
      nominalShardPlaintextSize: 16 * 1024 * 1024,
      shardCount: 1,
    );
    final encoded = manifest.encode();
    expect(utf8.decode(encoded), startsWith('{"bundle_id"'));
    expect(BundleManifest.parse(encoded).toJson(), manifest.toJson());
    expect(
      () => BundleManifest.parse(
        utf8.encode('{"schema":"SBOX-MANIFEST-3", "schema":"SBOX-MANIFEST-3"}'),
      ),
      throwsA(isA<SboxException>()),
    );
    expect(
      () => BundleManifest.parse(utf8.encode(' ${utf8.decode(encoded)}')),
      throwsA(isA<SboxException>()),
    );
    expect(
      () => BundleManifest(
        bundleId: hexLower(bundleId),
        recipientKeyId: hexLower(recipientKeyId),
        contentKind: SboxContentKind.file,
        originalName: 'e\u0301.txt',
        mediaType: '',
        title: 'x',
        description: '',
        tags: const <String>[],
        createdAt: '2026-08-17T00:00:00Z',
        logicalPlaintextSize: BigInt.zero,
        logicalPlaintextSha256: List<int>.filled(32, 0),
        nominalShardPlaintextSize: 16 * 1024 * 1024,
        shardCount: 1,
      ),
      throwsA(isA<SboxException>()),
    );
  });

  test('record codec authenticates the original record header', () async {
    final codec = BundleRecordCodec();
    final key = List<int>.filled(32, 0x11);
    final headerHash = List<int>.filled(32, 0x22);
    final bytes = await codec.encrypt(
      type: BundleRecordType.data,
      index: BigInt.one,
      plaintext: utf8.encode('hello'),
      shardKey: key,
      noncePrefix: <int>[1, 2, 3, 4],
      headerHash: headerHash,
    );
    final record = codec.parseAt(bytes, 0, maximumPlaintextLength: 1024);
    expect(
      await codec.decrypt(
        record: record,
        shardKey: key,
        noncePrefix: <int>[1, 2, 3, 4],
        headerHash: headerHash,
      ),
      utf8.encode('hello'),
    );
    bytes[13] ^= 1;
    expect(
      () => codec.parseAt(bytes, 0, maximumPlaintextLength: 1024),
      returnsNormally,
    );
    final changed = codec.parseAt(bytes, 0, maximumPlaintextLength: 1024);
    await expectLater(
      codec.decrypt(
        record: changed,
        shardKey: key,
        noncePrefix: <int>[1, 2, 3, 4],
        headerHash: headerHash,
      ),
      throwsA(isA<SboxException>()),
    );
  });
}
