import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

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

enum CloudBundleUploadStage { preparing, uploading, verifying, completed }

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
  });

  final CloudBundleUploadStage stage;
  final Map<String, CloudBundleSourceProgress> sources;
  final String? currentSource;
  final int? currentShardIndex;
  final int attempt;

  int get completedShards => sources.values.fold(
    0,
    (total, source) => total + source.completedShards,
  );

  int get totalShards => sources.values.fold(
    0,
    (total, source) => total + source.totalShards,
  );

  double get fraction => totalShards == 0
      ? 0
      : (completedShards / totalShards).clamp(0, 1).toDouble();

  String get overallLabel =>
      '$completedShards/$totalShards (${(fraction * 100).toStringAsFixed(1)}%)';

  String get sourceLabel => sources.values
      .map((source) => '${source.sourceName} ${source.ratioLabel}')
      .join(' · ');

  String get detailLabel {
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
/// Each repository's Contents API advances one Git branch head per write, so
/// shard publication must be serial within a source. GitHub explicitly
/// rejects concurrent contents writes with a branch-level conflict even when
/// the shard paths are different.
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
      throw ArgumentError.value(
        maxShardUploadRetries,
        'maxShardUploadRetries',
      );
    }
    if (retryBaseDelay.isNegative) {
      throw ArgumentError.value(retryBaseDelay, 'retryBaseDelay');
    }
  }

  static const int _giteeObjectLimit = 20 * 1024 * 1024;

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
  }) async {
    final effectiveOptions = _withSharedObjectLimit(options);
    final md5 =
        _encryptor == null && BackgroundBundleCrypto.supportsInput(input)
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
    final bundleId = hexLower(md5);
    try {
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
      final progress = _UploadProgressReporter(
        totalShards: plan.shardCount,
        onProgress: onProgress,
      )..emit(stage: CloudBundleUploadStage.preparing);
      final expected = objectNames.toSet();
      final github = GitHubDataSource(
        config: configuration.github.repositoryConfig,
        client: _client,
        credentialStore: _credentialStore,
        credentialId: configuration.github.credentialId,
        logger: _logger,
      );
      final gitee = GiteeDataSource(
        config: configuration.gitee.repositoryConfig,
        client: _client,
        credentialStore: _credentialStore,
        credentialId: configuration.gitee.credentialId,
        logger: _logger,
      );

      final remoteObjects = await Future.wait(<Future<Set<String>>>[
        _remoteObjects(github, expected, sourceName: 'GitHub'),
        _remoteObjects(gitee, expected, sourceName: 'Gitee'),
      ]);
      final githubObjects = remoteObjects[0];
      final giteeObjects = remoteObjects[1];
      await _assertRemoteSourcesAgree(
        github,
        gitee,
        githubObjects.intersection(giteeObjects),
      );
      final githubComplete = githubObjects.length == expected.length;
      final giteeComplete = giteeObjects.length == expected.length;
      progress
        ..setCompleted('GitHub', githubObjects.length)
        ..setCompleted('Gitee', giteeObjects.length)
        ..emit(stage: CloudBundleUploadStage.preparing);

      final root = Directory(configuration.backupDirectory);
      var localObjects = await _localObjects(root, expected);
      var localComplete = localObjects.length == expected.length;
      await _assertRemoteMatchesLocal(
        source: github,
        root: root,
        names: githubObjects.intersection(localObjects),
      );
      await _assertRemoteMatchesLocal(
        source: gitee,
        root: root,
        names: giteeObjects.intersection(localObjects),
      );

      if (!localComplete && (githubComplete || giteeComplete)) {
        final mirror = githubComplete ? github : gitee;
        await _restoreLocalCopy(
          source: mirror,
          root: root,
          objectNames: objectNames,
          existing: localObjects,
        );
        localObjects = await _localObjects(root, expected);
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
          );
        } else {
          await (_encryptor ?? BundleEncryptor()).encryptToDirectory(
            input: input,
            declaredLength: declaredLength,
            options: effectiveOptions,
            root: root,
          );
        }
        localObjects = await _localObjects(root, expected);
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
        await _assertRemoteMatchesLocal(
          source: github,
          root: root,
          names: githubObjects.intersection(localObjects),
        );
        await _assertRemoteMatchesLocal(
          source: gitee,
          root: root,
          names: giteeObjects.intersection(localObjects),
        );
      }

      progress.emit(stage: CloudBundleUploadStage.uploading);
      final uploadTasks = <Future<void>>[];
      final uploadedSources = <String>[];
      if (!githubComplete) {
        uploadedSources.add('GitHub');
        uploadTasks.add(
          _publishDirectory(
            source: github,
            root: root,
            objectNames: objectNames,
            existing: githubObjects,
            sourceName: 'GitHub',
            progress: progress,
          ),
        );
      }
      if (!giteeComplete) {
        uploadedSources.add('Gitee');
        uploadTasks.add(
          _publishDirectory(
            source: gitee,
            root: root,
            objectNames: objectNames,
            existing: giteeObjects,
            sourceName: 'Gitee',
            progress: progress,
          ),
        );
      }
      await Future.wait(uploadTasks);

      progress.emit(stage: CloudBundleUploadStage.verifying);
      await Future.wait(<Future<void>>[
        _verifyPublishedObjects(
          source: github,
          root: root,
          objectNames: objectNames,
          expected: expected,
          sourceName: 'GitHub',
          progress: progress,
        ),
        _verifyPublishedObjects(
          source: gitee,
          root: root,
          objectNames: objectNames,
          expected: expected,
          sourceName: 'Gitee',
          progress: progress,
        ),
      ]);
      progress.emit(stage: CloudBundleUploadStage.completed);
      final previewOutcome = await _readPreviewOutcome(
        root: root,
        rootObjectName: objectNames.firstWhere(
          (name) => parseCanonicalBundleBasename(name).shardIndex == 0,
        ),
        options: effectiveOptions,
        reused: !created,
      );
      return CloudBundleUploadResult(
        bundleId: bundleId,
        objectNames: List.unmodifiable(objectNames),
        duplicate: !created,
        uploadedSources: List.unmodifiable(uploadedSources),
        previewRequested: effectiveOptions.wantsPreview,
        previewEmbedded: previewOutcome.embedded,
        previewUnavailableReason: previewOutcome.reason,
      );
    } finally {
      md5.fillRange(0, md5.length, 0);
    }
  }

  Future<void> _assertRemoteSourcesAgree(
    EnumerableDataSource left,
    EnumerableDataSource right,
    Iterable<String> names,
  ) async {
    for (final name in names) {
      final leftRead = await left.get(SourcePath(name));
      final rightRead = await right.get(SourcePath(name));
      final leftHash = await _hashSourceRead(leftRead);
      final rightHash = await _hashSourceRead(rightRead);
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
    }
  }

  Future<void> _assertRemoteMatchesLocal({
    required EnumerableDataSource source,
    required Directory root,
    required Iterable<String> names,
  }) async {
    for (final name in names) {
      final local = File(p.join(root.path, name));
      if (await FileSystemEntity.type(local.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      final remote = await source.get(SourcePath(name));
      final localLength = await local.length();
      final localHash = await BackgroundBundleCrypto.sha256File(local);
      final remoteHash = await _hashSourceRead(remote);
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
    }
  }

  Future<Uint8List> _hashSourceRead(SourceRead read) async {
    final accumulator = HashDigestSink();
    final sink = crypto.sha256.startChunkedConversion(accumulator);
    var count = 0;
    await for (final chunk in read.body) {
      count += chunk.length;
      if (count > read.length) {
        throw const SboxException(
          SboxErrorCode.remoteChanged,
          '远端对象超过声明长度',
        );
      }
      sink.add(chunk);
    }
    if (count != read.length) {
      throw const SboxException(
        SboxErrorCode.remoteChanged,
        '远端对象长度不一致',
      );
    }
    sink.close();
    return Uint8List.fromList(accumulator.value.bytes);
  }

  Future<_PreviewOutcome> _readPreviewOutcome({
    required Directory root,
    required String rootObjectName,
    required BundleEncryptionOptions options,
    required bool reused,
  }) async {
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
  }) async {
    final objects = <String>{};
    try {
      String? cursor;
      do {
        SourceListPage page;
        try {
          page = await source.listObjects(cursor: cursor);
        } on SboxException catch (error) {
          if (error.code == SboxErrorCode.sourceNotFound) return objects;
          rethrow;
        }
        for (final object in page.objects) {
          if (expected.contains(object.path.value)) {
            objects.add(object.path.value);
          }
        }
        cursor = page.nextCursor;
      } while (cursor != null);
      return objects;
    } on SboxException catch (error) {
      _logger?.warning(
        '$sourceName: listing failed',
        detail: describeSboxError(error),
      );
      throw SboxException(error.code, '$sourceName: ${error.message}');
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
    Set<String> expected,
  ) async {
    if (!await root.exists()) return <String>{};
    final objects = <String>{};
    for (final name in expected) {
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
  }) async {
    await root.create(recursive: true);
    final pending = objectNames
        .where((name) => !existing.contains(name))
        .toList(growable: false);
    await _parallelForEach(
      pending,
      maxParallel: source.capabilities.maxParallelTransfers,
      action: (name) => _restoreObject(source: source, root: root, name: name),
    );
  }

  Future<void> _restoreObject({
    required DataSource source,
    required Directory root,
    required String name,
  }) async {
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

  Future<void> _publishDirectory({
    required EnumerableDataSource source,
    required Directory root,
    required List<String> objectNames,
    required Set<String> existing,
    required String sourceName,
    required _UploadProgressReporter progress,
  }) async {
    try {
      if (!source.capabilities.canWrite) {
        throw const SboxException(
          SboxErrorCode.sourceAuthentication,
          'Configure write credentials for this cloud source first',
        );
      }
      var observed = Set<String>.of(existing);
      for (var pass = 0; ; pass++) {
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

        // Continuations are independent immutable objects at the path level,
        // but each Contents API write also advances the same repository
        // branch. Publish them serially, then publish the root as the final
        // Bundle commit marker.
        for (final name in continuations) {
          await _publishObject(
            source: source,
            root: root,
            name: name,
            sourceName: sourceName,
            progress: progress,
          );
        }
        if (rootName != null) {
          await _publishObject(
            source: source,
            root: root,
            name: rootName,
            sourceName: sourceName,
            progress: progress,
          );
        }

        observed = await _remoteObjects(
          source,
          objectNames.toSet(),
          sourceName: sourceName,
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
        await _waitBeforeRetry(pass);
      }
    } on SboxException catch (error) {
      _logger?.warning(
        '$sourceName: publish failed',
        detail: describeSboxError(error),
      );
      throw SboxException(error.code, '$sourceName: ${error.message}');
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
  }) async {
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
      final shard = parseCanonicalBundleBasename(name);
      Object? lastError;
      for (var retry = 0; retry <= maxShardUploadRetries; retry++) {
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
          progress.completed(
            sourceName,
            shardIndex: shard.shardIndex,
            attempt: attempt,
          );
          return;
        } on Object catch (error) {
          lastError = error;
          if (error is SboxException &&
              error.code == SboxErrorCode.immutableConflict &&
              await _remoteObjectMatchesFile(
                source: source,
                name: name,
                length: length,
                expectedHash: digest,
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
            throw _shardUploadError(
              shard,
              attempt: attempt,
              error: error,
            );
          }
          _logger?.warning(
            '$sourceName: shard upload failed; retrying',
            detail: describeSboxError(error),
          );
          await _waitBeforeRetry(retry);
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
  }) async {
    try {
      final remote = await source.get(SourcePath(name));
      final remoteHash = await _hashSourceRead(remote);
      try {
        return remote.length == length &&
            constantTimeBytesEqual(remoteHash, expectedHash);
      } finally {
        remoteHash.fillRange(0, remoteHash.length, 0);
      }
    } on SboxException catch (error) {
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

  Future<void> _waitBeforeRetry(int retry) async {
    if (retryBaseDelay == Duration.zero) return;
    final multiplier = 1 << retry.clamp(0, 6).toInt();
    await Future<void>.delayed(retryBaseDelay * multiplier);
  }

  static bool _shouldRetry(Object error) {
    if (error is! SboxException) return true;
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
        : SboxException(
            SboxErrorCode.sourceNetwork,
            '上传请求失败',
          );
    return SboxException(
      sourceError.code,
      '分片 ${shard.shardIndex + 1}/${shard.shardCount} 上传失败（已尝试 $attempt 次）：'
          '${sourceError.message}',
    );
  }

  Future<void> _verifyPublishedObjects({
    required EnumerableDataSource source,
    required Directory root,
    required List<String> objectNames,
    required Set<String> expected,
    required String sourceName,
    required _UploadProgressReporter progress,
  }) async {
    final observed = await _remoteObjects(
      source,
      expected,
      sourceName: sourceName,
    );
    progress.setCompleted(sourceName, observed.length);
    if (observed.length != expected.length) {
      await _publishDirectory(
        source: source,
        root: root,
        objectNames: objectNames,
        existing: observed,
        sourceName: sourceName,
        progress: progress,
      );
    }
  }
}

final class _PreviewOutcome {
  const _PreviewOutcome({required this.embedded, this.reason});

  final bool embedded;
  final PreviewUnavailableReason? reason;
}

final class _UploadProgressReporter {
  _UploadProgressReporter({
    required this.totalShards,
    this.onProgress,
  }) : _completed = <String, int>{'GitHub': 0, 'Gitee': 0};

  final int totalShards;
  final void Function(CloudBundleUploadProgress progress)? onProgress;
  final Map<String, int> _completed;

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
        ),
      );
    } on Object {
      // UI progress must never be able to interrupt an upload.
    }
  }
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
