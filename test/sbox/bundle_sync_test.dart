import 'dart:io';
import 'dart:typed_data';

import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/engine/bundle_encryptor.dart';
import 'package:safebox/sbox/identity/bip39_identity.dart';
import 'package:safebox/sbox/source/bundle_sync.dart';
import 'package:safebox/sbox/source/local_directory_source.dart';
import 'package:safebox/sbox/source/source_path.dart';
import 'package:test/test.dart';

void main() {
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon about';

  test('download progress reports bytes and shard progress', () async {
    final temporary = await Directory.systemTemp.createTemp('sbox-sync-');
    final identity = await SboxIdentityDeriver().deriveIdentity(mnemonic);
    try {
      final plaintext = Uint8List(1024 * 1024 + 123);
      final encrypted = await BundleEncryptor().encryptBytes(
        plaintext: plaintext,
        options: BundleEncryptionOptions(
          recipient: identity.publicIdentity,
          contentKind: SboxContentKind.file,
          originalName: 'progress.bin',
          mediaType: 'application/octet-stream',
          targetNominalShardPlaintextSize: 1024 * 1024,
        ),
      );
      final source = await LocalDirectoryDataSource.attach(root: temporary);
      for (final object in encrypted.objects) {
        await source.putNew(
          SourcePath(object.basename),
          Stream<List<int>>.value(object.bytes),
          length: object.bytes.length,
          sha256: object.sha256,
        );
      }

      final progress = <BundleDownloadProgress>[];
      final decrypted = await BundleSync.fetchAndDecrypt(
        source: source,
        rootPath: SourcePath(encrypted.root.basename),
        mnemonic: mnemonic,
        expectedIdentity: identity.publicIdentity,
        onProgress: progress.add,
      );

      expect(decrypted.plaintext, orderedEquals(plaintext));
      expect(progress.any((item) => item.currentObjectBytes > 0), isTrue);
      expect(
        progress.any(
          (item) =>
              item.stage == BundleDownloadStage.downloading &&
              item.fraction != null,
        ),
        isTrue,
      );
      expect(
        progress.any(
          (item) =>
              item.stage == BundleDownloadStage.decrypting &&
              item.processedBytes > 0 &&
              item.totalProcessingBytes == plaintext.length,
        ),
        isTrue,
      );
      final finalProgress = progress.last;
      expect(finalProgress.stage, BundleDownloadStage.decrypting);
      expect(finalProgress.completedObjects, encrypted.objects.length);
      expect(finalProgress.downloadedBytes, greaterThan(0));

      final output = File('${temporary.path}${Platform.pathSeparator}out.bin');
      final streamingProgress = <BundleDownloadProgress>[];
      await BundleSync.fetchAndDecryptToFileStreaming(
        source: source,
        rootPath: SourcePath(encrypted.root.basename),
        mnemonic: mnemonic,
        expectedIdentity: identity.publicIdentity,
        destination: output,
        onProgress: streamingProgress.add,
      );
      expect(await output.readAsBytes(), orderedEquals(plaintext));
      expect(
        streamingProgress.any(
          (item) =>
              item.stage == BundleDownloadStage.merging &&
              item.processedBytes > 0 &&
              item.totalProcessingBytes == plaintext.length,
        ),
        isTrue,
      );
      expect(streamingProgress.last.stage, BundleDownloadStage.merging);
    } finally {
      identity.disposeControlledSecrets();
      if (await temporary.exists()) await temporary.delete(recursive: true);
    }
  });
}
