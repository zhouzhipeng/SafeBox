import 'dart:io';

import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/format/bundle_manifest.dart';
import 'package:safebox/sbox/storage/temporary_plaintext_store.dart';
import 'package:test/test.dart';

void main() {
  test('managed plaintext cache checks availability and clears only Bundle dirs', () async {
    final root = await Directory.systemTemp.createTemp('sbox-v3-plaintext-');
    final outside = File(
      '${root.parent.path}${Platform.pathSeparator}sbox-v3-keep.txt',
    );
    await outside.writeAsString('keep');
    try {
      final plaintext = <int>[1, 2, 3, 4];
      final manifest = BundleManifest(
        bundleId: '0123456789abcdef0123456789abcdef',
        recipientKeyId:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        contentKind: SboxContentKind.file,
        originalName: 'sample.txt',
        mediaType: 'text/plain',
        title: 'sample.txt',
        description: '',
        tags: const <String>[],
        createdAt: '2026-08-17T00:00:00Z',
        logicalPlaintextSize: BigInt.from(plaintext.length),
        logicalPlaintextSha256: sha256Bytes(plaintext),
        nominalShardPlaintextSize: 16 * 1024 * 1024,
        shardCount: 1,
      );
      final store = TemporaryPlaintextStore(root: root);
      final file = await store.fileFor(manifest);
      await file.writeAsBytes(plaintext, flush: true);
      expect(await store.isAvailable(file, manifest), isTrue);

      await file.writeAsBytes(<int>[9, 9, 9, 9], flush: true);
      expect(await store.isAvailable(file, manifest), isTrue);

      await file.writeAsBytes(<int>[9], flush: true);
      expect(await store.isAvailable(file, manifest), isFalse);
      await file.writeAsBytes(plaintext, flush: true);

      final report = await store.clearAll();
      expect(report.isComplete, isTrue);
      expect(report.deletedFiles, 1);
      expect(await file.exists(), isFalse);
      expect(await outside.readAsString(), 'keep');
    } finally {
      if (await outside.exists()) await outside.delete();
      if (await root.exists()) await root.delete(recursive: true);
    }
  });

  test('managed plaintext cache rejects a path outside its Bundle directory', () async {
    final root = await Directory.systemTemp.createTemp('sbox-v3-plaintext-');
    try {
      final manifest = BundleManifest(
        bundleId: 'fedcba9876543210fedcba9876543210',
        recipientKeyId:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
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
      final store = TemporaryPlaintextStore(root: root);
      await expectLater(
        store.isAvailable(
          File('${root.path}${Platform.pathSeparator}outside.txt'),
          manifest,
        ),
        throwsA(isA<Exception>()),
      );
    } finally {
      if (await root.exists()) await root.delete(recursive: true);
    }
  });
}
