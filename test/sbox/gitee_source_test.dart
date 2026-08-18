import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/source/credential.dart';
import 'package:safebox/sbox/source/data_source.dart';
import 'package:safebox/sbox/source/gitee_source.dart';
import 'package:safebox/sbox/source/remote_config.dart';
import 'package:safebox/sbox/source/source_path.dart';
import 'package:test/test.dart';

void main() {
  test('Gitee read requests use the provider token scheme', () async {
    final client = _RecordingClient();
    final source = GiteeDataSource(
      config: RepositorySourceConfig(owner: 'zzp', repository: 'sbox-files'),
      client: client,
      credentialStore: _CredentialStore(),
      credentialId: SourceCredentialId('gitee-test-token'),
    );

    await source.listObjects();

    expect(client.readRequest?.headers['authorization'], 'token test-token');
    expect(client.readRequest?.url.queryParameters, <String, String>{
      'page': '1',
      'per_page': '100',
    });
  });

  test('Gitee creates files with form-encoded API parameters', () async {
    final client = _RecordingClient();
    final source = GiteeDataSource(
      config: RepositorySourceConfig(owner: 'zzp', repository: 'sbox-files'),
      client: client,
      credentialStore: _CredentialStore(),
      credentialId: SourceCredentialId('gitee-test-token'),
    );
    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);

    await source.putNew(
      SourcePath('0123456789abcdef0123456789abcdef-0-of-1.sbox'),
      Stream<List<int>>.value(bytes),
      length: bytes.length,
      sha256: sha256Bytes(bytes),
    );

    final request = client.createRequest;
    expect(request, isNotNull);
    expect(request!.method, 'POST');
    expect(
      request.headers['content-type'],
      'application/x-www-form-urlencoded',
    );
    expect(request.url.queryParameters, isEmpty);
    expect(request.bodyFields, <String, String>{
      'access_token': 'test-token',
      'content': base64Encode(bytes),
      'message': 'sbox: add immutable object',
    });
  });

  test(
    'Gitee range reads tolerate a raw endpoint returning HTTP 200',
    () async {
      final client = _FullObjectRawClient();
      final source = GiteeDataSource(
        config: RepositorySourceConfig(owner: 'zzp', repository: 'sbox-files'),
        client: client,
      );

      final read = await source.getRange(
        SourcePath('0123456789abcdef0123456789abcdef-0-of-1.sbox'),
        start: 1,
        endExclusive: 3,
        objectInfo: SourceObjectInfo(
          path: SourcePath('0123456789abcdef0123456789abcdef-0-of-1.sbox'),
          length: 0,
          revision: RevisionToken(ascii.encode('revision')),
          downloadUri: Uri.parse(
            'https://gitee.com/zzp/sbox-files/raw/master/object.sbox',
          ),
        ),
      );

      expect(await read.body.expand((chunk) => chunk).toList(), <int>[2, 3]);
      expect(client.metadataRequests, 0);
      expect(
        client.rawRequest?.url.path,
        '/api/v5/repos/zzp/sbox-files/raw/0123456789abcdef0123456789abcdef-0-of-1.sbox',
      );
      expect(client.rawRequest?.url.queryParameters, isEmpty);
    },
  );

  test(
    'Gitee full reads bypass the large contents metadata response',
    () async {
      final client = _FullObjectRawClient();
      final source = GiteeDataSource(
        config: RepositorySourceConfig(owner: 'zzp', repository: 'sbox-files'),
        client: client,
      );

      final read = await source.get(
        SourcePath('0123456789abcdef0123456789abcdef-0-of-1.sbox'),
      );

      expect(await read.body.expand((chunk) => chunk).toList(), <int>[
        1,
        2,
        3,
        4,
      ]);
      expect(client.metadataRequests, 0);
      expect(
        client.rawRequest?.url.path,
        '/api/v5/repos/zzp/sbox-files/raw/0123456789abcdef0123456789abcdef-0-of-1.sbox',
      );
    },
  );

  test(
    'Gitee full reads tolerate raw responses without size or ETag headers',
    () async {
      final client = _FullObjectRawClient(omitRawHeaders: true);
      final source = GiteeDataSource(
        config: RepositorySourceConfig(owner: 'zzp', repository: 'sbox-files'),
        client: client,
      );

      final read = await source.get(
        SourcePath('0123456789abcdef0123456789abcdef-0-of-1.sbox'),
      );

      expect(await read.body.expand((chunk) => chunk).toList(), <int>[
        1,
        2,
        3,
        4,
      ]);
      expect(read.length, 4);
      expect(ascii.decode(read.revision.bytes), startsWith('raw-sha256:'));
    },
  );
}

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

final class _RecordingClient extends http.BaseClient {
  http.Request? createRequest;
  http.BaseRequest? readRequest;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET') {
      readRequest = request;
      if (request.url.path.contains('/raw/')) {
        return http.StreamedResponse(
          const Stream<List<int>>.empty(),
          404,
          request: request,
        );
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode('[]')),
        200,
        request: request,
      );
    }
    createRequest = request as http.Request;
    return http.StreamedResponse(
      Stream<List<int>>.value(
        utf8.encode('{"content":{"sha":"provider-revision"}}'),
      ),
      201,
      headers: const <String, String>{'content-type': 'application/json'},
      request: request,
    );
  }
}

final class _FullObjectRawClient extends http.BaseClient {
  _FullObjectRawClient({this.omitRawHeaders = false});

  final bool omitRawHeaders;
  http.BaseRequest? rawRequest;
  var metadataRequests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.host == 'gitee.com' &&
        request.url.path.contains('/api/v5/repos/') &&
        request.url.path.contains('/contents/')) {
      metadataRequests++;
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode(
            '{"type":"file","size":4,"sha":"revision",'
            '"download_url":"https://gitee.com/zzp/sbox-files/raw/main/object.sbox"}',
          ),
        ),
        200,
        request: request,
      );
    }
    if (request.url.host == 'gitee.com' &&
        request.url.path.contains('/api/v5/repos/') &&
        request.url.path.contains('/raw/')) {
      rawRequest = request;
      if (omitRawHeaders) {
        return http.StreamedResponse(
          Stream<List<int>>.value(Uint8List.fromList(<int>[1, 2, 3, 4])),
          200,
          request: request,
        );
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(Uint8List.fromList(<int>[1, 2, 3, 4])),
        200,
        contentLength: 4,
        headers: const <String, String>{'etag': '"revision"'},
        request: request,
      );
    }
    if (request.url.host == 'gitee.com') {
      return http.StreamedResponse(
        const Stream<List<int>>.empty(),
        302,
        headers: const <String, String>{
          'location': 'https://raw.giteeusercontent.com/zzp/sbox-files/raw/main/object.sbox',
        },
        request: request,
      );
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(Uint8List.fromList(<int>[1, 2, 3, 4])),
      200,
      request: request,
    );
  }
}
