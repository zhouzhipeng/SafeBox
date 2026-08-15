import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:file_selector/file_selector.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../platform/public_identity_store.dart';
import '../platform/app_settings_store.dart';
import '../platform/authorized_directory_gateway.dart';
import '../platform/secure_credential_store.dart';
import '../platform/source_configuration_store.dart';
import '../sbox/bytes.dart';
import '../sbox/catalog/catalog_models.dart';
import '../sbox/catalog/catalog_state.dart';
import '../sbox/constants.dart';
import '../sbox/engine/crypto_task_runner.dart';
import '../sbox/errors.dart';
import '../sbox/format/header.dart';
import '../sbox/identity/bip39_identity.dart';
import '../sbox/identity/public_identity_record.dart';
import '../sbox/source/cipher_sync.dart';
import '../sbox/source/credential.dart';
import '../sbox/source/data_source.dart';
import '../sbox/source/gitee_source.dart';
import '../sbox/source/github_source.dart';
import '../sbox/source/https_source.dart';
import '../sbox/source/local_directory_source.dart';
import '../sbox/source/local_scanner.dart';
import '../sbox/source/remote_config.dart';
import '../sbox/source/source_config.dart';
import '../sbox/source/source_path.dart';
import '../sbox/storage/local_cipher_store.dart';
import '../sbox/storage/io_hash.dart';
import '../sbox/storage/temporary_plaintext_store.dart';

enum AppSection { library, encrypt, decrypt, sources, keys, settings, more }

enum AppOperation {
  idle,
  derivingIdentity,
  inspecting,
  refreshing,
  unlockingCatalog,
  syncingObjects,
  encrypting,
  updatingCatalog,
  uploading,
  decrypting,
  exporting,
  cleaning,
}

final class StandaloneSboxInspection {
  const StandaloneSboxInspection({
    required this.path,
    required this.version,
    required this.fileId,
    required this.recipientKeyId,
    required this.ciphertextBytes,
    required this.ciphertextSha256,
    required this.keyMatches,
  });

  final String path;
  final String version;
  final String fileId;
  final String recipientKeyId;
  final int ciphertextBytes;
  final Uint8List ciphertextSha256;
  final bool? keyMatches;
}

final class SourceLocalStats {
  const SourceLocalStats({required this.objectCount, required this.totalBytes});

  final int objectCount;
  final int totalBytes;
}

final class AppController extends ChangeNotifier {
  AppController({
    PublicIdentityStore? identityStore,
    SourceConfigurationStore? sourceStore,
    CredentialStore? credentialStore,
    AppSettingsStore? settingsStore,
    Future<Directory> Function()? supportDirectory,
    Future<Directory> Function()? temporaryDirectory,
    Future<Directory> Function()? documentsDirectory,
    Connectivity? connectivity,
    AuthorizedDirectoryGateway? authorizedDirectoryGateway,
  }) : _identityStore = identityStore ?? PublicIdentityStore(),
       _sourceStore = sourceStore ?? SourceConfigurationStore(),
       _credentialStore = credentialStore ?? PlatformCredentialStore(),
       _settingsStore = settingsStore ?? AppSettingsStore(),
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory,
       _connectivity = connectivity ?? Connectivity(),
       _authorizedDirectoryGateway =
           authorizedDirectoryGateway ??
           const MethodChannelAuthorizedDirectoryGateway();

  AppController.preview()
    : _identityStore = PublicIdentityStore(),
      _sourceStore = SourceConfigurationStore(),
      _credentialStore = PlatformCredentialStore(),
      _settingsStore = AppSettingsStore(),
      _supportDirectory = getApplicationSupportDirectory,
      _temporaryDirectory = getTemporaryDirectory,
      _documentsDirectory = getApplicationDocumentsDirectory,
      _connectivity = Connectivity(),
      _authorizedDirectoryGateway =
          const MethodChannelAuthorizedDirectoryGateway() {
    _previewMode = true;
    _initialized = true;
    _previewRecipientKeyId =
        '9549c41744d3b469c512aa2c845677940937fd20685220fb0eb00f15082b04ae';
    _previewSignerKeyId =
        'dc6c7e5d4cfc3c6bb5b364086fc8b68da0f7d8b041da907896d8c9b0ca060f2e';
    final sourceId = SourceId('00112233445566778899aabbccddeeff');
    _sources = <SourceConfiguration>[
      SourceConfiguration(
        sourceId: sourceId,
        displayName: '我的公开资料库',
        provider: SourceProvider.github,
        mode: SourceMode.readWrite,
        localSyncPath: p.join('SafeBox', sourceId.value),
        owner: 'zhouzhipeng',
        repository: 'SafeBox',
        branchOrRef: 'main',
        credentialReference: SourceCredentialId('preview-token'),
        catalogId: '11223344556677889900aabbccddeeff',
        highestGeneration: 8,
        lastCatalogSha256:
            '2f5f9d330a8699c4a0d6372749da35638ff103279b98885df3d74f9d9bca5baa',
        lastLocalSyncAt: DateTime.utc(2026, 8, 15, 9, 42),
      ),
    ];
    _selectedSourceId = sourceId;
    _catalog = CatalogViewTaskResult(
      catalogId: '11223344556677889900aabbccddeeff',
      generation: 8,
      encryptedCatalogSha256: Uint8List(32),
      continuity: CatalogContinuity.advanced,
      catalogPayloadsJson: const <Map<String, Object?>>[],
      entries: const <CatalogEntryViewData>[
        CatalogEntryViewData(
          entryId: '00112233445566778899aabbccddeeff',
          revision: 4,
          title: '年度财务资料',
          description: '归档后的财务报表与原始数据',
          originalName: 'financial-report-2026.pdf',
          mediaType: 'application/pdf',
          plaintextSize: '24870912',
          updatedAt: '2026-08-15T08:30:00Z',
          tags: <String>['财务', '归档'],
          partCount: 2,
        ),
        CatalogEntryViewData(
          entryId: '11223344556677889900aabbccddeeff',
          revision: 2,
          title: '服务器恢复说明',
          description: '离线环境恢复操作记录',
          originalName: 'recovery-notes.txt',
          mediaType: 'text/plain; charset=utf-8',
          plaintextSize: '18432',
          updatedAt: '2026-08-14T12:06:00Z',
          tags: <String>['文本', '运维'],
          partCount: 1,
        ),
        CatalogEntryViewData(
          entryId: '22334455667788990011aabbccddeeff',
          revision: 3,
          title: '产品设计素材',
          description: '设计源文件的加密备份',
          originalName: 'design-assets.zip',
          mediaType: 'application/zip',
          plaintextSize: '157286400',
          updatedAt: '2026-08-12T18:20:00Z',
          tags: <String>['设计', '备份'],
          partCount: 10,
        ),
      ],
    );
    _temporaryRoot = p.join('SafeBox', 'temporary-plaintext');
    _temporaryStats = const TemporaryPlaintextStats(
      fileCount: 3,
      totalBytes: 31629312,
    );
    _statusMessage = '目录签名与历史链已验证';
  }

  final PublicIdentityStore _identityStore;
  final SourceConfigurationStore _sourceStore;
  final CredentialStore _credentialStore;
  final AppSettingsStore _settingsStore;
  final Future<Directory> Function() _supportDirectory;
  final Future<Directory> Function() _temporaryDirectory;
  final Future<Directory> Function() _documentsDirectory;
  final Connectivity _connectivity;
  final AuthorizedDirectoryGateway _authorizedDirectoryGateway;
  final Set<http.Client> _activeHttpClients = <http.Client>{};
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  bool _initialized = false;
  bool _previewMode = false;
  PublicIdentityRecord? _identity;
  String? _previewRecipientKeyId;
  String? _previewSignerKeyId;
  List<SourceConfiguration> _sources = <SourceConfiguration>[];
  List<StoredPublicIdentity> _identityHistory = <StoredPublicIdentity>[];
  SourceId? _selectedSourceId;
  CatalogViewTaskResult? _catalog;
  List<ScannedSboxCandidate> _looseCandidates = <ScannedSboxCandidate>[];
  StandaloneSboxInspection? _inspection;
  TemporaryPlaintextStats? _temporaryStats;
  String? _temporaryRoot;
  String? _lastDecryptedPath;
  String? _lastDecryptedName;
  String? _errorMessage;
  String? _statusMessage;
  bool _clearPlaintextOnExit = false;
  AppOperation _operation = AppOperation.idle;
  CipherSyncProgress? _syncProgress;
  List<CatalogConflictViewData> _catalogConflicts = <CatalogConflictViewData>[];
  List<String> _temporaryCleanupFailures = <String>[];
  bool _cancellationRequested = false;

  bool get initialized => _initialized;
  bool get hasIdentity => _identity != null || _previewRecipientKeyId != null;
  PublicIdentityRecord? get identity => _identity;
  String? get recipientKeyId => _identity == null
      ? _previewRecipientKeyId
      : hexLower(_identity!.identity.recipientKeyId);
  String? get signerKeyId => _identity == null
      ? _previewSignerKeyId
      : hexLower(_identity!.identity.catalogSignerKeyId);
  String get shortFingerprint {
    final value = recipientKeyId;
    if (value == null) return '未创建身份';
    return '${value.substring(0, 8)} · ${value.substring(8, 16)} · '
        '${value.substring(value.length - 8)}';
  }

  List<SourceConfiguration> get sources => List.unmodifiable(_sources);
  List<StoredPublicIdentity> get identityHistory =>
      List.unmodifiable(_identityHistory);
  SourceConfiguration? get selectedSource {
    final id = _selectedSourceId;
    if (id == null) return null;
    for (final source in _sources) {
      if (source.sourceId == id) return source;
    }
    return null;
  }

  CatalogViewTaskResult? get catalog => _catalog;
  List<ScannedSboxCandidate> get looseCandidates =>
      List.unmodifiable(_looseCandidates);
  StandaloneSboxInspection? get inspection => _inspection;
  TemporaryPlaintextStats? get temporaryStats => _temporaryStats;
  String? get temporaryRoot => _temporaryRoot;
  String? get lastDecryptedPath => _lastDecryptedPath;
  String? get lastDecryptedName => _lastDecryptedName;
  String? get errorMessage => _errorMessage;
  String? get statusMessage => _statusMessage;
  AppOperation get operation => _operation;
  bool get isBusy => _operation != AppOperation.idle;
  CipherSyncProgress? get syncProgress => _syncProgress;
  List<CatalogConflictViewData> get catalogConflicts =>
      List<CatalogConflictViewData>.unmodifiable(_catalogConflicts);
  List<String> get temporaryCleanupFailures =>
      List<String>.unmodifiable(_temporaryCleanupFailures);
  bool get clearPlaintextOnExit => _clearPlaintextOnExit;
  bool get supportsAuthorizedDirectorySelection =>
      !_previewMode && _authorizedDirectoryGateway.isSupported;

  Future<void> initialize() async {
    if (_initialized) return;
    try {
      final values = await Future.wait<Object?>(<Future<Object?>>[
        _identityStore.load(),
        _sourceStore.loadAll(),
        _temporaryDirectory(),
        _identityStore.loadAll(),
        _settingsStore.loadClearPlaintextOnExit(),
      ]);
      _identity = values[0] as PublicIdentityRecord?;
      _sources = values[1]! as List<SourceConfiguration>;
      final tempBase = values[2]! as Directory;
      _identityHistory = values[3]! as List<StoredPublicIdentity>;
      _clearPlaintextOnExit = values[4]! as bool;
      _temporaryRoot = p.join(tempBase.path, 'safebox-plaintext-v1');
      if (_authorizedDirectoryGateway.isSupported) {
        await _authorizedDirectoryGateway.protectTemporaryPlaintextRoot(
          _temporaryRoot!,
        );
      }
      if (_sources.isNotEmpty) {
        _selectedSourceId = _sources.first.sourceId;
      }
      await _discardIncompleteCipherStaging();
      await _discardIncompleteTemporaryJobs();
      await refreshTemporaryStats();
      _startConnectivityMonitoring();
    } catch (error) {
      _errorMessage = _friendlyError(error);
    } finally {
      _initialized = true;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    CryptoTaskRunner.cancelAll();
    for (final client in _activeHttpClients) {
      client.close();
    }
    _activeHttpClients.clear();
    super.dispose();
  }

  String generateMnemonic() => SboxIdentityDeriver().generateMnemonic();

  Future<void> establishIdentity(String mnemonic) async {
    await _run(AppOperation.derivingIdentity, () async {
      final result = await CryptoTaskRunner.derivePublicIdentity(mnemonic);
      final record = PublicIdentityRecord.fromJson(result.publicIdentityJson);
      await _identityStore.save(record);
      _identity = record;
      _identityHistory = await _identityStore.loadAll();
      _statusMessage =
          '身份已建立：RSA 候选 p ${result.pCandidateCount} / q ${result.qCandidateCount}；仅保存公钥。';
    });
  }

  Future<void> clearIdentity() async {
    await _identityStore.clear();
    _identity = null;
    _identityHistory = <StoredPublicIdentity>[];
    _catalog = null;
    _statusMessage = '本地公钥记录已删除；密文原件未受影响。';
    notifyListeners();
  }

  Future<bool> verifyMnemonic(String mnemonic) async {
    var matches = false;
    await _run(AppOperation.derivingIdentity, () async {
      final expected = _requireIdentity();
      final result = await CryptoTaskRunner.derivePublicIdentity(mnemonic);
      final recovered = PublicIdentityRecord.fromJson(
        result.publicIdentityJson,
      );
      matches =
          hexLower(recovered.identity.recipientKeyId) ==
              hexLower(expected.identity.recipientKeyId) &&
          hexLower(recovered.identity.catalogSignerKeyId) ==
              hexLower(expected.identity.catalogSignerKeyId);
      _statusMessage = matches
          ? '助记词恢复结果与 RSA Key ID 和 Catalog Signer Key ID 均匹配。'
          : '助记词恢复结果与当前公开身份不匹配。';
    });
    return matches;
  }

  Future<void> exportPublicIdentity() async {
    await _run(AppOperation.exporting, _exportPublicIdentity);
  }

  Future<void> _exportPublicIdentity() async {
    final record = _identity;
    if (record == null) throw StateError('尚未建立身份');
    const suggestedName = 'safebox-public-key.json';
    final bytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(record.toJson()),
    );
    if (_authorizedDirectoryGateway.supportsFileExport) {
      final temporaryRoot = _temporaryRoot;
      if (temporaryRoot == null) throw StateError('应用临时目录尚未初始化');
      final exportBase = Directory(
        p.join(p.dirname(temporaryRoot), 'safebox-public-export-v1'),
      );
      final exportRoot = Directory(
        p.join(exportBase.path, hexLower(secureRandomBytes(16))),
      );
      await exportRoot.create(recursive: true);
      final temporary = File(p.join(exportRoot.path, suggestedName));
      try {
        await temporary.writeAsBytes(bytes, flush: true);
        final exported = await _authorizedDirectoryGateway.exportFile(
          sourcePath: temporary.path,
          suggestedName: suggestedName,
          mimeType: 'application/json',
        );
        if (!exported) return;
      } finally {
        if (await temporary.exists()) await temporary.delete();
        if (await exportRoot.exists()) await exportRoot.delete();
        if (await exportBase.exists() &&
            await exportBase.list(followLinks: false).isEmpty) {
          await exportBase.delete();
        }
      }
      _statusMessage = '公钥已导出；文件不包含助记词或私钥。';
      notifyListeners();
      return;
    }
    final location = await getSaveLocation(suggestedName: suggestedName);
    if (location == null) return;
    await XFile.fromData(
      Uint8List.fromList(bytes),
      mimeType: 'application/json',
      name: suggestedName,
    ).saveTo(location.path);
    _statusMessage = '公钥已导出；文件不包含助记词或私钥。';
    notifyListeners();
  }

  Future<LocalDirectoryProbe> inspectLocalDirectory(String path) =>
      LocalDirectoryProbe.inspect(Directory(path));

  Future<void> addLocalSource({
    required String displayName,
    required String path,
    required bool requestWrite,
    required bool initializeEmptyAsCanonical,
  }) async {
    await _run(AppOperation.inspecting, () async {
      final directory = Directory(path);
      final probe = await LocalDirectoryProbe.inspect(directory);
      var mode = probe.mode == LocalDirectoryProbeMode.canonicalCatalog
          ? ConfiguredLocalMode.canonicalCatalog
          : ConfiguredLocalMode.looseReadOnly;
      if (mode == ConfiguredLocalMode.looseReadOnly &&
          initializeEmptyAsCanonical &&
          await _isEffectivelyEmpty(directory)) {
        mode = ConfiguredLocalMode.canonicalCatalog;
      }
      final attached = await LocalDirectoryDataSource.attach(
        root: directory,
        mode: mode == ConfiguredLocalMode.canonicalCatalog
            ? LocalDirectoryMode.canonicalCatalog
            : LocalDirectoryMode.looseReadOnly,
        requestWrite: requestWrite,
      );
      final config = SourceConfiguration(
        sourceId: SourceId.random(),
        displayName: displayName,
        provider: SourceProvider.local,
        mode: attached.capabilities.canWrite
            ? SourceMode.readWrite
            : SourceMode.readOnly,
        localSyncPath: attached.root.path,
        localDirectoryMode: mode,
      );
      _sources = <SourceConfiguration>[..._sources, config];
      _selectedSourceId = config.sourceId;
      await _sourceStore.saveAll(_sources);
      _catalog = null;
      if (mode == ConfiguredLocalMode.looseReadOnly) {
        await _scanLoose(config);
        _statusMessage = '已离线加载未编目本地 SBOX；multipart 必须有签名 Catalog 才能重组。';
      } else if (probe.catalogHeader != null) {
        _statusMessage = '已挂载规范本地目录；请输入助记词验证 catalog.sbox。';
      } else {
        _statusMessage = '已建立空的规范本地目录；首次加密将创建 catalog.sbox。';
      }
    });
  }

  Future<bool> chooseAndAddAuthorizedLocalSource() async {
    if (!supportsAuthorizedDirectorySelection) return false;
    final selection = await _authorizedDirectoryGateway.chooseDirectory();
    if (selection == null) return false;
    await _run(AppOperation.inspecting, () async {
      final id = SourceId.random();
      final support = await _supportDirectory();
      final mirror = Directory(
        p.join(support.path, 'authorized-cipher-mirrors', id.value),
      );
      await FileSystemLocalCipherStore.open(mirror);
      final mirrored = await _authorizedDirectoryGateway.mirrorCiphertext(
        reference: selection.reference,
        destinationRoot: mirror.path,
      );
      final probe = await LocalDirectoryProbe.inspect(mirror);
      final localMode = probe.mode == LocalDirectoryProbeMode.canonicalCatalog
          ? ConfiguredLocalMode.canonicalCatalog
          : ConfiguredLocalMode.looseReadOnly;
      final config = SourceConfiguration(
        sourceId: id,
        displayName: selection.displayName,
        provider: SourceProvider.local,
        mode: SourceMode.readOnly,
        localSyncPath: mirror.path,
        localDirectoryMode: localMode,
        directoryAuthorizationReference: selection.reference,
        directoryAuthorizationPlatform: selection.platform,
        directoryAuthorizationDisplayName: selection.displayName,
      );
      _sources = <SourceConfiguration>[..._sources, config];
      _selectedSourceId = id;
      await _sourceStore.saveAll(_sources);
      _catalog = null;
      _catalogConflicts = <CatalogConflictViewData>[];
      if (localMode == ConfiguredLocalMode.looseReadOnly) {
        await _scanLoose(config);
      }
      _statusMessage = mirrored.catalogPresent
          ? '系统目录已授权并建立永久密文镜像；该提供方不保证原子替换，因此以只读模式挂载。'
          : '系统目录已授权并扫描 ${mirrored.fileCount} 个密文文件；没有 Catalog，multipart 无法重组。';
    });
    return true;
  }

  Future<void> addManagedWritableLocalSource() async {
    final path = await defaultLocalCipherDirectory();
    for (final source in _sources) {
      if (source.provider == SourceProvider.local &&
          !source.isAuthorizedDirectory &&
          _sameFileSystemPath(
            p.normalize(p.absolute(source.localSyncPath)),
            p.normalize(p.absolute(path)),
          )) {
        await selectSource(source.sourceId);
        _statusMessage = '已切换到应用管理的本机永久密文目录。';
        notifyListeners();
        return;
      }
    }
    await addLocalSource(
      displayName: '本机 SafeBox（应用管理）',
      path: path,
      requestWrite: true,
      initializeEmptyAsCanonical: true,
    );
  }

  Future<void> addRemoteSource({
    required String displayName,
    required SourceProvider provider,
    required String localMirrorParent,
    String? owner,
    String? repository,
    String branch = 'main',
    String pathPrefix = '',
    Uri? httpsBaseUri,
    String? accessToken,
    SourceSyncPolicy syncPolicy = SourceSyncPolicy.manual,
  }) async {
    if (provider == SourceProvider.local) {
      throw ArgumentError('Use addLocalSource for a local directory');
    }
    await _run(AppOperation.inspecting, () async {
      final id = SourceId.random();
      final credentialId = accessToken == null || accessToken.trim().isEmpty
          ? null
          : SourceCredentialId('source-${id.value}');
      if (provider != SourceProvider.https &&
          credentialId == null &&
          accessToken != null) {
        throw ArgumentError('访问令牌不能为空');
      }
      if (credentialId != null) {
        final token = SourceAccessToken.fromUtf8(accessToken!.trim());
        try {
          await _credentialStore.putAccessToken(credentialId, token);
        } finally {
          token.dispose();
        }
      }
      final mirror = Directory(p.join(localMirrorParent, id.value));
      await FileSystemLocalCipherStore.open(mirror);
      final config = SourceConfiguration(
        sourceId: id,
        displayName: displayName,
        provider: provider,
        mode: provider == SourceProvider.https || credentialId == null
            ? SourceMode.readOnly
            : SourceMode.readWrite,
        localSyncPath: mirror.path,
        owner: owner,
        repository: repository,
        branchOrRef: provider == SourceProvider.https ? null : branch,
        pathPrefix: provider == SourceProvider.https ? '' : pathPrefix,
        httpsBaseUri: httpsBaseUri,
        credentialReference: credentialId,
        syncPolicy: syncPolicy,
      );
      _sources = <SourceConfiguration>[..._sources, config];
      _selectedSourceId = id;
      await _sourceStore.saveAll(_sources);
      _catalog = null;
      _statusMessage = credentialId == null
          ? '公开匿名读取已配置；未保存写入凭据。'
          : '数据源已配置；访问令牌仅保存在系统安全存储中。';
    });
  }

  Future<void> removeSource(SourceId id) async {
    final target = _sources
        .where((source) => source.sourceId == id)
        .firstOrNull;
    if (target == null) {
      return;
    }
    final credential = target.credentialReference;
    if (credential != null) {
      await _credentialStore.deleteAccessToken(credential);
    }
    final authorization = target.directoryAuthorizationReference;
    if (authorization != null) {
      try {
        await _authorizedDirectoryGateway.release(authorization);
      } on Object {
        // Configuration removal must not be held hostage by a revoked system
        // directory capability. The ciphertext mirror remains untouched.
      }
    }
    _sources = _sources.where((source) => source.sourceId != id).toList();
    _selectedSourceId = _sources.firstOrNull?.sourceId;
    _catalog = null;
    _catalogConflicts = <CatalogConflictViewData>[];
    _looseCandidates = <ScannedSboxCandidate>[];
    await _sourceStore.saveAll(_sources);
    _statusMessage = '数据源配置已移除；远端内容和本地 SBOX 原件均未删除。';
    notifyListeners();
  }

  Future<void> updateSyncPolicy(SourceId id, SourceSyncPolicy policy) async {
    final target = _sources
        .where((source) => source.sourceId == id)
        .firstOrNull;
    if (target == null || !target.isRemote) return;
    await _replaceSource(target.copyWith(syncPolicy: policy));
    notifyListeners();
    if (policy != SourceSyncPolicy.manual) {
      unawaited(runAutomaticCipherSync());
    }
  }

  void _startConnectivityMonitoring() {
    if (_previewMode || _connectivitySubscription != null) return;
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen(
      (results) => unawaited(runAutomaticCipherSync(results)),
      onError: (_) {},
    );
    unawaited(runAutomaticCipherSync());
  }

  Future<void> runAutomaticCipherSync([
    List<ConnectivityResult>? connectivity,
  ]) async {
    if (_previewMode || isBusy || !hasIdentity) return;
    late final List<ConnectivityResult> available;
    try {
      available = connectivity ?? await _connectivity.checkConnectivity();
    } catch (_) {
      return;
    }
    if (isBusy) return;
    if (available.isEmpty ||
        available.every((value) => value == ConnectivityResult.none)) {
      return;
    }
    final eligible = _sources
        .where(
          (source) =>
              source.isRemote &&
              !source.hasPendingCatalog &&
              _syncPolicyAllows(source.syncPolicy, available),
        )
        .toList(growable: false);
    if (eligible.isEmpty) return;

    _operation = AppOperation.refreshing;
    _syncProgress = null;
    _errorMessage = null;
    notifyListeners();
    Object? lastError;
    var refreshed = 0;
    try {
      for (final queued in eligible) {
        final current = _sources
            .where((value) => value.sourceId == queued.sourceId)
            .firstOrNull;
        if (current == null || current.hasPendingCatalog) continue;
        try {
          if (await _pullEncryptedCatalogForConfig(current)) refreshed++;
        } catch (error) {
          lastError = error;
        }
      }
      if (refreshed > 0) {
        _statusMessage = '自动同步已更新 $refreshed 个加密 Catalog；输入助记词后才会展示目录。';
      }
      if (lastError != null) _errorMessage = _friendlyError(lastError);
    } finally {
      _operation = AppOperation.idle;
      notifyListeners();
    }
  }

  static bool _syncPolicyAllows(
    SourceSyncPolicy policy,
    List<ConnectivityResult> available,
  ) => switch (policy) {
    SourceSyncPolicy.manual => false,
    SourceSyncPolicy.wifiOnly => available.any(
      (value) =>
          value == ConnectivityResult.wifi ||
          value == ConnectivityResult.ethernet,
    ),
    SourceSyncPolicy.anyNetwork => available.any(
      (value) => value != ConnectivityResult.none,
    ),
  };

  Future<bool> _pullEncryptedCatalogForConfig(
    SourceConfiguration config,
  ) async {
    if (!config.isRemote || config.hasPendingCatalog) return false;
    return _withSource(config, (source) async {
      final store = await FileSystemLocalCipherStore.open(
        Directory(config.localSyncPath),
      );
      final synchronizer = CipherMirrorSynchronizer(
        source: source,
        localStore: store,
        onProgress: _onSyncProgress,
      );
      final currentMirrorHash =
          config.localCatalogMirrorSha256 ?? config.lastCatalogSha256;
      final result = await synchronizer.pullEncryptedCatalog(
        ifNoneMatch: config.lastProviderRevision,
        expectedCurrentLocalSha256: currentMirrorHash == null
            ? null
            : decodeHex(currentMirrorHash),
        expectedRecipientKeyId: recipientKeyId,
      );
      await _replaceSource(
        config.copyWith(
          lastProviderRevision: result.providerRevision,
          localCatalogMirrorSha256: result.localObject == null
              ? null
              : hexLower(result.localObject!.sha256),
          lastLocalSyncAt: DateTime.now().toUtc(),
        ),
      );
      if (!result.notModified && _selectedSourceId == config.sourceId) {
        _catalog = null;
        _catalogConflicts = <CatalogConflictViewData>[];
      }
      return !result.notModified;
    });
  }

  Future<void> selectSource(SourceId id) async {
    if (!_sources.any((source) => source.sourceId == id)) return;
    _selectedSourceId = id;
    _catalog = null;
    _catalogConflicts = <CatalogConflictViewData>[];
    _looseCandidates = <ScannedSboxCandidate>[];
    _inspection = null;
    notifyListeners();
    final source = selectedSource!;
    if (source.isAuthorizedDirectory) {
      await _run(AppOperation.refreshing, () async {
        await _refreshAuthorizedDirectoryMirror(source);
        if (source.localDirectoryMode == ConfiguredLocalMode.looseReadOnly) {
          await _scanLoose(source);
        }
        _statusMessage = '系统授权目录的永久密文镜像已刷新。';
      });
      return;
    }
    if (source.provider == SourceProvider.local &&
        source.localDirectoryMode == ConfiguredLocalMode.looseReadOnly) {
      await _run(AppOperation.refreshing, () => _scanLoose(source));
    }
  }

  Future<void> refreshSelectedSource() async {
    final config = _requireSource();
    await _run(AppOperation.refreshing, () async {
      _catalogConflicts = <CatalogConflictViewData>[];
      if (config.provider == SourceProvider.local) {
        if (config.isAuthorizedDirectory) {
          await _refreshAuthorizedDirectoryMirror(config);
        }
        if (config.localDirectoryMode == ConfiguredLocalMode.looseReadOnly) {
          await _scanLoose(config);
          _statusMessage = '本地目录扫描完成：${_looseCandidates.length} 个可识别 SBOX。';
        } else {
          final catalog = File(p.join(config.localSyncPath, 'catalog.sbox'));
          if (!await catalog.exists()) {
            _statusMessage = '规范目录尚未创建 catalog.sbox。';
          } else {
            _statusMessage = '本地 catalog.sbox 已刷新；需要助记词完成签名验证。';
          }
        }
        return;
      }
      if (config.hasPendingCatalog) {
        _statusMessage = '本地有待同步 Catalog；不会用远端版本覆盖。请输入助记词后执行条件同步。';
        return;
      }
      final changed = await _pullEncryptedCatalogForConfig(config);
      _statusMessage = changed
          ? '已下载加密目录；请输入助记词验证签名并同步所需分片。'
          : '远端 catalog.sbox 未变化，本地密文镜像保持最新。';
    });
  }

  Future<void> unlockSelectedCatalog(
    String mnemonic, {
    bool syncObjects = true,
  }) async {
    final config = _requireSource();
    if (config.localDirectoryMode == ConfiguredLocalMode.looseReadOnly) {
      throw const SboxException(
        SboxErrorCode.catalogRequired,
        '未编目目录没有可验证的 catalog.sbox',
      );
    }
    final identityJson = _requireIdentity().toJson();
    await _run(AppOperation.unlockingCatalog, () async {
      final path = p.join(config.localSyncPath, 'catalog.sbox');
      final checkpoint = config.checkpoint;
      final result = await CryptoTaskRunner.unlockCatalog(
        catalogPath: path,
        mnemonic: mnemonic,
        publicIdentityJson: identityJson,
        expectedCatalogId: config.effectiveCatalogId,
        checkpointJson: checkpoint == null
            ? null
            : <String, Object?>{
                'catalog_id': checkpoint.catalogId,
                'highest_generation': checkpoint.highestGeneration,
                'last_catalog_sha256': checkpoint.lastCatalogSha256,
              },
      );
      _catalog = result;
      _catalogConflicts = <CatalogConflictViewData>[];
      final openedHash = hexLower(result.encryptedCatalogSha256);
      final opensPending =
          config.hasPendingCatalog && openedHash == config.pendingCatalogSha256;
      await _replaceSource(
        opensPending
            ? config.copyWith(lastLocalSyncAt: DateTime.now().toUtc())
            : config.copyWith(
                catalogId: result.catalogId,
                highestGeneration: result.generation,
                lastCatalogSha256: openedHash,
                localCatalogMirrorSha256: openedHash,
                lastLocalSyncAt: DateTime.now().toUtc(),
              ),
      );
      if (syncObjects && config.isRemote) {
        _operation = AppOperation.syncingObjects;
        notifyListeners();
        await _withSource(selectedSource!, (source) async {
          final store = await FileSystemLocalCipherStore.open(
            Directory(config.localSyncPath),
          );
          final sync = CipherMirrorSynchronizer(
            source: source,
            localStore: store,
            onProgress: _onSyncProgress,
          );
          await sync.pullAuthenticatedCatalogPayloads(
            result.catalogPayloadsJson.map(CatalogPayload.fromJson),
            expectedRecipientKeyId: recipientKeyId!,
          );
        });
      }
      _statusMessage = opensPending
          ? '本地待同步 Catalog 已通过解密与签名验证；远端检查点保持不变。'
          : _continuityText(result.continuity);
    });
  }

  Future<void> encryptAndSave({
    String? inputPath,
    String? text,
    required String mnemonic,
    required String originalName,
    required String title,
    required String description,
    required List<String> tags,
    required bool syncRemote,
  }) async {
    final config = _requireSource();
    if (!config.isWritable) {
      throw const SboxException(SboxErrorCode.sourceAuthentication, '当前数据源只读');
    }
    final identity = _requireIdentity();
    await _run(AppOperation.encrypting, () async {
      final pendingBaseHash = config.isRemote
          ? await _preparePendingCatalogBase(config)
          : null;
      final capabilities = await _withSource(
        config,
        (source) async => source.capabilities,
      );
      final mediaType = inputPath == null
          ? 'text/plain; charset=utf-8'
          : lookupMimeType(inputPath) ?? 'application/octet-stream';
      final result = await CryptoTaskRunner.encryptAndCommitCatalog(
        inputPath: inputPath,
        text: text,
        localCipherRoot: config.localSyncPath,
        publicIdentityJson: identity.toJson(),
        mnemonic: mnemonic,
        contentKind: inputPath == null
            ? SboxContentKind.text.wireValue
            : SboxContentKind.file.wireValue,
        originalName: originalName,
        mediaType: mediaType,
        title: title,
        description: description,
        tags: tags,
        capabilitiesJson: CryptoTaskRunner.capabilitiesToMessage(capabilities),
      );
      _catalog = CatalogViewTaskResult(
        catalogId: result.catalogId,
        generation: result.generation,
        encryptedCatalogSha256: result.encryptedCatalogSha256,
        continuity: CatalogContinuity.advanced,
        catalogPayloadsJson: result.catalogPayloadsJson,
        entries: result.entries,
      );
      _catalogConflicts = <CatalogConflictViewData>[];

      if (!config.isRemote) {
        await _replaceSource(
          config.copyWith(
            catalogId: result.catalogId,
            highestGeneration: result.generation,
            lastCatalogSha256: hexLower(result.encryptedCatalogSha256),
            localCatalogMirrorSha256: hexLower(result.encryptedCatalogSha256),
            lastLocalSyncAt: DateTime.now().toUtc(),
          ),
        );
        _statusMessage = '加密对象与 catalog.sbox 已永久保存到本地；未上传任何明文。';
        return;
      }

      final pending = config.copyWith(
        pendingCatalogId: result.catalogId,
        pendingCatalogGeneration: result.generation,
        pendingCatalogSha256: hexLower(result.encryptedCatalogSha256),
        localCatalogMirrorSha256: hexLower(result.encryptedCatalogSha256),
        pendingBaseCatalogSha256:
            config.pendingBaseCatalogSha256 ?? pendingBaseHash,
        lastLocalSyncAt: DateTime.now().toUtc(),
      );
      await _replaceSource(pending);
      if (!syncRemote) {
        _statusMessage = '密文已永久保存到本地并进入待同步队列；未上传任何明文。';
        return;
      }
      await _publishPendingCatalog(
        pending,
        mnemonic,
        identity.toJson(),
        pendingView: _catalog,
      );
    });
  }

  Future<void> syncPendingCatalog(String mnemonic) async {
    final config = _requireSource();
    if (!config.isRemote || !config.hasPendingCatalog) {
      throw StateError('当前数据源没有待同步 Catalog');
    }
    final identity = _requireIdentity();
    await _run(AppOperation.unlockingCatalog, () async {
      final path = p.join(config.localSyncPath, 'catalog.sbox');
      final pendingView = await CryptoTaskRunner.unlockCatalog(
        catalogPath: path,
        mnemonic: mnemonic,
        publicIdentityJson: identity.toJson(),
        expectedCatalogId: config.effectiveCatalogId,
      );
      if (hexLower(pendingView.encryptedCatalogSha256) !=
              config.pendingCatalogSha256 ||
          pendingView.generation != config.pendingCatalogGeneration) {
        throw const SboxException(
          SboxErrorCode.syncConflict,
          '本地待同步 Catalog 与持久化队列状态不一致',
        );
      }
      _catalog = pendingView;
      await _publishPendingCatalog(
        config,
        mnemonic,
        identity.toJson(),
        pendingView: pendingView,
      );
    });
  }

  Future<void> resolveCatalogConflicts({
    required String mnemonic,
    required Map<String, CatalogConflictResolution> resolutions,
  }) async {
    final config = _requireSource();
    if (!config.isRemote || !config.hasPendingCatalog) {
      throw StateError('当前数据源没有可处理的待同步 Catalog');
    }
    if (_catalogConflicts.isEmpty) {
      throw StateError('当前没有 Catalog 条目冲突');
    }
    final current = _catalog ?? (throw StateError('本地待同步 Catalog 未验证'));
    if (hexLower(current.encryptedCatalogSha256) !=
        config.pendingCatalogSha256) {
      throw const SboxException(
        SboxErrorCode.syncConflict,
        '本地待同步 Catalog 与冲突视图不一致',
      );
    }
    final baseHash = config.pendingBaseCatalogSha256;
    if (baseHash == null) {
      throw const SboxException(
        SboxErrorCode.syncConflict,
        '没有共同基线，不能执行逐条冲突选择',
      );
    }
    final identity = _requireIdentity();
    await _run(AppOperation.updatingCatalog, () async {
      final remoteRoot = Directory(
        p.join(
          config.localSyncPath,
          '.sbox-staging',
          'remote-resolve-${hexLower(secureRandomBytes(12))}',
        ),
      );
      CatalogViewTaskResult? resolvedView;
      SourceConfiguration? resolvedPending;
      RevisionToken? expectedRemoteRevision;
      String? newestBaseHash;
      try {
        try {
          await _withSource(config, (source) async {
            final remoteStore = await FileSystemLocalCipherStore.open(
              remoteRoot,
            );
            final remoteMirror = await CipherMirrorSynchronizer(
              source: source,
              localStore: remoteStore,
              onProgress: _onSyncProgress,
            ).pullEncryptedCatalog(expectedRecipientKeyId: recipientKeyId);
            final remoteCatalog = remoteMirror.localObject;
            if (remoteCatalog == null) {
              throw const SboxException(
                SboxErrorCode.syncConflict,
                '远端 Catalog 已删除，不能应用冲突选择',
              );
            }
            newestBaseHash = hexLower(remoteCatalog.sha256);
            await _savePendingBaseSnapshot(
              config,
              remoteCatalog.file,
              newestBaseHash!,
            );
            final result =
                await CryptoTaskRunner.resolvePendingCatalogConflicts(
                  baseCatalogPath: _pendingBaseCatalogPath(config),
                  localCatalogPath: p.join(
                    config.localSyncPath,
                    'catalog.sbox',
                  ),
                  remoteCatalogPath: remoteCatalog.file.path,
                  localCipherRoot: config.localSyncPath,
                  mnemonic: mnemonic,
                  publicIdentityJson: identity.toJson(),
                  expectedCurrentCatalogSha256: current.encryptedCatalogSha256,
                  resolutions: resolutions,
                );
            if (result is CatalogConflictsTaskResult) {
              _catalogConflicts = result.conflicts;
              throw const SboxException(
                SboxErrorCode.syncConflict,
                '冲突选择不完整或远端再次变化',
              );
            }
            final merged = result as CatalogMergedTaskResult;
            resolvedView = CatalogViewTaskResult(
              catalogId: merged.catalogId,
              generation: merged.generation,
              encryptedCatalogSha256: merged.encryptedCatalogSha256,
              entries: merged.entries,
              catalogPayloadsJson: merged.catalogPayloadsJson,
              continuity: CatalogContinuity.advanced,
            );
            expectedRemoteRevision = remoteMirror.providerRevision;
            resolvedPending = config.copyWith(
              pendingCatalogId: resolvedView!.catalogId,
              pendingCatalogGeneration: resolvedView!.generation,
              pendingCatalogSha256: hexLower(
                resolvedView!.encryptedCatalogSha256,
              ),
              localCatalogMirrorSha256: hexLower(
                resolvedView!.encryptedCatalogSha256,
              ),
              pendingBaseCatalogSha256: newestBaseHash,
              lastProviderRevision: expectedRemoteRevision,
            );
            await _replaceSource(resolvedPending!);
            if (baseHash != newestBaseHash) {
              await _deletePendingBaseHash(config, baseHash);
            }
            _catalog = resolvedView;
            _catalogConflicts = <CatalogConflictViewData>[];

            final localStore = await FileSystemLocalCipherStore.open(
              Directory(config.localSyncPath),
            );
            await CipherMirrorSynchronizer(
              source: source,
              localStore: localStore,
              onProgress: _onSyncProgress,
            ).pullAuthenticatedCatalogPayloads(
              merged.catalogPayloadsJson.map(CatalogPayload.fromJson),
              expectedRecipientKeyId: recipientKeyId!,
            );
          });
        } on Object {
          if (resolvedPending == null &&
              newestBaseHash != null &&
              newestBaseHash != baseHash) {
            await _deletePendingBaseHash(config, newestBaseHash!);
          }
          rethrow;
        }
      } finally {
        await _deleteTemporaryRemoteMirror(config, remoteRoot);
      }
      final resolved = resolvedView!;
      await _publishPendingCatalog(
        resolvedPending!,
        mnemonic,
        identity.toJson(),
        pendingView: resolved,
      );
    });
  }

  Future<void> updateCatalogEntryMetadata({
    required String entryId,
    required String title,
    required String description,
    required List<String> tags,
    required String mnemonic,
    required bool syncRemote,
  }) async {
    final config = _requireSource();
    if (!config.isWritable) {
      throw const SboxException(SboxErrorCode.sourceAuthentication, '当前数据源只读');
    }
    final current = _catalog ?? (throw StateError('请先验证并打开 Catalog'));
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty) {
      throw ArgumentError.value(title, 'title', 'Catalog 标题不能为空');
    }
    final identity = _requireIdentity();
    await _run(AppOperation.updatingCatalog, () async {
      final pendingBaseHash = config.isRemote
          ? await _preparePendingCatalogBase(config)
          : null;
      final result = await CryptoTaskRunner.updateCatalogMetadata(
        localCipherRoot: config.localSyncPath,
        mnemonic: mnemonic,
        publicIdentityJson: identity.toJson(),
        expectedCatalogId: current.catalogId,
        expectedCatalogSha256: current.encryptedCatalogSha256,
        entryId: entryId,
        title: normalizedTitle,
        description: description.trim(),
        tags: tags,
      );
      await _recordCatalogMutation(
        config: config,
        pendingBaseHash: pendingBaseHash,
        result: result,
        mnemonic: mnemonic,
        publicIdentityJson: identity.toJson(),
        syncRemote: syncRemote,
        localStatus: '条目元数据与签名 Catalog 已更新；永久密文对象未被改写。',
        queuedStatus: '条目元数据已写入本地加密 Catalog，并进入待同步队列。',
      );
    });
  }

  Future<void> deleteCatalogEntry({
    required String entryId,
    required String mnemonic,
    required bool syncRemote,
  }) async {
    final config = _requireSource();
    if (!config.isWritable) {
      throw const SboxException(SboxErrorCode.sourceAuthentication, '当前数据源只读');
    }
    final current = _catalog ?? (throw StateError('请先验证并打开 Catalog'));
    final identity = _requireIdentity();
    await _run(AppOperation.updatingCatalog, () async {
      final pendingBaseHash = config.isRemote
          ? await _preparePendingCatalogBase(config)
          : null;
      final result = await CryptoTaskRunner.deleteCatalogEntry(
        localCipherRoot: config.localSyncPath,
        mnemonic: mnemonic,
        publicIdentityJson: identity.toJson(),
        expectedCatalogId: current.catalogId,
        expectedCatalogSha256: current.encryptedCatalogSha256,
        entryId: entryId,
      );
      await _recordCatalogMutation(
        config: config,
        pendingBaseHash: pendingBaseHash,
        result: result,
        mnemonic: mnemonic,
        publicIdentityJson: identity.toJson(),
        syncRemote: syncRemote,
        localStatus: '条目已从 Catalog 逻辑删除并写入墓碑；永久 SBOX 原件未删除。',
        queuedStatus: '逻辑删除墓碑已加密保存并进入待同步队列；永久 SBOX 原件未删除。',
      );
    });
  }

  Future<void> _recordCatalogMutation({
    required SourceConfiguration config,
    required String? pendingBaseHash,
    required CatalogViewTaskResult result,
    required String mnemonic,
    required Map<String, Object?> publicIdentityJson,
    required bool syncRemote,
    required String localStatus,
    required String queuedStatus,
  }) async {
    _catalog = result;
    _catalogConflicts = <CatalogConflictViewData>[];
    if (!config.isRemote) {
      await _replaceSource(
        config.copyWith(
          catalogId: result.catalogId,
          highestGeneration: result.generation,
          lastCatalogSha256: hexLower(result.encryptedCatalogSha256),
          localCatalogMirrorSha256: hexLower(result.encryptedCatalogSha256),
          lastLocalSyncAt: DateTime.now().toUtc(),
        ),
      );
      _statusMessage = localStatus;
      return;
    }

    final pending = config.copyWith(
      pendingCatalogId: result.catalogId,
      pendingCatalogGeneration: result.generation,
      pendingCatalogSha256: hexLower(result.encryptedCatalogSha256),
      localCatalogMirrorSha256: hexLower(result.encryptedCatalogSha256),
      pendingBaseCatalogSha256:
          config.pendingBaseCatalogSha256 ?? pendingBaseHash,
      lastLocalSyncAt: DateTime.now().toUtc(),
    );
    await _replaceSource(pending);
    if (!syncRemote) {
      _statusMessage = queuedStatus;
      return;
    }
    await _publishPendingCatalog(
      pending,
      mnemonic,
      publicIdentityJson,
      pendingView: result,
    );
  }

  Future<void> discardPendingCatalogAndRestoreBase() async {
    final config = _requireSource();
    if (!config.isRemote || !config.hasPendingCatalog) return;
    await _run(AppOperation.cleaning, () async {
      final pendingHash = decodeHex(config.pendingCatalogSha256!);
      final baseHash = config.pendingBaseCatalogSha256;
      if (baseHash == null) {
        await _deleteCatalogIfHashMatches(config, pendingHash);
      } else {
        final base = File(_pendingBaseCatalogPath(config));
        await _restorePendingBase(
          config,
          base,
          decodeHex(baseHash),
          pendingHash,
        );
      }
      await _deletePendingBase(config);
      await _replaceSource(
        config.copyWith(
          clearPendingCatalog: true,
          localCatalogMirrorSha256: baseHash,
          clearLocalCatalogMirror: baseHash == null,
        ),
      );
      _catalog = null;
      _catalogConflicts = <CatalogConflictViewData>[];
      _statusMessage = '已放弃本地待同步目录版本；已加密对象仍永久保留，未删除任何远端内容。';
    });
  }

  Future<void> inspectStandalone(String path) async {
    await _run(AppOperation.inspecting, () async {
      final file = File(path);
      final handle = await file.open();
      try {
        await _setInspectionFromHandle(path, handle);
        _statusMessage = '公共头部解析完成；原始文件名只会在认证 Metadata 后显示。';
      } finally {
        await handle.close();
      }
    });
  }

  Future<void> inspectLooseCandidate(ScannedSboxCandidate candidate) async {
    final config = _requireSource();
    if (config.localDirectoryMode != ConfiguredLocalMode.looseReadOnly) {
      throw StateError('当前数据源不是未编目本地目录');
    }
    await _run(AppOperation.inspecting, () async {
      final root = p.normalize(
        p.absolute(
          await Directory(config.localSyncPath).resolveSymbolicLinks(),
        ),
      );
      final path = p.normalize(p.absolute(candidate.file.path));
      if (!p.isWithin(root, path) ||
          await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.file) {
        throw const SboxException(
          SboxErrorCode.remoteChanged,
          '扫描后的本地 SBOX 路径已变化或越界',
        );
      }
      final resolved = p.normalize(
        p.absolute(await File(path).resolveSymbolicLinks()),
      );
      if (!_sameFileSystemPath(resolved, path) || !p.isWithin(root, resolved)) {
        throw const SboxException(
          SboxErrorCode.remoteChanged,
          '扫描后的本地 SBOX 被替换为链接',
        );
      }
      final handle = await File(path).open();
      try {
        if (await handle.length() != candidate.ciphertextSize ||
            !constantTimeBytesEqual(
              await sha256RandomAccessFile(handle),
              candidate.sha256,
            )) {
          throw const SboxException(
            SboxErrorCode.remoteChanged,
            '扫描后的本地 SBOX 内容已变化',
          );
        }
        await _setInspectionFromHandle(path, handle);
        _statusMessage = '已重新核对目录边界、普通文件类型、长度、摘要与公共头部。';
      } finally {
        await handle.close();
      }
    });
  }

  Future<void> _setInspectionFromHandle(
    String path,
    RandomAccessFile handle,
  ) async {
    final length = await handle.length();
    if (length < SboxV1.headerLength) {
      throw const SboxException(SboxErrorCode.invalidHeader, 'SBOX 文件短于固定头部');
    }
    await handle.setPosition(0);
    final bytes = await handle.read(SboxV1.headerLength);
    final header = SboxHeader.parse(bytes);
    final hash = await sha256RandomAccessFile(handle);
    final keyId = hexLower(header.recipientKeyId);
    _inspection = StandaloneSboxInspection(
      path: path,
      version: '${SboxV1.versionMajor}.${SboxV1.versionMinor}',
      fileId: hexLower(header.fileId),
      recipientKeyId: keyId,
      ciphertextBytes: length,
      ciphertextSha256: hash,
      keyMatches: recipientKeyId == null ? null : keyId == recipientKeyId,
    );
  }

  Future<void> decryptStandalone(String mnemonic) async {
    final inspected = _inspection;
    if (inspected == null) throw StateError('请先选择 SBOX 文件');
    final identity = _requireIdentity();
    await _run(AppOperation.decrypting, () async {
      final result = await CryptoTaskRunner.decryptStandalone(
        sboxPath: inspected.path,
        temporaryPlaintextRoot: _temporaryRoot!,
        cipherRoots: _sources.map((source) => source.localSyncPath).toList(),
        mnemonic: mnemonic,
        publicIdentityJson: identity.toJson(),
        expectedCiphertextSha256: inspected.ciphertextSha256,
      );
      _lastDecryptedPath = result.plaintextPath;
      _lastDecryptedName = result.originalName;
      await refreshTemporaryStats();
      _statusMessage = 'GCM 与 Final 完整认证通过；明文已发布到受管理临时目录。';
    });
  }

  Future<void> decryptEntry(String entryId, String mnemonic) async {
    final config = _requireSource();
    final identity = _requireIdentity();
    await _run(AppOperation.decrypting, () async {
      final result = await CryptoTaskRunner.decryptCatalogEntry(
        catalogPath: p.join(config.localSyncPath, 'catalog.sbox'),
        entryId: entryId,
        localCipherRoot: config.localSyncPath,
        temporaryPlaintextRoot: _temporaryRoot!,
        cipherRoots: _sources.map((source) => source.localSyncPath).toList(),
        mnemonic: mnemonic,
        publicIdentityJson: identity.toJson(),
        expectedCatalogId: config.catalogId,
      );
      _lastDecryptedPath = result.plaintextPath;
      _lastDecryptedName = result.originalName;
      await refreshTemporaryStats();
      _statusMessage = '全部密文分片与整体摘要验证通过，明文已发布到临时目录。';
    });
  }

  Future<void> refreshTemporaryStats() async {
    final root = _temporaryRoot;
    if (root == null) return;
    try {
      final store = await ManagedTemporaryPlaintextStore.open(
        root: Directory(root),
        cipherRoots: _sources.map((source) => Directory(source.localSyncPath)),
      );
      _temporaryStats = await store.stats();
    } on SboxException {
      rethrow;
    }
    notifyListeners();
  }

  Future<TemporaryCleanupReport> clearTemporaryPlaintext() async {
    late TemporaryCleanupReport report;
    await _run(AppOperation.cleaning, () async {
      final store = await ManagedTemporaryPlaintextStore.open(
        root: Directory(_temporaryRoot!),
        cipherRoots: _sources.map((source) => Directory(source.localSyncPath)),
      );
      report = await store.clearAll();
      _temporaryCleanupFailures = report.failedPaths;
      _temporaryStats = await store.stats();
      _lastDecryptedPath = null;
      _lastDecryptedName = null;
      _statusMessage = report.isComplete
          ? '已删除 ${report.deletedFiles} 个临时明文；本地 SBOX 密文未受影响。'
          : '临时明文仅部分删除，仍有 ${report.failedPaths.length} 个路径失败。';
    });
    return report;
  }

  Future<void> deleteLastDecrypted() async {
    final path = _lastDecryptedPath;
    if (path == null) return;
    final store = await ManagedTemporaryPlaintextStore.open(
      root: Directory(_temporaryRoot!),
      cipherRoots: _sources.map((source) => Directory(source.localSyncPath)),
    );
    await store.deletePublishedPath(path);
    _lastDecryptedPath = null;
    _lastDecryptedName = null;
    _temporaryStats = await store.stats();
    _statusMessage = '该临时明文副本已删除；本地 SBOX 密文原件未受影响。';
    notifyListeners();
  }

  Future<void> exportLastDecrypted() async {
    await _run(AppOperation.exporting, _exportLastDecrypted);
  }

  Future<void> _exportLastDecrypted() async {
    final path = _lastDecryptedPath;
    if (path == null) return;
    if (_authorizedDirectoryGateway.supportsFileExport) {
      final suggestedName = p.basename(path);
      final exported = await _authorizedDirectoryGateway.exportFile(
        sourcePath: path,
        suggestedName: suggestedName,
        mimeType: lookupMimeType(suggestedName) ?? 'application/octet-stream',
      );
      if (!exported) return;
      _statusMessage = '已导出验证通过的明文；导出文件不再属于临时清理范围。';
      notifyListeners();
      return;
    }
    final location = await getSaveLocation(
      suggestedName: _lastDecryptedName ?? p.basename(path),
    );
    if (location == null) return;
    if (p.equals(p.normalize(path), p.normalize(location.path))) {
      throw ArgumentError('导出位置不能是受管理临时文件本身');
    }
    await File(path).copy(location.path);
    _statusMessage = '已导出验证通过的明文；导出文件不再属于临时清理范围。';
    notifyListeners();
  }

  Future<void> openLastDecrypted() async {
    final path = _lastDecryptedPath;
    if (path == null) return;
    if (!await launchUrl(Uri.file(path))) {
      throw StateError('系统无法打开该文件');
    }
  }

  Future<void> openLocalPath(String path) async {
    if (!await launchUrl(Uri.directory(path))) {
      throw StateError('系统无法打开该目录');
    }
  }

  Future<void> setClearPlaintextOnExit(bool value) async {
    await _settingsStore.saveClearPlaintextOnExit(value);
    _clearPlaintextOnExit = value;
    notifyListeners();
  }

  Future<SourceLocalStats> sourceStats(SourceConfiguration config) async {
    final root = Directory(config.localSyncPath);
    if (!await root.exists()) {
      return const SourceLocalStats(objectCount: 0, totalBytes: 0);
    }
    var count = 0;
    var bytes = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (await FileSystemEntity.type(entity.path, followLinks: false) ==
              FileSystemEntityType.file &&
          entity.path.toLowerCase().endsWith('.sbox')) {
        count++;
        bytes += await File(entity.path).length();
      }
    }
    return SourceLocalStats(objectCount: count, totalBytes: bytes);
  }

  Future<String> defaultRemoteMirrorParent() async {
    if (_previewMode) {
      return p.join('SafeBox', 'cipher-mirrors');
    }
    final base = await _supportDirectory();
    final root = Directory(p.join(base.path, 'cipher-mirrors'));
    await root.create(recursive: true);
    return root.path;
  }

  Future<String> defaultLocalCipherDirectory() async {
    if (_previewMode) return p.join('SafeBox', 'local-ciphertext');
    final base = await _documentsDirectory();
    final root = Directory(p.join(base.path, 'SafeBox'));
    await root.create(recursive: true);
    return root.path;
  }

  Future<String?> chooseLocalCipherDirectory({
    String confirmButtonText = '选择此 SBOX 目录',
  }) async {
    if (Platform.isAndroid || Platform.isIOS) {
      return defaultLocalCipherDirectory();
    }
    return getDirectoryPath(confirmButtonText: confirmButtonText);
  }

  Future<String?> chooseRemoteMirrorParentDirectory() async {
    if (Platform.isAndroid || Platform.isIOS) {
      return defaultRemoteMirrorParent();
    }
    return getDirectoryPath(confirmButtonText: '选择密文镜像根目录');
  }

  Future<AuthorizedDirectoryMirrorResult> _refreshAuthorizedDirectoryMirror(
    SourceConfiguration config,
  ) async {
    final reference = config.directoryAuthorizationReference;
    if (reference == null) {
      throw StateError('数据源没有系统目录授权引用');
    }
    final catalog = File(p.join(config.localSyncPath, 'catalog.sbox'));
    final before = await catalog.exists() ? await sha256File(catalog) : null;
    final result = await _authorizedDirectoryGateway.mirrorCiphertext(
      reference: reference,
      destinationRoot: config.localSyncPath,
    );
    final after = await catalog.exists() ? await sha256File(catalog) : null;
    final changed = before == null
        ? after != null
        : after == null || !constantTimeBytesEqual(before, after);
    if (changed) {
      _catalog = null;
      _catalogConflicts = <CatalogConflictViewData>[];
    }
    return result;
  }

  Future<SourceCapabilities> capabilitiesFor(SourceConfiguration config) =>
      _withSource(config, (source) async => source.capabilities);

  void clearMessages() {
    _errorMessage = null;
    _statusMessage = null;
    notifyListeners();
  }

  void cancelSensitiveWork() {
    if (!isBusy || _operation == AppOperation.exporting) return;
    _cancellationRequested = true;
    CryptoTaskRunner.cancelAll();
    for (final client in List<http.Client>.of(_activeHttpClients)) {
      client.close();
    }
    unawaited(_discardIncompleteCipherStaging());
    unawaited(_discardIncompleteTemporaryJobs());
    _statusMessage = '取消已请求；正在关闭任务并清理未完成暂存，永久 SBOX 原件不会删除。';
    notifyListeners();
  }

  Future<void> _discardIncompleteCipherStaging() async {
    final roots = _sources.map((source) => source.localSyncPath).toSet();
    for (final path in roots) {
      try {
        final directory = Directory(path);
        if (!await directory.exists()) continue;
        final store = await FileSystemLocalCipherStore.open(directory);
        await store.discardIncompleteStaging();
      } on Object {
        // An open handle may briefly prevent cleanup on Windows. Startup and
        // the next explicit cancellation retry the exact staging boundary.
      }
    }
  }

  Future<void> _discardIncompleteTemporaryJobs() async {
    final root = _temporaryRoot;
    if (root == null) return;
    try {
      final store = await ManagedTemporaryPlaintextStore.open(
        root: Directory(root),
        cipherRoots: _sources.map((source) => Directory(source.localSyncPath)),
      );
      await store.discardIncompleteJobs();
    } on Object {
      // Lifecycle cancellation must remain synchronous from Flutter's point
      // of view. A failed best-effort pass is retried during next startup.
    }
  }

  Future<String?> _preparePendingCatalogBase(SourceConfiguration config) async {
    if (!config.isRemote) return null;
    if (config.hasPendingCatalog) {
      final expected = config.pendingBaseCatalogSha256;
      if (expected == null) return null;
      final base = File(_pendingBaseCatalogPath(config));
      if (!await base.exists() ||
          !constantTimeBytesEqual(
            await sha256File(base),
            decodeHex(expected),
          )) {
        throw const SboxException(
          SboxErrorCode.syncConflict,
          '待同步 Catalog 的共同基线缺失或损坏',
        );
      }
      return expected;
    }

    final catalog = File(p.join(config.localSyncPath, 'catalog.sbox'));
    if (!await catalog.exists()) {
      if (config.lastCatalogSha256 != null) {
        throw const SboxException(
          SboxErrorCode.syncConflict,
          '可信 Catalog 检查点存在，但本地密文目录缺少 catalog.sbox',
        );
      }
      return null;
    }
    final checkpointHash = config.lastCatalogSha256;
    if (checkpointHash == null) {
      throw const SboxException(
        SboxErrorCode.catalogRequired,
        '请先输入助记词验证已下载的 catalog.sbox，再添加待同步项目',
      );
    }
    final expected = decodeHex(checkpointHash);
    final actual = await sha256File(catalog);
    if (!constantTimeBytesEqual(actual, expected)) {
      throw const SboxException(
        SboxErrorCode.syncConflict,
        '本地 catalog.sbox 与可信远端检查点不一致',
      );
    }

    final base = File(_pendingBaseCatalogPathForHash(config, checkpointHash));
    await base.parent.create(recursive: true);
    if (await base.exists()) {
      if (!constantTimeBytesEqual(await sha256File(base), expected)) {
        throw const SboxException(SboxErrorCode.syncConflict, '待同步基线目录已存在不同内容');
      }
      return checkpointHash;
    }
    final temporary = File(
      '${base.path}.${hexLower(secureRandomBytes(8))}.part',
    );
    try {
      await catalog.openRead().pipe(temporary.openWrite(mode: FileMode.write));
      if (!constantTimeBytesEqual(await sha256File(temporary), expected) ||
          !constantTimeBytesEqual(await sha256File(catalog), expected)) {
        throw const SboxException(
          SboxErrorCode.syncConflict,
          '建立待同步基线时本地 Catalog 发生变化',
        );
      }
      await temporary.rename(base.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
    return checkpointHash;
  }

  Future<void> _publishPendingCatalog(
    SourceConfiguration config,
    String mnemonic,
    Map<String, Object?> publicIdentityJson, {
    required CatalogViewTaskResult? pendingView,
  }) async {
    if (pendingView == null) {
      throw StateError('Pending Catalog must be unlocked before upload');
    }
    CatalogViewTaskResult working = pendingView;
    var workingConfig = config;
    if (hexLower(working.encryptedCatalogSha256) !=
        workingConfig.pendingCatalogSha256) {
      throw const SboxException(
        SboxErrorCode.syncConflict,
        '待同步 Catalog 摘要与队列状态不一致',
      );
    }
    _operation = AppOperation.uploading;
    notifyListeners();

    await _withSource(config, (source) async {
      final localStore = await FileSystemLocalCipherStore.open(
        Directory(config.localSyncPath),
      );
      final synchronizer = CipherMirrorSynchronizer(
        source: source,
        localStore: localStore,
        onProgress: _onSyncProgress,
      );
      var expectedRevision = workingConfig.lastProviderRevision;
      var mergeAttempts = 0;

      while (true) {
        try {
          final revision = await synchronizer.publishEncryptedCatalog(
            payloads: working.catalogPayloadsJson.map(CatalogPayload.fromJson),
            encryptedCatalogSha256: working.encryptedCatalogSha256,
            expectedRemoteRevision: expectedRevision,
          );
          final completed = workingConfig.copyWith(
            catalogId: working.catalogId,
            highestGeneration: working.generation,
            lastCatalogSha256: hexLower(working.encryptedCatalogSha256),
            localCatalogMirrorSha256: hexLower(working.encryptedCatalogSha256),
            lastProviderRevision: revision,
            clearPendingCatalog: true,
            lastLocalSyncAt: DateTime.now().toUtc(),
          );
          await _replaceSource(completed);
          await _deletePendingBase(workingConfig);
          _catalog = working;
          _catalogConflicts = <CatalogConflictViewData>[];
          _statusMessage = mergeAttempts == 0
              ? '加密对象已先上传，catalog.sbox 已完成条件提交。'
              : '检测到远端并发新增，已三方合并、重新签名并完成条件提交。';
          return;
        } on SboxException catch (error) {
          if (error.code != SboxErrorCode.syncConflict) rethrow;
          mergeAttempts++;
          if (mergeAttempts > 3) {
            _catalogConflicts = <CatalogConflictViewData>[
              _genericCatalogConflict(working, '远端持续变化，已达到 3 次随机退避重试上限'),
            ];
            rethrow;
          }
          final baseHash = workingConfig.pendingBaseCatalogSha256;
          if (baseHash == null) {
            _catalogConflicts = <CatalogConflictViewData>[
              _genericCatalogConflict(
                working,
                '本地与远端分别创建了首个 Catalog，没有共同基线，禁止自动覆盖',
              ),
            ];
            rethrow;
          }

          final remoteRoot = Directory(
            p.join(
              workingConfig.localSyncPath,
              '.sbox-staging',
              'remote-merge-${hexLower(secureRandomBytes(12))}',
            ),
          );
          try {
            final remoteStore = await FileSystemLocalCipherStore.open(
              remoteRoot,
            );
            final remoteMirror = await CipherMirrorSynchronizer(
              source: source,
              localStore: remoteStore,
              onProgress: _onSyncProgress,
            ).pullEncryptedCatalog(expectedRecipientKeyId: recipientKeyId);
            final remoteCatalog = remoteMirror.localObject;
            if (remoteCatalog == null) {
              throw const SboxException(
                SboxErrorCode.syncConflict,
                '远端 Catalog 条件读取未返回最新内容',
              );
            }
            final merge =
                await CryptoTaskRunner.mergePendingCatalogAfterConflict(
                  baseCatalogPath: _pendingBaseCatalogPath(workingConfig),
                  localCatalogPath: p.join(
                    workingConfig.localSyncPath,
                    'catalog.sbox',
                  ),
                  remoteCatalogPath: remoteCatalog.file.path,
                  localCipherRoot: workingConfig.localSyncPath,
                  mnemonic: mnemonic,
                  publicIdentityJson: publicIdentityJson,
                  expectedCurrentCatalogSha256: working.encryptedCatalogSha256,
                );
            if (merge is CatalogConflictsTaskResult) {
              _catalogConflicts = merge.conflicts;
              throw const SboxException(
                SboxErrorCode.syncConflict,
                '同一 Catalog 条目发生并发修改，需要用户处理',
              );
            }
            final merged = merge as CatalogMergedTaskResult;
            working = CatalogViewTaskResult(
              catalogId: merged.catalogId,
              generation: merged.generation,
              encryptedCatalogSha256: merged.encryptedCatalogSha256,
              entries: merged.entries,
              catalogPayloadsJson: merged.catalogPayloadsJson,
              continuity: CatalogContinuity.advanced,
            );
            _catalog = working;
            final remoteBaseHash = hexLower(remoteCatalog.sha256);
            await _savePendingBaseSnapshot(
              workingConfig,
              remoteCatalog.file,
              remoteBaseHash,
            );
            final nextConfig = workingConfig.copyWith(
              pendingCatalogId: working.catalogId,
              pendingCatalogGeneration: working.generation,
              pendingCatalogSha256: hexLower(working.encryptedCatalogSha256),
              localCatalogMirrorSha256: hexLower(
                working.encryptedCatalogSha256,
              ),
              pendingBaseCatalogSha256: remoteBaseHash,
              lastProviderRevision: remoteMirror.providerRevision,
            );
            await _replaceSource(nextConfig);
            if (baseHash != remoteBaseHash) {
              await _deletePendingBaseHash(workingConfig, baseHash);
            }
            workingConfig = nextConfig;
            expectedRevision = remoteMirror.providerRevision;
            await synchronizer.pullAuthenticatedCatalogPayloads(
              working.catalogPayloadsJson.map(CatalogPayload.fromJson),
              expectedRecipientKeyId: recipientKeyId!,
            );
          } finally {
            await _deleteTemporaryRemoteMirror(workingConfig, remoteRoot);
          }
          final jitter = 50 + secureRandomBytes(1).single % 151;
          await Future<void>.delayed(Duration(milliseconds: jitter));
        }
      }
    });
  }

  CatalogConflictViewData _genericCatalogConflict(
    CatalogViewTaskResult catalog,
    String reason,
  ) {
    final entry = catalog.entries.firstOrNull;
    final payload = catalog.catalogPayloadsJson.firstOrNull;
    return CatalogConflictViewData(
      entryId: entry?.entryId ?? '00000000000000000000000000000000',
      reason: reason,
      localTitle: entry?.title ?? '本地待同步目录',
      remoteTitle: null,
      localPayloadSha256: payload?['plaintext_sha256'] as String? ?? 'unknown',
      remotePayloadSha256: null,
      localPartCount: entry?.partCount ?? 0,
      remotePartCount: null,
      baseRevision: null,
      remoteRevision: null,
    );
  }

  String _pendingBaseCatalogPath(SourceConfiguration config) {
    final hash = config.pendingBaseCatalogSha256;
    if (hash == null) {
      throw StateError('Pending Catalog has no common-baseline hash');
    }
    return _pendingBaseCatalogPathForHash(config, hash);
  }

  String _pendingBaseCatalogPathForHash(
    SourceConfiguration config,
    String hash,
  ) => p.join(config.localSyncPath, '.sbox-sync', 'pending-base-$hash.sbox');

  Future<void> _savePendingBaseSnapshot(
    SourceConfiguration config,
    File source,
    String hash,
  ) async {
    final expected = decodeHex(hash);
    final target = File(_pendingBaseCatalogPathForHash(config, hash));
    await target.parent.create(recursive: true);
    if (await target.exists()) {
      if (!constantTimeBytesEqual(await sha256File(target), expected)) {
        throw const SboxException(
          SboxErrorCode.syncConflict,
          '同一摘要的待同步基线文件内容冲突',
        );
      }
      return;
    }
    final temporary = File(
      '${target.path}.${hexLower(secureRandomBytes(8))}.part',
    );
    try {
      await source.openRead().pipe(temporary.openWrite(mode: FileMode.write));
      if (!constantTimeBytesEqual(await sha256File(temporary), expected) ||
          !constantTimeBytesEqual(await sha256File(source), expected)) {
        throw const SboxException(
          SboxErrorCode.syncConflict,
          '复制待同步共同基线时源 Catalog 发生变化',
        );
      }
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _restorePendingBase(
    SourceConfiguration config,
    File base,
    Uint8List baseHash,
    Uint8List currentHash,
  ) async {
    if (!await base.exists() ||
        !constantTimeBytesEqual(await sha256File(base), baseHash)) {
      throw const SboxException(SboxErrorCode.syncConflict, '待同步共同基线缺失或损坏');
    }
    final store = await FileSystemLocalCipherStore.open(
      Directory(config.localSyncPath),
    );
    final staged = await store.createStaging(SourcePath('catalog.sbox'));
    try {
      final sink = staged.openSink();
      await sink.addStream(base.openRead());
      await sink.flush();
      await sink.close();
      await store.replaceDownloadedCatalog(
        staged,
        expectedLength: await base.length(),
        expectedSha256: baseHash,
        expectedCurrentSha256: currentHash,
      );
    } on Object {
      await staged.discard();
      rethrow;
    }
  }

  Future<void> _deleteCatalogIfHashMatches(
    SourceConfiguration config,
    Uint8List expectedHash,
  ) async {
    final catalog = File(p.join(config.localSyncPath, 'catalog.sbox'));
    if (!await catalog.exists() ||
        !constantTimeBytesEqual(await sha256File(catalog), expectedHash)) {
      throw const SboxException(
        SboxErrorCode.syncConflict,
        '本地 Catalog 已变化，拒绝删除待同步版本',
      );
    }
    await catalog.delete();
  }

  Future<void> _deletePendingBase(SourceConfiguration config) async {
    final hash = config.pendingBaseCatalogSha256;
    if (hash == null) return;
    await _deletePendingBaseHash(config, hash);
  }

  Future<void> _deletePendingBaseHash(
    SourceConfiguration config,
    String hash,
  ) async {
    final base = File(_pendingBaseCatalogPathForHash(config, hash));
    if (await base.exists()) {
      if (!constantTimeBytesEqual(await sha256File(base), decodeHex(hash))) {
        throw const SboxException(
          SboxErrorCode.syncConflict,
          '待同步共同基线摘要与文件名不一致',
        );
      }
      await base.delete();
    }
    final directory = base.parent;
    if (await directory.exists() &&
        await directory.list(followLinks: false).isEmpty) {
      await directory.delete();
    }
  }

  Future<void> _deleteTemporaryRemoteMirror(
    SourceConfiguration config,
    Directory remoteRoot,
  ) async {
    final stagingRoot = p.normalize(
      p.absolute(p.join(config.localSyncPath, '.sbox-staging')),
    );
    final target = p.normalize(p.absolute(remoteRoot.path));
    if (!p.isWithin(stagingRoot, target) ||
        !RegExp(r'^remote-(merge|resolve)-[0-9a-f]{24}$')
            .hasMatch(p.basename(target))) {
      throw const SboxException(SboxErrorCode.storageOverlap, '临时远端镜像清理路径越界');
    }
    await _deleteAppTreeNoFollow(remoteRoot.path);
  }

  Future<void> _scanLoose(SourceConfiguration config) async {
    final result = await LocalSboxScanner.scan(Directory(config.localSyncPath));
    _looseCandidates = result.candidates;
  }

  Future<void> _replaceSource(SourceConfiguration replacement) async {
    _sources = _sources
        .map(
          (source) =>
              source.sourceId == replacement.sourceId ? replacement : source,
        )
        .toList(growable: false);
    await _sourceStore.saveAll(_sources);
  }

  Future<T> _withSource<T>(
    SourceConfiguration config,
    Future<T> Function(DataSource source) action,
  ) async {
    http.Client? client;
    late final DataSource source;
    if (config.provider == SourceProvider.local) {
      source = await LocalDirectoryDataSource.attach(
        root: Directory(config.localSyncPath),
        mode: config.localDirectoryMode == ConfiguredLocalMode.canonicalCatalog
            ? LocalDirectoryMode.canonicalCatalog
            : LocalDirectoryMode.looseReadOnly,
        requestWrite: config.isWritable,
      );
    } else {
      client = http.Client();
      _activeHttpClients.add(client);
      source = switch (config.provider) {
        SourceProvider.github => GitHubDataSource(
          config: config.repositoryConfig,
          client: client,
          credentialStore: config.credentialReference == null
              ? null
              : _credentialStore,
          credentialId: config.credentialReference,
        ),
        SourceProvider.gitee => GiteeDataSource(
          config: config.repositoryConfig,
          client: client,
          credentialStore: config.credentialReference == null
              ? null
              : _credentialStore,
          credentialId: config.credentialReference,
        ),
        SourceProvider.https => HttpsReadOnlyDataSource(
          config: config.httpsBaseUri == null
              ? throw StateError('HTTPS source URL missing')
              : HttpsSourceConfig(baseUri: config.httpsBaseUri!),
          client: client,
        ),
        SourceProvider.local => throw StateError('Unreachable'),
      };
    }
    try {
      return await action(source);
    } finally {
      if (client != null) _activeHttpClients.remove(client);
      client?.close();
    }
  }

  SourceConfiguration _requireSource() =>
      selectedSource ?? (throw StateError('请先配置或打开一个本地 SBOX 目录'));

  PublicIdentityRecord _requireIdentity() =>
      _identity ?? (throw StateError('请先创建或恢复身份'));

  Future<void> _run(
    AppOperation operation,
    Future<void> Function() action,
  ) async {
    if (isBusy) throw StateError('已有任务正在运行');
    _operation = operation;
    _cancellationRequested = false;
    _syncProgress = null;
    _errorMessage = null;
    notifyListeners();
    try {
      await action();
    } catch (error) {
      _errorMessage = _cancellationRequested
          ? '操作已取消；未完成暂存已清理，永久 SBOX 原件保持不变。'
          : _friendlyError(error);
      rethrow;
    } finally {
      _operation = AppOperation.idle;
      _cancellationRequested = false;
      notifyListeners();
    }
  }

  void _onSyncProgress(CipherSyncProgress progress) {
    _syncProgress = progress;
    notifyListeners();
  }

  static Future<bool> _isEffectivelyEmpty(Directory directory) async {
    await for (final entity in directory.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name != '.sbox-staging') {
        return false;
      }
    }
    return true;
  }

  static bool _sameFileSystemPath(String left, String right) =>
      Platform.isWindows
      ? left.toLowerCase() == right.toLowerCase()
      : left == right;

  static String _continuityText(CatalogContinuity continuity) =>
      switch (continuity) {
        CatalogContinuity.firstTrusted => '目录签名已验证；这是此设备首次信任的 Catalog。',
        CatalogContinuity.unchanged => '目录签名与哈希已验证；Catalog 未变化。',
        CatalogContinuity.advanced => '目录签名与历史链已验证。',
        CatalogContinuity.historyGap => '目录签名有效，但历史链不连续；请人工核对检查点。',
      };

  static String _friendlyError(Object error) {
    if (error is SboxException) {
      return switch (error.code) {
        SboxErrorCode.invalidMnemonic => '助记词必须是校验有效的 12 个 BIP39 英文单词。',
        SboxErrorCode.keyMismatch ||
        SboxErrorCode.identityDerivation => '助记词与当前身份或此密文不匹配。',
        SboxErrorCode.authentication ||
        SboxErrorCode.integrity => '密钥不匹配、文件损坏或认证失败；未发布明文。',
        SboxErrorCode.catalogSignature => '目录签名无效，目录内容未展示。',
        SboxErrorCode.catalogRollback => '检测到目录回滚，已停止同步。',
        SboxErrorCode.catalogFork ||
        SboxErrorCode.syncConflict => '目录发生并发分叉，需要刷新后处理冲突。',
        SboxErrorCode.multipartMissing => '加密分片不完整，请继续同步。',
        SboxErrorCode.catalogRequired => '这是大文件分片，需要对应的 catalog.sbox。',
        SboxErrorCode.storageOverlap => '本地密文目录与临时明文目录不能相同或互相包含。',
        SboxErrorCode.sourceAuthentication => '数据源写入授权缺失、过期或权限不足。',
        SboxErrorCode.sourceNetwork => '无法连接或访问数据源，请检查网络或目录授权。',
        SboxErrorCode.sourceRateLimit => '数据源正在限流，请稍后重试。',
        SboxErrorCode.sourceLimit ||
        SboxErrorCode.tooManyParts => '文件或分片超过当前数据源能力限制。',
        SboxErrorCode.cancelled => '操作已取消，未完成暂存已清理。',
        _ => '${error.code.value}：操作失败且已安全停止。',
      };
    }
    if (error is FileSystemException) {
      return '本地文件访问失败，请检查目录授权和可用空间。';
    }
    if (error is FormatException || error is ArgumentError) {
      return '输入或文件格式无效，请检查后重试。';
    }
    return '操作未完成；未认证明文和未提交目录均不会发布。';
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}

Future<void> _deleteAppTreeNoFollow(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  switch (type) {
    case FileSystemEntityType.notFound:
      return;
    case FileSystemEntityType.file:
      await File(path).delete();
    case FileSystemEntityType.link:
      await Link(path).delete();
    case FileSystemEntityType.directory:
      await for (final child in Directory(path).list(followLinks: false)) {
        await _deleteAppTreeNoFollow(child.path);
      }
      await Directory(path).delete();
    default:
      throw const SboxException(
        SboxErrorCode.storageOverlap,
        '临时远端镜像包含不支持的文件系统对象',
      );
  }
}
