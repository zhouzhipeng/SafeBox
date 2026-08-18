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

  /// The repository-contents endpoint returns the directory listing directly;
  /// it does not provide the page/per_page cursor contract assumed by the
  /// generic repository source. Advertising synthetic pages here can make a
  /// completed upload loop over the same directory forever.
  @override
  bool get supportsListPagination => false;

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
  );

  @override
  Uri writeUri(SourcePath path) => _contentsUri(path);

  // Gitee's web download_url can reject large objects even with an API
  // token. The API raw endpoint accepts the token and uses the repository's
  // default branch when ref is omitted.
  @override
  Uri rawUri(SourcePath path, RepositoryObjectMetadata _) => _rawUri(path);

  @override
  Uri? rawUriWithoutMetadata(SourcePath path) => _rawUri(path);

  Uri _rawUri(SourcePath path) => Uri(
    scheme: 'https',
    host: 'gitee.com',
    pathSegments: <String>[
      'api',
      'v5',
      'repos',
      config.owner,
      config.repository,
      'raw',
      ...config.resolveBasename(path).split('/'),
    ],
  );

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
