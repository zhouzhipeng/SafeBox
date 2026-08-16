import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/sbox_theme.dart';
import '../../app/sbox_widgets.dart';

enum OnboardingStage { welcome, backup, confirm, recover, deriving, complete }

class MnemonicOnboarding extends StatefulWidget {
  const MnemonicOnboarding({
    super.key,
    required this.controller,
    required this.onFinished,
    this.initialStage = OnboardingStage.welcome,
    this.previewMnemonic,
  });

  final AppController controller;
  final ValueChanged<AppSection> onFinished;
  final OnboardingStage initialStage;
  final String? previewMnemonic;

  @override
  State<MnemonicOnboarding> createState() => _MnemonicOnboardingState();
}

class _MnemonicOnboardingState extends State<MnemonicOnboarding>
    with WidgetsBindingObserver {
  static const _confirmIndexes = <int>[1, 4, 7, 10];
  late OnboardingStage _stage;
  String _mnemonic = '';
  bool _backedUp = false;
  String? _inlineError;
  final _recovery = TextEditingController();
  final _confirm = <int, TextEditingController>{
    for (final index in _confirmIndexes) index: TextEditingController(),
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _stage = widget.initialStage;
    if (_stage == OnboardingStage.backup || _stage == OnboardingStage.confirm) {
      _mnemonic =
          widget.previewMnemonic ?? widget.controller.generateMnemonic();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _clearSensitiveInputs();
      if (mounted && _stage != OnboardingStage.deriving) {
        setState(() {
          _mnemonic = '';
          _stage = OnboardingStage.welcome;
          _backedUp = false;
          _inlineError = '应用离开前台，未完成的助记词流程已清除。';
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clearSensitiveInputs();
    _recovery.dispose();
    for (final controller in _confirm.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _clearSensitiveInputs() {
    _recovery.clear();
    for (final controller in _confirm.values) {
      controller.clear();
    }
  }

  void _createIdentity() {
    setState(() {
      _mnemonic = widget.controller.generateMnemonic();
      _backedUp = false;
      _inlineError = null;
      _stage = OnboardingStage.backup;
    });
  }

  Future<void> _confirmAndDerive() async {
    final words = _mnemonic.split(' ');
    final valid = _confirmIndexes.every(
      (index) => _confirm[index]!.text.trim().toLowerCase() == words[index],
    );
    if (!valid) {
      setState(() => _inlineError = '确认词不匹配，请对照离线备份重新填写。');
      return;
    }
    final oneShotMnemonic = _mnemonic;
    _mnemonic = '';
    _clearSensitiveInputs();
    setState(() {
      _inlineError = null;
      _stage = OnboardingStage.deriving;
    });
    try {
      await widget.controller.establishIdentity(oneShotMnemonic);
      if (mounted) setState(() => _stage = OnboardingStage.complete);
    } catch (_) {
      if (mounted) {
        setState(() {
          _stage = OnboardingStage.welcome;
          _inlineError = widget.controller.errorMessage;
        });
      }
    }
  }

  Future<void> _recoverIdentity() async {
    final oneShotMnemonic = _recovery.text.trim();
    _recovery.clear();
    setState(() {
      _inlineError = null;
      _stage = OnboardingStage.deriving;
    });
    try {
      await widget.controller.establishIdentity(oneShotMnemonic);
      if (mounted) setState(() => _stage = OnboardingStage.complete);
    } catch (_) {
      if (mounted) {
        setState(() {
          _stage = OnboardingStage.recover;
          _inlineError = widget.controller.errorMessage;
        });
      }
    }
  }

  Future<void> _openLocalDirectory() async {
    if (widget.controller.supportsAuthorizedDirectorySelection) {
      try {
        final added = await widget.controller
            .chooseAndAddAuthorizedLocalSource();
        if (added) widget.onFinished(AppSection.library);
      } catch (_) {}
      return;
    }
    final path = await widget.controller.chooseLocalCipherDirectory(
      confirmButtonText: '打开此 SBOX 目录',
    );
    if (path == null) return;
    try {
      await widget.controller.addLocalSource(
        displayName: '本地 SBOX 目录',
        path: path,
        requestWrite: true,
        initializeEmptyAsCanonical: true,
      );
      widget.onFinished(AppSection.library);
    } catch (_) {
      if (mounted) {
        setState(() => _inlineError = widget.controller.errorMessage);
      }
    }
  }

  Future<void> _createManagedLocalDirectory() async {
    try {
      await widget.controller.addManagedWritableLocalSource();
      widget.onFinished(AppSection.library);
    } catch (_) {
      if (mounted) {
        setState(() => _inlineError = widget.controller.errorMessage);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.15, -0.85),
            radius: 1.3,
            colors: <Color>[
              Color(0xFF102A36),
              SboxColors.background,
              SboxColors.backgroundDeep,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 34,
                  vertical: 22,
                ),
                child: Row(
                  children: <Widget>[
                    const SboxLogo(),
                    const Spacer(),
                    const StatusPill(
                      label: '本地离线身份',
                      icon: Icons.wifi_off_rounded,
                      tone: SboxColors.accent,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 36),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 940),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: _buildStage(context),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStage(BuildContext context) {
    return switch (_stage) {
      OnboardingStage.welcome => _welcome(context),
      OnboardingStage.backup => _backup(context),
      OnboardingStage.confirm => _confirmPage(context),
      OnboardingStage.recover => _recover(context),
      OnboardingStage.deriving => _deriving(context),
      OnboardingStage.complete => _complete(context),
    };
  }

  Widget _frame({required Widget child}) {
    return SboxCard(
      key: ValueKey<OnboardingStage>(_stage),
      padding: const EdgeInsets.fromLTRB(46, 38, 46, 42),
      color: const Color(0xFF101D2A),
      borderColor: const Color(0xFF304355),
      radius: 16,
      child: child,
    );
  }

  Widget _welcome(BuildContext context) {
    return _frame(
      child: Column(
        children: <Widget>[
          const _StepHeader(active: 0),
          const SizedBox(height: 42),
          _largeIcon(Icons.shield_outlined),
          const SizedBox(height: 22),
          Text(
            '建立你的 SafeBox 身份',
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 10),
          Text(
            '12 个 BIP39 英文单词会确定性恢复同一组 RSA-3072 与 Catalog 身份公钥。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge
                ?.copyWith(color: SboxColors.textMuted),
          ),
          const SizedBox(height: 30),
          if (_inlineError != null) ...<Widget>[
            SecurityNotice(
              title: '流程已停止',
              message: _inlineError!,
              warning: true,
            ),
            const SizedBox(height: 18),
          ],
          LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 620;
              final create = _IdentityChoice(
                icon: Icons.add_moderator_outlined,
                title: '创建新身份',
                description: '生成全新的 12 词助记词，只在本次流程显示。',
                action: '开始创建',
                primary: true,
                onPressed: _createIdentity,
              );
              final recover = _IdentityChoice(
                icon: Icons.key_outlined,
                title: '恢复现有身份',
                description: '临时输入已有助记词，核对并重新保存公开身份。',
                action: '开始恢复',
                onPressed: () => setState(() {
                  _inlineError = null;
                  _stage = OnboardingStage.recover;
                }),
              );
              return narrow
                  ? Column(
                      children: <Widget>[
                        create,
                        const SizedBox(height: 14),
                        recover,
                      ],
                    )
                  : Row(
                      children: <Widget>[
                        Expanded(child: create),
                        const SizedBox(width: 16),
                        Expanded(child: recover),
                      ],
                    );
            },
          ),
          const SizedBox(height: 24),
          const SecurityNotice(
            title: '私钥从不保存',
            message: '应用只永久保存公钥和 Key ID。每次解密都需要重新输入助记词，关闭进程是最终内存清理边界。',
          ),
        ],
      ),
    );
  }

  Widget _backup(BuildContext context) {
    final words = _mnemonic.split(' ');
    return _frame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _StepHeader(active: 0),
          const SizedBox(height: 30),
          Text(
            '备份你的助记词',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 8),
          Text(
            '请按顺序离线抄写这 12 个单词。离开此流程后，SafeBox 无法再次显示它们。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth < 560 ? 2 : 3;
              final spacing = 12.0;
              final width =
                  (constraints.maxWidth - spacing * (columns - 1)) / columns;
              return Wrap(
                spacing: spacing,
                runSpacing: 12,
                children: <Widget>[
                  for (var index = 0; index < words.length; index++)
                    SizedBox(
                      width: width,
                      child: Semantics(
                        label: '第 ${index + 1} 个助记词 ${words[index]}',
                        child: Container(
                          height: 54,
                          padding: const EdgeInsets.symmetric(horizontal: 13),
                          decoration: BoxDecoration(
                            color: SboxColors.panelSoft,
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(color: SboxColors.border),
                          ),
                          child: Row(
                            children: <Widget>[
                              SizedBox(
                                width: 25,
                                child: Text(
                                  '${index + 1}',
                                  style: const TextStyle(
                                    color: SboxColors.textDim,
                                    fontFamily: 'RobotoMono',
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  words[index],
                                  style: const TextStyle(
                                    color: SboxColors.text,
                                    fontFamily: 'RobotoMono',
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          const SecurityNotice(
            title: '失去助记词就会永久失去文件',
            message: '不要截图、不要保存到网盘或聊天工具。操作系统仍可能允许截图，SafeBox 无法承诺绝对阻止。',
            warning: true,
          ),
          const SizedBox(height: 14),
          CheckboxListTile(
            value: _backedUp,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('我已按顺序离线保存全部 12 个单词'),
            subtitle: const Text('应用不会替我保存，也不能通过系统身份验证找回。'),
            onChanged: (value) => setState(() => _backedUp = value ?? false),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: _createIdentity,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重新生成'),
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: _backedUp
                    ? () => setState(() => _stage = OnboardingStage.confirm)
                    : null,
                iconAlignment: IconAlignment.end,
                icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                label: const Text('下一步：确认备份'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _confirmPage(BuildContext context) {
    return _frame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _StepHeader(active: 1),
          const SizedBox(height: 34),
          Text(
            '确认离线备份',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 8),
          Text(
            '请输入指定位置的单词。不会提供自动填充或复制。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 28),
          Wrap(
            spacing: 14,
            runSpacing: 16,
            children: <Widget>[
              for (final index in _confirmIndexes)
                SizedBox(
                  width: 188,
                  child: TextField(
                    controller: _confirm[index],
                    autocorrect: false,
                    enableSuggestions: false,
                    autofillHints: null,
                    keyboardType: TextInputType.visiblePassword,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: '第 ${index + 1} 个单词',
                    ),
                  ),
                ),
            ],
          ),
          if (_inlineError != null) ...<Widget>[
            const SizedBox(height: 18),
            SecurityNotice(
              title: '确认失败',
              message: _inlineError!,
              warning: true,
            ),
          ],
          const SizedBox(height: 28),
          Row(
            children: <Widget>[
              OutlinedButton(
                onPressed: () =>
                    setState(() => _stage = OnboardingStage.backup),
                child: const Text('返回查看'),
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: _confirmAndDerive,
                icon: const Icon(Icons.verified_user_outlined, size: 18),
                label: const Text('确认并生成公钥'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _recover(BuildContext context) {
    return _frame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _StepHeader(active: 0),
          const SizedBox(height: 34),
          _largeIcon(Icons.key_outlined),
          const SizedBox(height: 18),
          Text(
            '恢复现有身份',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 8),
          Text(
            '输入 12 个 BIP39 英文单词，仅用于本次公钥恢复，不会保存。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _recovery,
            minLines: 3,
            maxLines: 4,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: null,
            keyboardType: TextInputType.visiblePassword,
            decoration: const InputDecoration(
              labelText: '12 词助记词',
              hintText: 'word1 word2 … word12',
              helperText: '单词之间使用空格；输入内容不会进入日志或持久化存储。',
            ),
          ),
          if (_inlineError != null) ...<Widget>[
            const SizedBox(height: 18),
            SecurityNotice(
              title: '无法恢复',
              message: _inlineError!,
              warning: true,
            ),
          ],
          const SizedBox(height: 24),
          Row(
            children: <Widget>[
              OutlinedButton(
                onPressed: () =>
                    setState(() => _stage = OnboardingStage.welcome),
                child: const Text('返回'),
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: _recoverIdentity,
                icon: const Icon(Icons.lock_open_outlined, size: 18),
                label: const Text('临时恢复并核对'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _deriving(BuildContext context) {
    return _frame(
      child: Column(
        children: <Widget>[
          const _StepHeader(active: 2),
          const SizedBox(height: 52),
          const SizedBox(
            width: 70,
            height: 70,
            child: CircularProgressIndicator(strokeWidth: 5),
          ),
          const SizedBox(height: 28),
          Text(
            '正在恢复 RSA-3072 公钥',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 10),
          Text(
            '正在执行确定性素数搜索，这可能需要数秒。界面仍保持响应，请不要退出应用。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge
                ?.copyWith(color: SboxColors.textMuted),
          ),
          const SizedBox(height: 28),
          const SboxProgressCard(
            title: '一次性 Crypto Isolate',
            detail: '派生完成后只返回公钥，私钥引用随 Isolate 终止。',
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _complete(BuildContext context) {
    return _frame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _StepHeader(active: 2),
          const SizedBox(height: 30),
          _largeIcon(Icons.verified_user_outlined),
          const SizedBox(height: 18),
          Text(
            '公开身份已就绪',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 8),
          Text(
            '只保存了公钥和 Key ID。私钥未保存，解密时仍需助记词。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),
          SboxCard(
            color: SboxColors.panelSoft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'RSA Key ID',
                  style: TextStyle(color: SboxColors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 6),
                MonospaceValue(
                  widget.controller.recipientKeyId ?? '',
                  maxLines: 3,
                ),
                const SizedBox(height: 14),
                const Text(
                  'Catalog Signer Key ID',
                  style: TextStyle(color: SboxColors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 6),
                MonospaceValue(
                  widget.controller.signerKeyId ?? '',
                  maxLines: 3,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const SecurityNotice(
            title: '仅保存公钥 · 私钥不落盘',
            message: '现在可以直接打开本地目录，也可以稍后配置公开 GitHub/Gitee 仓库；云端不是必需步骤。',
          ),
          const SizedBox(height: 22),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: <Widget>[
              ElevatedButton.icon(
                onPressed: _openLocalDirectory,
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('打开本地 SBOX 目录'),
              ),
              if (widget.controller.supportsAuthorizedDirectorySelection)
                OutlinedButton.icon(
                  onPressed: _createManagedLocalDirectory,
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('创建本机可写保险箱'),
                ),
              OutlinedButton.icon(
                onPressed: () => widget.onFinished(AppSection.sources),
                icon: const Icon(Icons.cloud_outlined),
                label: const Text('配置云端数据源'),
              ),
              TextButton(
                onPressed: () => widget.onFinished(AppSection.library),
                child: const Text('暂不配置'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _largeIcon(IconData icon) {
    return Container(
      width: 70,
      height: 70,
      decoration: BoxDecoration(
        color: SboxColors.accent.withValues(alpha: 0.1),
        shape: BoxShape.circle,
        border: Border.all(color: SboxColors.accent.withValues(alpha: 0.28)),
      ),
      child: Icon(icon, color: SboxColors.accent, size: 34),
    );
  }
}

class _StepHeader extends StatelessWidget {
  const _StepHeader({required this.active});

  final int active;

  @override
  Widget build(BuildContext context) {
    const labels = <String>['备份助记词', '确认备份', '生成公钥'];
    return Row(
      children: <Widget>[
        for (var index = 0; index < labels.length; index++) ...<Widget>[
          Expanded(
            child: Column(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Container(
                        height: 1,
                        color: index == 0
                            ? Colors.transparent
                            : (index <= active
                                  ? SboxColors.accent
                                  : SboxColors.border),
                      ),
                    ),
                    Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: index <= active
                            ? SboxColors.accent
                            : SboxColors.panelSoft,
                        border: Border.all(
                          color: index <= active
                              ? SboxColors.accent
                              : SboxColors.border,
                        ),
                      ),
                      child: index < active
                          ? const Icon(
                              Icons.check,
                              size: 16,
                              color: Color(0xFF03211D),
                            )
                          : Text(
                              '${index + 1}',
                              style: TextStyle(
                                color: index <= active
                                    ? const Color(0xFF03211D)
                                    : SboxColors.textMuted,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                    Expanded(
                      child: Container(
                        height: 1,
                        color: index == labels.length - 1
                            ? Colors.transparent
                            : (index < active
                                  ? SboxColors.accent
                                  : SboxColors.border),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                Text(
                  labels[index],
                  style: TextStyle(
                    color: index <= active
                        ? SboxColors.text
                        : SboxColors.textDim,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _IdentityChoice extends StatelessWidget {
  const _IdentityChoice({
    required this.icon,
    required this.title,
    required this.description,
    required this.action,
    required this.onPressed,
    this.primary = false,
  });

  final IconData icon;
  final String title;
  final String description;
  final String action;
  final VoidCallback onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return SboxCard(
      color: SboxColors.panelSoft,
      borderColor: primary
          ? SboxColors.accent.withValues(alpha: 0.4)
          : SboxColors.border,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            icon,
            color: primary ? SboxColors.accent : SboxColors.textMuted,
            size: 28,
          ),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 7),
          Text(description, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: primary
                ? ElevatedButton(onPressed: onPressed, child: Text(action))
                : OutlinedButton(onPressed: onPressed, child: Text(action)),
          ),
        ],
      ),
    );
  }
}
