import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/catalog/catalog_models.dart';
import 'package:safebox/sbox/catalog/catalog_plaintext_cache.dart';
import 'package:safebox/sbox/errors.dart';
import 'package:test/test.dart';

void main() {
  final catalog = SboxCatalog(
    catalogId: '0123456789abcdef0123456789abcdef',
    generation: 1,
    previousCatalogSha256: null,
    recipientKeyId: List<String>.filled(32, '11').join(),
    signerKeyId: List<String>.filled(32, '22').join(),
    createdAt: '2026-08-16T00:00:00Z',
    updatedAt: '2026-08-16T00:00:00Z',
    entries: const <CatalogEntry>[],
    tombstones: const <CatalogTombstone>[],
  );

  test('plaintext Catalog cache round-trips with its ciphertext binding', () {
    final cache = CatalogPlaintextCache.fromCatalog(
      catalog: catalog,
      catalogSha256: List<int>.filled(32, 0xab),
    );
    final decoded = CatalogPlaintextCache.decode(cache.encode());

    expect(decoded.catalog.catalogId, catalog.catalogId);
    expect(
      hexLower(decoded.catalogSha256),
      List<String>.filled(32, 'ab').join(),
    );
    expect(decoded.catalog.entries, isEmpty);
  });

  test('plaintext Catalog cache rejects malformed or changed bindings', () {
    final cache = CatalogPlaintextCache.fromCatalog(
      catalog: catalog,
      catalogSha256: List<int>.filled(32, 0xab),
    );
    final bytes = cache.encode();
    bytes[bytes.length - 3] ^= 1;

    expect(
      () => CatalogPlaintextCache.decode(bytes),
      throwsA(isA<SboxException>()),
    );
  });
}
