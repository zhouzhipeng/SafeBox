import 'dart:io';

import 'package:safebox/app/app_controller.dart';
import 'package:safebox/app/app_logger.dart';
import 'package:safebox/platform/app_settings_store.dart';
import 'package:safebox/platform/cloud_backup_configuration_store.dart';
import 'package:safebox/platform/public_identity_store.dart';
import 'package:safebox/platform/source_configuration_store.dart';
import 'package:safebox/sbox/source/cloud_backup_config.dart';
import 'package:safebox/sbox/source/credential.dart';
import 'package:safebox/sbox/storage/temporary_plaintext_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:test/test.dart';

void main() {
  test('initialize restores and updates the preview-details setting', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'sbox.v3.show_preview_and_details': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final controller = AppController(
      identityStore: PublicIdentityStore(preferences: preferences),
      appSettingsStore: AppSettingsStore(preferences: preferences),
      logger: AppLogger(preferences: preferences),
    );
    try {
      await controller.initialize();

      expect(controller.showPreviewAndDetails, isTrue);

      await controller.saveShowPreviewAndDetails(false);

      expect(controller.showPreviewAndDetails, isFalse);
      expect(preferences.getBool('sbox.v3.show_preview_and_details'), isFalse);
    } finally {
      controller.dispose();
    }
  });

  test(
    'removeIdentity clears local identity data and plaintext cache',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'sbox.v2.public_identity': 'legacy-public-key',
        'sbox.v2.cloud_backup_configuration': 'legacy-repository-address',
        'sbox.v2.source_configurations': 'legacy-source-config',
        'sbox.v2.clear_plaintext_on_exit': true,
        'sbox.v3.show_preview_and_details': true,
      });
      final preferences = await SharedPreferences.getInstance();
      final cloudStore = CloudBackupConfigurationStore(
        preferences: preferences,
      );
      await cloudStore.save(
        CloudBackupConfiguration(
          backupDirectory: r'C:\SafeBox\encrypted-backup',
          github: CloudRepositoryEndpoint(
            owner: 'owner',
            repository: 'github-box',
            credentialId: SourceCredentialId('custom-github-token'),
          ),
          gitee: CloudRepositoryEndpoint(
            owner: 'owner',
            repository: 'gitee-box',
            credentialId: SourceCredentialId('custom-gitee-token'),
          ),
        ),
      );
      await preferences.setString('sbox.v3.source_configurations', '[]');
      await AppSettingsStore(preferences: preferences)
          .saveClearPlaintextOnExit(true);

      final root = await Directory.systemTemp.createTemp(
        'safebox-remove-identity-',
      );
      final temporaryStore = TemporaryPlaintextStore(root: root);
      try {
        final managedRoot = await temporaryStore.ensureRoot();
        await File('${managedRoot.path}${Platform.pathSeparator}cached.txt')
            .writeAsString('temporary plaintext');

        final credentials = _RecordingCredentialStore();
        final controller = AppController(
          identityStore: PublicIdentityStore(preferences: preferences),
          cloudBackupConfigurationStore: cloudStore,
          sourceConfigurationStore: SourceConfigurationStore(
            preferences: preferences,
          ),
          credentialStore: credentials,
          temporaryPlaintextStore: temporaryStore,
          appSettingsStore: AppSettingsStore(preferences: preferences),
          logger: AppLogger(preferences: preferences),
        );
        await controller.initialize();
        await preferences.setString(
          'sbox.v3.public_identity',
          'saved-public-key',
        );

        await controller.removeIdentity();

        expect(controller.hasIdentity, isFalse);
        expect(
          credentials.deletedIds.map((id) => id.value),
          containsAll(<String>[
            'safebox-github-token',
            'safebox-gitee-token',
            'custom-github-token',
            'custom-gitee-token',
          ]),
        );
        for (final key in <String>[
          'sbox.v2.public_identity',
          'sbox.v3.public_identity',
          'sbox.v2.cloud_backup_configuration',
          'sbox.v3.cloud_backup_configuration',
          'sbox.v4.cloud_backup_configuration',
          'sbox.v2.source_configurations',
          'sbox.v3.source_configurations',
        ]) {
          expect(preferences.getString(key), isNull, reason: key);
        }
        expect(preferences.getBool('sbox.v3.clear_plaintext_on_exit'), isNull);
        expect(preferences.getBool('sbox.v3.show_preview_and_details'), isNull);
        expect(await root.exists(), isFalse);
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
  );
}

final class _RecordingCredentialStore implements CredentialStore {
  final deletedIds = <SourceCredentialId>[];

  @override
  Future<void> putAccessToken(
    SourceCredentialId id,
    SourceAccessToken token,
  ) async {}

  @override
  Future<SourceAccessToken?> getAccessToken(SourceCredentialId id) async =>
      null;

  @override
  Future<void> deleteAccessToken(SourceCredentialId id) async {
    deletedIds.add(id);
  }
}
