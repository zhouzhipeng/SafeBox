import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safebox/platform/web_proxy_http_client.dart';
import 'package:test/test.dart';

void main() {
  test(
    'proxy client preserves request metadata and streams the response',
    () async {
      final target = Uri.parse(
        'https://api.github.com/repos/example/private/releases/assets/42',
      );
      final inner = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.origin, 'https://app.example.test');
        expect(request.url.path, '/_safebox/proxy');
        expect(request.url.queryParameters, <String, String>{
          'url': target.toString(),
        });
        expect(request.url.toString(), isNot(contains('secret-token')));
        expect(request.headers['authorization'], 'Bearer secret-token');
        expect(request.headers['content-type'], 'application/octet-stream');
        expect(request.bodyBytes, <int>[1, 2, 3, 4]);
        return http.Response.bytes(
          <int>[5, 6, 7],
          206,
          headers: const <String, String>{
            SafeBoxWebProxyClient.markerHeader: '1',
            'content-range': 'bytes 0-2/3',
          },
        );
      });
      final client = SafeBoxWebProxyClient(
        inner,
        proxyEndpoint: Uri.parse('https://app.example.test/_safebox/proxy'),
      );
      final request = http.Request('POST', target)
        ..followRedirects = false
        ..headers['Authorization'] = 'Bearer secret-token'
        ..headers['Content-Type'] = 'application/octet-stream'
        ..bodyBytes = <int>[1, 2, 3, 4];

      final response = await client.send(request);

      expect(response.statusCode, 206);
      expect(response.headers['content-range'], 'bytes 0-2/3');
      expect(await response.stream.toBytes(), <int>[5, 6, 7]);
    },
  );

  test(
    'multipart headers produced during finalization reach the proxy',
    () async {
      final inner = MockClient((request) async {
        expect(
          request.headers['content-type'],
          startsWith('multipart/form-data; boundary='),
        );
        expect(request.body, contains('access_token'));
        expect(request.body, contains('token-value'));
        expect(request.body, contains('bundle.sbox'));
        return http.Response(
          '{}',
          201,
          headers: const <String, String>{
            SafeBoxWebProxyClient.markerHeader: '1',
          },
        );
      });
      final client = SafeBoxWebProxyClient(
        inner,
        proxyEndpoint: Uri.parse('http://localhost:8080/_safebox/proxy'),
      );
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('https://gitee.com/api/v5/repos/a/b/releases/1/attach_files'),
      )..fields['access_token'] = 'token-value';
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          utf8.encode('ciphertext'),
          filename: 'bundle.sbox',
        ),
      );

      final response = await client.send(request);

      expect(response.statusCode, 201);
      await response.stream.drain<void>();
    },
  );

  test('missing proxy marker produces a clear proxy error', () async {
    final client = SafeBoxWebProxyClient(
      MockClient((_) async => http.Response('not a proxy', 404)),
      proxyEndpoint: Uri.parse('http://localhost:8080/_safebox/proxy'),
    );

    await expectLater(
      client.get(Uri.parse('https://api.github.com/repos/a/b')),
      throwsA(isA<WebProxyUnavailableException>()),
    );
  });

  test('proxy endpoint must be an absolute HTTP(S) URL', () {
    final inner = MockClient((_) async => http.Response('', 200));

    expect(
      () => SafeBoxWebProxyClient(
        inner,
        proxyEndpoint: Uri.parse('/_safebox/proxy'),
      ),
      throwsArgumentError,
    );
    expect(
      () => SafeBoxWebProxyClient(
        inner,
        proxyEndpoint: Uri.parse(
          'https://user@app.example.test/_safebox/proxy',
        ),
      ),
      throwsArgumentError,
    );
  });
}
