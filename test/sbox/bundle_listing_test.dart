import 'dart:typed_data';

import 'package:safebox/sbox/errors.dart';
import 'package:safebox/sbox/format/bundle_header.dart';
import 'package:safebox/sbox/source/bundle_listing.dart';
import 'package:safebox/sbox/source/data_source.dart';
import 'package:safebox/sbox/source/source_path.dart';
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
