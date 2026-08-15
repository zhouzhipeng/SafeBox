import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('protocol core has no FFI or platform-channel escape hatch', () async {
    final core = Directory('lib/sbox');
    final forbidden = RegExp(
      r"dart:ffi|DynamicLibrary|MethodChannel|EventChannel|BasicMessageChannel",
    );
    await for (final entity in core.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      expect(
        await entity.readAsString(),
        isNot(matches(forbidden)),
        reason: '${entity.path} must remain pure Dart protocol code',
      );
    }
  });

  test(
    'platform persistence exposes no generic private-secret writer',
    () async {
      final platform = Directory('lib/platform');
      final forbiddenApi = RegExp(
        r'putSecret|saveMnemonic|savePrivateKey|persistSeed|pkcs8',
        caseSensitive: false,
      );
      await for (final entity in platform.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        expect(
          await entity.readAsString(),
          isNot(matches(forbiddenApi)),
          reason: '${entity.path} must not accept SBOX private material',
        );
      }
      final credential = await File('lib/platform/secure_credential_store.dart')
          .readAsString();
      expect(credential, contains('SourceAccessToken'));
      expect(credential, isNot(contains('SecretBytes')));
      expect(credential, isNot(contains('EphemeralMnemonic')));
    },
  );
}
