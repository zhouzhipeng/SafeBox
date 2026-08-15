import 'dart:convert';

import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/catalog/canonical_json.dart';
import 'package:safebox/sbox/catalog/catalog_models.dart';
import 'package:safebox/sbox/catalog/catalog_signature.dart';
import 'package:safebox/sbox/identity/bip39_identity.dart';
import 'package:safebox/sbox/identity/rsa_models.dart';
import 'package:test/test.dart';

void main() {
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon about';
  late EphemeralIdentity identity;
  late SboxCatalog catalog;
  final signatures = CatalogSignatureCodec();

  setUpAll(() async {
    identity = await SboxIdentityDeriver().deriveIdentity(mnemonic);
    catalog = SboxCatalog(
      catalogId: '000102030405060708090a0b0c0d0e0f',
      generation: 1,
      previousCatalogSha256: null,
      recipientKeyId:
          '9549c41744d3b469c512aa2c845677940937fd20685220fb0eb00f15082b04ae',
      signerKeyId:
          'dc6c7e5d4cfc3c6bb5b364086fc8b68da0f7d8b041da907896d8c9b0ca060f2e',
      createdAt: '2026-08-15T00:00:00Z',
      updatedAt: '2026-08-15T00:00:00Z',
      entries: const <CatalogEntry>[],
      tombstones: const <CatalogTombstone>[],
    );
  });

  tearDownAll(() {
    identity.disposeControlledSecrets();
  });

  test('RFC 8785 Catalog bytes and hashes match the vector', () {
    final canonical = CatalogCanonicalJson.encode(catalog.toJson());
    expect(
      canonical,
      '{"catalog_id":"000102030405060708090a0b0c0d0e0f",'
      '"created_at":"2026-08-15T00:00:00Z","entries":[],"generation":1,'
      '"previous_catalog_sha256":null,'
      '"recipient_key_id":"9549c41744d3b469c512aa2c845677940937fd20685220fb0eb00f15082b04ae",'
      '"schema":"SBOX-CATALOG-1",'
      '"signer_key_id":"dc6c7e5d4cfc3c6bb5b364086fc8b68da0f7d8b041da907896d8c9b0ca060f2e",'
      '"tombstones":[],"updated_at":"2026-08-15T00:00:00Z"}',
    );
    expect(
      hexLower(sha256Bytes(utf8.encode(canonical))),
      '3083bef651fab06a600e5f0fa29455427b68da6a8b40108810439f963eb5b726',
    );
    expect(
      hexLower(
        sha256Bytes(signatures.signedBytesForCatalogObject(catalog.toJson())),
      ),
      'a19cab07552bea589c1ab0d82bb15ed02a50291624ceab79687b0c216d51e413',
    );
  });

  test('Ed25519 signature and strict verification match the vector', () async {
    final signed = await signatures.sign(
      catalog: catalog,
      catalogSigningSeed: identity.catalogSigningSeed,
      expectedIdentity: identity.publicIdentity,
    );
    expect(
      signed.signatureValue,
      'WSiAR_lqmkiEDvqYNcgdtZpCzXy9jMawwDZtsl4Yn7iyAhdjzpAIwBGajFEyXcVwRCz_9J5EoIq24PDbc-aYAg',
    );
    final plaintext = signed.encodePlaintext();
    final verified = await signatures.verify(
      plaintext: plaintext,
      expectedIdentity: identity.publicIdentity,
      expectedCatalogId: catalog.catalogId,
    );
    expect(verified.catalog.generation, 1);
  });

  test(
    'duplicate keys, unknown fields and modified signatures are rejected',
    () async {
      final signed = await signatures.sign(
        catalog: catalog,
        catalogSigningSeed: identity.catalogSigningSeed,
        expectedIdentity: identity.publicIdentity,
      );
      final valid = utf8.decode(signed.encodePlaintext());
      final duplicateKey = valid.replaceFirst(
        '"catalog":{',
        '"catalog":{"schema":"SBOX-CATALOG-1",',
      );
      final unknownField = valid.replaceFirst(
        '"catalog_id"',
        '"unknown":true,"catalog_id"',
      );
      final modifiedSignature = valid.replaceFirst(
        signed.signatureValue,
        'A${signed.signatureValue.substring(1)}',
      );
      for (final candidate in <String>[
        duplicateKey,
        unknownField,
        modifiedSignature,
      ]) {
        await expectLater(
          signatures.verify(
            plaintext: utf8.encode(candidate),
            expectedIdentity: identity.publicIdentity,
          ),
          throwsA(anything),
        );
      }
    },
  );
}
