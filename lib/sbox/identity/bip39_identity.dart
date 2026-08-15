import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../bytes.dart';
import '../constants.dart';
import '../crypto/secret_bytes.dart';
import '../errors.dart';
import 'der.dart';
import 'hmac_drbg.dart';
import 'primality.dart';
import 'rsa_models.dart';

final class SboxIdentityDeriver {
  SboxIdentityDeriver({Random? secureRandom})
    : _secureRandom = secureRandom ?? Random.secure();

  final Random _secureRandom;

  String generateMnemonic() {
    final entropy = secureRandomBytes(16, random: _secureRandom);
    try {
      return bip39.entropyToMnemonic(hexLower(entropy));
    } finally {
      entropy.fillRange(0, entropy.length, 0);
    }
  }

  String normalizeAndValidateMnemonic(String mnemonic) {
    final normalized = unorm
        .nfkd(mnemonic)
        .trim()
        .split(RegExp(r'\s+'))
        .join(' ');
    final words = normalized.split(' ');
    if (words.length != 12 ||
        words.any((word) => !RegExp(r'^[a-z]+$').hasMatch(word)) ||
        !bip39.validateMnemonic(normalized)) {
      throw const SboxException(
        SboxErrorCode.invalidMnemonic,
        '助记词必须是校验有效的 12 个 BIP39 英文单词',
      );
    }
    return normalized;
  }

  Uint8List deriveBip39Seed(String mnemonic) {
    final normalized = normalizeAndValidateMnemonic(mnemonic);
    return Uint8List.fromList(bip39.mnemonicToSeed(normalized, passphrase: ''));
  }

  Future<Uint8List> deriveRsaDrbgOkm(List<int> bip39Seed) {
    return _hkdf(
      inputKeyMaterial: bip39Seed,
      salt: SboxV1.rsaHkdfSalt,
      info: SboxV1.rsaHkdfInfo,
      length: 48,
    );
  }

  Future<Uint8List> deriveCatalogSigningSeed(List<int> bip39Seed) {
    return _hkdf(
      inputKeyMaterial: bip39Seed,
      salt: SboxV1.catalogHkdfSalt,
      info: SboxV1.catalogHkdfInfo,
      length: 32,
    );
  }

  Future<EphemeralIdentity> deriveIdentity(String mnemonic) async {
    final bip39Seed = SecretBytes(deriveBip39Seed(mnemonic));
    Uint8List? drbgOkm;
    Uint8List? catalogSeed;
    HmacDrbgSha256? drbg;
    try {
      final outputs = await Future.wait<Uint8List>(<Future<Uint8List>>[
        deriveRsaDrbgOkm(bip39Seed.bytes),
        deriveCatalogSigningSeed(bip39Seed.bytes),
      ]);
      drbgOkm = outputs[0];
      catalogSeed = outputs[1];

      drbg = HmacDrbgSha256(
        entropyInput: Uint8List.sublistView(drbgOkm, 0, 32),
        nonce: Uint8List.sublistView(drbgOkm, 32, 48),
        personalization: asciiBytes(SboxV1.rsaPersonalization),
      );
      final rsa = DeterministicRsa3072Generator(drbg).generate();
      final spkiDer = encodeRsaSubjectPublicKeyInfo(rsa.privateKey.publicKey);
      final recipientKeyId = sha256Bytes(spkiDer);

      final ed25519 = DartEd25519();
      final signingKeyPair = await ed25519.newKeyPairFromSeed(catalogSeed);
      final signingPublicKey = await signingKeyPair.extractPublicKey();
      final signingPublicBytes = Uint8List.fromList(signingPublicKey.bytes);
      final signerKeyId = sha256Bytes(signingPublicBytes);

      final publicIdentity = PublicIdentity(
        rsaPublicKey: rsa.privateKey.publicKey,
        spkiDer: spkiDer,
        spkiPem: encodePublicKeyPem(spkiDer),
        recipientKeyId: recipientKeyId,
        catalogSigningPublicKey: signingPublicBytes,
        catalogSignerKeyId: signerKeyId,
      );
      return EphemeralIdentity(
        publicIdentity: publicIdentity,
        rsaPrivateKey: rsa.privateKey,
        catalogSigningSeed: catalogSeed,
        pCandidateCount: rsa.pCandidateCount,
        qCandidateCount: rsa.qCandidateCount,
      );
    } on SboxException {
      rethrow;
    } catch (_) {
      throw const SboxException(
        SboxErrorCode.identityDerivation,
        '身份派生失败；没有生成或保存任何私钥',
      );
    } finally {
      bip39Seed.dispose();
      drbg?.dispose();
      drbgOkm?.fillRange(0, drbgOkm.length, 0);
      // The returned identity owns its copy. The local derivation buffer can be
      // overwritten regardless of success.
      catalogSeed?.fillRange(0, catalogSeed.length, 0);
    }
  }

  Future<Uint8List> _hkdf({
    required List<int> inputKeyMaterial,
    required String salt,
    required String info,
    required int length,
  }) async {
    final algorithm = DartHkdf(hmac: Hmac.sha512(), outputLength: length);
    final derived = await algorithm.deriveKey(
      secretKey: SecretKey(inputKeyMaterial),
      nonce: ascii.encode(salt),
      info: ascii.encode(info),
    );
    return Uint8List.fromList(await derived.extractBytes());
  }
}
