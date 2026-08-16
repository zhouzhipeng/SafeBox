import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/catalog/catalog_container.dart';
import 'package:safebox/sbox/catalog/catalog_models.dart';
import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/engine/job_control.dart';
import 'package:safebox/sbox/errors.dart';
import 'package:safebox/sbox/identity/bip39_identity.dart';
import 'package:safebox/sbox/identity/ephemeral_mnemonic.dart';
import 'package:safebox/sbox/identity/rsa_models.dart';
import 'package:test/test.dart';

void main() {
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon about';
  late EphemeralIdentity identity;
  late SboxCatalog catalog;

  setUpAll(() async {
    identity = await SboxIdentityDeriver().deriveIdentity(mnemonic);
    catalog = SboxCatalog(
      catalogId: '0123456789abcdef0123456789abcdef',
      generation: 1,
      previousCatalogSha256: null,
      recipientKeyId: hexLower(identity.publicIdentity.recipientKeyId),
      signerKeyId: hexLower(identity.publicIdentity.catalogSignerKeyId),
      createdAt: '2026-08-15T00:00:00Z',
      updatedAt: '2026-08-15T00:00:00Z',
      entries: const <CatalogEntry>[],
      tombstones: const <CatalogTombstone>[],
    );
  });

  tearDownAll(() {
    identity.disposeControlledSecrets();
  });

  test('signed Catalog is encrypted and reopened as a complete SBOX', () async {
    final prepared = await createCatalogContainerWithMnemonic(
      catalog: catalog,
      mnemonic: EphemeralMnemonic.fromString(mnemonic),
      expectedIdentity: identity.publicIdentity,
    );
    expect(prepared.bytes.sublist(0, 8), SboxV1.magic);
    expect(
      prepared.header.recipientKeyId,
      identity.publicIdentity.recipientKeyId,
    );

    final opened = await openCatalogContainerWithMnemonic(
      container: prepared.bytes,
      mnemonic: EphemeralMnemonic.fromString(mnemonic),
      expectedIdentity: identity.publicIdentity,
      expectedCatalogId: catalog.catalogId,
      control: JobControl(),
    );
    expect(opened.catalog.catalog.generation, 1);
    expect(opened.catalog.catalog.entries, isEmpty);
    expect(opened.containerSha256, prepared.sha256);
  });

  test(
    'Catalog encryption can use the public identity without a mnemonic',
    () async {
      final prepared = await createCatalogContainerWithPublicKey(
        catalog: catalog,
        expectedIdentity: identity.publicIdentity,
      );
      final opened = await openCatalogContainerWithMnemonic(
        container: prepared.bytes,
        mnemonic: EphemeralMnemonic.fromString(mnemonic),
        expectedIdentity: identity.publicIdentity,
        expectedCatalogId: catalog.catalogId,
        control: JobControl(),
      );
      expect(opened.catalog.signatureValue, isEmpty);
      expect(opened.catalog.catalog.catalogId, catalog.catalogId);
    },
  );

  test(
    'tampered encrypted Catalog never reaches signed Catalog state',
    () async {
      final prepared = await createCatalogContainerWithMnemonic(
        catalog: catalog,
        mnemonic: EphemeralMnemonic.fromString(mnemonic),
        expectedIdentity: identity.publicIdentity,
      );
      final tampered = List<int>.from(prepared.bytes)..[500] ^= 1;
      await expectLater(
        openCatalogContainerWithMnemonic(
          container: tampered,
          mnemonic: EphemeralMnemonic.fromString(mnemonic),
          expectedIdentity: identity.publicIdentity,
          control: JobControl(),
        ),
        throwsA(isA<SboxException>()),
      );
    },
  );
}
