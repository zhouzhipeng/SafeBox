import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../bytes.dart';
import '../constants.dart';
import '../errors.dart';
import '../identity/der.dart';
import '../identity/rsa_models.dart';

/// HKDF-SHA256 for the public-key-readable v3 Manifest.
///
/// This class deliberately requires the complete, canonical SPKI DER. A key
/// ID, PEM string, modulus or any other public identifier is not accepted as
/// the HKDF input.
abstract final class MetadataKdf {
  static Uint8List derive({
    required List<int> spkiDer,
    required List<int> metadataSalt,
    required List<int> bundleId,
    required List<int> recipientKeyId,
    required int formatId,
  }) {
    if (metadataSalt.length != SboxProtocol.metadataSaltLength ||
        bundleId.length != SboxProtocol.bundleIdLength ||
        recipientKeyId.length != SboxProtocol.recipientKeyIdLength ||
        formatId < 0 ||
        formatId > 0xffff) {
      throw const SboxException(
        SboxErrorCode.invalidHeader,
        'Metadata 密钥参数无效',
      );
    }

    final publicKey = _parseCanonicalSpki(spkiDer);
    if (publicKey.modulus.bitLength != SboxProtocol.rsaBits ||
        publicKey.exponent != BigInt.from(SboxProtocol.rsaPublicExponent) ||
        !constantTimeBytesEqual(sha256Bytes(spkiDer), recipientKeyId)) {
      throw const SboxException(SboxErrorCode.keyMismatch, 'RSA 公共身份不匹配');
    }

    final info = buildInfo(
      bundleId: bundleId,
      recipientKeyId: recipientKeyId,
      formatId: formatId,
    );
    final prk = Uint8List.fromList(
      crypto.Hmac(crypto.sha256, metadataSalt).convert(spkiDer).bytes,
    );
    final expandInput = concatBytes(<List<int>>[info, const <int>[1]]);
    try {
      return Uint8List.fromList(
        crypto.Hmac(crypto.sha256, prk).convert(expandInput).bytes,
      );
    } finally {
      info.fillRange(0, info.length, 0);
      prk.fillRange(0, prk.length, 0);
      expandInput.fillRange(0, expandInput.length, 0);
    }
  }

  static Uint8List buildInfo({
    required List<int> bundleId,
    required List<int> recipientKeyId,
    required int formatId,
  }) {
    if (bundleId.length != SboxProtocol.bundleIdLength ||
        recipientKeyId.length != SboxProtocol.recipientKeyIdLength ||
        formatId < 0 ||
        formatId > 0xffff) {
      throw ArgumentError('Invalid Metadata KDF info inputs');
    }
    final format = Uint8List(2);
    writeUint16BigEndian(format, 0, formatId);
    return concatBytes(<List<int>>[
      asciiBytes('SBOX-v3/metadata-key'),
      const <int>[0],
      bundleId,
      recipientKeyId,
      format,
    ]);
  }

  static SboxRsaPublicKey _parseCanonicalSpki(List<int> input) {
    try {
      final key = parseRsaSubjectPublicKeyInfo(input);
      final canonical = encodeRsaSubjectPublicKeyInfo(key);
      if (!constantTimeBytesEqual(canonical, input)) {
        throw const FormatException('Non-canonical SPKI DER');
      }
      return key;
    } on FormatException {
      throw const SboxException(SboxErrorCode.keyMismatch, 'RSA 公共身份无效');
    } on ArgumentError {
      throw const SboxException(SboxErrorCode.keyMismatch, 'RSA 公共身份无效');
    }
  }
}
