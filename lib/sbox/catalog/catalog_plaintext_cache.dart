import 'dart:convert';
import 'dart:typed_data';

import '../bytes.dart';
import '../errors.dart';
import 'canonical_json.dart';
import 'catalog_models.dart';
import 'strict_json.dart';

/// A deliberately explicit, local-only cache envelope for a decrypted
/// Catalog. The ciphertext SHA-256 binds the plaintext cache to the exact
/// catalog.sbox version that produced it; callers must still verify the
/// public identity before using the decoded Catalog.
final class CatalogPlaintextCache {
  CatalogPlaintextCache._({
    required this.catalog,
    required List<int> catalogSha256,
  }) : catalogSha256 = Uint8List.fromList(catalogSha256);

  static const format = 'SBOX-CATALOG-CACHE-1';

  final SboxCatalog catalog;
  final Uint8List catalogSha256;

  Uint8List encode() => CatalogCanonicalJson.encodeUtf8(<String, Object?>{
    'format': format,
    'catalog_sha256': hexLower(catalogSha256),
    'catalog': catalog.toJson(),
  });

  static CatalogPlaintextCache fromCatalog({
    required SboxCatalog catalog,
    required List<int> catalogSha256,
  }) {
    if (catalogSha256.length != 32) {
      throw const SboxException(SboxErrorCode.catalog, 'Catalog 缓存绑定摘要长度无效');
    }
    return CatalogPlaintextCache._(
      catalog: catalog,
      catalogSha256: catalogSha256,
    );
  }

  static CatalogPlaintextCache decode(List<int> bytes) {
    late final String text;
    try {
      text = utf8.decode(bytes, allowMalformed: false);
      final root = StrictJsonParser(text).parse();
      if (root is! Map<String, Object?> ||
          root.length != 3 ||
          root['format'] != format ||
          root['catalog_sha256'] is! String ||
          root['catalog'] is! Map<String, Object?>) {
        throw _cacheError();
      }
      final hashText = root['catalog_sha256']! as String;
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hashText)) {
        throw _cacheError();
      }
      final hash = decodeHex(hashText);
      final catalog = SboxCatalog.fromJson(
        root['catalog']! as Map<String, Object?>,
      );
      return CatalogPlaintextCache._(catalog: catalog, catalogSha256: hash);
    } on SboxException {
      rethrow;
    } on FormatException {
      throw _cacheError();
    } on ArgumentError {
      throw _cacheError();
    }
  }
}

SboxException _cacheError() =>
    const SboxException(SboxErrorCode.catalog, 'Catalog 明文缓存格式无效');
