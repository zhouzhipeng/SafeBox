import 'dart:io';
import 'dart:typed_data';

import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/catalog/catalog_models.dart';
import 'package:safebox/sbox/engine/crypto_task_runner.dart';
import 'package:safebox/sbox/errors.dart';
import 'package:safebox/sbox/source/data_source.dart';
import 'package:test/test.dart';

const _vectorMnemonic =
    'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

void main() {
  test(
    'one-shot identity isolate returns only the public identity vector',
    () async {
      final result = await CryptoTaskRunner.derivePublicIdentity(
        _vectorMnemonic,
      );

      expect(
        result.publicIdentityJson['recipient_key_id'],
        '9549c41744d3b469c512aa2c845677940937fd20685220fb0eb00f15082b04ae',
      );
      expect(result.publicIdentityJson.keys, isNot(contains('private_key')));
      expect(result.publicIdentityJson.keys, isNot(contains('mnemonic')));
      expect(result.pCandidateCount, 2600);
      expect(result.qCandidateCount, 197);
    },
  );

  test(
    'public-key-only encryption creates and appends Catalog without a mnemonic',
    () async {
      final temporary = await Directory.systemTemp.createTemp('sbox-public-');
      addTearDown(() => temporary.delete(recursive: true));
      final cipherRoot = Directory(
        '${temporary.path}${Platform.pathSeparator}cipher',
      );
      final identity = await CryptoTaskRunner.derivePublicIdentity(
        _vectorMnemonic,
      );

      final first = await CryptoTaskRunner.encryptAndCommitCatalogPublic(
        text: 'public-key-only first\n',
        localCipherRoot: cipherRoot.path,
        publicIdentityJson: identity.publicIdentityJson,
        contentKind: 2,
        originalName: 'first.txt',
        mediaType: 'text/plain; charset=utf-8',
        title: 'First',
        description: '',
        tags: const <String>[],
        capabilitiesJson: CryptoTaskRunner.capabilitiesToMessage(
          SourceCapabilities.localReadWrite,
        ),
      );
      final catalogPath =
          '${cipherRoot.path}${Platform.pathSeparator}catalog.sbox';
      final unlocked = await CryptoTaskRunner.unlockCatalog(
        catalogPath: catalogPath,
        mnemonic: _vectorMnemonic,
        publicIdentityJson: identity.publicIdentityJson,
        expectedCatalogId: first.catalogId,
      );
      final second = await CryptoTaskRunner.encryptAndCommitCatalogPublic(
        text: 'public-key-only second\n',
        localCipherRoot: cipherRoot.path,
        publicIdentityJson: identity.publicIdentityJson,
        catalogSnapshotJson: unlocked.catalogJson,
        previousCatalogSha256: hexLower(first.encryptedCatalogSha256),
        contentKind: 2,
        originalName: 'second.txt',
        mediaType: 'text/plain; charset=utf-8',
        title: 'Second',
        description: '',
        tags: const <String>[],
        capabilitiesJson: CryptoTaskRunner.capabilitiesToMessage(
          SourceCapabilities.localReadWrite,
        ),
      );

      expect(first.generation, 1);
      expect(second.generation, 2);
      expect(second.catalogJson, isNotNull);
      expect(second.catalogPayloadsJson, hasLength(2));
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test('application task round trip commits Catalog and publishes plaintext', () async {
    final temporary = await Directory.systemTemp.createTemp('sbox-task-');
    addTearDown(() => temporary.delete(recursive: true));
    final cipherRoot = Directory(
      '${temporary.path}${Platform.pathSeparator}cipher',
    );
    final plaintextRoot = Directory(
      '${temporary.path}${Platform.pathSeparator}plain',
    );
    final identity = await CryptoTaskRunner.derivePublicIdentity(
      _vectorMnemonic,
    );

    final committed = await CryptoTaskRunner.encryptAndCommitCatalog(
      text: 'SafeBox application round trip\n',
      localCipherRoot: cipherRoot.path,
      publicIdentityJson: identity.publicIdentityJson,
      mnemonic: _vectorMnemonic,
      contentKind: 2,
      originalName: 'note.txt',
      mediaType: 'text/plain; charset=utf-8',
      title: 'Application round trip',
      description: 'verified test entry',
      tags: const <String>['test'],
      capabilitiesJson: CryptoTaskRunner.capabilitiesToMessage(
        SourceCapabilities.localReadWrite,
      ),
    );
    final catalog = File(
      '${cipherRoot.path}${Platform.pathSeparator}catalog.sbox',
    );
    expect(await catalog.exists(), isTrue);

    final view = await CryptoTaskRunner.unlockCatalog(
      catalogPath: catalog.path,
      mnemonic: _vectorMnemonic,
      publicIdentityJson: identity.publicIdentityJson,
      expectedCatalogId: committed.catalogId,
      expectedCiphertextSha256: committed.encryptedCatalogSha256,
    );
    expect(view.generation, 1);
    expect(view.entries.single.title, 'Application round trip');
    expect(view.entries.single.revision, 1);
    expect(view.entries.single.originalName, 'note.txt');

    final wrongCatalogHash = Uint8List.fromList(
      committed.encryptedCatalogSha256,
    )..[0] ^= 1;
    await expectLater(
      CryptoTaskRunner.unlockCatalog(
        catalogPath: catalog.path,
        mnemonic: _vectorMnemonic,
        publicIdentityJson: identity.publicIdentityJson,
        expectedCatalogId: committed.catalogId,
        expectedCiphertextSha256: wrongCatalogHash,
      ),
      throwsA(
        isA<SboxException>().having(
          (error) => error.code,
          'code',
          SboxErrorCode.remoteChanged,
        ),
      ),
    );

    final updated = await CryptoTaskRunner.updateCatalogMetadata(
      localCipherRoot: cipherRoot.path,
      mnemonic: _vectorMnemonic,
      publicIdentityJson: identity.publicIdentityJson,
      expectedCatalogId: committed.catalogId,
      expectedCatalogSha256: committed.encryptedCatalogSha256,
      entryId: committed.entryId,
      title: 'Updated title',
      description: 'updated without rewriting payload',
      tags: const <String>['catalog', 'test'],
    );
    expect(updated.generation, 2);
    expect(updated.entries.single.title, 'Updated title');
    expect(updated.entries.single.revision, 2);
    expect(updated.catalogPayloadsJson.single, committed.catalogPayloadJson);

    final decrypted = await CryptoTaskRunner.decryptCatalogEntry(
      catalogPath: catalog.path,
      entryId: committed.entryId,
      localCipherRoot: cipherRoot.path,
      temporaryPlaintextRoot: plaintextRoot.path,
      cipherRoots: <String>[cipherRoot.path],
      mnemonic: _vectorMnemonic,
      publicIdentityJson: identity.publicIdentityJson,
      expectedCatalogId: committed.catalogId,
    );
    expect(
      await File(decrypted.plaintextPath).readAsString(),
      'SafeBox application round trip\n',
    );
    expect(decrypted.originalName, 'note.txt');

    final payload = CatalogPayload.fromJson(committed.catalogPayloadJson);
    final standalone = File(
      '${cipherRoot.path}${Platform.pathSeparator}'
      '${payload.parts.single.objectPath.replaceAll('/', Platform.pathSeparator)}',
    );
    final expectedHash = decodeHex(payload.parts.single.sboxSha256);
    final standaloneResult = await CryptoTaskRunner.decryptStandalone(
      sboxPath: standalone.path,
      temporaryPlaintextRoot: plaintextRoot.path,
      cipherRoots: <String>[cipherRoot.path],
      mnemonic: _vectorMnemonic,
      publicIdentityJson: identity.publicIdentityJson,
      expectedCiphertextSha256: expectedHash,
    );
    expect(
      await File(standaloneResult.plaintextPath).readAsString(),
      'SafeBox application round trip\n',
    );
    final tampered = await standalone.readAsBytes();
    tampered[tampered.length - 1] ^= 1;
    await standalone.writeAsBytes(tampered, flush: true);
    await expectLater(
      CryptoTaskRunner.decryptStandalone(
        sboxPath: standalone.path,
        temporaryPlaintextRoot: plaintextRoot.path,
        cipherRoots: <String>[cipherRoot.path],
        mnemonic: _vectorMnemonic,
        publicIdentityJson: identity.publicIdentityJson,
        expectedCiphertextSha256: expectedHash,
      ),
      throwsA(anything),
    );

    final deleted = await CryptoTaskRunner.deleteCatalogEntry(
      localCipherRoot: cipherRoot.path,
      mnemonic: _vectorMnemonic,
      publicIdentityJson: identity.publicIdentityJson,
      expectedCatalogId: committed.catalogId,
      expectedCatalogSha256: updated.encryptedCatalogSha256,
      entryId: committed.entryId,
    );
    expect(deleted.generation, 3);
    expect(deleted.entries, isEmpty);
    expect(deleted.catalogPayloadsJson, isEmpty);
    expect(await standalone.exists(), isTrue);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test(
    'cancelAll terminates a sensitive isolate instead of resuming it',
    () async {
      final future = CryptoTaskRunner.derivePublicIdentity(_vectorMnemonic);
      final expectation = expectLater(future, throwsA(anything));
      CryptoTaskRunner.cancelAll();

      await expectation;
    },
  );

  test(
    'pending Catalog creates are three-way merged after a remote fork',
    () async {
      final temporary = await Directory.systemTemp.createTemp('sbox-merge-');
      addTearDown(() => temporary.delete(recursive: true));
      final baseRoot = Directory(
        '${temporary.path}${Platform.pathSeparator}base',
      );
      final localRoot = Directory(
        '${temporary.path}${Platform.pathSeparator}local',
      );
      final remoteRoot = Directory(
        '${temporary.path}${Platform.pathSeparator}remote',
      );
      final deleteLocalRoot = Directory(
        '${temporary.path}${Platform.pathSeparator}delete-local',
      );
      final deleteRemoteRoot = Directory(
        '${temporary.path}${Platform.pathSeparator}delete-remote',
      );
      final identity = await CryptoTaskRunner.derivePublicIdentity(
        _vectorMnemonic,
      );
      final capabilities = CryptoTaskRunner.capabilitiesToMessage(
        SourceCapabilities.localReadWrite,
      );

      final base = await CryptoTaskRunner.encryptAndCommitCatalog(
        text: 'base',
        localCipherRoot: baseRoot.path,
        publicIdentityJson: identity.publicIdentityJson,
        mnemonic: _vectorMnemonic,
        contentKind: 2,
        originalName: 'base.txt',
        mediaType: 'text/plain; charset=utf-8',
        title: 'Base',
        description: '',
        tags: const <String>[],
        capabilitiesJson: capabilities,
      );
      await _copyCipherRoot(baseRoot, localRoot);
      await _copyCipherRoot(baseRoot, remoteRoot);

      final localMetadata = await CryptoTaskRunner.updateCatalogMetadata(
        localCipherRoot: localRoot.path,
        mnemonic: _vectorMnemonic,
        publicIdentityJson: identity.publicIdentityJson,
        expectedCatalogId: base.catalogId,
        expectedCatalogSha256: base.encryptedCatalogSha256,
        entryId: base.entryId,
        title: 'Base with local metadata',
        description: 'local metadata edit',
        tags: const <String>['local'],
      );
      final local = await CryptoTaskRunner.encryptAndCommitCatalog(
        text: 'local',
        localCipherRoot: localRoot.path,
        publicIdentityJson: identity.publicIdentityJson,
        mnemonic: _vectorMnemonic,
        contentKind: 2,
        originalName: 'local.txt',
        mediaType: 'text/plain; charset=utf-8',
        title: 'Local create',
        description: '',
        tags: const <String>[],
        capabilitiesJson: capabilities,
      );
      await CryptoTaskRunner.encryptAndCommitCatalog(
        text: 'remote',
        localCipherRoot: remoteRoot.path,
        publicIdentityJson: identity.publicIdentityJson,
        mnemonic: _vectorMnemonic,
        contentKind: 2,
        originalName: 'remote.txt',
        mediaType: 'text/plain; charset=utf-8',
        title: 'Remote create',
        description: '',
        tags: const <String>[],
        capabilitiesJson: capabilities,
      );

      final merge = await CryptoTaskRunner.mergePendingCatalogAfterConflict(
        baseCatalogPath:
            '${baseRoot.path}${Platform.pathSeparator}catalog.sbox',
        localCatalogPath:
            '${localRoot.path}${Platform.pathSeparator}catalog.sbox',
        remoteCatalogPath:
            '${remoteRoot.path}${Platform.pathSeparator}catalog.sbox',
        localCipherRoot: localRoot.path,
        mnemonic: _vectorMnemonic,
        publicIdentityJson: identity.publicIdentityJson,
        expectedCurrentCatalogSha256: local.encryptedCatalogSha256,
      );
      expect(merge, isA<CatalogMergedTaskResult>());
      final merged = merge as CatalogMergedTaskResult;
      expect(merged.catalogId, base.catalogId);
      expect(merged.generation, 3);
      expect(
        merged.entries.map((entry) => entry.title),
        unorderedEquals(<String>[
          'Base with local metadata',
          'Local create',
          'Remote create',
        ]),
      );
      expect(merged.catalogPayloadsJson, hasLength(3));
      expect(
        merged.entries
            .singleWhere((entry) => entry.entryId == base.entryId)
            .revision,
        2,
      );
      expect(
        localMetadata.encryptedCatalogSha256,
        isNot(local.encryptedCatalogSha256),
      );

      await _copyCipherRoot(localRoot, deleteLocalRoot);
      await _copyCipherRoot(localRoot, deleteRemoteRoot);
      final deleted = await CryptoTaskRunner.deleteCatalogEntry(
        localCipherRoot: deleteLocalRoot.path,
        mnemonic: _vectorMnemonic,
        publicIdentityJson: identity.publicIdentityJson,
        expectedCatalogId: base.catalogId,
        expectedCatalogSha256: merged.encryptedCatalogSha256,
        entryId: base.entryId,
      );
      await CryptoTaskRunner.encryptAndCommitCatalog(
        text: 'remote after delete',
        localCipherRoot: deleteRemoteRoot.path,
        publicIdentityJson: identity.publicIdentityJson,
        mnemonic: _vectorMnemonic,
        contentKind: 2,
        originalName: 'remote-after-delete.txt',
        mediaType: 'text/plain; charset=utf-8',
        title: 'Remote create after delete',
        description: '',
        tags: const <String>[],
        capabilitiesJson: capabilities,
      );
      final deleteMerge =
          await CryptoTaskRunner.mergePendingCatalogAfterConflict(
            baseCatalogPath:
                '${localRoot.path}${Platform.pathSeparator}catalog.sbox',
            localCatalogPath:
                '${deleteLocalRoot.path}${Platform.pathSeparator}catalog.sbox',
            remoteCatalogPath:
                '${deleteRemoteRoot.path}${Platform.pathSeparator}catalog.sbox',
            localCipherRoot: deleteLocalRoot.path,
            mnemonic: _vectorMnemonic,
            publicIdentityJson: identity.publicIdentityJson,
            expectedCurrentCatalogSha256: deleted.encryptedCatalogSha256,
          );
      expect(deleteMerge, isA<CatalogMergedTaskResult>());
      final afterDelete = deleteMerge as CatalogMergedTaskResult;
      expect(afterDelete.generation, 5);
      expect(
        afterDelete.entries.map((entry) => entry.title),
        unorderedEquals(<String>[
          'Local create',
          'Remote create',
          'Remote create after delete',
        ]),
      );
      expect(
        afterDelete.entries.map((entry) => entry.entryId),
        isNot(contains(base.entryId)),
      );
    },
    timeout: const Timeout(Duration(seconds: 180)),
  );

  test(
    'same-entry conflicts require and apply an explicit local or remote choice',
    () async {
      final temporary = await Directory.systemTemp.createTemp('sbox-resolve-');
      addTearDown(() => temporary.delete(recursive: true));
      final baseRoot = Directory(
        '${temporary.path}${Platform.pathSeparator}base',
      );
      final localRoot = Directory(
        '${temporary.path}${Platform.pathSeparator}local',
      );
      final remoteChoiceRoot = Directory(
        '${temporary.path}${Platform.pathSeparator}local-remote-choice',
      );
      final remoteRoot = Directory(
        '${temporary.path}${Platform.pathSeparator}remote',
      );
      final identity = await CryptoTaskRunner.derivePublicIdentity(
        _vectorMnemonic,
      );
      final capabilities = CryptoTaskRunner.capabilitiesToMessage(
        SourceCapabilities.localReadWrite,
      );
      final base = await CryptoTaskRunner.encryptAndCommitCatalog(
        text: 'conflict',
        localCipherRoot: baseRoot.path,
        publicIdentityJson: identity.publicIdentityJson,
        mnemonic: _vectorMnemonic,
        contentKind: 2,
        originalName: 'conflict.txt',
        mediaType: 'text/plain; charset=utf-8',
        title: 'Base conflict entry',
        description: '',
        tags: const <String>[],
        capabilitiesJson: capabilities,
      );
      await _copyCipherRoot(baseRoot, localRoot);
      await _copyCipherRoot(baseRoot, remoteChoiceRoot);
      await _copyCipherRoot(baseRoot, remoteRoot);
      final local = await CryptoTaskRunner.updateCatalogMetadata(
        localCipherRoot: localRoot.path,
        mnemonic: _vectorMnemonic,
        publicIdentityJson: identity.publicIdentityJson,
        expectedCatalogId: base.catalogId,
        expectedCatalogSha256: base.encryptedCatalogSha256,
        entryId: base.entryId,
        title: 'Keep local',
        description: '',
        tags: const <String>[],
      );
      final localForRemoteChoice = await CryptoTaskRunner.updateCatalogMetadata(
        localCipherRoot: remoteChoiceRoot.path,
        mnemonic: _vectorMnemonic,
        publicIdentityJson: identity.publicIdentityJson,
        expectedCatalogId: base.catalogId,
        expectedCatalogSha256: base.encryptedCatalogSha256,
        entryId: base.entryId,
        title: 'Discard this local edit',
        description: '',
        tags: const <String>[],
      );
      await CryptoTaskRunner.updateCatalogMetadata(
        localCipherRoot: remoteRoot.path,
        mnemonic: _vectorMnemonic,
        publicIdentityJson: identity.publicIdentityJson,
        expectedCatalogId: base.catalogId,
        expectedCatalogSha256: base.encryptedCatalogSha256,
        entryId: base.entryId,
        title: 'Keep remote',
        description: '',
        tags: const <String>[],
      );

      final conflict = await CryptoTaskRunner.mergePendingCatalogAfterConflict(
        baseCatalogPath:
            '${baseRoot.path}${Platform.pathSeparator}catalog.sbox',
        localCatalogPath:
            '${localRoot.path}${Platform.pathSeparator}catalog.sbox',
        remoteCatalogPath:
            '${remoteRoot.path}${Platform.pathSeparator}catalog.sbox',
        localCipherRoot: localRoot.path,
        mnemonic: _vectorMnemonic,
        publicIdentityJson: identity.publicIdentityJson,
        expectedCurrentCatalogSha256: local.encryptedCatalogSha256,
      );
      expect(conflict, isA<CatalogConflictsTaskResult>());

      final keepLocal = await CryptoTaskRunner.resolvePendingCatalogConflicts(
        baseCatalogPath:
            '${baseRoot.path}${Platform.pathSeparator}catalog.sbox',
        localCatalogPath:
            '${localRoot.path}${Platform.pathSeparator}catalog.sbox',
        remoteCatalogPath:
            '${remoteRoot.path}${Platform.pathSeparator}catalog.sbox',
        localCipherRoot: localRoot.path,
        mnemonic: _vectorMnemonic,
        publicIdentityJson: identity.publicIdentityJson,
        expectedCurrentCatalogSha256: local.encryptedCatalogSha256,
        resolutions: <String, CatalogConflictResolution>{
          base.entryId: CatalogConflictResolution.keepLocal,
        },
      );
      expect(keepLocal, isA<CatalogMergedTaskResult>());
      final localResult = keepLocal as CatalogMergedTaskResult;
      expect(localResult.generation, 3);
      expect(localResult.entries.single.title, 'Keep local');
      expect(localResult.entries.single.revision, 3);

      final keepRemote = await CryptoTaskRunner.resolvePendingCatalogConflicts(
        baseCatalogPath:
            '${baseRoot.path}${Platform.pathSeparator}catalog.sbox',
        localCatalogPath:
            '${remoteChoiceRoot.path}${Platform.pathSeparator}catalog.sbox',
        remoteCatalogPath:
            '${remoteRoot.path}${Platform.pathSeparator}catalog.sbox',
        localCipherRoot: remoteChoiceRoot.path,
        mnemonic: _vectorMnemonic,
        publicIdentityJson: identity.publicIdentityJson,
        expectedCurrentCatalogSha256:
            localForRemoteChoice.encryptedCatalogSha256,
        resolutions: <String, CatalogConflictResolution>{
          base.entryId: CatalogConflictResolution.keepRemote,
        },
      );
      expect(keepRemote, isA<CatalogMergedTaskResult>());
      final remoteResult = keepRemote as CatalogMergedTaskResult;
      expect(remoteResult.generation, 3);
      expect(remoteResult.entries.single.title, 'Keep remote');
      expect(remoteResult.entries.single.revision, 2);
    },
    timeout: const Timeout(Duration(seconds: 180)),
  );
}

Future<void> _copyCipherRoot(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final relative = entity.path.substring(source.path.length + 1);
    if (relative.startsWith('.sbox-staging')) continue;
    final target = '${destination.path}${Platform.pathSeparator}$relative';
    if (entity is Directory) {
      await Directory(target).create(recursive: true);
    } else if (entity is File) {
      await File(target).parent.create(recursive: true);
      await entity.copy(target);
    }
  }
}
