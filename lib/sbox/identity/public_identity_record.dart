import 'dart:convert';
import 'dart:typed_data';

import '../bytes.dart';
import 'der.dart';
import 'rsa_identity_profile1.dart';
import 'rsa_models.dart';

/// The exact persisted RSA-only public identity schema.
final class PublicIdentityRecord {
  const PublicIdentityRecord({
    required this.spkiDer,
    required this.recipientKeyId,
  });

  final Uint8List spkiDer;
  final Uint8List recipientKeyId;

  factory PublicIdentityRecord.fromIdentity(PublicIdentity identity) {
    return PublicIdentityRecord(
      spkiDer: identity.spkiDer,
      recipientKeyId: identity.recipientKeyId,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': 'SBOX-PUBLIC-IDENTITY-1',
    'key_profile_id': RsaIdentityProfile1.keyProfileId,
    'spki_der': base64Url.encode(spkiDer).replaceAll('=', ''),
    'recipient_key_id': hexLower(recipientKeyId),
  };

  PublicIdentity toPublicIdentity() {
    final publicKey = parseRsaSubjectPublicKeyInfo(spkiDer);
    final derived = sha256Bytes(spkiDer);
    if (!constantTimeBytesEqual(derived, recipientKeyId)) {
      throw const FormatException('Public identity key ID mismatch');
    }
    return PublicIdentity(
      rsaPublicKey: publicKey,
      spkiDer: spkiDer,
      spkiPem: encodePublicKeyPem(spkiDer),
      recipientKeyId: recipientKeyId,
    );
  }

  factory PublicIdentityRecord.fromJson(Map<String, Object?> json) {
    const keys = <String>{
      'schema',
      'key_profile_id',
      'spki_der',
      'recipient_key_id',
    };
    if (json.length != keys.length || !json.keys.toSet().containsAll(keys)) {
      throw const FormatException('Invalid public identity schema');
    }
    if (json['schema'] != 'SBOX-PUBLIC-IDENTITY-1' ||
        json['key_profile_id'] != RsaIdentityProfile1.keyProfileId ||
        json['spki_der'] is! String ||
        json['recipient_key_id'] is! String) {
      throw const FormatException('Invalid public identity schema');
    }
    final encodedDer = json['spki_der']! as String;
    final keyId = json['recipient_key_id']! as String;
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(keyId) ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(encodedDer) ||
        encodedDer.contains('=')) {
      throw const FormatException('Invalid public identity encoding');
    }
    late final Uint8List der;
    try {
      final padding = '=' * ((4 - encodedDer.length % 4) % 4);
      der = Uint8List.fromList(base64Url.decode('$encodedDer$padding'));
      if (base64Url.encode(der).replaceAll('=', '') != encodedDer) {
        throw const FormatException('Non-canonical public identity encoding');
      }
      parseRsaSubjectPublicKeyInfo(der);
    } on FormatException {
      throw const FormatException('Invalid public identity DER');
    }
    final decodedKeyId = decodeHex(keyId);
    if (!constantTimeBytesEqual(sha256Bytes(der), decodedKeyId)) {
      throw const FormatException('Public identity key ID mismatch');
    }
    return PublicIdentityRecord(spkiDer: der, recipientKeyId: decodedKeyId);
  }
}
