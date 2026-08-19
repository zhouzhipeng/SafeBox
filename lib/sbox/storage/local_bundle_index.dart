import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../bytes.dart';
import '../constants.dart';
import '../errors.dart';
import '../format/baseline_jpeg_inspector.dart';
import '../format/bundle_manifest.dart';
import '../format/bundle_path.dart';
import '../format/bundle_preview.dart';
import '../format/canonical_json.dart';
import '../format/strict_json.dart';

enum BundleVerification { manifest, complete }

final class LocalBundleIndexEntry {
  LocalBundleIndexEntry({
    required this.bundleId,
    required this.rootBasename,
    required this.rootRevisionFingerprint,
    required this.manifestPrefixSha256,
    required this.verification,
    required this.manifest,
    this.rootHeaderHex,
    this.rootSize,
    this.encryptedSize,
    this.hasPreview = false,
    int? previewWidth,
    int? previewHeight,
    String? previewSha256,
    this.preview,
  }) : previewWidth = preview?.width ?? previewWidth,
       previewHeight = preview?.height ?? previewHeight,
       previewSha256 = preview == null
           ? previewSha256
           : hexLower(crypto.sha256.convert(preview.encodedBytesView).bytes) {
    final cachedPreviewFields = <Object?>[
      this.previewWidth,
      this.previewHeight,
      this.previewSha256,
    ];
    final presentFields = cachedPreviewFields.where((value) => value != null);
    if (presentFields.isNotEmpty && presentFields.length != 3) {
      throw ArgumentError('Cached preview metadata must be complete');
    }
    if (preview != null && !hasPreview) {
      throw ArgumentError('A cached preview requires hasPreview');
    }
  }

  final String bundleId;
  final String rootBasename;
  final String rootRevisionFingerprint;
  final String manifestPrefixSha256;
  final BundleVerification verification;
  final BundleManifest manifest;
  final String? rootHeaderHex;
  final int? rootSize;
  final int? encryptedSize;
  final bool hasPreview;
  final int? previewWidth;
  final int? previewHeight;
  final String? previewSha256;

  /// Runtime-only bytes loaded from the local JPG cache. They are never
  /// embedded in the JSON index.
  final BundlePreview? preview;

  bool get hasCachedPreview =>
      previewWidth != null && previewHeight != null && previewSha256 != null;

  Map<String, Object?> toJson() => <String, Object?>{
    'bundle_id': bundleId,
    'root_basename': rootBasename,
    'root_revision_fingerprint': rootRevisionFingerprint,
    'manifest_prefix_sha256': manifestPrefixSha256,
    'verification': verification.name,
    if (rootHeaderHex != null) 'root_header_hex': rootHeaderHex,
    if (rootSize != null) 'root_size': rootSize,
    if (encryptedSize != null) 'encrypted_size': encryptedSize,
    'has_preview': hasPreview,
    if (hasCachedPreview) ...<String, Object?>{
      'preview_width': previewWidth,
      'preview_height': previewHeight,
      'preview_sha256': previewSha256,
    },
    'manifest': manifest.toJson(),
  };

  factory LocalBundleIndexEntry.fromJson(Map<String, Object?> json) {
    const requiredKeys = <String>{
      'bundle_id',
      'root_basename',
      'root_revision_fingerprint',
      'manifest_prefix_sha256',
      'verification',
      'manifest',
    };
    const optionalKeys = <String>{
      'root_header_hex',
      'root_size',
      'encrypted_size',
      'has_preview',
      'preview_width',
      'preview_height',
      'preview_sha256',
    };
    final keys = json.keys.toSet();
    if (!keys.containsAll(requiredKeys) ||
        keys.any(
          (key) => !requiredKeys.contains(key) && !optionalKeys.contains(key),
        )) {
      throw const FormatException('Invalid local Bundle index entry');
    }
    final bundleId = json['bundle_id'];
    final rootBasename = json['root_basename'];
    final revision = json['root_revision_fingerprint'];
    final prefixHash = json['manifest_prefix_sha256'];
    final verification = json['verification'];
    final rootHeaderHex = json['root_header_hex'];
    final rootSize = json['root_size'];
    final encryptedSize = json['encrypted_size'];
    final hasPreview = json['has_preview'] ?? false;
    final previewWidth = json['preview_width'];
    final previewHeight = json['preview_height'];
    final previewSha256 = json['preview_sha256'];
    final manifestJson = json['manifest'];
    if (bundleId is! String ||
        rootBasename is! String ||
        revision is! String ||
        revision.isEmpty ||
        revision.length > 4096 ||
        revision.contains('\u0000') ||
        prefixHash is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(prefixHash) ||
        rootHeaderHex != null &&
            (rootHeaderHex is! String ||
                !RegExp(r'^[0-9a-f]+$').hasMatch(rootHeaderHex) ||
                rootHeaderHex.length != 2 * SboxProtocol.rootHeaderLength) ||
        hasPreview is! bool ||
        !_validPreviewMetadata(
          width: previewWidth,
          height: previewHeight,
          sha256: previewSha256,
          hasPreview: hasPreview,
        ) ||
        verification is! String ||
        (verification != 'manifest' && verification != 'complete') ||
        manifestJson is! Map<String, Object?>) {
      throw const FormatException('Invalid local Bundle index entry');
    }
    final parsedRootSize = rootSize == null ? null : _nonNegativeInt(rootSize);
    final parsedEncryptedSize = encryptedSize == null
        ? null
        : _nonNegativeInt(encryptedSize);
    if ((rootSize != null && parsedRootSize == null) ||
        (encryptedSize != null && parsedEncryptedSize == null)) {
      throw const FormatException('Invalid local Bundle index size');
    }
    LocalBundleIndex.validateKey(bundleId, 32);
    final manifest = BundleManifest.fromJson(manifestJson);
    if (manifest.bundleId != bundleId ||
        rootBasename !=
            canonicalBundleBasename(
              bundleId: decodeHex(bundleId),
              shardIndex: 0,
              shardCount: manifest.shardCount,
            )) {
      throw const FormatException('Local Bundle index binding mismatch');
    }
    return LocalBundleIndexEntry(
      bundleId: bundleId,
      rootBasename: rootBasename,
      rootRevisionFingerprint: revision,
      manifestPrefixSha256: prefixHash,
      verification: verification == 'complete'
          ? BundleVerification.complete
          : BundleVerification.manifest,
      manifest: manifest,
      rootHeaderHex: rootHeaderHex as String?,
      rootSize: parsedRootSize,
      encryptedSize: parsedEncryptedSize,
      hasPreview: hasPreview,
      previewWidth: previewWidth as int?,
      previewHeight: previewHeight as int?,
      previewSha256: previewSha256 as String?,
    );
  }

  LocalBundleIndexEntry withPreview(BundlePreview value) =>
      LocalBundleIndexEntry(
        bundleId: bundleId,
        rootBasename: rootBasename,
        rootRevisionFingerprint: rootRevisionFingerprint,
        manifestPrefixSha256: manifestPrefixSha256,
        verification: verification,
        manifest: manifest,
        rootHeaderHex: rootHeaderHex,
        rootSize: rootSize,
        encryptedSize: encryptedSize,
        hasPreview: hasPreview,
        preview: value,
      );

  static bool _validPreviewMetadata({
    required Object? width,
    required Object? height,
    required Object? sha256,
    required bool hasPreview,
  }) {
    final values = <Object?>[width, height, sha256];
    final count = values.where((value) => value != null).length;
    if (count == 0) return true;
    return count == 3 &&
        hasPreview &&
        width is int &&
        width >= 1 &&
        width <= SboxProtocol.maxPreviewDimension &&
        height is int &&
        height >= 1 &&
        height <= SboxProtocol.maxPreviewDimension &&
        width <= SboxProtocol.maxPreviewPixels ~/ height &&
        sha256 is String &&
        RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256);
  }

  static int? _nonNegativeInt(Object? value) {
    if (value is int && value >= 0) return value;
    return null;
  }
}

final class LocalBundleIndex {
  const LocalBundleIndex({required this.sourceId, required this.entries});

  final String sourceId;
  final List<LocalBundleIndexEntry> entries;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': 'SBOX-LOCAL-INDEX-3',
    'source_id': sourceId,
    'entries': entries.map((entry) => entry.toJson()).toList(growable: false),
  };

  String encode() => CanonicalJson.encode(toJson());

  static String manifestPrefixSha256(List<int> prefix) =>
      hexLower(crypto.sha256.convert(prefix).bytes);

  static LocalBundleIndex fromJson(Map<String, Object?> json) {
    if (json.length != 3 ||
        json['schema'] != 'SBOX-LOCAL-INDEX-3' ||
        json['source_id'] is! String ||
        json['entries'] is! List<Object?>) {
      throw const FormatException('Invalid local Bundle index');
    }
    final sourceId = json['source_id']! as String;
    SourceIdValidator.validate(sourceId);
    final values = json['entries']! as List<Object?>;
    if (values.length > 100000) {
      throw const FormatException('Local Bundle index is too large');
    }
    final entries = <LocalBundleIndexEntry>[];
    final ids = <String>{};
    for (final value in values) {
      if (value is! Map<String, Object?>) {
        throw const FormatException('Invalid local Bundle index entry');
      }
      final entry = LocalBundleIndexEntry.fromJson(value);
      if (!ids.add(entry.bundleId)) {
        throw const FormatException('Duplicate local Bundle index entry');
      }
      entries.add(entry);
    }
    return LocalBundleIndex(
      sourceId: sourceId,
      entries: List<LocalBundleIndexEntry>.unmodifiable(entries),
    );
  }

  static void validateKey(String value, int length) {
    if (!RegExp(r'^[0-9a-f]{' + length.toString() + r'}$').hasMatch(value)) {
      throw const SboxException(SboxErrorCode.invalidManifest, '本地索引字段无效');
    }
  }
}

/// The index is a local, rebuildable cache. It is never a source object and is
/// never uploaded with a Bundle.
final class LocalBundleIndexStore {
  LocalBundleIndexStore(this.cipherRoot, {this.fileName = 'index-v3.json'}) {
    if (p.basename(fileName) != fileName ||
        !RegExp(r'^index(?:-[a-z0-9_-]+)?-v3\.json$').hasMatch(fileName)) {
      throw ArgumentError.value(fileName, 'fileName');
    }
  }

  final Directory cipherRoot;
  final String fileName;

  Directory get _syncDirectory =>
      Directory(p.join(cipherRoot.path, '.sbox-sync'));

  Directory get previewDirectory => Directory(
    p.join(
      _syncDirectory.path,
      'previews',
      hexLower(crypto.sha256.convert(utf8.encode(fileName)).bytes)
          .substring(0, 32),
    ),
  );

  File get file => File(p.join(_syncDirectory.path, fileName));

  File previewFile(String bundleId) {
    LocalBundleIndex.validateKey(bundleId, 32);
    return File(p.join(previewDirectory.path, '$bundleId.jpg'));
  }

  Future<LocalBundleIndex?> load({
    String? expectedSourceId,
    bool includePreviews = false,
  }) async {
    if (!await file.exists()) return null;
    try {
      final bytes = await file.readAsBytes();
      if (bytes.length > 16 * 1024 * 1024) return null;
      final value = StrictJsonParser(
        utf8.decode(bytes, allowMalformed: false),
        maximumStringCodeUnits: 1024 * 1024,
      ).parse();
      if (value is! Map<String, Object?>) return null;
      final index = LocalBundleIndex.fromJson(value);
      if (expectedSourceId != null && index.sourceId != expectedSourceId) {
        return null;
      }
      if (!includePreviews) return index;
      return await _loadPreviews(index);
    } on Object {
      // A cache never blocks source enumeration; callers rebuild it.
      return null;
    }
  }

  Future<void> save(LocalBundleIndex index) async {
    SourceIdValidator.validate(index.sourceId);
    final directory = _syncDirectory;
    await directory.create(recursive: true);
    final expectedPreviewNames = <String>{};
    for (final entry in index.entries) {
      if (!entry.hasCachedPreview) continue;
      final previewName = '${entry.bundleId}.jpg';
      expectedPreviewNames.add(previewName);
      final preview = entry.preview;
      if (preview != null) {
        await _savePreview(entry.bundleId, preview);
      }
    }
    final stage = File(
      p.join(
        directory.path,
        '.index-v3.${hexLower(secureRandomBytes(8))}.part',
      ),
    );
    try {
      await stage.writeAsString(index.encode(), flush: true);
      final target = file;
      if (await target.exists()) await target.delete();
      await stage.rename(target.path);
      await _deleteStalePreviews(expectedPreviewNames);
    } finally {
      if (await stage.exists()) await stage.delete();
    }
  }

  Future<void> clear() async {
    if (await file.exists()) await file.delete();
    await _deleteEntityNoFollow(previewDirectory);
  }

  /// Removes all metadata JSON and cached JPG files owned by SafeBox below
  /// [cipherRoot], without touching encrypted Bundle objects.
  static Future<void> clearAll(Directory cipherRoot) async {
    final syncDirectory = Directory(p.join(cipherRoot.path, '.sbox-sync'));
    if (await FileSystemEntity.type(syncDirectory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    await for (final entity in syncDirectory.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name == 'previews') {
        await _deleteEntityNoFollow(entity);
        continue;
      }
      final isIndex = RegExp(r'^index(?:-[a-z0-9_-]+)?-v3\.json$')
          .hasMatch(name);
      final isIndexStage = RegExp(r'^\.index-v3\.[0-9a-f]{16}\.part$')
          .hasMatch(name);
      if (!isIndex && !isIndexStage) {
        continue;
      }
      if (await FileSystemEntity.type(entity.path, followLinks: false) ==
          FileSystemEntityType.file) {
        await File(entity.path).delete();
      }
    }
  }

  Future<LocalBundleIndex> _loadPreviews(LocalBundleIndex index) async {
    final entries = <LocalBundleIndexEntry>[];
    for (var entryIndex = 0; entryIndex < index.entries.length; entryIndex++) {
      final entry = index.entries[entryIndex];
      final preview = await _loadPreview(entry);
      entries.add(preview == null ? entry : entry.withPreview(preview));
      if ((entryIndex + 1) % 32 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    return LocalBundleIndex(
      sourceId: index.sourceId,
      entries: List<LocalBundleIndexEntry>.unmodifiable(entries),
    );
  }

  Future<BundlePreview?> _loadPreview(LocalBundleIndexEntry entry) async {
    if (!entry.hasCachedPreview) return null;
    final target = previewFile(entry.bundleId);
    if (await FileSystemEntity.type(target.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    Uint8List? bytes;
    try {
      final length = await target.length();
      if (length < 1 || length > SboxProtocol.maxPreviewBytes) return null;
      bytes = await target.readAsBytes();
      if (hexLower(crypto.sha256.convert(bytes).bytes) != entry.previewSha256) {
        return null;
      }
      BaselineJpegInspector.validate(
        bytes,
        width: entry.previewWidth!,
        height: entry.previewHeight!,
      );
      return BundlePreview(
        codec: BundlePreviewCodec.baselineJpeg,
        width: entry.previewWidth!,
        height: entry.previewHeight!,
        encodedBytes: bytes,
      );
    } on Object {
      return null;
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
    }
  }

  Future<void> _savePreview(String bundleId, BundlePreview preview) async {
    final bytes = preview.encodedBytes;
    try {
      BaselineJpegInspector.validate(
        bytes,
        width: preview.width,
        height: preview.height,
      );
      await previewDirectory.create(recursive: true);
      final stage = File(
        p.join(
          previewDirectory.path,
          '.$bundleId.${hexLower(secureRandomBytes(8))}.part',
        ),
      );
      try {
        await stage.writeAsBytes(bytes, flush: true);
        final target = previewFile(bundleId);
        if (await target.exists()) await target.delete();
        await stage.rename(target.path);
      } finally {
        if (await stage.exists()) await stage.delete();
      }
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<void> _deleteStalePreviews(Set<String> expectedNames) async {
    if (await FileSystemEntity.type(
          previewDirectory.path,
          followLinks: false,
        ) !=
        FileSystemEntityType.directory) {
      return;
    }
    await for (final entity in previewDirectory.list(followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type != FileSystemEntityType.file) continue;
      final name = p.basename(entity.path);
      if ((name.endsWith('.jpg') && !expectedNames.contains(name)) ||
          name.endsWith('.part')) {
        await File(entity.path).delete();
      }
    }
  }
}

Future<void> _deleteEntityNoFollow(FileSystemEntity entity) async {
  final type = await FileSystemEntity.type(entity.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return;
  if (type == FileSystemEntityType.link) {
    await Link(entity.path).delete();
    return;
  }
  if (type == FileSystemEntityType.file) {
    await File(entity.path).delete();
    return;
  }
  if (type != FileSystemEntityType.directory) return;
  final directory = Directory(entity.path);
  await for (final child in directory.list(followLinks: false)) {
    await _deleteEntityNoFollow(child);
  }
  await directory.delete();
}

abstract final class SourceIdValidator {
  static void validate(String value) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      throw const FormatException('Invalid local Bundle index source ID');
    }
  }
}
