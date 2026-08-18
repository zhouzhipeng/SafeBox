import 'dart:convert';

import '../bytes.dart';
import 'credential.dart';
import 'remote_config.dart';

enum SourceProvider { local, github, gitee, https }

enum SourceMode { readOnly, readWrite }

enum SourceSyncPolicy { manual, wifiOnly, anyNetwork }

final class SourceId {
  SourceId(String value)
    : value = RegExp(r'^[0-9a-f]{32}$').hasMatch(value)
          ? value
          : throw ArgumentError.value(value, 'value');

  factory SourceId.random() => SourceId(hexLower(secureRandomBytes(16)));

  final String value;

  @override
  bool operator ==(Object other) => other is SourceId && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

final class SourceConfiguration {
  SourceConfiguration({
    required this.sourceId,
    required this.displayName,
    required this.provider,
    required this.mode,
    required this.localSyncPath,
    this.owner,
    this.repository,
    this.pathPrefix = '',
    this.httpsBaseUri,
    this.credentialReference,
    this.expectedRecipientKeyId,
    this.syncPolicy = SourceSyncPolicy.manual,
  }) {
    _validate();
  }

  final SourceId sourceId;
  final String displayName;
  final SourceProvider provider;
  final SourceMode mode;
  final String localSyncPath;
  final String? owner;
  final String? repository;
  final String pathPrefix;
  final Uri? httpsBaseUri;
  final SourceCredentialId? credentialReference;
  final String? expectedRecipientKeyId;
  final SourceSyncPolicy syncPolicy;

  bool get isRemote => provider != SourceProvider.local;
  bool get isWritable => mode == SourceMode.readWrite;

  RepositorySourceConfig get repositoryConfig => RepositorySourceConfig(
    owner: owner!,
    repository: repository!,
    pathPrefix: pathPrefix,
  );

  HttpsSourceConfig get httpsConfig =>
      HttpsSourceConfig(baseUri: httpsBaseUri!);

  Map<String, Object?> toJson() => <String, Object?>{
    'source_id': sourceId.value,
    'display_name': displayName,
    'provider': provider.name,
    'mode': mode.name,
    'local_sync_path': localSyncPath,
    'sync_policy': syncPolicy.name,
    if (owner != null) 'owner': owner,
    if (repository != null) 'repository': repository,
    if (pathPrefix.isNotEmpty) 'path_prefix': pathPrefix,
    if (httpsBaseUri != null) 'https_base_uri': httpsBaseUri.toString(),
    if (credentialReference != null)
      'credential_reference': credentialReference!.value,
    if (expectedRecipientKeyId != null)
      'expected_recipient_key_id': expectedRecipientKeyId,
  };

  factory SourceConfiguration.fromJson(Map<String, Object?> json) {
    const allowed = <String>{
      'source_id',
      'display_name',
      'provider',
      'mode',
      'local_sync_path',
      'sync_policy',
      'owner',
      'repository',
      'path_prefix',
      'https_base_uri',
      'credential_reference',
      'expected_recipient_key_id',
    };
    if (json.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Unknown source configuration field');
    }
    String requiredString(String key) {
      final value = json[key];
      if (value is! String) {
        throw const FormatException('Invalid source configuration');
      }
      return value;
    }

    String? optionalString(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! String) {
        throw const FormatException('Invalid source configuration');
      }
      return value;
    }

    T enumValue<T extends Enum>(Iterable<T> values, String key) {
      final value = requiredString(key);
      return values.firstWhere(
        (item) => item.name == value,
        orElse: () =>
            throw const FormatException('Unknown source configuration enum'),
      );
    }

    final https = optionalString('https_base_uri');
    return SourceConfiguration(
      sourceId: SourceId(requiredString('source_id')),
      displayName: requiredString('display_name'),
      provider: enumValue(SourceProvider.values, 'provider'),
      mode: enumValue(SourceMode.values, 'mode'),
      localSyncPath: requiredString('local_sync_path'),
      owner: optionalString('owner'),
      repository: optionalString('repository'),
      pathPrefix: optionalString('path_prefix') ?? '',
      httpsBaseUri: https == null ? null : Uri.parse(https),
      credentialReference: optionalString('credential_reference') == null
          ? null
          : SourceCredentialId(optionalString('credential_reference')!),
      expectedRecipientKeyId: optionalString('expected_recipient_key_id'),
      syncPolicy: enumValue(SourceSyncPolicy.values, 'sync_policy'),
    );
  }

  void _validate() {
    if (displayName.isEmpty ||
        utf8.encode(displayName).length > 128 ||
        localSyncPath.isEmpty ||
        localSyncPath.contains('\u0000')) {
      throw ArgumentError('Invalid source configuration');
    }
    if (expectedRecipientKeyId != null &&
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedRecipientKeyId!)) {
      throw ArgumentError('Invalid expected identity');
    }
    switch (provider) {
      case SourceProvider.local:
        if (owner != null ||
            repository != null ||
            pathPrefix.isNotEmpty ||
            httpsBaseUri != null ||
            credentialReference != null ||
            mode == SourceMode.readOnly &&
                syncPolicy != SourceSyncPolicy.manual) {
          throw ArgumentError('Invalid local source configuration');
        }
      case SourceProvider.github || SourceProvider.gitee:
        if (owner == null || repository == null || httpsBaseUri != null) {
          throw ArgumentError('Invalid repository source configuration');
        }
        RepositorySourceConfig(
          owner: owner!,
          repository: repository!,
          pathPrefix: pathPrefix,
        );
      case SourceProvider.https:
        if (mode != SourceMode.readOnly ||
            owner != null ||
            repository != null ||
            pathPrefix.isNotEmpty ||
            httpsBaseUri == null ||
            credentialReference != null) {
          throw ArgumentError('Invalid HTTPS source configuration');
        }
        HttpsSourceConfig(baseUri: httpsBaseUri!);
    }
  }
}
