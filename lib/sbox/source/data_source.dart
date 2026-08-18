import 'dart:typed_data';

import '../bytes.dart';
import 'source_path.dart';

final class SourceCapabilities {
  const SourceCapabilities({
    required this.canRead,
    required this.canWrite,
    required this.canDelete,
    required this.canListObjects,
    required this.supportsRangeRead,
    required this.maxObjectBytes,
    required this.maxParallelTransfers,
  });

  final bool canRead;
  final bool canWrite;
  final bool canDelete;
  final bool canListObjects;
  final bool supportsRangeRead;
  final int? maxObjectBytes;
  final int maxParallelTransfers;
}

final class RevisionToken {
  RevisionToken(List<int> bytes) : bytes = Uint8List.fromList(bytes);

  final Uint8List bytes;

  bool matches(RevisionToken other) =>
      constantTimeBytesEqual(bytes, other.bytes);
}

final class SourceRead {
  const SourceRead({
    required this.body,
    required this.length,
    required this.revision,
    this.notModified = false,
  });

  final Stream<List<int>> body;
  final int length;
  final RevisionToken revision;
  final bool notModified;
}

final class SourceObjectInfo {
  const SourceObjectInfo({
    required this.path,
    required this.length,
    required this.revision,
    this.downloadUri,
  });

  final SourcePath path;
  final int length;
  final RevisionToken revision;
  final Uri? downloadUri;
}

final class SourceListPage {
  const SourceListPage({required this.objects, required this.nextCursor});

  final List<SourceObjectInfo> objects;
  final String? nextCursor;
}

abstract interface class DataSource {
  SourceCapabilities get capabilities;

  Future<SourceRead> get(SourcePath path, {RevisionToken? ifNoneMatch});

  Future<RevisionToken> putNew(
    SourcePath path,
    Stream<List<int>> body, {
    required int length,
    required Uint8List sha256,
  });

  Future<void> deleteIfMatch(SourcePath path, RevisionToken expected);
}

abstract interface class EnumerableDataSource implements DataSource {
  Future<SourceListPage> listObjects({String? cursor, int pageSize = 1000});
}

abstract interface class RangeReadableDataSource implements DataSource {
  Future<SourceRead> getRange(
    SourcePath path, {
    required int start,
    required int endExclusive,
    SourceObjectInfo? objectInfo,
  });
}
