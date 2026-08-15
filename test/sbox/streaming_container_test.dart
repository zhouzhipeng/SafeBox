import 'dart:io';

import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/engine/container_codec.dart';
import 'package:safebox/sbox/engine/job_control.dart';
import 'package:safebox/sbox/engine/streaming_container.dart';
import 'package:safebox/sbox/identity/bip39_identity.dart';
import 'package:safebox/sbox/identity/ephemeral_mnemonic.dart';
import 'package:safebox/sbox/identity/rsa_models.dart';
import 'package:test/test.dart';

void main() {
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon about';
  late EphemeralIdentity identity;
  late Directory temporaryDirectory;

  setUpAll(() async {
    identity = await SboxIdentityDeriver().deriveIdentity(mnemonic);
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'safebox-stream-test-',
    );
  });

  tearDownAll(() async {
    identity.disposeControlledSecrets();
    await temporaryDirectory.delete(recursive: true);
  });

  test('streaming API reproduces and decrypts the complete vector', () async {
    final encryptedFile = File('${temporaryDirectory.path}/vector.sbox');
    final plaintextFile = File('${temporaryDirectory.path}/verified.txt');
    final data = utf8Bytes('hello SBOX\n');
    final artifact = await encryptContainer(
      input: Stream<List<int>>.fromIterable(<List<int>>[
        data.sublist(0, 3),
        const <int>[],
        data.sublist(3),
      ]),
      inputLength: data.length,
      stagedOutput: encryptedFile.openWrite(mode: FileMode.writeOnly),
      options: EncryptOptions(
        recipient: identity.publicIdentity,
        contentKind: SboxContentKind.text,
        originalName: 'hello.txt',
        mediaType: 'text/plain; charset=utf-8',
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
      ),
      control: JobControl(),
    );
    expect(artifact.sboxLength, 664);
    expect(
      hexLower(artifact.sboxSha256),
      '107e8cee375d787593432b713acaca2396e17bc370616646aa54d33df699497e',
    );

    final verified = await decryptSingleContainerWithMnemonic(
      input: encryptedFile.openRead(),
      stagedPlaintext: plaintextFile.openWrite(mode: FileMode.writeOnly),
      mnemonic: EphemeralMnemonic.fromString(mnemonic),
      expectedIdentity: identity.publicIdentity,
      control: JobControl(),
    );
    expect(verified.metadata.originalName, 'hello.txt');
    expect(await plaintextFile.readAsString(), 'hello SBOX\n');
  });

  test('declared stream length is enforced in both directions', () async {
    final shortFile = File('${temporaryDirectory.path}/short.sbox');
    await expectLater(
      encryptContainer(
        input: Stream<List<int>>.value(const <int>[1, 2]),
        inputLength: 3,
        stagedOutput: shortFile.openWrite(mode: FileMode.writeOnly),
        options: EncryptOptions(
          recipient: identity.publicIdentity,
          contentKind: SboxContentKind.file,
          originalName: 'short.bin',
          mediaType: 'application/octet-stream',
        ),
        control: JobControl(),
      ),
      throwsA(anything),
    );

    final longFile = File('${temporaryDirectory.path}/long.sbox');
    await expectLater(
      encryptContainer(
        input: Stream<List<int>>.value(const <int>[1, 2, 3]),
        inputLength: 2,
        stagedOutput: longFile.openWrite(mode: FileMode.writeOnly),
        options: EncryptOptions(
          recipient: identity.publicIdentity,
          contentKind: SboxContentKind.file,
          originalName: 'long.bin',
          mediaType: 'application/octet-stream',
        ),
        control: JobControl(),
      ),
      throwsA(anything),
    );
  });
}
