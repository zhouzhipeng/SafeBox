import 'package:shared_preferences/shared_preferences.dart';

/// Public, non-secret UI preferences only.
final class AppSettingsStore {
  AppSettingsStore({SharedPreferences? preferences})
    : _providedPreferences = preferences;

  static const _clearOnExitKey = 'sbox.v3.clear_plaintext_on_exit';
  static const _legacyClearOnExitKey = 'sbox.v2.clear_plaintext_on_exit';
  final SharedPreferences? _providedPreferences;

  Future<bool> loadClearPlaintextOnExit() async {
    final preferences =
        _providedPreferences ?? await SharedPreferences.getInstance();
    return preferences.getBool(_clearOnExitKey) ?? false;
  }

  Future<void> saveClearPlaintextOnExit(bool value) async {
    final preferences =
        _providedPreferences ?? await SharedPreferences.getInstance();
    if (!await preferences.setBool(_clearOnExitKey, value)) {
      throw StateError('Application setting was not persisted');
    }
  }

  Future<void> clear() async {
    final preferences =
        _providedPreferences ?? await SharedPreferences.getInstance();
    await preferences.remove(_clearOnExitKey);
    await preferences.remove(_legacyClearOnExitKey);
  }
}
