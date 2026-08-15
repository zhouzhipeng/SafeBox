import 'dart:convert';
import 'dart:typed_data';

import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../bytes.dart';
import '../catalog/catalog_state.dart';
import 'credential.dart';
import 'data_source.dart';
import 'remote_config.dart';

enum SourceProvider { local, github, gitee, https }

enum SourceMode { readOnly, readWrite }

enum ConfiguredLocalMode { canonicalCatalog, looseReadOnly }

enum SourceSyncPolicy { manual, wifiOnly, anyNetwork }

final class SourceId {
  SourceId(String value) : value = _validate(value);

  factory SourceId.random() => SourceId(hexLower(secureRandomBytes(16)));

  final String value;

  static String _validate(String value) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      throw ArgumentError.value(value, 'value', 'Invalid source ID');
    }
    return value;
  }

  @override
  bool operator ==(Object other) => other is SourceId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class SourceConfiguration {
  SourceConfiguration({
    required this.sourceId,
    required String displayName,
    required this.provider,
    required this.mode,
    required this.localSyncPath,
    this.localDirectoryMode,
    this.directoryAuthorizationReference,
    this.directoryAuthorizationPlatform,
    this.directoryAuthorizationDisplayName,
    this.owner,
    this.repository,
    this.branchOrRef,
    this.pathPrefix = '',
    this.httpsBaseUri,
    this.credentialReference,
    this.expectedRecipientKeyId,
    this.expectedCatalogSignerKeyId,
    this.catalogId,
    this.highestGeneration,
    this.lastCatalogSha256,
    this.localCatalogMirrorSha256,
    this.lastProviderRevision,
    this.pendingCatalogId,
    this.pendingCatalogGeneration,
    this.pendingCatalogSha256,
    this.pendingBaseCatalogSha256,
    this.syncPolicy = SourceSyncPolicy.manual,
    this.lastLocalSyncAt,
  }) : displayName = unorm.nfc(displayName) {
    _validate();
  }

  final SourceId sourceId;
  final String displayName;
  final SourceProvider provider;
  final SourceMode mode;
  final String localSyncPath;
  final ConfiguredLocalMode? localDirectoryMode;
  final String? directoryAuthorizationReference;
  final String? directoryAuthorizationPlatform;
  final String? directoryAuthorizationDisplayName;
  final String? owner;
  final String? repository;
  final String? branchOrRef;
  final String pathPrefix;
  final Uri? httpsBaseUri;
  final SourceCredentialId? credentialReference;
  final String? expectedRecipientKeyId;
  final String? expectedCatalogSignerKeyId;
  final String? catalogId;
  final int? highestGeneration;
  final String? lastCatalogSha256;
  final String? localCatalogMirrorSha256;
  final RevisionToken? lastProviderRevision;
  final String? pendingCatalogId;
  final int? pendingCatalogGeneration;
  final String? pendingCatalogSha256;
  final String? pendingBaseCatalogSha256;
  final SourceSyncPolicy syncPolicy;
  final DateTime? lastLocalSyncAt;

  bool get isRemote => provider != SourceProvider.local;
  bool get isWritable => mode == SourceMode.readWrite;
  bool get isAuthorizedDirectory => directoryAuthorizationReference != null;
  bool get hasPendingCatalog => pendingCatalogSha256 != null;
  String? get effectiveCatalogId => pendingCatalogId ?? catalogId;

  String get catalogPath =>
      pathPrefix.isEmpty ? 'catalog.sbox' : '$pathPrefix/catalog.sbox';

  CatalogCheckpoint? get checkpoint {
    final fixedCatalogId = catalogId;
    final generation = highestGeneration;
    final hash = lastCatalogSha256;
    if (fixedCatalogId == null || generation == null || hash == null) {
      return null;
    }
    return CatalogCheckpoint(
      catalogId: fixedCatalogId,
      highestGeneration: generation,
      lastCatalogSha256: hash,
      lastProviderRevision: lastProviderRevision == null
          ? null
          : base64Url.encode(lastProviderRevision!.bytes).replaceAll('=', ''),
    );
  }

  SourceConfiguration copyWith({
    String? displayName,
    SourceMode? mode,
    String? localSyncPath,
    ConfiguredLocalMode? localDirectoryMode,
    String? directoryAuthorizationReference,
    String? directoryAuthorizationPlatform,
    String? directoryAuthorizationDisplayName,
    String? owner,
    String? repository,
    String? branchOrRef,
    String? pathPrefix,
    Uri? httpsBaseUri,
    SourceCredentialId? credentialReference,
    String? expectedRecipientKeyId,
    String? expectedCatalogSignerKeyId,
    String? catalogId,
    int? highestGeneration,
    String? lastCatalogSha256,
    String? localCatalogMirrorSha256,
    bool clearLocalCatalogMirror = false,
    RevisionToken? lastProviderRevision,
    String? pendingCatalogId,
    int? pendingCatalogGeneration,
    String? pendingCatalogSha256,
    String? pendingBaseCatalogSha256,
    bool clearPendingCatalog = false,
    SourceSyncPolicy? syncPolicy,
    DateTime? lastLocalSyncAt,
  }) => SourceConfiguration(
    sourceId: sourceId,
    displayName: displayName ?? this.displayName,
    provider: provider,
    mode: mode ?? this.mode,
    localSyncPath: localSyncPath ?? this.localSyncPath,
    localDirectoryMode: localDirectoryMode ?? this.localDirectoryMode,
    directoryAuthorizationReference:
        directoryAuthorizationReference ?? this.directoryAuthorizationReference,
    directoryAuthorizationPlatform:
        directoryAuthorizationPlatform ?? this.directoryAuthorizationPlatform,
    directoryAuthorizationDisplayName:
        directoryAuthorizationDisplayName ??
        this.directoryAuthorizationDisplayName,
    owner: owner ?? this.owner,
    repository: repository ?? this.repository,
    branchOrRef: branchOrRef ?? this.branchOrRef,
    pathPrefix: pathPrefix ?? this.pathPrefix,
    httpsBaseUri: httpsBaseUri ?? this.httpsBaseUri,
    credentialReference: credentialReference ?? this.credentialReference,
    expectedRecipientKeyId:
        expectedRecipientKeyId ?? this.expectedRecipientKeyId,
    expectedCatalogSignerKeyId:
        expectedCatalogSignerKeyId ?? this.expectedCatalogSignerKeyId,
    catalogId: catalogId ?? this.catalogId,
    highestGeneration: highestGeneration ?? this.highestGeneration,
    lastCatalogSha256: lastCatalogSha256 ?? this.lastCatalogSha256,
    localCatalogMirrorSha256: clearLocalCatalogMirror
        ? null
        : localCatalogMirrorSha256 ?? this.localCatalogMirrorSha256,
    lastProviderRevision: lastProviderRevision ?? this.lastProviderRevision,
    pendingCatalogId: clearPendingCatalog
        ? null
        : pendingCatalogId ?? this.pendingCatalogId,
    pendingCatalogGeneration: clearPendingCatalog
        ? null
        : pendingCatalogGeneration ?? this.pendingCatalogGeneration,
    pendingCatalogSha256: clearPendingCatalog
        ? null
        : pendingCatalogSha256 ?? this.pendingCatalogSha256,
    pendingBaseCatalogSha256: clearPendingCatalog
        ? null
        : pendingBaseCatalogSha256 ?? this.pendingBaseCatalogSha256,
    syncPolicy: syncPolicy ?? this.syncPolicy,
    lastLocalSyncAt: lastLocalSyncAt ?? this.lastLocalSyncAt,
  );

  RepositorySourceConfig get repositoryConfig {
    if (provider != SourceProvider.github && provider != SourceProvider.gitee) {
      throw StateError('Configuration is not a repository source');
    }
    return RepositorySourceConfig(
      owner: owner!,
      repository: repository!,
      branch: branchOrRef!,
      pathPrefix: pathPrefix,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'source_id': sourceId.value,
    'display_name': displayName,
    'provider': provider.name,
    'mode': mode.name,
    'local_sync_path': localSyncPath,
    'local_sync_mode': 'full_ciphertext',
    'sync_policy': syncPolicy.name,
    if (localDirectoryMode != null)
      'local_directory_mode': localDirectoryMode!.name,
    if (directoryAuthorizationReference != null)
      'directory_authorization_reference': directoryAuthorizationReference,
    if (directoryAuthorizationPlatform != null)
      'directory_authorization_platform': directoryAuthorizationPlatform,
    if (directoryAuthorizationDisplayName != null)
      'directory_authorization_display_name': directoryAuthorizationDisplayName,
    if (owner != null) 'owner': owner,
    if (repository != null) 'repository': repository,
    if (branchOrRef != null) 'branch_or_ref': branchOrRef,
    if (pathPrefix.isNotEmpty) 'path_prefix': pathPrefix,
    if (httpsBaseUri != null) 'https_base_uri': httpsBaseUri.toString(),
    if (credentialReference != null)
      'credential_reference': credentialReference!.value,
    if (expectedRecipientKeyId != null)
      'expected_recipient_key_id': expectedRecipientKeyId,
    if (expectedCatalogSignerKeyId != null)
      'expected_catalog_signer_key_id': expectedCatalogSignerKeyId,
    if (catalogId != null) 'catalog_id': catalogId,
    if (highestGeneration != null) 'highest_generation': highestGeneration,
    if (lastCatalogSha256 != null) 'last_catalog_sha256': lastCatalogSha256,
    if (localCatalogMirrorSha256 != null)
      'local_catalog_mirror_sha256': localCatalogMirrorSha256,
    if (lastProviderRevision != null)
      'last_provider_revision': base64Url
          .encode(lastProviderRevision!.bytes)
          .replaceAll('=', ''),
    if (pendingCatalogId != null) 'pending_catalog_id': pendingCatalogId,
    if (pendingCatalogGeneration != null)
      'pending_catalog_generation': pendingCatalogGeneration,
    if (pendingCatalogSha256 != null)
      'pending_catalog_sha256': pendingCatalogSha256,
    if (pendingBaseCatalogSha256 != null)
      'pending_base_catalog_sha256': pendingBaseCatalogSha256,
    if (lastLocalSyncAt != null)
      'last_local_sync_at': lastLocalSyncAt!
          .toUtc()
          .toIso8601String()
          .replaceFirst(RegExp(r'\.\d+Z$'), 'Z'),
  };

  factory SourceConfiguration.fromJson(Map<String, Object?> json) {
    const allowedKeys = <String>{
      'source_id',
      'display_name',
      'provider',
      'mode',
      'local_sync_path',
      'local_sync_mode',
      'sync_policy',
      'local_directory_mode',
      'directory_authorization_reference',
      'directory_authorization_platform',
      'directory_authorization_display_name',
      'owner',
      'repository',
      'branch_or_ref',
      'path_prefix',
      'https_base_uri',
      'credential_reference',
      'expected_recipient_key_id',
      'expected_catalog_signer_key_id',
      'catalog_id',
      'highest_generation',
      'last_catalog_sha256',
      'local_catalog_mirror_sha256',
      'last_provider_revision',
      'pending_catalog_id',
      'pending_catalog_generation',
      'pending_catalog_sha256',
      'pending_base_catalog_sha256',
      'last_local_sync_at',
    };
    if (json.keys.any((key) => !allowedKeys.contains(key)) ||
        json['local_sync_mode'] != 'full_ciphertext') {
      throw const FormatException('Unknown source configuration field');
    }

    T? optional<T>(String key) {
      final value = json[key];
      if (value == null) {
        return null;
      }
      if (value is! T) {
        throw const FormatException('Invalid source configuration field');
      }
      return value as T;
    }

    final provider = _enumByName(SourceProvider.values, json['provider']);
    final mode = _enumByName(SourceMode.values, json['mode']);
    final localModeName = optional<String>('local_directory_mode');
    final revisionText = optional<String>('last_provider_revision');
    final syncName = optional<String>('sync_policy') ?? 'manual';
    final syncPolicy = _enumByName(SourceSyncPolicy.values, syncName);
    final timestamp = optional<String>('last_local_sync_at');
    return SourceConfiguration(
      sourceId: SourceId(_requiredString(json, 'source_id')),
      displayName: _requiredString(json, 'display_name'),
      provider: provider,
      mode: mode,
      localSyncPath: _requiredString(json, 'local_sync_path'),
      localDirectoryMode: localModeName == null
          ? null
          : _enumByName(ConfiguredLocalMode.values, localModeName),
      directoryAuthorizationReference: optional<String>(
        'directory_authorization_reference',
      ),
      directoryAuthorizationPlatform: optional<String>(
        'directory_authorization_platform',
      ),
      directoryAuthorizationDisplayName: optional<String>(
        'directory_authorization_display_name',
      ),
      owner: optional<String>('owner'),
      repository: optional<String>('repository'),
      branchOrRef: optional<String>('branch_or_ref'),
      pathPrefix: optional<String>('path_prefix') ?? '',
      httpsBaseUri: optional<String>('https_base_uri') == null
          ? null
          : Uri.parse(optional<String>('https_base_uri')!),
      credentialReference: optional<String>('credential_reference') == null
          ? null
          : SourceCredentialId(optional<String>('credential_reference')!),
      expectedRecipientKeyId: optional<String>('expected_recipient_key_id'),
      expectedCatalogSignerKeyId: optional<String>(
        'expected_catalog_signer_key_id',
      ),
      catalogId: optional<String>('catalog_id'),
      highestGeneration: optional<int>('highest_generation'),
      lastCatalogSha256: optional<String>('last_catalog_sha256'),
      localCatalogMirrorSha256: optional<String>('local_catalog_mirror_sha256'),
      lastProviderRevision: revisionText == null
          ? null
          : RevisionToken(_decodeBase64Url(revisionText)),
      pendingCatalogId: optional<String>('pending_catalog_id'),
      pendingCatalogGeneration: optional<int>('pending_catalog_generation'),
      pendingCatalogSha256: optional<String>('pending_catalog_sha256'),
      pendingBaseCatalogSha256: optional<String>('pending_base_catalog_sha256'),
      syncPolicy: syncPolicy,
      lastLocalSyncAt: timestamp == null ? null : DateTime.parse(timestamp),
    );
  }

  void _validate() {
    final displayBytes = utf8.encode(displayName);
    if (displayBytes.isEmpty ||
        displayBytes.length > 128 ||
        displayName.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
        localSyncPath.isEmpty ||
        localSyncPath.contains('\u0000')) {
      throw ArgumentError('Invalid source configuration');
    }
    _validateHex(expectedRecipientKeyId, 64);
    _validateHex(expectedCatalogSignerKeyId, 64);
    _validateHex(catalogId, 32);
    _validateHex(lastCatalogSha256, 64);
    _validateHex(localCatalogMirrorSha256, 64);
    _validateHex(pendingCatalogId, 32);
    _validateHex(pendingCatalogSha256, 64);
    _validateHex(pendingBaseCatalogSha256, 64);
    final pendingPresence = <bool>[
      pendingCatalogId != null,
      pendingCatalogGeneration != null,
      pendingCatalogSha256 != null,
    ];
    final authorizationPresence = <bool>[
      directoryAuthorizationReference != null,
      directoryAuthorizationPlatform != null,
      directoryAuthorizationDisplayName != null,
    ];
    if ((highestGeneration == null) != (catalogId == null) ||
        (lastCatalogSha256 == null) != (catalogId == null) ||
        (highestGeneration != null && highestGeneration! < 1) ||
        (highestGeneration != null && highestGeneration! > 9007199254740991) ||
        pendingPresence.any((present) => present != pendingPresence.first) ||
        (pendingCatalogGeneration != null && pendingCatalogGeneration! < 1) ||
        (pendingCatalogGeneration != null &&
            pendingCatalogGeneration! > 9007199254740991) ||
        (pendingCatalogId != null &&
            catalogId != null &&
            pendingCatalogId != catalogId) ||
        (pendingCatalogId == null && pendingBaseCatalogSha256 != null) ||
        (pendingCatalogId != null &&
            (pendingBaseCatalogSha256 == null) !=
                (lastCatalogSha256 == null)) ||
        (lastLocalSyncAt != null && !lastLocalSyncAt!.isUtc) ||
        authorizationPresence.any(
          (present) => present != authorizationPresence.first,
        )) {
      throw ArgumentError('Invalid trusted source checkpoint');
    }

    if (directoryAuthorizationReference != null) {
      final reference = directoryAuthorizationReference!;
      final authorizationName = directoryAuthorizationDisplayName!;
      if (utf8.encode(reference).length > 1024 * 1024 ||
          reference.contains('\u0000') ||
          !const <String>{
            'android',
            'ios',
            'macos',
          }.contains(directoryAuthorizationPlatform) ||
          utf8.encode(authorizationName).isEmpty ||
          utf8.encode(authorizationName).length > 512 ||
          authorizationName.contains('\u0000')) {
        throw ArgumentError('Invalid directory authorization reference');
      }
    }

    switch (provider) {
      case SourceProvider.local:
        if (localDirectoryMode == null ||
            owner != null ||
            repository != null ||
            branchOrRef != null ||
            pathPrefix.isNotEmpty ||
            httpsBaseUri != null ||
            credentialReference != null ||
            pendingCatalogId != null ||
            syncPolicy != SourceSyncPolicy.manual ||
            (directoryAuthorizationReference != null &&
                mode != SourceMode.readOnly) ||
            (localDirectoryMode == ConfiguredLocalMode.looseReadOnly &&
                mode != SourceMode.readOnly)) {
          throw ArgumentError('Invalid local source configuration');
        }
      case SourceProvider.github || SourceProvider.gitee:
        if (localDirectoryMode != null ||
            directoryAuthorizationReference != null ||
            owner == null ||
            repository == null ||
            branchOrRef == null ||
            httpsBaseUri != null ||
            (mode == SourceMode.readWrite && credentialReference == null)) {
          throw ArgumentError('Invalid repository source configuration');
        }
        RepositorySourceConfig(
          owner: owner!,
          repository: repository!,
          branch: branchOrRef!,
          pathPrefix: pathPrefix,
        );
      case SourceProvider.https:
        if (mode != SourceMode.readOnly ||
            localDirectoryMode != null ||
            directoryAuthorizationReference != null ||
            owner != null ||
            repository != null ||
            branchOrRef != null ||
            pathPrefix.isNotEmpty ||
            httpsBaseUri == null ||
            credentialReference != null ||
            pendingCatalogId != null) {
          throw ArgumentError('Invalid HTTPS source configuration');
        }
        HttpsSourceConfig(baseUri: httpsBaseUri!);
    }
  }

  static void _validateHex(String? value, int length) {
    if (value != null && !RegExp('^[0-9a-f]{$length}\$').hasMatch(value)) {
      throw ArgumentError('Invalid source identity checkpoint');
    }
  }
}

T _enumByName<T extends Enum>(Iterable<T> values, Object? name) {
  if (name is! String) {
    throw const FormatException('Invalid source configuration enum');
  }
  return values.firstWhere(
    (value) => value.name == name,
    orElse: () =>
        throw const FormatException('Unknown source configuration enum'),
  );
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw const FormatException('Missing source configuration field');
  }
  return value;
}

Uint8List _decodeBase64Url(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw const FormatException('Invalid provider revision');
  }
  final padding = '=' * ((4 - value.length % 4) % 4);
  final bytes = Uint8List.fromList(base64Url.decode('$value$padding'));
  if (base64Url.encode(bytes).replaceAll('=', '') != value) {
    throw const FormatException('Invalid provider revision');
  }
  return bytes;
}
