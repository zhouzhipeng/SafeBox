import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/catalog/catalog_models.dart';
import 'package:safebox/sbox/catalog/catalog_signature.dart';
import 'package:safebox/sbox/catalog/catalog_state.dart';
import 'package:safebox/sbox/errors.dart';
import 'package:safebox/sbox/identity/bip39_identity.dart';
import 'package:safebox/sbox/identity/rsa_models.dart';
import 'package:test/test.dart';

void main() {
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon about';
  late EphemeralIdentity identity;
  late CatalogSignatureCodec signatures;

  setUpAll(() async {
    identity = await SboxIdentityDeriver().deriveIdentity(mnemonic);
    signatures = CatalogSignatureCodec();
  });

  tearDownAll(() => identity.disposeControlledSecrets());

  CatalogEntry entry(
    String id,
    String title, {
    int revision = 1,
    List<String> tags = const <String>[],
  }) {
    const hash =
        'cbce65dce351514751a199dfeebc0895c864bb81ac5dfd77581a448020dd9a83';
    final fileId = id;
    return CatalogEntry(
      entryId: id,
      revision: revision,
      title: title,
      description: '',
      originalName: '$id.txt',
      mediaType: 'text/plain',
      payload: CatalogPayload(
        mode: CatalogPayloadMode.single,
        plaintextSize: BigInt.from(11),
        plaintextSha256: hash,
        parts: <CatalogPart>[
          CatalogPart(
            index: 0,
            objectPath: 'objects/${fileId.substring(0, 2)}/$fileId.sbox',
            fileId: fileId,
            plaintextOffset: BigInt.zero,
            plaintextSize: BigInt.from(11),
            plaintextSha256: hash,
            sboxSize: BigInt.from(664),
            sboxSha256: '107e8cee375d787593432b713acaca2396e17bc370616646aa54d33df699497e',
          ),
        ],
      ),
      tags: tags,
      createdAt: '2026-08-15T00:00:00Z',
      updatedAt: '2026-08-15T00:00:00Z',
    );
  }

  Future<VerifiedCatalog> verifyCatalog(SboxCatalog catalog) async {
    final signed = await signatures.sign(
      catalog: catalog,
      catalogSigningSeed: identity.catalogSigningSeed,
      expectedIdentity: identity.publicIdentity,
    );
    return signatures.verify(
      plaintext: signed.encodePlaintext(),
      expectedIdentity: identity.publicIdentity,
    );
  }

  SboxCatalog catalog({
    required int generation,
    required List<CatalogEntry> entries,
    String? previous,
  }) {
    return SboxCatalog(
      catalogId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      generation: generation,
      previousCatalogSha256: generation == 1 ? null : previous ?? '0000000000000000000000000000000000000000000000000000000000000000',
      recipientKeyId: hexLower(identity.publicIdentity.recipientKeyId),
      signerKeyId: hexLower(identity.publicIdentity.catalogSignerKeyId),
      createdAt: '2026-08-15T00:00:00Z',
      updatedAt: '2026-08-15T00:00:00Z',
      entries: entries,
      tombstones: const <CatalogTombstone>[],
    );
  }

  test('checkpoint rejects rollback and same-generation forks', () {
    const lastHash =
        '1111111111111111111111111111111111111111111111111111111111111111';
    const checkpoint = CatalogCheckpoint(
      catalogId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      highestGeneration: 3,
      lastCatalogSha256: lastHash,
    );
    expect(
      validateCatalogCheckpoint(
        remote: catalog(generation: 3, entries: const <CatalogEntry>[]),
        remoteContainerSha256: lastHash,
        local: checkpoint,
      ),
      CatalogContinuity.unchanged,
    );
    expect(
      () => validateCatalogCheckpoint(
        remote: catalog(
          generation: 2,
          entries: const <CatalogEntry>[],
          previous: lastHash,
        ),
        remoteContainerSha256: lastHash,
        local: checkpoint,
      ),
      throwsA(
        isA<SboxException>().having(
          (error) => error.code,
          'code',
          SboxErrorCode.catalogRollback,
        ),
      ),
    );
    expect(
      () => validateCatalogCheckpoint(
        remote: catalog(generation: 3, entries: const <CatalogEntry>[]),
        remoteContainerSha256:
            '2222222222222222222222222222222222222222222222222222222222222222',
        local: checkpoint,
      ),
      throwsA(isA<SboxException>()),
    );
  });

  test('Catalog generators normalize user strings and tags to NFC', () {
    final generated = entry(
      '00000000000000000000000000000009',
      'Cafe\u0301',
      tags: const <String>['re\u0301sume\u0301'],
    );
    expect(generated.title, 'Café');
    expect(generated.tags, const <String>['résumé']);
  });

  test('three-way merge combines disjoint edits deterministically', () async {
    final a = entry('00000000000000000000000000000001', 'A');
    final b = entry('00000000000000000000000000000002', 'B');
    final base = await verifyCatalog(
      catalog(generation: 1, entries: <CatalogEntry>[a, b]),
    );
    final remoteB = CatalogEntry(
      entryId: b.entryId,
      revision: 2,
      title: 'B remote',
      description: b.description,
      originalName: b.originalName,
      mediaType: b.mediaType,
      payload: b.payload,
      tags: b.tags,
      createdAt: b.createdAt,
      updatedAt: '2026-08-15T00:00:01Z',
    );
    final remote = await verifyCatalog(
      catalog(
        generation: 2,
        previous:
            '3333333333333333333333333333333333333333333333333333333333333333',
        entries: <CatalogEntry>[a, remoteB],
      ),
    );
    final result = mergeCatalog(
      base: base,
      remote: remote,
      pending: <CatalogOperation>[
        UpdateCatalogMetadata(
          entryId: a.entryId,
          title: 'A local',
          description: '',
          tags: const <String>[],
          updatedAt: '2026-08-15T00:00:02Z',
        ),
      ],
    );
    expect(result, isA<MergedCatalog>());
    final merged = result as MergedCatalog;
    expect(merged.nextGeneration, 3);
    expect(merged.entries.map((value) => value.title), <String>[
      'A local',
      'B remote',
    ]);
  });

  test('same-entry concurrent edits require explicit user resolution', () async {
    final a = entry('00000000000000000000000000000003', 'A');
    final base = await verifyCatalog(
      catalog(generation: 1, entries: <CatalogEntry>[a]),
    );
    final remoteA = CatalogEntry(
      entryId: a.entryId,
      revision: 2,
      title: 'remote',
      description: a.description,
      originalName: a.originalName,
      mediaType: a.mediaType,
      payload: a.payload,
      tags: a.tags,
      createdAt: a.createdAt,
      updatedAt: '2026-08-15T00:00:01Z',
    );
    final remote = await verifyCatalog(
      catalog(
        generation: 2,
        previous:
            '4444444444444444444444444444444444444444444444444444444444444444',
        entries: <CatalogEntry>[remoteA],
      ),
    );
    final result = mergeCatalog(
      base: base,
      remote: remote,
      pending: <CatalogOperation>[
        UpdateCatalogMetadata(
          entryId: a.entryId,
          title: 'local',
          description: '',
          tags: const <String>[],
          updatedAt: '2026-08-15T00:00:02Z',
        ),
      ],
    );
    expect(result, isA<UserCatalogConflicts>());
  });
}
