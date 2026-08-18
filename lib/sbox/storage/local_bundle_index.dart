import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../bytes.dart';
import '../errors.dart';
import '../format/bundle_manifest.dart';
import '../format/bundle_path.dart';
import '../format/canonical_json.dart';
import '../format/strict_json.dart';

enum BundleVerification { manifest, complete }

final class LocalBundleIndexEntry {
  const LocalBundleIndexEntry({
    required this.bundleId,
    required this.rootBasename,
    required this.rootRevisionFingerprint,
    required this.manifestPrefixSha256,
    required this.verification,
    required this.manifest,
  });

  final String bundleId;
  final String rootBasename;
  final String rootRevisionFingerprint;
  final String manifestPrefixSha256;
  final BundleVerification verification;
  final BundleManifest manifest;

  Map<String, Object?> toJson() => <String, Object?>{
    'bundle_id': bundleId,
    'root_basename': rootBasename,
    'root_revision_fingerprint': rootRevisionFingerprint,
    'manifest_prefix_sha256': manifestPrefixSha256,
    'verification': verification.name,
    'manifest': manifest.toJson(),
  };

  factory LocalBundleIndexEntry.fromJson(Map<String, Object?> json) {
    const keys = <String>{
      'bundle_id',
      'root_basename',
      'root_revision_fingerprint',
      'manifest_prefix_sha256',
      'verification',
      'manifest',
    };
    if (json.length != keys.length || !json.keys.toSet().containsAll(keys)) {
      throw const FormatException('Invalid local Bundle index entry');
    }
    final bundleId = json['bundle_id'];
    final rootBasename = json['root_basename'];
    final revision = json['root_revision_fingerprint'];
    final prefixHash = json['manifest_prefix_sha256'];
    final verification = json['verification'];
    final manifestJson = json['manifest'];
    if (bundleId is! String ||
        rootBasename is! String ||
        revision is! String ||
        revision.isEmpty ||
        revision.length > 4096 ||
        revision.contains('\u0000') ||
        prefixHash is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(prefixHash) ||
        verification is! String ||
        (verification != 'manifest' && verification != 'complete') ||
        manifestJson is! Map<String, Object?>) {
      throw const FormatException('Invalid local Bundle index entry');
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
    );
  }
}

final class LocalBundleIndex {
  const LocalBundleIndex({required this.sourceId, required this.entries});

  final String sourceId;
  final List<LocalBundleIndexEntry> entries;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': 'SBOX-LOCAL-INDEX-2',
    'source_id': sourceId,
    'entries': entries.map((entry) => entry.toJson()).toList(growable: false),
  };

  String encode() => CanonicalJson.encode(toJson());

  static String manifestPrefixSha256(List<int> prefix) =>
      hexLower(crypto.sha256.convert(prefix).bytes);

  static LocalBundleIndex fromJson(Map<String, Object?> json) {
    if (json.length != 3 ||
        json['schema'] != 'SBOX-LOCAL-INDEX-2' ||
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
  LocalBundleIndexStore(this.cipherRoot);

  final Directory cipherRoot;

  File get file => File(p.join(cipherRoot.path, '.sbox-sync', 'index-v2.json'));

  Future<LocalBundleIndex?> load({String? expectedSourceId}) async {
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
      return index;
    } on Object {
      // A cache never blocks source enumeration; callers rebuild it.
      return null;
    }
  }

  Future<void> save(LocalBundleIndex index) async {
    final directory = Directory(p.join(cipherRoot.path, '.sbox-sync'));
    await directory.create(recursive: true);
    final stage = File(
      p.join(
        directory.path,
        '.index-v2.${hexLower(secureRandomBytes(8))}.part',
      ),
    );
    try {
      await stage.writeAsString(index.encode(), flush: true);
      final target = file;
      if (await target.exists()) await target.delete();
      await stage.rename(target.path);
    } finally {
      if (await stage.exists()) await stage.delete();
    }
  }

  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }
}

abstract final class SourceIdValidator {
  static void validate(String value) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      throw const FormatException('Invalid local Bundle index source ID');
    }
  }
}
