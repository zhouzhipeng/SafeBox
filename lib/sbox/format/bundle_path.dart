import '../bytes.dart';
import '../constants.dart';
import '../errors.dart';
import 'bundle_header.dart';

final class BundlePathInfo {
  const BundlePathInfo({
    required this.bundleId,
    required this.shardIndex,
    required this.shardCount,
  });

  final String bundleId;
  final int shardIndex;
  final int shardCount;

  bool get isRoot => shardIndex == 0;

  String get canonicalBasename => canonicalBundleBasename(
    bundleId: decodeHex(bundleId),
    shardIndex: shardIndex,
    shardCount: shardCount,
  );
}

String canonicalBundleBasename({
  required List<int> bundleId,
  required int shardIndex,
  required int shardCount,
}) {
  if (bundleId.length != SboxProtocol.bundleIdLength ||
      shardCount < 1 ||
      shardCount > SboxProtocol.maxShardCount ||
      shardIndex < 0 ||
      shardIndex >= shardCount) {
    throw const SboxException(SboxErrorCode.invalidHeader, 'Bundle 路径参数无效');
  }
  final id = hexLower(bundleId);
  if (shardCount == 1) return '$id.sbox';
  return '${id}_${_canonicalDecimal(shardIndex)}_${_canonicalDecimal(shardCount)}.sbox';
}

BundlePathInfo parseCanonicalBundleBasename(String value) {
  if (value.codeUnits.any((unit) => unit > 0x7f) ||
      value.contains('/') ||
      value.contains('\\') ||
      value.contains('\u0000') ||
      value.contains('%')) {
    throw const SboxException(SboxErrorCode.invalidHeader, 'Bundle 对象路径无效');
  }
  final unsharded = RegExp(r'^([0-9a-f]{32})\.sbox$').firstMatch(value);
  if (unsharded != null) {
    return BundlePathInfo(
      bundleId: unsharded.group(1)!,
      shardIndex: 0,
      shardCount: 1,
    );
  }
  final multipart = RegExp(
    r'^([0-9a-f]{32})_(0|[1-9][0-9]*)_([1-9][0-9]*)\.sbox$',
  ).firstMatch(value);
  if (multipart == null) {
    throw const SboxException(SboxErrorCode.invalidHeader, 'Bundle 对象路径无效');
  }
  final index = int.tryParse(multipart.group(2)!);
  final count = int.tryParse(multipart.group(3)!);
  if (index == null ||
      count == null ||
      count < 2 ||
      count > 10000 ||
      index < 0 ||
      index >= count) {
    throw const SboxException(SboxErrorCode.invalidHeader, 'Bundle 分片路径范围无效');
  }
  return BundlePathInfo(
    bundleId: multipart.group(1)!,
    shardIndex: index,
    shardCount: count,
  );
}

void validateBundlePathAgainstHeader(String basename, BundleHeader header) {
  final path = parseCanonicalBundleBasename(basename);
  if (hexLower(header.bundleId) != path.bundleId ||
      header.shardIndex != path.shardIndex ||
      header.shardCount != path.shardCount ||
      (path.shardCount == 1 && !header.isRoot) ||
      (path.shardCount >= 2 && header.isRoot && path.shardIndex != 0)) {
    throw const SboxException(SboxErrorCode.shardMismatch, '对象路径与公共头不一致');
  }
}

String _canonicalDecimal(int value) {
  if (value < 0) throw ArgumentError.value(value, 'value');
  return value.toString();
}
