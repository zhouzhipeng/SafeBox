import 'data_source.dart';
import 'repository_data_source.dart';
import 'source_path.dart';

final class GiteeDataSource extends RepositoryDataSource {
  GiteeDataSource({
    required super.config,
    required super.client,
    super.credentialStore,
    super.credentialId,
    super.logger,
    super.sourceName = 'Gitee',
  });

  @override
  SourceCapabilities get capabilities => SourceCapabilities(
    canRead: true,
    canWrite: credentialStore != null && credentialId != null,
    canDelete: false,
    canListObjects: true,
    supportsRangeRead: true,
    maxObjectBytes: 20 * 1024 * 1024,
    maxParallelTransfers: 2,
  );

  @override
  String get createMethod => 'POST';

  @override
  String get apiAcceptHeader => 'application/json';

  @override
  RepositoryCredentialPlacement get credentialPlacement =>
      RepositoryCredentialPlacement.formBody;

  @override
  bool get emptyMetadataListMeansNotFound => true;

  @override
  Uri metadataUri(SourcePath path) => _contentsUri(path);

  @override
  Uri listUri({String? cursor, int pageSize = 1000}) => Uri(
    scheme: 'https',
    host: 'gitee.com',
    pathSegments: <String>[
      'api',
      'v5',
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
  };

  Uri _contentsUri(SourcePath path) => Uri(
    scheme: 'https',
    host: 'gitee.com',
    pathSegments: <String>[
      'api',
      'v5',
      'repos',
      config.owner,
      config.repository,
      'contents',
      ...config.resolveBasename(path).split('/'),
    ],
  );
}
