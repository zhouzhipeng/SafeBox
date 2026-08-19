import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'data_source.dart';
import 'repository_data_source.dart';

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
  Uri latestReleaseUri() => Uri(
    scheme: 'https',
    host: 'api.github.com',
    pathSegments: <String>[
      'repos',
      config.owner,
      config.repository,
      'releases',
      'tags',
      safeBoxReleaseTag,
    ],
  );

  @override
  Uri createReleaseUri() => Uri(
    scheme: 'https',
    host: 'api.github.com',
    pathSegments: <String>[
      'repos',
      config.owner,
      config.repository,
      'releases',
    ],
  );

  @override
  Uri assetListUri({
    required int releaseId,
    required int page,
    required int perPage,
  }) => Uri(
    scheme: 'https',
    host: 'api.github.com',
    pathSegments: <String>[
      'repos',
      config.owner,
      config.repository,
      'releases',
      releaseId.toString(),
      'assets',
    ],
    queryParameters: <String, String>{
      'page': page.toString(),
      'per_page': perPage.toString(),
    },
  );

  @override
  Uri assetDownloadUri({required int releaseId, required int assetId}) => Uri(
    scheme: 'https',
    host: 'api.github.com',
    pathSegments: <String>[
      'repos',
      config.owner,
      config.repository,
      'releases',
      'assets',
      assetId.toString(),
    ],
  );

  @override
  Uri assetDeleteUri({required int releaseId, required int assetId}) =>
      assetDownloadUri(releaseId: releaseId, assetId: assetId);

  @override
  Uri repositoryProbeUri() => Uri(
    scheme: 'https',
    host: 'api.github.com',
    pathSegments: <String>['repos', config.owner, config.repository],
  );

  @override
  Map<String, String> publicHeaders({required bool raw}) => <String, String>{
    'Accept': raw ? 'application/octet-stream' : 'application/vnd.github+json',
    'User-Agent': 'SafeBox',
    'X-GitHub-Api-Version': '2022-11-28',
  };

  @override
  Future<http.BaseRequest> createLatestReleaseRequest(String token) async {
    final request = http.Request('POST', createReleaseUri())
      ..headers.addAll(publicHeaders(raw: false))
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Content-Type'] = 'application/json; charset=utf-8'
      ..body = jsonEncode(<String, Object?>{
        'tag_name': safeBoxReleaseTag,
        'name': safeBoxReleaseTag,
        'body': 'SafeBox encrypted object store',
        'draft': false,
        'prerelease': false,
        'generate_release_notes': false,
        'make_latest': 'true',
      });
    return request;
  }

  @override
  Future<http.BaseRequest> uploadAssetRequest({
    required RepositoryReleaseMetadata release,
    required String token,
    required String assetName,
    required Uint8List bytes,
  }) async {
    final uri = Uri(
      scheme: 'https',
      host: 'uploads.github.com',
      pathSegments: <String>[
        'repos',
        config.owner,
        config.repository,
        'releases',
        release.id.toString(),
        'assets',
      ],
      queryParameters: <String, String>{'name': assetName},
    );
    final request = http.Request('POST', uri)
      // The upload body is raw binary, but GitHub still returns JSON asset
      // metadata and expects the normal GitHub JSON Accept header.
      ..headers.addAll(publicHeaders(raw: false))
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Content-Type'] = 'application/octet-stream'
      // Keep the request-owned buffer independent from putNew's secure
      // cleanup of its upload buffer.
      ..bodyBytes = Uint8List.fromList(bytes);
    return request;
  }

  @override
  http.BaseRequest deleteAssetRequest({
    required RepositoryObjectMetadata metadata,
    required String token,
  }) =>
      http.Request(
          'DELETE',
          assetDeleteUri(
            releaseId: metadata.releaseId,
            assetId: metadata.assetId,
          ),
        )
        ..headers.addAll(publicHeaders(raw: false))
        ..headers['Authorization'] = 'Bearer $token';
}
