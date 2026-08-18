import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/format/bundle_manifest.dart';
import 'package:safebox/sbox/storage/local_bundle_index.dart';
import 'package:test/test.dart';

void main() {
  test(
    'local Bundle index is rebuildable and remains outside source objects',
    () async {
      final root = await Directory.systemTemp.createTemp('sbox-v2-index-');
      try {
        final bundleId = List<int>.generate(16, (index) => 0xa0 + index);
        final recipientKeyId = List<int>.filled(32, 0x20);
        final manifest = BundleManifest(
          bundleId: hexLower(bundleId),
          recipientKeyId: hexLower(recipientKeyId),
          contentKind: SboxContentKind.file,
          originalName: 'sample.bin',
          mediaType: 'application/octet-stream',
          title: 'sample.bin',
          description: '',
          tags: const <String>[],
          createdAt: '2026-08-17T00:00:00Z',
          logicalPlaintextSize: BigInt.zero,
          logicalPlaintextSha256: List<int>.filled(32, 0),
          nominalShardPlaintextSize: 16 * 1024 * 1024,
          shardCount: 1,
        );
        final index = LocalBundleIndex(
          sourceId: '0123456789abcdef0123456789abcdef',
          entries: <LocalBundleIndexEntry>[
            LocalBundleIndexEntry(
              bundleId: manifest.bundleId,
              rootBasename: '${manifest.bundleId}.sbox',
              rootRevisionFingerprint: 'local-revision',
              manifestPrefixSha256: hexLower(List<int>.filled(32, 0x33)),
              verification: BundleVerification.complete,
              manifest: manifest,
            ),
          ],
        );
        final store = LocalBundleIndexStore(root);
        await store.save(index);
        expect(
          await File(p.join(root.path, '.sbox-sync', 'index-v2.json')).exists(),
          isTrue,
        );
        final loaded = await store.load(expectedSourceId: index.sourceId);
        expect(loaded?.entries.single.manifest.originalName, 'sample.bin');
        expect(
          await store.load(
            expectedSourceId: 'fedcba9876543210fedcba9876543210',
          ),
          isNull,
        );
        expect(index.encode(), isNot(contains('bundle_dek')));
        expect(index.encode(), isNot(contains('mnemonic')));
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
  );
}
