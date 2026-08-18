import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/source/credential.dart';
import 'package:safebox/sbox/source/gitee_source.dart';
import 'package:safebox/sbox/source/remote_config.dart';
import 'package:safebox/sbox/source/source_path.dart';
import 'package:test/test.dart';

void main() {
  test('Gitee read requests use the provider token scheme', () async {
    final client = _RecordingClient();
    final source = GiteeDataSource(
      config: RepositorySourceConfig(
        owner: 'zzp',
        repository: 'sbox-files',
        branch: 'main',
      ),
      client: client,
      credentialStore: _CredentialStore(),
      credentialId: SourceCredentialId('gitee-test-token'),
    );

    await source.listObjects();

    expect(client.readRequest?.headers['authorization'], 'token test-token');
  });

  test('Gitee creates files with form-encoded API parameters', () async {
    final client = _RecordingClient();
    final source = GiteeDataSource(
      config: RepositorySourceConfig(
        owner: 'zzp',
        repository: 'sbox-files',
        branch: 'main',
      ),
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
      'branch': 'main',
      'content': base64Encode(bytes),
      'message': 'sbox: add immutable object',
    });
  });

  test(
    'Gitee range reads tolerate a raw endpoint returning HTTP 200',
    () async {
      final client = _FullObjectRawClient();
      final source = GiteeDataSource(
        config: RepositorySourceConfig(
          owner: 'zzp',
          repository: 'sbox-files',
          branch: 'main',
        ),
        client: client,
      );

      final read = await source.getRange(
        SourcePath('0123456789abcdef0123456789abcdef-0-of-1.sbox'),
        start: 1,
        endExclusive: 3,
      );

      expect(await read.body.expand((chunk) => chunk).toList(), <int>[2, 3]);
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
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.host == 'gitee.com' &&
        request.url.path.contains('/api/v5/repos/')) {
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode('{"type":"file","size":4,"sha":"revision"}'),
        ),
        200,
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
