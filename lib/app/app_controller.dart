import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/app_settings_store.dart';
import '../platform/cloud_backup_configuration_store.dart';
import '../platform/secure_credential_store.dart';
import '../platform/source_configuration_store.dart';
import '../platform/public_identity_store.dart';
import '../platform/temporary_plaintext_platform.dart';
import '../sbox/bytes.dart';
import '../sbox/identity/bip39_identity.dart';
import '../sbox/identity/public_identity_record.dart';
import '../sbox/source/credential.dart';
import '../sbox/storage/temporary_plaintext_store.dart';
import 'app_logger.dart';

enum AppSection { library, encrypt, decrypt, sources, keys, settings }

final class AppController extends ChangeNotifier {
  AppController({
    PublicIdentityStore? identityStore,
    CloudBackupConfigurationStore? cloudBackupConfigurationStore,
    SourceConfigurationStore? sourceConfigurationStore,
    CredentialStore? credentialStore,
    TemporaryPlaintextStore? temporaryPlaintextStore,
    AppSettingsStore? appSettingsStore,
    AppLogger? logger,
  }) : _identityStore = identityStore ?? PublicIdentityStore(),
       _cloudBackupConfigurationStore =
           cloudBackupConfigurationStore ?? CloudBackupConfigurationStore(),
       _sourceConfigurationStore =
           sourceConfigurationStore ?? SourceConfigurationStore(),
       _credentialStore = credentialStore ?? PlatformCredentialStore(),
       _temporaryPlaintextStore =
           temporaryPlaintextStore ?? TemporaryPlaintextStore(),
       _appSettingsStore = appSettingsStore ?? AppSettingsStore(),
       _logger = logger ?? AppLogger(),
       _ownsLogger = logger == null {
    _logger.addListener(_loggerChanged);
  }

  static final _githubCredential = SourceCredentialId('safebox-github-token');
  static final _giteeCredential = SourceCredentialId('safebox-gitee-token');

  final PublicIdentityStore _identityStore;
  final CloudBackupConfigurationStore _cloudBackupConfigurationStore;
  final SourceConfigurationStore _sourceConfigurationStore;
  final CredentialStore _credentialStore;
  final TemporaryPlaintextStore _temporaryPlaintextStore;
  final AppSettingsStore _appSettingsStore;
  final AppLogger _logger;
  final bool _ownsLogger;
  PublicIdentityRecord? _identity;
  bool _initialized = false;
  String? _statusMessage;
  String? _errorMessage;

  bool get initialized => _initialized;
  bool get hasIdentity => _identity != null;
  PublicIdentityRecord? get identityRecord => _identity;
  String? get statusMessage => _statusMessage;
  String? get errorMessage => _errorMessage;
  AppLogger get logger => _logger;
  String get shortFingerprint {
    final record = _identity;
    if (record == null) return '未配置公开身份';
    final id = hexLower(record.recipientKeyId);
    return '${id.substring(0, 8)}…${id.substring(id.length - 8)}';
  }

  Future<void> initialize() async {
    if (_initialized) return;
    await _logger.initialize();
    _identity = await _identityStore.load();
    _initialized = true;
    _statusMessage = _identity == null ? '请创建或恢复 RSA 公开身份' : '已加载 RSA 公开身份';
    notifyListeners();
  }

  Future<String> createIdentity() async {
    final deriver = SboxIdentityDeriver();
    final mnemonic = deriver.generateMnemonic();
    final identity = await deriver.deriveIdentity(mnemonic);
    try {
      final record = PublicIdentityRecord.fromIdentity(identity.publicIdentity);
      await _identityStore.save(record);
      _identity = record;
      _statusMessage = '公开身份已保存；助记词只显示本次，请离线保管';
      _errorMessage = null;
      notifyListeners();
      return mnemonic;
    } finally {
      identity.disposeControlledSecrets();
    }
  }

  Future<void> restoreIdentity(String mnemonic) async {
    final identity = await SboxIdentityDeriver().deriveIdentity(mnemonic);
    try {
      final record = PublicIdentityRecord.fromIdentity(identity.publicIdentity);
      await _identityStore.save(record);
      _identity = record;
      _statusMessage = '公开身份已从助记词恢复';
      _errorMessage = null;
      notifyListeners();
    } finally {
      identity.disposeControlledSecrets();
    }
  }

  /// Removes all SafeBox identity-related data stored on this device.
  ///
  /// Remote repository contents are deliberately not touched. Each local
  /// cleanup is attempted even when another cleanup fails so a retry can make
  /// progress instead of stopping at the first unavailable store.
  Future<void> removeIdentity() async {
    final credentialIds = <SourceCredentialId>{
      _githubCredential,
      _giteeCredential,
    };
    try {
      final configuration = await _cloudBackupConfigurationStore.load();
      if (configuration != null) {
        credentialIds
          ..add(configuration.github.credentialId)
          ..add(configuration.gitee.credentialId);
      }
    } on Object {
      // The raw configuration key is still removed below even if its value
      // is corrupt and cannot be decoded.
    }
    try {
      final configurations = await _sourceConfigurationStore.loadAll();
      for (final configuration in configurations) {
        final credential = configuration.credentialReference;
        if (credential != null) credentialIds.add(credential);
      }
    } on Object {
      // As above, clearing the raw source-configuration key is still useful.
    }

    final failures = <Object>[];
    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } on Object catch (error) {
        failures.add(error);
      }
    }

    await attempt(() async {
      for (final credentialId in credentialIds) {
        await _credentialStore.deleteAccessToken(credentialId);
      }
    });
    await attempt(_identityStore.clear);
    await attempt(_cloudBackupConfigurationStore.clear);
    await attempt(_sourceConfigurationStore.clear);
    await attempt(_appSettingsStore.clear);
    await attempt(() async {
      final root = Directory(_temporaryPlaintextStore.path);
      if (await root.exists()) {
        await TemporaryPlaintextPlatform.protectRoot(root.path);
      }
      await _temporaryPlaintextStore.deleteRoot();
    });
    await attempt(_logger.clear);

    if (failures.isNotEmpty) {
      throw StateError('本机身份相关数据没有完全清理，请重试。');
    }

    _identity = null;
    _statusMessage = '请创建或恢复 RSA 公开身份';
    _errorMessage = null;
    notifyListeners();
  }

  void setStatus(String message) {
    _statusMessage = message;
    _errorMessage = null;
    notifyListeners();
  }

  void setError(Object error, {String operation = '应用操作失败'}) {
    _errorMessage = error.toString();
    _statusMessage = null;
    _logger.error(error, operation: operation);
    notifyListeners();
  }

  void clearMessages() {
    _statusMessage = null;
    _errorMessage = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _logger.removeListener(_loggerChanged);
    if (_ownsLogger) _logger.dispose();
    _identity = null;
    super.dispose();
  }

  void _loggerChanged() {
    if (_initialized) notifyListeners();
  }
}
