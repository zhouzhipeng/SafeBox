import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safebox/app/app_controller.dart';
import 'package:safebox/app/safebox_app.dart';

void main() {
  testWidgets('desktop shell exposes the complete SafeBox navigation', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1586, 992);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(SafeBoxApp(controller: AppController.preview()));
    await tester.pumpAndSettle();

    expect(find.text('资料库'), findsWidgets);
    expect(find.text('加密'), findsOneWidget);
    expect(find.text('解密'), findsOneWidget);
    expect(find.text('数据源'), findsOneWidget);
    expect(find.text('密钥'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('目录已验证'), findsOneWidget);
  });
}
