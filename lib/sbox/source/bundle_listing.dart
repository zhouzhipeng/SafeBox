import 'dart:typed_data';

import '../constants.dart';
import '../engine/background_bundle_crypto.dart';
import '../engine/bundle_probe.dart';
import '../errors.dart';
import '../format/bundle_header.dart';
import '../format/bundle_manifest.dart';
import '../format/bundle_path.dart';
import '../format/bundle_preview.dart';
import '../identity/rsa_models.dart';
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
  }) : hasPreview = hasPreview ?? preview != null;

  final SourcePath path;
  final SourceObjectInfo info;
  final BundleHeader header;
  final BundleManifest? manifest;
  final BundlePreview? preview;
  final bool hasPreview;
  final BundleTrustStatus status;
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
    int maxRetainedPreviewBytes = SboxProtocol.maxRetainedPreviewBytes,
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
    final rangeSource = source as RangeReadableDataSource;
    var roots = <ListedBundleRoot>[];
    var retainedPreviewBytes = 0;
    final seenPaths = <String>{};
    final parallelism =
        (maxParallelTransfers ?? source.capabilities.maxParallelTransfers)
            .clamp(1, SboxProtocol.defaultMaxParallelTransfers);
    SboxException? recoverableCandidateError;
    String? cursor;
    do {
      final page = await source.listObjects(cursor: cursor, pageSize: pageSize);
      final candidates = <SourceObjectInfo>[];
      for (final info in page.objects) {
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
      }

      for (var offset = 0; offset < candidates.length; offset += parallelism) {
        final end = (offset + parallelism).clamp(0, candidates.length);
        final batch = candidates.sublist(offset, end);
        final results = await Future.wait<ListedBundleRoot?>(
          batch.map((info) async {
            try {
              return await _readRoot(rangeSource, info, identity: identity);
            } on SboxException catch (error) {
              if (_isIgnorableCandidateError(error.code)) return null;
              if (_isRecoverableCandidateError(error.code)) {
                // A provider may reject one raw object (for example a large
                // public Gitee object) while the rest of the repository is
                // readable. Do not discard roots already found for the page.
                recoverableCandidateError ??= error;
                return null;
              }
              rethrow;
            }
          }),
        );
        for (final root in results.whereType<ListedBundleRoot>()) {
          final preview = root.preview;
          if (preview == null ||
              preview.encodedLength <=
                  maxRetainedPreviewBytes - retainedPreviewBytes) {
            if (preview != null) retainedPreviewBytes += preview.encodedLength;
            roots.add(root);
            onRoot?.call(root);
            continue;
          }
          preview.dispose();
          final withoutPreview = ListedBundleRoot(
            path: root.path,
            info: root.info,
            header: root.header,
            manifest: root.manifest,
            hasPreview: true,
            status: root.status,
          );
          roots.add(withoutPreview);
          onRoot?.call(withoutPreview);
        }
      }
      cursor = page.nextCursor;
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
    if (identity == null) {
      return ListedBundleRoot(path: info.path, info: info, header: header);
    }
    try {
      final result = await BackgroundBundleCrypto.readManifest(
        basename: info.path.value,
        objectPrefix: headerBytes,
        identity: identity,
      );
      return ListedBundleRoot(
        path: info.path,
        info: info,
        header: header,
        manifest: result.manifest,
        preview: result.preview,
        status: result.status,
      );
    } on SboxException {
      // A public key that does not match this recipient, or an unreadable
      // Metadata block, does not make the public object disappear from the
      // library. It remains a headerOnly candidate.
      return ListedBundleRoot(path: info.path, info: info, header: header);
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
