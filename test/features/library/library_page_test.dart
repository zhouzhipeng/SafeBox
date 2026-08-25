import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safebox/app/app_controller.dart';
import 'package:safebox/app/sbox_theme.dart';
import 'package:safebox/features/library/library_page.dart';
import 'package:safebox/platform/cloud_backup_configuration_store.dart';
import 'package:safebox/sbox/format/bundle_header.dart';
import 'package:safebox/sbox/source/cloud_backup_config.dart';
import 'package:safebox/sbox/source/credential.dart';
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

    expect(find.text('选择文件'), findsOneWidget);
    expect(find.text('上传文件'), findsNothing);

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
    expect(find.text('加密并上传'), findsOneWidget);

    await tester.tap(find.textContaining('点击可更换文件'));
    await waitForText('second.zip');
    expect(find.text('second.zip'), findsOneWidget);
    expect(find.text('加密并上传'), findsOneWidget);
    expect(selectionCount, 2);

    await tester.tap(find.byKey(const Key('library-upload-file-button')));
    await tester.pump();

    expect(selectionCount, 2, reason: '上传按钮不应重新打开文件选择器');
    expect(find.text('请先完成安全身份设置。'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('SBOX selection switches action and saves to Local', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final temporary = (await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp(
        'safebox-library-sbox-import-test-',
      );
      final encoded = await File('test/fixtures/rust_sdk_interop.sbox.b64')
          .readAsString();
      await File('${directory.path}${Platform.pathSeparator}import.sbox')
          .writeAsBytes(base64Decode(encoded.trim()), flush: true);
      return directory;
    }))!;
    addTearDown(() => tester.runAsync(() => temporary.delete(recursive: true)));
    final selected = File(
      '${temporary.path}${Platform.pathSeparator}import.sbox',
    );
    final backup = Directory(
      '${temporary.path}${Platform.pathSeparator}local-backup',
    );
    final selectedBytes = (await tester.runAsync(selected.readAsBytes))!;
    final header = BundleHeader.parse(selectedBytes);
    final destination = File(
      '${backup.path}${Platform.pathSeparator}${header.canonicalBasename}',
    );

    final preferences = await SharedPreferences.getInstance();
    await CloudBackupConfigurationStore(preferences: preferences).save(
      CloudBackupConfiguration(
        backupDirectory: backup.path,
        github: CloudRepositoryEndpoint(
          owner: 'owner',
          repository: 'github-box',
          credentialId: SourceCredentialId('github-token'),
          enabled: false,
        ),
        gitee: CloudRepositoryEndpoint(
          owner: 'owner',
          repository: 'gitee-box',
          credentialId: SourceCredentialId('gitee-token'),
          enabled: false,
        ),
      ),
    );

    const fileSelectorChannel = MethodChannel(
      'plugins.flutter.io/file_selector',
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        fileSelectorChannel,
        null,
      ),
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      fileSelectorChannel,
      (call) async =>
          call.method == 'openFile' ? <String>[selected.path] : null,
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

    Future<void> waitForText(String text) async {
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 10));
        if (find.text(text).evaluate().isNotEmpty) return;
      }
    }

    await tester.tap(find.byKey(const Key('library-select-file-button')));
    await waitForText('import.sbox');

    expect(find.text('保存到local'), findsOneWidget);
    expect(find.text('附加信息（可选）'), findsNothing);

    await tester.tap(find.byKey(const Key('library-save-sbox-button')));
    await waitForText('SBOX 文件已保存到 Local。');

    expect(await tester.runAsync(destination.exists), isTrue);
    expect(await tester.runAsync(destination.readAsBytes), selectedBytes);
    expect(find.text('选择文件'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('Local file menu opens the encrypted backup folder', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final temporary = (await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp(
        'safebox-library-local-menu-test-',
      );
      final encoded = await File('test/fixtures/rust_sdk_interop.sbox.b64')
          .readAsString();
      final object = base64Decode(encoded.trim());
      final header = BundleHeader.parse(object);
      await File(
        '${directory.path}${Platform.pathSeparator}${header.canonicalBasename}',
      ).writeAsBytes(object, flush: true);
      return directory;
    }))!;
    addTearDown(() => tester.runAsync(() => temporary.delete(recursive: true)));
    final canonicalBackupPath = (await tester.runAsync(
      temporary.resolveSymbolicLinks,
    ))!;

    final preferences = await SharedPreferences.getInstance();
    await CloudBackupConfigurationStore(preferences: preferences).save(
      CloudBackupConfiguration(
        backupDirectory: temporary.path,
        github: CloudRepositoryEndpoint(
          owner: 'owner',
          repository: 'github-box',
          credentialId: SourceCredentialId('github-token'),
          enabled: false,
        ),
        gitee: CloudRepositoryEndpoint(
          owner: 'owner',
          repository: 'gitee-box',
          credentialId: SourceCredentialId('gitee-token'),
          enabled: false,
        ),
      ),
    );

    Directory? openedDirectory;
    final controller = AppController();
    addTearDown(controller.dispose);
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSboxTheme(),
        home: Scaffold(
          body: LibraryPage(
            controller: controller,
            directoryOpener: (directory) async {
              openedDirectory = directory;
            },
          ),
        ),
      ),
    );

    Future<void> waitFor(Finder finder) async {
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 10));
        if (finder.evaluate().isNotEmpty) return;
      }
    }

    await waitFor(find.byTooltip('更多操作'));
    await waitFor(find.byTooltip('刷新'));

    expect(find.byTooltip('更多操作'), findsOneWidget);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('打开文件夹'), findsOneWidget);

    await tester.tap(find.text('打开文件夹'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(openedDirectory?.absolute.path, canonicalBackupPath);
    expect(find.text('文件夹已打开。'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('decrypt dialog uses twelve responsive recovery word inputs', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final temporary = (await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp(
        'safebox-library-decrypt-dialog-test-',
      );
      final encoded = await File('test/fixtures/rust_sdk_interop.sbox.b64')
          .readAsString();
      final object = base64Decode(encoded.trim());
      final header = BundleHeader.parse(object);
      await File(
        '${directory.path}${Platform.pathSeparator}${header.canonicalBasename}',
      ).writeAsBytes(object, flush: true);
      return directory;
    }))!;
    addTearDown(() => tester.runAsync(() => temporary.delete(recursive: true)));

    final preferences = await SharedPreferences.getInstance();
    await CloudBackupConfigurationStore(preferences: preferences).save(
      CloudBackupConfiguration(
        backupDirectory: temporary.path,
        github: CloudRepositoryEndpoint(
          owner: 'owner',
          repository: 'github-box',
          credentialId: SourceCredentialId('github-token'),
          enabled: false,
        ),
        gitee: CloudRepositoryEndpoint(
          owner: 'owner',
          repository: 'gitee-box',
          credentialId: SourceCredentialId('gitee-token'),
          enabled: false,
        ),
      ),
    );

    final controller = AppController();
    addTearDown(controller.dispose);
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSboxTheme(),
        home: Scaffold(body: LibraryPage(controller: controller)),
      ),
    );

    Future<void> waitFor(Finder finder) async {
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 10));
        if (finder.evaluate().isNotEmpty) return;
      }
    }

    await waitFor(find.text('解密'));
    await tester.tap(find.text('解密'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('recovery-phrase-dialog')), findsOneWidget);
    expect(find.text('输入 12 个恢复词'), findsOneWidget);
    expect(find.text('按顺序输入恢复词，恢复词只保存在你手中'), findsOneWidget);
    for (var index = 1; index <= 12; index++) {
      expect(find.byKey(Key('recovery-word-$index')), findsOneWidget);
    }

    final firstRect = tester.getRect(find.byKey(const Key('recovery-word-1')));
    final secondRect = tester.getRect(find.byKey(const Key('recovery-word-2')));
    final thirdRect = tester.getRect(find.byKey(const Key('recovery-word-3')));
    final fourthRect = tester.getRect(find.byKey(const Key('recovery-word-4')));
    expect(secondRect.top, firstRect.top);
    expect(thirdRect.top, firstRect.top);
    expect(fourthRect.top, greaterThan(firstRect.top));

    var submit = tester.widget<ElevatedButton>(
      find.byKey(const Key('recovery-phrase-submit')),
    );
    expect(submit.onPressed, isNull);

    const words = <String>[
      'alpha',
      'bravo',
      'charlie',
      'delta',
      'echo',
      'foxtrot',
      'golf',
      'hotel',
      'india',
      'juliet',
      'kilo',
      'lima',
    ];
    await tester.enterText(
      find.byKey(const Key('recovery-word-1')),
      words.join(' '),
    );
    await tester.pump();

    for (var index = 0; index < words.length; index++) {
      final field = tester.widget<TextField>(
        find.byKey(Key('recovery-word-${index + 1}')),
      );
      expect(field.controller?.text, words[index]);
    }
    submit = tester.widget<ElevatedButton>(
      find.byKey(const Key('recovery-phrase-submit')),
    );
    expect(submit.onPressed, isNotNull);

    await tester.binding.setSurfaceSize(const Size(430, 900));
    await tester.pumpAndSettle();
    final mobileFirst = tester.getRect(
      find.byKey(const Key('recovery-word-1')),
    );
    final mobileSecond = tester.getRect(
      find.byKey(const Key('recovery-word-2')),
    );
    final mobileThird = tester.getRect(
      find.byKey(const Key('recovery-word-3')),
    );
    expect(mobileSecond.top, mobileFirst.top);
    expect(mobileThird.top, greaterThan(mobileFirst.top));
    expect(tester.takeException(), isNull);

    final cancel = find.byKey(const Key('recovery-phrase-cancel'));
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recovery-phrase-dialog')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
