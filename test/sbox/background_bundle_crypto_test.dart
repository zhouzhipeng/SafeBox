import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/engine/background_bundle_crypto.dart';
import 'package:safebox/sbox/engine/bundle_decryptor.dart';
import 'package:safebox/sbox/engine/bundle_encryptor.dart';
import 'package:safebox/sbox/errors.dart';
import 'package:safebox/sbox/format/bundle_header.dart';
import 'package:safebox/sbox/identity/bip39_identity.dart';
import 'package:safebox/sbox/identity/rsa_models.dart';
import 'package:test/test.dart';

void main() {
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon about';
  late final EphemeralIdentity identity;

  setUpAll(() async {
    identity = await SboxIdentityDeriver().deriveIdentity(mnemonic);
  });

  tearDownAll(() => identity.disposeControlledSecrets());

  test(
    'runs hashing, encryption and decryption outside the UI isolate',
    () async {
      final plaintext = Uint8List(1 * 1024 * 1024 + 17);
      plaintext[0] = 0x31;
      plaintext[plaintext.length - 1] = 0x39;
      final input = MemoryBundleInput(plaintext);
      final directory = await Directory.systemTemp.createTemp(
        'sbox-background-',
      );
      final output = File(
        '${directory.path}${Platform.pathSeparator}restored.bin',
      );
      final progressReceiver = _UiLikeProgressReceiver();
      try {
        final digest = await BackgroundBundleCrypto.md5ForInput(
          input: input,
          declaredLength: plaintext.length,
        );
        expect(digest, crypto.md5.convert(plaintext).bytes);
        digest.fillRange(0, digest.length, 0);

        final names = await BackgroundBundleCrypto.encryptToDirectory(
          input: input,
          declaredLength: plaintext.length,
          options: BundleEncryptionOptions(
            recipient: identity.publicIdentity,
            contentKind: SboxContentKind.file,
            originalName: 'background.bin',
            mediaType: 'application/octet-stream',
            createdAt: '2026-08-18T00:00:00Z',
            targetNominalShardPlaintextSize: 1024 * 1024,
          ),
          root: directory,
          onProgress: progressReceiver.handleEncryption,
        );
        expect(names, hasLength(2));
        expect(
          progressReceiver.encryption.any(
            (item) => item.stage == BundleEncryptionStage.splitting,
          ),
          isTrue,
        );
        expect(
          progressReceiver.encryption.any(
            (item) => item.stage == BundleEncryptionStage.encrypting,
          ),
          isTrue,
        );

        final objects = <String, List<int>>{
          for (final name in names)
            name: await File('${directory.path}${Platform.pathSeparator}$name')
                .readAsBytes(),
        };
        final root = objects.entries.firstWhere(
          (entry) => BundleHeader.parse(entry.value).isRoot,
        );
        final listed = await BackgroundBundleCrypto.readManifest(
          basename: root.key,
          objectPrefix: root.value,
          identity: identity.publicIdentity,
        );
        expect(listed.manifest?.originalName, 'background.bin');

        final decrypted = await BackgroundBundleCrypto.decrypt(
          objects: objects,
          mnemonic: mnemonic,
          onProgress: progressReceiver.handleDecryption,
        );
        expect(decrypted.plaintext, plaintext);
        decrypted.plaintext.fillRange(0, decrypted.plaintext.length, 0);

        await expectLater(
          BackgroundBundleCrypto.decrypt(
            objects: objects,
            mnemonic:
                'abandon abandon abandon abandon abandon abandon abandon '
                'abandon abandon abandon abandon abandon',
          ),
          throwsA(isA<SboxException>()),
        );

        await BackgroundBundleCrypto.decryptToFile(
          objects: objects,
          mnemonic: mnemonic,
          destination: output,
          onProgress: progressReceiver.handleDecryption,
        );
        expect(await output.readAsBytes(), plaintext);
        expect(progressReceiver.decryption, isNotEmpty);
      } finally {
        progressReceiver.dispose();
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    },
  );
}

/// Models a Flutter State/controller bound callback. [ReceivePort] is
/// deliberately unsendable, so an isolate launcher must not capture this
/// receiver while forwarding progress events.
final class _UiLikeProgressReceiver {
  _UiLikeProgressReceiver() : _unsendablePort = ReceivePort();

  final ReceivePort _unsendablePort;
  final List<BundleEncryptionProgress> encryption =
      <BundleEncryptionProgress>[];
  final List<BundleDecryptionProgress> decryption =
      <BundleDecryptionProgress>[];

  void handleEncryption(BundleEncryptionProgress progress) {
    encryption.add(progress);
  }

  void handleDecryption(BundleDecryptionProgress progress) {
    decryption.add(progress);
  }

  void dispose() => _unsendablePort.close();
}
