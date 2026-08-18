import 'data_source.dart';
import 'repository_data_source.dart';
import 'source_path.dart';

final class GitHubDataSource extends RepositoryDataSource {
  GitHubDataSource({
    required super.config,
    required super.client,
    super.credentialStore,
    super.credentialId,
    super.logger,
    super.sourceName = 'GitHub',
  });

  @override
  SourceCapabilities get capabilities => SourceCapabilities(
    canRead: true,
    canWrite: credentialStore != null && credentialId != null,
    canDelete: credentialStore != null && credentialId != null,
    canListObjects: true,
    supportsRangeRead: true,
    maxObjectBytes: 100 * 1024 * 1024,
    maxParallelTransfers: 4,
  );

  @override
  String get createMethod => 'PUT';

  @override
  String get apiAcceptHeader => 'application/vnd.github+json';

  @override
  Uri metadataUri(SourcePath path) => _contentsUri(path);

  @override
  Uri listUri({String? cursor, int pageSize = 1000}) => Uri(
    scheme: 'https',
    host: 'api.github.com',
    pathSegments: <String>[
      'repos',
      config.owner,
      config.repository,
      'contents',
      if (config.pathPrefix.isNotEmpty) ...config.pathPrefix.split('/'),
    ],
    queryParameters: <String, String>{
      'page': cursor ?? '1',
      'per_page': (pageSize < providerPageSize ? pageSize : providerPageSize)
          .toString(),
    },
  );

  @override
  Uri writeUri(SourcePath path) => _contentsUri(path);

  @override
  Uri rawUri(SourcePath path, RepositoryObjectMetadata metadata) =>
      resolvedDownloadUri(metadata);

  @override
  Uri repositoryProbeUri() => listUri();

  @override
  Map<String, String> publicHeaders({required bool raw}) => <String, String>{
    'Accept': raw ? 'application/octet-stream' : apiAcceptHeader,
    'User-Agent': 'SafeBox',
    'X-GitHub-Api-Version': '2022-11-28',
  };

  Uri _contentsUri(SourcePath path) => Uri(
    scheme: 'https',
    host: 'api.github.com',
    pathSegments: <String>[
      'repos',
      config.owner,
      config.repository,
      'contents',
      ...config.resolveBasename(path).split('/'),
    ],
  );
}
