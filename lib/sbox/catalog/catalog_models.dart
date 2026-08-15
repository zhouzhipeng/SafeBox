import 'dart:convert';

import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../constants.dart';
import '../errors.dart';

const int _maximumSafeInteger = 9007199254740991;
final BigInt _maximumUint64 = (BigInt.one << 64) - BigInt.one;
final RegExp _idPattern = RegExp(r'^[0-9a-f]{32}$');
final RegExp _hashPattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _decimalPattern = RegExp(r'^(0|[1-9][0-9]*)$');
final RegExp _utcSecondsPattern = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$',
);

enum CatalogPayloadMode { single, multipart }

final class CatalogPart {
  CatalogPart({
    required this.index,
    required this.objectPath,
    required this.fileId,
    required this.plaintextOffset,
    required this.plaintextSize,
    required this.plaintextSha256,
    required this.sboxSize,
    required this.sboxSha256,
  }) {
    _validate();
  }

  final int index;
  final String objectPath;
  final String fileId;
  final BigInt plaintextOffset;
  final BigInt plaintextSize;
  final String plaintextSha256;
  final BigInt sboxSize;
  final String sboxSha256;

  String get canonicalObjectPath =>
      'objects/${fileId.substring(0, 2)}/$fileId.sbox';

  Map<String, Object?> toJson() => <String, Object?>{
    'index': index,
    'object_path': objectPath,
    'file_id': fileId,
    'plaintext_offset': plaintextOffset.toString(),
    'plaintext_size': plaintextSize.toString(),
    'plaintext_sha256': plaintextSha256,
    'sbox_size': sboxSize.toString(),
    'sbox_sha256': sboxSha256,
  };

  factory CatalogPart.fromJson(Map<String, Object?> json) {
    _requireKeys(json, const <String>{
      'index',
      'object_path',
      'file_id',
      'plaintext_offset',
      'plaintext_size',
      'plaintext_sha256',
      'sbox_size',
      'sbox_sha256',
    });
    return CatalogPart(
      index: _safeInteger(json['index']),
      objectPath: _string(json['object_path']),
      fileId: _string(json['file_id']),
      plaintextOffset: _decimalUint64(json['plaintext_offset']),
      plaintextSize: _decimalUint64(json['plaintext_size']),
      plaintextSha256: _string(json['plaintext_sha256']),
      sboxSize: _decimalUint64(json['sbox_size']),
      sboxSha256: _string(json['sbox_sha256']),
    );
  }

  void _validate() {
    if (index < 0 ||
        index > _maximumSafeInteger ||
        !_idPattern.hasMatch(fileId) ||
        objectPath != canonicalObjectPath ||
        plaintextOffset.isNegative ||
        plaintextOffset > _maximumUint64 ||
        plaintextSize.isNegative ||
        plaintextSize > _maximumUint64 ||
        !_hashPattern.hasMatch(plaintextSha256) ||
        sboxSize <= BigInt.zero ||
        sboxSize > _maximumUint64 ||
        !_hashPattern.hasMatch(sboxSha256)) {
      throw _catalogError();
    }
  }
}

final class CatalogPayload {
  CatalogPayload({
    required this.mode,
    required this.plaintextSize,
    required this.plaintextSha256,
    required List<CatalogPart> parts,
    this.multipartId,
    this.partPlaintextSize,
  }) : parts = List<CatalogPart>.unmodifiable(
         List<CatalogPart>.from(parts)
           ..sort((a, b) => a.index.compareTo(b.index)),
       ) {
    _validate();
  }

  final CatalogPayloadMode mode;
  final String? multipartId;
  final BigInt plaintextSize;
  final String plaintextSha256;
  final BigInt? partPlaintextSize;
  final List<CatalogPart> parts;

  Map<String, Object?> toJson() {
    final result = <String, Object?>{
      'mode': mode.name,
      'plaintext_size': plaintextSize.toString(),
      'plaintext_sha256': plaintextSha256,
      'parts': parts.map((part) => part.toJson()).toList(growable: false),
    };
    if (mode == CatalogPayloadMode.multipart) {
      result['multipart_id'] = multipartId;
      result['part_plaintext_size'] = partPlaintextSize.toString();
    }
    return result;
  }

  factory CatalogPayload.fromJson(Map<String, Object?> json) {
    final modeText = _string(json['mode']);
    final mode = switch (modeText) {
      'single' => CatalogPayloadMode.single,
      'multipart' => CatalogPayloadMode.multipart,
      _ => throw _catalogError(),
    };
    final expectedKeys = <String>{
      'mode',
      'plaintext_size',
      'plaintext_sha256',
      'parts',
      if (mode == CatalogPayloadMode.multipart) 'multipart_id',
      if (mode == CatalogPayloadMode.multipart) 'part_plaintext_size',
    };
    _requireKeys(json, expectedKeys);
    final partValues = _list(json['parts']);
    final parsedParts = partValues
        .map((value) => CatalogPart.fromJson(_map(value)))
        .toList(growable: false);
    for (var index = 0; index < parsedParts.length; index++) {
      if (parsedParts[index].index != index) {
        throw _catalogError();
      }
    }
    return CatalogPayload(
      mode: mode,
      multipartId: mode == CatalogPayloadMode.multipart
          ? _string(json['multipart_id'])
          : null,
      plaintextSize: _decimalUint64(json['plaintext_size']),
      plaintextSha256: _string(json['plaintext_sha256']),
      partPlaintextSize: mode == CatalogPayloadMode.multipart
          ? _decimalUint64(json['part_plaintext_size'])
          : null,
      parts: parsedParts,
    );
  }

  void _validate() {
    if (plaintextSize.isNegative ||
        plaintextSize > _maximumUint64 ||
        !_hashPattern.hasMatch(plaintextSha256)) {
      throw _catalogError();
    }
    var expectedOffset = BigInt.zero;
    for (var index = 0; index < parts.length; index++) {
      final part = parts[index];
      if (part.index != index || part.plaintextOffset != expectedOffset) {
        throw _catalogError();
      }
      expectedOffset += part.plaintextSize;
    }
    if (expectedOffset != plaintextSize) {
      throw _catalogError();
    }

    switch (mode) {
      case CatalogPayloadMode.single:
        if (multipartId != null ||
            partPlaintextSize != null ||
            parts.length != 1 ||
            parts.single.plaintextOffset != BigInt.zero ||
            parts.single.plaintextSize != plaintextSize ||
            parts.single.plaintextSha256 != plaintextSha256) {
          throw _catalogError();
        }
      case CatalogPayloadMode.multipart:
        final partSize = partPlaintextSize;
        if (multipartId == null ||
            !_idPattern.hasMatch(multipartId!) ||
            partSize == null ||
            partSize < BigInt.from(SboxV1.minPartPlaintextSize) ||
            partSize > BigInt.from(SboxV1.maxPartPlaintextSize) ||
            plaintextSize <= BigInt.zero ||
            parts.length < 2 ||
            parts.length > 10000) {
          throw _catalogError();
        }
        for (var index = 0; index < parts.length; index++) {
          final length = parts[index].plaintextSize;
          if (length <= BigInt.zero ||
              (index < parts.length - 1 && length != partSize) ||
              (index == parts.length - 1 && length > partSize)) {
            throw _catalogError();
          }
        }
    }
  }
}

final class CatalogEntry {
  CatalogEntry({
    required this.entryId,
    required this.revision,
    required String title,
    required String description,
    required String originalName,
    required String mediaType,
    required this.payload,
    required List<String> tags,
    required this.createdAt,
    required this.updatedAt,
  }) : title = unorm.nfc(title),
       description = unorm.nfc(description),
       originalName = unorm.nfc(originalName),
       mediaType = unorm.nfc(mediaType),
       tags = List<String>.unmodifiable(
         tags.map(unorm.nfc).toList()..sort(_compareUtf8),
       ) {
    _validate();
  }

  final String entryId;
  final int revision;
  final String title;
  final String description;
  final String originalName;
  final String mediaType;
  final CatalogPayload payload;
  final List<String> tags;
  final String createdAt;
  final String updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'entry_id': entryId,
    'revision': revision,
    'title': title,
    'description': description,
    'original_name': originalName,
    'media_type': mediaType,
    'payload': payload.toJson(),
    'tags': tags,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  factory CatalogEntry.fromJson(Map<String, Object?> json) {
    _requireKeys(json, const <String>{
      'entry_id',
      'revision',
      'title',
      'description',
      'original_name',
      'media_type',
      'payload',
      'tags',
      'created_at',
      'updated_at',
    });
    final rawTitle = _string(json['title']);
    final rawDescription = _string(json['description']);
    final rawOriginalName = _string(json['original_name']);
    final rawMediaType = _string(json['media_type']);
    if (unorm.nfc(rawTitle) != rawTitle ||
        unorm.nfc(rawDescription) != rawDescription ||
        unorm.nfc(rawOriginalName) != rawOriginalName ||
        unorm.nfc(rawMediaType) != rawMediaType) {
      throw _catalogError();
    }
    final rawTags = _list(json['tags']).map(_string).toList(growable: false);
    if (!_isSorted(rawTags, _compareUtf8)) {
      throw _catalogError();
    }
    return CatalogEntry(
      entryId: _string(json['entry_id']),
      revision: _safeInteger(json['revision']),
      title: rawTitle,
      description: rawDescription,
      originalName: rawOriginalName,
      mediaType: rawMediaType,
      payload: CatalogPayload.fromJson(_map(json['payload'])),
      tags: rawTags,
      createdAt: _string(json['created_at']),
      updatedAt: _string(json['updated_at']),
    );
  }

  void _validate() {
    final titleLength = utf8.encode(title).length;
    final descriptionLength = utf8.encode(description).length;
    final nameLength = utf8.encode(originalName).length;
    final mediaBytes = utf8.encode(mediaType);
    if (!_idPattern.hasMatch(entryId) ||
        revision < 1 ||
        revision > _maximumSafeInteger ||
        titleLength < 1 ||
        titleLength > 256 ||
        _hasC0OrC1(title) ||
        descriptionLength > 4096 ||
        description.contains('\u0000') ||
        originalName.isEmpty ||
        nameLength > 1024 ||
        originalName.contains('\u0000') ||
        originalName.contains('/') ||
        originalName.contains('\\') ||
        originalName == '.' ||
        originalName == '..' ||
        mediaBytes.length > 255 ||
        mediaBytes.any((byte) => byte > 0x7f || byte < 0x20) ||
        tags.length > 32 ||
        !_validTimestamp(createdAt) ||
        !_validTimestamp(updatedAt)) {
      throw _catalogError();
    }
    final uniqueTags = <String>{};
    for (final tag in tags) {
      final length = utf8.encode(tag).length;
      if (tag != unorm.nfc(tag) ||
          length < 1 ||
          length > 64 ||
          !uniqueTags.add(tag)) {
        throw _catalogError();
      }
    }
  }
}

final class CatalogTombstone {
  CatalogTombstone({
    required this.entryId,
    required this.revision,
    required this.deletedAt,
  }) {
    if (!_idPattern.hasMatch(entryId) ||
        revision < 1 ||
        revision > _maximumSafeInteger ||
        !_validTimestamp(deletedAt)) {
      throw _catalogError();
    }
  }

  final String entryId;
  final int revision;
  final String deletedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'entry_id': entryId,
    'revision': revision,
    'deleted_at': deletedAt,
  };

  factory CatalogTombstone.fromJson(Map<String, Object?> json) {
    _requireKeys(json, const <String>{'entry_id', 'revision', 'deleted_at'});
    return CatalogTombstone(
      entryId: _string(json['entry_id']),
      revision: _safeInteger(json['revision']),
      deletedAt: _string(json['deleted_at']),
    );
  }
}

final class SboxCatalog {
  SboxCatalog({
    required this.catalogId,
    required this.generation,
    required this.previousCatalogSha256,
    required this.recipientKeyId,
    required this.signerKeyId,
    required this.createdAt,
    required this.updatedAt,
    required List<CatalogEntry> entries,
    required List<CatalogTombstone> tombstones,
  }) : entries = List<CatalogEntry>.unmodifiable(
         List<CatalogEntry>.from(entries)
           ..sort((a, b) => a.entryId.compareTo(b.entryId)),
       ),
       tombstones = List<CatalogTombstone>.unmodifiable(
         List<CatalogTombstone>.from(tombstones)
           ..sort((a, b) => a.entryId.compareTo(b.entryId)),
       ) {
    _validate();
  }

  final String catalogId;
  final int generation;
  final String? previousCatalogSha256;
  final String recipientKeyId;
  final String signerKeyId;
  final String createdAt;
  final String updatedAt;
  final List<CatalogEntry> entries;
  final List<CatalogTombstone> tombstones;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': SboxV1.catalogSchema,
    'catalog_id': catalogId,
    'generation': generation,
    'previous_catalog_sha256': previousCatalogSha256,
    'recipient_key_id': recipientKeyId,
    'signer_key_id': signerKeyId,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'entries': entries.map((entry) => entry.toJson()).toList(growable: false),
    'tombstones': tombstones
        .map((tombstone) => tombstone.toJson())
        .toList(growable: false),
  };

  factory SboxCatalog.fromJson(Map<String, Object?> json) {
    _requireKeys(json, const <String>{
      'schema',
      'catalog_id',
      'generation',
      'previous_catalog_sha256',
      'recipient_key_id',
      'signer_key_id',
      'created_at',
      'updated_at',
      'entries',
      'tombstones',
    });
    if (json['schema'] != SboxV1.catalogSchema) {
      throw _catalogError();
    }
    final entries = _list(json['entries'])
        .map((value) => CatalogEntry.fromJson(_map(value)))
        .toList(growable: false);
    final tombstones = _list(json['tombstones'])
        .map((value) => CatalogTombstone.fromJson(_map(value)))
        .toList(growable: false);
    if (!_isSorted(entries, (a, b) => a.entryId.compareTo(b.entryId)) ||
        !_isSorted(tombstones, (a, b) => a.entryId.compareTo(b.entryId))) {
      throw _catalogError();
    }
    final previous = json['previous_catalog_sha256'];
    if (previous != null && previous is! String) {
      throw _catalogError();
    }
    return SboxCatalog(
      catalogId: _string(json['catalog_id']),
      generation: _safeInteger(json['generation']),
      previousCatalogSha256: previous as String?,
      recipientKeyId: _string(json['recipient_key_id']),
      signerKeyId: _string(json['signer_key_id']),
      createdAt: _string(json['created_at']),
      updatedAt: _string(json['updated_at']),
      entries: entries,
      tombstones: tombstones,
    );
  }

  void _validate() {
    if (!_idPattern.hasMatch(catalogId) ||
        generation < 1 ||
        generation > _maximumSafeInteger ||
        (generation == 1
            ? previousCatalogSha256 != null
            : previousCatalogSha256 == null ||
                  !_hashPattern.hasMatch(previousCatalogSha256!)) ||
        !_hashPattern.hasMatch(recipientKeyId) ||
        !_hashPattern.hasMatch(signerKeyId) ||
        !_validTimestamp(createdAt) ||
        !_validTimestamp(updatedAt) ||
        entries.length > 50000 ||
        tombstones.length > 50000) {
      throw _catalogError();
    }

    final activeIds = <String>{};
    final tombstoneIds = <String>{};
    final fileIds = <String>{};
    final objectPaths = <String>{};
    final multipartIds = <String>{};
    var totalParts = 0;
    for (final entry in entries) {
      if (!activeIds.add(entry.entryId)) {
        throw _catalogError();
      }
      totalParts += entry.payload.parts.length;
      final multipartId = entry.payload.multipartId;
      if (multipartId != null && !multipartIds.add(multipartId)) {
        throw _catalogError();
      }
      for (final part in entry.payload.parts) {
        if (!fileIds.add(part.fileId) || !objectPaths.add(part.objectPath)) {
          throw _catalogError();
        }
      }
    }
    for (final tombstone in tombstones) {
      if (!tombstoneIds.add(tombstone.entryId) ||
          activeIds.contains(tombstone.entryId)) {
        throw _catalogError();
      }
    }
    if (totalParts > 100000) {
      throw _catalogError();
    }
  }
}

String formatUtcSeconds(DateTime value) {
  final utc = value.toUtc();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${two(utc.month)}-${two(utc.day)}T'
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}Z';
}

Map<String, Object?> _map(Object? value) {
  if (value is! Map<String, Object?>) {
    throw _catalogError();
  }
  return value;
}

List<Object?> _list(Object? value) {
  if (value is! List<Object?>) {
    throw _catalogError();
  }
  return value;
}

String _string(Object? value) {
  if (value is! String) {
    throw _catalogError();
  }
  return value;
}

int _safeInteger(Object? value) {
  if (value is! int || value.abs() > _maximumSafeInteger) {
    throw _catalogError();
  }
  return value;
}

BigInt _decimalUint64(Object? value) {
  final text = _string(value);
  if (!_decimalPattern.hasMatch(text)) {
    throw _catalogError();
  }
  final result = BigInt.parse(text);
  if (result > _maximumUint64) {
    throw _catalogError();
  }
  return result;
}

void _requireKeys(Map<String, Object?> json, Set<String> expected) {
  if (json.length != expected.length ||
      !json.keys.toSet().containsAll(expected)) {
    throw _catalogError();
  }
}

bool _validTimestamp(String value) {
  if (!_utcSecondsPattern.hasMatch(value)) {
    return false;
  }
  try {
    return formatUtcSeconds(DateTime.parse(value)) == value;
  } on FormatException {
    return false;
  }
}

bool _hasC0OrC1(String value) =>
    value.runes.any((rune) => rune <= 0x1f || (rune >= 0x7f && rune <= 0x9f));

int _compareUtf8(String left, String right) {
  final leftBytes = utf8.encode(left);
  final rightBytes = utf8.encode(right);
  final length = leftBytes.length < rightBytes.length
      ? leftBytes.length
      : rightBytes.length;
  for (var index = 0; index < length; index++) {
    final comparison = leftBytes[index].compareTo(rightBytes[index]);
    if (comparison != 0) {
      return comparison;
    }
  }
  return leftBytes.length.compareTo(rightBytes.length);
}

bool _isSorted<T>(List<T> values, int Function(T, T) compare) {
  for (var index = 1; index < values.length; index++) {
    if (compare(values[index - 1], values[index]) >= 0) {
      return false;
    }
  }
  return true;
}

SboxException _catalogError() =>
    const SboxException(SboxErrorCode.catalog, '加密目录格式无效');
