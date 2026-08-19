import 'package:http/http.dart' as http;

import '../../platform/secure_credential_store.dart';
import 'cloud_backup_config.dart';
import 'credential.dart';
import 'data_source.dart';
import 'gitee_source.dart';
import 'github_source.dart';
import '../logging.dart';

/// Creates the two HTTP data sources described by one SafeBox configuration.
/// The caller owns and closes [client] after all requests finish.
final class CloudRepositoryPair {
  CloudRepositoryPair._({
    required this.github,
    required this.gitee,
    required this.githubEnabled,
    required this.giteeEnabled,
  });

  factory CloudRepositoryPair.fromConfiguration({
    required CloudBackupConfiguration configuration,
    required http.Client client,
    CredentialStore? credentialStore,
    SboxLogger? logger,
  }) {
    final credentials = credentialStore ?? PlatformCredentialStore();
    return CloudRepositoryPair._(
      github: GitHubDataSource(
        config: configuration.github.repositoryConfig,
        client: client,
        credentialStore: credentials,
        credentialId: configuration.github.credentialId,
        logger: logger,
      ),
      githubEnabled: configuration.github.enabled,
      gitee: GiteeDataSource(
        config: configuration.gitee.repositoryConfig,
        client: client,
        credentialStore: credentials,
        credentialId: configuration.gitee.credentialId,
        logger: logger,
      ),
      giteeEnabled: configuration.gitee.enabled,
    );
  }

  final EnumerableDataSource github;
  final EnumerableDataSource gitee;
  final bool githubEnabled;
  final bool giteeEnabled;

  /// Returns only repositories that are enabled in the current configuration.
  ///
  /// The concrete [github] and [gitee] fields remain available for callers
  /// that need a stable provider reference, but normal sync and listing flows
  /// should use this collection so a disabled repository is never contacted.
  List<({String name, EnumerableDataSource source})> get enabledSources => [
    if (githubEnabled) (name: 'GitHub', source: github),
    if (giteeEnabled) (name: 'Gitee', source: gitee),
  ];
}
