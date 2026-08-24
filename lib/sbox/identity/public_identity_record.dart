import 'dart:convert';
import 'dart:typed_data';

import '../bytes.dart';
import 'der.dart';
import 'rsa_identity_profile1.dart';
import 'rsa_models.dart';

const _compactPublicKeyPrefix = 'sboxpk1:';
const _compactPublicKeyChecksumBytes = 4;
const _profile1ModulusBytes = RsaIdentityProfile1.rsaBits ~/ 8;

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

  /// Encodes the public identity as the compact single-line format copied by
  /// SafeBox. Profile 1 fixes the exponent and DER wrapper, so only the
  /// 3072-bit modulus and a four-byte key-ID checksum need to be carried.
  String encode() {
    final identity = toPublicIdentity();
    final modulus = bigIntToFixedBytes(
      identity.rsaPublicKey.modulus,
      _profile1ModulusBytes,
    );
    final payload = concatBytes(<List<int>>[
      modulus,
      identity.recipientKeyId.sublist(0, _compactPublicKeyChecksumBytes),
    ]);
    return '$_compactPublicKeyPrefix'
        '${base64Url.encode(payload).replaceAll('=', '')}';
  }

  /// Retains the original verbose JSON representation for persisted data and
  /// compatibility with SDK clients that have not adopted `sboxpk1:` yet.
  String encodeJson() => jsonEncode(toJson());

  /// Decodes either the compact copied format or the legacy public-identity
  /// JSON document.
  factory PublicIdentityRecord.decode(String input) {
    final value = input.trim();
    if (value.startsWith(_compactPublicKeyPrefix)) {
      return PublicIdentityRecord._fromCompact(value);
    }
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('Invalid public identity');
      }
      return PublicIdentityRecord.fromJson(decoded);
    } on FormatException {
      throw const FormatException('Invalid public identity');
    }
  }

  factory PublicIdentityRecord._fromCompact(String value) {
    final encoded = value.substring(_compactPublicKeyPrefix.length);
    if (encoded.isEmpty ||
        encoded.contains('=') ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(encoded)) {
      throw const FormatException('Invalid compact public key encoding');
    }

    late final Uint8List payload;
    try {
      final padding = '=' * ((4 - encoded.length % 4) % 4);
      payload = Uint8List.fromList(base64Url.decode('$encoded$padding'));
    } on FormatException {
      throw const FormatException('Invalid compact public key encoding');
    }
    if (payload.length !=
            _profile1ModulusBytes + _compactPublicKeyChecksumBytes ||
        base64Url.encode(payload).replaceAll('=', '') != encoded) {
      throw const FormatException('Invalid compact public key encoding');
    }

    final modulusBytes = payload.sublist(0, _profile1ModulusBytes);
    final modulus = bytesToBigInt(modulusBytes);
    if (modulus.bitLength != RsaIdentityProfile1.rsaBits || modulus.isEven) {
      throw const FormatException('Invalid compact RSA public key');
    }
    final key = SboxRsaPublicKey(
      modulus: modulus,
      exponent: BigInt.from(RsaIdentityProfile1.publicExponent),
    );
    final spkiDer = encodeRsaSubjectPublicKeyInfo(key);
    final recipientKeyId = sha256Bytes(spkiDer);
    final checksum = payload.sublist(_profile1ModulusBytes);
    if (!constantTimeBytesEqual(
      checksum,
      recipientKeyId.sublist(0, _compactPublicKeyChecksumBytes),
    )) {
      throw const FormatException('Compact public key checksum mismatch');
    }
    return PublicIdentityRecord(
      spkiDer: spkiDer,
      recipientKeyId: recipientKeyId,
    );
  }

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
