import 'package:cryptography/dart.dart';
import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/identity/bip39_identity.dart';
import 'package:safebox/sbox/identity/der.dart';
import 'package:safebox/sbox/identity/hmac_drbg.dart';
import 'package:safebox/sbox/identity/primality.dart';
import 'package:test/test.dart';

void main() {
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon about';

  final deriver = SboxIdentityDeriver();

  test('BIP39 and HKDF values match SBOX v1 vector', () async {
    final seed = deriver.deriveBip39Seed(mnemonic);
    expect(
      hexLower(seed),
      '5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc'
      '19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4',
    );

    final drbgOkm = await deriver.deriveRsaDrbgOkm(seed);
    expect(
      hexLower(drbgOkm),
      '1abf8d87ee7320c33c1d5d567a1c095ee166f5c8563d4f3cb2347f09ccfc543b'
      'e28e7fff1eebb75789d92fba9a0375da',
    );

    final catalogSeed = await deriver.deriveCatalogSigningSeed(seed);
    expect(
      hexLower(catalogSeed),
      '05bfbbc1919ac84f114c3da35b31ae73e423d96b8bb217603fa90e1cfbf8edeb',
    );

    seed.fillRange(0, seed.length, 0);
    drbgOkm.fillRange(0, drbgOkm.length, 0);
    catalogSeed.fillRange(0, catalogSeed.length, 0);
  });

  test('RSA and Ed25519 public identity matches SBOX v1 vector', () async {
    final identity = await deriver.deriveIdentity(mnemonic);
    try {
      expect(identity.pCandidateCount, 2600);
      expect(identity.qCandidateCount, 197);
      expect(
        hexLower(identity.publicIdentity.recipientKeyId),
        '9549c41744d3b469c512aa2c845677940937fd20685220fb0eb00f15082b04ae',
      );
      expect(
        hexLower(identity.catalogSigningSeed),
        '05bfbbc1919ac84f114c3da35b31ae73e423d96b8bb217603fa90e1cfbf8edeb',
      );
      expect(
        hexLower(identity.publicIdentity.catalogSigningPublicKey),
        'b563122ff456cb55816c16b87cd0a6fdb7e798115f9851804d26142dfb7ec77b',
      );
      expect(
        hexLower(identity.publicIdentity.catalogSignerKeyId),
        'dc6c7e5d4cfc3c6bb5b364086fc8b68da0f7d8b041da907896d8c9b0ca060f2e',
      );
    } finally {
      identity.disposeControlledSecrets();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('deterministic RSA candidate counts match the profile', () async {
    final seed = deriver.deriveBip39Seed(mnemonic);
    final okm = await deriver.deriveRsaDrbgOkm(seed);
    final drbg = HmacDrbgSha256(
      entropyInput: okm.sublist(0, 32),
      nonce: okm.sublist(32),
      personalization: asciiBytes(SboxV1.rsaPersonalization),
    );
    try {
      final result = DeterministicRsa3072Generator(drbg).generate();
      expect(result.pCandidateCount, 2600);
      expect(result.qCandidateCount, 197);
      final spki = encodeRsaSubjectPublicKeyInfo(result.privateKey.publicKey);
      expect(
        hexLower(sha256Bytes(spki)),
        '9549c41744d3b469c512aa2c845677940937fd20685220fb0eb00f15082b04ae',
      );

      final catalogSeed = await deriver.deriveCatalogSigningSeed(seed);
      try {
        final keyPair = await DartEd25519().newKeyPairFromSeed(catalogSeed);
        final publicKey = await keyPair.extractPublicKey();
        expect(
          hexLower(publicKey.bytes),
          'b563122ff456cb55816c16b87cd0a6fdb7e798115f9851804d26142dfb7ec77b',
        );
      } finally {
        catalogSeed.fillRange(0, catalogSeed.length, 0);
      }
    } finally {
      seed.fillRange(0, seed.length, 0);
      okm.fillRange(0, okm.length, 0);
      drbg.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('invalid or non-12-word mnemonics are rejected', () {
    expect(
      () => deriver.deriveBip39Seed('abandon abandon abandon'),
      throwsA(anything),
    );
  });
}
