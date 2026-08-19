import 'package:shared_preferences/shared_preferences.dart';

import '../sbox/constants.dart';

/// Public, non-secret UI preferences only.
final class AppSettingsStore {
  AppSettingsStore({SharedPreferences? preferences})
    : _providedPreferences = preferences;

  static const _clearOnExitKey = 'sbox.v3.clear_plaintext_on_exit';
  static const _legacyClearOnExitKey = 'sbox.v2.clear_plaintext_on_exit';
  static const _targetNominalShardPlaintextSizeKey =
      'sbox.v3.target_nominal_shard_plaintext_size';
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

  Future<int> loadTargetNominalShardPlaintextSize() async {
    final preferences =
        _providedPreferences ?? await SharedPreferences.getInstance();
    final value = preferences.getInt(_targetNominalShardPlaintextSizeKey);
    return _isValidTargetNominalShardPlaintextSize(value)
        ? value!
        : SboxProtocol.defaultNominalShardPlaintextSize;
  }

  Future<void> saveTargetNominalShardPlaintextSize(int value) async {
    if (!_isValidTargetNominalShardPlaintextSize(value)) {
      throw ArgumentError.value(value, 'value');
    }
    final preferences =
        _providedPreferences ?? await SharedPreferences.getInstance();
    if (!await preferences.setInt(_targetNominalShardPlaintextSizeKey, value)) {
      throw StateError('Application setting was not persisted');
    }
  }

  Future<void> clear() async {
    final preferences =
        _providedPreferences ?? await SharedPreferences.getInstance();
    await preferences.remove(_clearOnExitKey);
    await preferences.remove(_legacyClearOnExitKey);
    await preferences.remove(_targetNominalShardPlaintextSizeKey);
  }

  static bool _isValidTargetNominalShardPlaintextSize(int? value) {
    const unit = 1024 * 1024;
    return value != null &&
        value >= SboxProtocol.minNominalShardPlaintextSize &&
        value <= SboxProtocol.maxNominalShardPlaintextSize &&
        value % unit == 0;
  }
}
