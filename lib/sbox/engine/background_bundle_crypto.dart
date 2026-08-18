import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import '../constants.dart';
import '../format/bundle_header.dart';
import '../format/bundle_manifest.dart';
import '../format/bundle_preview.dart';
import '../../platform/preview_generation_result.dart';
import '../identity/der.dart';
import '../identity/rsa_models.dart';
import '../storage/io_hash.dart' as io_hash;
import 'bundle_probe.dart';
import 'bundle_decryptor.dart';
import 'bundle_encryptor.dart';

/// Runs the CPU-heavy parts of a Bundle transfer away from Flutter's UI
/// isolate. File and memory inputs are represented by small, sendable
/// descriptors; large downloaded objects use [TransferableTypedData] so the
/// UI isolate does not copy every shard while dispatching the work.
abstract final class BackgroundBundleCrypto {
  static bool supportsInput(BundleInput input) =>
      input is FileBundleInput || input is MemoryBundleInput;

  static Future<Uint8List> md5ForInput({
    required BundleInput input,
    required int declaredLength,
    bool validateUtf8 = false,
  }) async {
    final request = _InputRequest.fromInput(input);
    final result = await Isolate.run<Uint8List>(
      () => _md5Worker(
        request,
        declaredLength: declaredLength,
        validateUtf8: validateUtf8,
      ),
      debugName: 'safebox-md5',
    );
    return Uint8List.fromList(result);
  }

  static Future<List<String>> encryptToDirectory({
    required BundleInput input,
    required int declaredLength,
    required BundleEncryptionOptions options,
    required Directory root,
  }) async {
    final request = _EncryptionRequest.fromValues(
      input: input,
      declaredLength: declaredLength,
      options: options,
      rootPath: root.path,
    );
    final result = await Isolate.run<List<String>>(
      () => _encryptWorker(request),
      debugName: 'safebox-encrypt',
    );
    return List<String>.unmodifiable(result);
  }

  static Future<DecryptedBundle> decrypt({
    required Map<String, List<int>> objects,
    required String mnemonic,
    PublicIdentity? expectedIdentity,
  }) async {
    final request = _DecryptRequest.fromValues(
      objects: objects,
      mnemonic: mnemonic,
      expectedIdentity: expectedIdentity,
    );
    final result = await Isolate.run<Map<String, Object?>>(
      () => _decryptWorker(request),
      debugName: 'safebox-decrypt',
    );
    final manifestJson = Map<String, Object?>.from(
      result['manifest']! as Map<Object?, Object?>,
    );
    final rootHeader = BundleHeader.parse(
      Uint8List.fromList(result['rootHeader']! as List<int>),
    );
    final plaintext = (result['plaintext']! as TransferableTypedData)
        .materialize()
        .asUint8List();
    final previewValue = result['preview'];
    final preview = previewValue == null
        ? null
        : _PreviewRequest.fromMap(
            Map<String, Object?>.from(previewValue as Map),
          ).toPreview();
    return DecryptedBundle(
      manifest: BundleManifest.fromJson(manifestJson),
      rootHeader: rootHeader,
      plaintext: plaintext,
      preview: preview,
      status: BundleTrustStatus.complete,
    );
  }

  static Future<void> decryptToFile({
    required Map<String, List<int>> objects,
    required String mnemonic,
    required File destination,
    PublicIdentity? expectedIdentity,
  }) async {
    final request = _DecryptRequest.fromValues(
      objects: objects,
      mnemonic: mnemonic,
      expectedIdentity: expectedIdentity,
    );
    await Isolate.run<void>(
      () => _decryptToFileWorker(request, destination.path),
      debugName: 'safebox-decrypt-file',
    );
  }

  static Future<Uint8List> sha256File(File file) async {
    final result = await Isolate.run<Uint8List>(
      () => _sha256FileWorker(file.path),
      debugName: 'safebox-sha256',
    );
    return Uint8List.fromList(result);
  }

  /// Reads and authenticates the public Manifest without doing the work on
  /// the Flutter isolate. The caller still owns the range request that
  /// obtains [objectPrefix]; only parsing, KDF and AES-GCM are dispatched to
  /// the background isolate.
  static Future<BundleProbeResult> readMetadata({
    required String basename,
    required List<int> objectPrefix,
    required PublicIdentity identity,
  }) async {
    final request = _ManifestRequest(
      basename: basename,
      objectPrefix: Uint8List.fromList(objectPrefix),
      identity: _PublicIdentityRequest.fromIdentity(identity),
    );
    final result = await Isolate.run<Map<String, Object?>>(
      () => _manifestWorker(request),
      debugName: 'safebox-read-manifest',
    );
    final manifestJson = result['manifest'];
    final previewValue = result['preview'];
    final preview = previewValue == null
        ? null
        : _PreviewRequest.fromMap(
            Map<String, Object?>.from(previewValue as Map),
          ).toPreview();
    final manifest = manifestJson == null
        ? null
        : BundleManifest.fromJson(
            Map<String, Object?>.from(manifestJson as Map),
          );
    return BundleProbeResult(
      basename: result['basename']! as String,
      header: BundleHeader.parse(
        Uint8List.fromList(result['header']! as List<int>),
      ),
      manifest: manifest,
      metadata: manifest == null
          ? null
          : BundleMetadata(manifest: manifest, preview: preview),
      status: BundleTrustStatus.values[result['status']! as int],
    );
  }

  static Future<BundleProbeResult> readManifest({
    required String basename,
    required List<int> objectPrefix,
    required PublicIdentity identity,
  }) => readMetadata(
    basename: basename,
    objectPrefix: objectPrefix,
    identity: identity,
  );
}

Future<Uint8List> _md5Worker(
  _InputRequest input, {
  required int declaredLength,
  required bool validateUtf8,
}) async {
  return BundleEncryptor().md5ForInput(
    input: input.open(),
    declaredLength: declaredLength,
    validateUtf8: validateUtf8,
  );
}

Future<List<String>> _encryptWorker(_EncryptionRequest request) async {
  final identity = request.identity.toPublicIdentity();
  final options = BundleEncryptionOptions(
    recipient: identity,
    contentKind: SboxContentKind.fromWireName(request.contentKind),
    originalName: request.originalName,
    mediaType: request.mediaType,
    title: request.title,
    description: request.description,
    tags: request.tags,
    createdAt: request.createdAt,
    targetNominalShardPlaintextSize: request.targetNominalShardPlaintextSize,
    maxObjectBytes: request.maxObjectBytes,
    preview: request.preview?.toPreview(),
    previewRequested: request.previewRequested,
    previewUnavailableReason: request.previewUnavailableReason == null
        ? null
        : PreviewUnavailableReason.values[request.previewUnavailableReason!],
    randomness: request.randomness?.toValue(),
  );
  return BundleEncryptor().encryptToDirectory(
    input: request.input.open(),
    declaredLength: request.declaredLength,
    options: options,
    root: Directory(request.rootPath),
  );
}

Future<Map<String, Object?>> _decryptWorker(_DecryptRequest request) async {
  final decrypted = await BundleDecryptor().decrypt(
    objects: request.materializeObjects(),
    mnemonic: request.mnemonic,
    expectedIdentity: request.expectedIdentity?.toPublicIdentity(),
  );
  final plaintext = decrypted.plaintext;
  final transferable = TransferableTypedData.fromList(<TypedData>[plaintext]);
  plaintext.fillRange(0, plaintext.length, 0);
  final preview = decrypted.preview;
  final previewMap = preview == null
      ? null
      : _PreviewRequest.fromPreview(preview).toMap();
  preview?.dispose();
  return <String, Object?>{
    'manifest': decrypted.manifest.toJson(),
    'rootHeader': decrypted.rootHeader.rawBytes,
    'plaintext': transferable,
    'preview': previewMap,
  };
}

Future<void> _decryptToFileWorker(
  _DecryptRequest request,
  String destinationPath,
) => BundleDecryptor().decryptToFile(
  objects: request.materializeObjects(),
  mnemonic: request.mnemonic,
  destination: File(destinationPath),
  expectedIdentity: request.expectedIdentity?.toPublicIdentity(),
);

Future<Uint8List> _sha256FileWorker(String path) =>
    io_hash.sha256File(File(path));

Future<Map<String, Object?>> _manifestWorker(_ManifestRequest request) async {
  final result = await BundleProbe.readMetadata(
    basename: request.basename,
    objectPrefix: request.objectPrefix,
    identity: request.identity.toPublicIdentity(),
  );
  return <String, Object?>{
    'basename': result.basename,
    'header': result.header.rawBytes,
    'manifest': result.manifest?.toJson(),
    'preview': result.preview == null
        ? null
        : _PreviewRequest.fromPreview(result.preview!).toMap(),
    'status': result.status.index,
  };
}

final class _InputRequest {
  _InputRequest.file(this.filePath) : memory = null;

  _InputRequest.memory(List<int> bytes)
    : filePath = null,
      memory = TransferableTypedData.fromList(<TypedData>[
        Uint8List.fromList(bytes),
      ]);

  final String? filePath;
  final TransferableTypedData? memory;

  factory _InputRequest.fromInput(BundleInput input) {
    if (input is FileBundleInput) return _InputRequest.file(input.file.path);
    if (input is MemoryBundleInput) return _InputRequest.memory(input.bytes);
    throw UnsupportedError(
      'Background Bundle workers support only file and memory inputs',
    );
  }

  BundleInput open() {
    final path = filePath;
    if (path != null) return FileBundleInput(File(path));
    return MemoryBundleInput(memory!.materialize().asUint8List());
  }
}

final class _PublicIdentityRequest {
  _PublicIdentityRequest({
    required List<int> spkiDer,
    required List<int> recipientKeyId,
  }) : spkiDer = Uint8List.fromList(spkiDer),
       recipientKeyId = Uint8List.fromList(recipientKeyId);

  factory _PublicIdentityRequest.fromIdentity(PublicIdentity identity) =>
      _PublicIdentityRequest(
        spkiDer: identity.spkiDer,
        recipientKeyId: identity.recipientKeyId,
      );

  final Uint8List spkiDer;
  final Uint8List recipientKeyId;

  PublicIdentity toPublicIdentity() {
    final der = Uint8List.fromList(spkiDer);
    return PublicIdentity(
      rsaPublicKey: parseRsaSubjectPublicKeyInfo(der),
      spkiDer: der,
      spkiPem: encodePublicKeyPem(der),
      recipientKeyId: recipientKeyId,
    );
  }
}

final class _ManifestRequest {
  _ManifestRequest({
    required this.basename,
    required this.objectPrefix,
    required this.identity,
  });

  final String basename;
  final Uint8List objectPrefix;
  final _PublicIdentityRequest identity;
}

final class _PreviewRequest {
  _PreviewRequest({
    required this.codecId,
    required this.width,
    required this.height,
    required List<int> bytes,
  }) : bytes = Uint8List.fromList(bytes);

  factory _PreviewRequest.fromPreview(BundlePreview preview) =>
      _PreviewRequest(
        codecId: preview.codec.wireId,
        width: preview.width,
        height: preview.height,
        bytes: preview.encodedBytes,
      );

  factory _PreviewRequest.fromMap(Map<String, Object?> value) =>
      _PreviewRequest(
        codecId: value['codec_id']! as int,
        width: value['width']! as int,
        height: value['height']! as int,
        bytes: List<int>.from(value['bytes']! as List),
      );

  final int codecId;
  final int width;
  final int height;
  final Uint8List bytes;

  BundlePreview toPreview() => BundlePreview(
    codec: BundlePreviewCodec.fromWireId(codecId),
    width: width,
    height: height,
    encodedBytes: bytes,
  );

  Map<String, Object?> toMap() => <String, Object?>{
    'codec_id': codecId,
    'width': width,
    'height': height,
    'bytes': bytes,
  };
}

final class _RandomnessRequest {
  _RandomnessRequest({
    required List<int> bundleId,
    required List<int> bundleDek,
    required Iterable<List<int>> noncePrefixes,
    required List<int> oaepSeed,
    required List<int> metadataSalt,
    required List<int> metadataNonce,
  }) : bundleId = Uint8List.fromList(bundleId),
       bundleDek = Uint8List.fromList(bundleDek),
       noncePrefixes = List<Uint8List>.unmodifiable(
         noncePrefixes.map(Uint8List.fromList),
       ),
       oaepSeed = Uint8List.fromList(oaepSeed),
       metadataSalt = Uint8List.fromList(metadataSalt),
       metadataNonce = Uint8List.fromList(metadataNonce);

  factory _RandomnessRequest.fromValue(BundleEncryptionRandomness value) =>
      _RandomnessRequest(
        bundleId: value.bundleId,
        bundleDek: value.bundleDek,
        noncePrefixes: value.noncePrefixes,
        oaepSeed: value.oaepSeed,
        metadataSalt: value.metadataSalt,
        metadataNonce: value.metadataNonce,
      );

  final Uint8List bundleId;
  final Uint8List bundleDek;
  final List<Uint8List> noncePrefixes;
  final Uint8List oaepSeed;
  final Uint8List metadataSalt;
  final Uint8List metadataNonce;

  BundleEncryptionRandomness toValue() => BundleEncryptionRandomness(
    bundleId: bundleId,
    bundleDek: bundleDek,
    noncePrefixes: noncePrefixes,
    oaepSeed: oaepSeed,
    metadataSalt: metadataSalt,
    metadataNonce: metadataNonce,
  );
}

final class _EncryptionRequest {
  _EncryptionRequest({
    required this.input,
    required this.declaredLength,
    required this.identity,
    required this.contentKind,
    required this.originalName,
    required this.mediaType,
    required this.title,
    required this.description,
    required this.tags,
    required this.createdAt,
    required this.targetNominalShardPlaintextSize,
    required this.maxObjectBytes,
    required this.preview,
    required this.previewRequested,
    required this.previewUnavailableReason,
    required this.randomness,
    required this.rootPath,
  });

  factory _EncryptionRequest.fromValues({
    required BundleInput input,
    required int declaredLength,
    required BundleEncryptionOptions options,
    required String rootPath,
  }) => _EncryptionRequest(
    input: _InputRequest.fromInput(input),
    declaredLength: declaredLength,
    identity: _PublicIdentityRequest.fromIdentity(options.recipient),
    contentKind: options.contentKind.wireName,
    originalName: options.originalName,
    mediaType: options.mediaType,
    title: options.title,
    description: options.description,
    tags: List<String>.unmodifiable(options.tags),
    createdAt: options.createdAt,
    targetNominalShardPlaintextSize: options.targetNominalShardPlaintextSize,
    maxObjectBytes: options.maxObjectBytes,
    preview: options.preview == null
        ? null
        : _PreviewRequest.fromPreview(options.preview!),
    previewRequested: options.wantsPreview,
    previewUnavailableReason: options.previewUnavailableReason?.index,
    randomness: options.randomness == null
        ? null
        : _RandomnessRequest.fromValue(options.randomness!),
    rootPath: rootPath,
  );

  final _InputRequest input;
  final int declaredLength;
  final _PublicIdentityRequest identity;
  final String contentKind;
  final String originalName;
  final String mediaType;
  final String? title;
  final String description;
  final List<String> tags;
  final String? createdAt;
  final int targetNominalShardPlaintextSize;
  final int? maxObjectBytes;
  final _PreviewRequest? preview;
  final bool previewRequested;
  final int? previewUnavailableReason;
  final _RandomnessRequest? randomness;
  final String rootPath;
}

final class _ObjectRequest {
  _ObjectRequest(this.basename, List<int> bytes)
    : bytes = TransferableTypedData.fromList(<TypedData>[
        Uint8List.fromList(bytes),
      ]);

  final String basename;
  final TransferableTypedData bytes;
}

final class _DecryptRequest {
  _DecryptRequest({
    required this.objects,
    required this.mnemonic,
    required this.expectedIdentity,
  });

  factory _DecryptRequest.fromValues({
    required Map<String, List<int>> objects,
    required String mnemonic,
    required PublicIdentity? expectedIdentity,
  }) => _DecryptRequest(
    objects: List<_ObjectRequest>.unmodifiable(
      objects.entries.map((entry) => _ObjectRequest(entry.key, entry.value)),
    ),
    mnemonic: mnemonic,
    expectedIdentity: expectedIdentity == null
        ? null
        : _PublicIdentityRequest.fromIdentity(expectedIdentity),
  );

  final List<_ObjectRequest> objects;
  final String mnemonic;
  final _PublicIdentityRequest? expectedIdentity;

  Map<String, List<int>> materializeObjects() => <String, List<int>>{
    for (final object in objects)
      object.basename: object.bytes.materialize().asUint8List(),
  };
}
