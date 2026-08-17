import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safebox/app/app_controller.dart';
import 'package:safebox/app/safebox_app.dart';
import 'package:safebox/app/sbox_dialogs.dart';
import 'package:safebox/features/decrypt/decrypt_page.dart';

void main() {
  testWidgets('mnemonic dialog closes cleanly from the decrypt page', (
    tester,
  ) async {
    await tester.pumpWidget(
      SafeBoxApp(
        controller: AppController.preview(),
        initialSection: AppSection.decrypt,
      ),
    );
    await tester.pumpAndSettle();

    final prompt = showMnemonicPrompt(
      tester.element(find.byType(DecryptPage)),
      title: 'test',
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'test mnemonic');
    await tester.tap(find.byType(ElevatedButton).last);

    expect(await prompt, 'test mnemonic');
    await tester.pumpAndSettle();
  });
}
