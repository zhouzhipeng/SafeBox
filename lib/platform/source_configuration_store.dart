import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../sbox/source/source_config.dart';

final class SourceConfigurationStore {
  SourceConfigurationStore({SharedPreferences? preferences})
    : _providedPreferences = preferences;

  static const String _storageKey = 'sbox.v2.source_configurations';
  final SharedPreferences? _providedPreferences;

  Future<List<SourceConfiguration>> loadAll() async {
    final preferences =
        _providedPreferences ?? await SharedPreferences.getInstance();
    final encoded = preferences.getString(_storageKey);
    if (encoded == null) {
      return const <SourceConfiguration>[];
    }
    final decoded = jsonDecode(encoded);
    if (decoded is! List<Object?> || decoded.length > 100) {
      throw const FormatException('Invalid source configuration list');
    }
    final ids = <SourceId>{};
    final result = <SourceConfiguration>[];
    for (final item in decoded) {
      if (item is! Map<String, Object?>) {
        throw const FormatException('Invalid source configuration');
      }
      final config = SourceConfiguration.fromJson(item);
      if (!ids.add(config.sourceId)) {
        throw const FormatException('Duplicate source configuration');
      }
      result.add(config);
    }
    result.sort(
      (left, right) => left.sourceId.value.compareTo(right.sourceId.value),
    );
    return List<SourceConfiguration>.unmodifiable(result);
  }

  Future<void> saveAll(Iterable<SourceConfiguration> configurations) async {
    final list = configurations.toList(growable: false);
    if (list.length > 100 ||
        list.map((value) => value.sourceId).toSet().length != list.length) {
      throw ArgumentError('Invalid source configuration set');
    }
    final preferences =
        _providedPreferences ?? await SharedPreferences.getInstance();
    final encoded = jsonEncode(
      list.map((value) => value.toJson()).toList(growable: false),
    );
    final saved = await preferences.setString(_storageKey, encoded);
    if (!saved) {
      throw StateError('Source configurations were not persisted');
    }
  }

  Future<void> remove(SourceId id) async {
    final current = await loadAll();
    await saveAll(current.where((value) => value.sourceId != id));
  }
}
