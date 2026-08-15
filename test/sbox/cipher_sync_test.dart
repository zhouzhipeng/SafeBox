import 'dart:io';
import 'dart:typed_data';

import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/catalog/catalog_models.dart';
import 'package:safebox/sbox/catalog/catalog_signature.dart';
import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/engine/container_codec.dart';
import 'package:safebox/sbox/identity/bip39_identity.dart';
import 'package:safebox/sbox/identity/rsa_models.dart';
import 'package:safebox/sbox/source/cipher_sync.dart';
import 'package:safebox/sbox/source/data_source.dart';
import 'package:safebox/sbox/source/source_path.dart';
import 'package:safebox/sbox/storage/local_cipher_store.dart';
import 'package:test/test.dart';

void main() {
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon about';
  late EphemeralIdentity identity;
  late Uint8List objectBytes;
  late Uint8List catalogBytes;
  late CatalogPayload payload;
  late VerifiedCatalog verified;
  late Directory root;

  setUpAll(() async {
    identity = await SboxIdentityDeriver().deriveIdentity(mnemonic);
    final plaintext = utf8Bytes('cipher mirror payload');
    objectBytes = await SboxContainerCodec().encryptBytes(
      recipient: identity.publicIdentity,
      contentKind: SboxContentKind.file,
      originalName: 'payload.txt',
      mediaType: 'text/plain',
      data: plaintext,
    );
    final fileId = hexLower(objectBytes.sublist(28, 44));
    final part = CatalogPart(
      index: 0,
      objectPath: 'objects/${fileId.substring(0, 2)}/$fileId.sbox',
      fileId: fileId,
      plaintextOffset: BigInt.zero,
      plaintextSize: BigInt.from(plaintext.length),
      plaintextSha256: hexLower(sha256Bytes(plaintext)),
      sboxSize: BigInt.from(objectBytes.length),
      sboxSha256: hexLower(sha256Bytes(objectBytes)),
    );
    payload = CatalogPayload(
      mode: CatalogPayloadMode.single,
      plaintextSize: part.plaintextSize,
      plaintextSha256: part.plaintextSha256,
      parts: <CatalogPart>[part],
    );
    final entry = CatalogEntry(
      entryId: '11111111111111111111111111111111',
      revision: 1,
      title: 'Mirror item',
      description: '',
      originalName: 'payload.txt',
      mediaType: 'text/plain',
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
      entries: <CatalogEntry>[entry],
      tombstones: const <CatalogTombstone>[],
    );
    final codec = CatalogSignatureCodec();
    final signed = await codec.sign(
      catalog: catalog,
      catalogSigningSeed: identity.catalogSigningSeed,
      expectedIdentity: identity.publicIdentity,
    );
    verified = await codec.verify(
      plaintext: signed.encodePlaintext(),
      expectedIdentity: identity.publicIdentity,
    );
    catalogBytes = await SboxContainerCodec().encryptBytes(
      recipient: identity.publicIdentity,
      contentKind: SboxContentKind.catalog,
      originalName: 'catalog.json',
      mediaType: 'application/vnd.sbox.catalog+json',
      data: signed.encodePlaintext(),
    );
    root = await Directory.systemTemp.createTemp('safebox-sync-test-');
  });

  tearDownAll(() async {
    identity.disposeControlledSecrets();
    await root.delete(recursive: true);
  });

  test(
    'pull mirrors encrypted Catalog and all verified payload objects',
    () async {
      final source = _MemoryDataSource(<String, Uint8List>{
        'catalog.sbox': catalogBytes,
        payload.parts.single.objectPath: objectBytes,
      });
      final store = await FileSystemLocalCipherStore.open(
        Directory('${root.path}/pull'),
      );
      final sync = CipherMirrorSynchronizer(source: source, localStore: store);

      final catalogResult = await sync.pullEncryptedCatalog(
        expectedRecipientKeyId: verified.catalog.recipientKeyId,
      );
      expect(catalogResult.notModified, isFalse);
      expect(catalogResult.localObject?.sha256, sha256Bytes(catalogBytes));

      final result = await sync.pullVerifiedCatalogObjects(verified);
      expect(result.total, 1);
      expect(result.transferred, 1);
      final local = await store.find(
        SourcePath(payload.parts.single.objectPath),
        sha256Bytes(objectBytes),
      );
      expect(await local!.file.readAsBytes(), objectBytes);

      final reused = await sync.pullVerifiedCatalogObjects(verified);
      expect(reused.reused, 1);
      expect(reused.transferred, 0);
    },
  );

  test(
    'corrupt remote part is rejected before permanent publication',
    () async {
      final corrupt = Uint8List.fromList(objectBytes)..[500] ^= 1;
      final source = _MemoryDataSource(<String, Uint8List>{
        payload.parts.single.objectPath: corrupt,
      });
      final store = await FileSystemLocalCipherStore.open(
        Directory('${root.path}/corrupt'),
      );
      final sync = CipherMirrorSynchronizer(source: source, localStore: store);

      await expectLater(
        sync.pullVerifiedCatalogObjects(verified),
        throwsA(anything),
      );
      expect(
        await store.find(
          SourcePath(payload.parts.single.objectPath),
          sha256Bytes(objectBytes),
        ),
        isNull,
      );
    },
  );

  test('publish uploads every immutable object before catalog.sbox', () async {
    final localSource = _MemoryDataSource(<String, Uint8List>{
      'catalog.sbox': catalogBytes,
      payload.parts.single.objectPath: objectBytes,
    });
    final store = await FileSystemLocalCipherStore.open(
      Directory('${root.path}/publish'),
    );
    final pull = CipherMirrorSynchronizer(
      source: localSource,
      localStore: store,
    );
    await pull.pullEncryptedCatalog(
      expectedRecipientKeyId: verified.catalog.recipientKeyId,
    );
    await pull.pullVerifiedCatalogObjects(verified);

    final target = _MemoryDataSource(<String, Uint8List>{});
    final publish = CipherMirrorSynchronizer(source: target, localStore: store);
    await publish.publishEncryptedCatalog(
      payloads: <CatalogPayload>[payload],
      encryptedCatalogSha256: sha256Bytes(catalogBytes),
    );
    expect(target.writeOrder, <String>[
      payload.parts.single.objectPath,
      'catalog.sbox',
    ]);
  });
}

final class _MemoryDataSource implements DataSource {
  _MemoryDataSource(Map<String, Uint8List> values)
    : values = <String, Uint8List>{
        for (final entry in values.entries)
          entry.key: Uint8List.fromList(entry.value),
      };

  final Map<String, Uint8List> values;
  final List<String> writeOrder = <String>[];

  @override
  SourceCapabilities get capabilities => SourceCapabilities(
    canRead: true,
    canWrite: true,
    canDelete: true,
    conditionalWrite: true,
    history: false,
    maxObjectBytes: BigInt.from(100 * 1024 * 1024),
    maxRequestBodyBytes: BigInt.from(140 * 1024 * 1024),
    uploadEncoding: UploadEncoding.binary,
    maxParallelObjectTransfers: 4,
    supportsStreamingDownload: true,
    supportsResumableObjectDownload: false,
  );

  @override
  Future<SourceRead> get(SourcePath path, {RevisionToken? ifNoneMatch}) async {
    final value = values[path.value];
    if (value == null) {
      throw StateError('not found');
    }
    final revision = RevisionToken(sha256Bytes(value));
    if (ifNoneMatch != null && revision.matches(ifNoneMatch)) {
      return SourceRead(
        body: const Stream<List<int>>.empty(),
        length: 0,
        revision: revision,
        notModified: true,
      );
    }
    return SourceRead(
      body: Stream<List<int>>.fromIterable(<List<int>>[
        value.sublist(0, 13),
        value.sublist(13),
      ]),
      length: value.length,
      revision: revision,
    );
  }

  @override
  Future<RevisionToken> putNew(
    SourcePath path,
    Stream<List<int>> body, {
    required int length,
    required Uint8List sha256,
  }) async {
    final bytes = await _collect(body);
    expect(bytes.length, length);
    expect(sha256Bytes(bytes), sha256);
    final prior = values[path.value];
    if (prior != null && !constantTimeBytesEqual(prior, bytes)) {
      throw StateError('conflict');
    }
    values[path.value] = bytes;
    writeOrder.add(path.value);
    return RevisionToken(sha256Bytes(bytes));
  }

  @override
  Future<RevisionToken> compareAndSwap(
    SourcePath path,
    RevisionToken expected,
    Stream<List<int>> body, {
    required int length,
  }) async {
    final prior = values[path.value];
    if (prior == null ||
        !constantTimeBytesEqual(sha256Bytes(prior), expected.bytes)) {
      throw StateError('conflict');
    }
    final bytes = await _collect(body);
    expect(bytes.length, length);
    values[path.value] = bytes;
    writeOrder.add(path.value);
    return RevisionToken(sha256Bytes(bytes));
  }

  @override
  Future<void> deleteIfMatch(SourcePath path, RevisionToken expected) async {
    final prior = values[path.value];
    if (prior == null ||
        !constantTimeBytesEqual(sha256Bytes(prior), expected.bytes)) {
      throw StateError('conflict');
    }
    values.remove(path.value);
  }
}

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final output = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    output.add(chunk);
  }
  return output.takeBytes();
}
