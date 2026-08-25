import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../platform/runtime_environment.dart';
import '../../platform/web_runtime_limits.dart';
import '../bytes.dart';
import '../constants.dart';
import '../engine/background_bundle_crypto.dart';
import '../engine/bundle_encryptor.dart';
import '../engine/bundle_planner.dart';
import '../engine/bundle_probe.dart';
import '../errors.dart';
import '../format/bundle_header.dart';
import '../format/bundle_path.dart';
import '../format/metadata_block.dart';
import '../format/sbox_version.dart';
import '../../platform/preview_generation_result.dart';
import '../logging.dart';
import 'cloud_backup_config.dart';
import 'credential.dart';
import 'data_source.dart';
import 'gitee_source.dart';
import 'github_source.dart';
import 'source_path.dart';

enum CloudBundleUploadStage {
  preparing,
  splitting,
  encrypting,
  uploading,
  verifying,
  completed,
}

/// Signals that the current upload should stop at the next safe boundary.
///
/// The UI also closes the upload's HTTP client so an in-flight request is
/// interrupted immediately. The checks in the uploader cover the local
/// preparation, retry and verification phases where there may not be an
/// active HTTP request to close.
final class CloudBundleUploadCancellation {
  bool _cancelled = false;
  final Set<void Function()> _listeners = <void Function()>{};

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      try {
        listener();
      } on Object {
        // A cancellation listener must not prevent the other cleanup hooks.
      }
    }
  }

  /// Registers a cleanup hook and returns a function that removes it.
  ///
  /// This lets the uploader close its HTTP client even when callers cancel
  /// the token directly instead of going through the page action.
  void Function() registerOnCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    var registered = true;
    return () {
      if (!registered) return;
      registered = false;
      _listeners.remove(listener);
    };
  }

  void throwIfCancelled() {
    if (_cancelled) {
      throw const SboxException(SboxErrorCode.cancelled, '上传已取消');
    }
  }
}

final class CloudBundleSourceProgress {
  const CloudBundleSourceProgress({
    required this.sourceName,
    required this.completedShards,
    required this.totalShards,
  });

  final String sourceName;
  final int completedShards;
  final int totalShards;

  double get fraction => totalShards == 0
      ? 0
      : (completedShards / totalShards).clamp(0, 1).toDouble();

  String get ratioLabel => '$completedShards/$totalShards';
}

final class CloudBundleUploadProgress {
  const CloudBundleUploadProgress({
    required this.stage,
    required this.sources,
    this.currentSource,
    this.currentShardIndex,
    this.attempt = 1,
    this.processedBytes = 0,
    this.totalBytes = 0,
    this.processedShards = 0,
    this.processingTotalShards = 0,
    this.currentShardBytes = 0,
    this.currentShardLength = 0,
  });

  final CloudBundleUploadStage stage;
  final Map<String, CloudBundleSourceProgress> sources;
  final String? currentSource;
  final int? currentShardIndex;
  final int attempt;
  final int processedBytes;
  final int totalBytes;
  final int processedShards;
  final int processingTotalShards;
  final int currentShardBytes;
  final int currentShardLength;

  bool get isComplete => stage == CloudBundleUploadStage.completed;

  int get completedShards =>
      sources.values.fold(0, (total, source) => total + source.completedShards);

  int get totalShards =>
      sources.values.fold(0, (total, source) => total + source.totalShards);

  double get fraction {
    if (stage == CloudBundleUploadStage.splitting ||
        stage == CloudBundleUploadStage.encrypting) {
      if (totalBytes <= 0) {
        return processingTotalShards > 0 &&
                processedShards >= processingTotalShards
            ? 1
            : 0;
      }
      return (processedBytes / totalBytes).clamp(0, 1).toDouble();
    }
    if (totalShards == 0) return 0;
    final value = (completedShards / totalShards).clamp(0, 1).toDouble();
    // The last shard can be written before the verification pass and the
    // final local inspection. Keep the visual progress just below complete
    // until the explicit terminal event is emitted.
    if (!isComplete && value >= 1) return 0.99;
    return value;
  }

  String get overallLabel {
    if (stage == CloudBundleUploadStage.splitting ||
        stage == CloudBundleUploadStage.encrypting) {
      const action = '切分&加密文件';
      final shardLabel = processingTotalShards > 0
          ? ' · $processedShards/$processingTotalShards 个分片'
          : '';
      return '$action ${(fraction * 100).toStringAsFixed(1)}%$shardLabel';
    }
    if (!isComplete && totalShards > 0 && completedShards >= totalShards) {
      return '$completedShards/$totalShards（正在核对）';
    }
    return '$completedShards/$totalShards (${(fraction * 100).toStringAsFixed(1)}%)';
  }

  String get sourceLabel => sources.values
      .map((source) => '${source.sourceName} ${source.ratioLabel}')
      .join(' · ');

  String get detailLabel {
    if (stage == CloudBundleUploadStage.splitting ||
        stage == CloudBundleUploadStage.encrypting) {
      const action = '正在切分&加密文件';
      final bytes = totalBytes <= 0
          ? null
          : '$action ${_formatBytes(processedBytes)} / ${_formatBytes(totalBytes)}';
      final shard = currentShardIndex == null || processingTotalShards <= 0
          ? null
          : '分片 ${currentShardIndex! + 1}/$processingTotalShards';
      final currentBytes = currentShardLength <= 0
          ? null
          : '当前 ${_formatBytes(currentShardBytes)} / ${_formatBytes(currentShardLength)}';
      return <String>[action, ?bytes, ?shard, ?currentBytes].join(' · ');
    }
    final current = currentSource == null || currentShardIndex == null
        ? null
        : '$currentSource 分片 ${currentShardIndex! + 1}';
    final retry = attempt > 1 ? '，第 $attempt 次尝试' : '';
    return [
      '整体 $overallLabel',
      sourceLabel,
      if (current != null) '$current$retry',
    ].join(' · ');
  }
}

final class CloudBundleUploadResult {
  const CloudBundleUploadResult({
    required this.bundleId,
    required this.objectNames,
    required this.duplicate,
    required this.uploadedSources,
    required this.previewRequested,
    required this.previewEmbedded,
    required this.previewUnavailableReason,
  }) : assert(
         previewEmbedded
             ? previewUnavailableReason == null
             : previewUnavailableReason != null,
       );

  final String bundleId;
  final List<String> objectNames;
  final bool duplicate;
  final List<String> uploadedSources;
  final bool previewRequested;
  final bool previewEmbedded;
  final PreviewUnavailableReason? previewUnavailableReason;

  String get rootObjectName => objectNames.firstWhere(
    (name) => parseCanonicalBundleBasename(name).shardIndex == 0,
  );
}

/// Hashes, de-duplicates, encrypts and publishes one file through both
/// repository APIs. CPU-heavy work is delegated to background isolates.
///
/// Release assets are published with bounded per-provider parallelism. Bundle
/// continuation assets are independent; the root asset remains the final
/// publication marker so a resumed upload never exposes a new Bundle before
/// all of its continuation assets are available.
final class CloudBundleUploader {
  CloudBundleUploader({
    required this._credentialStore,
    required this._client,
    BundleEncryptor? encryptor,
    this._logger,
    this.maxShardUploadRetries = 3,
    this.retryBaseDelay = const Duration(milliseconds: 300),
    // ignore: prefer_initializing_formals
  }) : _encryptor = encryptor {
    if (maxShardUploadRetries < 0) {
      throw ArgumentError.value(maxShardUploadRetries, 'maxShardUploadRetries');
    }
    if (retryBaseDelay.isNegative) {
      throw ArgumentError.value(retryBaseDelay, 'retryBaseDelay');
    }
  }

  static const int _giteeObjectLimit = 20 * 1024 * 1024;
  static const Duration _remoteListingTimeout = Duration(seconds: 45);
  static const Duration _maximumProviderRetryDelay = Duration(hours: 1);

  final CredentialStore _credentialStore;
  final http.Client _client;
  final BundleEncryptor? _encryptor;
  final SboxLogger? _logger;
  final int maxShardUploadRetries;
  final Duration retryBaseDelay;

  Future<CloudBundleUploadResult> upload({
    required BundleInput input,
    required int declaredLength,
    required BundleEncryptionOptions options,
    required CloudBackupConfiguration configuration,
    void Function(CloudBundleUploadProgress progress)? onProgress,
    CloudBundleUploadCancellation? cancellation,
  }) async {
    if (isWebRuntime) {
      return _uploadInMemory(
        input: input,
        declaredLength: declaredLength,
        options: options,
        configuration: configuration,
        onProgress: onProgress,
        cancellation: cancellation,
      );
    }
    final signal = cancellation ?? CloudBundleUploadCancellation();
    final unregisterCancellation = signal.registerOnCancel(_client.close);
    Uint8List? md5;
    try {
      signal.throwIfCancelled();
      final effectiveOptions = _withSharedObjectLimit(options);
      md5 = _encryptor == null && BackgroundBundleCrypto.supportsInput(input)
          ? await BackgroundBundleCrypto.md5ForInput(
              input: input,
              declaredLength: declaredLength,
              validateUtf8: options.contentKind == SboxContentKind.text,
            )
          : await (_encryptor ?? BundleEncryptor()).md5ForInput(
              input: input,
              declaredLength: declaredLength,
              validateUtf8: options.contentKind == SboxContentKind.text,
            );
      signal.throwIfCancelled();
      final bundleId = hexLower(md5);
      final plan = BundlePlanner.plan(
        logicalLength: declaredLength,
        targetNominalShardPlaintextSize:
            effectiveOptions.targetNominalShardPlaintextSize,
        maxObjectBytes: effectiveOptions.maxObjectBytes,
      );
      final objectNames = <String>[
        for (final shard in plan.shards)
          canonicalBundleBasename(
            bundleId: md5,
            shardIndex: shard.index,
            shardCount: plan.shardCount,
          ),
      ];
      final expected = objectNames.toSet();
      final sources = <_CloudUploadSource>[
        if (configuration.github.enabled)
          _CloudUploadSource(
            name: 'GitHub',
            source: GitHubDataSource(
              config: configuration.github.repositoryConfig,
              client: _client,
              credentialStore: _credentialStore,
              credentialId: configuration.github.credentialId,
              logger: _logger,
            ),
          ),
        if (configuration.gitee.enabled)
          _CloudUploadSource(
            name: 'Gitee',
            source: GiteeDataSource(
              config: configuration.gitee.repositoryConfig,
              client: _client,
              credentialStore: _credentialStore,
              credentialId: configuration.gitee.credentialId,
              logger: _logger,
            ),
          ),
      ];
      if (sources.isEmpty) {
        throw const SboxException(
          SboxErrorCode.sourceAuthentication,
          '至少启用一个云端仓库后才能上传',
        );
      }
      final progress = _UploadProgressReporter(
        totalShards: plan.shardCount,
        totalBytes: declaredLength,
        sourceNames: sources.map((source) => source.name),
        onProgress: onProgress,
      )..emit(stage: CloudBundleUploadStage.preparing);

      final remoteObjects = <String, Set<String>>{};
      await Future.wait<void>(
        sources.map((configured) async {
          remoteObjects[configured.name] = await _remoteObjects(
            configured.source,
            expected,
            sourceName: configured.name,
            cancellation: signal,
          );
        }),
      );
      final first = sources.first;
      final firstObjects = remoteObjects[first.name]!;
      for (final configured in sources.skip(1)) {
        await _assertRemoteSourcesAgree(
          first.source,
          configured.source,
          firstObjects.intersection(remoteObjects[configured.name]!),
          cancellation: signal,
        );
      }
      final remoteComplete = <String, bool>{
        for (final configured in sources)
          configured.name:
              remoteObjects[configured.name]!.length == expected.length,
      };
      for (final configured in sources) {
        progress.setCompleted(
          configured.name,
          remoteObjects[configured.name]!.length,
        );
      }
      progress.emit(stage: CloudBundleUploadStage.preparing);

      final root = Directory(configuration.backupDirectory);
      var localObjects = await _localObjects(
        root,
        expected,
        cancellation: signal,
      );
      var localComplete = localObjects.length == expected.length;
      for (final configured in sources) {
        await _assertRemoteMatchesLocal(
          source: configured.source,
          root: root,
          names: remoteObjects[configured.name]!.intersection(localObjects),
          cancellation: signal,
        );
      }

      _CloudUploadSource? mirror;
      for (final configured in sources) {
        if (remoteComplete[configured.name] == true) {
          mirror = configured;
          break;
        }
      }
      if (!localComplete && mirror != null) {
        await _restoreLocalCopy(
          source: mirror.source,
          root: root,
          objectNames: objectNames,
          existing: localObjects,
          cancellation: signal,
        );
        localObjects = await _localObjects(
          root,
          expected,
          cancellation: signal,
        );
        localComplete = localObjects.length == expected.length;
      }

      var created = false;
      if (!localComplete) {
        // A remote partial Bundle is resumable when the local encryption can
        // reproduce its existing objects.  Do not reject it before preparing
        // the local objects: _publishDirectory already excludes objects that
        // are present remotely and can continue with the missing shards.
        if (_encryptor == null && BackgroundBundleCrypto.supportsInput(input)) {
          await BackgroundBundleCrypto.encryptToDirectory(
            input: input,
            declaredLength: declaredLength,
            options: effectiveOptions,
            root: root,
            onProgress: progress.updateEncryption,
          );
        } else {
          await (_encryptor ?? BundleEncryptor()).encryptToDirectory(
            input: input,
            declaredLength: declaredLength,
            options: effectiveOptions,
            root: root,
            onProgress: progress.updateEncryption,
          );
        }
        signal.throwIfCancelled();
        localObjects = await _localObjects(
          root,
          expected,
          cancellation: signal,
        );
        localComplete = localObjects.length == expected.length;
        created = true;
      }
      if (!localComplete) {
        throw const SboxException(
          SboxErrorCode.storageOverlap,
          'The local encrypted Bundle is incomplete',
        );
      }

      // If encryption had to be recreated, validate the remote partial
      // objects before treating their names as completed.  The Bundle ID is
      // the plaintext MD5, while encrypted bytes also contain fresh random
      // material; same-name objects with different bytes must never be mixed
      // into one Bundle.
      if (created) {
        for (final configured in sources) {
          await _assertRemoteMatchesLocal(
            source: configured.source,
            root: root,
            names: remoteObjects[configured.name]!.intersection(localObjects),
            cancellation: signal,
          );
        }
      }

      progress.emit(stage: CloudBundleUploadStage.uploading);
      final uploadTasks = <Future<void>>[];
      final uploadedSources = <String>[];
      for (final configured in sources) {
        if (remoteComplete[configured.name] == true) continue;
        uploadedSources.add(configured.name);
        uploadTasks.add(
          _publishDirectory(
            source: configured.source,
            root: root,
            objectNames: objectNames,
            existing: remoteObjects[configured.name]!,
            sourceName: configured.name,
            progress: progress,
            cancellation: signal,
          ),
        );
      }
      await Future.wait(uploadTasks);

      // _publishDirectory already performs a post-upload directory check for
      // every source it changed. Sources that were already complete were
      // checked by the initial listing. Running _verifyPublishedObjects here
      // repeated the same directory scan and, for Gitee, could trigger a
      // size lookup for every shard a second time while the UI stayed at
      // 100% with a "verifying" label.
      progress.emit(stage: CloudBundleUploadStage.verifying);
      final previewOutcome = await _readPreviewOutcome(
        root: root,
        rootObjectName: objectNames.firstWhere(
          (name) => parseCanonicalBundleBasename(name).shardIndex == 0,
        ),
        options: effectiveOptions,
        reused: !created,
        cancellation: signal,
      );
      // This is the terminal event. It must be emitted only after remote
      // verification and local metadata inspection have both completed;
      // publishing the final shard is not the same as finishing the upload.
      progress.emit(stage: CloudBundleUploadStage.completed);
      return CloudBundleUploadResult(
        bundleId: bundleId,
        objectNames: List.unmodifiable(objectNames),
        duplicate: !created,
        uploadedSources: List.unmodifiable(uploadedSources),
        previewRequested: effectiveOptions.wantsPreview,
        previewEmbedded: previewOutcome.embedded,
        previewUnavailableReason: previewOutcome.reason,
      );
    } on Object {
      if (signal.isCancelled) {
        throw const SboxException(SboxErrorCode.cancelled, '上传已取消');
      }
      rethrow;
    } finally {
      unregisterCancellation();
      final digest = md5;
      digest?.fillRange(0, digest.length, 0);
    }
  }

  Future<CloudBundleUploadResult> _uploadInMemory({
    required BundleInput input,
    required int declaredLength,
    required BundleEncryptionOptions options,
    required CloudBackupConfiguration configuration,
    void Function(CloudBundleUploadProgress progress)? onProgress,
    CloudBundleUploadCancellation? cancellation,
  }) async {
    if (declaredLength > WebRuntimeLimits.maxFileBytes) {
      throw SboxException(
        SboxErrorCode.sourceLimit,
        'Web 版单文件上限为 ${WebRuntimeLimits.maxFileMiB} MiB',
      );
    }

    final signal = cancellation ?? CloudBundleUploadCancellation();
    final unregisterCancellation = signal.registerOnCancel(_client.close);
    Uint8List? md5;
    EncryptedBundle? encrypted;
    final memoryObjects = <String, Uint8List>{};
    try {
      signal.throwIfCancelled();
      final effectiveOptions = _withSharedObjectLimit(options);
      final encryptor = _encryptor ?? BundleEncryptor();
      md5 = await encryptor.md5ForInput(
        input: input,
        declaredLength: declaredLength,
        validateUtf8: options.contentKind == SboxContentKind.text,
      );
      signal.throwIfCancelled();
      final bundleId = hexLower(md5);
      final plan = BundlePlanner.plan(
        logicalLength: declaredLength,
        targetNominalShardPlaintextSize:
            effectiveOptions.targetNominalShardPlaintextSize,
        maxObjectBytes: effectiveOptions.maxObjectBytes,
      );
      final objectNames = <String>[
        for (final shard in plan.shards)
          canonicalBundleBasename(
            bundleId: md5,
            shardIndex: shard.index,
            shardCount: plan.shardCount,
          ),
      ];
      final expected = objectNames.toSet();
      final sources = <_CloudUploadSource>[
        if (configuration.github.enabled)
          _CloudUploadSource(
            name: 'GitHub',
            source: GitHubDataSource(
              config: configuration.github.repositoryConfig,
              client: _client,
              credentialStore: _credentialStore,
              credentialId: configuration.github.credentialId,
              logger: _logger,
            ),
          ),
        if (configuration.gitee.enabled)
          _CloudUploadSource(
            name: 'Gitee',
            source: GiteeDataSource(
              config: configuration.gitee.repositoryConfig,
              client: _client,
              credentialStore: _credentialStore,
              credentialId: configuration.gitee.credentialId,
              logger: _logger,
            ),
          ),
      ];
      if (sources.isEmpty) {
        throw const SboxException(
          SboxErrorCode.sourceAuthentication,
          '至少启用一个云端仓库后才能上传',
        );
      }

      final progress = _UploadProgressReporter(
        totalShards: plan.shardCount,
        totalBytes: declaredLength,
        sourceNames: sources.map((source) => source.name),
        onProgress: onProgress,
      )..emit(stage: CloudBundleUploadStage.preparing);
      final remoteObjects = <String, Set<String>>{};
      await Future.wait<void>(
        sources.map((configured) async {
          remoteObjects[configured.name] = await _remoteObjects(
            configured.source,
            expected,
            sourceName: configured.name,
            cancellation: signal,
          );
        }),
      );
      final first = sources.first;
      final firstObjects = remoteObjects[first.name]!;
      for (final configured in sources.skip(1)) {
        await _assertRemoteSourcesAgree(
          first.source,
          configured.source,
          firstObjects.intersection(remoteObjects[configured.name]!),
          cancellation: signal,
        );
      }
      final remoteComplete = <String, bool>{
        for (final configured in sources)
          configured.name:
              remoteObjects[configured.name]!.length == expected.length,
      };
      for (final configured in sources) {
        progress.setCompleted(
          configured.name,
          remoteObjects[configured.name]!.length,
        );
      }
      progress.emit(stage: CloudBundleUploadStage.preparing);

      _CloudUploadSource? mirror;
      for (final configured in sources) {
        if (remoteComplete[configured.name] == true) {
          mirror = configured;
          break;
        }
      }
      final allComplete = remoteComplete.values.every((value) => value);
      final rootObjectName = objectNames.firstWhere(
        (name) => parseCanonicalBundleBasename(name).shardIndex == 0,
      );
      if (mirror != null && allComplete) {
        final rootRead = await mirror.source.get(SourcePath(rootObjectName));
        final rootBytes = await _readSourceBytes(
          rootRead,
          cancellation: signal,
          maximumBytes: effectiveOptions.maxObjectBytes!,
        );
        try {
          progress.emit(stage: CloudBundleUploadStage.verifying);
          final previewOutcome = await _readPreviewOutcomeBytes(
            rootBytes: rootBytes,
            rootObjectName: rootObjectName,
            options: effectiveOptions,
            reused: true,
            cancellation: signal,
          );
          progress.emit(stage: CloudBundleUploadStage.completed);
          return CloudBundleUploadResult(
            bundleId: bundleId,
            objectNames: List.unmodifiable(objectNames),
            duplicate: true,
            uploadedSources: const <String>[],
            previewRequested: effectiveOptions.wantsPreview,
            previewEmbedded: previewOutcome.embedded,
            previewUnavailableReason: previewOutcome.reason,
          );
        } finally {
          rootBytes.fillRange(0, rootBytes.length, 0);
        }
      }

      var created = false;
      if (mirror != null) {
        // A complete provider is the immutable source of truth when repairing
        // another provider. Read one object at a time to keep peak tab memory
        // bounded by the Bundle plus one network chunk.
        var retainedCiphertextBytes = 0;
        for (final name in objectNames) {
          signal.throwIfCancelled();
          final read = await mirror.source.get(SourcePath(name));
          if (read.length < 0 ||
              read.length >
                  WebRuntimeLimits.maxCiphertextBytes -
                      retainedCiphertextBytes) {
            throw const SboxException(
              SboxErrorCode.sourceLimit,
              '远端 Bundle 超过浏览器内存下载上限',
            );
          }
          final bytes = await _readSourceBytes(
            read,
            cancellation: signal,
            maximumBytes: effectiveOptions.maxObjectBytes!,
          );
          retainedCiphertextBytes += bytes.length;
          memoryObjects[name] = bytes;
        }
      } else {
        final hasPartial = remoteObjects.values.any(
          (items) => items.isNotEmpty,
        );
        if (hasPartial) {
          throw const SboxException(
            SboxErrorCode.immutableConflict,
            'Web 版没有可复用的本地密文，无法安全续传残缺 Bundle；请先删除远端残片后重试',
          );
        }
        encrypted = await encryptor.encrypt(
          input: input,
          declaredLength: declaredLength,
          options: effectiveOptions,
          onProgress: progress.updateEncryption,
        );
        var retainedCiphertextBytes = 0;
        for (final object in encrypted.objects) {
          if (object.bytes.length >
              WebRuntimeLimits.maxCiphertextBytes - retainedCiphertextBytes) {
            throw const SboxException(
              SboxErrorCode.sourceLimit,
              '加密 Bundle 超过浏览器内存上限',
            );
          }
          retainedCiphertextBytes += object.bytes.length;
          memoryObjects[object.basename] = object.bytes;
        }
        if (memoryObjects.keys.toSet().length != expected.length ||
            !memoryObjects.keys.toSet().containsAll(expected)) {
          throw const SboxException(SboxErrorCode.shardMissing, '内存加密结果缺少预期分片');
        }
        created = true;
      }

      progress.emit(stage: CloudBundleUploadStage.uploading);
      final uploadedSources = <String>[];
      final uploadTasks = <Future<void>>[];
      for (final configured in sources) {
        if (remoteComplete[configured.name] == true) continue;
        uploadedSources.add(configured.name);
        uploadTasks.add(
          _publishMemory(
            source: configured.source,
            objects: memoryObjects,
            objectNames: objectNames,
            existing: remoteObjects[configured.name]!,
            sourceName: configured.name,
            progress: progress,
            cancellation: signal,
          ),
        );
      }
      await Future.wait(uploadTasks);
      progress.emit(stage: CloudBundleUploadStage.verifying);
      final previewOutcome = await _readPreviewOutcomeBytes(
        rootBytes: memoryObjects[rootObjectName]!,
        rootObjectName: rootObjectName,
        options: effectiveOptions,
        reused: !created,
        cancellation: signal,
      );
      progress.emit(stage: CloudBundleUploadStage.completed);
      return CloudBundleUploadResult(
        bundleId: bundleId,
        objectNames: List.unmodifiable(objectNames),
        duplicate: !created,
        uploadedSources: List.unmodifiable(uploadedSources),
        previewRequested: effectiveOptions.wantsPreview,
        previewEmbedded: previewOutcome.embedded,
        previewUnavailableReason: previewOutcome.reason,
      );
    } on Object {
      if (signal.isCancelled) {
        throw const SboxException(SboxErrorCode.cancelled, '上传已取消');
      }
      rethrow;
    } finally {
      unregisterCancellation();
      md5?.fillRange(0, md5.length, 0);
      for (final bytes in memoryObjects.values) {
        bytes.fillRange(0, bytes.length, 0);
      }
      final result = encrypted;
      if (result != null) {
        result.plaintextSha256.fillRange(0, result.plaintextSha256.length, 0);
        for (final object in result.objects) {
          object.bytes.fillRange(0, object.bytes.length, 0);
          object.sha256.fillRange(0, object.sha256.length, 0);
        }
        result.preview?.dispose();
      }
    }
  }

  Future<Uint8List> _readSourceBytes(
    SourceRead read, {
    required CloudBundleUploadCancellation cancellation,
    required int maximumBytes,
  }) async {
    if (read.notModified ||
        read.length < 0 ||
        read.length > maximumBytes) {
      throw const SboxException(
        SboxErrorCode.sourceLimit,
        '远端对象超过浏览器内存上限',
      );
    }
    final output = BytesBuilder(copy: false);
    var count = 0;
    try {
      await for (final chunk in read.body) {
        cancellation.throwIfCancelled();
        count += chunk.length;
        if (count > read.length || count > maximumBytes) {
          throw const SboxException(
            SboxErrorCode.remoteChanged,
            '远端对象超过声明长度',
          );
        }
        output.add(chunk);
      }
      if (count != read.length) {
        throw const SboxException(SboxErrorCode.remoteChanged, '远端对象长度不一致');
      }
      return output.takeBytes();
    } catch (_) {
      final partial = output.takeBytes();
      partial.fillRange(0, partial.length, 0);
      rethrow;
    }
  }

  Future<_PreviewOutcome> _readPreviewOutcomeBytes({
    required Uint8List rootBytes,
    required String rootObjectName,
    required BundleEncryptionOptions options,
    required bool reused,
    required CloudBundleUploadCancellation cancellation,
  }) async {
    cancellation.throwIfCancelled();
    final header = BundleHeader.parse(rootBytes);
    validateBundlePathAgainstHeader(rootObjectName, header);
    if (header.version == SboxVersion.v30) {
      return const _PreviewOutcome(
        embedded: false,
        reason: PreviewUnavailableReason.existingV30,
      );
    }
    final result = await BundleProbe.readMetadata(
      basename: rootObjectName,
      objectPrefix: rootBytes,
      identity: options.recipient,
    );
    try {
      cancellation.throwIfCancelled();
      if (result.preview != null) {
        return const _PreviewOutcome(embedded: true);
      }
      if (reused) {
        return const _PreviewOutcome(
          embedded: false,
          reason: PreviewUnavailableReason.existingV31WithoutPreview,
        );
      }
      if (options.preview != null) {
        final manifestBytes = result.manifest!.encode();
        try {
          if (options.preview!.encodedLength >
              MetadataBlockCodec.previewCapacity(manifestBytes.length)) {
            return const _PreviewOutcome(
              embedded: false,
              reason: PreviewUnavailableReason.metadataCapacity,
            );
          }
        } finally {
          manifestBytes.fillRange(0, manifestBytes.length, 0);
        }
      }
      return _PreviewOutcome(
        embedded: false,
        reason:
            options.previewUnavailableReason ??
            (options.wantsPreview
                ? PreviewUnavailableReason.encodeFailed
                : PreviewUnavailableReason.userDisabled),
      );
    } finally {
      result.preview?.dispose();
    }
  }

  Future<void> _assertRemoteSourcesAgree(
    EnumerableDataSource left,
    EnumerableDataSource right,
    Iterable<String> names, {
    required CloudBundleUploadCancellation cancellation,
  }) async {
    final maxParallel =
        left.capabilities.maxParallelTransfers <
            right.capabilities.maxParallelTransfers
        ? left.capabilities.maxParallelTransfers
        : right.capabilities.maxParallelTransfers;
    await _parallelForEach(
      names,
      maxParallel: maxParallel,
      action: (name) async {
        cancellation.throwIfCancelled();
        final reads = await Future.wait<SourceRead>(<Future<SourceRead>>[
          left.get(SourcePath(name)),
          right.get(SourcePath(name)),
        ]);
        final leftRead = reads[0];
        final rightRead = reads[1];
        final hashes = await Future.wait<Uint8List>(<Future<Uint8List>>[
          _hashSourceRead(leftRead, cancellation: cancellation),
          _hashSourceRead(rightRead, cancellation: cancellation),
        ]);
        final leftHash = hashes[0];
        final rightHash = hashes[1];
        try {
          if (leftRead.length != rightRead.length ||
              !constantTimeBytesEqual(leftHash, rightHash)) {
            throw const SboxException(
              SboxErrorCode.immutableConflict,
              '双云存在相同路径但字节不同的不可变对象',
            );
          }
        } finally {
          leftHash.fillRange(0, leftHash.length, 0);
          rightHash.fillRange(0, rightHash.length, 0);
        }
      },
    );
  }

  Future<void> _assertRemoteMatchesLocal({
    required EnumerableDataSource source,
    required Directory root,
    required Iterable<String> names,
    required CloudBundleUploadCancellation cancellation,
  }) async {
    await _parallelForEach(
      names,
      maxParallel: source.capabilities.maxParallelTransfers,
      action: (name) async {
        cancellation.throwIfCancelled();
        final local = File(p.join(root.path, name));
        if (await FileSystemEntity.type(local.path, followLinks: false) !=
            FileSystemEntityType.file) {
          return;
        }
        final remote = await source.get(SourcePath(name));
        final localLength = await local.length();
        final localHash = await BackgroundBundleCrypto.sha256File(local);
        cancellation.throwIfCancelled();
        final remoteHash = await _hashSourceRead(
          remote,
          cancellation: cancellation,
        );
        try {
          if (localLength != remote.length ||
              !constantTimeBytesEqual(localHash, remoteHash)) {
            throw const SboxException(
              SboxErrorCode.immutableConflict,
              '本地与远端存在相同路径但字节不同的不可变对象',
            );
          }
        } finally {
          localHash.fillRange(0, localHash.length, 0);
          remoteHash.fillRange(0, remoteHash.length, 0);
        }
      },
    );
  }

  Future<Uint8List> _hashSourceRead(
    SourceRead read, {
    required CloudBundleUploadCancellation cancellation,
  }) async {
    final accumulator = HashDigestSink();
    final sink = crypto.sha256.startChunkedConversion(accumulator);
    var count = 0;
    await for (final chunk in read.body) {
      cancellation.throwIfCancelled();
      count += chunk.length;
      if (count > read.length) {
        throw const SboxException(SboxErrorCode.remoteChanged, '远端对象超过声明长度');
      }
      sink.add(chunk);
    }
    if (count != read.length) {
      throw const SboxException(SboxErrorCode.remoteChanged, '远端对象长度不一致');
    }
    sink.close();
    return Uint8List.fromList(accumulator.value.bytes);
  }

  Future<_PreviewOutcome> _readPreviewOutcome({
    required Directory root,
    required String rootObjectName,
    required BundleEncryptionOptions options,
    required bool reused,
    required CloudBundleUploadCancellation cancellation,
  }) async {
    cancellation.throwIfCancelled();
    final rootFile = File(p.join(root.path, rootObjectName));
    final headerBytes = await _readHeader(rootFile);
    final header = BundleHeader.parse(headerBytes);
    validateBundlePathAgainstHeader(rootObjectName, header);
    if (header.version == SboxVersion.v30) {
      return const _PreviewOutcome(
        embedded: false,
        reason: PreviewUnavailableReason.existingV30,
      );
    }

    final result = await BundleProbe.readMetadata(
      basename: rootObjectName,
      objectPrefix: headerBytes,
      identity: options.recipient,
    );
    try {
      cancellation.throwIfCancelled();
      if (result.preview != null) {
        return const _PreviewOutcome(embedded: true);
      }
      if (reused) {
        return const _PreviewOutcome(
          embedded: false,
          reason: PreviewUnavailableReason.existingV31WithoutPreview,
        );
      }
      if (options.preview != null) {
        final manifestBytes = result.manifest!.encode();
        try {
          if (options.preview!.encodedLength >
              MetadataBlockCodec.previewCapacity(manifestBytes.length)) {
            return const _PreviewOutcome(
              embedded: false,
              reason: PreviewUnavailableReason.metadataCapacity,
            );
          }
        } finally {
          manifestBytes.fillRange(0, manifestBytes.length, 0);
        }
      }
      return _PreviewOutcome(
        embedded: false,
        reason:
            options.previewUnavailableReason ??
            (options.wantsPreview
                ? PreviewUnavailableReason.encodeFailed
                : PreviewUnavailableReason.userDisabled),
      );
    } finally {
      result.preview?.dispose();
    }
  }

  Future<Set<String>> _remoteObjects(
    EnumerableDataSource source,
    Set<String> expected, {
    required String sourceName,
    required CloudBundleUploadCancellation cancellation,
  }) async {
    final objects = <String>{};
    try {
      if (expected.isEmpty) return objects;
      String? cursor;
      final visitedCursors = <String>{};
      final visitedPages = <String>{};
      do {
        cancellation.throwIfCancelled();
        if (cursor != null && !visitedCursors.add(cursor)) {
          throw const SboxException(
            SboxErrorCode.sourceNetwork,
            '数据源分页游标重复，无法完成云端校验',
          );
        }
        late SourceListPage page;
        for (var retry = 0; ; retry++) {
          late Object error;
          try {
            page = await _listObjectsForUpload(
              source,
              cursor: cursor,
            ).timeout(_remoteListingTimeout);
            cancellation.throwIfCancelled();
            break;
          } on SboxException catch (caught) {
            if (caught.code == SboxErrorCode.sourceNotFound) return objects;
            error = caught;
          } on TimeoutException {
            error = const SboxException(
              SboxErrorCode.sourceNetwork,
              '云端目录校验超时',
            );
          }
          cancellation.throwIfCancelled();
          if (retry >= maxShardUploadRetries || !_shouldRetry(error)) {
            throw error;
          }
          _logger?.warning(
            '$sourceName: listing failed; retrying',
            detail: describeSboxError(error),
          );
          await _waitBeforeRetry(
            retry,
            cancellation: cancellation,
            error: error,
          );
        }
        final pageSignature = page.objects
            .map((object) => object.path.value)
            .join('\u0000');
        if (!visitedPages.add(pageSignature)) {
          throw const SboxException(
            SboxErrorCode.sourceNetwork,
            '数据源重复返回目录页，无法完成云端校验',
          );
        }
        for (final object in page.objects) {
          cancellation.throwIfCancelled();
          if (expected.contains(object.path.value)) {
            objects.add(object.path.value);
          }
        }
        // Only the current Bundle matters here. Once every expected object is
        // visible, scanning unrelated historical objects in later pages only
        // delays completion and can leave the UI at a misleading 100%.
        if (objects.length == expected.length) return objects;
        cursor = page.nextCursor;
      } while (cursor != null);
      return objects;
    } on SboxException catch (error) {
      _logger?.warning(
        '$sourceName: listing failed',
        detail: describeSboxError(error),
      );
      throw SboxException(
        error.code,
        '$sourceName: ${error.message}',
        retryAfter: error.retryAfter,
        httpStatus: error.httpStatus,
      );
    } on Object catch (error) {
      _logger?.error(error, operation: '$sourceName: listing failed');
      throw SboxException(
        SboxErrorCode.sourceNetwork,
        '$sourceName: unable to list remote objects',
      );
    }
  }

  Future<Set<String>> _localObjects(
    Directory root,
    Set<String> expected, {
    required CloudBundleUploadCancellation cancellation,
  }) async {
    cancellation.throwIfCancelled();
    if (!await root.exists()) return <String>{};
    final objects = <String>{};
    for (final name in expected) {
      cancellation.throwIfCancelled();
      final file = File(p.join(root.path, name));
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.file) {
        objects.add(name);
      }
    }
    return objects;
  }

  Future<void> _restoreLocalCopy({
    required DataSource source,
    required Directory root,
    required List<String> objectNames,
    required Set<String> existing,
    required CloudBundleUploadCancellation cancellation,
  }) async {
    cancellation.throwIfCancelled();
    await root.create(recursive: true);
    final pending = objectNames
        .where((name) => !existing.contains(name))
        .toList(growable: false);
    await _parallelForEach(
      pending,
      maxParallel: source.capabilities.maxParallelTransfers,
      action: (name) => _restoreObject(
        source: source,
        root: root,
        name: name,
        cancellation: cancellation,
      ),
    );
  }

  Future<void> _restoreObject({
    required DataSource source,
    required Directory root,
    required String name,
    required CloudBundleUploadCancellation cancellation,
  }) async {
    cancellation.throwIfCancelled();
    final target = File(p.join(root.path, name));
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      throw const SboxException(
        SboxErrorCode.storageOverlap,
        'A local encrypted object path is already occupied',
      );
    }
    final read = await source.get(SourcePath(name));
    final stage = File('${target.path}.${hexLower(secureRandomBytes(8))}.part');
    IOSink? output;
    var renamed = false;
    var count = 0;
    try {
      output = stage.openWrite();
      await for (final chunk in read.body) {
        cancellation.throwIfCancelled();
        count += chunk.length;
        if (count > read.length) {
          throw const SboxException(
            SboxErrorCode.remoteChanged,
            'A remote object is longer than declared',
          );
        }
        output.add(chunk);
      }
      if (count != read.length) {
        throw const SboxException(
          SboxErrorCode.remoteChanged,
          'A remote object is incomplete',
        );
      }
      await output.flush();
      await output.close();
      output = null;
      await stage.rename(target.path);
      renamed = true;
    } finally {
      await output?.close();
      if (!renamed && await stage.exists()) await stage.delete();
    }
  }

  Future<void> _publishMemory({
    required EnumerableDataSource source,
    required Map<String, Uint8List> objects,
    required List<String> objectNames,
    required Set<String> existing,
    required String sourceName,
    required _UploadProgressReporter progress,
    required CloudBundleUploadCancellation cancellation,
  }) async {
    try {
      cancellation.throwIfCancelled();
      if (!source.capabilities.canWrite) {
        throw const SboxException(
          SboxErrorCode.sourceAuthentication,
          'Configure write credentials for this cloud source first',
        );
      }
      var observed = Set<String>.of(existing);
      for (var pass = 0; ; pass++) {
        cancellation.throwIfCancelled();
        final pending = _publicationOrder(objectNames)
            .where((name) => !observed.contains(name))
            .toList(growable: false);
        String? rootName;
        for (final name in pending) {
          if (parseCanonicalBundleBasename(name).shardIndex == 0) {
            rootName = name;
            break;
          }
        }
        final continuations = pending
            .where((name) => name != rootName)
            .toList(growable: false);
        await _parallelForEach(
          continuations,
          maxParallel: source.capabilities.maxParallelTransfers,
          action: (name) => _publishMemoryObject(
            source: source,
            name: name,
            bytes: objects[name]!,
            sourceName: sourceName,
            progress: progress,
            cancellation: cancellation,
          ),
        );
        if (rootName != null) {
          await _publishMemoryObject(
            source: source,
            name: rootName,
            bytes: objects[rootName]!,
            sourceName: sourceName,
            progress: progress,
            cancellation: cancellation,
          );
        }

        progress.emit(
          stage: CloudBundleUploadStage.verifying,
          currentSource: sourceName,
        );
        observed = await _remoteObjects(
          source,
          objectNames.toSet(),
          sourceName: sourceName,
          cancellation: cancellation,
        );
        progress.setCompleted(sourceName, observed.length);
        if (observed.length == objectNames.length) return;
        if (pass >= maxShardUploadRetries) {
          throw SboxException(
            SboxErrorCode.shardMissing,
            '上传校验失败，$sourceName 仍缺少 '
            '${objectNames.length - observed.length} 个分片',
          );
        }
        await _waitBeforeRetry(pass, cancellation: cancellation);
      }
    } on SboxException catch (error) {
      _logger?.warning(
        '$sourceName: publish failed',
        detail: describeSboxError(error),
      );
      throw SboxException(
        error.code,
        '$sourceName: ${error.message}',
        retryAfter: error.retryAfter,
        httpStatus: error.httpStatus,
      );
    } on Object catch (error) {
      _logger?.error(error, operation: '$sourceName: publish failed');
      throw SboxException(
        SboxErrorCode.sourceNetwork,
        '$sourceName: unable to publish the Bundle',
      );
    }
  }

  Future<void> _publishMemoryObject({
    required DataSource source,
    required String name,
    required Uint8List bytes,
    required String sourceName,
    required _UploadProgressReporter progress,
    required CloudBundleUploadCancellation cancellation,
  }) async {
    cancellation.throwIfCancelled();
    final header = BundleHeader.parse(bytes);
    validateBundlePathAgainstHeader(name, header);
    final digest = Uint8List.fromList(crypto.sha256.convert(bytes).bytes);
    try {
      final shard = parseCanonicalBundleBasename(name);
      Object? lastError;
      for (var retry = 0; retry <= maxShardUploadRetries; retry++) {
        cancellation.throwIfCancelled();
        final attempt = retry + 1;
        progress.emit(
          stage: CloudBundleUploadStage.uploading,
          currentSource: sourceName,
          currentShardIndex: shard.shardIndex,
          attempt: attempt,
        );
        try {
          await source.putNew(
            SourcePath(name),
            Stream<List<int>>.value(bytes),
            length: bytes.length,
            sha256: digest,
          );
          cancellation.throwIfCancelled();
          progress.completed(
            sourceName,
            shardIndex: shard.shardIndex,
            attempt: attempt,
          );
          return;
        } on Object catch (error) {
          cancellation.throwIfCancelled();
          lastError = error;
          if (error is SboxException &&
              error.code == SboxErrorCode.immutableConflict &&
              await _remoteObjectMatchesBytes(
                source: source,
                name: name,
                bytes: bytes,
                expectedHash: digest,
                cancellation: cancellation,
              )) {
            progress.completed(
              sourceName,
              shardIndex: shard.shardIndex,
              attempt: attempt,
            );
            return;
          }
          if (retry >= maxShardUploadRetries || !_shouldRetry(error)) {
            throw _shardUploadError(shard, attempt: attempt, error: error);
          }
          _logger?.warning(
            '$sourceName: shard upload failed; retrying',
            detail: describeSboxError(error),
          );
          await _waitBeforeRetry(
            retry,
            cancellation: cancellation,
            error: error,
          );
        }
      }
      throw _shardUploadError(
        shard,
        attempt: maxShardUploadRetries + 1,
        error: lastError,
      );
    } finally {
      digest.fillRange(0, digest.length, 0);
    }
  }

  Future<bool> _remoteObjectMatchesBytes({
    required DataSource source,
    required String name,
    required Uint8List bytes,
    required Uint8List expectedHash,
    required CloudBundleUploadCancellation cancellation,
  }) async {
    try {
      cancellation.throwIfCancelled();
      final remote = await source.get(SourcePath(name));
      final remoteHash = await _hashSourceRead(
        remote,
        cancellation: cancellation,
      );
      try {
        return remote.length == bytes.length &&
            constantTimeBytesEqual(remoteHash, expectedHash);
      } finally {
        remoteHash.fillRange(0, remoteHash.length, 0);
      }
    } on SboxException catch (error) {
      if (error.code == SboxErrorCode.cancelled) rethrow;
      return false;
    } on Object {
      return false;
    }
  }

  Future<void> _publishDirectory({
    required EnumerableDataSource source,
    required Directory root,
    required List<String> objectNames,
    required Set<String> existing,
    required String sourceName,
    required _UploadProgressReporter progress,
    required CloudBundleUploadCancellation cancellation,
  }) async {
    try {
      cancellation.throwIfCancelled();
      if (!source.capabilities.canWrite) {
        throw const SboxException(
          SboxErrorCode.sourceAuthentication,
          'Configure write credentials for this cloud source first',
        );
      }
      var observed = Set<String>.of(existing);
      for (var pass = 0; ; pass++) {
        cancellation.throwIfCancelled();
        final pending = _publicationOrder(objectNames)
            .where((name) => !observed.contains(name))
            .toList(growable: false);
        String? rootName;
        for (final name in pending) {
          if (parseCanonicalBundleBasename(name).shardIndex == 0) {
            rootName = name;
            break;
          }
        }
        final continuations = pending
            .where((name) => name != rootName)
            .toList(growable: false);

        // Continuations are independent immutable assets. Publish them with
        // the provider's bounded transfer parallelism, then publish the root
        // as the final Bundle commit marker.
        await _parallelForEach(
          continuations,
          maxParallel: source.capabilities.maxParallelTransfers,
          action: (name) => _publishObject(
            source: source,
            root: root,
            name: name,
            sourceName: sourceName,
            progress: progress,
            cancellation: cancellation,
          ),
        );
        if (rootName != null) {
          cancellation.throwIfCancelled();
          await _publishObject(
            source: source,
            root: root,
            name: rootName,
            sourceName: sourceName,
            progress: progress,
            cancellation: cancellation,
          );
        }

        // The last put can finish before this source's post-publish listing.
        // Switch stages before waiting for that listing so the UI never
        // presents the final shard write as the terminal upload state.
        progress.emit(
          stage: CloudBundleUploadStage.verifying,
          currentSource: sourceName,
        );
        cancellation.throwIfCancelled();
        observed = await _remoteObjects(
          source,
          objectNames.toSet(),
          sourceName: sourceName,
          cancellation: cancellation,
        );
        progress.setCompleted(sourceName, observed.length);
        if (observed.length == objectNames.length) return;
        if (pass >= maxShardUploadRetries) {
          throw SboxException(
            SboxErrorCode.shardMissing,
            '上传校验失败，$sourceName 仍缺少 '
            '${objectNames.length - observed.length} 个分片',
          );
        }
        progress.emit(
          stage: CloudBundleUploadStage.verifying,
          currentSource: sourceName,
        );
        await _waitBeforeRetry(pass, cancellation: cancellation);
      }
    } on SboxException catch (error) {
      _logger?.warning(
        '$sourceName: publish failed',
        detail: describeSboxError(error),
      );
      throw SboxException(
        error.code,
        '$sourceName: ${error.message}',
        retryAfter: error.retryAfter,
        httpStatus: error.httpStatus,
      );
    } on Object catch (error) {
      _logger?.error(error, operation: '$sourceName: publish failed');
      throw SboxException(
        SboxErrorCode.sourceNetwork,
        '$sourceName: unable to publish the Bundle',
      );
    }
  }

  Future<void> _publishObject({
    required DataSource source,
    required Directory root,
    required String name,
    required String sourceName,
    required _UploadProgressReporter progress,
    required CloudBundleUploadCancellation cancellation,
  }) async {
    cancellation.throwIfCancelled();
    final file = File(p.join(root.path, name));
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const SboxException(
        SboxErrorCode.sourceNotFound,
        'The local encrypted object does not exist',
      );
    }
    final headerBytes = await _readHeader(file);
    final header = BundleHeader.parse(headerBytes);
    validateBundlePathAgainstHeader(name, header);
    final length = await file.length();
    final digest = await BackgroundBundleCrypto.sha256File(file);
    try {
      cancellation.throwIfCancelled();
      final shard = parseCanonicalBundleBasename(name);
      Object? lastError;
      for (var retry = 0; retry <= maxShardUploadRetries; retry++) {
        cancellation.throwIfCancelled();
        final attempt = retry + 1;
        progress.emit(
          stage: CloudBundleUploadStage.uploading,
          currentSource: sourceName,
          currentShardIndex: shard.shardIndex,
          attempt: attempt,
        );
        try {
          // A fresh stream is required for every retry because the source
          // consumes the input stream while hashing and publishing it.
          await source.putNew(
            SourcePath(name),
            file.openRead(),
            length: length,
            sha256: digest,
          );
          cancellation.throwIfCancelled();
          progress.completed(
            sourceName,
            shardIndex: shard.shardIndex,
            attempt: attempt,
          );
          return;
        } on Object catch (error) {
          cancellation.throwIfCancelled();
          lastError = error;
          if (error is SboxException &&
              error.code == SboxErrorCode.immutableConflict &&
              await _remoteObjectMatchesFile(
                source: source,
                name: name,
                length: length,
                expectedHash: digest,
                cancellation: cancellation,
              )) {
            // A concurrent or resumed upload may have published this exact
            // shard after the listing. It is already complete, so advance
            // progress and continue with the next pending shard.
            progress.completed(
              sourceName,
              shardIndex: shard.shardIndex,
              attempt: attempt,
            );
            return;
          }
          if (retry >= maxShardUploadRetries || !_shouldRetry(error)) {
            throw _shardUploadError(shard, attempt: attempt, error: error);
          }
          _logger?.warning(
            '$sourceName: shard upload failed; retrying',
            detail: describeSboxError(error),
          );
          await _waitBeforeRetry(
            retry,
            cancellation: cancellation,
            error: error,
          );
        }
      }
      throw _shardUploadError(
        shard,
        attempt: maxShardUploadRetries + 1,
        error: lastError,
      );
    } finally {
      digest.fillRange(0, digest.length, 0);
    }
  }

  Future<bool> _remoteObjectMatchesFile({
    required DataSource source,
    required String name,
    required int length,
    required Uint8List expectedHash,
    required CloudBundleUploadCancellation cancellation,
  }) async {
    try {
      cancellation.throwIfCancelled();
      final remote = await source.get(SourcePath(name));
      final remoteHash = await _hashSourceRead(
        remote,
        cancellation: cancellation,
      );
      try {
        return remote.length == length &&
            constantTimeBytesEqual(remoteHash, expectedHash);
      } finally {
        remoteHash.fillRange(0, remoteHash.length, 0);
      }
    } on SboxException catch (error) {
      if (error.code == SboxErrorCode.cancelled) rethrow;
      // The object may not have been committed yet. Any other read failure
      // is treated as "not confirmed" and the original upload error remains
      // authoritative.
      if (error.code == SboxErrorCode.sourceNotFound) return false;
      return false;
    } on Object {
      return false;
    }
  }

  BundleEncryptionOptions _withSharedObjectLimit(
    BundleEncryptionOptions options,
  ) {
    final configured = options.maxObjectBytes;
    final maxObjectBytes = configured == null || configured > _giteeObjectLimit
        ? _giteeObjectLimit
        : configured;
    return BundleEncryptionOptions(
      recipient: options.recipient,
      contentKind: options.contentKind,
      originalName: options.originalName,
      mediaType: options.mediaType,
      title: options.title,
      description: options.description,
      tags: options.tags,
      createdAt: options.createdAt,
      targetNominalShardPlaintextSize: options.targetNominalShardPlaintextSize,
      maxObjectBytes: maxObjectBytes,
      preview: options.preview,
      previewRequested: options.previewRequested,
      previewUnavailableReason: options.previewUnavailableReason,
      randomness: options.randomness,
    );
  }

  static List<String> _publicationOrder(Iterable<String> names) {
    final parsed = names.map((name) {
      final info = parseCanonicalBundleBasename(name);
      return (name: name, root: info.shardIndex == 0, index: info.shardIndex);
    }).toList();
    parsed.sort((left, right) {
      if (left.root != right.root) return left.root ? 1 : -1;
      return left.index.compareTo(right.index);
    });
    return List.unmodifiable(parsed.map((item) => item.name));
  }

  static Future<List<int>> _readHeader(File file) async {
    final bytes = <int>[];
    await for (final chunk in file.openRead(0, SboxProtocol.rootHeaderLength)) {
      bytes.addAll(chunk);
      if (bytes.length >= SboxProtocol.rootHeaderLength) break;
    }
    if (bytes.length < SboxProtocol.commonHeaderLength) {
      throw const SboxException(
        SboxErrorCode.truncated,
        'The local encrypted object header is incomplete',
      );
    }
    return bytes;
  }

  Future<void> _waitBeforeRetry(
    int retry, {
    required CloudBundleUploadCancellation cancellation,
    Object? error,
  }) async {
    cancellation.throwIfCancelled();
    final multiplier = 1 << retry.clamp(0, 6).toInt();
    var delay = retryBaseDelay * multiplier;
    final providerDelay = error is SboxException ? error.retryAfter : null;
    if (providerDelay != null && providerDelay.compareTo(delay) > 0) {
      delay = providerDelay;
    }
    if (delay.compareTo(_maximumProviderRetryDelay) > 0) {
      delay = _maximumProviderRetryDelay;
    }
    if (delay <= Duration.zero) return;

    // A provider can ask the uploader to wait for minutes. Keep that wait
    // cancellable instead of leaving the page stuck in Future.delayed.
    final completed = Completer<void>();
    void finish() {
      if (!completed.isCompleted) completed.complete();
    }

    final unregisterCancellation = cancellation.registerOnCancel(finish);
    final timer = Timer(delay, finish);
    try {
      await completed.future;
    } finally {
      timer.cancel();
      unregisterCancellation();
    }
    cancellation.throwIfCancelled();
  }

  static bool _shouldRetry(Object error) {
    if (error is! SboxException) return true;
    // HTTP 422 is a provider validation response, not a transient network
    // failure. putNew has already confirmed whether the object was committed;
    // repeating the same Release asset upload only creates more false failures.
    if (error.httpStatus == 422) return false;
    switch (error.code) {
      case SboxErrorCode.sourceNetwork:
      case SboxErrorCode.sourceRateLimit:
      case SboxErrorCode.remoteChanged:
      case SboxErrorCode.truncated:
        return true;
      default:
        return false;
    }
  }

  static SboxException _shardUploadError(
    BundlePathInfo shard, {
    required int attempt,
    required Object? error,
  }) {
    final sourceError = error is SboxException
        ? error
        : SboxException(SboxErrorCode.sourceNetwork, '上传请求失败');
    return SboxException(
      sourceError.code,
      '分片 ${shard.shardIndex + 1}/${shard.shardCount} 上传失败（已尝试 $attempt 次）：'
      '${sourceError.message}',
      retryAfter: sourceError.retryAfter,
      httpStatus: sourceError.httpStatus,
    );
  }

  Future<SourceListPage> _listObjectsForUpload(
    EnumerableDataSource source, {
    String? cursor,
  }) {
    // Release asset metadata already includes the object size, so upload
    // verification can use the same listing path as the library.
    return source.listObjects(cursor: cursor);
  }
}

final class _CloudUploadSource {
  const _CloudUploadSource({required this.name, required this.source});

  final String name;
  final EnumerableDataSource source;
}

final class _PreviewOutcome {
  const _PreviewOutcome({required this.embedded, this.reason});

  final bool embedded;
  final PreviewUnavailableReason? reason;
}

final class _UploadProgressReporter {
  _UploadProgressReporter({
    required this.totalShards,
    required this.totalBytes,
    required Iterable<String> sourceNames,
    this.onProgress,
  }) : _completed = <String, int>{
         for (final sourceName in sourceNames) sourceName: 0,
       };

  final int totalShards;
  final int totalBytes;
  final void Function(CloudBundleUploadProgress progress)? onProgress;
  final Map<String, int> _completed;
  int _processedBytes = 0;
  int _processedShards = 0;
  int _processingTotalShards = 0;
  int _currentShardBytes = 0;
  int _currentShardLength = 0;

  void updateEncryption(BundleEncryptionProgress progress) {
    _processedBytes = progress.processedBytes.clamp(0, totalBytes).toInt();
    _processedShards = progress.completedShards
        .clamp(0, progress.totalShards)
        .toInt();
    _processingTotalShards = progress.totalShards;
    _currentShardBytes = progress.currentShardBytes;
    _currentShardLength = progress.currentShardLength;
    emit(
      stage: progress.stage == BundleEncryptionStage.splitting
          ? CloudBundleUploadStage.splitting
          : CloudBundleUploadStage.encrypting,
      currentShardIndex: progress.currentShardIndex,
    );
  }

  void setCompleted(String sourceName, int value) {
    _completed[sourceName] = value.clamp(0, totalShards).toInt();
  }

  void completed(
    String sourceName, {
    required int shardIndex,
    required int attempt,
  }) {
    final current = _completed[sourceName] ?? 0;
    _completed[sourceName] = (current + 1).clamp(0, totalShards).toInt();
    emit(
      stage: CloudBundleUploadStage.uploading,
      currentSource: sourceName,
      currentShardIndex: shardIndex,
      attempt: attempt,
    );
  }

  void emit({
    required CloudBundleUploadStage stage,
    String? currentSource,
    int? currentShardIndex,
    int attempt = 1,
  }) {
    final callback = onProgress;
    if (callback == null) return;
    try {
      callback(
        CloudBundleUploadProgress(
          stage: stage,
          sources: Map.unmodifiable(<String, CloudBundleSourceProgress>{
            for (final entry in _completed.entries)
              entry.key: CloudBundleSourceProgress(
                sourceName: entry.key,
                completedShards: entry.value,
                totalShards: totalShards,
              ),
          }),
          currentSource: currentSource,
          currentShardIndex: currentShardIndex,
          attempt: attempt,
          processedBytes: _processedBytes,
          totalBytes: totalBytes,
          processedShards: _processedShards,
          processingTotalShards: _processingTotalShards,
          currentShardBytes: _currentShardBytes,
          currentShardLength: _currentShardLength,
        ),
      );
    } on Object {
      // UI progress must never be able to interrupt an upload.
    }
  }
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MiB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '$bytes B';
}

Future<void> _parallelForEach<T>(
  Iterable<T> values, {
  required int maxParallel,
  required Future<void> Function(T value) action,
}) async {
  final items = values.toList(growable: false);
  if (items.isEmpty) return;
  final workerCount = maxParallel < 1
      ? 1
      : maxParallel > items.length
      ? items.length
      : maxParallel;
  var next = 0;

  Future<void> worker() async {
    while (true) {
      if (next >= items.length) return;
      final index = next++;
      await action(items[index]);
    }
  }

  await Future.wait(<Future<void>>[
    for (var index = 0; index < workerCount; index++) worker(),
  ]);
}
