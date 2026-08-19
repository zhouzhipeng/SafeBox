import 'dart:io';
import 'dart:typed_data';

import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/engine/bundle_encryptor.dart';
import 'package:safebox/sbox/errors.dart';
import 'package:safebox/sbox/format/bundle_path.dart';
import 'package:safebox/sbox/identity/bip39_identity.dart';
import 'package:safebox/sbox/source/bundle_sync.dart';
import 'package:safebox/sbox/source/data_source.dart';
import 'package:safebox/sbox/source/local_directory_source.dart';
import 'package:safebox/sbox/source/source_path.dart';
import 'package:test/test.dart';

void main() {
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon about';

  test('download cancellation exposes a stable cancelled error', () {
    final cancellation = BundleDownloadCancellation();
    var cleanupCalls = 0;
    final unregister = cancellation.registerOnCancel(() => cleanupCalls++);

    expect(cancellation.isCancelled, isFalse);
    cancellation.cancel();
    expect(cancellation.isCancelled, isTrue);
    expect(cleanupCalls, 1);
    cancellation.cancel();
    expect(cleanupCalls, 1);
    expect(
      cancellation.throwIfCancelled,
      throwsA(
        isA<SboxException>().having(
          (error) => error.code,
          'code',
          SboxErrorCode.cancelled,
        ),
      ),
    );
    unregister();
  });

  test('download progress reports bytes and shard progress', () async {
    final temporary = await Directory.systemTemp.createTemp('sbox-sync-');
    final downloadedDirectory = await Directory.systemTemp.createTemp(
      'sbox-sync-download-',
    );
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

      final downloadProgress = <BundleDownloadProgress>[];
      final encryptedDestination = await LocalDirectoryDataSource.attach(
        root: downloadedDirectory,
      );
      await BundleSync.downloadTo(
        source: source,
        rootPath: SourcePath(encrypted.root.basename),
        destination: encryptedDestination,
        onProgress: downloadProgress.add,
      );
      expect(downloadProgress.last.stage, BundleDownloadStage.downloading);
      final copied = await BundleSync.fetchAndDecrypt(
        source: encryptedDestination,
        rootPath: SourcePath(encrypted.root.basename),
        mnemonic: mnemonic,
        expectedIdentity: identity.publicIdentity,
      );
      expect(copied.plaintext, orderedEquals(plaintext));
      copied.plaintext.fillRange(0, copied.plaintext.length, 0);
    } finally {
      identity.disposeControlledSecrets();
      if (await temporary.exists()) await temporary.delete(recursive: true);
      if (await downloadedDirectory.exists()) {
        await downloadedDirectory.delete(recursive: true);
      }
    }
  });

  test('download reads continuation shards with bounded parallelism', () async {
    final temporary = await Directory.systemTemp.createTemp('sbox-sync-');
    final identity = await SboxIdentityDeriver().deriveIdentity(mnemonic);
    try {
      final plaintext = Uint8List.fromList(
        List<int>.generate(4 * 1024 * 1024, (index) => index & 0xff),
      );
      final encrypted = await BundleEncryptor().encryptBytes(
        plaintext: plaintext,
        options: BundleEncryptionOptions(
          recipient: identity.publicIdentity,
          contentKind: SboxContentKind.file,
          originalName: 'parallel-download.bin',
          mediaType: 'application/octet-stream',
          targetNominalShardPlaintextSize: 1024 * 1024,
        ),
      );
      final local = await LocalDirectoryDataSource.attach(root: temporary);
      for (final object in encrypted.objects) {
        await local.putNew(
          SourcePath(object.basename),
          Stream<List<int>>.value(object.bytes),
          length: object.bytes.length,
          sha256: object.sha256,
        );
      }
      final source = _TrackingReadSource(local);

      final result = await BundleSync.fetchAndDecrypt(
        source: source,
        rootPath: SourcePath(encrypted.root.basename),
        mnemonic: mnemonic,
        expectedIdentity: identity.publicIdentity,
      );

      expect(result.plaintext, orderedEquals(plaintext));
      expect(source.maxConcurrentContinuationReads, greaterThan(1));
      result.plaintext.fillRange(0, result.plaintext.length, 0);
    } finally {
      identity.disposeControlledSecrets();
      if (await temporary.exists()) await temporary.delete(recursive: true);
    }
  });
}

final class _TrackingReadSource implements DataSource {
  _TrackingReadSource(this._delegate);

  final DataSource _delegate;
  var _activeContinuationReads = 0;
  var maxConcurrentContinuationReads = 0;

  @override
  SourceCapabilities get capabilities {
    final original = _delegate.capabilities;
    return SourceCapabilities(
      canRead: original.canRead,
      canWrite: original.canWrite,
      canDelete: original.canDelete,
      canListObjects: original.canListObjects,
      supportsRangeRead: original.supportsRangeRead,
      maxObjectBytes: original.maxObjectBytes,
      maxParallelTransfers: 3,
    );
  }

  @override
  Future<SourceRead> get(SourcePath path, {RevisionToken? ifNoneMatch}) async {
    final shard = parseCanonicalBundleBasename(path.value);
    if (shard.shardIndex == 0) {
      return _delegate.get(path, ifNoneMatch: ifNoneMatch);
    }

    _activeContinuationReads++;
    if (_activeContinuationReads > maxConcurrentContinuationReads) {
      maxConcurrentContinuationReads = _activeContinuationReads;
    }
    try {
      final read = await _delegate.get(path, ifNoneMatch: ifNoneMatch);
      return SourceRead(
        body: _holdReadOpen(read.body),
        length: read.length,
        revision: read.revision,
        notModified: read.notModified,
      );
    } catch (_) {
      _activeContinuationReads--;
      rethrow;
    }
  }

  Stream<List<int>> _holdReadOpen(Stream<List<int>> body) async* {
    try {
      await Future<void>.delayed(const Duration(milliseconds: 15));
      yield* body;
    } finally {
      _activeContinuationReads--;
    }
  }

  @override
  Future<RevisionToken> putNew(
    SourcePath path,
    Stream<List<int>> body, {
    required int length,
    required Uint8List sha256,
  }) => _delegate.putNew(path, body, length: length, sha256: sha256);

  @override
  Future<void> deleteIfMatch(SourcePath path, RevisionToken expected) =>
      _delegate.deleteIfMatch(path, expected);
}
