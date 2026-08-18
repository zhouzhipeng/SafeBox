import 'dart:io';
import 'dart:typed_data';

import '../errors.dart';
import '../engine/background_bundle_crypto.dart';
import '../engine/bundle_decryptor.dart';
import '../engine/bundle_encryptor.dart';
import '../format/bundle_header.dart';
import '../format/bundle_path.dart';
import '../identity/rsa_models.dart';
import 'data_source.dart';
import 'source_path.dart';

abstract final class BundleSync {
  static Future<DecryptedBundle> fetchAndDecrypt({
    required DataSource source,
    required SourcePath rootPath,
    required String mnemonic,
    PublicIdentity? expectedIdentity,
  }) async {
    final objects = await _downloadObjects(source: source, rootPath: rootPath);
    return BackgroundBundleCrypto.decrypt(
      objects: objects,
      mnemonic: mnemonic,
      expectedIdentity: expectedIdentity,
    );
  }

  static Future<void> fetchAndDecryptToFile({
    required DataSource source,
    required SourcePath rootPath,
    required String mnemonic,
    required File destination,
    PublicIdentity? expectedIdentity,
  }) => fetchAndDecryptToFileStreaming(
    source: source,
    rootPath: rootPath,
    mnemonic: mnemonic,
    destination: destination,
    expectedIdentity: expectedIdentity,
  );

  /// Downloads ciphertext shards concurrently and performs authentication,
  /// decryption and verified plaintext publication in a background isolate.
  /// Plaintext is never returned to this source layer.
  static Future<void> fetchAndDecryptToFileStreaming({
    required DataSource source,
    required SourcePath rootPath,
    required String mnemonic,
    required File destination,
    PublicIdentity? expectedIdentity,
  }) async {
    final objects = await _downloadObjects(source: source, rootPath: rootPath);
    await BackgroundBundleCrypto.decryptToFile(
      objects: objects,
      mnemonic: mnemonic,
      destination: destination,
      expectedIdentity: expectedIdentity,
    );
  }

  static Future<Map<String, List<int>>> _downloadObjects({
    required DataSource source,
    required SourcePath rootPath,
  }) async {
    if (!source.capabilities.canRead) {
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        'The current data source is not readable',
      );
    }
    final rootRead = await source.get(rootPath);
    final rootBytes = await _readObject(source, rootRead);
    final rootHeader = BundleHeader.parse(rootBytes);
    validateBundlePathAgainstHeader(rootPath.value, rootHeader);
    if (!rootHeader.isRoot) {
      throw const SboxException(
        SboxErrorCode.rootRequired,
        'A root shard is required',
      );
    }

    final objects = <String, List<int>>{rootPath.value: rootBytes};
    final paths = <SourcePath>[
      for (var index = 1; index < rootHeader.shardCount; index++)
        SourcePath(
          canonicalBundleBasename(
            bundleId: rootHeader.bundleId,
            shardIndex: index,
            shardCount: rootHeader.shardCount,
          ),
        ),
    ];
    await _parallelForEach(
      paths,
      maxParallel: source.capabilities.maxParallelTransfers,
      action: (path) async {
        try {
          final read = await source.get(path);
          objects[path.value] = await _readObject(source, read);
        } on SboxException catch (error) {
          if (error.code == SboxErrorCode.sourceNotFound) {
            throw const SboxException(
              SboxErrorCode.shardMissing,
              'Bundle is missing a continuation shard',
            );
          }
          rethrow;
        }
      },
    );
    return objects;
  }

  static Future<List<RevisionToken>> publish(
    DataSource source,
    EncryptedBundle bundle,
  ) async {
    if (!source.capabilities.canWrite) {
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        'The current data source is not writable',
      );
    }
    if (source.capabilities.maxObjectBytes != null &&
        bundle.objects.any(
          (object) => object.bytes.length > source.capabilities.maxObjectBytes!,
        )) {
      throw const SboxException(
        SboxErrorCode.sourceLimit,
        'An object exceeds the data source limit',
      );
    }
    final continuation = bundle.objects
        .where((object) => !object.header.isRoot)
        .toList();
    continuation.sort(
      (left, right) =>
          left.header.shardIndex.compareTo(right.header.shardIndex),
    );
    final revisions = await _parallelMap(
      continuation,
      maxParallel: source.capabilities.maxParallelTransfers,
      action: (object) => _put(source, object),
    );
    // The root object is the immutable Bundle commit marker.
    revisions.add(await _put(source, bundle.root));
    return List<RevisionToken>.unmodifiable(revisions);
  }

  static Future<void> delete(
    DataSource source,
    Iterable<({SourcePath path, RevisionToken revision, bool isRoot})> objects,
  ) async {
    final list = objects.toList(growable: false);
    final roots = list.where((object) => object.isRoot).toList(growable: false);
    if (roots.length != 1) {
      throw const SboxException(
        SboxErrorCode.rootRequired,
        'Deleting a Bundle requires exactly one root object',
      );
    }
    await source.deleteIfMatch(roots.single.path, roots.single.revision);
    for (final object in list.where((object) => !object.isRoot)) {
      await source.deleteIfMatch(object.path, object.revision);
    }
  }

  static Future<RevisionToken> _put(
    DataSource source,
    EncryptedBundleObject object,
  ) => source.putNew(
    SourcePath(object.basename),
    Stream<List<int>>.value(object.bytes),
    length: object.bytes.length,
    sha256: object.sha256,
  );

  static Future<Uint8List> _readObject(
    DataSource source,
    SourceRead read,
  ) async {
    if (read.notModified ||
        read.length < 0 ||
        (source.capabilities.maxObjectBytes != null &&
            read.length > source.capabilities.maxObjectBytes!)) {
      throw const SboxException(
        SboxErrorCode.remoteChanged,
        'The remote object length is not acceptable',
      );
    }
    final output = BytesBuilder(copy: false);
    var count = 0;
    await for (final chunk in read.body) {
      count += chunk.length;
      if (count > read.length) {
        throw const SboxException(
          SboxErrorCode.remoteChanged,
          'The remote object is longer than declared',
        );
      }
      output.add(chunk);
    }
    if (count != read.length) {
      throw const SboxException(
        SboxErrorCode.remoteChanged,
        'The remote object is incomplete',
      );
    }
    return output.takeBytes();
  }
}

Future<void> _parallelForEach<T>(
  Iterable<T> values, {
  required int maxParallel,
  required Future<void> Function(T value) action,
}) async {
  final items = values.toList(growable: false);
  if (items.isEmpty) return;
  final workerCount = maxParallel < 1
      ? 1
      : maxParallel > items.length
      ? items.length
      : maxParallel;
  var next = 0;

  Future<void> worker() async {
    while (true) {
      if (next >= items.length) return;
      final index = next++;
      await action(items[index]);
    }
  }

  await Future.wait(<Future<void>>[
    for (var index = 0; index < workerCount; index++) worker(),
  ]);
}

Future<List<R>> _parallelMap<T, R>(
  Iterable<T> values, {
  required int maxParallel,
  required Future<R> Function(T value) action,
}) async {
  final items = values.toList(growable: false);
  if (items.isEmpty) return <R>[];
  final results = List<R?>.filled(items.length, null);
  final workerCount = maxParallel < 1
      ? 1
      : maxParallel > items.length
      ? items.length
      : maxParallel;
  var next = 0;

  Future<void> worker() async {
    while (true) {
      if (next >= items.length) return;
      final index = next++;
      results[index] = await action(items[index]);
    }
  }

  await Future.wait(<Future<void>>[
    for (var index = 0; index < workerCount; index++) worker(),
  ]);
  return <R>[for (final result in results) result as R];
}
