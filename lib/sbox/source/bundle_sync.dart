import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../bytes.dart';
import '../errors.dart';
import '../engine/background_bundle_crypto.dart';
import '../engine/bundle_decryptor.dart';
import '../engine/bundle_encryptor.dart';
import '../format/bundle_header.dart';
import '../format/bundle_path.dart';
import '../identity/rsa_models.dart';
import 'data_source.dart';
import 'source_path.dart';

enum BundleDownloadStage { preparing, downloading, decrypting, merging }

/// Signals that a download should stop at the next safe boundary.
///
/// The caller can register cleanup hooks such as closing the HTTP client used
/// by the current download. The stream reader also observes this signal so a
/// cancellation interrupts an in-flight object response instead of waiting
/// for the whole shard to arrive.
final class BundleDownloadCancellation {
  bool _cancelled = false;
  final Completer<void> _cancelledCompleter = Completer<void>();
  final Set<void Function()> _listeners = <void Function()>{};

  bool get isCancelled => _cancelled;

  Future<void> get whenCancelled => _cancelledCompleter.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_cancelledCompleter.isCompleted) _cancelledCompleter.complete();
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
      throw const SboxException(SboxErrorCode.cancelled, '下载已取消');
    }
  }
}

final class BundleDownloadProgress {
  const BundleDownloadProgress({
    required this.stage,
    required this.downloadedBytes,
    required this.completedObjects,
    required this.totalObjects,
    required this.progressUnits,
    this.currentShardIndex,
    this.currentObjectBytes = 0,
    this.currentObjectLength = 0,
    this.processedBytes = 0,
    this.totalProcessingBytes = 0,
    this.processedShards = 0,
    this.processingTotalShards = 0,
  });

  final BundleDownloadStage stage;
  final int downloadedBytes;
  final int completedObjects;
  final int totalObjects;

  /// Completed objects plus the fractional progress of active objects. The
  /// value is weighted by object count because continuation object lengths
  /// are discovered while their responses are opened.
  final double progressUnits;
  final int? currentShardIndex;
  final int currentObjectBytes;
  final int currentObjectLength;
  final int processedBytes;
  final int totalProcessingBytes;
  final int processedShards;
  final int processingTotalShards;

  double? get fraction {
    if (stage == BundleDownloadStage.decrypting ||
        stage == BundleDownloadStage.merging) {
      if (totalProcessingBytes <= 0) {
        return null;
      }
      return (processedBytes / totalProcessingBytes).clamp(0, 1).toDouble();
    }
    if (totalObjects <= 0) {
      return null;
    }
    return (progressUnits / totalObjects).clamp(0, 1).toDouble();
  }

  String get overallLabel {
    final value = fraction;
    if (value == null) {
      return switch (stage) {
        BundleDownloadStage.decrypting => '文件解密',
        BundleDownloadStage.merging => '文件合并',
        _ => '读取文件信息',
      };
    }
    if (stage == BundleDownloadStage.decrypting ||
        stage == BundleDownloadStage.merging) {
      final action = stage == BundleDownloadStage.decrypting ? '文件解密' : '文件合并';
      final shardLabel = processingTotalShards > 0
          ? ' · $processedShards/$processingTotalShards 个分片'
          : '';
      return '$action ${(value * 100).toStringAsFixed(1)}%$shardLabel';
    }
    return '${(value * 100).toStringAsFixed(1)}% · '
        '$completedObjects/$totalObjects 个分片';
  }

  String get detailLabel {
    if (stage == BundleDownloadStage.decrypting ||
        stage == BundleDownloadStage.merging) {
      final action = stage == BundleDownloadStage.decrypting ? '解密文件' : '合并文件';
      final processing = totalProcessingBytes <= 0
          ? action
          : '$action ${_formatBytes(processedBytes)} / '
                '${_formatBytes(totalProcessingBytes)} '
                '(${(processedBytes / totalProcessingBytes * 100).clamp(0, 100).toStringAsFixed(1)}%)';
      return <String>[
        '已下载 ${_formatBytes(downloadedBytes)}',
        processing,
        if (processingTotalShards > 0)
          '已处理 $processedShards/$processingTotalShards 个分片',
      ].join(' · ');
    }
    final current = currentShardIndex;
    final currentLabel = current == null || currentObjectLength <= 0
        ? null
        : totalObjects > 0
        ? '当前分片 ${current + 1}/$totalObjects：'
              '${_formatBytes(currentObjectBytes)} / '
              '${_formatBytes(currentObjectLength)} '
              '(${(currentObjectBytes / currentObjectLength * 100).clamp(0, 100).toStringAsFixed(1)}%)'
        : '正在读取文件头：${_formatBytes(currentObjectBytes)} / '
              '${_formatBytes(currentObjectLength)} '
              '(${(currentObjectBytes / currentObjectLength * 100).clamp(0, 100).toStringAsFixed(1)}%)';
    return <String>[
      '已下载 ${_formatBytes(downloadedBytes)}',
      ?currentLabel,
      if (totalObjects > 0) '已完成 $completedObjects/$totalObjects 个分片',
    ].join(' · ');
  }
}

abstract final class BundleSync {
  /// Downloads and stores a complete encrypted Bundle without deriving an
  /// identity or decrypting any plaintext.
  ///
  /// Objects are written to [destination] in continuation-first order and
  /// the root object last, so a local data source never exposes a complete
  /// Bundle marker before all continuation shards have been stored.
  static Future<void> downloadTo({
    required DataSource source,
    required SourcePath rootPath,
    required DataSource destination,
    void Function(BundleDownloadProgress progress)? onProgress,
    BundleDownloadCancellation? cancellation,
  }) async {
    final signal = cancellation ?? BundleDownloadCancellation();
    if (!destination.capabilities.canWrite) {
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        'The destination data source is not writable',
      );
    }
    final objects = await _downloadObjects(
      source: source,
      rootPath: rootPath,
      onProgress: onProgress,
      cancellation: signal,
      emitDecrypting: false,
    );
    for (final name in _publicationOrder(objects.objects.keys)) {
      signal.throwIfCancelled();
      final bytes = objects.objects[name]!;
      await destination.putNew(
        SourcePath(name),
        Stream<List<int>>.value(bytes),
        length: bytes.length,
        sha256: sha256Bytes(bytes),
      );
    }
    signal.throwIfCancelled();
  }

  static Future<DecryptedBundle> fetchAndDecrypt({
    required DataSource source,
    required SourcePath rootPath,
    required String mnemonic,
    PublicIdentity? expectedIdentity,
    void Function(BundleDownloadProgress progress)? onProgress,
    BundleDownloadCancellation? cancellation,
  }) async {
    final signal = cancellation ?? BundleDownloadCancellation();
    final objects = await _downloadObjects(
      source: source,
      rootPath: rootPath,
      onProgress: onProgress,
      cancellation: signal,
      emitDecrypting: true,
    );
    signal.throwIfCancelled();
    final decrypted = await BackgroundBundleCrypto.decrypt(
      objects: objects.objects,
      mnemonic: mnemonic,
      expectedIdentity: expectedIdentity,
      onProgress: objects.reporter.updateDecryption,
    );
    try {
      signal.throwIfCancelled();
      return decrypted;
    } catch (_) {
      decrypted.plaintext.fillRange(0, decrypted.plaintext.length, 0);
      decrypted.preview?.dispose();
      rethrow;
    }
  }

  static Future<void> fetchAndDecryptToFile({
    required DataSource source,
    required SourcePath rootPath,
    required String mnemonic,
    required File destination,
    PublicIdentity? expectedIdentity,
    void Function(BundleDownloadProgress progress)? onProgress,
    BundleDownloadCancellation? cancellation,
  }) => fetchAndDecryptToFileStreaming(
    source: source,
    rootPath: rootPath,
    mnemonic: mnemonic,
    destination: destination,
    expectedIdentity: expectedIdentity,
    onProgress: onProgress,
    cancellation: cancellation,
  );

  /// Downloads ciphertext shards concurrently and performs authentication,
  /// decryption and verified plaintext publication in a background isolate.
  /// Plaintext is never returned to this source layer.
  static Future<void> fetchAndDecryptToFileStreaming({
    required DataSource source,
    required SourcePath rootPath,
    required String mnemonic,
    required File destination,
    PublicIdentity? expectedIdentity,
    void Function(BundleDownloadProgress progress)? onProgress,
    BundleDownloadCancellation? cancellation,
  }) async {
    final signal = cancellation ?? BundleDownloadCancellation();
    final objects = await _downloadObjects(
      source: source,
      rootPath: rootPath,
      onProgress: onProgress,
      cancellation: signal,
      emitDecrypting: true,
    );
    signal.throwIfCancelled();
    await BackgroundBundleCrypto.decryptToFile(
      objects: objects.objects,
      mnemonic: mnemonic,
      destination: destination,
      expectedIdentity: expectedIdentity,
      onProgress: objects.reporter.updateDecryption,
    );
    signal.throwIfCancelled();
  }

  static Future<_DownloadedObjects> _downloadObjects({
    required DataSource source,
    required SourcePath rootPath,
    void Function(BundleDownloadProgress progress)? onProgress,
    required BundleDownloadCancellation cancellation,
    required bool emitDecrypting,
  }) async {
    cancellation.throwIfCancelled();
    if (!source.capabilities.canRead) {
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        'The current data source is not readable',
      );
    }
    final reporter = _DownloadProgressReporter(onProgress);
    final rootRead = await source.get(rootPath);
    cancellation.throwIfCancelled();
    reporter.startObject(shardIndex: 0, length: rootRead.length);
    final rootBytes = await _readObject(
      source,
      rootRead,
      cancellation: cancellation,
      onBytesRead: (count) => reporter.updateObject(0, count),
    );
    cancellation.throwIfCancelled();
    reporter.completeObject(0);
    final rootHeader = BundleHeader.parse(rootBytes);
    validateBundlePathAgainstHeader(rootPath.value, rootHeader);
    if (!rootHeader.isRoot) {
      throw const SboxException(
        SboxErrorCode.rootRequired,
        'A root shard is required',
      );
    }
    reporter.setTotalObjects(rootHeader.shardCount);

    final objects = <String, List<int>>{rootPath.value: rootBytes};
    final paths = <({SourcePath path, int shardIndex})>[
      for (var index = 1; index < rootHeader.shardCount; index++)
        (
          path: SourcePath(
            canonicalBundleBasename(
              bundleId: rootHeader.bundleId,
              shardIndex: index,
              shardCount: rootHeader.shardCount,
            ),
          ),
          shardIndex: index,
        ),
    ];
    await _parallelForEach(
      paths,
      maxParallel: source.capabilities.maxParallelTransfers,
      action: (item) async {
        try {
          cancellation.throwIfCancelled();
          final read = await source.get(item.path);
          cancellation.throwIfCancelled();
          reporter.startObject(
            shardIndex: item.shardIndex,
            length: read.length,
          );
          objects[item.path.value] = await _readObject(
            source,
            read,
            cancellation: cancellation,
            onBytesRead: (count) =>
                reporter.updateObject(item.shardIndex, count),
          );
          cancellation.throwIfCancelled();
          reporter.completeObject(item.shardIndex);
        } on SboxException catch (error) {
          if (error.code == SboxErrorCode.sourceNotFound) {
            throw const SboxException(
              SboxErrorCode.shardMissing,
              'Bundle is missing a continuation shard',
            );
          }
          rethrow;
        }
      },
    );
    cancellation.throwIfCancelled();
    if (emitDecrypting) reporter.emitDecrypting();
    return _DownloadedObjects(objects: objects, reporter: reporter);
  }

  static Future<List<RevisionToken>> publish(
    DataSource source,
    EncryptedBundle bundle,
  ) async {
    if (!source.capabilities.canWrite) {
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        'The current data source is not writable',
      );
    }
    if (source.capabilities.maxObjectBytes != null &&
        bundle.objects.any(
          (object) => object.bytes.length > source.capabilities.maxObjectBytes!,
        )) {
      throw const SboxException(
        SboxErrorCode.sourceLimit,
        'An object exceeds the data source limit',
      );
    }
    final continuation = bundle.objects
        .where((object) => !object.header.isRoot)
        .toList();
    continuation.sort(
      (left, right) =>
          left.header.shardIndex.compareTo(right.header.shardIndex),
    );
    final revisions = await _parallelMap(
      continuation,
      maxParallel: source.capabilities.maxParallelTransfers,
      action: (object) => _put(source, object),
    );
    // The root object is the immutable Bundle commit marker.
    revisions.add(await _put(source, bundle.root));
    return List<RevisionToken>.unmodifiable(revisions);
  }

  static Future<void> delete(
    DataSource source,
    Iterable<({SourcePath path, RevisionToken revision, bool isRoot})> objects,
  ) async {
    final list = objects.toList(growable: false);
    final roots = list.where((object) => object.isRoot).toList(growable: false);
    if (roots.length != 1) {
      throw const SboxException(
        SboxErrorCode.rootRequired,
        'Deleting a Bundle requires exactly one root object',
      );
    }
    await source.deleteIfMatch(roots.single.path, roots.single.revision);
    for (final object in list.where((object) => !object.isRoot)) {
      await source.deleteIfMatch(object.path, object.revision);
    }
  }

  static Future<RevisionToken> _put(
    DataSource source,
    EncryptedBundleObject object,
  ) => source.putNew(
    SourcePath(object.basename),
    Stream<List<int>>.value(object.bytes),
    length: object.bytes.length,
    sha256: object.sha256,
  );

  static Future<Uint8List> _readObject(
    DataSource source,
    SourceRead read, {
    required BundleDownloadCancellation cancellation,
    void Function(int bytesRead)? onBytesRead,
  }) async {
    cancellation.throwIfCancelled();
    if (read.notModified ||
        read.length < 0 ||
        (source.capabilities.maxObjectBytes != null &&
            read.length > source.capabilities.maxObjectBytes!)) {
      throw const SboxException(
        SboxErrorCode.remoteChanged,
        'The remote object length is not acceptable',
      );
    }
    final output = BytesBuilder(copy: false);
    var count = 0;
    await for (final chunk in _cancelOnSignal(read.body, cancellation)) {
      count += chunk.length;
      if (count > read.length) {
        throw const SboxException(
          SboxErrorCode.remoteChanged,
          'The remote object is longer than declared',
        );
      }
      output.add(chunk);
      onBytesRead?.call(count);
    }
    cancellation.throwIfCancelled();
    if (count != read.length) {
      throw const SboxException(
        SboxErrorCode.remoteChanged,
        'The remote object is incomplete',
      );
    }
    return output.takeBytes();
  }
}

List<String> _publicationOrder(Iterable<String> names) {
  final parsed = names.map((name) {
    final info = parseCanonicalBundleBasename(name);
    return (name: name, root: info.shardIndex == 0, index: info.shardIndex);
  }).toList();
  parsed.sort((left, right) {
    if (left.root != right.root) return left.root ? 1 : -1;
    return left.index.compareTo(right.index);
  });
  return List<String>.unmodifiable(parsed.map((item) => item.name));
}

Stream<List<int>> _cancelOnSignal(
  Stream<List<int>> source,
  BundleDownloadCancellation cancellation,
) {
  late final StreamController<List<int>> controller;
  StreamSubscription<List<int>>? subscription;
  var stopped = false;
  void Function() unregister = () {};

  void stop({Object? error, StackTrace? stackTrace}) {
    if (stopped) return;
    stopped = true;
    unregister();
    final current = subscription;
    if (current != null) unawaited(current.cancel());
    if (error != null) controller.addError(error, stackTrace);
    unawaited(controller.close());
  }

  controller = StreamController<List<int>>(
    sync: true,
    onListen: () {
      if (stopped) return;
      if (cancellation.isCancelled) {
        stop(error: const SboxException(SboxErrorCode.cancelled, '下载已取消'));
        return;
      }
      subscription = source.listen(
        controller.add,
        onError: (Object error, StackTrace stackTrace) {
          if (stopped) return;
          stopped = true;
          unregister();
          final current = subscription;
          if (current != null) unawaited(current.cancel());
          controller.addError(error, stackTrace);
          unawaited(controller.close());
        },
        onDone: () => stop(),
        cancelOnError: false,
      );
    },
    onCancel: () async {
      if (stopped) return;
      stopped = true;
      unregister();
      await subscription?.cancel();
    },
  );
  unregister = cancellation.registerOnCancel(() {
    stop(error: const SboxException(SboxErrorCode.cancelled, '下载已取消'));
  });
  return controller.stream;
}

final class _DownloadProgressReporter {
  _DownloadProgressReporter(this.onProgress);

  final void Function(BundleDownloadProgress progress)? onProgress;
  final Map<int, ({int bytes, int length})> _active =
      <int, ({int bytes, int length})>{};
  int _downloadedBytes = 0;
  int _completedObjects = 0;
  int _totalObjects = 0;
  int? _currentShardIndex;
  int _processedBytes = 0;
  int _totalProcessingBytes = 0;
  int _processedShards = 0;
  int _processingTotalShards = 0;
  int? _processingCurrentShardIndex;

  void startObject({required int shardIndex, required int length}) {
    _active[shardIndex] = (bytes: 0, length: length);
    _currentShardIndex = shardIndex;
    _emit();
  }

  void updateObject(int shardIndex, int bytesRead) {
    final active = _active[shardIndex];
    if (active == null) return;
    final bytes = bytesRead.clamp(0, active.length).toInt();
    _downloadedBytes += bytes - active.bytes;
    _active[shardIndex] = (bytes: bytes, length: active.length);
    _currentShardIndex = shardIndex;
    _emit();
  }

  void completeObject(int shardIndex) {
    final active = _active.remove(shardIndex);
    if (active == null) return;
    _downloadedBytes += active.length - active.bytes;
    _completedObjects++;
    _currentShardIndex = _active.isEmpty ? null : _active.keys.first;
    _emit();
  }

  void setTotalObjects(int totalObjects) {
    _totalObjects = totalObjects < 0 ? 0 : totalObjects;
    _emit();
  }

  void emitDecrypting() {
    _processedBytes = 0;
    _totalProcessingBytes = 0;
    _processedShards = 0;
    _processingTotalShards = 0;
    _processingCurrentShardIndex = null;
    _emit(stage: BundleDownloadStage.decrypting);
  }

  void updateDecryption(BundleDecryptionProgress progress) {
    _processedBytes = progress.processedBytes;
    _totalProcessingBytes = progress.totalBytes;
    _processedShards = progress.completedShards;
    _processingTotalShards = progress.totalShards;
    _processingCurrentShardIndex = progress.currentShardIndex;
    _emit(
      stage: progress.stage == BundleDecryptionStage.merging
          ? BundleDownloadStage.merging
          : BundleDownloadStage.decrypting,
    );
  }

  void _emit({BundleDownloadStage? stage}) {
    final callback = onProgress;
    if (callback == null) return;
    final effectiveStage =
        stage ??
        (_totalObjects == 0
            ? BundleDownloadStage.preparing
            : BundleDownloadStage.downloading);
    final progress = _progressUnits;
    final current = _currentShardIndex == null
        ? null
        : _active[_currentShardIndex!];
    final processing =
        effectiveStage == BundleDownloadStage.decrypting ||
        effectiveStage == BundleDownloadStage.merging;
    try {
      callback(
        BundleDownloadProgress(
          stage: effectiveStage,
          downloadedBytes: _downloadedBytes,
          completedObjects: _completedObjects,
          totalObjects: _totalObjects,
          progressUnits: progress,
          currentShardIndex: processing
              ? _processingCurrentShardIndex
              : _currentShardIndex,
          currentObjectBytes: processing ? 0 : current?.bytes ?? 0,
          currentObjectLength: processing ? 0 : current?.length ?? 0,
          processedBytes: _processedBytes,
          totalProcessingBytes: _totalProcessingBytes,
          processedShards: _processedShards,
          processingTotalShards: _processingTotalShards,
        ),
      );
    } on Object {
      // UI progress must never be able to interrupt a download.
    }
  }

  double get _progressUnits {
    var value = _completedObjects.toDouble();
    for (final object in _active.values) {
      if (object.length > 0) {
        value += (object.bytes / object.length).clamp(0, 1);
      }
    }
    return value;
  }
}

final class _DownloadedObjects {
  const _DownloadedObjects({required this.objects, required this.reporter});

  final Map<String, List<int>> objects;
  final _DownloadProgressReporter reporter;
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

Future<List<R>> _parallelMap<T, R>(
  Iterable<T> values, {
  required int maxParallel,
  required Future<R> Function(T value) action,
}) async {
  final items = values.toList(growable: false);
  if (items.isEmpty) return <R>[];
  final results = List<R?>.filled(items.length, null);
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
      results[index] = await action(items[index]);
    }
  }

  await Future.wait(<Future<void>>[
    for (var index = 0; index < workerCount; index++) worker(),
  ]);
  return <R>[for (final result in results) result as R];
}
