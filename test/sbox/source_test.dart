import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/errors.dart';
import 'package:safebox/sbox/format/bundle_header.dart';
import 'package:safebox/sbox/source/bundle_listing.dart';
import 'package:safebox/sbox/source/data_source.dart';
import 'package:safebox/sbox/source/local_directory_source.dart';
import 'package:safebox/sbox/source/source_path.dart';
import 'package:test/test.dart';

void main() {
  test('local source is direct-root, paged and immutable', () async {
    final temporary = await Directory.systemTemp.createTemp('sbox-v2-source-');
    try {
      final source = await LocalDirectoryDataSource.attach(root: temporary);
      final rootHeader = BundleHeader.root(
        bundleId: List<int>.generate(16, (index) => index),
        shardCount: 1,
        shardPlaintextSize: BigInt.zero,
        recipientKeyId: List<int>.filled(32, 0x20),
        noncePrefix: <int>[1, 2, 3, 4],
        wrappedBundleDek: List<int>.filled(384, 0x44),
      );
      final rootPath = SourcePath(rootHeader.canonicalBasename);
      final rootBytes = rootHeader.encode();
      final rootRevision = await source.putNew(
        rootPath,
        Stream<List<int>>.value(rootBytes),
        length: rootBytes.length,
        sha256: sha256Bytes(rootBytes),
      );
      expect(
        await source.putNew(
          rootPath,
          Stream<List<int>>.value(rootBytes),
          length: rootBytes.length,
          sha256: sha256Bytes(rootBytes),
        ),
        predicate<RevisionToken>((revision) => revision.matches(rootRevision)),
      );

      final continuationHeader = BundleHeader.continuation(
        bundleId: rootHeader.bundleId,
        shardIndex: 1,
        shardCount: 2,
        shardPlaintextSize: BigInt.one,
        recipientKeyId: rootHeader.recipientKeyId,
        noncePrefix: <int>[5, 6, 7, 8],
      );
      final continuationBytes = continuationHeader.encode();
      await source.putNew(
        SourcePath(continuationHeader.canonicalBasename),
        Stream<List<int>>.value(continuationBytes),
        length: continuationBytes.length,
        sha256: sha256Bytes(continuationBytes),
      );

      await Directory(p.join(temporary.path, 'nested')).create();
      await File(p.join(temporary.path, 'nested', rootHeader.canonicalBasename))
          .writeAsBytes(rootBytes);

      final firstPage = await source.listObjects(pageSize: 1);
      expect(firstPage.objects, hasLength(1));
      expect(firstPage.nextCursor, '1');
      final secondPage = await source.listObjects(
        cursor: firstPage.nextCursor,
        pageSize: 1,
      );
      expect(secondPage.objects, hasLength(1));
      expect(secondPage.nextCursor, isNull);

      final roots = await BundleListing.listRoots(source);
      expect(roots, hasLength(1));
      expect(roots.single.path, rootPath);

      final prefix = await source.getRange(
        rootPath,
        start: 0,
        endExclusive: 12,
      );
      expect(await prefix.body.toList(), [rootBytes.sublist(0, 12)]);

      final changed = Uint8List.fromList(rootBytes)..[511] ^= 1;
      await expectLater(
        source.putNew(
          rootPath,
          Stream<List<int>>.value(changed),
          length: changed.length,
          sha256: sha256Bytes(changed),
        ),
        throwsA(isA<SboxException>()),
      );
      await source.deleteIfMatch(rootPath, rootRevision);
      expect(
        await File(p.join(temporary.path, rootPath.value)).exists(),
        isFalse,
      );
    } finally {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    }
  });
}
