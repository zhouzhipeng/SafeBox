import 'dart:io';
import 'dart:typed_data';

import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/engine/container_codec.dart';
import 'package:safebox/sbox/errors.dart';
import 'package:safebox/sbox/identity/bip39_identity.dart';
import 'package:safebox/sbox/identity/rsa_models.dart';
import 'package:safebox/sbox/source/local_directory_source.dart';
import 'package:safebox/sbox/source/local_scanner.dart';
import 'package:safebox/sbox/source/source_path.dart';
import 'package:test/test.dart';

void main() {
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon about';
  late EphemeralIdentity identity;
  late Directory testRoot;
  late Uint8List sboxBytes;

  setUpAll(() async {
    identity = await SboxIdentityDeriver().deriveIdentity(mnemonic);
    testRoot = await Directory.systemTemp.createTemp('safebox-local-source-');
    sboxBytes = await SboxContainerCodec().encryptBytes(
      recipient: identity.publicIdentity,
      contentKind: SboxContentKind.text,
      originalName: 'local.txt',
      mediaType: 'text/plain',
      data: utf8Bytes('local source'),
    );
  });

  tearDownAll(() async {
    identity.disposeControlledSecrets();
    await testRoot.delete(recursive: true);
  });

  Future<Uint8List> collect(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: true);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  test(
    'canonical local source provides immutable put and CAS Catalog',
    () async {
      final root = Directory('${testRoot.path}/canonical');
      final source = await LocalDirectoryDataSource.attach(
        root: root,
        mode: LocalDirectoryMode.canonicalCatalog,
        requestWrite: true,
      );
      expect(source.readOnly, isFalse);
      final objectPath = SourcePath(
        'objects/${hexLower(sboxBytes.sublist(28, 29))}/object.sbox',
      );
      final objectHash = sha256Bytes(sboxBytes);
      final revision = await source.putNew(
        objectPath,
        Stream<List<int>>.value(sboxBytes),
        length: sboxBytes.length,
        sha256: objectHash,
      );
      final read = await source.get(objectPath);
      expect(await collect(read.body), sboxBytes);
      final unchanged = await source.get(objectPath, ifNoneMatch: revision);
      expect(unchanged.notModified, isTrue);
      await expectLater(
        source.putNew(
          objectPath,
          Stream<List<int>>.value(<int>[...sboxBytes, 0]),
          length: sboxBytes.length + 1,
          sha256: sha256Bytes(<int>[...sboxBytes, 0]),
        ),
        throwsA(anything),
      );

      final catalogPath = SourcePath('catalog.sbox');
      final catalogV1 = sboxBytes;
      final catalogRevision = await source.putNew(
        catalogPath,
        Stream<List<int>>.value(catalogV1),
        length: catalogV1.length,
        sha256: sha256Bytes(catalogV1),
      );
      final catalogV2 = Uint8List.fromList(<int>[...sboxBytes]..[500] ^= 1);
      final nextRevision = await source.compareAndSwap(
        catalogPath,
        catalogRevision,
        Stream<List<int>>.value(catalogV2),
        length: catalogV2.length,
      );
      expect(nextRevision.bytes, sha256Bytes(catalogV2));
      await expectLater(
        source.compareAndSwap(
          catalogPath,
          catalogRevision,
          Stream<List<int>>.value(catalogV1),
          length: catalogV1.length,
        ),
        throwsA(anything),
      );
    },
  );

  test('probe does not downgrade an invalid catalog to loose mode', () async {
    final looseRoot = Directory('${testRoot.path}/loose')..createSync();
    final loose = await LocalDirectoryProbe.inspect(looseRoot);
    expect(loose.mode, LocalDirectoryProbeMode.looseReadOnly);

    final invalidRoot = Directory('${testRoot.path}/invalid')..createSync();
    await File('${invalidRoot.path}/catalog.sbox')
        .writeAsBytes(<int>[...List<int>.filled(468, 0)]);
    await expectLater(
      LocalDirectoryProbe.inspect(invalidRoot),
      throwsA(anything),
    );
  });

  test(
    'loose scanner folds identical copies and flags same-ID conflicts',
    () async {
      final root = Directory('${testRoot.path}/scan')..createSync();
      final first = File('${root.path}/first.sbox');
      final nested = Directory('${root.path}/nested')..createSync();
      final duplicate = File('${nested.path}/duplicate.SBOX');
      final conflict = File('${nested.path}/conflict.sbox');
      await first.writeAsBytes(sboxBytes);
      await duplicate.writeAsBytes(sboxBytes);
      final changed = Uint8List.fromList(sboxBytes)..[500] ^= 1;
      await conflict.writeAsBytes(changed);

      final result = await LocalSboxScanner.scan(root);
      expect(result.candidates, hasLength(1));
      expect(result.candidates.single.duplicateCopies, hasLength(2));
      expect(result.candidates.single.hasFileIdConflict, isTrue);
    },
  );

  test('loose scanner enforces candidate and depth limits', () async {
    final limitRoot = Directory('${testRoot.path}/scan-limits')..createSync();
    await File('${limitRoot.path}/one.sbox').writeAsBytes(sboxBytes);
    await File('${limitRoot.path}/two.sbox').writeAsBytes(sboxBytes);
    await expectLater(
      LocalSboxScanner.scan(limitRoot, maximumCandidates: 1),
      throwsA(
        isA<SboxException>()
            .having((error) => error.code, 'code', SboxErrorCode.limits)
            .having((error) => error.message, 'message', contains('超过 1 个')),
      ),
    );

    final depthRoot = Directory('${testRoot.path}/scan-depth')..createSync();
    final levelOne = Directory('${depthRoot.path}/one')..createSync();
    final levelTwo = Directory('${levelOne.path}/two')..createSync();
    await File('${levelTwo.path}/deep.sbox').writeAsBytes(sboxBytes);
    final shallow = await LocalSboxScanner.scan(depthRoot, maximumDepth: 1);
    expect(shallow.candidates, isEmpty);
    final deep = await LocalSboxScanner.scan(depthRoot, maximumDepth: 2);
    expect(deep.candidates, hasLength(1));
  });

  test('loose scanner does not follow a link outside its root', () async {
    final root = Directory('${testRoot.path}/scan-no-follow')..createSync();
    final outside = Directory('${testRoot.path}/outside-scan')..createSync();
    await File('${outside.path}/outside.sbox').writeAsBytes(sboxBytes);
    final linkedPath = '${root.path}/linked-outside';
    if (Platform.isWindows) {
      final created = await Process.run('powershell.exe', <String>[
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'& { param([string]$link, [string]$target) '
            r'New-Item -ItemType Junction -LiteralPath $link -Target $target '
            r'| Out-Null }',
        linkedPath,
        outside.absolute.path,
      ]);
      expect(created.exitCode, 0, reason: created.stderr.toString());
    } else {
      await Link(linkedPath).create(outside.path);
    }

    final result = await LocalSboxScanner.scan(root);
    expect(result.candidates, isEmpty);
    expect(await File('${outside.path}/outside.sbox').exists(), isTrue);
  });
}
