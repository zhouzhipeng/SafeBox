import 'dart:convert';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';

import '../bytes.dart';
import 'rsa_models.dart';
import 'rsa_identity_profile1.dart';

Uint8List encodeRsaSubjectPublicKeyInfo(SboxRsaPublicKey key) {
  if (key.exponent != BigInt.from(RsaIdentityProfile1.publicExponent) ||
      key.modulus.bitLength != RsaIdentityProfile1.rsaBits) {
    throw ArgumentError('RSA public key does not match Profile 1');
  }
  final rsaPublicKey = ASN1Sequence()
    ..add(ASN1Integer(key.modulus))
    ..add(ASN1Integer(key.exponent));

  final algorithmIdentifier = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.113549.1.1.1'))
    ..add(ASN1Null());

  final subjectPublicKeyInfo = ASN1Sequence()
    ..add(algorithmIdentifier)
    ..add(ASN1BitString(rsaPublicKey.encodedBytes));
  return Uint8List.fromList(subjectPublicKeyInfo.encodedBytes);
}

/// Strictly parses the DER form required by SBOX-PUBLIC-IDENTITY-1.
SboxRsaPublicKey parseRsaSubjectPublicKeyInfo(List<int> input) {
  final reader = _DerReader(input);
  final outer = reader.readConstructed(0x30);
  reader.expectEnd();

  final outerReader = _DerReader(outer);
  final algorithm = outerReader.readConstructed(0x30);
  final algorithmReader = _DerReader(algorithm);
  final oid = algorithmReader.readPrimitive(0x06);
  final nullParameters = algorithmReader.readPrimitive(0x05);
  algorithmReader.expectEnd();
  const rsaEncryptionOid = <int>[
    0x2a,
    0x86,
    0x48,
    0x86,
    0xf7,
    0x0d,
    0x01,
    0x01,
    0x01,
  ];
  if (!_sameBytes(oid, rsaEncryptionOid) || nullParameters.isNotEmpty) {
    throw const FormatException('Invalid RSA SubjectPublicKeyInfo algorithm');
  }

  final bitString = outerReader.readPrimitive(0x03);
  outerReader.expectEnd();
  if (bitString.isEmpty || bitString[0] != 0) {
    throw const FormatException('Invalid RSA SubjectPublicKeyInfo bit string');
  }
  final rsaReader = _DerReader(bitString.sublist(1));
  final rsaBody = rsaReader.readConstructed(0x30);
  rsaReader.expectEnd();
  final keyReader = _DerReader(rsaBody);
  final modulusBytes = keyReader.readPrimitive(0x02);
  final exponentBytes = keyReader.readPrimitive(0x02);
  keyReader.expectEnd();
  final modulus = _decodePositiveInteger(modulusBytes);
  final exponent = _decodePositiveInteger(exponentBytes);
  if (modulus.bitLength != RsaIdentityProfile1.rsaBits ||
      exponent != BigInt.from(RsaIdentityProfile1.publicExponent)) {
    throw const FormatException('Invalid RSA public key dimensions');
  }
  final key = SboxRsaPublicKey(modulus: modulus, exponent: exponent);
  // Parsing alone is not enough for the v3 Metadata KDF: the exact DER
  // spelling is part of the key material. Reject alternate encodings of the
  // same RSA modulus before the bytes can be used as an identity.
  if (!constantTimeBytesEqual(encodeRsaSubjectPublicKeyInfo(key), input)) {
    throw const FormatException('Non-canonical RSA SubjectPublicKeyInfo');
  }
  return key;
}

String encodePublicKeyPem(List<int> spkiDer) {
  final encoded = base64.encode(spkiDer);
  final lines = <String>['-----BEGIN PUBLIC KEY-----'];
  for (var offset = 0; offset < encoded.length; offset += 64) {
    final end = (offset + 64).clamp(0, encoded.length);
    lines.add(encoded.substring(offset, end));
  }
  lines.add('-----END PUBLIC KEY-----');
  return '${lines.join('\n')}\n';
}

BigInt _decodePositiveInteger(List<int> bytes) {
  if (bytes.isEmpty ||
      (bytes.length > 1 && bytes[0] == 0 && bytes[1] < 0x80) ||
      (bytes[0] & 0x80) != 0) {
    throw const FormatException('Invalid DER INTEGER');
  }
  return bytesToBigInt(bytes[0] == 0 ? bytes.sublist(1) : bytes);
}

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

final class _DerReader {
  _DerReader(List<int> bytes) : _bytes = Uint8List.fromList(bytes);

  final Uint8List _bytes;
  int _offset = 0;

  Uint8List readConstructed(int expectedTag) {
    final value = _read(expectedTag);
    return value;
  }

  Uint8List readPrimitive(int expectedTag) => _read(expectedTag);

  Uint8List _read(int expectedTag) {
    if (_offset >= _bytes.length || _bytes[_offset++] != expectedTag) {
      throw const FormatException('Invalid DER tag');
    }
    final length = _readLength();
    if (length > _bytes.length - _offset) {
      throw const FormatException('Truncated DER value');
    }
    final result = Uint8List.fromList(
      _bytes.sublist(_offset, _offset + length),
    );
    _offset += length;
    return result;
  }

  int _readLength() {
    if (_offset >= _bytes.length) {
      throw const FormatException('Truncated DER length');
    }
    final first = _bytes[_offset++];
    if (first < 0x80) return first;
    final count = first & 0x7f;
    if (count == 0 || count > 4 || _offset + count > _bytes.length) {
      throw const FormatException('Invalid DER length');
    }
    if (_bytes[_offset] == 0) {
      throw const FormatException('Non-canonical DER length');
    }
    var length = 0;
    for (var index = 0; index < count; index++) {
      length = (length << 8) | _bytes[_offset++];
    }
    if (length < 0x80) {
      throw const FormatException('Non-canonical DER length');
    }
    return length;
  }

  void expectEnd() {
    if (_offset != _bytes.length) {
      throw const FormatException('Trailing DER value');
    }
  }
}
