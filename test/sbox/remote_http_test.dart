import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';
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
}

final class _ThrowingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Future<http.StreamedResponse>.error(StateError('连接被拒绝'));
}
