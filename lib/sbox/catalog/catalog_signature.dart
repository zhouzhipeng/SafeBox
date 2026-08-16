import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import '../bytes.dart';
import '../constants.dart';
import '../errors.dart';
import '../identity/rsa_models.dart';
import 'canonical_json.dart';
import 'catalog_models.dart';
import 'strict_json.dart';

final class SignedCatalog {
  SignedCatalog._({
    required this.catalog,
    required this.signatureAlgorithm,
    required this.signatureValue,
  });

  final SboxCatalog catalog;
  final String signatureAlgorithm;
  final String signatureValue;

  Map<String, Object?> toJson() => <String, Object?>{
    'catalog': catalog.toJson(),
    'signature': <String, Object?>{
      'algorithm': signatureAlgorithm,
      'value': signatureValue,
    },
  };

  Uint8List encodePlaintext() => CatalogCanonicalJson.encodeUtf8(toJson());
}

final class VerifiedCatalog {
  VerifiedCatalog._({
    required this.catalog,
    required this.signatureValue,
    required List<int> plaintextSha256,
  }) : plaintextSha256 = Uint8List.fromList(plaintextSha256);

  final SboxCatalog catalog;
  final String signatureValue;
  final Uint8List plaintextSha256;

  VerifiedCatalogEntry entryById(String entryId) {
    final matches = catalog.entries.where((entry) => entry.entryId == entryId);
    if (matches.length != 1) {
      throw _catalogError();
    }
    return VerifiedCatalogEntry._(matches.single);
  }
}

/// An entry that can only be obtained from a successfully authenticated
/// [VerifiedCatalog]. Legacy Ed25519 catalogs are signature-verified; new
/// public-key-only catalogs are authenticated by the outer RSA-OAEP and
/// AES-256-GCM container and identity-bound catalog fields.
final class VerifiedCatalogEntry {
  const VerifiedCatalogEntry._(this.entry);

  final CatalogEntry entry;
}

final class CatalogSignatureCodec {
  CatalogSignatureCodec() : _ed25519 = DartEd25519();

  final DartEd25519 _ed25519;

  Uint8List canonicalCatalogBytes(SboxCatalog catalog) =>
      CatalogCanonicalJson.encodeUtf8(catalog.toJson());

  Uint8List signedBytesForCatalogObject(Map<String, Object?> catalogObject) =>
      concatBytes(<List<int>>[
        asciiBytes(SboxV1.catalogSignatureContext),
        const <int>[0],
        CatalogCanonicalJson.encodeUtf8(catalogObject),
      ]);

  Future<SignedCatalog> sign({
    required SboxCatalog catalog,
    required List<int> catalogSigningSeed,
    required PublicIdentity expectedIdentity,
  }) async {
    if (catalogSigningSeed.length != 32 ||
        catalog.recipientKeyId != hexLower(expectedIdentity.recipientKeyId) ||
        catalog.signerKeyId != hexLower(expectedIdentity.catalogSignerKeyId)) {
      throw const SboxException(SboxErrorCode.keyMismatch, '目录签名身份不匹配');
    }
    final keyPair = await _ed25519.newKeyPairFromSeed(catalogSigningSeed);
    final publicKey = await keyPair.extractPublicKey();
    if (!constantTimeBytesEqual(
      publicKey.bytes,
      expectedIdentity.catalogSigningPublicKey,
    )) {
      throw const SboxException(SboxErrorCode.keyMismatch, '目录签名身份不匹配');
    }
    final signedBytes = signedBytesForCatalogObject(catalog.toJson());
    try {
      final signature = await _ed25519.sign(
        signedBytes,
        keyPair: keyPair,
        publicKey: publicKey,
      );
      final value = base64Url.encode(signature.bytes).replaceAll('=', '');
      return SignedCatalog._(
        catalog: catalog,
        signatureAlgorithm: 'Ed25519',
        signatureValue: value,
      );
    } finally {
      signedBytes.fillRange(0, signedBytes.length, 0);
    }
  }

  /// Encodes a catalog that can be created with the recipient public key only.
  ///
  /// The outer SBOX container still authenticates the plaintext with
  /// AES-256-GCM after the DEK is wrapped by RSA-OAEP.  This mode deliberately
  /// omits the Ed25519 author signature because producing that signature would
  /// require the mnemonic/private key during an encryption-only operation.
  SignedCatalog publicKeyOnly({
    required SboxCatalog catalog,
    required PublicIdentity expectedIdentity,
  }) {
    if (catalog.recipientKeyId != hexLower(expectedIdentity.recipientKeyId) ||
        catalog.signerKeyId != hexLower(expectedIdentity.catalogSignerKeyId)) {
      throw const SboxException(SboxErrorCode.keyMismatch, 'Catalog 公钥身份不匹配');
    }
    return SignedCatalog._(
      catalog: catalog,
      signatureAlgorithm: 'public-key-only',
      signatureValue: '',
    );
  }

  Uint8List encodePublicKeyOnly({
    required SboxCatalog catalog,
    required PublicIdentity expectedIdentity,
  }) => publicKeyOnly(
    catalog: catalog,
    expectedIdentity: expectedIdentity,
  ).encodePlaintext();

  Future<VerifiedCatalog> verify({
    required List<int> plaintext,
    required PublicIdentity expectedIdentity,
    String? expectedCatalogId,
  }) async {
    if (plaintext.length > 16 * 1024 * 1024) {
      throw _catalogError();
    }
    late final String text;
    try {
      text = utf8.decode(plaintext, allowMalformed: false);
    } on FormatException {
      throw _catalogError();
    }

    try {
      final root = StrictJsonParser(text).parse();
      if (root is! Map<String, Object?> ||
          root.length != 2 ||
          !root.containsKey('catalog') ||
          !root.containsKey('signature')) {
        throw _catalogError();
      }
      final catalogObject = _asMap(root['catalog']);
      final signatureObject = _asMap(root['signature']);
      if (signatureObject.length != 2 ||
          signatureObject['algorithm'] is! String ||
          signatureObject['value'] is! String) {
        throw _catalogError();
      }
      final algorithm = signatureObject['algorithm']! as String;
      final signatureValue = signatureObject['value']! as String;
      final catalog = SboxCatalog.fromJson(catalogObject);
      if (catalog.recipientKeyId != hexLower(expectedIdentity.recipientKeyId) ||
          catalog.signerKeyId !=
              hexLower(expectedIdentity.catalogSignerKeyId) ||
          (expectedCatalogId != null &&
              catalog.catalogId != expectedCatalogId)) {
        throw const SboxException(
          SboxErrorCode.keyMismatch,
          '目录身份或 Catalog ID 不匹配',
        );
      }

      if (algorithm == 'Ed25519') {
        final signatureBytes = _decodeSignature(signatureValue);
        final signedBytes = signedBytesForCatalogObject(catalogObject);
        final publicKey = SimplePublicKey(
          expectedIdentity.catalogSigningPublicKey,
          type: KeyPairType.ed25519,
        );
        final valid = await _ed25519.verify(
          signedBytes,
          signature: Signature(signatureBytes, publicKey: publicKey),
        );
        signedBytes.fillRange(0, signedBytes.length, 0);
        if (!valid) {
          throw _catalogError();
        }
      } else if (algorithm == 'public-key-only') {
        if (signatureValue.isNotEmpty) {
          throw _catalogError();
        }
      } else {
        throw _catalogError();
      }
      return VerifiedCatalog._(
        catalog: catalog,
        signatureValue: signatureValue,
        plaintextSha256: sha256Bytes(plaintext),
      );
    } on SboxException {
      rethrow;
    } on FormatException {
      throw _catalogError();
    } on ArgumentError {
      throw _catalogError();
    }
  }

  static Uint8List _decodeSignature(String value) {
    if (!RegExp(r'^[A-Za-z0-9_-]{86}$').hasMatch(value)) {
      throw _catalogError();
    }
    final decoded = Uint8List.fromList(base64Url.decode('$value=='));
    if (decoded.length != 64 ||
        base64Url.encode(decoded).replaceAll('=', '') != value) {
      throw _catalogError();
    }
    return decoded;
  }

  static Map<String, Object?> _asMap(Object? value) {
    if (value is! Map<String, Object?>) {
      throw _catalogError();
    }
    return value;
  }
}

SboxException _catalogError() =>
    const SboxException(SboxErrorCode.catalog, '目录 JSON 或签名无效');
