import 'package:flutter/material.dart';

import '../features/identity/mnemonic_onboarding.dart';
import '../features/library/library_page.dart';
import '../features/settings/settings_page.dart';
import 'app_controller.dart';
import 'sbox_theme.dart';
import 'sbox_widgets.dart';

class SafeBoxApp extends StatefulWidget {
  const SafeBoxApp({super.key, this.controller});

  final AppController? controller;

  @override
  State<SafeBoxApp> createState() => _SafeBoxAppState();
}

class _SafeBoxAppState extends State<SafeBoxApp> {
  late final AppController _controller = widget.controller ?? AppController();
  late final bool _ownsController = widget.controller == null;
  AppSection _section = AppSection.library;
  bool _booted = false;
  bool _onboarding = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
    _initialize();
  }

  Future<void> _initialize() async {
    await _controller.initialize();
    if (!mounted) return;
    setState(() {
      _booted = true;
      _onboarding = !_controller.hasIdentity;
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SafeBox',
      theme: buildSboxTheme(),
      home: !_booted
          ? const _BootScreen()
          : _onboarding
          ? MnemonicOnboarding(
              controller: _controller,
              onFinished: () => setState(() {
                _onboarding = false;
                _section = AppSection.library;
              }),
              onOpenSettings: () => setState(() {
                _onboarding = false;
                _section = AppSection.settings;
              }),
            )
          : _HomeShell(
              controller: _controller,
              section: _section,
              onSectionChanged: (section) => setState(() => _section = section),
              onOpenOnboarding: () => setState(() => _onboarding = true),
            ),
    );
  }
}

final class _HomeShell extends StatefulWidget {
  const _HomeShell({
    required this.controller,
    required this.section,
    required this.onSectionChanged,
    required this.onOpenOnboarding,
  });

  final AppController controller;
  final AppSection section;
  final ValueChanged<AppSection> onSectionChanged;
  final VoidCallback onOpenOnboarding;

  @override
  State<_HomeShell> createState() => _HomeShellState();
}

final class _HomeShellState extends State<_HomeShell> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final mobile = constraints.maxWidth < 760;
            final settingsSelected = widget.section == AppSection.settings;
            final page = settingsSelected
                ? SettingsPage(
                    controller: widget.controller,
                    onOpenOnboarding: widget.onOpenOnboarding,
                  )
                : LibraryPage(
                    controller: widget.controller,
                    onOpenCloudSettings: () =>
                        widget.onSectionChanged(AppSection.settings),
                  );
            return DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    SboxColors.backgroundDeep,
                    SboxColors.background,
                  ],
                ),
              ),
              child: Column(
                children: <Widget>[
                  SboxTopBar(
                    mobile: mobile,
                    filesSelected: !settingsSelected,
                    settingsSelected: settingsSelected,
                    onFilesTap: () =>
                        widget.onSectionChanged(AppSection.library),
                    onSettingsTap: () =>
                        widget.onSectionChanged(AppSection.settings),
                  ),
                  Expanded(child: page),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

final class _BootScreen extends StatelessWidget {
  const _BootScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[SboxColors.backgroundDeep, SboxColors.background],
          ),
        ),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SboxLogo(),
              SizedBox(height: 24),
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
