import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;

import '../bytes.dart';
import '../catalog/catalog_models.dart';
import '../catalog/catalog_signature.dart';
import '../constants.dart';
import '../errors.dart';
import '../format/header.dart';
import '../storage/local_cipher_store.dart';
import 'data_source.dart';
import 'source_path.dart';

enum CipherSyncStage {
  catalogDownload,
  objectDownload,
  objectUpload,
  catalogUpload,
}

final class CipherSyncProgress {
  const CipherSyncProgress({
    required this.stage,
    required this.completed,
    required this.total,
  });

  final CipherSyncStage stage;
  final int completed;
  final int total;
}

typedef CipherSyncProgressCallback = void Function(CipherSyncProgress progress);

final class CatalogMirrorResult {
  const CatalogMirrorResult({
    required this.providerRevision,
    required this.notModified,
    this.localObject,
  });

  final RevisionToken providerRevision;
  final bool notModified;
  final CiphertextObject? localObject;
}

final class CipherMirrorSummary {
  const CipherMirrorSummary({
    required this.total,
    required this.reused,
    required this.transferred,
  });

  final int total;
  final int reused;
  final int transferred;
}

/// Synchronizes only encrypted SBOX objects. Catalog plaintext and private key
/// material never cross this boundary.
final class CipherMirrorSynchronizer {
  CipherMirrorSynchronizer({
    required this.source,
    required this.localStore,
    this.onProgress,
  });

  final DataSource source;
  final LocalCipherStore localStore;
  final CipherSyncProgressCallback? onProgress;

  Future<CatalogMirrorResult> pullEncryptedCatalog({
    RevisionToken? ifNoneMatch,
    Uint8List? expectedCurrentLocalSha256,
    String? expectedRecipientKeyId,
  }) async {
    final path = SourcePath('catalog.sbox');
    final read = await source.get(path, ifNoneMatch: ifNoneMatch);
    if (read.notModified) {
      return CatalogMirrorResult(
        providerRevision: read.revision,
        notModified: true,
      );
    }
    if (read.length < SboxV1.headerLength ||
        read.length > SboxV1.maxCatalogCiphertextSize) {
      throw const SboxException(
        SboxErrorCode.sourceLimit,
        '远端 catalog.sbox 大小超过协议上限',
      );
    }
    onProgress?.call(
      const CipherSyncProgress(
        stage: CipherSyncStage.catalogDownload,
        completed: 0,
        total: 1,
      ),
    );
    final staged = await localStore.createStaging(path);
    try {
      final result = await _downloadToStaging(
        staged,
        read.body,
        expectedLength: read.length,
      );
      _verifyHeader(
        result.header,
        expectedRecipientKeyId: expectedRecipientKeyId,
      );
      final object = await localStore.replaceDownloadedCatalog(
        staged,
        expectedLength: read.length,
        expectedSha256: result.sha256,
        expectedCurrentSha256: expectedCurrentLocalSha256,
      );
      onProgress?.call(
        const CipherSyncProgress(
          stage: CipherSyncStage.catalogDownload,
          completed: 1,
          total: 1,
        ),
      );
      return CatalogMirrorResult(
        providerRevision: read.revision,
        notModified: false,
        localObject: object,
      );
    } on Object {
      await staged.discard();
      rethrow;
    }
  }

  Future<CipherMirrorSummary> pullVerifiedCatalogObjects(
    VerifiedCatalog verified,
  ) => pullAuthenticatedCatalogPayloads(
    verified.catalog.entries.map((entry) => entry.payload),
    expectedRecipientKeyId: verified.catalog.recipientKeyId,
  );

  /// Mirrors the typed payload plan returned by the dedicated Catalog
  /// verification isolate. Callers must never construct this plan from
  /// unverified remote JSON.
  Future<CipherMirrorSummary> pullAuthenticatedCatalogPayloads(
    Iterable<CatalogPayload> payloads, {
    required String expectedRecipientKeyId,
  }) async {
    final plan = _uniquePayloadParts(payloads);
    final expectedRecipient = expectedRecipientKeyId;
    var reused = 0;
    final missing = <CatalogPart>[];
    for (final part in plan) {
      final expectedHash = _decodeHash(part.sboxSha256);
      final existing = await localStore.find(
        SourcePath(part.objectPath),
        expectedHash,
      );
      if (existing == null) {
        missing.add(part);
        continue;
      }
      _requirePartLength(part, existing.length);
      final header = await _readHeader(existing.file);
      _verifyHeader(
        header,
        expectedFileId: part.fileId,
        expectedRecipientKeyId: expectedRecipient,
      );
      reused++;
    }
    var completed = reused;
    onProgress?.call(
      CipherSyncProgress(
        stage: CipherSyncStage.objectDownload,
        completed: completed,
        total: plan.length,
      ),
    );
    await _runBounded<CatalogPart>(
      missing,
      source.capabilities.maxParallelObjectTransfers,
      (part) async {
        await _downloadPart(part, expectedRecipient);
        completed++;
        onProgress?.call(
          CipherSyncProgress(
            stage: CipherSyncStage.objectDownload,
            completed: completed,
            total: plan.length,
          ),
        );
      },
    );
    return CipherMirrorSummary(
      total: plan.length,
      reused: reused,
      transferred: missing.length,
    );
  }

  /// Uploads every referenced immutable payload object before publishing the
  /// already signed and encrypted catalog.sbox with conditional semantics.
  Future<RevisionToken> publishEncryptedCatalog({
    required Iterable<CatalogPayload> payloads,
    required Uint8List encryptedCatalogSha256,
    RevisionToken? expectedRemoteRevision,
  }) async {
    final parts = _uniquePayloadParts(payloads);
    var completed = 0;
    onProgress?.call(
      CipherSyncProgress(
        stage: CipherSyncStage.objectUpload,
        completed: 0,
        total: parts.length,
      ),
    );
    await _runBounded<CatalogPart>(
      parts,
      source.capabilities.maxParallelObjectTransfers,
      (part) async {
        final expectedHash = _decodeHash(part.sboxSha256);
        final local = await localStore.find(
          SourcePath(part.objectPath),
          expectedHash,
        );
        if (local == null) {
          throw const SboxException(
            SboxErrorCode.multipartMissing,
            '本地密文分片不完整，不能发布 Catalog',
          );
        }
        _requirePartLength(part, local.length);
        await source.putNew(
          SourcePath(part.objectPath),
          local.file.openRead(),
          length: local.length,
          sha256: expectedHash,
        );
        completed++;
        onProgress?.call(
          CipherSyncProgress(
            stage: CipherSyncStage.objectUpload,
            completed: completed,
            total: parts.length,
          ),
        );
      },
    );

    final catalog = await localStore.find(
      SourcePath('catalog.sbox'),
      encryptedCatalogSha256,
    );
    if (catalog == null) {
      throw const SboxException(
        SboxErrorCode.catalog,
        '已加密的本地 catalog.sbox 不存在',
      );
    }
    onProgress?.call(
      const CipherSyncProgress(
        stage: CipherSyncStage.catalogUpload,
        completed: 0,
        total: 1,
      ),
    );
    final revision = expectedRemoteRevision == null
        ? await source.putNew(
            SourcePath('catalog.sbox'),
            catalog.file.openRead(),
            length: catalog.length,
            sha256: encryptedCatalogSha256,
          )
        : await source.compareAndSwap(
            SourcePath('catalog.sbox'),
            expectedRemoteRevision,
            catalog.file.openRead(),
            length: catalog.length,
          );
    onProgress?.call(
      const CipherSyncProgress(
        stage: CipherSyncStage.catalogUpload,
        completed: 1,
        total: 1,
      ),
    );
    return revision;
  }

  Future<void> _downloadPart(CatalogPart part, String expectedRecipient) async {
    final size = _partLength(part);
    final maximum = source.capabilities.maxObjectBytes;
    if (maximum != null && part.sboxSize > maximum) {
      throw const SboxException(
        SboxErrorCode.sourceLimit,
        'Catalog 分片超过当前数据源单对象上限',
      );
    }
    final path = SourcePath(part.objectPath);
    final read = await source.get(path);
    if (read.length != size) {
      throw const SboxException(
        SboxErrorCode.remoteChanged,
        '远端分片长度与 Catalog 不一致',
      );
    }
    final staged = await localStore.createStaging(path);
    try {
      final result = await _downloadToStaging(
        staged,
        read.body,
        expectedLength: size,
      );
      final expectedHash = _decodeHash(part.sboxSha256);
      if (!constantTimeBytesEqual(result.sha256, expectedHash)) {
        throw const SboxException(
          SboxErrorCode.remoteChanged,
          '远端分片摘要与 Catalog 不一致',
        );
      }
      _verifyHeader(
        result.header,
        expectedFileId: part.fileId,
        expectedRecipientKeyId: expectedRecipient,
      );
      await localStore.commitDownloaded(
        staged,
        expectedLength: size,
        expectedSha256: expectedHash,
      );
    } on Object {
      await staged.discard();
      rethrow;
    }
  }

  static Future<_DownloadedStaging> _downloadToStaging(
    StagedCiphertext staged,
    Stream<List<int>> source, {
    required int expectedLength,
  }) async {
    final output = staged.openSink();
    final accumulator = AccumulatorSink<crypto.Digest>();
    final hashSink = crypto.sha256.startChunkedConversion(accumulator);
    final header = BytesBuilder(copy: false);
    var written = 0;

    Stream<List<int>> inspect() async* {
      await for (final chunk in source) {
        written += chunk.length;
        if (written > expectedLength) {
          throw const SboxException(
            SboxErrorCode.remoteChanged,
            '下载对象超过 Catalog 声明长度',
          );
        }
        hashSink.add(chunk);
        final needed = SboxV1.headerLength - header.length;
        if (needed > 0) {
          header.add(chunk.length <= needed ? chunk : chunk.sublist(0, needed));
        }
        yield chunk;
      }
    }

    try {
      await output.addStream(inspect());
      if (written != expectedLength) {
        throw const SboxException(SboxErrorCode.remoteChanged, '下载对象提前结束');
      }
      hashSink.close();
      await output.flush();
      await output.close();
      return _DownloadedStaging(
        sha256: Uint8List.fromList(accumulator.events.single.bytes),
        header: SboxHeader.parse(header.takeBytes()),
      );
    } on Object {
      try {
        hashSink.close();
      } on StateError {
        // It was already closed on the success path.
      }
      await output.close();
      rethrow;
    }
  }

  static Future<SboxHeader> _readHeader(File file) async {
    final handle = await file.open();
    try {
      return SboxHeader.parse(await handle.read(SboxV1.headerLength));
    } finally {
      await handle.close();
    }
  }

  static void _verifyHeader(
    SboxHeader header, {
    String? expectedFileId,
    String? expectedRecipientKeyId,
  }) {
    if ((expectedFileId != null && hexLower(header.fileId) != expectedFileId) ||
        (expectedRecipientKeyId != null &&
            hexLower(header.recipientKeyId) != expectedRecipientKeyId)) {
      throw const SboxException(
        SboxErrorCode.remoteChanged,
        'SBOX 公共头部与可信清单不一致',
      );
    }
  }

  static List<CatalogPart> _uniquePayloadParts(
    Iterable<CatalogPayload> payloads,
  ) {
    final byPath = <String, CatalogPart>{};
    for (final payload in payloads) {
      for (final part in payload.parts) {
        final prior = byPath[part.objectPath];
        if (prior != null &&
            (prior.fileId != part.fileId ||
                prior.sboxSize != part.sboxSize ||
                prior.sboxSha256 != part.sboxSha256)) {
          throw const SboxException(
            SboxErrorCode.catalog,
            'Catalog 对同一对象路径给出了冲突定义',
          );
        }
        byPath[part.objectPath] = part;
      }
    }
    final result = byPath.values.toList(growable: false)
      ..sort((left, right) => left.objectPath.compareTo(right.objectPath));
    return result;
  }

  static int _partLength(CatalogPart part) {
    if (part.sboxSize > BigInt.from(0x7fffffffffffffff)) {
      throw const SboxException(
        SboxErrorCode.sourceLimit,
        'Catalog 分片长度超过当前平台范围',
      );
    }
    return part.sboxSize.toInt();
  }

  static void _requirePartLength(CatalogPart part, int actual) {
    if (_partLength(part) != actual) {
      throw const SboxException(
        SboxErrorCode.remoteChanged,
        '本地分片长度与 Catalog 不一致',
      );
    }
  }

  static Uint8List _decodeHash(String value) {
    try {
      return Uint8List.fromList(hex.decode(value));
    } on FormatException {
      throw const SboxException(SboxErrorCode.catalog, 'Catalog 对象摘要无效');
    }
  }

  static Future<void> _runBounded<T>(
    List<T> values,
    int parallelism,
    Future<void> Function(T value) action,
  ) async {
    if (values.isEmpty) {
      return;
    }
    var next = 0;
    Object? firstError;
    StackTrace? firstStack;

    Future<void> worker() async {
      while (firstError == null) {
        if (next >= values.length) {
          return;
        }
        final value = values[next++];
        try {
          await action(value);
        } on Object catch (error, stack) {
          firstError ??= error;
          firstStack ??= stack;
        }
      }
    }

    final count = parallelism.clamp(1, 4).clamp(1, values.length);
    await Future.wait(List<Future<void>>.generate(count, (_) => worker()));
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack!);
    }
  }
}

final class _DownloadedStaging {
  const _DownloadedStaging({required this.sha256, required this.header});

  final Uint8List sha256;
  final SboxHeader header;
}
