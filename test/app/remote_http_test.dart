import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:safebox/app/app_logger.dart';
import 'package:safebox/sbox/errors.dart';
import 'package:safebox/sbox/source/remote_http.dart';

void main() {
  test(
    'remote network failures retain the underlying cause in app logs',
    () async {
      final logger = AppLogger();
      final remote = RemoteHttp(
        _ThrowingClient(),
        logger: logger,
        sourceName: 'GitHub',
      );

      await expectLater(
        remote.get(Uri.parse('https://api.github.com/repos/example/box')),
        throwsA(
          isA<SboxException>().having(
            (error) => error.code,
            'code',
            SboxErrorCode.sourceNetwork,
          ),
        ),
      );

      expect(logger.entries, isNotEmpty);
      expect(logger.exportText(), contains('StateError'));
      expect(logger.exportText(), contains('连接被拒绝'));
      expect(logger.exportText(), isNot(contains('/repos/example/box')));
    },
  );

  test(
    'HTTP 403 rate-limit headers are retryable and retain the delay',
    () async {
      final remote = RemoteHttp(_ThrowingClient());
      final response = http.StreamedResponse(
        const Stream<List<int>>.empty(),
        403,
        headers: const <String, String>{
          'x-ratelimit-remaining': '0',
          'retry-after': '17',
        },
      );

      await expectLater(
        remote.throwForStatus(response, RemoteFailureContext.immutableCreate),
        throwsA(
          isA<SboxException>()
              .having(
                (error) => error.code,
                'code',
                SboxErrorCode.sourceRateLimit,
              )
              .having(
                (error) => error.retryAfter,
                'retryAfter',
                const Duration(seconds: 17),
              ),
        ),
      );
    },
  );

  test('HTTP 403 rate-limit response bodies are retryable', () async {
    final remote = RemoteHttp(_ThrowingClient());
    final response = http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('{"message":"操作过于频繁，请稍后再试"}')),
      403,
    );

    await expectLater(
      remote.throwForStatus(response, RemoteFailureContext.immutableCreate),
      throwsA(
        isA<SboxException>().having(
          (error) => error.code,
          'code',
          SboxErrorCode.sourceRateLimit,
        ),
      ),
    );
  });

  test('ordinary HTTP 403 responses remain authentication failures', () async {
    final remote = RemoteHttp(_ThrowingClient());
    final response = http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('{"message":"Forbidden"}')),
      403,
    );

    await expectLater(
      remote.throwForStatus(response, RemoteFailureContext.immutableCreate),
      throwsA(
        isA<SboxException>().having(
          (error) => error.code,
          'code',
          SboxErrorCode.sourceAuthentication,
        ),
      ),
    );
  });
}

final class _ThrowingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Future<http.StreamedResponse>.error(StateError('连接被拒绝'));
}
