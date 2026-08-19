import 'dart:io';

import 'package:path/path.dart' as p;

import '../constants.dart';
import '../engine/bundle_probe.dart';
import '../errors.dart';
import '../format/bundle_header.dart';
import '../format/bundle_path.dart';
import '../format/bundle_manifest.dart';
import '../format/bundle_preview.dart';
import '../identity/rsa_models.dart';

final class BundleCandidate {
  BundleCandidate({
    required this.basename,
    required this.file,
    required this.header,
    required this.ciphertextSize,
    this.manifest,
    this.preview,
    bool? hasPreview,
    this.status = BundleTrustStatus.headerOnly,
  }) : hasPreview = hasPreview ?? preview != null;

  final String basename;
  final File file;
  final BundleHeader header;
  final int ciphertextSize;
  final BundleManifest? manifest;
  final BundlePreview? preview;
  final bool hasPreview;
  final BundleTrustStatus status;
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
    PublicIdentity? identity,
    int maxRetainedPreviewBytes = SboxProtocol.maxRetainedPreviewBytes,
  }) async {
    if (!await selectedRoot.exists()) {
      throw const SboxException(SboxErrorCode.sourceNotFound, '数据源目录不存在');
    }
    if (maxRetainedPreviewBytes < 0) {
      throw ArgumentError.value(
        maxRetainedPreviewBytes,
        'maxRetainedPreviewBytes',
      );
    }
    final canonical = await selectedRoot.resolveSymbolicLinks();
    final root = Directory(canonical);
    final candidates = <BundleCandidate>[];
    var retainedPreviewBytes = 0;
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
        if (headerLength != SboxProtocol.commonHeaderLength &&
                headerLength != SboxProtocol.rootHeaderLength ||
            length < headerLength) {
          continue;
        }
        final headerHandle = await file.open(mode: FileMode.read);
        final headerBytes = await headerHandle.read(headerLength);
        final header = BundleHeader.parse(headerBytes);
        await headerHandle.close();
        validateBundlePathAgainstHeader(basename, header);
        if (!header.isRoot || path.shardIndex != 0) continue;
        BundleManifest? manifest;
        BundlePreview? preview;
        var status = BundleTrustStatus.headerOnly;
        if (identity != null) {
          try {
            final result = await BundleProbe.readManifest(
              basename: basename,
              objectPrefix: headerBytes,
              identity: identity,
            );
            manifest = result.manifest;
            preview = result.preview;
            status = result.status;
          } on SboxException {
            // Keep the candidate as headerOnly when this identity cannot read
            // its public Metadata.
          }
        }
        final candidate = BundleCandidate(
          basename: basename,
          file: file,
          header: header,
          ciphertextSize: length,
          manifest: manifest,
          preview: preview,
          status: status,
        );
        if (candidate.preview == null ||
            candidate.preview!.encodedLength <=
                maxRetainedPreviewBytes - retainedPreviewBytes) {
          if (candidate.preview != null) {
            retainedPreviewBytes += candidate.preview!.encodedLength;
          }
          candidates.add(candidate);
        } else {
          candidate.preview!.dispose();
          candidates.add(
            BundleCandidate(
              basename: candidate.basename,
              file: candidate.file,
              header: candidate.header,
              ciphertextSize: candidate.ciphertextSize,
              manifest: candidate.manifest,
              hasPreview: true,
              status: candidate.status,
            ),
          );
        }
      } on SboxException {
        // Non-v3 and malformed objects are not promoted to Bundle candidates.
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
