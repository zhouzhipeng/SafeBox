import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/errors.dart';
import 'package:safebox/sbox/source/credential.dart';
import 'package:safebox/sbox/source/data_source.dart';
import 'package:safebox/sbox/source/github_source.dart';
import 'package:safebox/sbox/source/remote_config.dart';
import 'package:safebox/sbox/source/source_path.dart';
import 'package:test/test.dart';

void main() {
  test('GitHub exposes a public Release URL for an object', () {
    final source = GitHubDataSource(
      config: RepositorySourceConfig(
        owner: 'owner',
        repository: 'repo',
        pathPrefix: 'nested',
      ),
      client: _GitHubReleaseClient(),
    );

    expect(
      source.publicReleaseAssetUri(SourcePath('object.sbox')).toString(),
      'https://github.com/owner/repo/releases/download/latest/'
      'safebox-bmVzdGVk--object.sbox',
    );
  });

  test('GitHub creates the dedicated latest release lazily', () async {
    final client = _GitHubReleaseClient();
    final source = _source(client);

    final page = await source.listObjects();

    expect(page.objects, isEmpty);
    expect(client.releaseCreateRequests, 1);
    expect(client.releaseId, 7);
    expect(
      client.requests.any((request) => request.url.path.contains('/contents')),
      isFalse,
    );
    final create = client.requests.singleWhere(
      (request) =>
          request.method == 'POST' && request.url.path.endsWith('/releases'),
    ) as http.Request;
    final body = jsonDecode(create.body) as Map<String, Object?>;
    expect(body['tag_name'], 'latest');
    expect(body['name'], 'latest');
    expect(body['make_latest'], 'true');
  });

  test(
    'GitHub uploads raw binary release assets and supports read/range/delete',
    () async {
      final client = _GitHubReleaseClient();
      final source = _source(client);
      final path = SourcePath('0123456789abcdef0123456789abcdef.sbox');
      final bytes = Uint8List.fromList(<int>[0, 1, 2, 127, 128, 255]);

      final revision = await source.putNew(
        path,
        Stream<List<int>>.value(bytes),
        length: bytes.length,
        sha256: sha256Bytes(bytes),
      );

      expect(client.uploadRequests, 1);
      final upload = client.requests.singleWhere(
        (request) => request.url.host == 'uploads.github.com',
      ) as http.Request;
      expect(upload.headers['content-type'], 'application/octet-stream');
      expect(upload.bodyBytes, bytes);
      expect(upload.url.queryParameters['name'], path.value);
      expect(ascii.decode(revision.bytes), 'release-asset:7:1');

      final read = await source.get(path);
      expect(await read.body.expand((chunk) => chunk).toList(), bytes);

      final range = await source.getRange(path, start: 2, endExclusive: 5);
      expect(await range.body.expand((chunk) => chunk).toList(), <int>[
        2,
        127,
        128,
      ]);

      final sameRevision = await source.putNew(
        path,
        Stream<List<int>>.value(bytes),
        length: bytes.length,
        sha256: sha256Bytes(bytes),
      );
      expect(sameRevision.matches(revision), isTrue);
      expect(client.uploadRequests, 1);

      final changed = Uint8List.fromList(<int>[9, 8, 7]);
      await expectLater(
        source.putNew(
          path,
          Stream<List<int>>.value(changed),
          length: changed.length,
          sha256: sha256Bytes(changed),
        ),
        throwsA(
          isA<SboxException>().having(
            (error) => error.code,
            'code',
            SboxErrorCode.immutableConflict,
          ),
        ),
      );

      await source.deleteIfMatch(path, revision);
      expect(client.assets, isEmpty);
      expect(client.releaseExists, isTrue);
    },
  );

  test('GitHub keeps a stale revision from deleting an asset', () async {
    final client = _GitHubReleaseClient()
      ..releaseExists = true
      ..assets.add(
        _AssetRecord(1, 'object.sbox', Uint8List.fromList(<int>[1])),
      );
    final source = _source(client);

    await expectLater(
      source.deleteIfMatch(
        SourcePath('object.sbox'),
        RevisionToken(ascii.encode('release-asset:7:999')),
      ),
      throwsA(
        isA<SboxException>().having(
          (error) => error.code,
          'code',
          SboxErrorCode.shardConflict,
        ),
      ),
    );
    expect(client.deleteRequests, 0);
  });

  test('GitHub release assets use API pagination', () async {
    final client = _GitHubReleaseClient()..releaseExists = true;
    client.assets.addAll(<_AssetRecord>[
      _AssetRecord(1, 'a.sbox', Uint8List.fromList(<int>[1])),
      _AssetRecord(2, 'b.sbox', Uint8List.fromList(<int>[2])),
    ]);
    final source = _source(client);

    final first = await source.listObjects(pageSize: 1);
    final second = await source.listObjects(
      cursor: first.nextCursor,
      pageSize: 1,
    );

    expect(first.objects.single.path.value, 'a.sbox');
    expect(first.nextCursor, '2');
    expect(second.objects.single.path.value, 'b.sbox');
    expect(second.nextCursor, isNull);
    expect(
      client.requests.where((request) => request.url.path.endsWith('/assets')),
      hasLength(2),
    );
  });

  test('GitHub confirms an asset when upload returns duplicate 422', () async {
    final client = _GitHubReleaseClient()
      ..releaseExists = true
      ..return422AfterCommit = true;
    final source = _source(client);
    final path = SourcePath('ambiguous.sbox');
    final bytes = Uint8List.fromList(<int>[3, 4, 5]);

    final revision = await source.putNew(
      path,
      Stream<List<int>>.value(bytes),
      length: bytes.length,
      sha256: sha256Bytes(bytes),
    );

    expect(ascii.decode(revision.bytes), 'release-asset:7:1');
    expect(client.uploadRequests, 1);
  });
}

GitHubDataSource _source(_GitHubReleaseClient client) => GitHubDataSource(
  config: RepositorySourceConfig(owner: 'owner', repository: 'repo'),
  client: client,
  credentialStore: _CredentialStore(),
  credentialId: SourceCredentialId('github-test-token'),
);

final class _CredentialStore implements CredentialStore {
  @override
  Future<void> deleteAccessToken(SourceCredentialId id) async {}

  @override
  Future<SourceAccessToken?> getAccessToken(SourceCredentialId id) async =>
      SourceAccessToken.fromUtf8('test-token');

  @override
  Future<void> putAccessToken(
    SourceCredentialId id,
    SourceAccessToken token,
  ) async {}
}

final class _AssetRecord {
  _AssetRecord(this.id, this.name, this.bytes);

  final int id;
  final String name;
  final Uint8List bytes;
}

final class _GitHubReleaseClient extends http.BaseClient {
  final List<http.BaseRequest> requests = <http.BaseRequest>[];
  final List<_AssetRecord> assets = <_AssetRecord>[];
  var releaseExists = false;
  var releaseCreateRequests = 0;
  var uploadRequests = 0;
  var deleteRequests = 0;
  var return422AfterCommit = false;
  var nextAssetId = 1;
  int get releaseId => 7;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'GET' && path.endsWith('/releases/tags/latest')) {
      if (!releaseExists) return _response(request, 404, const <int>[]);
      return _json(request, _releaseJson());
    }
    if (request.method == 'POST' && path.endsWith('/releases')) {
      releaseExists = true;
      releaseCreateRequests++;
      return _json(request, _releaseJson(), status: 201);
    }
    if (request.method == 'GET' && path.endsWith('/assets')) {
      final page = int.parse(request.url.queryParameters['page'] ?? '1');
      final perPage = int.parse(
        request.url.queryParameters['per_page'] ?? '100',
      );
      final start = (page - 1) * perPage;
      final values = start >= assets.length
          ? <Object?>[]
          : assets.skip(start).take(perPage).map(_assetJson).toList();
      final headers = page == 1 && assets.length > perPage
          ? <String, String>{
              'content-type': 'application/json',
              'link': '<https://api.github.com/?page=2>; rel="next"',
            }
          : const <String, String>{
              'content-type': 'application/json',
              'link': '<https://api.github.com/?page=2>; rel="last"',
            };
      return _json(request, values, headers: headers);
    }
    if (request.method == 'POST' && request.url.host == 'uploads.github.com') {
      uploadRequests++;
      final upload = request as http.Request;
      final name = request.url.queryParameters['name']!;
      final record = _AssetRecord(
        nextAssetId++,
        name,
        Uint8List.fromList(upload.bodyBytes),
      );
      assets.removeWhere((asset) => asset.name == name);
      assets.add(record);
      if (return422AfterCommit) {
        return _json(request, <String, Object?>{
          'message': 'already exists',
        }, status: 422);
      }
      return _json(request, _assetJson(record), status: 201);
    }
    if (path.contains('/releases/assets/')) {
      final assetId = int.parse(pathSegmentsLast(path));
      final matching = assets.where((value) => value.id == assetId);
      final asset = matching.isEmpty ? null : matching.first;
      if (request.method == 'GET') {
        if (asset == null) return _response(request, 404, const <int>[]);
        return http.StreamedResponse(
          Stream<List<int>>.value(asset.bytes),
          200,
          contentLength: asset.bytes.length,
          request: request,
        );
      }
      if (request.method == 'DELETE') {
        deleteRequests++;
        assets.removeWhere((value) => value.id == assetId);
        return _response(request, 204, const <int>[]);
      }
    }
    return _response(request, 404, const <int>[]);
  }

  Map<String, Object?> _releaseJson() => <String, Object?>{
    'id': releaseId,
    'tag_name': 'latest',
    'name': 'latest',
  };

  Map<String, Object?> _assetJson(_AssetRecord asset) => <String, Object?>{
    'id': asset.id,
    'name': asset.name,
    'size': asset.bytes.length,
    'state': 'uploaded',
  };

  http.StreamedResponse _json(
    http.BaseRequest request,
    Object value, {
    int status = 200,
    Map<String, String>? headers,
  }) => http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(jsonEncode(value))),
    status,
    headers:
        headers ?? const <String, String>{'content-type': 'application/json'},
    request: request,
  );

  http.StreamedResponse _response(
    http.BaseRequest request,
    int status,
    List<int> bytes,
  ) => http.StreamedResponse(
    Stream<List<int>>.value(bytes),
    status,
    request: request,
  );
}

String pathSegmentsLast(String path) => path.split('/').last;
