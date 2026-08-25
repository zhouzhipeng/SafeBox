import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safebox/app/app_controller.dart';
import 'package:safebox/app/sbox_theme.dart';
import 'package:safebox/features/identity/mnemonic_onboarding.dart';

void main() {
  testWidgets('enter and space move focus to the next recovery word', (
    tester,
  ) async {
    final controller = AppController();
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() async {
      controller.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSboxTheme(),
        home: MnemonicOnboarding(controller: controller, onFinished: () {}),
      ),
    );
    await tester.tap(find.text('恢复已有身份'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(12));

    await tester.tap(fields.at(0));
    await tester.enterText(fields.at(0), 'abandon');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(tester.widget<TextField>(fields.at(1)).focusNode!.hasFocus, isTrue);

    await tester.enterText(fields.at(1), 'ability');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(tester.widget<TextField>(fields.at(1)).controller!.text, 'ability');
    expect(tester.widget<TextField>(fields.at(2)).focusNode!.hasFocus, isTrue);

    await tester.enterText(fields.at(2), 'able ');
    await tester.pump();

    expect(tester.widget<TextField>(fields.at(2)).controller!.text, 'able');
    expect(tester.widget<TextField>(fields.at(3)).focusNode!.hasFocus, isTrue);
  });
}
