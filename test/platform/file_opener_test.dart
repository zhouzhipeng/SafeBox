import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safebox/platform/file_opener.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.zhouzhipeng.safebox/windows_shell');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Windows opens a file through the native shell association', () async {
    final root = await Directory.systemTemp.createTemp('safebox-open-file-');
    addTearDown(() => root.delete(recursive: true));
    final file = await File('${root.path}${Platform.pathSeparator}archive.zip')
        .writeAsBytes(<int>[0x50, 0x4b]);
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return null;
        });

    await FileOpener.open(file);

    expect(capturedCall?.method, 'openPath');
    expect(capturedCall?.arguments, <String, Object?>{
      'path': file.absolute.path,
    });
  }, skip: !Platform.isWindows);

  test('Windows opens a directory through the native shell', () async {
    final directory = await Directory.systemTemp.createTemp(
      'safebox-open-directory-',
    );
    addTearDown(() => directory.delete(recursive: true));
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return null;
        });

    await FileOpener.openDirectory(directory);

    expect(capturedCall?.method, 'openPath');
    expect(capturedCall?.arguments, <String, Object?>{
      'path': directory.absolute.path,
    });
  }, skip: !Platform.isWindows);

  test('missing paths are rejected before invoking the native shell', () async {
    var invoked = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          invoked = true;
          return null;
        });
    final missing = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'safebox-file-that-does-not-exist',
    );

    await expectLater(
      FileOpener.open(missing),
      throwsA(isA<FileSystemException>()),
    );

    expect(invoked, isFalse);
  });
}
