import 'data_source.dart';
import 'repository_data_source.dart';
import 'source_path.dart';

final class GiteeDataSource extends RepositoryDataSource {
  GiteeDataSource({
    required super.config,
    required super.client,
    super.credentialStore,
    super.credentialId,
  });

  // Gitee documents 100 MiB raw reads but does not publish an equivalent
  // Contents-write body ceiling. v1 therefore advertises a conservative
  // 20 MiB decoded limit, which safely fits the default 16 MiB SBOX part.
  static final BigInt _maxObjectBytes = BigInt.from(20 * 1024 * 1024);
  static final BigInt _maxRequestBytes = BigInt.from(28 * 1024 * 1024);

  @override
  SourceCapabilities get capabilities => SourceCapabilities(
    canRead: true,
    canWrite: credentialStore != null && credentialId != null,
    canDelete: false,
    conditionalWrite: true,
    history: true,
    maxObjectBytes: _maxObjectBytes,
    maxRequestBodyBytes: _maxRequestBytes,
    uploadEncoding: UploadEncoding.base64Json,
    maxParallelObjectTransfers: 2,
    supportsStreamingDownload: true,
    supportsResumableObjectDownload: false,
  );

  @override
  String get createMethod => 'POST';

  @override
  String get apiAcceptHeader => 'application/json';

  @override
  RepositoryCredentialPlacement get credentialPlacement =>
      RepositoryCredentialPlacement.jsonBody;

  @override
  Uri metadataUri(SourcePath path) => _contentsUri(path, includeRef: true);

  @override
  Uri writeUri(SourcePath path) => _contentsUri(path, includeRef: false);

  @override
  Uri rawUri(SourcePath path, RepositoryObjectMetadata metadata) {
    final resolved = config.resolve(path);
    return Uri(
      scheme: 'https',
      host: 'gitee.com',
      pathSegments: <String>[
        config.owner,
        config.repository,
        'raw',
        config.branch,
        ...resolved.segments,
      ],
    );
  }

  @override
  Uri repositoryProbeUri() => Uri(
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
    queryParameters: <String, String>{'ref': config.branch},
  );

  @override
  Map<String, String> publicHeaders({required bool raw}) => <String, String>{
    'Accept': raw ? 'application/octet-stream' : 'application/json',
    'User-Agent': 'SafeBox-v1',
  };

  Uri _contentsUri(SourcePath path, {required bool includeRef}) {
    final resolved = config.resolve(path);
    return Uri(
      scheme: 'https',
      host: 'gitee.com',
      pathSegments: <String>[
        'api',
        'v5',
        'repos',
        config.owner,
        config.repository,
        'contents',
        ...resolved.segments,
      ],
      queryParameters: includeRef
          ? <String, String>{'ref': config.branch}
          : null,
    );
  }
}
