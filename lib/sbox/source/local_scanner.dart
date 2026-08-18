import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../errors.dart';
import '../format/bundle_header.dart';
import '../format/bundle_path.dart';
import '../storage/io_hash.dart';

final class BundleCandidate {
  BundleCandidate({
    required this.basename,
    required this.file,
    required this.header,
    required this.ciphertextSize,
    required List<int> sha256,
  }) : sha256 = Uint8List.fromList(sha256);

  final String basename;
  final File file;
  final BundleHeader header;
  final int ciphertextSize;
  final Uint8List sha256;
}

final class BundleScanResult {
  const BundleScanResult({required this.roots, required this.scannedFileCount});

  final List<BundleCandidate> roots;
  final int scannedFileCount;
}

abstract final class LocalBundleScanner {
  static Future<BundleScanResult> scan(
    Directory selectedRoot, {
    int maximumCandidates = 100000,
  }) async {
    if (!await selectedRoot.exists()) {
      throw const SboxException(SboxErrorCode.sourceNotFound, '数据源目录不存在');
    }
    final canonical = await selectedRoot.resolveSymbolicLinks();
    final root = Directory(canonical);
    final candidates = <BundleCandidate>[];
    var count = 0;
    await for (final entity in root.list(followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type != FileSystemEntityType.file ||
          p.dirname(entity.path) != canonical ||
          !p.basename(entity.path).endsWith('.sbox')) {
        continue;
      }
      count++;
      if (count > maximumCandidates) {
        throw SboxException(
          SboxErrorCode.sourceLimit,
          '候选对象超过 $maximumCandidates 个',
        );
      }
      final basename = p.basename(entity.path);
      BundlePathInfo path;
      try {
        path = parseCanonicalBundleBasename(basename);
      } on SboxException {
        continue;
      }
      final file = File(entity.path);
      final length = await file.length();
      if (length < 12) continue;
      try {
        final handle = await file.open(mode: FileMode.read);
        final prefix = await handle.read(12);
        await handle.close();
        final headerLength = prefix.length < 12
            ? 0
            : ((prefix[10] << 8) | prefix[11]);
        if (headerLength != 128 && headerLength != 512 ||
            length < headerLength) {
          continue;
        }
        final headerHandle = await file.open(mode: FileMode.read);
        final header = BundleHeader.parse(
          await headerHandle.read(headerLength),
        );
        await headerHandle.close();
        validateBundlePathAgainstHeader(basename, header);
        if (!header.isRoot || path.shardIndex != 0) continue;
        candidates.add(
          BundleCandidate(
            basename: basename,
            file: file,
            header: header,
            ciphertextSize: length,
            sha256: await sha256File(file),
          ),
        );
      } on SboxException {
        // Non-v2 and malformed objects are not promoted to Bundle candidates.
      } on FileSystemException {
        // A disappearing file is ignored; a later listing can observe it.
      }
    }
    candidates.sort((left, right) => left.basename.compareTo(right.basename));
    return BundleScanResult(
      roots: List<BundleCandidate>.unmodifiable(candidates),
      scannedFileCount: count,
    );
  }
}
