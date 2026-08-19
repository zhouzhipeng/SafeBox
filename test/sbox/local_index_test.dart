import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/format/bundle_manifest.dart';
import 'package:safebox/sbox/format/bundle_preview.dart';
import 'package:safebox/sbox/storage/local_bundle_index.dart';
import 'package:test/test.dart';

void main() {
  test(
    'local Bundle index is rebuildable and remains outside source objects',
    () async {
      final root = await Directory.systemTemp.createTemp('sbox-v3-index-');
      BundlePreview? preview;
      BundlePreview? loadedPreview;
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
        final image = img.Image(width: 16, height: 9);
        image.setPixelRgb(0, 0, 0x20, 0x80, 0xc0);
        preview = BundlePreview(
          codec: BundlePreviewCodec.baselineJpeg,
          width: image.width,
          height: image.height,
          encodedBytes: img.encodeJpg(image, quality: 80),
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
              hasPreview: true,
              preview: preview,
            ),
          ],
        );
        final store = LocalBundleIndexStore(root);
        await store.save(index);
        expect(
          await File(p.join(root.path, '.sbox-sync', 'index-v3.json')).exists(),
          isTrue,
        );
        expect(await store.previewFile(manifest.bundleId).exists(), isTrue);
        final loaded = await store.load(expectedSourceId: index.sourceId);
        expect(loaded?.entries.single.manifest.originalName, 'sample.bin');
        expect(loaded?.entries.single.hasCachedPreview, isTrue);
        expect(loaded?.entries.single.preview, isNull);
        if (loaded == null) throw StateError('metadata cache was not loaded');
        await store.save(loaded);
        final loadedWithPreview = await store.load(
          expectedSourceId: index.sourceId,
          includePreviews: true,
        );
        loadedPreview = loadedWithPreview?.entries.single.preview;
        expect(loadedPreview?.encodedBytes, preview.encodedBytes);
        expect(
          await store.load(
            expectedSourceId: 'fedcba9876543210fedcba9876543210',
          ),
          isNull,
        );
        expect(index.encode(), isNot(contains('bundle_dek')));
        expect(index.encode(), isNot(contains('mnemonic')));
        expect(index.encode(), isNot(contains('/9j/')));

        await store.previewFile(manifest.bundleId).writeAsBytes(<int>[1, 2, 3]);
        final corruptedPreviewCache = await store.load(
          expectedSourceId: index.sourceId,
          includePreviews: true,
        );
        expect(corruptedPreviewCache, isNotNull);
        expect(corruptedPreviewCache?.entries.single.preview, isNull);

        final encryptedBundle = File(
          p.join(root.path, '${manifest.bundleId}.sbox'),
        );
        await encryptedBundle.writeAsString('encrypted bundle placeholder');
        await LocalBundleIndexStore.clearAll(root);
        expect(await store.file.exists(), isFalse);
        expect(await store.previewDirectory.exists(), isFalse);
        expect(await encryptedBundle.exists(), isTrue);
      } finally {
        loadedPreview?.dispose();
        preview?.dispose();
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
  );
}
