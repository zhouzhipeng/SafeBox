import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/errors.dart';
import 'package:safebox/sbox/source/credential.dart';
import 'package:safebox/sbox/source/data_source.dart';
import 'package:safebox/sbox/source/gitee_source.dart';
import 'package:safebox/sbox/source/github_source.dart';
import 'package:safebox/sbox/source/https_source.dart';
import 'package:safebox/sbox/source/remote_config.dart';
import 'package:safebox/sbox/source/remote_http.dart';
import 'package:safebox/sbox/source/source_path.dart';
import 'package:test/test.dart';

void main() {
  group('remote repository adapters', () {
    final payload = Uint8List.fromList(
      List<int>.generate(257, (index) => index & 0xff),
    );
    final blobSha = _gitBlobSha(payload);

    test(
      'GitHub anonymously resolves metadata then streams pinned blob',
      () async {
        var calls = 0;
        final client = MockClient.streaming((request, body) async {
          calls++;
          expect(request.headers.containsKey('authorization'), isFalse);
          expect(
            request.url.queryParameters['ref'],
            calls == 1 ? 'main' : null,
          );
          if (calls == 1) {
            expect(
              request.url.path,
              '/repos/alice/vault/contents/sbox/catalog.sbox',
            );
            expect(
              request.headers['accept'],
              'application/vnd.github.object+json',
            );
            return _jsonResponse(<String, Object?>{
              'type': 'file',
              'sha': blobSha,
              'size': payload.length,
            });
          }
          expect(request.url.path, '/repos/alice/vault/git/blobs/$blobSha');
          expect(request.headers['accept'], 'application/vnd.github.raw+json');
          return http.StreamedResponse(
            Stream<List<int>>.fromIterable(<List<int>>[
              payload.sublist(0, 5),
              payload.sublist(5),
            ]),
            200,
            contentLength: payload.length,
          );
        });
        final source = GitHubDataSource(
          config: RepositorySourceConfig(
            owner: 'alice',
            repository: 'vault',
            branch: 'main',
            pathPrefix: 'sbox',
          ),
          client: client,
        );

        final read = await source.get(SourcePath('catalog.sbox'));
        expect(await _collect(read.body), payload);
        expect(ascii.decode(read.revision.bytes), blobSha);
        expect(calls, 2);
      },
    );

    test('GitHub create streams Base64 JSON and disposes the token', () async {
      final store = _CredentialStore('github-token');
      var calls = 0;
      final client = MockClient.streaming((request, body) async {
        calls++;
        if (calls == 1) {
          expect(request.method, 'GET');
          return http.StreamedResponse(const Stream<List<int>>.empty(), 404);
        }
        expect(request.method, 'PUT');
        expect(request.url.query, isEmpty);
        expect(request.url.toString(), isNot(contains('github-token')));
        expect(request.headers['authorization'], 'Bearer github-token');
        expect(request.headers['x-github-api-version'], '2026-03-10');
        final encoded = await body.toBytes();
        expect(encoded.length, request.contentLength);
        final value = jsonDecode(utf8.decode(encoded)) as Map<String, dynamic>;
        expect(value['message'], 'sbox: add encrypted object');
        expect(value['branch'], 'main');
        expect(base64Decode(value['content'] as String), payload);
        return _jsonResponse(<String, Object?>{
          'content': <String, Object?>{'sha': blobSha},
        }, status: 201);
      });
      final source = GitHubDataSource(
        config: RepositorySourceConfig(
          owner: 'alice',
          repository: 'vault',
          branch: 'main',
        ),
        client: client,
        credentialStore: store,
        credentialId: SourceCredentialId('github-main'),
      );

      final revision = await source.putNew(
        SourcePath('objects/00/object.sbox'),
        Stream<List<int>>.fromIterable(<List<int>>[
          payload.sublist(0, 1),
          payload.sublist(1, 3),
          payload.sublist(3),
        ]),
        length: payload.length,
        sha256: sha256Bytes(payload),
      );
      expect(ascii.decode(revision.bytes), blobSha);
      expect(store.lastIssued?.isDisposed, isTrue);
    });

    test(
      'GitHub Catalog update carries the opaque expected blob SHA',
      () async {
        final store = _CredentialStore('catalog-token');
        final client = MockClient.streaming((request, body) async {
          expect(request.method, 'PUT');
          final value = jsonDecode(
            utf8.decode(await body.toBytes()),
          ) as Map<String, dynamic>;
          expect(value['message'], 'sbox: update encrypted catalog');
          expect(value['sha'], '0123456789abcdef0123456789abcdef01234567');
          return _jsonResponse(<String, Object?>{
            'content': <String, Object?>{'sha': blobSha},
          });
        });
        final source = GitHubDataSource(
          config: RepositorySourceConfig(
            owner: 'alice',
            repository: 'vault',
            branch: 'main',
          ),
          client: client,
          credentialStore: store,
          credentialId: SourceCredentialId('github-main'),
        );
        await source.compareAndSwap(
          SourcePath('catalog.sbox'),
          RevisionToken(
            ascii.encode('0123456789abcdef0123456789abcdef01234567'),
          ),
          Stream<List<int>>.value(payload),
          length: payload.length,
        );
      },
    );

    test(
      'Gitee uses anonymous raw reads and POST for immutable create',
      () async {
        final store = _CredentialStore('gitee-token');
        var calls = 0;
        final client = MockClient.streaming((request, body) async {
          calls++;
          if (calls == 1) {
            expect(request.headers.containsKey('authorization'), isFalse);
            expect(
              request.url.path,
              '/api/v5/repos/alice/vault/contents/catalog.sbox',
            );
            return _jsonResponse(<String, Object?>{
              'type': 'file',
              'sha': blobSha,
              'size': payload.length,
            });
          }
          if (calls == 2) {
            expect(request.method, 'GET');
            expect(request.headers.containsKey('authorization'), isFalse);
            expect(request.url.path, '/alice/vault/raw/main/catalog.sbox');
            expect(request.url.query, isEmpty);
            return http.StreamedResponse(
              Stream<List<int>>.value(payload),
              200,
              contentLength: payload.length,
            );
          }
          if (calls == 3) {
            return http.StreamedResponse(const Stream<List<int>>.empty(), 404);
          }
          expect(request.method, 'POST');
          expect(request.url.query, isEmpty);
          expect(request.url.toString(), isNot(contains('gitee-token')));
          expect(request.headers.containsKey('authorization'), isFalse);
          final value = jsonDecode(
            utf8.decode(await body.toBytes()),
          ) as Map<String, dynamic>;
          expect(value['access_token'], 'gitee-token');
          expect(base64Decode(value['content'] as String), payload);
          return _jsonResponse(<String, Object?>{
            'content': <String, Object?>{'sha': blobSha},
          }, status: 201);
        });
        final source = GiteeDataSource(
          config: RepositorySourceConfig(
            owner: 'alice',
            repository: 'vault',
            branch: 'main',
          ),
          client: client,
          credentialStore: store,
          credentialId: SourceCredentialId('gitee-main'),
        );

        expect(
          await _collect((await source.get(SourcePath('catalog.sbox'))).body),
          payload,
        );
        await source.putNew(
          SourcePath('objects/00/object.sbox'),
          Stream<List<int>>.value(payload),
          length: payload.length,
          sha256: sha256Bytes(payload),
        );
        expect(calls, 4);
      },
    );

    test(
      'conditional provider conflicts are mapped without response text',
      () async {
        final store = _CredentialStore('secret-token');
        final client = MockClient.streaming((request, body) async {
          await body.drain<void>();
          return http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode('secret-token must not leak')),
            409,
          );
        });
        final source = GitHubDataSource(
          config: RepositorySourceConfig(
            owner: 'alice',
            repository: 'vault',
            branch: 'main',
          ),
          client: client,
          credentialStore: store,
          credentialId: SourceCredentialId('github-main'),
        );
        await expectLater(
          source.compareAndSwap(
            SourcePath('catalog.sbox'),
            RevisionToken(
              ascii.encode('0123456789abcdef0123456789abcdef01234567'),
            ),
            Stream<List<int>>.value(payload),
            length: payload.length,
          ),
          throwsA(
            isA<SboxException>()
                .having(
                  (error) => error.code,
                  'code',
                  SboxErrorCode.syncConflict,
                )
                .having(
                  (error) => error.toString(),
                  'message',
                  isNot(contains('secret-token')),
                ),
          ),
        );
      },
    );
  });

  group('generic HTTPS and redirect policy', () {
    test('HTTPS source streams, bounds, and reuses ETag', () async {
      final bytes = utf8.encode('encrypted bytes');
      var calls = 0;
      final client = MockClient.streaming((request, body) async {
        calls++;
        if (calls == 1) {
          expect(
            request.url.toString(),
            'https://cdn.example/sbox/catalog.sbox',
          );
          return http.StreamedResponse(
            Stream<List<int>>.value(bytes),
            200,
            headers: <String, String>{'etag': '"revision-1"'},
            contentLength: bytes.length,
          );
        }
        expect(request.headers['if-none-match'], '"revision-1"');
        return http.StreamedResponse(const Stream<List<int>>.empty(), 304);
      });
      final source = HttpsReadOnlyDataSource(
        config: HttpsSourceConfig(
          baseUri: Uri.parse('https://cdn.example/sbox/'),
        ),
        client: client,
      );
      final first = await source.get(SourcePath('catalog.sbox'));
      expect(await _collect(first.body), bytes);
      final second = await source.get(
        SourcePath('catalog.sbox'),
        ifNoneMatch: first.revision,
      );
      expect(second.notModified, isTrue);
    });

    test(
      'cross-origin redirect strips authorization and cookie headers',
      () async {
        var calls = 0;
        final client = MockClient.streaming((request, body) async {
          calls++;
          if (calls == 1) {
            expect(request.headers['authorization'], 'Bearer temporary');
            return http.StreamedResponse(
              const Stream<List<int>>.empty(),
              302,
              headers: <String, String>{
                'location': 'https://objects.example/pinned.sbox',
              },
            );
          }
          expect(request.url.host, 'objects.example');
          expect(request.headers.containsKey('authorization'), isFalse);
          expect(request.headers.containsKey('cookie'), isFalse);
          return http.StreamedResponse(
            Stream<List<int>>.value(const <int>[1]),
            200,
            contentLength: 1,
          );
        });
        final response = await RemoteHttp(client).get(
          Uri.parse('https://api.example/object'),
          headers: const <String, String>{
            'Authorization': 'Bearer temporary',
            'Cookie': 'session=temporary',
          },
        );
        expect(await _collect(response.stream), const <int>[1]);
      },
    );
  });

  test('access tokens are redacted and their mutable bytes are disposable', () {
    final token = SourceAccessToken.fromUtf8('do-not-print-me');
    expect(token.toString(), isNot(contains('do-not-print-me')));
    token.dispose();
    expect(token.isDisposed, isTrue);
    expect(
      () => token.useAuthorizationValue('Bearer', (value) => value),
      throwsStateError,
    );
  });
}

final class _CredentialStore implements CredentialStore {
  _CredentialStore(this.value);

  final String value;
  SourceAccessToken? lastIssued;

  @override
  Future<void> deleteAccessToken(SourceCredentialId id) async {}

  @override
  Future<SourceAccessToken?> getAccessToken(SourceCredentialId id) async {
    return lastIssued = SourceAccessToken.fromUtf8(value);
  }

  @override
  Future<void> putAccessToken(
    SourceCredentialId id,
    SourceAccessToken token,
  ) async {}
}

http.StreamedResponse _jsonResponse(
  Map<String, Object?> value, {
  int status = 200,
}) {
  final bytes = utf8.encode(jsonEncode(value));
  return http.StreamedResponse(
    Stream<List<int>>.value(bytes),
    status,
    headers: const <String, String>{'content-type': 'application/json'},
    contentLength: bytes.length,
  );
}

String _gitBlobSha(List<int> value) => crypto.sha1.convert(<int>[
  ...ascii.encode('blob ${value.length}\u0000'),
  ...value,
]).toString();

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final output = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    output.add(chunk);
  }
  return output.takeBytes();
}
