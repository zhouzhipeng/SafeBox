import 'dart:math' as math;

import '../constants.dart';
import '../errors.dart';

final class BundleShardPlan {
  const BundleShardPlan({
    required this.index,
    required this.offset,
    required this.length,
  });

  final int index;
  final int offset;
  final int length;
}

final class BundlePlan {
  const BundlePlan({
    required this.logicalLength,
    required this.nominalShardPlaintextSize,
    required this.shards,
  });

  final int logicalLength;
  final int nominalShardPlaintextSize;
  final List<BundleShardPlan> shards;

  int get shardCount => shards.length;
  bool get isMultipart => shardCount > 1;
}

abstract final class BundlePlanner {
  static int dataRecordCount(int plaintextLength) {
    if (plaintextLength < 0) throw ArgumentError.value(plaintextLength);
    if (plaintextLength == 0) return 0;
    return (plaintextLength + SboxProtocol.chunkSize - 1) ~/
        SboxProtocol.chunkSize;
  }

  static int continuationUpperBound(int plaintextLength) {
    return 128 + plaintextLength + 29 * dataRecordCount(plaintextLength) + 77;
  }

  static int rootUpperBound(int plaintextLength, int manifestLength) {
    return 512 +
        manifestLength +
        29 +
        plaintextLength +
        29 * dataRecordCount(plaintextLength) +
        77;
  }

  static BundlePlan plan({
    required int logicalLength,
    int targetNominalShardPlaintextSize =
        SboxProtocol.defaultNominalShardPlaintextSize,
    int? maxObjectBytes,
    int manifestLength = SboxProtocol.maxManifestBytes,
  }) {
    if (logicalLength < 0 ||
        targetNominalShardPlaintextSize <
            SboxProtocol.minNominalShardPlaintextSize ||
        targetNominalShardPlaintextSize >
            SboxProtocol.maxNominalShardPlaintextSize ||
        targetNominalShardPlaintextSize % (1024 * 1024) != 0 ||
        manifestLength < 1 ||
        manifestLength > SboxProtocol.maxManifestBytes) {
      throw const SboxException(
        SboxErrorCode.sourceLimit,
        '分片大小或 Manifest 大小无效',
      );
    }
    final unit = 1024 * 1024;
    final candidates = <int>[];
    for (
      var candidate = SboxProtocol.minNominalShardPlaintextSize;
      candidate <= SboxProtocol.maxNominalShardPlaintextSize;
      candidate += unit
    ) {
      final count = logicalLength == 0
          ? 1
          : (logicalLength + candidate - 1) ~/ candidate;
      if (count > SboxProtocol.maxShardCount) continue;
      if (maxObjectBytes != null &&
          (rootUpperBound(math.min(candidate, logicalLength), manifestLength) >
                  maxObjectBytes ||
              (count > 1 &&
                  continuationUpperBound(math.min(candidate, logicalLength)) >
                      maxObjectBytes))) {
        continue;
      }
      candidates.add(candidate);
    }
    if (candidates.isEmpty) {
      throw const SboxException(SboxErrorCode.sourceLimit, '数据源无法容纳规范 SBOX 分片');
    }
    final belowOrEqual = candidates
        .where((candidate) => candidate <= targetNominalShardPlaintextSize)
        .toList(growable: false);
    final selected = belowOrEqual.isNotEmpty
        ? belowOrEqual.last
        : candidates.first;
    final count = logicalLength == 0
        ? 1
        : (logicalLength + selected - 1) ~/ selected;
    final shards = <BundleShardPlan>[
      for (var index = 0; index < count; index++)
        BundleShardPlan(
          index: index,
          offset: index * selected,
          length: math.min(selected, logicalLength - index * selected),
        ),
    ];
    return BundlePlan(
      logicalLength: logicalLength,
      nominalShardPlaintextSize: selected,
      shards: List<BundleShardPlan>.unmodifiable(shards),
    );
  }
}
