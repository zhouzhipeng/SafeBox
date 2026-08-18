import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import '../bytes.dart';
import '../constants.dart';
import '../errors.dart';

final class MetadataCiphertext {
  MetadataCiphertext({required List<int> ciphertext, required List<int> tag})
    : ciphertext = Uint8List.fromList(ciphertext),
      tag = Uint8List.fromList(tag) {
    if (this.ciphertext.length != SboxProtocol.metadataCiphertextLength ||
        this.tag.length != SboxProtocol.gcmTagLength) {
      throw ArgumentError('Invalid Metadata ciphertext dimensions');
    }
  }

  final Uint8List ciphertext;
  final Uint8List tag;

  void dispose() {
    ciphertext.fillRange(0, ciphertext.length, 0);
    tag.fillRange(0, tag.length, 0);
  }
}

/// Fixed-parameter AES-256-GCM for the v3 Header Manifest block.
final class MetadataCipher {
  MetadataCipher() : _aesGcm = DartAesGcm.with256bits(nonceLength: 12);

  final DartAesGcm _aesGcm;

  Future<MetadataCiphertext> encrypt({
    required List<int> key,
    required List<int> nonce,
    required List<int> plaintext,
    required List<int> aad,
  }) async {
    _validate(key: key, nonce: nonce, plaintext: plaintext, aad: aad);
    final box = await _aesGcm.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: aad,
    );
    return MetadataCiphertext(
      ciphertext: box.cipherText,
      tag: box.mac.bytes,
    );
  }

  Future<Uint8List> decrypt({
    required List<int> key,
    required List<int> nonce,
    required List<int> ciphertext,
    required List<int> tag,
    required List<int> aad,
  }) async {
    if (key.length != SboxProtocol.bundleDekLength ||
        nonce.length != SboxProtocol.metadataNonceLength ||
        ciphertext.length != SboxProtocol.metadataCiphertextLength ||
        tag.length != SboxProtocol.gcmTagLength ||
        aad.length !=
            SboxProtocol.metadataAadPrefixLength +
                1 +
                SboxProtocol.metadataAadHeaderLength) {
      throw const SboxException(SboxErrorCode.invalidHeader, 'Metadata 参数无效');
    }
    try {
      final plaintext = await _aesGcm.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(tag)),
        secretKey: SecretKey(key),
        aad: aad,
      );
      if (plaintext.length != SboxProtocol.metadataBlockLength) {
        throw const SboxException(
          SboxErrorCode.invalidManifest,
          'Metadata 块长度无效',
        );
      }
      return Uint8List.fromList(plaintext);
    } on SboxException {
      rethrow;
    } catch (_) {
      throw const SboxException(SboxErrorCode.authentication, 'Metadata 认证失败');
    }
  }

  static Uint8List buildAad(List<int> rootHeaderPrefix) {
    if (rootHeaderPrefix.length != SboxProtocol.metadataAadHeaderLength) {
      throw ArgumentError('Expected root header bytes [0,576)');
    }
    return concatBytes(<List<int>>[
      asciiBytes('SBOX-v3/metadata'),
      const <int>[0],
      rootHeaderPrefix,
    ]);
  }

  static void _validate({
    required List<int> key,
    required List<int> nonce,
    required List<int> plaintext,
    required List<int> aad,
  }) {
    if (key.length != SboxProtocol.bundleDekLength ||
        nonce.length != SboxProtocol.metadataNonceLength ||
        plaintext.length != SboxProtocol.metadataBlockLength ||
        aad.length !=
            SboxProtocol.metadataAadPrefixLength +
                1 +
                SboxProtocol.metadataAadHeaderLength) {
      throw ArgumentError('Invalid Metadata cipher dimensions');
    }
  }
}
