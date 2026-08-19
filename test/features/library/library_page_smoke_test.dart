import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safebox/app/app_controller.dart';
import 'package:safebox/app/sbox_theme.dart';
import 'package:safebox/features/library/library_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('library page builds', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final controller = AppController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSboxTheme(),
        home: Scaffold(body: LibraryPage(controller: controller)),
      ),
    );
    expect(find.text('上传文件'), findsOneWidget);
  });
}
