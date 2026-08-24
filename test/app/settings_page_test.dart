import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safebox/app/app_controller.dart';
import 'package:safebox/app/app_logger.dart';
import 'package:safebox/features/settings/settings_page.dart';
import 'package:safebox/platform/app_settings_store.dart';
import 'package:safebox/platform/public_identity_store.dart';
import 'package:safebox/sbox/bytes.dart';
import 'package:safebox/sbox/identity/public_identity_record.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('copy public key confirms visibility and copies compact key', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final identityStore = PublicIdentityStore(preferences: preferences);
    await identityStore.save(
      PublicIdentityRecord(
        spkiDer: Uint8List.fromList(
          base64Url.decode(base64Url.normalize(_encodedSpki)),
        ),
        recipientKeyId: decodeHex(_keyId),
      ),
    );
    final controller = AppController(
      identityStore: identityStore,
      appSettingsStore: AppSettingsStore(preferences: preferences),
      logger: AppLogger(preferences: preferences),
    );
    await controller.initialize();

    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final arguments = call.arguments! as Map<Object?, Object?>;
          clipboardText = arguments['text']! as String;
        }
        return null;
      },
    );
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() async {
      controller.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(controller: controller, onOpenOnboarding: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('复制公钥'), findsOneWidget);
    await tester.tap(find.text('复制公钥'));
    await tester.pumpAndSettle();
    expect(find.text('复制公钥？'), findsOneWidget);
    expect(find.textContaining('不能仅凭公钥解密文件正文'), findsOneWidget);

    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(clipboardText, isNotNull);
    expect(clipboardText, startsWith('sboxpk1:'));
    expect(clipboardText!.length, 526);
    expect(
      hexLower(sha256Bytes(utf8.encode(clipboardText!))),
      'b6d9e085207e617655e703bf9a835e4b9d3ad09480742661a7ac0f4fc8f94f51',
    );
    final copied = PublicIdentityRecord.decode(clipboardText!);
    expect(copied.toJson(), <String, Object?>{
      'schema': 'SBOX-PUBLIC-IDENTITY-1',
      'key_profile_id': 1,
      'spki_der': _encodedSpki,
      'recipient_key_id': _keyId,
    });
    expect(clipboardText!.length, lessThan(copied.encodeJson().length));
    expect(find.text('公钥已复制。'), findsOneWidget);
  });
}

const _keyId =
    '9549c41744d3b469c512aa2c845677940937fd20685220fb0eb00f15082b04ae';

const _encodedSpki =
    'MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAuuLMXcnG7m37vzI1006K27P077n8a7rS5BKwP4E60rXTjHedUcDRlg_4O0CQgFCjnaB3VEtKk7VZJX0ucD76N-agPrjGOuV5T0WQ4uw3g9914tSPJol8G9AkXZlYgU8RVCTnkgYNCkuR3TRsaP_5oW80ELOskT52PZ_OEKFusm8eBU0yDLpNkgRKNIqLmxL1saBtGGbY4v-sfcNwNT6XKLX505WqEzA3Ig6XQs6a7wR3KFP9uKettKLBiLlC3WO0WJF9BpRrNNtSo-UE8xA8Y6uYLQYuDlXYf2tzsIv6jh3aC1-UQW9HX1ljRsB7qUrmpf55QfRzUt_cdIBWTf8M7utQHGZhv30mQilNcwwNdnaLH4vdqHjH1bqJQrIhPzAqmbDjarZ-CCc1QpamATcoY9rN9-g1_qDd-DqfYPVm3vdhA2hc5jKQgf99LEP3Lbv6sPc8g6GmzX7n6yffyy0JyCDqAaxNRKokr1ZjDpKZDR4DGeX89UH18-CP857_w0XHAgMBAAE';
