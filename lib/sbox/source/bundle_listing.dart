import 'dart:typed_data';

import '../errors.dart';
import '../format/bundle_header.dart';
import '../format/bundle_path.dart';
import 'data_source.dart';
import 'source_path.dart';

final class ListedBundleRoot {
  const ListedBundleRoot({
    required this.path,
    required this.info,
    required this.header,
  });

  final SourcePath path;
  final SourceObjectInfo info;
  final BundleHeader header;
}

abstract final class BundleListing {
  static Future<List<ListedBundleRoot>> listRoots(
    EnumerableDataSource source, {
    int pageSize = 1000,
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
    final rangeSource = source as RangeReadableDataSource;
    final roots = <ListedBundleRoot>[];
    final seenPaths = <String>{};
    String? cursor;
    do {
      final page = await source.listObjects(cursor: cursor, pageSize: pageSize);
      for (final info in page.objects) {
        if (!seenPaths.add(info.path.value)) {
          throw const SboxException(SboxErrorCode.shardConflict, '数据源返回重复对象路径');
        }
        BundlePathInfo path;
        try {
          path = parseCanonicalBundleBasename(info.path.value);
        } on SboxException {
          continue;
        }
        if (path.shardIndex != 0) continue;
        final prefix = await rangeSource.getRange(
          info.path,
          start: 0,
          endExclusive: path.shardCount == 1 ? 512 : 512,
        );
        final headerBytes = await _readAtMost(prefix.body, prefix.length);
        final header = BundleHeader.parse(headerBytes);
        if (!header.isRoot) continue;
        if (header.canonicalBasename != info.path.value) {
          throw const SboxException(SboxErrorCode.shardMismatch, '对象路径与公共头不一致');
        }
        roots.add(
          ListedBundleRoot(path: info.path, info: info, header: header),
        );
      }
      cursor = page.nextCursor;
    } while (cursor != null);
    roots.sort((left, right) => left.path.value.compareTo(right.path.value));
    return List<ListedBundleRoot>.unmodifiable(roots);
  }

  static Future<Uint8List> _readAtMost(
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
    return output.takeBytes();
  }
}
