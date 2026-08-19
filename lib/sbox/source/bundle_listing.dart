import 'dart:typed_data';

import '../bytes.dart';
import '../constants.dart';
import '../engine/background_bundle_crypto.dart';
import '../engine/bundle_probe.dart';
import '../errors.dart';
import '../format/bundle_header.dart';
import '../format/bundle_manifest.dart';
import '../format/bundle_path.dart';
import '../format/bundle_preview.dart';
import '../identity/rsa_models.dart';
import '../storage/local_bundle_index.dart';
import 'data_source.dart';
import 'source_path.dart';

final class ListedBundleRoot {
  const ListedBundleRoot({
    required this.path,
    required this.info,
    required this.header,
    this.manifest,
    this.preview,
    bool? hasPreview,
    this.status = BundleTrustStatus.headerOnly,
    this.isCached = false,
  }) : hasPreview = hasPreview ?? preview != null;

  final SourcePath path;
  final SourceObjectInfo info;
  final BundleHeader header;
  final BundleManifest? manifest;
  final BundlePreview? preview;
  final bool hasPreview;
  final BundleTrustStatus status;
  final bool isCached;
}

abstract final class BundleListing {
  /// Lists all roots and calls [onRoot] as each valid root is decoded.
  ///
  /// The callback is useful for UIs that should publish the first few files
  /// without waiting for the complete repository scan.
  static Future<List<ListedBundleRoot>> listRoots(
    EnumerableDataSource source, {
    int pageSize = 1000,
    PublicIdentity? identity,
    int? maxParallelTransfers,
    int? initialRootLimit,
    int maxRetainedPreviewBytes = SboxProtocol.maxRetainedPreviewBytes,
    bool includePreview = true,
    LocalBundleIndex? metadataCache,
    void Function(ListedBundleRoot root)? onRoot,
    void Function(SourceObjectInfo object)? onObject,
  }) async {
    if (!source.capabilities.canListObjects ||
        !source.capabilities.supportsRangeRead) {
      throw const SboxException(
        SboxErrorCode.listingUnsupported,
        '当前数据源不支持对象列举',
      );
    }
    if (source is! RangeReadableDataSource) {
      throw const SboxException(
        SboxErrorCode.listingUnsupported,
        '当前数据源不支持范围读取',
      );
    }
    if (maxRetainedPreviewBytes < 0) {
      throw ArgumentError.value(
        maxRetainedPreviewBytes,
        'maxRetainedPreviewBytes',
      );
    }
    if (initialRootLimit != null && initialRootLimit < 1) {
      throw ArgumentError.value(initialRootLimit, 'initialRootLimit');
    }
    final rangeSource = source as RangeReadableDataSource;
    final cachedByBundleId = <String, LocalBundleIndexEntry>{
      for (final entry
          in metadataCache?.entries ?? const <LocalBundleIndexEntry>[])
        entry.bundleId: entry,
    };
    var roots = <ListedBundleRoot>[];
    var retainedPreviewBytes = 0;
    final seenPaths = <String>{};
    final parallelism =
        (maxParallelTransfers ?? source.capabilities.maxParallelTransfers)
            .clamp(1, SboxProtocol.defaultMaxParallelTransfers);
    var initialRootsRead = 0;
    SboxException? recoverableCandidateError;
    String? cursor;
    do {
      final page = await source.listObjects(cursor: cursor, pageSize: pageSize);
      final candidates = <SourceObjectInfo>[];
      for (var index = 0; index < page.objects.length; index++) {
        final info = page.objects[index];
        if (info.path.value.endsWith('.sbox')) onObject?.call(info);
        if (!seenPaths.add(info.path.value)) {
          throw const SboxException(SboxErrorCode.shardConflict, '数据源返回重复对象路径');
        }
        if (seenPaths.length > SboxProtocol.maxCandidateObjects) {
          throw const SboxException(SboxErrorCode.sourceLimit, '候选对象超过安全上限');
        }
        BundlePathInfo path;
        try {
          path = parseCanonicalBundleBasename(info.path.value);
        } on SboxException {
          continue;
        }
        if (path.shardIndex == 0) {
          // A repository can contain objects written by an older SafeBox
          // version (or a partial upload).  When the provider gives us an
          // exact size, avoid a range request that cannot possibly contain a
          // v3 root header.  Gitee may omit the size, so zero means unknown.
          if (info.length == 0 ||
              info.length >= SboxProtocol.rootHeaderLength) {
            candidates.add(info);
          }
        }
        if ((index + 1) % 64 == 0) {
          // Parsing a provider page is synchronous work on the UI isolate.
          // Keep long listings cooperative with pointer and scroll events.
          await Future<void>.delayed(Duration.zero);
        }
      }

      Future<void> readCandidate(SourceObjectInfo info) async {
        late final ListedBundleRoot root;
        try {
          final path = parseCanonicalBundleBasename(info.path.value);
          root = await _readRoot(
            rangeSource,
            info,
            identity: identity,
            includePreview: includePreview,
            cachedEntry: cachedByBundleId[path.bundleId],
          );
        } on SboxException catch (error) {
          if (_isIgnorableCandidateError(error.code)) return;
          if (_isRecoverableCandidateError(error.code)) {
            // A provider may reject one raw object (for example a large
            // public Gitee object) while the rest of the repository is
            // readable. Do not discard roots already found for the page.
            recoverableCandidateError ??= error;
            return;
          }
          rethrow;
        }
        final preview = root.preview;
        if (preview == null ||
            preview.encodedLength <=
                maxRetainedPreviewBytes - retainedPreviewBytes) {
          if (preview != null) retainedPreviewBytes += preview.encodedLength;
          roots.add(root);
          initialRootsRead++;
          onRoot?.call(root);
          return;
        }
        preview.dispose();
        final withoutPreview = ListedBundleRoot(
          path: root.path,
          info: root.info,
          header: root.header,
          manifest: root.manifest,
          hasPreview: true,
          status: root.status,
          isCached: root.isCached,
        );
        roots.add(withoutPreview);
        initialRootsRead++;
        onRoot?.call(withoutPreview);
      }

      // The home page only needs a small first window. Keep the first window
      // bounded before starting the rest of this page in the background. The
      // source listing itself is still consumed completely so search and the
      // final result remain complete.
      final initialLimit = initialRootLimit == null
          ? null
          : initialRootLimit - initialRootsRead;
      final firstWindow = initialLimit == null || initialLimit <= 0
          ? candidates
          : candidates.take(initialLimit);
      await _parallelForEach<SourceObjectInfo>(
        firstWindow,
        maxParallel: parallelism,
        action: readCandidate,
      );
      if (firstWindow.length < candidates.length) {
        await _parallelForEach<SourceObjectInfo>(
          candidates.skip(firstWindow.length),
          maxParallel: parallelism,
          action: readCandidate,
        );
      }
      cursor = page.nextCursor;
      // Cache hits can complete without a real I/O suspension. Yield between
      // pages so a large source cannot starve Flutter input and frame events.
      await Future<void>.delayed(Duration.zero);
    } while (cursor != null);
    final listingError = recoverableCandidateError;
    if (roots.isEmpty && listingError != null) throw listingError;
    roots.sort((left, right) => left.path.value.compareTo(right.path.value));
    return List<ListedBundleRoot>.unmodifiable(roots);
  }

  static Future<ListedBundleRoot> _readRoot(
    RangeReadableDataSource source,
    SourceObjectInfo info, {
    required PublicIdentity? identity,
    required bool includePreview,
    LocalBundleIndexEntry? cachedEntry,
  }) async {
    final path = parseCanonicalBundleBasename(info.path.value);
    final prefix = await source.getRange(
      info.path,
      start: 0,
      endExclusive: SboxProtocol.rootHeaderLength,
      objectInfo: info,
    );
    if (prefix.notModified || prefix.length != SboxProtocol.rootHeaderLength) {
      throw const SboxException(SboxErrorCode.remoteChanged, '公共头范围响应长度无效');
    }
    final headerBytes = await _readExact(prefix.body, prefix.length);
    final header = BundleHeader.parse(headerBytes);
    if (!header.isRoot || header.canonicalBasename != info.path.value) {
      throw const SboxException(SboxErrorCode.shardMismatch, '对象路径与公共头不一致');
    }
    if (path.shardIndex != 0) {
      throw const SboxException(SboxErrorCode.shardMismatch, '根对象路径无效');
    }
    final cached = cachedEntry;
    ListedBundleRoot? cachedRoot;
    if (cached != null &&
        cached.rootRevisionFingerprint == hexLower(info.revision.bytes) &&
        cached.manifestPrefixSha256 == hexLower(header.hash)) {
      try {
        cached.manifest.validateAgainstHeader(header);
        final cachedPreview = includePreview ? cached.preview?.copy() : null;
        cachedRoot = ListedBundleRoot(
          path: info.path,
          info: info,
          header: header,
          manifest: cached.manifest,
          preview: cachedPreview,
          hasPreview: cached.hasPreview,
          status: BundleTrustStatus.metadataReadable,
        );
        // A cached JPG is bound to this unchanged root by the revision and
        // Manifest-prefix hashes above. Reuse it instead of decrypting the
        // Metadata Block again when previews are enabled.
        if (!includePreview || identity == null || cachedPreview != null) {
          return cachedRoot;
        }
      } on SboxException {
        // A stale or corrupted cache entry is only a performance miss. Fall
        // through to the authenticated Metadata read below.
      }
    }
    if (identity == null) {
      return cachedRoot ??
          ListedBundleRoot(path: info.path, info: info, header: header);
    }
    try {
      final result = await BackgroundBundleCrypto.readManifest(
        basename: info.path.value,
        objectPrefix: headerBytes,
        identity: identity,
      );
      final preview = result.preview;
      if (!includePreview) preview?.dispose();
      return ListedBundleRoot(
        path: info.path,
        info: info,
        header: header,
        manifest: result.manifest,
        preview: includePreview ? preview : null,
        hasPreview: result.preview != null,
        status: result.status,
      );
    } on SboxException {
      // A public key that does not match this recipient, or an unreadable
      // Metadata block, does not make the public object disappear from the
      // library. It remains a headerOnly candidate.
      return cachedRoot ??
          ListedBundleRoot(path: info.path, info: info, header: header);
    }
  }

  static bool _isIgnorableCandidateError(SboxErrorCode code) => switch (code) {
    SboxErrorCode.invalidHeader ||
    SboxErrorCode.unsupportedVersion ||
    SboxErrorCode.truncated ||
    SboxErrorCode.shardMismatch ||
    SboxErrorCode.sourceNotFound ||
    SboxErrorCode.remoteChanged => true,
    _ => false,
  };

  static bool _isRecoverableCandidateError(SboxErrorCode code) =>
      switch (code) {
        SboxErrorCode.sourceAuthentication ||
        SboxErrorCode.sourceNetwork => true,
        _ => false,
      };

  static Future<Uint8List> _readExact(
    Stream<List<int>> body,
    int length,
  ) async {
    final output = BytesBuilder(copy: false);
    var count = 0;
    await for (final chunk in body) {
      count += chunk.length;
      if (count > length) {
        throw const SboxException(SboxErrorCode.remoteChanged, '公共头范围响应过长');
      }
      output.add(chunk);
    }
    if (count != length) {
      throw const SboxException(SboxErrorCode.truncated, '公共头范围响应不完整');
    }
    return output.takeBytes();
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
    var completed = 0;
    while (true) {
      if (next >= items.length) return;
      final index = next++;
      await action(items[index]);
      completed++;
      if (completed % 8 == 0) {
        // Awaiting an already-completed Future only queues a microtask. Yield
        // to the event queue periodically so pointer and scroll events run.
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  await Future.wait(<Future<void>>[
    for (var index = 0; index < workerCount; index++) worker(),
  ]);
}
