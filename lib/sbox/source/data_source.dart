import 'dart:typed_data';

import '../bytes.dart';
import 'source_path.dart';

enum UploadEncoding { binary, base64Json }

final class SourceCapabilities {
  const SourceCapabilities({
    required this.canRead,
    required this.canWrite,
    required this.canDelete,
    required this.conditionalWrite,
    required this.history,
    required this.maxObjectBytes,
    required this.maxRequestBodyBytes,
    required this.uploadEncoding,
    required this.maxParallelObjectTransfers,
    required this.supportsStreamingDownload,
    required this.supportsResumableObjectDownload,
  }) : assert(
         maxParallelObjectTransfers >= 1 && maxParallelObjectTransfers <= 4,
       );

  final bool canRead;
  final bool canWrite;
  final bool canDelete;
  final bool conditionalWrite;
  final bool history;
  final BigInt? maxObjectBytes;
  final BigInt? maxRequestBodyBytes;
  final UploadEncoding uploadEncoding;
  final int maxParallelObjectTransfers;
  final bool supportsStreamingDownload;
  final bool supportsResumableObjectDownload;

  static const localReadWrite = SourceCapabilities(
    canRead: true,
    canWrite: true,
    canDelete: true,
    conditionalWrite: true,
    history: false,
    maxObjectBytes: null,
    maxRequestBodyBytes: null,
    uploadEncoding: UploadEncoding.binary,
    maxParallelObjectTransfers: 4,
    supportsStreamingDownload: true,
    supportsResumableObjectDownload: true,
  );
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

abstract interface class DataSource {
  SourceCapabilities get capabilities;

  Future<SourceRead> get(SourcePath path, {RevisionToken? ifNoneMatch});

  Future<RevisionToken> putNew(
    SourcePath path,
    Stream<List<int>> body, {
    required int length,
    required Uint8List sha256,
  });

  Future<RevisionToken> compareAndSwap(
    SourcePath path,
    RevisionToken expected,
    Stream<List<int>> body, {
    required int length,
  });

  Future<void> deleteIfMatch(SourcePath path, RevisionToken expected);
}
