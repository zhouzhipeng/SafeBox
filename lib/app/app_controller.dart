import 'package:flutter/foundation.dart';

import '../platform/public_identity_store.dart';
import '../sbox/bytes.dart';
import '../sbox/identity/bip39_identity.dart';
import '../sbox/identity/public_identity_record.dart';
import 'app_logger.dart';

enum AppSection { library, encrypt, decrypt, sources, keys, settings }

final class AppController extends ChangeNotifier {
  AppController({PublicIdentityStore? identityStore, AppLogger? logger})
    : _identityStore = identityStore ?? PublicIdentityStore(),
      _logger = logger ?? AppLogger(),
      _ownsLogger = logger == null {
    _logger.addListener(_loggerChanged);
  }

  final PublicIdentityStore _identityStore;
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
