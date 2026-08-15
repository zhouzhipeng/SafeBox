import 'dart:io';
import 'dart:typed_data';

import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/catalog/catalog_models.dart';
import 'package:safebox/sbox/catalog/catalog_signature.dart';
import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/engine/container_codec.dart';
import 'package:safebox/sbox/engine/job_control.dart';
import 'package:safebox/sbox/engine/multipart.dart';
import 'package:safebox/sbox/engine/multipart_decrypt.dart';
import 'package:safebox/sbox/engine/streaming_container.dart';
import 'package:safebox/sbox/identity/bip39_identity.dart';
import 'package:safebox/sbox/identity/ephemeral_mnemonic.dart';
import 'package:safebox/sbox/identity/rsa_models.dart';
import 'package:safebox/sbox/source/data_source.dart';
import 'package:safebox/sbox/source/source_path.dart';
import 'package:safebox/sbox/storage/local_cipher_store.dart';
import 'package:safebox/sbox/storage/temporary_plaintext_store.dart';
import 'package:test/test.dart';

void main() {
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon about';
  late EphemeralIdentity identity;
  late Directory testRoot;
  late Directory cipherRoot;
  late Directory plaintextRoot;

  setUpAll(() async {
    identity = await SboxIdentityDeriver().deriveIdentity(mnemonic);
    testRoot = await Directory.systemTemp.createTemp('safebox-storage-test-');
    cipherRoot = Directory('${testRoot.path}/cipher');
    plaintextRoot = Directory('${testRoot.path}/plaintext');
  });

  tearDownAll(() async {
    identity.disposeControlledSecrets();
    await testRoot.delete(recursive: true);
  });

  test('default 16 MiB boundary and upper-bound arithmetic are exact', () {
    final exact = MultipartPlanner.plan(
      logicalLength: 16 * 1024 * 1024,
      target: SourceCapabilities.localReadWrite,
    );
    final over = MultipartPlanner.plan(
      logicalLength: 16 * 1024 * 1024 + 1,
      target: SourceCapabilities.localReadWrite,
    );
    expect(exact.parts, hasLength(1));
    expect(over.parts, hasLength(2));
    expect(over.parts[0].length, 16 * 1024 * 1024);
    expect(over.parts[1].length, 1);
    expect(
      MultipartPlanner.sboxSizeUpperBound(BigInt.from(16 * 1024 * 1024)),
      BigInt.from(16 * 1024 * 1024 + 4670 + 29 * 4),
    );
  });

  test(
    '1 MiB multipart vector encrypts complete independent SBOX parts',
    () async {
      final store = await FileSystemLocalCipherStore.open(cipherRoot);
      final data = <int>[
        ...List<int>.filled(1024 * 1024, 0x61),
        ...List<int>.filled(1024 * 1024, 0x62),
        0x71,
      ];
      final prepared = await encryptLogicalFile(
        input: MemoryReadableInputRef(data),
        inputLength: data.length,
        target: SourceCapabilities.localReadWrite,
        cipherStore: store,
        options: EncryptOptions(
          recipient: identity.publicIdentity,
          contentKind: SboxContentKind.file,
          originalName: 'vector.bin',
          mediaType: 'application/octet-stream',
        ),
        control: JobControl(),
        targetPartPlaintextSize: 1024 * 1024,
      );

      final payload = prepared.catalogPayload;
      expect(payload.parts, hasLength(3));
      expect(payload.partPlaintextSize, BigInt.from(1024 * 1024));
      expect(
        payload.plaintextSha256,
        '307ac063f271573ef5ae38cf78be6e1bab447e878772e11b25633f5e6a7a48fc',
      );
      expect(payload.parts.map((part) => part.plaintextSha256), <String>[
        '9bc1b2a288b26af7257a36277ae3816a7d4f16e89c1e7e77d0a5c48bad62b360',
        'e56ec8dc1862be6c09c53620cbc0f00f639de2a51c882745fbbc4e144714b3c2',
        '8e35c2cd3bf6641bdb0e2050b76932cbb2e6034a0ddacc1d9bea82a6ba57f7cf',
      ]);

      final reconstructed = BytesBuilder(copy: false);
      final fileIds = <String>{};
      final noncePrefixes = <String>{};
      for (var index = 0; index < prepared.objects.length; index++) {
        final object = prepared.objects[index];
        final container = await object.file.readAsBytes();
        final verified = await SboxContainerCodec().decryptBytes(
          container: container,
          privateKey: identity.rsaPrivateKey,
          expectedRecipientKeyId: identity.publicIdentity.recipientKeyId,
        );
        expect(verified.metadata.contentKind, SboxContentKind.multipartPart);
        expect(verified.metadata.multipart!.partIndex, index);
        expect(
          hexLower(verified.metadata.multipart!.multipartId),
          payload.multipartId,
        );
        fileIds.add(hexLower(verified.header.fileId));
        noncePrefixes.add(hexLower(verified.header.noncePrefix));
        reconstructed.add(verified.data);
      }
      expect(fileIds, hasLength(3));
      expect(noncePrefixes, hasLength(3));
      expect(sha256Bytes(reconstructed.takeBytes()), sha256Bytes(data));
      expect(await store.listPermanentObjects().length, 3);

      final catalogEntry = CatalogEntry(
        entryId: '11111111111111111111111111111111',
        revision: 1,
        title: 'Multipart vector',
        description: '',
        originalName: 'vector.bin',
        mediaType: 'application/octet-stream',
        payload: payload,
        tags: const <String>[],
        createdAt: '2026-08-15T00:00:00Z',
        updatedAt: '2026-08-15T00:00:00Z',
      );
      final catalog = SboxCatalog(
        catalogId: '22222222222222222222222222222222',
        generation: 1,
        previousCatalogSha256: null,
        recipientKeyId: hexLower(identity.publicIdentity.recipientKeyId),
        signerKeyId: hexLower(identity.publicIdentity.catalogSignerKeyId),
        createdAt: '2026-08-15T00:00:00Z',
        updatedAt: '2026-08-15T00:00:00Z',
        entries: <CatalogEntry>[catalogEntry],
        tombstones: const <CatalogTombstone>[],
      );
      final signatureCodec = CatalogSignatureCodec();
      final signed = await signatureCodec.sign(
        catalog: catalog,
        catalogSigningSeed: identity.catalogSigningSeed,
        expectedIdentity: identity.publicIdentity,
      );
      final verifiedCatalog = await signatureCodec.verify(
        plaintext: signed.encodePlaintext(),
        expectedIdentity: identity.publicIdentity,
        expectedCatalogId: catalog.catalogId,
      );
      final temporary = await ManagedTemporaryPlaintextStore.open(
        root: Directory('${testRoot.path}/multipart-plaintext'),
        cipherRoots: <Directory>[cipherRoot],
      );
      final reassembled = await decryptCatalogEntry(
        entry: verifiedCatalog.entryById(catalogEntry.entryId),
        cipherStore: store,
        plaintextStore: temporary,
        mnemonic: EphemeralMnemonic.fromString(mnemonic),
        expectedIdentity: identity.publicIdentity,
        control: JobControl(),
      );
      expect(await reassembled.file.length(), data.length);
      expect(
        hexLower(sha256Bytes(await reassembled.file.readAsBytes())),
        payload.plaintextSha256,
      );
      await temporary.clearAll();
    },
  );

  test(
    'managed plaintext cleanup never deletes permanent SBOX objects',
    () async {
      final store = await FileSystemLocalCipherStore.open(cipherRoot);
      final temporary = await ManagedTemporaryPlaintextStore.open(
        root: plaintextRoot,
        cipherRoots: <Directory>[cipherRoot],
      );
      final fixed = SboxEncryptionRandomness(
        fileId: decodeHex('f0000000000000000000000000000001'),
        dek: decodeHex(
          '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f',
        ),
        noncePrefix: decodeHex('01020304'),
        oaepSeed: decodeHex(
          '303132333435363738393a3b3c3d3e3f'
          '404142434445464748494a4b4c4d4e4f',
        ),
      );
      final path = SourcePath(
        'objects/f0/f0000000000000000000000000000001.sbox',
      );
      final stagedCipher = await store.createStaging(path);
      final sourceBytes = utf8Bytes('temporary plaintext');
      final artifact = await encryptContainer(
        input: Stream<List<int>>.value(sourceBytes),
        inputLength: sourceBytes.length,
        stagedOutput: stagedCipher.openSink(),
        options: EncryptOptions(
          recipient: identity.publicIdentity,
          contentKind: SboxContentKind.file,
          originalName: 'temporary.txt',
          mediaType: 'text/plain',
          randomness: fixed,
        ),
        control: JobControl(),
      );
      stagedCipher.accept(artifact);
      final permanent = await store.commitVerified(stagedCipher);
      fixed.dispose();

      final stagedPlaintext = await temporary.createForJob(JobId.random());
      final verified = await decryptSingleContainerWithMnemonic(
        input: permanent.file.openRead(),
        stagedPlaintext: stagedPlaintext.openSink(),
        mnemonic: EphemeralMnemonic.fromString(mnemonic),
        expectedIdentity: identity.publicIdentity,
        control: JobControl(),
      );
      stagedPlaintext.accept(verified);
      final published = await temporary.publishVerified(stagedPlaintext);
      expect(await published.file.readAsString(), 'temporary plaintext');
      await temporary.deletePublishedPath(published.file.path);
      expect(await published.file.exists(), isFalse);
      expect(await permanent.file.exists(), isTrue);
      await File('${plaintextRoot.path}${Platform.pathSeparator}.nomedia')
          .writeAsString('');
      final report = await temporary.clearAll();
      expect(report.isComplete, isTrue);
      expect((await temporary.stats()).fileCount, 0);
      expect(await permanent.file.exists(), isTrue);
    },
  );

  test('overlapping roots and traversal source paths are rejected', () async {
    final rejectedRoot = Directory('${cipherRoot.path}/nested-plaintext');
    await expectLater(
      ManagedTemporaryPlaintextStore.open(
        root: rejectedRoot,
        cipherRoots: <Directory>[cipherRoot],
      ),
      throwsA(anything),
    );
    expect(await rejectedRoot.exists(), isFalse);
    expect(() => SourcePath('../escape.sbox'), throwsA(anything));
    expect(() => SourcePath('objects/%2e%2e/escape.sbox'), throwsA(anything));
  });

  test(
    'startup recovery deletes only unpublished plaintext remnants',
    () async {
      final temporary = await ManagedTemporaryPlaintextStore.open(
        root: plaintextRoot,
        cipherRoots: <Directory>[cipherRoot],
      );
      final staged = await temporary.createForJob(
        JobId('11111111111111111111111111111111'),
      );
      await staged.file.writeAsString('unauthenticated partial plaintext');
      final publishedDirectory = Directory(
        '${plaintextRoot.path}${Platform.pathSeparator}'
        '22222222222222222222222222222222',
      );
      await publishedDirectory.create();
      final published = File(
        '${publishedDirectory.path}${Platform.pathSeparator}verified.txt',
      );
      await published.writeAsString('verified plaintext');

      expect(await temporary.discardIncompleteJobs(), 1);
      expect(await staged.file.parent.exists(), isFalse);
      expect(await published.readAsString(), 'verified plaintext');
    },
  );

  test('startup recovery removes only incomplete ciphertext staging', () async {
    final store = await FileSystemLocalCipherStore.open(cipherRoot);
    final staged = await store.createStaging(
      SourcePath('objects/aa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.sbox'),
    );
    await staged.file.writeAsString('incomplete ciphertext');
    final permanent = File(
      '${cipherRoot.path}${Platform.pathSeparator}objects'
      '${Platform.pathSeparator}bb${Platform.pathSeparator}'
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.sbox',
    );
    await permanent.parent.create(recursive: true);
    await permanent.writeAsString('permanent ciphertext');

    expect(await store.discardIncompleteStaging(), 1);
    expect(await staged.file.exists(), isFalse);
    expect(await permanent.readAsString(), 'permanent ciphertext');
  });

  test('managed plaintext cleanup never follows a directory link', () async {
    final root = Directory('${testRoot.path}/linked-plaintext');
    final external = Directory('${testRoot.path}/must-survive')..createSync();
    final externalFile = File('${external.path}/outside.txt')
      ..writeAsStringSync('must survive');
    final temporary = await ManagedTemporaryPlaintextStore.open(
      root: root,
      cipherRoots: <Directory>[cipherRoot],
    );
    final job = Directory('${root.path}/33333333333333333333333333333333')
      ..createSync();
    final linkedPath = '${job.path}/external-link';
    if (Platform.isWindows) {
      final created = await Process.run('powershell.exe', <String>[
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'& { param([string]$link, [string]$target) '
            r'New-Item -ItemType Junction -LiteralPath $link -Target $target '
            r'| Out-Null }',
        linkedPath,
        external.absolute.path,
      ]);
      expect(created.exitCode, 0, reason: created.stderr.toString());
    } else {
      await Link(linkedPath).create(external.path);
    }

    final report = await temporary.clearAll();
    expect(report.isComplete, isTrue);
    expect(await externalFile.readAsString(), 'must survive');
    expect(await job.exists(), isFalse);
  });
}
