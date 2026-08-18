import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../sbox/source/cloud_backup_config.dart';

final class CloudBackupConfigurationStore {
  CloudBackupConfigurationStore({SharedPreferences? preferences})
    : _providedPreferences = preferences;

  static const String _storageKey = 'sbox.v4.cloud_backup_configuration';
  static const List<String> _obsoleteStorageKeys = <String>[
    'sbox.v2.cloud_backup_configuration',
    'sbox.v3.cloud_backup_configuration',
  ];
  final SharedPreferences? _providedPreferences;

  Future<CloudBackupConfiguration?> load() async {
    final preferences =
        _providedPreferences ?? await SharedPreferences.getInstance();
    for (final key in _obsoleteStorageKeys) {
      await preferences.remove(key);
    }
    final encoded = preferences.getString(_storageKey);
    if (encoded == null) return null;
    final decoded = jsonDecode(encoded);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Invalid cloud backup configuration');
    }
    return CloudBackupConfiguration.fromJson(decoded);
  }

  Future<void> save(CloudBackupConfiguration configuration) async {
    final preferences =
        _providedPreferences ?? await SharedPreferences.getInstance();
    final saved = await preferences.setString(
      _storageKey,
      configuration.encode(),
    );
    if (!saved) throw StateError('Cloud backup configuration was not saved');
    for (final key in _obsoleteStorageKeys) {
      await preferences.remove(key);
    }
  }

  Future<void> clear() async {
    final preferences =
        _providedPreferences ?? await SharedPreferences.getInstance();
    await preferences.remove(_storageKey);
    for (final key in _obsoleteStorageKeys) {
      await preferences.remove(key);
    }
  }
}
