import 'dart:async';

import 'package:flutter/material.dart';

import '../features/decrypt/decrypt_page.dart';
import '../features/encrypt/encrypt_page.dart';
import '../features/identity/mnemonic_onboarding.dart';
import '../features/library/library_page.dart';
import '../features/settings/keys_settings_pages.dart';
import '../features/sources/sources_page.dart';
import 'app_controller.dart';
import 'sbox_theme.dart';
import 'sbox_widgets.dart';

class SafeBoxApp extends StatefulWidget {
  const SafeBoxApp({
    super.key,
    this.controller,
    this.initialSection = AppSection.library,
    this.initialCatalogEntryId,
    this.forceOnboarding = false,
  });

  final AppController? controller;
  final AppSection initialSection;
  final String? initialCatalogEntryId;
  final bool forceOnboarding;

  @override
  State<SafeBoxApp> createState() => _SafeBoxAppState();
}

class _SafeBoxAppState extends State<SafeBoxApp> with WidgetsBindingObserver {
  late final AppController _controller;
  late final bool _ownsController;
  late AppSection _section;
  bool _booted = false;
  bool _showOnboarding = false;
  bool _privacyShield = false;
  String? _catalogEntryId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = widget.controller ?? AppController();
    _ownsController = widget.controller == null;
    _section = widget.initialSection;
    _catalogEntryId = widget.initialCatalogEntryId;
    _controller.addListener(_onControllerChanged);
    _initialize();
  }

  Future<void> _initialize() async {
    await _controller.initialize();
    if (!mounted) return;
    setState(() {
      _booted = true;
      _showOnboarding = widget.forceOnboarding || !_controller.hasIdentity;
    });
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (mounted) setState(() => _privacyShield = false);
        unawaited(_controller.runAutomaticCipherSync());
      case AppLifecycleState.inactive ||
          AppLifecycleState.paused ||
          AppLifecycleState.hidden:
        _controller.cancelSensitiveWork();
        if (mounted) setState(() => _privacyShield = true);
      case AppLifecycleState.detached:
        _controller.cancelSensitiveWork();
        if (_controller.clearPlaintextOnExit) {
          unawaited(
            _controller.clearTemporaryPlaintext().then<void>(
              (_) {},
              onError: (_) {},
            ),
          );
        }
        if (mounted) setState(() => _privacyShield = true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _navigate(AppSection section) {
    setState(() {
      _section = section;
      if (section != AppSection.decrypt) _catalogEntryId = null;
    });
  }

  void _decryptEntry(String entryId) {
    setState(() {
      _catalogEntryId = entryId;
      _section = AppSection.decrypt;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SafeBox',
      theme: buildSboxTheme(),
      home: !_booted
          ? const _BootScreen()
          : Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (_showOnboarding)
                  MnemonicOnboarding(
                    controller: _controller,
                    onFinished: (section) => setState(() {
                      _showOnboarding = false;
                      _section = section;
                    }),
                  )
                else
                  _ResponsiveShell(
                    controller: _controller,
                    section: _section,
                    catalogEntryId: _catalogEntryId,
                    onNavigate: _navigate,
                    onDecryptEntry: _decryptEntry,
                    onCreateIdentity: () =>
                        setState(() => _showOnboarding = true),
                  ),
                if (_privacyShield) const _PrivacyShield(),
              ],
            ),
    );
  }
}

class _ResponsiveShell extends StatelessWidget {
  const _ResponsiveShell({
    required this.controller,
    required this.section,
    required this.catalogEntryId,
    required this.onNavigate,
    required this.onDecryptEntry,
    required this.onCreateIdentity,
  });

  final AppController controller;
  final AppSection section;
  final String? catalogEntryId;
  final ValueChanged<AppSection> onNavigate;
  final ValueChanged<String> onDecryptEntry;
  final VoidCallback onCreateIdentity;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= 900;
        return Scaffold(
          body: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  Color(0xFF0A1724),
                  SboxColors.background,
                  SboxColors.backgroundDeep,
                ],
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Row(
                children: <Widget>[
                  if (desktop)
                    _DesktopSidebar(section: section, onNavigate: onNavigate),
                  Expanded(
                    child: Column(
                      children: <Widget>[
                        _TopStatusBar(controller: controller, mobile: !desktop),
                        _MessageStrip(controller: controller),
                        Expanded(
                          child: MediaQuery(
                            data: MediaQuery.of(context).copyWith(
                              textScaler: MediaQuery.textScalerOf(context)
                                  .clamp(maxScaleFactor: 2),
                            ),
                            child: _page(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          bottomNavigationBar: desktop
              ? null
              : _MobileNavigation(section: section, onNavigate: onNavigate),
        );
      },
    );
  }

  Widget _page() => switch (section) {
    AppSection.library => LibraryPage(
      controller: controller,
      onOpenSources: () => onNavigate(AppSection.sources),
      onDecryptEntry: onDecryptEntry,
      onStandaloneSelected: () => onNavigate(AppSection.decrypt),
    ),
    AppSection.encrypt => EncryptPage(controller: controller),
    AppSection.decrypt => DecryptPage(
      controller: controller,
      catalogEntryId: catalogEntryId,
    ),
    AppSection.sources => SourcesPage(controller: controller),
    AppSection.keys => KeysPage(
      controller: controller,
      onCreateIdentity: onCreateIdentity,
    ),
    AppSection.settings => SettingsPage(
      controller: controller,
      onOpenSources: () => onNavigate(AppSection.sources),
    ),
    AppSection.more => MorePage(onNavigate: onNavigate),
  };
}

class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar({required this.section, required this.onNavigate});
  final AppSection section;
  final ValueChanged<AppSection> onNavigate;

  @override
  Widget build(BuildContext context) {
    const primary = <(AppSection, IconData, String)>[
      (AppSection.library, Icons.grid_view_rounded, '资料库'),
      (AppSection.encrypt, Icons.lock_outline_rounded, '加密'),
      (AppSection.decrypt, Icons.lock_open_outlined, '解密'),
      (AppSection.sources, Icons.storage_outlined, '数据源'),
      (AppSection.keys, Icons.key_outlined, '密钥'),
      (AppSection.settings, Icons.settings_outlined, '设置'),
    ];
    return Container(
      width: 276,
      decoration: const BoxDecoration(
        color: SboxColors.sidebar,
        border: Border(right: BorderSide(color: SboxColors.borderSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.fromLTRB(28, 26, 24, 30),
            child: SboxLogo(),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '安全工作区',
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: SboxColors.textDim, letterSpacing: 1.2),
            ),
          ),
          const SizedBox(height: 10),
          for (final item in primary)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 3),
              child: _SidebarItem(
                icon: item.$2,
                label: item.$3,
                selected: section == item.$1,
                onTap: () => onNavigate(item.$1),
              ),
            ),
          const Spacer(),
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 12, 18, 20),
            child: SecurityNotice(
              title: '私钥不落盘',
              message: '公钥与 SBOX 可永久保存；每次私钥操作均使用一次性 Isolate。',
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: SboxColors.borderSoft)),
            ),
            child: const Row(
              children: <Widget>[
                Icon(Icons.shield_outlined, size: 16, color: SboxColors.accent),
                SizedBox(width: 8),
                Text(
                  'SBOX v1 · 离线优先',
                  style: TextStyle(color: SboxColors.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: selected
              ? SboxColors.accent.withValues(alpha: 0.11)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: selected
                ? SboxColors.accent.withValues(alpha: 0.25)
                : Colors.transparent,
          ),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              icon,
              size: 20,
              color: selected ? SboxColors.accent : SboxColors.textMuted,
            ),
            const SizedBox(width: 13),
            Text(
              label,
              style: TextStyle(
                color: selected ? SboxColors.text : SboxColors.textMuted,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
            if (selected) ...<Widget>[
              const Spacer(),
              Container(
                width: 4,
                height: 18,
                decoration: BoxDecoration(
                  color: SboxColors.accent,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class _TopStatusBar extends StatelessWidget {
  const _TopStatusBar({required this.controller, required this.mobile});
  final AppController controller;
  final bool mobile;
  @override
  Widget build(BuildContext context) => Container(
    height: mobile ? 64 : 58,
    padding: EdgeInsets.symmetric(horizontal: mobile ? 18 : 28),
    decoration: BoxDecoration(
      color: SboxColors.background.withValues(alpha: 0.72),
      border: const Border(bottom: BorderSide(color: SboxColors.borderSoft)),
    ),
    child: Row(
      children: <Widget>[
        if (mobile) ...<Widget>[
          const SboxLogo(compact: true),
          const Spacer(),
        ] else
          const Spacer(),
        if (!mobile)
          const StatusPill(
            label: '本地离线处理',
            icon: Icons.wifi_off_rounded,
            tone: SboxColors.accent,
            compact: true,
          ),
        if (!mobile) const SizedBox(width: 14),
        Container(
          width: 7,
          height: 7,
          decoration: const BoxDecoration(
            color: SboxColors.success,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            controller.shortFingerprint,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: SboxColors.textMuted,
              fontSize: 11,
              fontFamily: 'RobotoMono',
            ),
          ),
        ),
        if (mobile) ...<Widget>[
          const SizedBox(width: 8),
          IconButton(
            onPressed: () {},
            icon: const Icon(Icons.notifications_none_rounded),
            tooltip: '状态通知',
          ),
        ],
      ],
    ),
  );
}

class _MessageStrip extends StatelessWidget {
  const _MessageStrip({required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) {
    final error = controller.errorMessage;
    final status = controller.statusMessage;
    if (error == null && status == null) return const SizedBox.shrink();
    final isError = error != null;
    final tone = isError ? SboxColors.danger : SboxColors.accent;
    return Material(
      color: tone.withValues(alpha: 0.09),
      child: Container(
        constraints: const BoxConstraints(minHeight: 42),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 9),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: tone.withValues(alpha: 0.22)),
          ),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              isError ? Icons.error_outline : Icons.check_circle_outline,
              color: tone,
              size: 18,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                error ?? status!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: tone,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              onPressed: controller.clearMessages,
              icon: const Icon(Icons.close_rounded, size: 18),
              tooltip: '关闭提示',
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileNavigation extends StatelessWidget {
  const _MobileNavigation({required this.section, required this.onNavigate});
  final AppSection section;
  final ValueChanged<AppSection> onNavigate;
  @override
  Widget build(BuildContext context) {
    final index = switch (section) {
      AppSection.library => 0,
      AppSection.encrypt => 1,
      AppSection.decrypt => 2,
      _ => 3,
    };
    return NavigationBar(
      height: 72,
      backgroundColor: SboxColors.sidebar,
      indicatorColor: SboxColors.accent.withValues(alpha: 0.14),
      selectedIndex: index,
      onDestinationSelected: (value) => onNavigate(
        <AppSection>[
          AppSection.library,
          AppSection.encrypt,
          AppSection.decrypt,
          AppSection.more,
        ][value],
      ),
      destinations: const <NavigationDestination>[
        NavigationDestination(
          icon: Icon(Icons.grid_view_outlined),
          selectedIcon: Icon(Icons.grid_view_rounded, color: SboxColors.accent),
          label: '资料库',
        ),
        NavigationDestination(
          icon: Icon(Icons.lock_outline_rounded),
          selectedIcon: Icon(Icons.lock_rounded, color: SboxColors.accent),
          label: '加密',
        ),
        NavigationDestination(
          icon: Icon(Icons.lock_open_outlined),
          selectedIcon: Icon(Icons.lock_open_rounded, color: SboxColors.accent),
          label: '解密',
        ),
        NavigationDestination(
          icon: Icon(Icons.more_horiz_rounded),
          selectedIcon: Icon(Icons.more_rounded, color: SboxColors.accent),
          label: '更多',
        ),
      ],
    );
  }
}

class _BootScreen extends StatelessWidget {
  const _BootScreen();
  @override
  Widget build(BuildContext context) => const Scaffold(
    body: DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          colors: <Color>[Color(0xFF102A36), SboxColors.backgroundDeep],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SboxLogo(),
            SizedBox(height: 28),
            SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            SizedBox(height: 14),
            Text(
              '正在加载公开配置与本地密文索引',
              style: TextStyle(color: SboxColors.textMuted),
            ),
          ],
        ),
      ),
    ),
  );
}

class _PrivacyShield extends StatelessWidget {
  const _PrivacyShield();
  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: SboxColors.backgroundDeep,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SboxLogo(),
          SizedBox(height: 20),
          Icon(
            Icons.visibility_off_outlined,
            color: SboxColors.accent,
            size: 34,
          ),
          SizedBox(height: 12),
          Text(
            'SafeBox 已隐藏敏感内容',
            style: TextStyle(
              color: SboxColors.text,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 6),
          Text(
            '返回前台后可重新开始需要助记词的任务',
            style: TextStyle(color: SboxColors.textMuted),
          ),
        ],
      ),
    ),
  );
}
