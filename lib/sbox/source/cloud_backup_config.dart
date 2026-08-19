import 'dart:convert';

import 'credential.dart';
import 'remote_config.dart';

/// One repository endpoint in the public-cloud pair. Tokens are referenced by
/// ID only; the token bytes live in the platform secure credential store.
final class CloudRepositoryEndpoint {
  CloudRepositoryEndpoint({
    required this.owner,
    required this.repository,
    required this.credentialId,
    this.enabled = true,
    this.pathPrefix = '',
    this.repositoryUrl,
  }) {
    _sourceConfig();
  }

  final String owner;
  final String repository;
  final String pathPrefix;
  final SourceCredentialId credentialId;
  final bool enabled;
  final String? repositoryUrl;

  String webUrl({required String host}) =>
      repositoryUrl ?? 'https://$host/$owner/$repository';

  /// Parses the single repository address shown in the UI while retaining the
  /// existing provider model used by the sync engine.
  factory CloudRepositoryEndpoint.fromRepositoryUrl(
    String value, {
    required SourceCredentialId credentialId,
    required String expectedHost,
    bool enabled = true,
  }) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.toLowerCase() != expectedHost.toLowerCase() ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('Invalid repository address');
    }
    final segments = uri.pathSegments.where((segment) => segment.isNotEmpty);
    final parts = segments.toList(growable: false);
    if (parts.length != 2) {
      throw const FormatException(
        'Repository address must include owner and repository',
      );
    }
    final repository = parts[1].endsWith('.git')
        ? parts[1].substring(0, parts[1].length - 4)
        : parts[1];
    return CloudRepositoryEndpoint(
      owner: parts[0],
      repository: repository,
      credentialId: credentialId,
      enabled: enabled,
      repositoryUrl: value,
    );
  }

  RepositorySourceConfig get repositoryConfig => _sourceConfig();

  Map<String, Object?> toJson() => <String, Object?>{
    'owner': owner,
    'repository': repository,
    'enabled': enabled,
    if (pathPrefix.isNotEmpty) 'path_prefix': pathPrefix,
    'credential_id': credentialId.value,
    if (repositoryUrl != null) 'repository_url': repositoryUrl,
  };

  factory CloudRepositoryEndpoint.fromJson(Map<String, Object?> json) {
    const allowed = <String>{
      'owner',
      'repository',
      'enabled',
      'path_prefix',
      'credential_id',
      'repository_url',
    };
    if (json.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Unknown cloud repository field');
    }
    String requiredString(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw const FormatException('Invalid cloud repository field');
      }
      return value;
    }

    final prefix = json['path_prefix'] ?? '';
    if (prefix is! String) {
      throw const FormatException('Invalid cloud repository path prefix');
    }
    final repositoryUrlValue = json['repository_url'];
    if (repositoryUrlValue != null && repositoryUrlValue is! String) {
      throw const FormatException('Invalid cloud repository URL');
    }
    final String? repositoryUrl = repositoryUrlValue as String?;
    final enabledValue = json['enabled'] ?? true;
    if (enabledValue is! bool) {
      throw const FormatException('Invalid cloud repository enabled flag');
    }
    return CloudRepositoryEndpoint(
      owner: requiredString('owner'),
      repository: requiredString('repository'),
      pathPrefix: prefix,
      credentialId: SourceCredentialId(requiredString('credential_id')),
      enabled: enabledValue,
      repositoryUrl: repositoryUrl,
    );
  }

  RepositorySourceConfig _sourceConfig() => RepositorySourceConfig(
    owner: owner,
    repository: repository,
    pathPrefix: pathPrefix,
  );
}

/// A single SafeBox configuration containing the local encrypted mirror and
/// the two public API repositories that receive every object.
final class CloudBackupConfiguration {
  CloudBackupConfiguration({
    required this.backupDirectory,
    required this.github,
    required this.gitee,
  }) {
    if (backupDirectory.trim().isEmpty || backupDirectory.contains('\u0000')) {
      throw ArgumentError.value(backupDirectory, 'backupDirectory');
    }
  }

  final String backupDirectory;
  final CloudRepositoryEndpoint github;
  final CloudRepositoryEndpoint gitee;

  Map<String, Object?> toJson() => <String, Object?>{
    'backup_directory': backupDirectory,
    'github': github.toJson(),
    'gitee': gitee.toJson(),
  };

  factory CloudBackupConfiguration.fromJson(Map<String, Object?> json) {
    const allowed = <String>{'backup_directory', 'github', 'gitee'};
    if (json.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Unknown cloud backup configuration field');
    }
    final directory = json['backup_directory'];
    final github = json['github'];
    final gitee = json['gitee'];
    if (directory is! String ||
        github is! Map<String, Object?> ||
        gitee is! Map<String, Object?>) {
      throw const FormatException('Invalid cloud backup configuration');
    }
    return CloudBackupConfiguration(
      backupDirectory: directory,
      github: CloudRepositoryEndpoint.fromJson(github),
      gitee: CloudRepositoryEndpoint.fromJson(gitee),
    );
  }

  String encode() => jsonEncode(toJson());
}
