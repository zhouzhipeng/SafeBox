import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../bytes.dart';
import '../errors.dart';
import '../format/header.dart';
import '../storage/io_hash.dart';

enum LocalDirectoryProbeMode { canonicalCatalog, looseReadOnly }

final class LocalDirectoryProbe {
  const LocalDirectoryProbe({
    required this.mode,
    required this.root,
    this.catalogHeader,
  });

  final LocalDirectoryProbeMode mode;
  final Directory root;
  final SboxHeader? catalogHeader;

  static Future<LocalDirectoryProbe> inspect(Directory selectedRoot) async {
    if (!await selectedRoot.exists()) {
      throw const SboxException(SboxErrorCode.sourceNetwork, '所选本地目录不存在');
    }
    final canonical = await selectedRoot.resolveSymbolicLinks();
    final root = Directory(canonical);
    final catalog = File(p.join(canonical, 'catalog.sbox'));
    final type = await FileSystemEntity.type(catalog.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return LocalDirectoryProbe(
        mode: LocalDirectoryProbeMode.looseReadOnly,
        root: root,
      );
    }
    if (type != FileSystemEntityType.file ||
        await catalog.length() < SboxHeaderLength.value) {
      throw _catalogDirectoryError();
    }
    final handle = await catalog.open(mode: FileMode.read);
    try {
      final bytes = await handle.read(SboxHeaderLength.value);
      if (bytes.length != SboxHeaderLength.value) {
        throw _catalogDirectoryError();
      }
      return LocalDirectoryProbe(
        mode: LocalDirectoryProbeMode.canonicalCatalog,
        root: root,
        catalogHeader: SboxHeader.parse(bytes),
      );
    } finally {
      await handle.close();
    }
  }
}

/// Avoids importing the full constants namespace solely for a public fixed
/// read length in the local scanner.
abstract final class SboxHeaderLength {
  static const int value = 468;
}

final class ScannedSboxCandidate {
  ScannedSboxCandidate({
    required this.relativePath,
    required this.file,
    required this.ciphertextSize,
    required this.header,
    required List<int> sha256,
    required this.duplicateCopies,
    required this.hasFileIdConflict,
  }) : sha256 = Uint8List.fromList(sha256);

  final String relativePath;
  final File file;
  final int ciphertextSize;
  final SboxHeader header;
  final Uint8List sha256;
  final List<String> duplicateCopies;
  final bool hasFileIdConflict;
}

final class LooseDirectoryScanResult {
  const LooseDirectoryScanResult({
    required this.candidates,
    required this.scannedFileCount,
  });

  final List<ScannedSboxCandidate> candidates;
  final int scannedFileCount;
}

abstract final class LocalSboxScanner {
  static Future<LooseDirectoryScanResult> scan(
    Directory selectedRoot, {
    int maximumDepth = 8,
    int maximumCandidates = 100000,
  }) async {
    if (maximumDepth < 0 || maximumCandidates < 1) {
      throw ArgumentError('Invalid local scan limits');
    }
    final canonicalRoot = await selectedRoot.resolveSymbolicLinks();
    final pending = <_PendingDirectory>[
      _PendingDirectory(Directory(canonicalRoot), 0),
    ];
    final raw = <_RawCandidate>[];
    var candidateCount = 0;
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      await for (final entity in current.directory.list(followLinks: false)) {
        final type = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.directory) {
          if (current.depth >= maximumDepth) {
            continue;
          }
          final resolved = await Directory(entity.path).resolveSymbolicLinks();
          if (resolved == canonicalRoot ||
              !p.isWithin(canonicalRoot, resolved) ||
              !_samePath(resolved, p.normalize(p.absolute(entity.path)))) {
            continue;
          }
          pending.add(
            _PendingDirectory(Directory(resolved), current.depth + 1),
          );
          continue;
        }
        if (type != FileSystemEntityType.file ||
            !_hasAsciiSboxExtension(entity.path)) {
          continue;
        }
        candidateCount++;
        if (candidateCount > maximumCandidates) {
          throw SboxException(
            SboxErrorCode.limits,
            '本地 SBOX 候选超过 $maximumCandidates 个，扫描未完成',
          );
        }
        final file = File(entity.path);
        if (await file.length() < SboxHeaderLength.value) {
          continue;
        }
        final handle = await file.open(mode: FileMode.read);
        try {
          final headerBytes = await handle.read(SboxHeaderLength.value);
          if (headerBytes.length != SboxHeaderLength.value) {
            continue;
          }
          try {
            final header = SboxHeader.parse(headerBytes);
            raw.add(
              _RawCandidate(
                relativePath: p
                    .relative(file.path, from: canonicalRoot)
                    .replaceAll(p.separator, '/'),
                file: file,
                size: await file.length(),
                header: header,
                sha256: await sha256File(file),
              ),
            );
          } on SboxException {
            // Invalid public headers are diagnostic noise, not candidates that
            // can be decrypted or displayed as valid SBOX objects.
          }
        } finally {
          await handle.close();
        }
      }
    }

    final byFileId = <String, List<_RawCandidate>>{};
    for (final candidate in raw) {
      byFileId
          .putIfAbsent(
            hexLower(candidate.header.fileId),
            () => <_RawCandidate>[],
          )
          .add(candidate);
    }
    final results = <ScannedSboxCandidate>[];
    for (final group in byFileId.values) {
      group.sort((a, b) => a.relativePath.compareTo(b.relativePath));
      final primary = group.first;
      final conflict = group.any(
        (candidate) =>
            !constantTimeBytesEqual(candidate.sha256, primary.sha256),
      );
      results.add(
        ScannedSboxCandidate(
          relativePath: primary.relativePath,
          file: primary.file,
          ciphertextSize: primary.size,
          header: primary.header,
          sha256: primary.sha256,
          duplicateCopies: List<String>.unmodifiable(
            group.skip(1).map((candidate) => candidate.relativePath),
          ),
          hasFileIdConflict: conflict,
        ),
      );
    }
    results.sort((a, b) => a.relativePath.compareTo(b.relativePath));
    return LooseDirectoryScanResult(
      candidates: List<ScannedSboxCandidate>.unmodifiable(results),
      scannedFileCount: candidateCount,
    );
  }

  static bool _hasAsciiSboxExtension(String value) {
    final name = p.basename(value);
    if (name.length < 5) {
      return false;
    }
    final suffix = name.substring(name.length - 5);
    return suffix.codeUnits.every((unit) => unit < 0x80) &&
        suffix.toLowerCase() == '.sbox';
  }

  static bool _samePath(String left, String right) => Platform.isWindows
      ? left.toLowerCase() == right.toLowerCase()
      : left == right;
}

final class _PendingDirectory {
  const _PendingDirectory(this.directory, this.depth);

  final Directory directory;
  final int depth;
}

final class _RawCandidate {
  const _RawCandidate({
    required this.relativePath,
    required this.file,
    required this.size,
    required this.header,
    required this.sha256,
  });

  final String relativePath;
  final File file;
  final int size;
  final SboxHeader header;
  final Uint8List sha256;
}

SboxException _catalogDirectoryError() =>
    const SboxException(SboxErrorCode.catalog, '目录包含无效 catalog.sbox，不能降级为散装扫描');
