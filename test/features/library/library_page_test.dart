import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safebox/app/app_controller.dart';
import 'package:safebox/app/sbox_theme.dart';
import 'package:safebox/features/library/library_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('second file selection keeps the upload action responsive', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final temporary = (await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp(
        'safebox-library-upload-test-',
      );
      final first = File('${directory.path}${Platform.pathSeparator}first.zip');
      final second = File(
        '${directory.path}${Platform.pathSeparator}second.zip',
      );
      await first.writeAsBytes(<int>[1]);
      await second.writeAsBytes(<int>[2, 3]);
      return directory;
    }))!;
    addTearDown(() => tester.runAsync(() => temporary.delete(recursive: true)));
    final first = File('${temporary.path}${Platform.pathSeparator}first.zip');
    final second = File('${temporary.path}${Platform.pathSeparator}second.zip');

    const fileSelectorChannel = MethodChannel(
      'plugins.flutter.io/file_selector',
    );
    final selections = <String>[first.path, second.path];
    var selectionCount = 0;
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        fileSelectorChannel,
        null,
      ),
    );

    final controller = AppController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSboxTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 700,
            child: LibraryPage(controller: controller),
          ),
        ),
      ),
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      fileSelectorChannel,
      (call) async {
        if (call.method != 'openFile') return null;
        final selected = selections[selectionCount];
        selectionCount++;
        return <String>[selected];
      },
    );

    Future<void> waitForText(String text) async {
      for (var attempt = 0; attempt < 30; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (find.text(text).evaluate().isNotEmpty) return;
      }
    }

    await tester.tap(find.byKey(const Key('library-select-file-button')));
    await waitForText('first.zip');
    expect(find.text('first.zip'), findsOneWidget);

    await tester.tap(find.textContaining('点击可更换文件'));
    await waitForText('second.zip');
    expect(find.text('second.zip'), findsOneWidget);
    expect(selectionCount, 2);

    await tester.tap(find.byKey(const Key('library-upload-file-button')));
    await tester.pump();

    expect(selectionCount, 2, reason: '上传按钮不应重新打开文件选择器');
    expect(find.text('请先完成安全身份设置。'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
