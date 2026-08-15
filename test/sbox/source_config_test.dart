import 'dart:convert';

import 'package:safebox/sbox/source/credential.dart';
import 'package:safebox/sbox/source/data_source.dart';
import 'package:safebox/sbox/source/source_config.dart';
import 'package:test/test.dart';

void main() {
  test(
    'local-only configuration contains no cloud or credential requirement',
    () {
      final config = SourceConfiguration(
        sourceId: SourceId('00112233445566778899aabbccddeeff'),
        displayName: '离线资料库',
        provider: SourceProvider.local,
        mode: SourceMode.readOnly,
        localSyncPath: r'D:\vault',
        localDirectoryMode: ConfiguredLocalMode.looseReadOnly,
      );
      final encoded = config.toJson();
      expect(encoded.containsKey('owner'), isFalse);
      expect(encoded.containsKey('credential_reference'), isFalse);
      expect(encoded['sync_policy'], 'manual');
      expect(
        SourceConfiguration.fromJson(encoded).provider,
        SourceProvider.local,
      );
    },
  );

  test('repository configuration round-trips only an opaque credential ID', () {
    final config = SourceConfiguration(
      sourceId: SourceId('00112233445566778899aabbccddeeff'),
      displayName: 'GitHub public vault',
      provider: SourceProvider.github,
      mode: SourceMode.readWrite,
      localSyncPath: r'D:\mirrors\00112233445566778899aabbccddeeff',
      owner: 'alice',
      repository: 'vault',
      branchOrRef: 'main',
      pathPrefix: 'sbox',
      credentialReference: SourceCredentialId('github-main'),
      expectedRecipientKeyId: List<String>.filled(32, '11').join(),
      expectedCatalogSignerKeyId: List<String>.filled(32, '22').join(),
      catalogId: List<String>.filled(16, '33').join(),
      highestGeneration: 7,
      lastCatalogSha256: List<String>.filled(32, '44').join(),
      lastProviderRevision: RevisionToken(const <int>[0, 1, 2, 3]),
      syncPolicy: SourceSyncPolicy.wifiOnly,
      lastLocalSyncAt: DateTime.utc(2026, 8, 15),
    );
    final jsonText = jsonEncode(config.toJson());
    expect(jsonText, isNot(contains('actual-access-token')));
    final parsed = SourceConfiguration.fromJson(
      jsonDecode(jsonText) as Map<String, Object?>,
    );
    expect(parsed.repositoryConfig.owner, 'alice');
    expect(parsed.repositoryConfig.pathPrefix, 'sbox');
    expect(parsed.lastProviderRevision?.bytes, const <int>[0, 1, 2, 3]);
    expect(parsed.checkpoint?.highestGeneration, 7);
  });

  test(
    'mobile directory authorization is opaque, persistent and read-only',
    () {
      final config = SourceConfiguration(
        sourceId: SourceId('00112233445566778899aabbccddeeff'),
        displayName: '系统文件保险箱',
        provider: SourceProvider.local,
        mode: SourceMode.readOnly,
        localSyncPath: '/private/app/authorized/00112233',
        localDirectoryMode: ConfiguredLocalMode.canonicalCatalog,
        directoryAuthorizationReference: 'content-tree-or-bookmark',
        directoryAuthorizationPlatform: 'android',
        directoryAuthorizationDisplayName: 'Documents/SafeBox',
      );
      final parsed = SourceConfiguration.fromJson(config.toJson());
      expect(parsed.isAuthorizedDirectory, isTrue);
      expect(
        parsed.directoryAuthorizationReference,
        'content-tree-or-bookmark',
      );
      expect(parsed.mode, SourceMode.readOnly);
      expect(
        () => config.copyWith(mode: SourceMode.readWrite),
        throwsArgumentError,
      );
    },
  );

  test('pending encrypted Catalog queue round-trips and can be cleared', () {
    final config = SourceConfiguration(
      sourceId: SourceId('00112233445566778899aabbccddeeff'),
      displayName: 'GitHub pending vault',
      provider: SourceProvider.github,
      mode: SourceMode.readWrite,
      localSyncPath: r'D:\mirrors\00112233445566778899aabbccddeeff',
      owner: 'alice',
      repository: 'vault',
      branchOrRef: 'main',
      credentialReference: SourceCredentialId('github-main'),
      catalogId: '11111111111111111111111111111111',
      highestGeneration: 2,
      lastCatalogSha256: List<String>.filled(32, '22').join(),
      pendingCatalogId: '11111111111111111111111111111111',
      pendingCatalogGeneration: 4,
      pendingCatalogSha256: List<String>.filled(32, '33').join(),
      pendingBaseCatalogSha256: List<String>.filled(32, '22').join(),
    );
    final parsed = SourceConfiguration.fromJson(config.toJson());
    expect(parsed.hasPendingCatalog, isTrue);
    expect(parsed.pendingCatalogGeneration, 4);
    expect(
      parsed.pendingBaseCatalogSha256,
      List<String>.filled(32, '22').join(),
    );

    final cleared = parsed.copyWith(clearPendingCatalog: true);
    expect(cleared.hasPendingCatalog, isFalse);
    expect(cleared.catalogId, parsed.catalogId);
    expect(cleared.lastCatalogSha256, parsed.lastCatalogSha256);
  });

  test('HTTPS configurations reject writable mode and insecure URLs', () {
    expect(
      () => SourceConfiguration(
        sourceId: SourceId.random(),
        displayName: 'bad',
        provider: SourceProvider.https,
        mode: SourceMode.readWrite,
        localSyncPath: '/mirror/source',
        httpsBaseUri: Uri.parse('http://example.test/sbox'),
      ),
      throwsArgumentError,
    );
  });

  test('unknown persisted fields fail closed', () {
    final json = <String, Object?>{
      'source_id': '00112233445566778899aabbccddeeff',
      'display_name': 'Local',
      'provider': 'local',
      'mode': 'readOnly',
      'local_sync_path': '/vault',
      'local_sync_mode': 'full_ciphertext',
      'sync_policy': 'manual',
      'local_directory_mode': 'looseReadOnly',
      'private_key': 'must never be accepted',
    };
    expect(() => SourceConfiguration.fromJson(json), throwsFormatException);
  });
}
