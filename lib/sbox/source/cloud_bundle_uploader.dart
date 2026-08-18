import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../app/app_logger.dart';
import '../bytes.dart';
import '../constants.dart';
import '../engine/bundle_encryptor.dart';
import '../engine/bundle_planner.dart';
import '../errors.dart';
import '../format/bundle_header.dart';
import '../format/bundle_path.dart';
import '../storage/io_hash.dart';
import 'cloud_backup_config.dart';
import 'credential.dart';
import 'data_source.dart';
import 'gitee_source.dart';
import 'github_source.dart';
import 'source_path.dart';

final class CloudBundleUploadResult {
  const CloudBundleUploadResult({
    required this.bundleId,
    required this.objectNames,
    required this.duplicate,
    required this.uploadedSources,
  });

  final String bundleId;
  final List<String> objectNames;
  final bool duplicate;
  final List<String> uploadedSources;

  String get rootObjectName => objectNames.firstWhere(
    (name) => parseCanonicalBundleBasename(name).shardIndex == 0,
  );
}

/// Hashes, de-duplicates, encrypts and publishes one file through both
/// repository APIs. It never invokes Git or transfers the whole repository.
final class CloudBundleUploader {
  CloudBundleUploader({
    required this._credentialStore,
    required this._client,
    BundleEncryptor? encryptor,
    this._logger,
  }) : _encryptor = encryptor ?? BundleEncryptor();

  static const int _giteeObjectLimit = 20 * 1024 * 1024;

  final CredentialStore _credentialStore;
  final http.Client _client;
  final BundleEncryptor _encryptor;
  final AppLogger? _logger;

  Future<CloudBundleUploadResult> upload({
    required BundleInput input,
    required int declaredLength,
    required BundleEncryptionOptions options,
    required CloudBackupConfiguration configuration,
  }) async {
    final effectiveOptions = _withSharedObjectLimit(options);
    final md5 = await _encryptor.md5ForInput(
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
      final githubComplete = githubObjects.length == expected.length;
      final giteeComplete = giteeObjects.length == expected.length;

      final root = Directory(configuration.backupDirectory);
      var localObjects = await _localObjects(root, expected);
      var localComplete = localObjects.length == expected.length;

      if (!localComplete && (githubComplete || giteeComplete)) {
        final mirror = githubComplete ? github : gitee;
        await _restoreLocalCopy(
          source: mirror,
          root: root,
          objectNames: objectNames,
          existing: localObjects,
        );
        localComplete = true;
      }

      var created = false;
      if (!localComplete) {
        final remotePartial =
            githubObjects.isNotEmpty || giteeObjects.isNotEmpty;
        if (remotePartial) {
          throw const SboxException(
            SboxErrorCode.immutableConflict,
            '公开云中已存在不完整的同 MD5 Bundle，无法安全重建',
          );
        }
        await _encryptor.encryptToDirectory(
          input: input,
          declaredLength: declaredLength,
          options: effectiveOptions,
          root: root,
        );
        localObjects = await _localObjects(root, expected);
        localComplete = localObjects.length == expected.length;
        created = true;
      }
      if (!localComplete) {
        throw const SboxException(SboxErrorCode.storageOverlap, '本地加密备份未完整生成');
      }

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
          ),
        );
      }
      await Future.wait(uploadTasks);
      return CloudBundleUploadResult(
        bundleId: bundleId,
        objectNames: List.unmodifiable(objectNames),
        duplicate: !created,
        uploadedSources: List.unmodifiable(uploadedSources),
      );
    } finally {
      md5.fillRange(0, md5.length, 0);
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
          // An empty public repository can be reported as a missing contents
          // directory by provider APIs; treat it as an empty source.
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
        '$sourceName：列举云端对象失败',
        detail: AppLogger.describeError(error),
      );
      throw SboxException(error.code, '$sourceName：${error.message}');
    } on Object catch (error) {
      _logger?.error(error, operation: '$sourceName：列举云端对象失败');
      throw SboxException(SboxErrorCode.sourceNetwork, '$sourceName：无法安全连接数据源');
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
    final ordered = _publicationOrder(objectNames);
    for (final name in ordered) {
      if (existing.contains(name)) continue;
      final target = File(p.join(root.path, name));
      final type = await FileSystemEntity.type(target.path, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        throw const SboxException(
          SboxErrorCode.storageOverlap,
          '本地加密备份路径被其他文件占用',
        );
      }
      final read = await source.get(SourcePath(name));
      final stage = File(
        '${target.path}.${hexLower(secureRandomBytes(8))}.part',
      );
      final output = stage.openWrite();
      var count = 0;
      try {
        await for (final chunk in read.body) {
          count += chunk.length;
          if (count > read.length) {
            throw const SboxException(SboxErrorCode.remoteChanged, '公开云对象长度异常');
          }
          output.add(chunk);
        }
        if (count != read.length) {
          throw const SboxException(SboxErrorCode.remoteChanged, '公开云对象不完整');
        }
        await output.flush();
        await output.close();
        await stage.rename(target.path);
      } finally {
        await output.close();
        if (await stage.exists()) await stage.delete();
      }
    }
  }

  Future<void> _publishDirectory({
    required DataSource source,
    required Directory root,
    required List<String> objectNames,
    required Set<String> existing,
    required String sourceName,
  }) async {
    try {
      if (!source.capabilities.canWrite) {
        throw const SboxException(
          SboxErrorCode.sourceAuthentication,
          '请先配置当前云端的访问令牌',
        );
      }
      final ordered = _publicationOrder(objectNames);
      for (final name in ordered) {
        if (existing.contains(name)) continue;
        final file = File(p.join(root.path, name));
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw const SboxException(SboxErrorCode.sourceNotFound, '本地加密对象不存在');
        }
        final bytes = await _readHeader(file);
        final header = BundleHeader.parse(bytes);
        validateBundlePathAgainstHeader(name, header);
        final length = await file.length();
        final sha256 = await sha256File(file);
        await source.putNew(
          SourcePath(name),
          file.openRead(),
          length: length,
          sha256: sha256,
        );
      }
    } on SboxException catch (error) {
      _logger?.warning(
        '$sourceName：发布云端对象失败',
        detail: AppLogger.describeError(error),
      );
      throw SboxException(error.code, '$sourceName：${error.message}');
    } on Object catch (error) {
      _logger?.error(error, operation: '$sourceName：发布云端对象失败');
      throw SboxException(SboxErrorCode.sourceNetwork, '$sourceName：无法安全连接数据源');
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
      throw const SboxException(SboxErrorCode.truncated, '本地加密对象头不完整');
    }
    return bytes;
  }
}
