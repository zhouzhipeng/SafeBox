import '../errors.dart';

enum SboxJobPhase {
  queued,
  preparing,
  scanningLocalDirectory,
  planningParts,
  reading,
  encryptingPart,
  committingLocalCiphertext,
  downloadingParts,
  authenticatingParts,
  reassembling,
  uploadingPart,
  committingCatalog,
  publishing,
  completed,
  cancelling,
  cancelled,
  failed,
}

final class SboxJobProgress {
  const SboxJobProgress({
    required this.phase,
    required this.processedBytes,
    this.totalBytes,
    this.partIndex = 0,
    this.partCount = 1,
    this.safeMessage = '',
  });

  final SboxJobPhase phase;
  final int processedBytes;
  final int? totalBytes;
  final int partIndex;
  final int partCount;
  final String safeMessage;
}

typedef SboxProgressCallback = void Function(SboxJobProgress progress);

/// Idempotent cooperative cancellation for work performed inside a crypto
/// isolate. The isolate owner remains responsible for force-killing stalled
/// work and deleting its staged output.
final class JobControl {
  JobControl({this.onProgress});

  final SboxProgressCallback? onProgress;
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }

  void checkCancelled() {
    if (_cancelled) {
      throw const SboxException(SboxErrorCode.cancelled, '操作已取消');
    }
  }

  void report(SboxJobProgress progress) {
    checkCancelled();
    onProgress?.call(progress);
  }
}
