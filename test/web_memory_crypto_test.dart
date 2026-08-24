import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/engine/background_bundle_crypto.dart';
import 'package:safebox/sbox/engine/bundle_encryptor.dart';
import 'package:safebox/sbox/format/bundle_header.dart';
import 'package:safebox/sbox/identity/bip39_identity.dart';

void main() {
  test(
    'browser hashes, encrypts, reads metadata, and decrypts in memory',
    () async {
      const mnemonic =
          'abandon abandon abandon abandon abandon abandon abandon abandon '
          'abandon abandon abandon about';
      final identity = await SboxIdentityDeriver().deriveIdentity(mnemonic);
      final plaintext = Uint8List.fromList(
        List<int>.generate(96 * 1024 + 17, (index) => index & 0xff),
      );
      final input = MemoryBundleInput(plaintext);
      EncryptedBundle? encrypted;
      try {
        encrypted = await BundleEncryptor().encrypt(
          input: input,
          declaredLength: plaintext.length,
          options: BundleEncryptionOptions(
            recipient: identity.publicIdentity,
            contentKind: SboxContentKind.file,
            originalName: 'web-smoke.bin',
            mediaType: 'application/octet-stream',
            createdAt: '2026-08-24T00:00:00Z',
          ),
        );
        final root = encrypted.objects.firstWhere(
          (object) => BundleHeader.parse(object.bytes).isRoot,
        );
        final metadata = await BackgroundBundleCrypto.readMetadata(
          basename: root.basename,
          objectPrefix: root.bytes,
          identity: identity.publicIdentity,
        );
        expect(metadata.manifest?.originalName, 'web-smoke.bin');

        final decrypted = await BackgroundBundleCrypto.decrypt(
          objects: <String, List<int>>{
            for (final object in encrypted.objects)
              object.basename: object.bytes,
          },
          mnemonic: mnemonic,
          expectedIdentity: identity.publicIdentity,
        );
        try {
          expect(decrypted.plaintext, plaintext);
        } finally {
          decrypted.plaintext.fillRange(0, decrypted.plaintext.length, 0);
          decrypted.preview?.dispose();
        }
      } finally {
        input.dispose();
        plaintext.fillRange(0, plaintext.length, 0);
        final result = encrypted;
        if (result != null) {
          result.plaintextSha256.fillRange(0, result.plaintextSha256.length, 0);
          for (final object in result.objects) {
            object.bytes.fillRange(0, object.bytes.length, 0);
            object.sha256.fillRange(0, object.sha256.length, 0);
          }
          result.preview?.dispose();
        }
        identity.disposeControlledSecrets();
      }
    },
    skip: kIsWeb ? false : 'Web-only smoke test',
  );
}
