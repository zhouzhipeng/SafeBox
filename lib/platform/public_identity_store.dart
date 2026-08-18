import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../sbox/identity/public_identity_record.dart';

final class StoredPublicIdentity {
  const StoredPublicIdentity({required this.record, required this.createdAt});

  final PublicIdentityRecord record;
  final DateTime createdAt;
}

final class PublicIdentityStore {
  PublicIdentityStore({SharedPreferences? preferences})
    : _providedPreferences = preferences;

  static const String _storageKey = 'sbox.v2.public_identity';
  static const String _historyKey = 'sbox.v2.public_identity_history';
  final SharedPreferences? _providedPreferences;

  Future<PublicIdentityRecord?> load() async {
    final preferences =
        _providedPreferences ?? await SharedPreferences.getInstance();
    final value = preferences.getString(_storageKey);
    if (value == null) return null;
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Invalid public identity');
    }
    return PublicIdentityRecord.fromJson(decoded);
  }

  Future<void> save(PublicIdentityRecord record) async {
    final preferences =
        _providedPreferences ?? await SharedPreferences.getInstance();
    if (!await preferences.setString(
      _storageKey,
      jsonEncode(record.toJson()),
    )) {
      throw StateError('Public identity was not persisted');
    }
    final history = await loadAll();
    final keyId = record.toJson()['recipient_key_id'];
    final updated = <StoredPublicIdentity>[
      StoredPublicIdentity(record: record, createdAt: DateTime.now().toUtc()),
      ...history.where(
        (item) => item.record.toJson()['recipient_key_id'] != keyId,
      ),
    ].take(20).toList(growable: false);
    if (!await preferences.setString(
      _historyKey,
      jsonEncode(
        updated
            .map(
              (item) => <String, Object?>{
                'created_at': item.createdAt.toIso8601String(),
                'public_identity': item.record.toJson(),
              },
            )
            .toList(growable: false),
      ),
    )) {
      throw StateError('Public identity history was not persisted');
    }
  }

  Future<List<StoredPublicIdentity>> loadAll() async {
    final preferences =
        _providedPreferences ?? await SharedPreferences.getInstance();
    final encoded = preferences.getString(_historyKey);
    if (encoded == null) {
      final current = await load();
      return current == null
          ? const <StoredPublicIdentity>[]
          : <StoredPublicIdentity>[
              StoredPublicIdentity(
                record: current,
                createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
              ),
            ];
    }
    final decoded = jsonDecode(encoded);
    if (decoded is! List<Object?> || decoded.length > 20) {
      throw const FormatException('Invalid public identity history');
    }
    final result = <StoredPublicIdentity>[];
    final ids = <String>{};
    for (final value in decoded) {
      if (value is! Map<String, Object?> ||
          value.length != 2 ||
          value['created_at'] is! String ||
          value['public_identity'] is! Map<String, Object?>) {
        throw const FormatException('Invalid public identity history');
      }
      final record = PublicIdentityRecord.fromJson(
        value['public_identity']! as Map<String, Object?>,
      );
      final id = record.toJson()['recipient_key_id']! as String;
      if (!ids.add(id)) {
        throw const FormatException('Duplicate public identity history');
      }
      result.add(
        StoredPublicIdentity(
          record: record,
          createdAt: DateTime.parse(value['created_at']! as String).toUtc(),
        ),
      );
    }
    return List<StoredPublicIdentity>.unmodifiable(result);
  }

  Future<void> clear() async {
    final preferences =
        _providedPreferences ?? await SharedPreferences.getInstance();
    await preferences.remove(_storageKey);
    await preferences.remove(_historyKey);
  }
}
