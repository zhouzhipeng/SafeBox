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
        expect(
          store.previewDirectory.path,
          p.join(root.path, '.sbox-sync', 'previews'),
        );
        final previewEntities = await store.previewDirectory
            .list(followLinks: false)
            .toList();
        expect(previewEntities, hasLength(1));
        expect(
          previewEntities.single.path,
          store.previewFile(manifest.bundleId).path,
        );

        // Preview storage is shared by source-specific indexes. Saving the
        // same immutable Bundle through another index must not create a
        // second directory or a second JPG.
        final otherStore = LocalBundleIndexStore(
          root,
          fileName: 'index-github-v3.json',
        );
        await otherStore.save(index);
        expect(
          otherStore.previewFile(manifest.bundleId).path,
          store.previewFile(manifest.bundleId).path,
        );
        expect(
          await store.previewDirectory
              .list(followLinks: false)
              .where((entity) => entity is File)
              .length,
          1,
        );

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

  test(
    'reads a legacy multi-file preview directory and flattens it on save',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sbox-v3-preview-migration-',
      );
      BundlePreview? preview;
      BundlePreview? loadedPreview;
      try {
        final bundleId = '1234567890abcdef1234567890abcdef';
        final manifest = BundleManifest(
          bundleId: bundleId,
          recipientKeyId: '20' * 32,
          contentKind: SboxContentKind.file,
          originalName: 'legacy.bin',
          mediaType: 'application/octet-stream',
          title: 'legacy.bin',
          description: '',
          tags: const <String>[],
          createdAt: '2026-08-17T00:00:00Z',
          logicalPlaintextSize: BigInt.zero,
          logicalPlaintextSha256: List<int>.filled(32, 0),
          nominalShardPlaintextSize: 16 * 1024 * 1024,
          shardCount: 1,
        );
        final image = img.Image(width: 4, height: 3);
        preview = BundlePreview(
          codec: BundlePreviewCodec.baselineJpeg,
          width: image.width,
          height: image.height,
          encodedBytes: img.encodeJpg(image, quality: 80),
        );
        final index = LocalBundleIndex(
          sourceId: 'fedcba9876543210fedcba9876543210',
          entries: <LocalBundleIndexEntry>[
            LocalBundleIndexEntry(
              bundleId: bundleId,
              rootBasename: '$bundleId.sbox',
              rootRevisionFingerprint: 'legacy-revision',
              manifestPrefixSha256: hexLower(List<int>.filled(32, 0x33)),
              verification: BundleVerification.complete,
              manifest: manifest,
              hasPreview: true,
              preview: preview,
            ),
          ],
        );
        final store = LocalBundleIndexStore(root);
        await Directory(p.join(store.previewDirectory.path, bundleId))
            .create(recursive: true);
        await File(
          p.join(store.previewDirectory.path, bundleId, 'candidate-a.jpg'),
        ).writeAsBytes(<int>[1, 2, 3]);
        await File(
          p.join(store.previewDirectory.path, bundleId, 'candidate-b.jpg'),
        ).writeAsBytes(preview.encodedBytes);
        await store.file.parent.create(recursive: true);
        await store.file.writeAsString(index.encode());

        final loaded = await store.load(
          expectedSourceId: index.sourceId,
          includePreviews: true,
        );
        loadedPreview = loaded?.entries.single.preview;
        expect(loadedPreview?.encodedBytes, preview.encodedBytes);

        await store.save(loaded!);
        expect(await store.previewFile(bundleId).exists(), isTrue);
        expect(
          await Directory(p.join(store.previewDirectory.path, bundleId))
              .exists(),
          isFalse,
        );
        expect(
          await store.previewDirectory
              .list(followLinks: false)
              .where((entity) => entity is File)
              .length,
          1,
        );
      } finally {
        loadedPreview?.dispose();
        preview?.dispose();
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
  );
}
