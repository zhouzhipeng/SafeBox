import 'dart:io';
import 'dart:isolate';
import 'dart:async';
import 'dart:typed_data';

import '../bytes.dart';
import '../catalog/canonical_json.dart';
import '../catalog/catalog_container.dart';
import '../catalog/catalog_models.dart';
import '../catalog/catalog_state.dart';
import '../constants.dart';
import '../errors.dart';
import '../identity/bip39_identity.dart';
import '../identity/ephemeral_mnemonic.dart';
import '../identity/public_identity_record.dart';
import '../source/data_source.dart';
import '../source/source_path.dart';
import '../storage/local_cipher_store.dart';
import '../storage/io_hash.dart';
import '../storage/temporary_plaintext_store.dart';
import 'multipart_decrypt.dart' as multipart;
import 'job_control.dart';
import 'multipart.dart';
import 'streaming_container.dart';

final class IdentityTaskResult {
  const IdentityTaskResult({
    required this.publicIdentityJson,
    required this.pCandidateCount,
    required this.qCandidateCount,
  });

  final Map<String, Object?> publicIdentityJson;
  final int pCandidateCount;
  final int qCandidateCount;
}

final class EncryptFileTaskResult {
  const EncryptFileTaskResult({
    required this.catalogPayloadJson,
    required this.objectPaths,
  });

  final Map<String, Object?> catalogPayloadJson;
  final List<String> objectPaths;
}

final class DecryptFileTaskResult {
  const DecryptFileTaskResult({
    required this.plaintextPath,
    required this.originalName,
    required this.plaintextLength,
  });

  final String plaintextPath;
  final String originalName;
  final int plaintextLength;
}

final class CatalogCommitTaskResult {
  const CatalogCommitTaskResult({
    required this.catalogId,
    required this.catalogEntryJson,
    required this.catalogPayloadJson,
    required this.catalogPayloadsJson,
    required this.entries,
    required this.encryptedCatalogSha256,
    required this.entryId,
    required this.generation,
  });

  final String catalogId;
  final Map<String, Object?> catalogEntryJson;
  final Map<String, Object?> catalogPayloadJson;
  final List<Map<String, Object?>> catalogPayloadsJson;
  final List<CatalogEntryViewData> entries;
  final Uint8List encryptedCatalogSha256;
  final String entryId;
  final int generation;
}

final class CatalogEntryViewData {
  const CatalogEntryViewData({
    required this.entryId,
    required this.revision,
    required this.title,
    required this.description,
    required this.originalName,
    required this.mediaType,
    required this.plaintextSize,
    required this.updatedAt,
    required this.tags,
    required this.partCount,
  });

  final String entryId;
  final int revision;
  final String title;
  final String description;
  final String originalName;
  final String mediaType;
  final String plaintextSize;
  final String updatedAt;
  final List<String> tags;
  final int partCount;
}

final class CatalogViewTaskResult {
  const CatalogViewTaskResult({
    required this.catalogId,
    required this.generation,
    required this.encryptedCatalogSha256,
    required this.entries,
    required this.catalogPayloadsJson,
    required this.continuity,
  });

  final String catalogId;
  final int generation;
  final Uint8List encryptedCatalogSha256;
  final List<CatalogEntryViewData> entries;
  final List<Map<String, Object?>> catalogPayloadsJson;
  final CatalogContinuity continuity;
}

final class CatalogConflictViewData {
  const CatalogConflictViewData({
    required this.entryId,
    required this.reason,
    required this.localTitle,
    required this.remoteTitle,
    required this.localPayloadSha256,
    required this.remotePayloadSha256,
    required this.localPartCount,
    required this.remotePartCount,
    required this.baseRevision,
    required this.remoteRevision,
  });

  final String entryId;
  final String reason;
  final String localTitle;
  final String? remoteTitle;
  final String localPayloadSha256;
  final String? remotePayloadSha256;
  final int localPartCount;
  final int? remotePartCount;
  final int? baseRevision;
  final int? remoteRevision;
}

sealed class CatalogMergeTaskResult {
  const CatalogMergeTaskResult();
}

final class CatalogMergedTaskResult extends CatalogMergeTaskResult {
  const CatalogMergedTaskResult({
    required this.catalogId,
    required this.generation,
    required this.encryptedCatalogSha256,
    required this.catalogPayloadsJson,
    required this.entries,
  });

  final String catalogId;
  final int generation;
  final Uint8List encryptedCatalogSha256;
  final List<Map<String, Object?>> catalogPayloadsJson;
  final List<CatalogEntryViewData> entries;
}

final class CatalogConflictsTaskResult extends CatalogMergeTaskResult {
  const CatalogConflictsTaskResult(this.conflicts);

  final List<CatalogConflictViewData> conflicts;
}

enum CatalogConflictResolution { keepLocal, keepRemote }

enum _CatalogMutationKind { updateMetadata, delete }

abstract final class CryptoTaskRunner {
  static final Set<_ActiveCryptoIsolate> _active = <_ActiveCryptoIsolate>{};

  /// Immediately terminates every one-shot isolate that could contain a
  /// mnemonic or reconstructed private key. Call this when the application
  /// leaves the foreground. A cancelled task can never be resumed.
  static void cancelAll() {
    for (final job in List<_ActiveCryptoIsolate>.of(_active)) {
      job.cancel();
    }
  }

  static Future<IdentityTaskResult> derivePublicIdentity(String mnemonic) {
    return _runOneShot(() async {
      final ephemeral = await SboxIdentityDeriver().deriveIdentity(mnemonic);
      try {
        return IdentityTaskResult(
          publicIdentityJson: PublicIdentityRecord(
            identity: ephemeral.publicIdentity,
          ).toJson(),
          pCandidateCount: ephemeral.pCandidateCount,
          qCandidateCount: ephemeral.qCandidateCount,
        );
      } finally {
        ephemeral.disposeControlledSecrets();
      }
    }, debugName: 'sbox-identity-once');
  }

  static Future<EncryptFileTaskResult> encryptFile({
    required String inputPath,
    required String localCipherRoot,
    required Map<String, Object?> publicIdentityJson,
    required int contentKind,
    required String originalName,
    required String mediaType,
    required Map<String, Object?> capabilitiesJson,
  }) {
    return _runOneShot(() async {
      final input = File(inputPath);
      final identity = PublicIdentityRecord.fromJson(publicIdentityJson)
          .identity;
      final store = await FileSystemLocalCipherStore.open(
        Directory(localCipherRoot),
      );
      final capabilities = _capabilitiesFromMessage(capabilitiesJson);
      final prepared = await encryptLogicalFile(
        input: FileReadableInputRef(input),
        inputLength: await input.length(),
        target: capabilities,
        cipherStore: store,
        options: EncryptOptions(
          recipient: identity,
          contentKind: SboxContentKind.fromWireValue(contentKind),
          originalName: originalName,
          mediaType: mediaType,
        ),
        control: JobControl(),
      );
      return EncryptFileTaskResult(
        catalogPayloadJson: prepared.catalogPayload.toJson(),
        objectPaths: prepared.objects
            .map((object) => object.path.value)
            .toList(growable: false),
      );
    }, debugName: 'sbox-encrypt-once');
  }

  static Future<CatalogCommitTaskResult> encryptAndCommitCatalog({
    String? inputPath,
    String? text,
    required String localCipherRoot,
    required Map<String, Object?> publicIdentityJson,
    required String mnemonic,
    required int contentKind,
    required String originalName,
    required String mediaType,
    required String title,
    required String description,
    required List<String> tags,
    required Map<String, Object?> capabilitiesJson,
  }) {
    if ((inputPath == null) == (text == null)) {
      throw ArgumentError('Exactly one plaintext input must be supplied');
    }
    return _runOneShot(() async {
      final identity = PublicIdentityRecord.fromJson(publicIdentityJson)
          .identity;
      final store = await FileSystemLocalCipherStore.open(
        Directory(localCipherRoot),
      );
      final catalogFile = File(
        '$localCipherRoot${Platform.pathSeparator}catalog.sbox',
      );
      SboxCatalog? previous;
      Uint8List? previousHash;
      if (await catalogFile.exists()) {
        final length = await catalogFile.length();
        if (length > SboxV1.maxCatalogCiphertextSize) {
          throw const FormatException('Existing catalog.sbox is too large');
        }
        final bytes = Uint8List.fromList(await catalogFile.readAsBytes());
        final opened = await openCatalogContainerWithMnemonic(
          container: bytes,
          mnemonic: EphemeralMnemonic.fromString(mnemonic),
          expectedIdentity: identity,
          control: JobControl(),
        );
        previous = opened.catalog.catalog;
        previousHash = opened.containerSha256;
      }

      final ReadableInputRef input;
      final int inputLength;
      if (inputPath != null) {
        final file = File(inputPath);
        input = FileReadableInputRef(file);
        inputLength = await file.length();
      } else {
        final bytes = utf8Bytes(text!);
        input = MemoryReadableInputRef(bytes);
        inputLength = bytes.length;
      }
      final prepared = await encryptLogicalFile(
        input: input,
        inputLength: inputLength,
        target: _capabilitiesFromMessage(capabilitiesJson),
        cipherStore: store,
        options: EncryptOptions(
          recipient: identity,
          contentKind: SboxContentKind.fromWireValue(contentKind),
          originalName: originalName,
          mediaType: mediaType,
        ),
        control: JobControl(),
      );

      final now = _utcSeconds(DateTime.now());
      final entryId = hexLower(secureRandomBytes(16));
      final entry = CatalogEntry(
        entryId: entryId,
        revision: 1,
        title: title,
        description: description,
        originalName: originalName,
        mediaType: mediaType,
        payload: prepared.catalogPayload,
        tags: tags,
        createdAt: now,
        updatedAt: now,
      );
      final catalog = SboxCatalog(
        catalogId: previous?.catalogId ?? hexLower(secureRandomBytes(16)),
        generation: (previous?.generation ?? 0) + 1,
        previousCatalogSha256: previousHash == null
            ? null
            : hexLower(previousHash),
        recipientKeyId: hexLower(identity.recipientKeyId),
        signerKeyId: hexLower(identity.catalogSignerKeyId),
        createdAt: previous?.createdAt ?? now,
        updatedAt: now,
        entries: <CatalogEntry>[...?previous?.entries, entry],
        tombstones: previous?.tombstones ?? const <CatalogTombstone>[],
      );
      final encrypted = await createCatalogContainerWithMnemonic(
        catalog: catalog,
        mnemonic: EphemeralMnemonic.fromString(mnemonic),
        expectedIdentity: identity,
      );
      final staged = await store.createStaging(SourcePath('catalog.sbox'));
      try {
        final sink = staged.openSink();
        sink.add(encrypted.bytes);
        await sink.flush();
        await sink.close();
        if (previousHash == null) {
          await store.commitDownloaded(
            staged,
            expectedLength: encrypted.bytes.length,
            expectedSha256: encrypted.sha256,
          );
        } else {
          await store.replaceDownloadedCatalog(
            staged,
            expectedLength: encrypted.bytes.length,
            expectedSha256: encrypted.sha256,
            expectedCurrentSha256: previousHash,
          );
        }
      } on Object {
        await staged.discard();
        rethrow;
      }
      return CatalogCommitTaskResult(
        catalogId: catalog.catalogId,
        catalogEntryJson: entry.toJson(),
        catalogPayloadJson: prepared.catalogPayload.toJson(),
        catalogPayloadsJson: catalog.entries
            .map((value) => value.payload.toJson())
            .toList(growable: false),
        entries: _viewEntries(catalog),
        encryptedCatalogSha256: encrypted.sha256,
        entryId: entryId,
        generation: catalog.generation,
      );
    }, debugName: 'sbox-encrypt-catalog-once');
  }

  static Future<CatalogViewTaskResult> unlockCatalog({
    required String catalogPath,
    required String mnemonic,
    required Map<String, Object?> publicIdentityJson,
    String? expectedCatalogId,
    Map<String, Object?>? checkpointJson,
  }) {
    return _runOneShot(() async {
      final identity = PublicIdentityRecord.fromJson(publicIdentityJson)
          .identity;
      final bytes = Uint8List.fromList(await File(catalogPath).readAsBytes());
      final opened = await openCatalogContainerWithMnemonic(
        container: bytes,
        mnemonic: EphemeralMnemonic.fromString(mnemonic),
        expectedIdentity: identity,
        control: JobControl(),
        expectedCatalogId: expectedCatalogId,
      );
      final checkpoint = checkpointJson == null
          ? null
          : CatalogCheckpoint(
              catalogId: checkpointJson['catalog_id']! as String,
              highestGeneration: checkpointJson['highest_generation']! as int,
              lastCatalogSha256:
                  checkpointJson['last_catalog_sha256']! as String,
            );
      final continuity = validateCatalogCheckpoint(
        remote: opened.catalog.catalog,
        remoteContainerSha256: hexLower(opened.containerSha256),
        local: checkpoint,
      );
      return CatalogViewTaskResult(
        catalogId: opened.catalog.catalog.catalogId,
        generation: opened.catalog.catalog.generation,
        encryptedCatalogSha256: opened.containerSha256,
        continuity: continuity,
        catalogPayloadsJson: opened.catalog.catalog.entries
            .map((entry) => entry.payload.toJson())
            .toList(growable: false),
        entries: _viewEntries(opened.catalog.catalog),
      );
    }, debugName: 'sbox-unlock-catalog-once');
  }

  static Future<CatalogViewTaskResult> updateCatalogMetadata({
    required String localCipherRoot,
    required String mnemonic,
    required Map<String, Object?> publicIdentityJson,
    required String expectedCatalogId,
    required Uint8List expectedCatalogSha256,
    required String entryId,
    required String title,
    required String description,
    required List<String> tags,
  }) => _mutateCatalog(
    localCipherRoot: localCipherRoot,
    mnemonic: mnemonic,
    publicIdentityJson: publicIdentityJson,
    expectedCatalogId: expectedCatalogId,
    expectedCatalogSha256: expectedCatalogSha256,
    entryId: entryId,
    kind: _CatalogMutationKind.updateMetadata,
    title: title,
    description: description,
    tags: tags,
  );

  static Future<CatalogViewTaskResult> deleteCatalogEntry({
    required String localCipherRoot,
    required String mnemonic,
    required Map<String, Object?> publicIdentityJson,
    required String expectedCatalogId,
    required Uint8List expectedCatalogSha256,
    required String entryId,
  }) => _mutateCatalog(
    localCipherRoot: localCipherRoot,
    mnemonic: mnemonic,
    publicIdentityJson: publicIdentityJson,
    expectedCatalogId: expectedCatalogId,
    expectedCatalogSha256: expectedCatalogSha256,
    entryId: entryId,
    kind: _CatalogMutationKind.delete,
  );

  /// Re-signs and re-encrypts a Catalog mutation in a fresh isolate. The
  /// expected ciphertext digest protects against a concurrent process or a
  /// sync client replacing catalog.sbox between the UI view and commit.
  static Future<CatalogViewTaskResult> _mutateCatalog({
    required String localCipherRoot,
    required String mnemonic,
    required Map<String, Object?> publicIdentityJson,
    required String expectedCatalogId,
    required Uint8List expectedCatalogSha256,
    required String entryId,
    required _CatalogMutationKind kind,
    String? title,
    String? description,
    List<String>? tags,
  }) {
    return _runOneShot(() async {
      final identity = PublicIdentityRecord.fromJson(publicIdentityJson)
          .identity;
      final catalogFile = File(
        '$localCipherRoot${Platform.pathSeparator}catalog.sbox',
      );
      if (!await catalogFile.exists() ||
          await catalogFile.length() > SboxV1.maxCatalogCiphertextSize) {
        throw const FormatException('Catalog is missing or too large');
      }
      final bytes = Uint8List.fromList(await catalogFile.readAsBytes());
      final opened = await openCatalogContainerWithMnemonic(
        container: bytes,
        mnemonic: EphemeralMnemonic.fromString(mnemonic),
        expectedIdentity: identity,
        control: JobControl(),
        expectedCatalogId: expectedCatalogId,
      );
      if (!constantTimeBytesEqual(
        opened.containerSha256,
        expectedCatalogSha256,
      )) {
        throw const SboxException(
          SboxErrorCode.syncConflict,
          'Catalog 在编辑期间发生变化，拒绝覆盖',
        );
      }

      final now = _utcSeconds(DateTime.now());
      final CatalogOperation operation = switch (kind) {
        _CatalogMutationKind.updateMetadata => UpdateCatalogMetadata(
          entryId: entryId,
          title: title!,
          description: description!,
          tags: List<String>.of(tags!),
          updatedAt: now,
        ),
        _CatalogMutationKind.delete => DeleteCatalogEntry(
          entryId: entryId,
          deletedAt: now,
        ),
      };
      final outcome = mergeCatalog(
        base: opened.catalog,
        remote: opened.catalog,
        pending: <CatalogOperation>[operation],
      );
      if (outcome is UserCatalogConflicts) {
        throw const SboxException(
          SboxErrorCode.syncConflict,
          'Catalog 条目在编辑期间发生变化',
        );
      }
      final merged = outcome as MergedCatalog;
      final current = opened.catalog.catalog;
      final next = SboxCatalog(
        catalogId: current.catalogId,
        generation: merged.nextGeneration,
        previousCatalogSha256: hexLower(opened.containerSha256),
        recipientKeyId: current.recipientKeyId,
        signerKeyId: current.signerKeyId,
        createdAt: current.createdAt,
        updatedAt: now,
        entries: merged.entries,
        tombstones: merged.tombstones,
      );
      final encrypted = await createCatalogContainerWithMnemonic(
        catalog: next,
        mnemonic: EphemeralMnemonic.fromString(mnemonic),
        expectedIdentity: identity,
      );
      final store = await FileSystemLocalCipherStore.open(
        Directory(localCipherRoot),
      );
      final staged = await store.createStaging(SourcePath('catalog.sbox'));
      try {
        final sink = staged.openSink();
        sink.add(encrypted.bytes);
        await sink.flush();
        await sink.close();
        await store.replaceDownloadedCatalog(
          staged,
          expectedLength: encrypted.bytes.length,
          expectedSha256: encrypted.sha256,
          expectedCurrentSha256: opened.containerSha256,
        );
      } on Object {
        await staged.discard();
        rethrow;
      }
      return CatalogViewTaskResult(
        catalogId: next.catalogId,
        generation: next.generation,
        encryptedCatalogSha256: encrypted.sha256,
        entries: _viewEntries(next),
        catalogPayloadsJson: next.entries
            .map((entry) => entry.payload.toJson())
            .toList(growable: false),
        continuity: CatalogContinuity.advanced,
      );
    }, debugName: 'sbox-catalog-${kind.name}-once');
  }

  /// Performs a three-way merge after a conditional Catalog write fails.
  /// Both Catalog inputs remain encrypted on disk; decryption, signature
  /// verification, merge, signing and re-encryption all happen in this
  /// one-shot isolate. Pending create, metadata-update and tombstone-delete
  /// operations are derived from the signed common baseline and local
  /// snapshot; payload replacement or malformed history fails closed.
  static Future<CatalogMergeTaskResult> mergePendingCatalogAfterConflict({
    required String baseCatalogPath,
    required String localCatalogPath,
    required String remoteCatalogPath,
    required String localCipherRoot,
    required String mnemonic,
    required Map<String, Object?> publicIdentityJson,
    required Uint8List expectedCurrentCatalogSha256,
  }) {
    return _runOneShot(() async {
      final identity = PublicIdentityRecord.fromJson(publicIdentityJson)
          .identity;
      final baseBytes = Uint8List.fromList(
        await File(baseCatalogPath).readAsBytes(),
      );
      final base = await openCatalogContainerWithMnemonic(
        container: baseBytes,
        mnemonic: EphemeralMnemonic.fromString(mnemonic),
        expectedIdentity: identity,
        control: JobControl(),
      );
      final localBytes = Uint8List.fromList(
        await File(localCatalogPath).readAsBytes(),
      );
      final local = await openCatalogContainerWithMnemonic(
        container: localBytes,
        mnemonic: EphemeralMnemonic.fromString(mnemonic),
        expectedIdentity: identity,
        control: JobControl(),
        expectedCatalogId: base.catalog.catalog.catalogId,
      );
      final remoteBytes = Uint8List.fromList(
        await File(remoteCatalogPath).readAsBytes(),
      );
      final remote = await openCatalogContainerWithMnemonic(
        container: remoteBytes,
        mnemonic: EphemeralMnemonic.fromString(mnemonic),
        expectedIdentity: identity,
        control: JobControl(),
        expectedCatalogId: base.catalog.catalog.catalogId,
      );
      validateCatalogCheckpoint(
        remote: remote.catalog.catalog,
        remoteContainerSha256: hexLower(remote.containerSha256),
        local: CatalogCheckpoint(
          catalogId: base.catalog.catalog.catalogId,
          highestGeneration: base.catalog.catalog.generation,
          lastCatalogSha256: hexLower(base.containerSha256),
        ),
      );
      final pending = _derivePendingOperations(
        base.catalog.catalog,
        local.catalog.catalog,
      );
      if (pending.conflicts.isNotEmpty) {
        return CatalogConflictsTaskResult(pending.conflicts);
      }
      final outcome = mergeCatalog(
        base: base.catalog,
        remote: remote.catalog,
        pending: pending.operations,
      );
      if (outcome is UserCatalogConflicts) {
        final conflicts = outcome.conflicts
            .map((conflict) {
              final localEntry = _entryOrNull(
                local.catalog.catalog,
                conflict.entryId,
              );
              final remoteEntry = _entryOrNull(
                remote.catalog.catalog,
                conflict.entryId,
              );
              return CatalogConflictViewData(
                entryId: conflict.entryId,
                reason: conflict.reason,
                localTitle: localEntry?.title ?? '本地删除',
                remoteTitle: remoteEntry?.title,
                localPayloadSha256:
                    localEntry?.payload.plaintextSha256 ?? 'deleted',
                remotePayloadSha256: remoteEntry?.payload.plaintextSha256,
                localPartCount: localEntry?.payload.parts.length ?? 0,
                remotePartCount: remoteEntry?.payload.parts.length,
                baseRevision: conflict.baseRevision,
                remoteRevision: conflict.remoteRevision,
              );
            })
            .toList(growable: false);
        return CatalogConflictsTaskResult(conflicts);
      }
      final merged = outcome as MergedCatalog;
      final remoteCatalog = remote.catalog.catalog;
      final now = _utcSeconds(DateTime.now());
      final catalog = SboxCatalog(
        catalogId: remoteCatalog.catalogId,
        generation: merged.nextGeneration,
        previousCatalogSha256: hexLower(remote.containerSha256),
        recipientKeyId: remoteCatalog.recipientKeyId,
        signerKeyId: remoteCatalog.signerKeyId,
        createdAt: remoteCatalog.createdAt,
        updatedAt: now,
        entries: merged.entries,
        tombstones: merged.tombstones,
      );
      final encrypted = await createCatalogContainerWithMnemonic(
        catalog: catalog,
        mnemonic: EphemeralMnemonic.fromString(mnemonic),
        expectedIdentity: identity,
      );
      final store = await FileSystemLocalCipherStore.open(
        Directory(localCipherRoot),
      );
      final staged = await store.createStaging(SourcePath('catalog.sbox'));
      try {
        final sink = staged.openSink();
        sink.add(encrypted.bytes);
        await sink.flush();
        await sink.close();
        await store.replaceDownloadedCatalog(
          staged,
          expectedLength: encrypted.bytes.length,
          expectedSha256: encrypted.sha256,
          expectedCurrentSha256: expectedCurrentCatalogSha256,
        );
      } on Object {
        await staged.discard();
        rethrow;
      }
      return CatalogMergedTaskResult(
        catalogId: catalog.catalogId,
        generation: catalog.generation,
        encryptedCatalogSha256: encrypted.sha256,
        catalogPayloadsJson: catalog.entries
            .map((entry) => entry.payload.toJson())
            .toList(growable: false),
        entries: _viewEntries(catalog),
      );
    }, debugName: 'sbox-merge-catalog-once');
  }

  /// Applies explicit per-entry conflict choices to the newest authenticated
  /// remote Catalog. Keeping a local deletion confirms its tombstone; keeping
  /// a local entry supersedes the remote entry/tombstone with a new revision.
  static Future<CatalogMergeTaskResult> resolvePendingCatalogConflicts({
    required String baseCatalogPath,
    required String localCatalogPath,
    required String remoteCatalogPath,
    required String localCipherRoot,
    required String mnemonic,
    required Map<String, Object?> publicIdentityJson,
    required Uint8List expectedCurrentCatalogSha256,
    required Map<String, CatalogConflictResolution> resolutions,
  }) {
    return _runOneShot(() async {
      final identity = PublicIdentityRecord.fromJson(publicIdentityJson)
          .identity;
      final base = await openCatalogContainerWithMnemonic(
        container: Uint8List.fromList(
          await File(baseCatalogPath).readAsBytes(),
        ),
        mnemonic: EphemeralMnemonic.fromString(mnemonic),
        expectedIdentity: identity,
        control: JobControl(),
      );
      final local = await openCatalogContainerWithMnemonic(
        container: Uint8List.fromList(
          await File(localCatalogPath).readAsBytes(),
        ),
        mnemonic: EphemeralMnemonic.fromString(mnemonic),
        expectedIdentity: identity,
        control: JobControl(),
        expectedCatalogId: base.catalog.catalog.catalogId,
      );
      final remote = await openCatalogContainerWithMnemonic(
        container: Uint8List.fromList(
          await File(remoteCatalogPath).readAsBytes(),
        ),
        mnemonic: EphemeralMnemonic.fromString(mnemonic),
        expectedIdentity: identity,
        control: JobControl(),
        expectedCatalogId: base.catalog.catalog.catalogId,
      );
      validateCatalogCheckpoint(
        remote: remote.catalog.catalog,
        remoteContainerSha256: hexLower(remote.containerSha256),
        local: CatalogCheckpoint(
          catalogId: base.catalog.catalog.catalogId,
          highestGeneration: base.catalog.catalog.generation,
          lastCatalogSha256: hexLower(base.containerSha256),
        ),
      );
      final pending = _derivePendingOperations(
        base.catalog.catalog,
        local.catalog.catalog,
      );
      if (pending.conflicts.isNotEmpty) {
        return CatalogConflictsTaskResult(pending.conflicts);
      }

      final firstPass = mergeCatalog(
        base: base.catalog,
        remote: remote.catalog,
        pending: pending.operations,
      );
      late final MergedCatalog merged;
      if (firstPass is MergedCatalog) {
        merged = firstPass;
      } else {
        final conflicts = (firstPass as UserCatalogConflicts).conflicts;
        final conflictIds = conflicts
            .map((conflict) => conflict.entryId)
            .toSet();
        if (resolutions.length != conflictIds.length ||
            !conflictIds.every(resolutions.containsKey)) {
          return CatalogConflictsTaskResult(
            _catalogConflictViews(
              conflicts: conflicts,
              local: local.catalog.catalog,
              remote: remote.catalog.catalog,
            ),
          );
        }

        final safePass = mergeCatalog(
          base: base.catalog,
          remote: remote.catalog,
          pending: pending.operations
              .where((operation) => !conflictIds.contains(operation.entryId))
              .toList(growable: false),
        );
        if (safePass is! MergedCatalog) {
          throw const SboxException(
            SboxErrorCode.syncConflict,
            '非冲突 Catalog 操作无法重放',
          );
        }
        final entries = <String, CatalogEntry>{
          for (final entry in safePass.entries) entry.entryId: entry,
        };
        final tombstones = <String, CatalogTombstone>{
          for (final tombstone in safePass.tombstones)
            tombstone.entryId: tombstone,
        };
        final baseCatalog = base.catalog.catalog;
        final localCatalog = local.catalog.catalog;
        final remoteCatalog = remote.catalog.catalog;
        for (final conflict in conflicts) {
          if (resolutions[conflict.entryId] ==
              CatalogConflictResolution.keepRemote) {
            continue;
          }
          final localEntry = _entryOrNull(localCatalog, conflict.entryId);
          final localTombstone = _tombstoneOrNull(
            localCatalog,
            conflict.entryId,
          );
          final revision =
              _highestRevisionFor(
                conflict.entryId,
                baseCatalog,
                localCatalog,
                remoteCatalog,
              ) +
              1;
          if (localEntry != null) {
            tombstones.remove(conflict.entryId);
            entries[conflict.entryId] = CatalogEntry(
              entryId: localEntry.entryId,
              revision: revision,
              title: localEntry.title,
              description: localEntry.description,
              originalName: localEntry.originalName,
              mediaType: localEntry.mediaType,
              payload: localEntry.payload,
              tags: localEntry.tags,
              createdAt: localEntry.createdAt,
              updatedAt: localEntry.updatedAt,
            );
          } else if (localTombstone != null) {
            entries.remove(conflict.entryId);
            tombstones[conflict.entryId] = CatalogTombstone(
              entryId: conflict.entryId,
              revision: revision,
              deletedAt: localTombstone.deletedAt,
            );
          } else {
            throw const SboxException(
              SboxErrorCode.syncConflict,
              '本地冲突条目不存在，无法应用选择',
            );
          }
        }
        final resolvedEntries = entries.values.toList()
          ..sort((left, right) => left.entryId.compareTo(right.entryId));
        final resolvedTombstones = tombstones.values.toList()
          ..sort((left, right) => left.entryId.compareTo(right.entryId));
        merged = MergedCatalog(
          entries: List<CatalogEntry>.unmodifiable(resolvedEntries),
          tombstones: List<CatalogTombstone>.unmodifiable(resolvedTombstones),
          nextGeneration: remote.catalog.catalog.generation + 1,
        );
      }

      final remoteCatalog = remote.catalog.catalog;
      final now = _utcSeconds(DateTime.now());
      final catalog = SboxCatalog(
        catalogId: remoteCatalog.catalogId,
        generation: merged.nextGeneration,
        previousCatalogSha256: hexLower(remote.containerSha256),
        recipientKeyId: remoteCatalog.recipientKeyId,
        signerKeyId: remoteCatalog.signerKeyId,
        createdAt: remoteCatalog.createdAt,
        updatedAt: now,
        entries: merged.entries,
        tombstones: merged.tombstones,
      );
      final encrypted = await createCatalogContainerWithMnemonic(
        catalog: catalog,
        mnemonic: EphemeralMnemonic.fromString(mnemonic),
        expectedIdentity: identity,
      );
      final store = await FileSystemLocalCipherStore.open(
        Directory(localCipherRoot),
      );
      final staged = await store.createStaging(SourcePath('catalog.sbox'));
      try {
        final sink = staged.openSink();
        sink.add(encrypted.bytes);
        await sink.flush();
        await sink.close();
        await store.replaceDownloadedCatalog(
          staged,
          expectedLength: encrypted.bytes.length,
          expectedSha256: encrypted.sha256,
          expectedCurrentSha256: expectedCurrentCatalogSha256,
        );
      } on Object {
        await staged.discard();
        rethrow;
      }
      return CatalogMergedTaskResult(
        catalogId: catalog.catalogId,
        generation: catalog.generation,
        encryptedCatalogSha256: encrypted.sha256,
        catalogPayloadsJson: catalog.entries
            .map((entry) => entry.payload.toJson())
            .toList(growable: false),
        entries: _viewEntries(catalog),
      );
    }, debugName: 'sbox-resolve-catalog-once');
  }

  static Future<DecryptFileTaskResult> decryptCatalogEntry({
    required String catalogPath,
    required String entryId,
    required String localCipherRoot,
    required String temporaryPlaintextRoot,
    required List<String> cipherRoots,
    required String mnemonic,
    required Map<String, Object?> publicIdentityJson,
    String? expectedCatalogId,
  }) {
    return _runOneShot(() async {
      final identity = PublicIdentityRecord.fromJson(publicIdentityJson)
          .identity;
      final catalogBytes = await File(catalogPath).readAsBytes();
      final opened = await openCatalogContainerWithMnemonic(
        container: catalogBytes,
        mnemonic: EphemeralMnemonic.fromString(mnemonic),
        expectedIdentity: identity,
        control: JobControl(),
        expectedCatalogId: expectedCatalogId,
      );
      final store = await FileSystemLocalCipherStore.open(
        Directory(localCipherRoot),
      );
      final temporary = await ManagedTemporaryPlaintextStore.open(
        root: Directory(temporaryPlaintextRoot),
        cipherRoots: cipherRoots.map(Directory.new),
      );
      final verified = await multipart.decryptCatalogEntry(
        entry: opened.catalog.entryById(entryId),
        cipherStore: store,
        plaintextStore: temporary,
        mnemonic: EphemeralMnemonic.fromString(mnemonic),
        expectedIdentity: identity,
        control: JobControl(),
      );
      return DecryptFileTaskResult(
        plaintextPath: verified.file.path,
        originalName: verified.metadata.metadata.originalName,
        plaintextLength: verified.metadata.plaintextLength,
      );
    }, debugName: 'sbox-decrypt-catalog-entry-once');
  }

  static Future<DecryptFileTaskResult> decryptStandalone({
    required String sboxPath,
    required String temporaryPlaintextRoot,
    required List<String> cipherRoots,
    required String mnemonic,
    required Map<String, Object?> publicIdentityJson,
    required Uint8List expectedCiphertextSha256,
  }) {
    return _runOneShot(() async {
      final identity = PublicIdentityRecord.fromJson(publicIdentityJson)
          .identity;
      final temporary = await ManagedTemporaryPlaintextStore.open(
        root: Directory(temporaryPlaintextRoot),
        cipherRoots: cipherRoots.map(Directory.new),
      );
      final staged = await temporary.createForJob(JobId.random());
      final handle = await File(sboxPath).open();
      try {
        if (!constantTimeBytesEqual(
          await sha256RandomAccessFile(handle),
          expectedCiphertextSha256,
        )) {
          throw const SboxException(
            SboxErrorCode.remoteChanged,
            '所选 SBOX 在检查后发生变化',
          );
        }
        final verified = await decryptSingleContainerWithMnemonic(
          input: _readHandle(handle),
          stagedPlaintext: staged.openSink(),
          mnemonic: EphemeralMnemonic.fromString(mnemonic),
          expectedIdentity: identity,
          control: JobControl(),
        );
        staged.accept(verified);
        final published = await temporary.publishVerified(staged);
        return DecryptFileTaskResult(
          plaintextPath: published.file.path,
          originalName: verified.metadata.originalName,
          plaintextLength: verified.plaintextLength,
        );
      } on Object {
        await staged.discard();
        rethrow;
      } finally {
        await handle.close();
      }
    }, debugName: 'sbox-decrypt-once');
  }

  static Map<String, Object?> capabilitiesToMessage(
    SourceCapabilities capabilities,
  ) => <String, Object?>{
    'can_read': capabilities.canRead,
    'can_write': capabilities.canWrite,
    'can_delete': capabilities.canDelete,
    'conditional_write': capabilities.conditionalWrite,
    'history': capabilities.history,
    'max_object_bytes': capabilities.maxObjectBytes?.toString(),
    'max_request_body_bytes': capabilities.maxRequestBodyBytes?.toString(),
    'upload_encoding': capabilities.uploadEncoding.name,
    'max_parallel': capabilities.maxParallelObjectTransfers,
    'streaming': capabilities.supportsStreamingDownload,
    'resumable': capabilities.supportsResumableObjectDownload,
  };

  static SourceCapabilities _capabilitiesFromMessage(
    Map<String, Object?> value,
  ) => SourceCapabilities(
    canRead: value['can_read']! as bool,
    canWrite: value['can_write']! as bool,
    canDelete: value['can_delete']! as bool,
    conditionalWrite: value['conditional_write']! as bool,
    history: value['history']! as bool,
    maxObjectBytes: value['max_object_bytes'] == null
        ? null
        : BigInt.parse(value['max_object_bytes']! as String),
    maxRequestBodyBytes: value['max_request_body_bytes'] == null
        ? null
        : BigInt.parse(value['max_request_body_bytes']! as String),
    uploadEncoding: UploadEncoding.values.byName(
      value['upload_encoding']! as String,
    ),
    maxParallelObjectTransfers: value['max_parallel']! as int,
    supportsStreamingDownload: value['streaming']! as bool,
    supportsResumableObjectDownload: value['resumable']! as bool,
  );

  static String _utcSeconds(DateTime value) =>
      value.toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z');

  static Future<T> _runOneShot<T>(
    Future<T> Function() computation, {
    required String debugName,
  }) async {
    final resultPort = ReceivePort('$debugName-result');
    final exitPort = ReceivePort('$debugName-exit');
    final job = _ActiveCryptoIsolate(resultPort, exitPort);
    _active.add(job);
    try {
      final isolate = await Isolate.spawn<_CryptoIsolateRequest<T>>(
        _cryptoIsolateEntry<T>,
        _CryptoIsolateRequest<T>(resultPort.sendPort, computation),
        debugName: debugName,
        errorsAreFatal: true,
        onError: resultPort.sendPort,
        onExit: exitPort.sendPort,
      );
      job.attach(isolate);
      return await job.result.then((value) => value as T);
    } finally {
      _active.remove(job);
      job.dispose();
    }
  }
}

Stream<List<int>> _readHandle(RandomAccessFile handle) async* {
  await handle.setPosition(0);
  while (true) {
    final chunk = await handle.read(1024 * 1024);
    if (chunk.isEmpty) return;
    yield chunk;
  }
}

List<CatalogEntryViewData> _viewEntries(SboxCatalog catalog) => catalog.entries
    .map(
      (entry) => CatalogEntryViewData(
        entryId: entry.entryId,
        revision: entry.revision,
        title: entry.title,
        description: entry.description,
        originalName: entry.originalName,
        mediaType: entry.mediaType,
        plaintextSize: entry.payload.plaintextSize.toString(),
        updatedAt: entry.updatedAt,
        tags: entry.tags,
        partCount: entry.payload.parts.length,
      ),
    )
    .toList(growable: false);

CatalogEntry? _entryOrNull(SboxCatalog catalog, String entryId) {
  for (final entry in catalog.entries) {
    if (entry.entryId == entryId) return entry;
  }
  return null;
}

CatalogTombstone? _tombstoneOrNull(SboxCatalog catalog, String entryId) {
  for (final tombstone in catalog.tombstones) {
    if (tombstone.entryId == entryId) return tombstone;
  }
  return null;
}

int _highestRevisionFor(
  String entryId,
  SboxCatalog base,
  SboxCatalog local,
  SboxCatalog remote,
) {
  var highest = 0;
  for (final catalog in <SboxCatalog>[base, local, remote]) {
    final entry = _entryOrNull(catalog, entryId);
    final tombstone = _tombstoneOrNull(catalog, entryId);
    if (entry != null && entry.revision > highest) highest = entry.revision;
    if (tombstone != null && tombstone.revision > highest) {
      highest = tombstone.revision;
    }
  }
  return highest;
}

List<CatalogConflictViewData> _catalogConflictViews({
  required List<CatalogMergeConflict> conflicts,
  required SboxCatalog local,
  required SboxCatalog remote,
}) => conflicts
    .map((conflict) {
      final localEntry = _entryOrNull(local, conflict.entryId);
      final remoteEntry = _entryOrNull(remote, conflict.entryId);
      return CatalogConflictViewData(
        entryId: conflict.entryId,
        reason: conflict.reason,
        localTitle: localEntry?.title ?? '本地删除',
        remoteTitle: remoteEntry?.title,
        localPayloadSha256: localEntry?.payload.plaintextSha256 ?? 'deleted',
        remotePayloadSha256: remoteEntry?.payload.plaintextSha256,
        localPartCount: localEntry?.payload.parts.length ?? 0,
        remotePartCount: remoteEntry?.payload.parts.length,
        baseRevision: conflict.baseRevision,
        remoteRevision: conflict.remoteRevision,
      );
    })
    .toList(growable: false);

final class _PendingOperations {
  const _PendingOperations({required this.operations, required this.conflicts});

  final List<CatalogOperation> operations;
  final List<CatalogConflictViewData> conflicts;
}

_PendingOperations _derivePendingOperations(
  SboxCatalog base,
  SboxCatalog local,
) {
  if (base.catalogId != local.catalogId ||
      base.recipientKeyId != local.recipientKeyId ||
      base.signerKeyId != local.signerKeyId ||
      base.createdAt != local.createdAt ||
      local.generation <= base.generation) {
    throw const SboxException(
      SboxErrorCode.catalogFork,
      '待同步 Catalog 与共同基线不属于同一条历史',
    );
  }
  final baseEntries = <String, CatalogEntry>{
    for (final entry in base.entries) entry.entryId: entry,
  };
  final localEntries = <String, CatalogEntry>{
    for (final entry in local.entries) entry.entryId: entry,
  };
  final baseTombstones = <String, CatalogTombstone>{
    for (final tombstone in base.tombstones) tombstone.entryId: tombstone,
  };
  final localTombstones = <String, CatalogTombstone>{
    for (final tombstone in local.tombstones) tombstone.entryId: tombstone,
  };
  final operations = <CatalogOperation>[];
  final conflicts = <CatalogConflictViewData>[];
  for (final baseEntry in base.entries) {
    final localEntry = localEntries[baseEntry.entryId];
    final localTombstone = localTombstones[baseEntry.entryId];
    if (localEntry != null) {
      if (_sameJson(baseEntry.toJson(), localEntry.toJson())) continue;
      if (_isMetadataOnlyUpdate(baseEntry, localEntry)) {
        operations.add(
          UpdateCatalogMetadata(
            entryId: localEntry.entryId,
            title: localEntry.title,
            description: localEntry.description,
            tags: localEntry.tags,
            updatedAt: localEntry.updatedAt,
          ),
        );
      } else {
        conflicts.add(
          _localCatalogConflict(
            baseEntry: baseEntry,
            localEntry: localEntry,
            reason: '待同步目录对既有条目执行了不受支持的负载或结构修改',
          ),
        );
      }
      continue;
    }
    if (localTombstone != null &&
        localTombstone.revision > baseEntry.revision) {
      operations.add(
        DeleteCatalogEntry(
          entryId: baseEntry.entryId,
          deletedAt: localTombstone.deletedAt,
        ),
      );
    } else {
      conflicts.add(
        _localCatalogConflict(
          baseEntry: baseEntry,
          localEntry: null,
          reason: localTombstone == null
              ? '待同步目录无墓碑地移除了既有条目'
              : '待同步目录的删除墓碑 revision 无效',
        ),
      );
    }
  }

  for (final baseTombstone in base.tombstones) {
    final localTombstone = localTombstones[baseTombstone.entryId];
    if (localTombstone == null ||
        !_sameJson(baseTombstone.toJson(), localTombstone.toJson())) {
      conflicts.add(
        CatalogConflictViewData(
          entryId: baseTombstone.entryId,
          reason: '待同步目录改写或移除了共同基线墓碑',
          localTitle: '本地删除记录',
          remoteTitle: '共同基线删除记录',
          localPayloadSha256: 'deleted',
          remotePayloadSha256: null,
          localPartCount: 0,
          remotePartCount: 0,
          baseRevision: baseTombstone.revision,
          remoteRevision: baseTombstone.revision,
        ),
      );
    }
  }

  for (final localEntry in local.entries) {
    if (baseEntries.containsKey(localEntry.entryId)) continue;
    if (baseTombstones.containsKey(localEntry.entryId)) {
      conflicts.add(
        CatalogConflictViewData(
          entryId: localEntry.entryId,
          reason: '待同步目录试图复活共同基线中已删除的条目',
          localTitle: localEntry.title,
          remoteTitle: '共同基线删除记录',
          localPayloadSha256: localEntry.payload.plaintextSha256,
          remotePayloadSha256: null,
          localPartCount: localEntry.payload.parts.length,
          remotePartCount: 0,
          baseRevision: baseTombstones[localEntry.entryId]!.revision,
          remoteRevision: baseTombstones[localEntry.entryId]!.revision,
        ),
      );
    } else {
      operations.add(CreateCatalogEntry(localEntry));
    }
  }

  for (final localTombstone in local.tombstones) {
    if (baseTombstones.containsKey(localTombstone.entryId) ||
        baseEntries.containsKey(localTombstone.entryId)) {
      continue;
    }
    conflicts.add(
      CatalogConflictViewData(
        entryId: localTombstone.entryId,
        reason: '待同步目录包含共同基线中不存在的删除墓碑，无法安全重放',
        localTitle: '本地删除记录',
        remoteTitle: null,
        localPayloadSha256: 'deleted',
        remotePayloadSha256: null,
        localPartCount: 0,
        remotePartCount: null,
        baseRevision: null,
        remoteRevision: null,
      ),
    );
  }
  return _PendingOperations(operations: operations, conflicts: conflicts);
}

bool _isMetadataOnlyUpdate(CatalogEntry base, CatalogEntry local) =>
    local.entryId == base.entryId &&
    local.revision > base.revision &&
    local.originalName == base.originalName &&
    local.mediaType == base.mediaType &&
    local.createdAt == base.createdAt &&
    local.updatedAt.compareTo(base.updatedAt) >= 0 &&
    _sameJson(base.payload.toJson(), local.payload.toJson());

CatalogConflictViewData _localCatalogConflict({
  required CatalogEntry baseEntry,
  required CatalogEntry? localEntry,
  required String reason,
}) => CatalogConflictViewData(
  entryId: baseEntry.entryId,
  reason: reason,
  localTitle: localEntry?.title ?? '本地删除',
  remoteTitle: baseEntry.title,
  localPayloadSha256: localEntry?.payload.plaintextSha256 ?? 'deleted',
  remotePayloadSha256: baseEntry.payload.plaintextSha256,
  localPartCount: localEntry?.payload.parts.length ?? 0,
  remotePartCount: baseEntry.payload.parts.length,
  baseRevision: baseEntry.revision,
  remoteRevision: baseEntry.revision,
);

bool _sameJson(Map<String, Object?> left, Map<String, Object?> right) =>
    constantTimeBytesEqual(
      CatalogCanonicalJson.encodeUtf8(left),
      CatalogCanonicalJson.encodeUtf8(right),
    );

final class _CryptoIsolateRequest<T> {
  const _CryptoIsolateRequest(this.resultPort, this.computation);

  final SendPort resultPort;
  final Future<T> Function() computation;
}

Future<void> _cryptoIsolateEntry<T>(_CryptoIsolateRequest<T> request) async {
  try {
    final result = await request.computation();
    Isolate.exit(request.resultPort, <Object?>['success', result]);
  } on Object catch (error, stack) {
    Isolate.exit(request.resultPort, <Object?>['failure', error, '$stack']);
  }
}

final class _ActiveCryptoIsolate {
  _ActiveCryptoIsolate(this._resultPort, this._exitPort) {
    _resultSubscription = _resultPort.listen(_receiveResult);
    _exitSubscription = _exitPort.listen((_) {
      Future<void>.delayed(Duration.zero, () {
        if (!_result.isCompleted) {
          _result.completeError(
            const SboxException(
              SboxErrorCode.cancelled,
              '敏感任务所在的独立 Isolate 已终止',
            ),
          );
        }
      });
    });
  }

  final ReceivePort _resultPort;
  final ReceivePort _exitPort;
  final Completer<Object?> _result = Completer<Object?>();
  late final StreamSubscription<Object?> _resultSubscription;
  late final StreamSubscription<Object?> _exitSubscription;
  Isolate? _isolate;
  bool _cancelled = false;

  Future<Object?> get result => _result.future;

  void attach(Isolate isolate) {
    _isolate = isolate;
    if (_cancelled) {
      isolate.kill(priority: Isolate.immediate);
      scheduleMicrotask(_completeCancelled);
    }
  }

  void cancel() {
    _cancelled = true;
    final isolate = _isolate;
    if (isolate == null) {
      return;
    }
    isolate.kill(priority: Isolate.immediate);
    _completeCancelled();
  }

  void _completeCancelled() {
    if (!_result.isCompleted) {
      _result.completeError(
        const SboxException(SboxErrorCode.cancelled, '敏感任务已取消'),
      );
    }
  }

  void _receiveResult(Object? message) {
    if (_result.isCompleted) {
      return;
    }
    if (message is List<Object?> && message.isNotEmpty) {
      if (message.first == 'success' && message.length == 2) {
        _result.complete(message[1]);
        return;
      }
      if (message.first == 'failure' && message.length == 3) {
        final error = message[1];
        _result.completeError(
          error is Object ? error : StateError('Crypto isolate failed'),
          StackTrace.fromString(message[2] as String),
        );
        return;
      }
      // VM onError messages use [errorString, stackString].
      if (message.length == 2 && message[0] is String && message[1] is String) {
        _result.completeError(
          RemoteError(message[0]! as String, message[1]! as String),
        );
        return;
      }
    }
    _result.completeError(StateError('Invalid crypto isolate response'));
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _resultSubscription.cancel();
    _exitSubscription.cancel();
    _resultPort.close();
    _exitPort.close();
  }
}
