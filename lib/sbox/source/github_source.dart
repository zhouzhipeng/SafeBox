import 'data_source.dart';
import 'repository_data_source.dart';
import 'source_path.dart';

final class GitHubDataSource extends RepositoryDataSource {
  GitHubDataSource({
    required super.config,
    required super.client,
    super.credentialStore,
    super.credentialId,
  });

  static final BigInt _maxObjectBytes = BigInt.from(100 * 1024 * 1024);
  static final BigInt _maxRequestBytes = BigInt.from(140 * 1024 * 1024);

  @override
  SourceCapabilities get capabilities => SourceCapabilities(
    canRead: true,
    canWrite: credentialStore != null && credentialId != null,
    canDelete: credentialStore != null && credentialId != null,
    conditionalWrite: true,
    history: true,
    maxObjectBytes: _maxObjectBytes,
    maxRequestBodyBytes: _maxRequestBytes,
    uploadEncoding: UploadEncoding.base64Json,
    maxParallelObjectTransfers: 4,
    supportsStreamingDownload: true,
    supportsResumableObjectDownload: false,
  );

  @override
  String get createMethod => 'PUT';

  @override
  String get apiAcceptHeader => 'application/vnd.github+json';

  @override
  Uri metadataUri(SourcePath path) => _contentsUri(path, includeRef: true);

  @override
  Uri writeUri(SourcePath path) => _contentsUri(path, includeRef: false);

  @override
  Uri rawUri(SourcePath path, RepositoryObjectMetadata metadata) => Uri(
    scheme: 'https',
    host: 'api.github.com',
    pathSegments: <String>[
      'repos',
      config.owner,
      config.repository,
      'git',
      'blobs',
      metadata.blobSha,
    ],
  );

  @override
  Map<String, String> publicHeaders({required bool raw}) => <String, String>{
    'Accept': raw
        ? 'application/vnd.github.raw+json'
        : 'application/vnd.github.object+json',
    'X-GitHub-Api-Version': '2026-03-10',
    'User-Agent': 'SafeBox-v1',
  };

  Uri _contentsUri(SourcePath path, {required bool includeRef}) {
    final resolved = config.resolve(path);
    return Uri(
      scheme: 'https',
      host: 'api.github.com',
      pathSegments: <String>[
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
