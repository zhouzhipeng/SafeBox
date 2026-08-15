import 'dart:convert';

import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/engine/container_codec.dart';
import 'package:safebox/sbox/errors.dart';
import 'package:safebox/sbox/identity/bip39_identity.dart';
import 'package:safebox/sbox/identity/rsa_models.dart';
import 'package:test/test.dart';

void main() {
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon about';
  late EphemeralIdentity identity;
  late List<int> vector;
  final codec = SboxContainerCodec();

  setUpAll(() async {
    identity = await SboxIdentityDeriver().deriveIdentity(mnemonic);
    vector = await codec.encryptBytes(
      recipient: identity.publicIdentity,
      contentKind: SboxContentKind.text,
      originalName: 'hello.txt',
      mediaType: 'text/plain; charset=utf-8',
      data: utf8.encode('hello SBOX\n'),
      randomness: SboxEncryptionRandomness(
        fileId: decodeHex('000102030405060708090a0b0c0d0e0f'),
        dek: decodeHex(
          '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f',
        ),
        noncePrefix: decodeHex('a0a1a2a3'),
        oaepSeed: decodeHex(
          '202122232425262728292a2b2c2d2e2f'
          '303132333435363738393a3b3c3d3e3f',
        ),
      ),
    );
  });

  tearDownAll(() {
    identity.disposeControlledSecrets();
  });

  test('complete SBOX bytes match the interoperability vector', () {
    expect(vector.length, 664);
    expect(
      hexLower(sha256Bytes(vector)),
      '107e8cee375d787593432b713acaca2396e17bc370616646aa54d33df699497e',
    );
    expect(
      base64.encode(vector),
      'U0JPWA0KGgoBAAHUAAAAAAABAAEAAQAAAEAAAAABAgMEBQYHCAkKCwwNDg+VScQX'
      'RNO0acUSqiyEVneUCTf9IGhSIPsOsA8VCCsErqChoqMBgAAAaWEqGuJoPN/GLKOe'
      'pxlLyNkHakFdOb1ovqPHJ+ACwrP7kKlPOEh4kptOXGyqEAQ3BfezCzj/pAiFwpwh'
      'n8udfgEuLdA/4V3ar/gi/f9qzIe/flK2MjYldvGwXQLwEH+RyK5AE2jOOIubgdQK'
      '3kGp4jOCAiwCyW1mB6zcms5I3jEtDHE31MxNwN2JyK/nbREttl29RonB2491DjC5'
      '15xw78RePSeJTR+kEbZXg6vz7jV11X4pBLsafKbA36NuX8XmqbEegITTu0kjqPyU'
      'PmAnsfRFzjQpCcTJiYY4VdVyXY9UVmelleuxPeVPO/c+pxmIEEp8JQFR4m5hMk1x'
      '6bypsOP9rIWZcgagKAqtr1efFJEItPX2bs/sNqnJmMDyFMG9rD+NNb2XU9uvmXkh'
      'vmNnCrtjgvn9aFDY1WzCbjMewYRE4/r0HGvFbMf558CjyKq0AJinJ2ORUfoLDuHS'
      'wSugwRETRXecKYyWjgP35fkzYwl/ms7rBsmviE/wTbs2fBBAAQAAAAAAAAAAAAAA'
      'Mh27XDYjZLW8uTu7OFHTZcL69XEplmPhbRdBoExPdTowrrsTk3P9y43yiKS6b/8H'
      '6lQcmiqDGpuqP+KsqkzNxDFMtwIAAAAAAAAAAQAAAAvYytTiA1SV9lSCp16dxAlg'
      'kIxJWhhI3m9L2V3/AAAAAAAAAAIAAAAw67Ojm6cSkthAfO3BoYpPuGKTW3zNmhOg'
      'COqb+Tba7yBaqxZAYBVFjtxKR8Zhs8TbSE9jK7xZB5fvmvScHCJh9A==',
    );
  });

  test('complete vector decrypts only after all records verify', () async {
    final result = await codec.decryptBytes(
      container: vector,
      privateKey: identity.rsaPrivateKey,
      expectedRecipientKeyId: identity.publicIdentity.recipientKeyId,
    );
    expect(result.metadata.contentKind, SboxContentKind.text);
    expect(result.metadata.originalName, 'hello.txt');
    expect(result.metadata.mediaType, 'text/plain; charset=utf-8');
    expect(utf8.decode(result.data), 'hello SBOX\n');
  });

  test(
    'header, tag, truncation and trailing data tampering fail closed',
    () async {
      Future<void> expectFailure(List<int> candidate) async {
        await expectLater(
          codec.decryptBytes(
            container: candidate,
            privateKey: identity.rsaPrivateKey,
            expectedRecipientKeyId: identity.publicIdentity.recipientKeyId,
          ),
          throwsA(isA<SboxException>()),
        );
      }

      final changedHeader = List<int>.from(vector)..[30] ^= 1;
      final changedTag = List<int>.from(vector)..[550] ^= 1;
      final truncated = vector.sublist(0, vector.length - 77);
      final trailing = <int>[...vector, 0];
      await expectFailure(changedHeader);
      await expectFailure(changedTag);
      await expectFailure(truncated);
      await expectFailure(trailing);
    },
  );

  test('deterministic mutation fuzz corpus always fails closed', () async {
    var state = 0x5b0_0001;
    for (var index = 0; index < 32; index++) {
      state = (1664525 * state + 1013904223) & 0xffffffff;
      final position = state % vector.length;
      state = (1664525 * state + 1013904223) & 0xffffffff;
      final bit = 1 << (state & 7);
      final candidate = List<int>.from(vector)..[position] ^= bit;
      await expectLater(
        codec.decryptBytes(
          container: candidate,
          privateKey: identity.rsaPrivateKey,
          expectedRecipientKeyId: identity.publicIdentity.recipientKeyId,
        ),
        throwsA(isA<SboxException>()),
        reason: 'mutation $index at byte $position must not publish plaintext',
      );
    }
  });
}
