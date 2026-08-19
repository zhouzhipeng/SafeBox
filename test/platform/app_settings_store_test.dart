import 'package:safebox/platform/app_settings_store.dart';
import 'package:safebox/sbox/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:test/test.dart';

void main() {
  test('shard size defaults to 16 MiB and persists', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final store = AppSettingsStore(preferences: preferences);

    expect(
      await store.loadTargetNominalShardPlaintextSize(),
      SboxProtocol.defaultNominalShardPlaintextSize,
    );

    await store.saveTargetNominalShardPlaintextSize(32 * 1024 * 1024);

    expect(await store.loadTargetNominalShardPlaintextSize(), 32 * 1024 * 1024);
  });

  test('invalid stored shard size falls back to the default', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'sbox.v3.target_nominal_shard_plaintext_size': 3 * 1024 * 1024 + 1,
    });
    final preferences = await SharedPreferences.getInstance();
    final store = AppSettingsStore(preferences: preferences);

    expect(
      await store.loadTargetNominalShardPlaintextSize(),
      SboxProtocol.defaultNominalShardPlaintextSize,
    );
    await expectLater(
      store.saveTargetNominalShardPlaintextSize(513 * 1024 * 1024),
      throwsArgumentError,
    );
  });

  test('light theme defaults to dark and persists', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final store = AppSettingsStore(preferences: preferences);

    expect(await store.loadLightTheme(), isFalse);

    await store.saveLightTheme(true);

    expect(await store.loadLightTheme(), isTrue);
  });

  test('preview details default to hidden and persist', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final store = AppSettingsStore(preferences: preferences);

    expect(await store.loadShowPreviewAndDetails(), isFalse);

    await store.saveShowPreviewAndDetails(true);

    expect(await store.loadShowPreviewAndDetails(), isTrue);
  });

  test('clear removes the stored shard size', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'sbox.v3.target_nominal_shard_plaintext_size': 8 * 1024 * 1024,
      'sbox.v3.light_theme': true,
      'sbox.v3.show_preview_and_details': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final store = AppSettingsStore(preferences: preferences);

    await store.clear();

    expect(
      await store.loadTargetNominalShardPlaintextSize(),
      SboxProtocol.defaultNominalShardPlaintextSize,
    );
    expect(await store.loadLightTheme(), isFalse);
    expect(await store.loadShowPreviewAndDetails(), isFalse);
  });
}
