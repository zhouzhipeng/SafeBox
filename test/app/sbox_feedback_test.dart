import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safebox/app/sbox_feedback.dart';

void main() {
  testWidgets('error feedback stays until the close action is pressed', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showSboxFeedback(context, '发生错误', error: true),
              child: const Text('显示错误'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('显示错误'));
    await tester.pumpAndSettle();

    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackBar.duration, sboxPersistentErrorSnackBarDuration);
    expect(snackBar.dismissDirection, DismissDirection.none);
    expect(snackBar.action?.label, '关闭');

    await tester.pump(const Duration(minutes: 1));
    expect(find.text('发生错误'), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('发生错误'), findsNothing);
  });
}
