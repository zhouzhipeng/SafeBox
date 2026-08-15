import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safebox/app/app_controller.dart';
import 'package:safebox/app/safebox_app.dart';
import 'package:safebox/app/sbox_theme.dart';
import 'package:safebox/features/identity/mnemonic_onboarding.dart';
import 'package:safebox/features/sources/sources_page.dart';

const _visualOnlyMnemonic =
    'legal winner thank year wave sausage worth useful legal winner thank yellow';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadBundledFonts);

  testWidgets('mnemonic desktop visual baseline', (tester) async {
    _setDesktop(tester);
    final controller = AppController.preview();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildSboxTheme(),
        home: MnemonicOnboarding(
          controller: controller,
          initialStage: OnboardingStage.backup,
          previewMnemonic: _visualOnlyMnemonic,
          onFinished: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MnemonicOnboarding),
      matchesGoldenFile('goldens/sbox-v1-mnemonic-desktop.png'),
    );
  });

  testWidgets('catalog desktop visual baseline', (tester) async {
    _setDesktop(tester);
    await _pumpPreview(tester, AppSection.library);
    await expectLater(
      find.byType(SafeBoxApp),
      matchesGoldenFile('goldens/sbox-v1-catalog-desktop.png'),
    );
  });

  testWidgets('catalog mobile visual baseline', (tester) async {
    _setMobile(tester, width: 864, height: 1821);
    await _pumpPreview(tester, AppSection.library);
    await expectLater(
      find.byType(SafeBoxApp),
      matchesGoldenFile('goldens/sbox-v1-catalog-mobile.png'),
    );
  });

  testWidgets('encrypt desktop visual baseline', (tester) async {
    _setDesktop(tester);
    await _pumpPreview(tester, AppSection.encrypt);
    await expectLater(
      find.byType(SafeBoxApp),
      matchesGoldenFile('goldens/sbox-v1-encrypt-desktop.png'),
    );
  });

  testWidgets('download decrypt desktop visual baseline', (tester) async {
    _setDesktop(tester);
    await _pumpPreview(
      tester,
      AppSection.decrypt,
      entryId: '00112233445566778899aabbccddeeff',
    );
    await expectLater(
      find.byType(SafeBoxApp),
      matchesGoldenFile('goldens/sbox-v1-download-decrypt-desktop.png'),
    );
  });

  testWidgets('data sources desktop visual baseline', (tester) async {
    _setDesktop(tester);
    await _pumpPreview(tester, AppSection.sources);
    await expectLater(
      find.byType(SafeBoxApp),
      matchesGoldenFile('goldens/sbox-v1-data-sources-desktop.png'),
    );
  });

  testWidgets('add source desktop visual baseline', (tester) async {
    _setDesktop(tester);
    await _pumpAddSource(tester);
    await expectLater(
      find.byType(AddSourceView),
      matchesGoldenFile('goldens/sbox-v1-add-source-desktop.png'),
    );
  });

  testWidgets('add source mobile visual baseline', (tester) async {
    _setMobile(tester, width: 863, height: 1823);
    await _pumpAddSource(tester);
    await expectLater(
      find.byType(AddSourceView),
      matchesGoldenFile('goldens/sbox-v1-add-source-mobile.png'),
    );
  });
}

Future<void> _loadBundledFonts() async {
  final notoSans = FontLoader('NotoSansSC')
    ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf'));
  final robotoMono = FontLoader('RobotoMono')
    ..addFont(rootBundle.load('assets/fonts/RobotoMono-Variable.ttf'));
  final materialIcons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await Future.wait(<Future<void>>[
    notoSans.load(),
    robotoMono.load(),
    materialIcons.load(),
  ]);
}

Future<void> _pumpPreview(
  WidgetTester tester,
  AppSection section, {
  String? entryId,
}) async {
  final controller = AppController.preview()..clearMessages();
  await tester.pumpWidget(
    SafeBoxApp(
      controller: controller,
      initialSection: section,
      initialCatalogEntryId: entryId,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpAddSource(WidgetTester tester) async {
  final controller = AppController.preview()..clearMessages();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildSboxTheme(),
      home: Scaffold(
        body: AddSourceView(controller: controller, onClose: () {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _setDesktop(WidgetTester tester) {
  tester.view.physicalSize = const Size(1586, 992);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _setMobile(
  WidgetTester tester, {
  required double width,
  required double height,
}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
