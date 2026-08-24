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
    return _ceilDiv(plaintextLength, SboxProtocol.chunkSize);
  }

  static int continuationUpperBound(int plaintextLength) {
    if (plaintextLength < 0) throw ArgumentError.value(plaintextLength);
    return _checkedSum(<int>[
      SboxProtocol.commonHeaderLength,
      plaintextLength,
      29 * dataRecordCount(plaintextLength),
      77,
    ]);
  }

  static int rootUpperBound(int plaintextLength) {
    if (plaintextLength < 0) throw ArgumentError.value(plaintextLength);
    return _checkedSum(<int>[
      SboxProtocol.rootHeaderLength,
      plaintextLength,
      29 * dataRecordCount(plaintextLength),
      77,
    ]);
  }

  static BundlePlan plan({
    required int logicalLength,
    int targetNominalShardPlaintextSize =
        SboxProtocol.defaultNominalShardPlaintextSize,
    int? maxObjectBytes,
  }) {
    if (logicalLength < 0 ||
        targetNominalShardPlaintextSize <
            SboxProtocol.minNominalShardPlaintextSize ||
        targetNominalShardPlaintextSize >
            SboxProtocol.maxNominalShardPlaintextSize ||
        targetNominalShardPlaintextSize % (1024 * 1024) != 0) {
      throw const SboxException(SboxErrorCode.sourceLimit, '分片大小无效');
    }
    final unit = 1024 * 1024;
    final candidates = <int>[];
    for (
      var candidate = SboxProtocol.minNominalShardPlaintextSize;
      candidate <= SboxProtocol.maxNominalShardPlaintextSize;
      candidate += unit
    ) {
      final count = logicalLength == 0 ? 1 : _ceilDiv(logicalLength, candidate);
      if (count > SboxProtocol.maxShardCount) continue;
      if (maxObjectBytes != null &&
          (rootUpperBound(math.min(candidate, logicalLength)) >
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
    final count = logicalLength == 0 ? 1 : _ceilDiv(logicalLength, selected);
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

  static int _ceilDiv(int value, int divisor) {
    final quotient = value ~/ divisor;
    return value % divisor == 0 ? quotient : quotient + 1;
  }

  static int _checkedSum(List<int> values) {
    // Dart web integers are represented as JavaScript numbers. Keep size
    // arithmetic inside the largest integer that every supported target can
    // represent exactly; the SBOX protocol limit (512 MiB * 10,000 shards)
    // is comfortably below this value.
    const maxInt = 0x1fffffffffffff;
    var result = 0;
    for (final value in values) {
      if (value < 0 || result > maxInt - value) {
        throw const SboxException(SboxErrorCode.sourceLimit, '对象大小计算溢出');
      }
      result += value;
    }
    return result;
  }
}
