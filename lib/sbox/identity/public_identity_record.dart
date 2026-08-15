import 'dart:convert';
import 'dart:typed_data';

import '../bytes.dart';
import 'der.dart';
import 'rsa_models.dart';

final class PublicIdentityRecord {
  PublicIdentityRecord({required this.identity}) {
    _validate(identity);
  }

  final PublicIdentity identity;

  Map<String, Object?> toJson() => <String, Object?>{
    'profile': 'SBOX-v1-RSA3072-Ed25519',
    'rsa_modulus_hex': identity.rsaPublicKey.modulus.toRadixString(16),
    'rsa_exponent': identity.rsaPublicKey.exponent.toInt(),
    'spki_der': base64Url.encode(identity.spkiDer).replaceAll('=', ''),
    'recipient_key_id': hexLower(identity.recipientKeyId),
    'catalog_signing_public_key': hexLower(identity.catalogSigningPublicKey),
    'catalog_signer_key_id': hexLower(identity.catalogSignerKeyId),
  };

  factory PublicIdentityRecord.fromJson(Map<String, Object?> json) {
    const keys = <String>{
      'profile',
      'rsa_modulus_hex',
      'rsa_exponent',
      'spki_der',
      'recipient_key_id',
      'catalog_signing_public_key',
      'catalog_signer_key_id',
    };
    if (json.length != keys.length ||
        json.keys.any((key) => !keys.contains(key)) ||
        json['profile'] != 'SBOX-v1-RSA3072-Ed25519' ||
        json['rsa_modulus_hex'] is! String ||
        json['rsa_exponent'] is! int ||
        json['spki_der'] is! String ||
        json['recipient_key_id'] is! String ||
        json['catalog_signing_public_key'] is! String ||
        json['catalog_signer_key_id'] is! String) {
      throw const FormatException('Invalid public identity record');
    }
    final modulusText = json['rsa_modulus_hex']! as String;
    if (!RegExp(r'^[0-9a-f]{768}$').hasMatch(modulusText)) {
      throw const FormatException('Invalid RSA public modulus');
    }
    final key = SboxRsaPublicKey(
      modulus: BigInt.parse(modulusText, radix: 16),
      exponent: BigInt.from(json['rsa_exponent']! as int),
    );
    final spki = _decodeBase64Url(json['spki_der']! as String);
    final identity = PublicIdentity(
      rsaPublicKey: key,
      spkiDer: spki,
      spkiPem: encodePublicKeyPem(spki),
      recipientKeyId: decodeHex(json['recipient_key_id']! as String),
      catalogSigningPublicKey: decodeHex(
        json['catalog_signing_public_key']! as String,
      ),
      catalogSignerKeyId: decodeHex(json['catalog_signer_key_id']! as String),
    );
    _validate(identity);
    return PublicIdentityRecord(identity: identity);
  }

  static void _validate(PublicIdentity identity) {
    final expectedDer = encodeRsaSubjectPublicKeyInfo(identity.rsaPublicKey);
    if (identity.rsaPublicKey.modulus.bitLength != 3072 ||
        identity.rsaPublicKey.exponent != BigInt.from(65537) ||
        !constantTimeBytesEqual(expectedDer, identity.spkiDer) ||
        identity.recipientKeyId.length != 32 ||
        !constantTimeBytesEqual(
          sha256Bytes(identity.spkiDer),
          identity.recipientKeyId,
        ) ||
        identity.catalogSigningPublicKey.length != 32 ||
        identity.catalogSignerKeyId.length != 32 ||
        !constantTimeBytesEqual(
          sha256Bytes(identity.catalogSigningPublicKey),
          identity.catalogSignerKeyId,
        )) {
      throw const FormatException('Public identity record failed validation');
    }
  }
}

Uint8List _decodeBase64Url(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw const FormatException('Invalid public identity encoding');
  }
  final padding = '=' * ((4 - value.length % 4) % 4);
  final result = Uint8List.fromList(base64Url.decode('$value$padding'));
  if (base64Url.encode(result).replaceAll('=', '') != value) {
    throw const FormatException('Invalid public identity encoding');
  }
  return result;
}
