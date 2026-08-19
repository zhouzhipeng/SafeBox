import 'dart:typed_data';

import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/engine/bundle_probe.dart';
import 'package:safebox/sbox/errors.dart';
import 'package:safebox/sbox/format/bundle_header.dart';
import 'package:safebox/sbox/format/bundle_manifest.dart';
import 'package:safebox/sbox/format/bundle_preview.dart';
import 'package:safebox/sbox/identity/rsa_models.dart';
import 'package:safebox/sbox/source/bundle_listing.dart';
import 'package:safebox/sbox/source/data_source.dart';
import 'package:safebox/sbox/source/source_path.dart';
import 'package:safebox/sbox/storage/local_bundle_index.dart';
import 'package:test/test.dart';

void main() {
  test('one unreadable candidate does not hide readable roots', () async {
    final readableHeader = _rootHeader(1);
    final unreadableHeader = _rootHeader(2);
    final readablePath = SourcePath(readableHeader.canonicalBasename);
    final unreadablePath = SourcePath(unreadableHeader.canonicalBasename);
    final source = _CandidateFailureSource(
      objects: <SourceObjectInfo>[
        SourceObjectInfo(
          path: readablePath,
          length: readableHeader.headerLength,
          revision: RevisionToken(<int>[1]),
        ),
        SourceObjectInfo(
          path: unreadablePath,
          length: unreadableHeader.headerLength,
          revision: RevisionToken(<int>[2]),
        ),
      ],
      headers: <String, Uint8List>{
        readablePath.value: readableHeader.encode(),
        unreadablePath.value: unreadableHeader.encode(),
      },
      unreadablePath: unreadablePath,
    );

    final emitted = <ListedBundleRoot>[];
    final roots = await BundleListing.listRoots(
      source,
      identity: null,
      onRoot: emitted.add,
    );

    expect(roots, hasLength(1));
    expect(roots.single.path, readablePath);
    expect(emitted, hasLength(1));
    expect(emitted.single.path, readablePath);
  });

  test('reuses a matching metadata cache without an identity', () async {
    final header = _rootHeader(3);
    final path = SourcePath(header.canonicalBasename);
    final revision = RevisionToken(<int>[7, 8]);
    final manifest = BundleManifest(
      bundleId: hexLower(header.bundleId),
      recipientKeyId: hexLower(header.recipientKeyId),
      contentKind: SboxContentKind.file,
      originalName: 'cached.bin',
      mediaType: 'application/octet-stream',
      title: 'cached.bin',
      description: 'from cache',
      tags: const <String>[],
      createdAt: '2026-08-17T00:00:00Z',
      logicalPlaintextSize: BigInt.zero,
      logicalPlaintextSha256: List<int>.filled(32, 0),
      nominalShardPlaintextSize: 16 * 1024 * 1024,
      shardCount: 1,
    );
    final source = _CandidateFailureSource(
      objects: <SourceObjectInfo>[
        SourceObjectInfo(
          path: path,
          length: header.headerLength,
          revision: revision,
        ),
      ],
      headers: <String, Uint8List>{path.value: header.encode()},
      unreadablePath: SourcePath('ffffffffffffffffffffffffffffffff.sbox'),
    );
    final roots = await BundleListing.listRoots(
      source,
      identity: null,
      metadataCache: LocalBundleIndex(
        sourceId: '0123456789abcdef0123456789abcdef',
        entries: <LocalBundleIndexEntry>[
          LocalBundleIndexEntry(
            bundleId: manifest.bundleId,
            rootBasename: path.value,
            rootRevisionFingerprint: hexLower(revision.bytes),
            manifestPrefixSha256: hexLower(header.hash),
            verification: BundleVerification.manifest,
            manifest: manifest,
            rootHeaderHex: hexLower(header.rawBytes),
          ),
        ],
      ),
    );

    expect(roots, hasLength(1));
    expect(roots.single.manifest?.originalName, 'cached.bin');
    expect(roots.single.status, BundleTrustStatus.metadataReadable);
  });

  test('reuses a cached JPG without recalculating metadata', () async {
    final header = _rootHeader(4);
    final path = SourcePath(header.canonicalBasename);
    final revision = RevisionToken(<int>[9, 10]);
    final manifest = BundleManifest(
      bundleId: hexLower(header.bundleId),
      recipientKeyId: hexLower(header.recipientKeyId),
      contentKind: SboxContentKind.file,
      originalName: 'cached-preview.jpg',
      mediaType: 'image/jpeg',
      title: 'cached-preview.jpg',
      description: '',
      tags: const <String>[],
      createdAt: '2026-08-17T00:00:00Z',
      logicalPlaintextSize: BigInt.zero,
      logicalPlaintextSha256: List<int>.filled(32, 0),
      nominalShardPlaintextSize: 16 * 1024 * 1024,
      shardCount: 1,
    );
    final preview = BundlePreview(
      codec: BundlePreviewCodec.baselineJpeg,
      width: 1,
      height: 1,
      encodedBytes: <int>[0xff, 0xd8, 0xff, 0xd9],
    );
    final source = _CandidateFailureSource(
      objects: <SourceObjectInfo>[
        SourceObjectInfo(
          path: path,
          length: header.headerLength,
          revision: revision,
        ),
      ],
      headers: <String, Uint8List>{path.value: header.encode()},
      unreadablePath: SourcePath('ffffffffffffffffffffffffffffffff.sbox'),
    );
    try {
      // The SPKI is intentionally invalid. A Metadata recalculation would
      // fail while parsing it, so success proves the cached preview path was
      // used after the root revision/hash binding checks.
      final identity = PublicIdentity(
        rsaPublicKey: SboxRsaPublicKey(
          modulus: BigInt.from(3),
          exponent: BigInt.from(3),
        ),
        spkiDer: <int>[0],
        spkiPem: '',
        recipientKeyId: header.recipientKeyId,
      );
      final roots = await BundleListing.listRoots(
        source,
        identity: identity,
        metadataCache: LocalBundleIndex(
          sourceId: '0123456789abcdef0123456789abcdef',
          entries: <LocalBundleIndexEntry>[
            LocalBundleIndexEntry(
              bundleId: manifest.bundleId,
              rootBasename: path.value,
              rootRevisionFingerprint: hexLower(revision.bytes),
              manifestPrefixSha256: hexLower(header.hash),
              verification: BundleVerification.manifest,
              manifest: manifest,
              rootHeaderHex: hexLower(header.rawBytes),
              hasPreview: true,
              preview: preview,
            ),
          ],
        ),
      );

      expect(roots, hasLength(1));
      expect(roots.single.preview?.encodedBytes, preview.encodedBytes);
      roots.single.preview?.dispose();
    } finally {
      preview.dispose();
    }
  });
}

BundleHeader _rootHeader(int seed) => BundleHeader.root(
  bundleId: List<int>.generate(16, (index) => seed + index),
  shardCount: 1,
  shardPlaintextSize: BigInt.zero,
  recipientKeyId: List<int>.filled(32, 0x20 + seed),
  noncePrefix: <int>[1, 2, 3, 4],
  wrappedBundleDek: List<int>.filled(384, 0x44),
  metadataSalt: List<int>.filled(32, 0x10),
  metadataNonce: List<int>.filled(12, 0x20),
  metadataCiphertext: List<int>.filled(16400, 0x30),
  metadataTag: List<int>.filled(16, 0x40),
);

final class _CandidateFailureSource
    implements EnumerableDataSource, RangeReadableDataSource {
  _CandidateFailureSource({
    required this.objects,
    required this.headers,
    required this.unreadablePath,
  });

  final List<SourceObjectInfo> objects;
  final Map<String, Uint8List> headers;
  final SourcePath unreadablePath;

  @override
  SourceCapabilities get capabilities => const SourceCapabilities(
    canRead: true,
    canWrite: false,
    canDelete: false,
    canListObjects: true,
    supportsRangeRead: true,
    maxObjectBytes: null,
    maxParallelTransfers: 2,
  );

  @override
  Future<SourceListPage> listObjects({
    String? cursor,
    int pageSize = 1000,
  }) async => SourceListPage(objects: objects, nextCursor: null);

  @override
  Future<SourceRead> get(SourcePath path, {RevisionToken? ifNoneMatch}) async {
    throw UnimplementedError();
  }

  @override
  Future<SourceRead> getRange(
    SourcePath path, {
    required int start,
    required int endExclusive,
    SourceObjectInfo? objectInfo,
  }) async {
    if (path == unreadablePath) {
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        'candidate is unavailable',
      );
    }
    final bytes = headers[path.value]!;
    return SourceRead(
      body: Stream<List<int>>.value(bytes),
      length: bytes.length,
      revision: RevisionToken(<int>[1]),
    );
  }

  @override
  Future<RevisionToken> putNew(
    SourcePath path,
    Stream<List<int>> body, {
    required int length,
    required Uint8List sha256,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteIfMatch(SourcePath path, RevisionToken expected) async {
    throw UnimplementedError();
  }
}
