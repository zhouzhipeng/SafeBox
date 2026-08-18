import 'package:http/http.dart' as http;

import '../../app/app_logger.dart';
import '../../platform/secure_credential_store.dart';
import 'cloud_backup_config.dart';
import 'credential.dart';
import 'data_source.dart';
import 'gitee_source.dart';
import 'github_source.dart';

/// Creates the two HTTP data sources described by one SafeBox configuration.
/// The caller owns and closes [client] after all requests finish.
final class CloudRepositoryPair {
  CloudRepositoryPair._({required this.github, required this.gitee});

  factory CloudRepositoryPair.fromConfiguration({
    required CloudBackupConfiguration configuration,
    required http.Client client,
    CredentialStore? credentialStore,
    AppLogger? logger,
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
      gitee: GiteeDataSource(
        config: configuration.gitee.repositoryConfig,
        client: client,
        credentialStore: credentials,
        credentialId: configuration.gitee.credentialId,
        logger: logger,
      ),
    );
  }

  final EnumerableDataSource github;
  final EnumerableDataSource gitee;
}
