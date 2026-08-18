import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/engine/bundle_encryptor.dart';
import 'package:safebox/sbox/engine/bundle_decryptor.dart';
import 'package:safebox/sbox/engine/bundle_probe.dart';
import 'package:safebox/sbox/format/bundle_record.dart';
import 'package:safebox/sbox/errors.dart';
import 'package:safebox/sbox/identity/bip39_identity.dart';
import 'package:safebox/sbox/identity/rsa_models.dart';
import 'package:test/test.dart';

void main() {
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon about';
  late PublicIdentity recipient;
  late EphemeralIdentity identity;

  setUpAll(() async {
    identity = await SboxIdentityDeriver().deriveIdentity(mnemonic);
    recipient = identity.publicIdentity;
  });

  tearDownAll(() {
    identity.disposeControlledSecrets();
  });

  test('empty Bundle has one root object and round-trips', () async {
    final encrypted = await _encrypt(
      const <int>[],
      recipient: recipient,
      randomness: _randomness(1, 0),
    );
    expect(encrypted.objects, hasLength(1));
    expect(encrypted.root.header.isRoot, isTrue);
    expect(encrypted.root.header.shardPlaintextSize, BigInt.zero);
    expect(encrypted.root.basename, endsWith('.sbox'));
    expect(encrypted.root.header.wrappedBundleDek, hasLength(384));

    final decrypted = await BundleDecryptor().decryptBytes(
      shardBytes: encrypted.objects.map((object) => object.bytes).toList(),
      mnemonic: mnemonic,
    );
    expect(decrypted.plaintext, isEmpty);
    expect(decrypted.manifest.contentKind, SboxContentKind.file);
  });

  test('production Bundle ID is the MD5 of the original bytes', () async {
    final plaintext = <int>[1, 2, 3, 4, 5];
    final encrypted = await BundleEncryptor().encryptBytes(
      plaintext: plaintext,
      options: BundleEncryptionOptions(
        recipient: recipient,
        contentKind: SboxContentKind.file,
        originalName: 'sample.bin',
        mediaType: 'application/octet-stream',
        createdAt: '2026-08-17T00:00:00Z',
      ),
    );
    expect(
      encrypted.manifest.bundleId,
      crypto.md5.convert(plaintext).toString(),
    );
  });

  test(
    'root prefix authentication exposes only authenticated Manifest state',
    () async {
      final encrypted = await _encrypt(
        const <int>[1, 2, 3],
        recipient: recipient,
        randomness: _randomness(1, 5),
      );
      final root = encrypted.root;
      final manifestRecord = BundleRecordCodec().parseAt(
        root.bytes,
        root.header.headerLength,
        maximumPlaintextLength: SboxProtocol.maxManifestBytes,
      );
      final prefix = root.bytes.sublist(0, manifestRecord.nextOffset);
      final probe = await BundleProbe.authenticateManifest(
        basename: root.basename,
        objectPrefix: prefix,
        mnemonic: mnemonic,
      );
      expect(probe.manifestAuthenticated, isTrue);
      expect(probe.manifest?.originalName, 'sample.bin');
    },
  );

  test(
    'verified decryption publishes through a same-directory temporary file',
    () async {
      final encrypted = await _encrypt(
        const <int>[9, 8, 7],
        recipient: recipient,
        randomness: _randomness(1, 6),
      );
      final temporary = await Directory.systemTemp.createTemp('sbox-v2-plain-');
      final destination = File(
        '${temporary.path}${Platform.pathSeparator}out.bin',
      );
      try {
        final objects = <String, List<int>>{
          for (final object in encrypted.objects) object.basename: object.bytes,
        };
        await BundleDecryptor().decryptToFile(
          objects: objects,
          mnemonic: mnemonic,
          destination: destination,
        );
        expect(await destination.readAsBytes(), [9, 8, 7]);
        await expectLater(
          BundleDecryptor().decryptToFile(
            objects: objects,
            mnemonic: mnemonic,
            destination: destination,
          ),
          throwsA(isA<SboxException>()),
        );
      } finally {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      }
    },
  );

  test(
    'multipart Bundle encrypts continuation shards without RSA wrapping',
    () async {
      final plaintext = Uint8List(1024 * 1024 + 1);
      plaintext[0] = 0x41;
      plaintext[plaintext.length - 1] = 0x5a;
      final encrypted = await _encrypt(
        plaintext,
        recipient: recipient,
        randomness: _randomness(2, 1),
        targetNominalShardPlaintextSize: 1024 * 1024,
      );
      expect(encrypted.objects.map((object) => object.header.shardIndex), [
        0,
        1,
      ]);
      expect(encrypted.objects[0].header.wrappedBundleDek, hasLength(384));
      expect(encrypted.objects[1].header.wrappedBundleDek, isEmpty);
      expect(encrypted.objects[0].basename, contains('_0_2.sbox'));
      expect(encrypted.objects[1].basename, contains('_1_2.sbox'));

      final shuffled = encrypted.objects.reversed
          .map((object) => object.bytes)
          .toList(growable: false);
      final decrypted = await BundleDecryptor().decryptBytes(
        shardBytes: shuffled,
        mnemonic: mnemonic,
      );
      expect(decrypted.plaintext, plaintext);
    },
  );

  test(
    'directory encryption streams one shard at a time and commits root last',
    () async {
      final plaintext = Uint8List(1024 * 1024 + 1);
      plaintext[0] = 0x31;
      plaintext[plaintext.length - 1] = 0x39;
      final randomness = _randomness(2, 7);
      final directory = await Directory.systemTemp.createTemp(
        'sbox-v2-stream-',
      );
      try {
        final committed = await BundleEncryptor().encryptToDirectory(
          input: MemoryBundleInput(plaintext),
          declaredLength: plaintext.length,
          options: BundleEncryptionOptions(
            recipient: recipient,
            contentKind: SboxContentKind.file,
            originalName: 'stream.bin',
            mediaType: 'application/octet-stream',
            createdAt: '2026-08-17T00:00:00Z',
            targetNominalShardPlaintextSize: 1024 * 1024,
            randomness: randomness,
          ),
          root: directory,
        );
        expect(committed, hasLength(2));
        expect(committed.last, contains('_0_2.sbox'));
        expect(
          await Future.wait(
            committed.map((name) => File('${directory.path}/$name').exists()),
          ),
          everyElement(isTrue),
        );
        expect(
          await directory
              .list()
              .where(
                (entity) => entity is File && entity.path.contains('.part'),
              )
              .toList(),
          isEmpty,
        );
        final objects = <String, List<int>>{
          for (final name in committed)
            name: await File('${directory.path}/$name').readAsBytes(),
        };
        final decrypted = await BundleDecryptor().decrypt(
          objects: objects,
          mnemonic: mnemonic,
        );
        expect(decrypted.plaintext, plaintext);
        decrypted.plaintext.fillRange(0, decrypted.plaintext.length, 0);
      } finally {
        randomness.dispose();
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    },
  );

  test('text input is required to be strict UTF-8 before encryption', () async {
    await expectLater(
      BundleEncryptor().encryptBytes(
        plaintext: const <int>[0xff],
        options: BundleEncryptionOptions(
          recipient: recipient,
          contentKind: SboxContentKind.text,
          originalName: 'bad.txt',
          mediaType: 'text/plain',
          createdAt: '2026-08-17T00:00:00Z',
          randomness: _randomness(1, 2),
        ),
      ),
      throwsA(
        predicate(
          (error) =>
              error is SboxException && error.code == SboxErrorCode.integrity,
        ),
      ),
    );
  });

  test('input changes between passes fail the complete encryption', () async {
    final input = _ChangingInput();
    await expectLater(
      BundleEncryptor().encrypt(
        input: input,
        declaredLength: 3,
        options: BundleEncryptionOptions(
          recipient: recipient,
          contentKind: SboxContentKind.file,
          originalName: 'changed.bin',
          mediaType: 'application/octet-stream',
          createdAt: '2026-08-17T00:00:00Z',
          randomness: _randomness(1, 3),
        ),
      ),
      throwsA(
        predicate(
          (error) =>
              error is SboxException &&
              error.code == SboxErrorCode.inputChanged,
        ),
      ),
    );
  });

  test('missing or tampered shards never produce plaintext', () async {
    final encrypted = await _encrypt(
      Uint8List(1024 * 1024 + 1),
      recipient: recipient,
      randomness: _randomness(2, 4),
      targetNominalShardPlaintextSize: 1024 * 1024,
    );
    await expectLater(
      BundleDecryptor().decryptBytes(
        shardBytes: <List<int>>[encrypted.objects.first.bytes],
        mnemonic: mnemonic,
      ),
      throwsA(
        predicate(
          (error) =>
              error is SboxException &&
              error.code == SboxErrorCode.shardMissing,
        ),
      ),
    );

    final tampered = encrypted.objects
        .map((object) => Uint8List.fromList(object.bytes))
        .toList(growable: false);
    tampered[0][512 + 13] ^= 1;
    await expectLater(
      BundleDecryptor().decryptBytes(shardBytes: tampered, mnemonic: mnemonic),
      throwsA(isA<SboxException>()),
    );
  });
}

Future<EncryptedBundle> _encrypt(
  List<int> plaintext, {
  required PublicIdentity recipient,
  required BundleEncryptionRandomness randomness,
  int targetNominalShardPlaintextSize =
      SboxProtocol.defaultNominalShardPlaintextSize,
}) => BundleEncryptor().encryptBytes(
  plaintext: plaintext,
  options: BundleEncryptionOptions(
    recipient: recipient,
    contentKind: SboxContentKind.file,
    originalName: 'sample.bin',
    mediaType: 'application/octet-stream',
    createdAt: '2026-08-17T00:00:00Z',
    targetNominalShardPlaintextSize: targetNominalShardPlaintextSize,
    randomness: randomness,
  ),
);

BundleEncryptionRandomness _randomness(int shardCount, int offset) =>
    BundleEncryptionRandomness(
      bundleId: List<int>.generate(
        16,
        (index) => (0xa0 + index + offset) & 0xff,
      ),
      bundleDek: List<int>.generate(32, (index) => (index + offset) & 0xff),
      noncePrefixes: <List<int>>[
        for (var index = 0; index < shardCount; index++)
          <int>[index + 1, index + 2, index + 3, index + 4],
      ],
      oaepSeed: List<int>.filled(32, 0x55 + offset),
    );

final class _ChangingInput implements BundleInput {
  var _readCount = 0;

  @override
  Future<int> length() async => 3;

  @override
  Stream<List<int>> openRange(int start, int length) {
    expect(start, 0);
    expect(length, 3);
    final bytes = _readCount++ == 0 ? <int>[1, 2, 3] : <int>[4, 5, 6];
    return Stream<List<int>>.value(bytes);
  }
}
