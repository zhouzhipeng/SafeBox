import 'package:flutter_test/flutter_test.dart';
import 'package:safebox/platform/app_settings_store.dart';
import 'package:safebox/platform/public_identity_store.dart';
import 'package:safebox/platform/source_configuration_store.dart';
import 'package:safebox/sbox/engine/crypto_task_runner.dart';
import 'package:safebox/sbox/identity/public_identity_record.dart';
import 'package:safebox/sbox/source/source_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _vectorMnemonic =
    'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'all ordinary persisted state contains public/config data only',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final identityStore = PublicIdentityStore(preferences: preferences);
      final sourceStore = SourceConfigurationStore(preferences: preferences);
      final settingsStore = AppSettingsStore(preferences: preferences);

      final publicResult = await CryptoTaskRunner.derivePublicIdentity(
        _vectorMnemonic,
      );
      await identityStore.save(
        PublicIdentityRecord.fromJson(publicResult.publicIdentityJson),
      );
      await sourceStore.saveAll(<SourceConfiguration>[
        SourceConfiguration(
          sourceId: SourceId('00112233445566778899aabbccddeeff'),
          displayName: 'offline encrypted root',
          provider: SourceProvider.local,
          mode: SourceMode.readWrite,
          localSyncPath: r'D:\SafeBox\ciphertext',
          localDirectoryMode: ConfiguredLocalMode.canonicalCatalog,
        ),
      ]);
      await settingsStore.saveClearPlaintextOnExit(true);

      final serialized = preferences
          .getKeys()
          .map((key) => '$key=${preferences.get(key)}')
          .join('\n')
          .toLowerCase();
      expect(serialized, isNot(contains(_vectorMnemonic)));
      expect(serialized, isNot(contains('private_key')));
      expect(serialized, isNot(contains('private-key')));
      expect(serialized, isNot(contains('mnemonic')));
      expect(serialized, isNot(contains('bip39_seed')));
      expect(serialized, isNot(contains('pkcs8')));
      expect(serialized, contains('recipient_key_id'));
      expect(serialized, contains('clear_plaintext_on_exit'));
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
