import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/identity/bip39_identity.dart';
import 'package:safebox/sbox/identity/public_identity_record.dart';
import 'package:test/test.dart';

void main() {
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon about';

  test('the frozen RSA Profile 1 vector remains stable', () async {
    final deriver = SboxIdentityDeriver();
    final seed = deriver.deriveBip39Seed(mnemonic);
    expect(
      hexLower(seed),
      '5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc'
      '19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4',
    );
    final okm = await deriver.deriveRsaDrbgOkm(seed);
    expect(
      hexLower(okm),
      '1abf8d87ee7320c33c1d5d567a1c095ee166f5c8563d4f3cb2347f09ccfc543b'
      'e28e7fff1eebb75789d92fba9a0375da',
    );
    seed.fillRange(0, seed.length, 0);
    okm.fillRange(0, okm.length, 0);

    final identity = await deriver.deriveIdentity(mnemonic);
    try {
      expect(identity.pCandidateCount, 2600);
      expect(identity.qCandidateCount, 197);
      expect(
        hexLower(identity.publicIdentity.recipientKeyId),
        '9549c41744d3b469c512aa2c845677940937fd20685220fb0eb00f15082b04ae',
      );
      final record = PublicIdentityRecord.fromIdentity(identity.publicIdentity);
      final restored = PublicIdentityRecord.fromJson(record.toJson())
          .toPublicIdentity();
      expect(restored.recipientKeyId, identity.publicIdentity.recipientKeyId);
      expect(restored.spkiDer, identity.publicIdentity.spkiDer);
    } finally {
      identity.disposeControlledSecrets();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test(
    'only normalized, checksum-valid twelve-word mnemonics are accepted',
    () {
      final deriver = SboxIdentityDeriver();
      expect(deriver.normalizeAndValidateMnemonic('  $mnemonic  '), mnemonic);
      expect(
        () => deriver.deriveBip39Seed('abandon abandon abandon'),
        throwsA(anything),
      );
      expect(
        () => deriver.deriveBip39Seed(
          'abandon abandon abandon abandon abandon abandon abandon abandon '
          'abandon abandon abandon abandon',
        ),
        throwsA(anything),
      );
    },
  );
}
