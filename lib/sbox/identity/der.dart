import 'dart:convert';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';

import 'rsa_models.dart';

Uint8List encodeRsaSubjectPublicKeyInfo(SboxRsaPublicKey key) {
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
