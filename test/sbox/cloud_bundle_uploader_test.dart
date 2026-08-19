import 'package:safebox/sbox/source/cloud_bundle_uploader.dart';
import 'package:safebox/sbox/errors.dart';
import 'package:test/test.dart';

void main() {
  test('upload progress reserves 100 percent for the terminal event', () {
    const sources = <String, CloudBundleSourceProgress>{
      'GitHub': CloudBundleSourceProgress(
        sourceName: 'GitHub',
        completedShards: 22,
        totalShards: 22,
      ),
      'Gitee': CloudBundleSourceProgress(
        sourceName: 'Gitee',
        completedShards: 22,
        totalShards: 22,
      ),
    };

    const uploading = CloudBundleUploadProgress(
      stage: CloudBundleUploadStage.uploading,
      sources: sources,
    );
    expect(uploading.isComplete, isFalse);
    expect(uploading.fraction, lessThan(1));
    expect(uploading.overallLabel, '44/44（正在核对）');

    const completed = CloudBundleUploadProgress(
      stage: CloudBundleUploadStage.completed,
      sources: sources,
    );
    expect(completed.isComplete, isTrue);
    expect(completed.fraction, 1);
    expect(completed.overallLabel, '44/44 (100.0%)');
  });

  test('upload cancellation exposes a stable cancelled error', () {
    final cancellation = CloudBundleUploadCancellation();
    var cleanupCalls = 0;
    final unregister = cancellation.registerOnCancel(() => cleanupCalls++);

    expect(cancellation.isCancelled, isFalse);
    cancellation.cancel();
    expect(cancellation.isCancelled, isTrue);
    expect(cleanupCalls, 1);
    unregister();
    cancellation.cancel();
    expect(cleanupCalls, 1);
    expect(
      cancellation.throwIfCancelled,
      throwsA(
        isA<SboxException>().having(
          (error) => error.code,
          'code',
          SboxErrorCode.cancelled,
        ),
      ),
    );
  });
}
