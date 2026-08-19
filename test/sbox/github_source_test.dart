import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/source/credential.dart';
import 'package:safebox/sbox/source/data_source.dart';
import 'package:safebox/sbox/source/github_source.dart';
import 'package:safebox/sbox/source/remote_config.dart';
import 'package:safebox/sbox/source/source_path.dart';
import 'package:test/test.dart';

void main() {
  test(
    'GitHub directory listings do not request a synthetic next page',
    () async {
      final client = _DirectoryClient(
        List<Object?>.generate(
          100,
          (index) => <String, Object?>{
            'type': 'file',
            'name': '${index.toRadixString(16).padLeft(32, '0')}.sbox',
            'sha': 'revision-$index',
            'size': 16992,
          },
        ),
      );
      final source = GitHubDataSource(
        config: RepositorySourceConfig(
          owner: 'zhouzhipeng',
          repository: 'sbox-files',
        ),
        client: client,
        credentialStore: _CredentialStore(),
        credentialId: SourceCredentialId('github-test-token'),
      );

      final page = await source.listObjects(pageSize: 1000);

      expect(page.objects, hasLength(100));
      expect(page.nextCursor, isNull);
      expect(client.requests, hasLength(1));
      expect(client.requests.single.url.queryParameters, isEmpty);
      expect(
        client.requests.single.headers['authorization'],
        'Bearer test-token',
      );
    },
  );

  test(
    'GitHub treats a committed 422 response as an idempotent success',
    () async {
      final client = _CommitThen422Client();
      final source = GitHubDataSource(
        config: RepositorySourceConfig(owner: 'owner', repository: 'repo'),
        client: client,
        credentialStore: _CredentialStore(),
        credentialId: SourceCredentialId('github-test-token'),
      );
      final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);

      final revision = await source.putNew(
        SourcePath('0123456789abcdef0123456789abcdef.sbox'),
        Stream<List<int>>.value(bytes),
        length: bytes.length,
        sha256: sha256Bytes(bytes),
      );

      expect(
        revision.matches(RevisionToken(asciiBytes('provider-revision'))),
        isTrue,
      );
      expect(client.putRequests, 1);
      expect(client.metadataReads, greaterThanOrEqualTo(2));
    },
  );

  test(
    'GitHub deletes files with the bearer credential and revision',
    () async {
      final client = _DeleteClient();
      final source = GitHubDataSource(
        config: RepositorySourceConfig(owner: 'owner', repository: 'repo'),
        client: client,
        credentialStore: _CredentialStore(),
        credentialId: SourceCredentialId('github-test-token'),
      );

      await source.deleteIfMatch(
        SourcePath('0123456789abcdef0123456789abcdef.sbox'),
        RevisionToken(ascii.encode('provider-revision')),
      );

      final request = client.request;
      expect(request, isNotNull);
      expect(request!.method, 'DELETE');
      expect(request.headers['authorization'], 'Bearer test-token');
      expect(jsonDecode(request.body), <String, String>{
        'message': 'sbox: delete immutable object',
        'sha': 'provider-revision',
      });
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

final class _DirectoryClient extends http.BaseClient {
  _DirectoryClient(this.entries);

  final List<Object?> entries;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(entries))),
      200,
      request: request,
    );
  }
}

final class _CommitThen422Client extends http.BaseClient {
  static final Uri _downloadUri = Uri.parse(
    'https://raw.githubusercontent.com/owner/repo/main/object.sbox',
  );
  static final Uint8List _bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);

  var committed = false;
  var putRequests = 0;
  var metadataReads = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'PUT') {
      putRequests++;
      committed = true;
      return http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode('{"message":"Validation Failed"}')),
        422,
        request: request,
      );
    }
    if (request.url == _downloadUri) {
      return http.StreamedResponse(
        Stream<List<int>>.value(_bytes),
        200,
        contentLength: _bytes.length,
        headers: const <String, String>{'etag': '"provider-revision"'},
        request: request,
      );
    }

    metadataReads++;
    if (!committed) {
      return http.StreamedResponse(
        Stream<List<int>>.value(const <int>[]),
        404,
        request: request,
      );
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'type': 'file',
            'size': _bytes.length,
            'sha': 'provider-revision',
            'download_url': _downloadUri.toString(),
          }),
        ),
      ),
      200,
      request: request,
    );
  }
}

final class _DeleteClient extends http.BaseClient {
  http.Request? request;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    this.request = request as http.Request;
    return http.StreamedResponse(
      const Stream<List<int>>.empty(),
      204,
      request: request,
    );
  }
}
