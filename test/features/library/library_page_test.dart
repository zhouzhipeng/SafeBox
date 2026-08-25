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
}
