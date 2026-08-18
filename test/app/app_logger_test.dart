import 'package:flutter_test/flutter_test.dart';
import 'package:safebox/app/app_logger.dart';
import 'package:safebox/sbox/errors.dart';

void main() {
  test('application logs redact credentials and URL paths', () {
    final logger = AppLogger();
    logger.error(
      StateError(
        'Authorization: Bearer secret-value access_token=another-secret '
        'https://api.example.test/private/file.sbox?token=third-secret',
      ),
      operation: '云端请求失败',
    );

    final exported = logger.exportText();
    expect(exported, contains('Authorization=<已隐藏>'));
    expect(exported, contains('access_token=<已隐藏>'));
    expect(exported, contains('https://api.example.test'));
    expect(exported, isNot(contains('secret-value')));
    expect(exported, isNot(contains('another-secret')));
    expect(exported, isNot(contains('third-secret')));
    expect(exported, isNot(contains('/private/file.sbox')));
  });

  test('SBOX errors keep their stable code in diagnostics', () {
    final logger = AppLogger();
    logger.error(
      const SboxException(SboxErrorCode.sourceNetwork, '无法安全连接数据源'),
      operation: '浏览云端文件失败',
    );

    expect(logger.entries, hasLength(1));
    expect(logger.entries.single.detail, contains('SBOX_E_SOURCE_NETWORK'));
  });
}
