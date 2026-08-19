import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/errors.dart';
import 'package:safebox/sbox/source/credential.dart';
import 'package:safebox/sbox/source/data_source.dart';
import 'package:safebox/sbox/source/gitee_source.dart';
import 'package:safebox/sbox/source/remote_config.dart';
import 'package:safebox/sbox/source/source_path.dart';
import 'package:test/test.dart';

void main() {
  test('Gitee release assets expose bounded parallel transfers', () {
    expect(_source(_GiteeReleaseClient()).capabilities.maxParallelTransfers, 2);
  });

  test(
    'Gitee returns an empty read-only store without creating a release',
    () async {
      final client = _GiteeReleaseClient();
      final source = GiteeDataSource(
        config: RepositorySourceConfig(owner: 'zzp', repository: 'repo'),
        client: client,
      );

      final page = await source.listObjects();

      expect(page.objects, isEmpty);
      expect(client.releaseCreateRequests, 0);
    },
  );

  test(
    'Gitee creates latest release with the repository default branch',
    () async {
      final client = _GiteeReleaseClient();
      final source = _source(client);

      final page = await source.listObjects();

      expect(page.objects, isEmpty);
      expect(client.releaseCreateRequests, 1);
      expect(client.releaseId, 11);
      final create = client.requests.singleWhere(
        (request) =>
            request.method == 'POST' && request.url.path.endsWith('/releases'),
      ) as http.Request;
      expect(create.bodyFields['access_token'], 'test-token');
      expect(create.bodyFields['tag_name'], 'latest');
      expect(create.bodyFields['target_commitish'], 'master');
    },
  );

  test(
    'Gitee uploads multipart binary assets and supports read/range/delete',
    () async {
      final client = _GiteeReleaseClient();
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
        (request) => request.url.path.endsWith('/attach_files'),
      ) as http.MultipartRequest;
      expect(upload.fields['access_token'], 'test-token');
      expect(upload.fields.containsKey('content'), isFalse);
      expect(upload.files.single.filename, path.value);
      expect(client.uploadedBytes, bytes);
      expect(ascii.decode(revision.bytes), 'release-asset:11:1');

      final read = await source.get(path);
      expect(await read.body.expand((chunk) => chunk).toList(), bytes);

      final range = await source.getRange(path, start: 2, endExclusive: 5);
      expect(await range.body.expand((chunk) => chunk).toList(), <int>[
        2,
        127,
        128,
      ]);

      await source.deleteIfMatch(path, revision);
      expect(client.assets, isEmpty);
      expect(client.deleteRequests, 1);
    },
  );

  test('Gitee rejects a stale revision before deleting', () async {
    final client = _GiteeReleaseClient()
      ..releaseExists = true
      ..assets.add(
        _AssetRecord(1, 'object.sbox', Uint8List.fromList(<int>[1])),
      );
    final source = _source(client);

    await expectLater(
      source.deleteIfMatch(
        SourcePath('object.sbox'),
        RevisionToken(ascii.encode('release-asset:11:999')),
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

  test('Gitee confirms a committed asset after an upload 422', () async {
    final client = _GiteeReleaseClient()
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

    expect(ascii.decode(revision.bytes), 'release-asset:11:1');
    expect(client.uploadRequests, 1);
  });
}

GiteeDataSource _source(_GiteeReleaseClient client) => GiteeDataSource(
  config: RepositorySourceConfig(owner: 'zzp', repository: 'repo'),
  client: client,
  credentialStore: _CredentialStore(),
  credentialId: SourceCredentialId('gitee-test-token'),
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

final class _GiteeReleaseClient extends http.BaseClient {
  final List<http.BaseRequest> requests = <http.BaseRequest>[];
  final List<_AssetRecord> assets = <_AssetRecord>[];
  var releaseExists = false;
  var releaseCreateRequests = 0;
  var uploadRequests = 0;
  var deleteRequests = 0;
  var return422AfterCommit = false;
  var nextAssetId = 1;
  Uint8List uploadedBytes = Uint8List(0);
  int get releaseId => 11;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'GET' && path.endsWith('/releases/tags/latest')) {
      return releaseExists
          ? _json(request, _releaseJson())
          : _json(request, null);
    }
    if (request.method == 'GET' && path == '/api/v5/repos/zzp/repo') {
      return _json(request, <String, Object?>{'default_branch': 'master'});
    }
    if (request.method == 'POST' && path.endsWith('/releases')) {
      releaseExists = true;
      releaseCreateRequests++;
      return _json(request, _releaseJson(), status: 201);
    }
    if (request.method == 'GET' && path.endsWith('/attach_files')) {
      final page = int.parse(request.url.queryParameters['page'] ?? '1');
      final perPage = int.parse(
        request.url.queryParameters['per_page'] ?? '100',
      );
      final start = (page - 1) * perPage;
      final values = start >= assets.length
          ? <Object?>[]
          : assets.skip(start).take(perPage).map(_assetJson).toList();
      return _json(request, values);
    }
    if (request.method == 'POST' && path.endsWith('/attach_files')) {
      uploadRequests++;
      final multipart = request as http.MultipartRequest;
      final file = multipart.files.single;
      final chunks = await file.finalize().toList();
      uploadedBytes = Uint8List.fromList(
        chunks.expand((chunk) => chunk).toList(),
      );
      final record = _AssetRecord(nextAssetId++, file.filename!, uploadedBytes);
      assets.removeWhere((asset) => asset.name == record.name);
      assets.add(record);
      if (return422AfterCommit) {
        return _json(request, <String, Object?>{
          'message': 'already exists',
        }, status: 422);
      }
      return _json(request, _assetJson(record), status: 201);
    }
    if (path.contains('/attach_files/') && path.endsWith('/download')) {
      final assetId = int.parse(
        path.split('/').elementAt(path.split('/').length - 2),
      );
      final matching = assets.where((asset) => asset.id == assetId);
      if (matching.isEmpty) return _response(request, 404, const <int>[]);
      final asset = matching.first;
      return http.StreamedResponse(
        Stream<List<int>>.value(asset.bytes),
        200,
        contentLength: asset.bytes.length,
        request: request,
      );
    }
    if (request.method == 'DELETE' && path.contains('/attach_files/')) {
      deleteRequests++;
      final assetId = int.parse(path.split('/').last);
      assets.removeWhere((asset) => asset.id == assetId);
      return _response(request, 204, const <int>[]);
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
  };

  http.StreamedResponse _json(
    http.BaseRequest request,
    Object? value, {
    int status = 200,
  }) => http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(jsonEncode(value))),
    status,
    headers: const <String, String>{'content-type': 'application/json'},
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
