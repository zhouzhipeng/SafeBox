import 'dart:convert';
import 'dart:typed_data';

import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../bytes.dart';
import '../constants.dart';
import '../errors.dart';
import 'bundle_header.dart';
import 'canonical_json.dart';
import 'strict_json.dart';

final class BundleManifest {
  BundleManifest({
    required this.bundleId,
    required this.recipientKeyId,
    required this.contentKind,
    required this.originalName,
    required this.mediaType,
    required this.title,
    required this.description,
    required Iterable<String> tags,
    required this.createdAt,
    required this.logicalPlaintextSize,
    required List<int> logicalPlaintextSha256,
    required this.nominalShardPlaintextSize,
    required this.shardCount,
  }) : tags = List<String>.unmodifiable(tags),
       logicalPlaintextSha256 = Uint8List.fromList(logicalPlaintextSha256) {
    _validate();
  }

  final String bundleId;
  final String recipientKeyId;
  final SboxContentKind contentKind;
  final String originalName;
  final String mediaType;
  final String title;
  final String description;
  final List<String> tags;
  final String createdAt;
  final BigInt logicalPlaintextSize;
  final Uint8List logicalPlaintextSha256;
  final int nominalShardPlaintextSize;
  final int shardCount;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': 'SBOX-MANIFEST-2',
    'bundle_id': bundleId,
    'recipient_key_id': recipientKeyId,
    'content_kind': contentKind.wireName,
    'original_name': originalName,
    'media_type': mediaType,
    'title': title,
    'description': description,
    'tags': tags,
    'created_at': createdAt,
    'logical_plaintext_size': logicalPlaintextSize.toString(),
    'logical_plaintext_sha256': hexLower(logicalPlaintextSha256),
    'nominal_shard_plaintext_size': nominalShardPlaintextSize.toString(),
    'shard_count': shardCount,
  };

  Uint8List encode() {
    final bytes = CanonicalJson.encodeUtf8(toJson());
    if (bytes.isEmpty || bytes.length > SboxProtocol.maxManifestBytes) {
      throw _invalidManifest();
    }
    return bytes;
  }

  static BundleManifest parse(List<int> plaintext) {
    if (plaintext.isEmpty || plaintext.length > SboxProtocol.maxManifestBytes) {
      throw _invalidManifest();
    }
    late final String source;
    try {
      source = utf8.decode(plaintext, allowMalformed: false);
      final value = StrictJsonParser(source).parse();
      if (value is! Map<String, Object?>) throw const FormatException('object');
      final manifest = _fromJson(value);
      final canonical = manifest.encode();
      if (!constantTimeBytesEqual(canonical, plaintext)) {
        throw const FormatException('non-canonical');
      }
      return manifest;
    } on SboxException {
      rethrow;
    } on Object {
      throw _invalidManifest();
    }
  }

  static BundleManifest fromJson(Map<String, Object?> value) =>
      _fromJson(value);

  BigInt expectedShardPlaintextSize(int index) {
    if (index < 0 || index >= shardCount) {
      throw ArgumentError.value(index, 'index');
    }
    if (logicalPlaintextSize == BigInt.zero) return BigInt.zero;
    final offset = BigInt.from(index) * BigInt.from(nominalShardPlaintextSize);
    final remaining = logicalPlaintextSize - offset;
    return remaining <= BigInt.zero
        ? BigInt.zero
        : remaining < BigInt.from(nominalShardPlaintextSize)
        ? remaining
        : BigInt.from(nominalShardPlaintextSize);
  }

  int expectedShardCount() {
    if (logicalPlaintextSize == BigInt.zero) return 1;
    final size = BigInt.from(nominalShardPlaintextSize);
    return ((logicalPlaintextSize + size - BigInt.one) ~/ size).toInt();
  }

  void validateAgainstHeader(BundleHeader header) {
    if (bundleId != hexLower(header.bundleId) ||
        recipientKeyId != hexLower(header.recipientKeyId) ||
        shardCount != header.shardCount ||
        expectedShardCount() != shardCount ||
        expectedShardPlaintextSize(0) != header.shardPlaintextSize) {
      throw const SboxException(
        SboxErrorCode.shardMismatch,
        'Manifest 与公共头不一致',
      );
    }
    if (logicalPlaintextSize == BigInt.zero &&
        (shardCount != 1 || header.shardPlaintextSize != BigInt.zero)) {
      throw const SboxException(SboxErrorCode.shardMismatch, '空 Bundle 分片规划无效');
    }
    if (!header.isRoot || header.shardIndex != 0) {
      throw const SboxException(
        SboxErrorCode.shardMismatch,
        'Manifest 不是根分片 Manifest',
      );
    }
  }

  static BundleManifest _fromJson(Map<String, Object?> json) {
    const keys = <String>{
      'schema',
      'bundle_id',
      'recipient_key_id',
      'content_kind',
      'original_name',
      'media_type',
      'title',
      'description',
      'tags',
      'created_at',
      'logical_plaintext_size',
      'logical_plaintext_sha256',
      'nominal_shard_plaintext_size',
      'shard_count',
    };
    if (json.length != keys.length || !json.keys.toSet().containsAll(keys)) {
      throw _invalidManifest();
    }
    final schema = json['schema'];
    final bundleId = json['bundle_id'];
    final recipientKeyId = json['recipient_key_id'];
    final contentKindName = json['content_kind'];
    final originalName = json['original_name'];
    final mediaType = json['media_type'];
    final title = json['title'];
    final description = json['description'];
    final tags = json['tags'];
    final createdAt = json['created_at'];
    final logicalSize = json['logical_plaintext_size'];
    final logicalHash = json['logical_plaintext_sha256'];
    final nominalSize = json['nominal_shard_plaintext_size'];
    final shardCount = json['shard_count'];
    if (schema != 'SBOX-MANIFEST-2' ||
        bundleId is! String ||
        recipientKeyId is! String ||
        contentKindName is! String ||
        originalName is! String ||
        mediaType is! String ||
        title is! String ||
        description is! String ||
        tags is! List<Object?> ||
        createdAt is! String ||
        logicalSize is! String ||
        logicalHash is! String ||
        nominalSize is! String ||
        shardCount is! int ||
        tags.any((value) => value is! String)) {
      throw _invalidManifest();
    }
    late final SboxContentKind contentKind;
    try {
      contentKind = SboxContentKind.fromWireName(contentKindName);
    } on ArgumentError {
      throw _invalidManifest();
    }
    final size = _parseCanonicalUint64(logicalSize);
    final nominal = _parseCanonicalDecimal(nominalSize);
    if (nominal < SboxProtocol.minNominalShardPlaintextSize ||
        nominal > SboxProtocol.maxNominalShardPlaintextSize ||
        nominal % (1024 * 1024) != 0) {
      throw _invalidManifest();
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(logicalHash)) {
      throw _invalidManifest();
    }
    final result = BundleManifest(
      bundleId: bundleId,
      recipientKeyId: recipientKeyId,
      contentKind: contentKind,
      originalName: originalName,
      mediaType: mediaType,
      title: title,
      description: description,
      tags: tags.cast<String>(),
      createdAt: createdAt,
      logicalPlaintextSize: size,
      logicalPlaintextSha256: decodeHex(logicalHash),
      nominalShardPlaintextSize: nominal,
      shardCount: shardCount,
    );
    return result;
  }

  void _validate() {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(bundleId) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(recipientKeyId) ||
        logicalPlaintextSize.isNegative ||
        logicalPlaintextSize.bitLength > 64 ||
        logicalPlaintextSha256.length != 32 ||
        shardCount < 1 ||
        shardCount > SboxProtocol.maxShardCount ||
        nominalShardPlaintextSize < SboxProtocol.minNominalShardPlaintextSize ||
        nominalShardPlaintextSize > SboxProtocol.maxNominalShardPlaintextSize ||
        nominalShardPlaintextSize % (1024 * 1024) != 0 ||
        expectedShardCount() != shardCount) {
      throw _invalidManifest();
    }
    _validateNfcString(
      originalName,
      maxBytes: SboxProtocol.maxOriginalNameBytes,
    );
    if (originalName.isEmpty ||
        originalName == '.' ||
        originalName == '..' ||
        originalName.contains('\u0000') ||
        originalName.contains('/') ||
        originalName.contains('\\')) {
      throw _invalidManifest();
    }
    final mediaBytes = utf8.encode(mediaType);
    if (mediaBytes.length > 255 ||
        mediaBytes.any((value) => value < 0x20 || value > 0x7e)) {
      throw _invalidManifest();
    }
    _validateNfcString(title, maxBytes: SboxProtocol.maxTitleBytes);
    if (title.isEmpty || title.runes.any(_isC0OrC1)) throw _invalidManifest();
    _validateNfcString(description, maxBytes: SboxProtocol.maxDescriptionBytes);
    if (description.contains('\u0000')) throw _invalidManifest();
    if (tags.length > SboxProtocol.maxTagCount ||
        tags.toSet().length != tags.length) {
      throw _invalidManifest();
    }
    for (final tag in tags) {
      _validateNfcString(tag, maxBytes: SboxProtocol.maxTagBytes);
      if (tag.isEmpty) throw _invalidManifest();
    }
    for (var index = 1; index < tags.length; index++) {
      if (_compareUtf8(tags[index - 1], tags[index]) >= 0) {
        throw _invalidManifest();
      }
    }
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$')
        .hasMatch(createdAt)) {
      throw _invalidManifest();
    }
    try {
      final parsed = DateTime.parse(createdAt);
      if (!parsed.isUtc ||
          parsed.toIso8601String().replaceFirst(RegExp(r'\.000Z$'), 'Z') !=
              createdAt) {
        throw _invalidManifest();
      }
    } on FormatException {
      throw _invalidManifest();
    }
  }

  static void _validateNfcString(String value, {required int maxBytes}) {
    final units = value.codeUnits;
    for (var index = 0; index < units.length; index++) {
      final unit = units[index];
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (index + 1 >= units.length ||
            units[index + 1] < 0xdc00 ||
            units[index + 1] > 0xdfff) {
          throw _invalidManifest();
        }
        index++;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        throw _invalidManifest();
      }
    }
    if (unorm.nfc(value) != value || utf8.encode(value).length > maxBytes) {
      throw _invalidManifest();
    }
  }

  static BigInt _parseCanonicalUint64(String value) {
    final result = _parseCanonicalDecimalBigInt(value);
    if (result.isNegative || result.bitLength > 64) throw _invalidManifest();
    return result;
  }

  static int _parseCanonicalDecimal(String value) {
    final result = _parseCanonicalDecimalBigInt(value);
    if (result.isNegative || result > BigInt.from(0x7fffffff)) {
      throw _invalidManifest();
    }
    return result.toInt();
  }

  static BigInt _parseCanonicalDecimalBigInt(String value) {
    if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value)) {
      throw _invalidManifest();
    }
    try {
      return BigInt.parse(value);
    } on FormatException {
      throw _invalidManifest();
    }
  }

  static int _compareUtf8(String left, String right) {
    final a = utf8.encode(left);
    final b = utf8.encode(right);
    final length = a.length < b.length ? a.length : b.length;
    for (var index = 0; index < length; index++) {
      final comparison = a[index].compareTo(b[index]);
      if (comparison != 0) return comparison;
    }
    return a.length.compareTo(b.length);
  }

  static bool _isC0OrC1(int rune) =>
      (rune >= 0 && rune <= 0x1f) || (rune >= 0x7f && rune <= 0x9f);

  static SboxException _invalidManifest() =>
      const SboxException(SboxErrorCode.invalidManifest, 'SBOX Manifest 无效');
}
