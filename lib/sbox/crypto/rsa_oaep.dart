import 'dart:math';
import 'dart:typed_data';

import '../bytes.dart';
import '../constants.dart';
import '../errors.dart';
import '../identity/rsa_models.dart';

/// RFC 8017 RSAES-OAEP using SHA-256 for both Hash and MGF1.
///
/// Hashing is delegated to package:crypto and modular exponentiation to the
/// Dart runtime's BigInt implementation. Private operations use multiplicative
/// blinding plus CRT and expose one uniform decryption error.
final class RsaOaepSha256 {
  RsaOaepSha256({Random? secureRandom})
    : _secureRandom = secureRandom ?? Random.secure();

  static const int _hashLength = 32;
  final Random _secureRandom;

  Uint8List encrypt({
    required List<int> message,
    required SboxRsaPublicKey publicKey,
    required List<int> label,
    List<int>? seed,
  }) {
    final modulusLength = publicKey.modulusBytes;
    if (message.length > modulusLength - 2 * _hashLength - 2) {
      throw ArgumentError.value(message.length, 'message', 'Message too long');
    }
    if (seed != null && seed.length != _hashLength) {
      throw ArgumentError.value(seed.length, 'seed', 'Expected 32 bytes');
    }

    final oaepSeed = Uint8List.fromList(
      seed ?? secureRandomBytes(_hashLength, random: _secureRandom),
    );
    final labelHash = sha256Bytes(label);
    final dataBlockLength = modulusLength - _hashLength - 1;
    final dataBlock = Uint8List(dataBlockLength);
    dataBlock.setRange(0, _hashLength, labelHash);
    final separatorIndex = dataBlockLength - message.length - 1;
    dataBlock[separatorIndex] = 0x01;
    dataBlock.setRange(separatorIndex + 1, dataBlockLength, message);

    final dataMask = _mgf1(oaepSeed, dataBlockLength);
    final maskedDataBlock = _xor(dataBlock, dataMask);
    final seedMask = _mgf1(maskedDataBlock, _hashLength);
    final maskedSeed = _xor(oaepSeed, seedMask);
    final encodedMessage = Uint8List(modulusLength)
      ..setRange(1, 1 + _hashLength, maskedSeed)
      ..setRange(1 + _hashLength, modulusLength, maskedDataBlock);

    try {
      final messageRepresentative = bytesToBigInt(encodedMessage);
      if (messageRepresentative >= publicKey.modulus) {
        throw StateError('OAEP representative is out of range');
      }
      final ciphertext = messageRepresentative.modPow(
        publicKey.exponent,
        publicKey.modulus,
      );
      return bigIntToFixedBytes(ciphertext, modulusLength);
    } finally {
      oaepSeed.fillRange(0, oaepSeed.length, 0);
      labelHash.fillRange(0, labelHash.length, 0);
      dataBlock.fillRange(0, dataBlock.length, 0);
      dataMask.fillRange(0, dataMask.length, 0);
      maskedDataBlock.fillRange(0, maskedDataBlock.length, 0);
      seedMask.fillRange(0, seedMask.length, 0);
      maskedSeed.fillRange(0, maskedSeed.length, 0);
      encodedMessage.fillRange(0, encodedMessage.length, 0);
    }
  }

  Uint8List decrypt({
    required List<int> ciphertext,
    required SboxRsaPrivateKey privateKey,
    required List<int> label,
  }) {
    final modulus = privateKey.publicKey.modulus;
    final modulusLength = privateKey.publicKey.modulusBytes;
    var invalid = ciphertext.length == modulusLength ? 0 : 1;
    final normalizedCiphertext = Uint8List(modulusLength);
    if (ciphertext.length == modulusLength) {
      normalizedCiphertext.setAll(0, ciphertext);
    }
    var ciphertextRepresentative = bytesToBigInt(normalizedCiphertext);
    if (ciphertextRepresentative >= modulus) {
      invalid = 1;
      ciphertextRepresentative %= modulus;
    }

    Uint8List? encodedMessage;
    Uint8List? seedMask;
    Uint8List? seed;
    Uint8List? dataMask;
    Uint8List? dataBlock;
    Uint8List? labelHash;
    try {
      final messageRepresentative = _blindedPrivateOperation(
        ciphertextRepresentative,
        privateKey,
      );
      if (messageRepresentative.modPow(
            privateKey.publicKey.exponent,
            modulus,
          ) !=
          ciphertextRepresentative) {
        invalid = 1;
      }
      encodedMessage = bigIntToFixedBytes(messageRepresentative, modulusLength);
      invalid |= encodedMessage[0];

      final maskedSeed = Uint8List.sublistView(
        encodedMessage,
        1,
        1 + _hashLength,
      );
      final maskedDataBlock = Uint8List.sublistView(
        encodedMessage,
        1 + _hashLength,
      );
      seedMask = _mgf1(maskedDataBlock, _hashLength);
      seed = _xor(maskedSeed, seedMask);
      dataMask = _mgf1(seed, modulusLength - _hashLength - 1);
      dataBlock = _xor(maskedDataBlock, dataMask);
      labelHash = sha256Bytes(label);

      for (var index = 0; index < _hashLength; index++) {
        invalid |= dataBlock[index] ^ labelHash[index];
      }

      var lookingForSeparator = 1;
      var messageOffset = dataBlock.length;
      for (var index = _hashLength; index < dataBlock.length; index++) {
        final value = dataBlock[index];
        if (lookingForSeparator == 1) {
          if (value == 0x01) {
            lookingForSeparator = 0;
            messageOffset = index + 1;
          } else if (value != 0x00) {
            invalid = 1;
          }
        }
      }
      invalid |= lookingForSeparator;
      if (invalid != 0) {
        throw _decryptionError();
      }
      return Uint8List.fromList(dataBlock.sublist(messageOffset));
    } on SboxException {
      rethrow;
    } catch (_) {
      throw _decryptionError();
    } finally {
      normalizedCiphertext.fillRange(0, normalizedCiphertext.length, 0);
      encodedMessage?.fillRange(0, encodedMessage.length, 0);
      seedMask?.fillRange(0, seedMask.length, 0);
      seed?.fillRange(0, seed.length, 0);
      dataMask?.fillRange(0, dataMask.length, 0);
      dataBlock?.fillRange(0, dataBlock.length, 0);
      labelHash?.fillRange(0, labelHash.length, 0);
    }
  }

  BigInt _blindedPrivateOperation(BigInt ciphertext, SboxRsaPrivateKey key) {
    final modulus = key.publicKey.modulus;
    BigInt blindingFactor;
    do {
      final randomBytes = secureRandomBytes(
        key.publicKey.modulusBytes,
        random: _secureRandom,
      );
      blindingFactor = bytesToBigInt(randomBytes);
      randomBytes.fillRange(0, randomBytes.length, 0);
    } while (blindingFactor <= BigInt.one ||
        blindingFactor >= modulus ||
        blindingFactor.gcd(modulus) != BigInt.one);

    final blindedCiphertext =
        (ciphertext * blindingFactor.modPow(key.publicKey.exponent, modulus)) %
        modulus;
    final messageP = blindedCiphertext.modPow(key.dP, key.p);
    final messageQ = blindedCiphertext.modPow(key.dQ, key.q);
    final correction = positiveMod(key.qInv * (messageP - messageQ), key.p);
    final blindedMessage = messageQ + key.q * correction;
    return (blindedMessage * blindingFactor.modInverse(modulus)) % modulus;
  }

  static Uint8List buildDekLabel({
    required List<int> fileId,
    required List<int> recipientKeyId,
  }) {
    if (fileId.length != SboxV1.fileIdLength ||
        recipientKeyId.length != SboxV1.recipientKeyIdLength) {
      throw ArgumentError('Invalid SBOX OAEP label component length');
    }
    return concatBytes(<List<int>>[
      asciiBytes(SboxV1.oaepLabelPrefix),
      const <int>[0],
      fileId,
      recipientKeyId,
    ]);
  }

  static Uint8List _mgf1(List<int> seed, int outputLength) {
    final result = Uint8List(outputLength);
    var offset = 0;
    for (var counter = 0; offset < outputLength; counter++) {
      final counterBytes = Uint8List(4);
      writeUint32BigEndian(counterBytes, 0, counter);
      final digest = sha256Bytes(concatBytes(<List<int>>[seed, counterBytes]));
      final take = min(digest.length, outputLength - offset);
      result.setRange(offset, offset + take, digest);
      offset += take;
      counterBytes.fillRange(0, counterBytes.length, 0);
      digest.fillRange(0, digest.length, 0);
    }
    return result;
  }

  static Uint8List _xor(List<int> left, List<int> right) {
    if (left.length != right.length) {
      throw ArgumentError('XOR inputs must have equal lengths');
    }
    return Uint8List.fromList(
      List<int>.generate(
        left.length,
        (index) => left[index] ^ right[index],
        growable: false,
      ),
    );
  }

  static SboxException _decryptionError() =>
      const SboxException(SboxErrorCode.authentication, '密钥解封或密文认证失败');
}
