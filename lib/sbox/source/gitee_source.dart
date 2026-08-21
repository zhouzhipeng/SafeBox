import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../errors.dart';
import 'data_source.dart';
import 'remote_http.dart';
import 'repository_data_source.dart';

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
  String get publicWebHost => 'gitee.com';

  @override
  SourceCapabilities get capabilities => SourceCapabilities(
    canRead: true,
    canWrite: credentialStore != null && credentialId != null,
    canDelete: credentialStore != null && credentialId != null,
    canListObjects: true,
    supportsRangeRead: true,
    maxObjectBytes: 20 * 1024 * 1024,
    // Release attachments are independent assets. Keep Gitee conservative,
    // but allow a small amount of parallelism for shard transfers.
    maxParallelTransfers: 2,
  );

  @override
  RepositoryCredentialPlacement get credentialPlacement =>
      RepositoryCredentialPlacement.formBody;

  @override
  Uri latestReleaseUri() => Uri(
    scheme: 'https',
    host: 'gitee.com',
    pathSegments: <String>[
      'api',
      'v5',
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
    host: 'gitee.com',
    pathSegments: <String>[
      'api',
      'v5',
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
    host: 'gitee.com',
    pathSegments: <String>[
      'api',
      'v5',
      'repos',
      config.owner,
      config.repository,
      'releases',
      releaseId.toString(),
      'attach_files',
    ],
    queryParameters: <String, String>{
      'page': page.toString(),
      'per_page': perPage.toString(),
    },
  );

  @override
  Uri assetDownloadUri({required int releaseId, required int assetId}) => Uri(
    scheme: 'https',
    host: 'gitee.com',
    pathSegments: <String>[
      'api',
      'v5',
      'repos',
      config.owner,
      config.repository,
      'releases',
      releaseId.toString(),
      'attach_files',
      assetId.toString(),
      'download',
    ],
  );

  @override
  Uri assetDeleteUri({required int releaseId, required int assetId}) => Uri(
    scheme: 'https',
    host: 'gitee.com',
    pathSegments: <String>[
      'api',
      'v5',
      'repos',
      config.owner,
      config.repository,
      'releases',
      releaseId.toString(),
      'attach_files',
      assetId.toString(),
    ],
  );

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
    ],
  );

  @override
  Map<String, String> publicHeaders({required bool raw}) => <String, String>{
    'Accept': raw ? 'application/octet-stream' : 'application/json',
    'User-Agent': 'SafeBox',
  };

  @override
  Future<http.BaseRequest> createLatestReleaseRequest(String token) async {
    final targetCommitish = await _defaultBranch();
    final request = http.Request('POST', createReleaseUri())
      ..headers.addAll(publicHeaders(raw: false))
      ..headers['Content-Type'] = 'application/x-www-form-urlencoded';
    request.bodyFields = <String, String>{
      'access_token': token,
      'tag_name': safeBoxReleaseTag,
      'name': safeBoxReleaseTag,
      'body': 'SafeBox encrypted object store',
      'prerelease': 'false',
      'target_commitish': targetCommitish,
    };
    return request;
  }

  @override
  Future<http.BaseRequest> uploadAssetRequest({
    required RepositoryReleaseMetadata release,
    required String token,
    required String assetName,
    required Uint8List bytes,
  }) async {
    final request =
        http.MultipartRequest(
            'POST',
            assetListUri(
              releaseId: release.id,
              page: 1,
              perPage: providerPageSize,
            ).replace(queryParameters: const <String, String>{}),
          )
          ..headers.addAll(publicHeaders(raw: false))
          ..fields['access_token'] = token;
    request.files.add(
      http.MultipartFile.fromBytes('file', bytes, filename: assetName),
    );
    return request;
  }

  @override
  http.BaseRequest deleteAssetRequest({
    required RepositoryObjectMetadata metadata,
    required String token,
  }) {
    final request = http.Request(
      'DELETE',
      assetDeleteUri(releaseId: metadata.releaseId, assetId: metadata.assetId),
    )..headers.addAll(publicHeaders(raw: false));
    request.bodyFields = <String, String>{'access_token': token};
    return request;
  }

  Future<String> _defaultBranch() async {
    final response = await httpTransport.get(
      repositoryProbeUri(),
      headers: await authenticatedRequestHeaders(raw: false),
    );
    if (response.statusCode != 200) {
      await httpTransport.throwForStatus(response, RemoteFailureContext.read);
    }
    final value = await httpTransport.readJsonObject(response);
    final branch = value['default_branch'];
    if (branch is! String || branch.isEmpty) {
      throw const SboxException(
        SboxErrorCode.sourceNetwork,
        'Gitee repository response has no default branch',
      );
    }
    return branch;
  }
}
