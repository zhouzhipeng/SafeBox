import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sbox/errors.dart';

enum AppLogLevel { info, warning, error }

final class AppLogEntry {
  const AppLogEntry({
    required this.timestamp,
    required this.level,
    required this.title,
    required this.detail,
  });

  final DateTime timestamp;
  final AppLogLevel level;
  final String title;
  final String detail;

  Map<String, Object?> toJson() => <String, Object?>{
    'timestamp': timestamp.toUtc().toIso8601String(),
    'level': level.name,
    'title': title,
    'detail': detail,
  };

  static AppLogEntry? fromJson(Object? value) {
    if (value is! Map) return null;
    final timestampValue = value['timestamp'];
    final levelValue = value['level'];
    final titleValue = value['title'];
    final detailValue = value['detail'];
    if (timestampValue is! String ||
        levelValue is! String ||
        titleValue is! String ||
        detailValue is! String) {
      return null;
    }
    final timestamp = DateTime.tryParse(timestampValue);
    final level = switch (levelValue) {
      'info' => AppLogLevel.info,
      'warning' => AppLogLevel.warning,
      'error' => AppLogLevel.error,
      _ => null,
    };
    if (timestamp == null || level == null) return null;
    return AppLogEntry(
      timestamp: timestamp.toUtc(),
      level: level,
      title: AppLogger.sanitize(titleValue),
      detail: AppLogger.sanitize(detailValue),
    );
  }
}

/// Bounded, persistent diagnostics for the application UI.
///
/// Logs are intentionally short and sanitized. They are for diagnosing
/// control-flow and connectivity failures, not for exporting SBOX data.
final class AppLogger extends ChangeNotifier {
  AppLogger({SharedPreferences? preferences})
    : _providedPreferences = preferences;

  static const String _storageKey = 'sbox.v2.application_logs';
  static const int maximumEntries = 200;
  static const int maximumFieldLength = 600;

  SharedPreferences? _providedPreferences;
  final List<AppLogEntry> _entries = <AppLogEntry>[];
  Future<void> _writeQueue = Future<void>.value();
  bool _initialized = false;

  List<AppLogEntry> get entries => List.unmodifiable(_entries);

  Future<void> initialize() async {
    if (_initialized) return;
    try {
      final preferences = await _preferences();
      final encoded = preferences.getString(_storageKey);
      if (encoded != null) {
        final decoded = jsonDecode(encoded);
        if (decoded is List) {
          for (final item in decoded.take(maximumEntries)) {
            final entry = AppLogEntry.fromJson(item);
            if (entry != null) _entries.add(entry);
          }
        }
      }
    } on Object {
      // A corrupted diagnostics record must never prevent the app from
      // starting. The next log entry will replace it.
      _entries.clear();
    }
    _initialized = true;
    notifyListeners();
  }

  void info(String title, {String? detail}) =>
      _append(AppLogLevel.info, title, detail);

  void warning(String title, {String? detail}) =>
      _append(AppLogLevel.warning, title, detail);

  void error(Object error, {String operation = '应用操作失败', String? context}) {
    final parts = <String>[describeError(error)];
    if (context != null && context.trim().isNotEmpty) {
      parts.add(sanitize(context));
    }
    _append(AppLogLevel.error, operation, parts.join(' · '));
  }

  Future<void> clear() async {
    _entries.clear();
    notifyListeners();
    _writeQueue = _writeQueue.then<void>((_) async {
      try {
        await (await _preferences()).remove(_storageKey);
      } on Object {
        // Clearing diagnostics is best effort and must not surface a second
        // error while the user is already handling the original one.
      }
    });
    await _writeQueue;
  }

  String exportText() {
    if (_entries.isEmpty) return '暂无应用日志';
    return _entries
        .map(
          (entry) =>
              '${_formatTimestamp(entry.timestamp)} [${entry.level.name.toUpperCase()}] '
              '${entry.title}: ${entry.detail}',
        )
        .join('\n');
  }

  static String describeError(Object error) {
    if (error is SboxException) {
      return '${error.code.value}: ${sanitize(error.message)}';
    }
    final detail = sanitize(error.toString());
    final type = error.runtimeType.toString();
    return detail == type ? type : '$type: $detail';
  }

  /// Removes credentials and strips URLs down to their host before a message
  /// is stored. This also protects logs when a third-party exception includes
  /// a request URL or a query string.
  static String sanitize(String value) {
    var result = value.replaceAll('\r', ' ').replaceAll('\n', ' ').trim();
    result = result.replaceAllMapped(
      RegExp(
        r'authorization\s*[:=]\s*(?:bearer|token)\s+[^\s,;]+',
        caseSensitive: false,
      ),
      (_) => 'Authorization=<已隐藏>',
    );
    result = result.replaceAllMapped(
      RegExp(
        r'(mnemonic|seed|bundle[_-]?dek)\s*[:=]\s*[^,;]+',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}=<已隐藏>',
    );
    result = result.replaceAllMapped(
      RegExp(
        r'(authorization|token|access[_-]?token|password|secret)\s*[:=]\s*[^\s,;]+',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}=<已隐藏>',
    );
    result = result.replaceAllMapped(
      RegExp(r'\bbearer\s+[^\s,;]+', caseSensitive: false),
      (_) => 'Bearer <已隐藏>',
    );
    result = result.replaceAllMapped(
      RegExp(r'https?://[^\s,;]+', caseSensitive: false),
      (match) {
        final uri = Uri.tryParse(match.group(0)!);
        if (uri == null || uri.host.isEmpty) return '<URL 已隐藏>';
        final port = uri.hasPort ? ':${uri.port}' : '';
        return '${uri.scheme}://${uri.host}$port';
      },
    );
    if (result.length > maximumFieldLength) {
      result = '${result.substring(0, maximumFieldLength - 1)}…';
    }
    return result.isEmpty ? '（无附加信息）' : result;
  }

  void _append(AppLogLevel level, String title, String? detail) {
    _entries.insert(
      0,
      AppLogEntry(
        timestamp: DateTime.now().toUtc(),
        level: level,
        title: sanitize(title),
        detail: sanitize(detail ?? '无附加信息'),
      ),
    );
    if (_entries.length > maximumEntries) {
      _entries.removeRange(maximumEntries, _entries.length);
    }
    notifyListeners();
    _schedulePersist();
  }

  void _schedulePersist() {
    _writeQueue = _writeQueue.then<void>((_) async {
      try {
        final preferences = await _preferences();
        await preferences.setString(
          _storageKey,
          jsonEncode(_entries.map((entry) => entry.toJson()).toList()),
        );
      } on Object {
        // Diagnostics must never become the cause of an application failure.
      }
    });
  }

  Future<SharedPreferences> _preferences() async {
    return _providedPreferences ??= await SharedPreferences.getInstance();
  }

  static String _formatTimestamp(DateTime timestamp) {
    final value = timestamp.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
  }
}
