import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../app/sbox_feedback.dart';
import '../../app/sbox_theme.dart';
import '../../app/sbox_widgets.dart';

final class MnemonicOnboarding extends StatefulWidget {
  const MnemonicOnboarding({
    super.key,
    required this.controller,
    required this.onFinished,
    this.onOpenSettings,
  });

  final AppController controller;
  final VoidCallback onFinished;
  final VoidCallback? onOpenSettings;

  @override
  State<MnemonicOnboarding> createState() => _MnemonicOnboardingState();
}

final class _MnemonicOnboardingState extends State<MnemonicOnboarding> {
  final _restoreControllers = List<TextEditingController>.generate(
    12,
    (_) => TextEditingController(),
  );
  List<String>? _mnemonic;
  int _step = 1;
  bool _restoring = false;
  bool _busy = false;

  @override
  void dispose() {
    for (final controller in _restoreControllers) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final mobile = constraints.maxWidth < 760;
            return DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    context.sboxColors.backgroundDeep,
                    context.sboxColors.background,
                  ],
                ),
              ),
              child: Column(
                children: <Widget>[
                  SboxTopBar(mobile: mobile, firstUse: true),
                  Expanded(child: _buildContent(context, mobile)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, bool mobile) {
    final title = switch (_step) {
      1 when _mnemonic != null => '保存你的恢复词',
      1 when _restoring => '恢复已有身份',
      2 => '连接云端备份',
      3 => '设置完成',
      _ => '欢迎使用 SafeBox',
    };
    final subtitle = switch (_step) {
      1 when _mnemonic != null => '请按顺序保存这 12 个词，完成后即可继续设置',
      1 when _restoring => '输入你的 12 个恢复词，找回安全身份',
      2 => '身份设置完成后，再连接你的云端备份',
      3 => '你的文件现在已经准备好受到保护',
      _ => '完成一次设置，之后只需拖入文件',
    };
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        mobile ? 24 : 28,
        mobile ? 34 : 36,
        mobile ? 24 : 28,
        mobile ? 24 : 30,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Column(
            children: <Widget>[
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.displaySmall
                    ?.copyWith(fontSize: mobile ? 32 : 38),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: context.sboxColors.textMuted,
                  fontSize: mobile ? 15 : 16,
                ),
              ),
              const SizedBox(height: 24),
              _StepProgress(step: _step, mobile: mobile),
              const SizedBox(height: 28),
              if (_step == 1 && _mnemonic == null && !_restoring)
                _buildIdentityChoice(context, mobile)
              else if (_step == 1 && _mnemonic != null)
                _buildRecoveryPhrase(context, mobile)
              else if (_step == 1)
                _buildRestoreIdentity(context, mobile)
              else if (_step == 2)
                _buildCloudStep(context, mobile)
              else
                _buildCompleteStep(context, mobile),
              const SizedBox(height: 24),
              _buildBottomHint(context, mobile),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIdentityChoice(BuildContext context, bool mobile) {
    return Column(
      children: <Widget>[
        SboxCard(
          padding: EdgeInsets.all(mobile ? 24 : 30),
          child: mobile
              ? Column(
                  children: <Widget>[
                    const _ShieldArt(size: 190),
                    const SizedBox(height: 12),
                    _identityChoiceActions(context, mobile),
                  ],
                )
              : Row(
                  children: <Widget>[
                    const Expanded(child: _ShieldArt(size: 250)),
                    const SizedBox(width: 36),
                    Expanded(child: _identityChoiceActions(context, mobile)),
                  ],
                ),
        ),
        const SizedBox(height: 14),
        _buildPendingCloudCard(context, mobile),
        const SizedBox(height: 18),
        _continueButton(
          context,
          mobile: mobile,
          label: '继续设置',
          onPressed: _busy
              ? null
              : widget.controller.hasIdentity
              ? () => setState(() => _step = 2)
              : () => _showFeedback('请先创建或恢复安全身份。', error: true),
        ),
      ],
    );
  }

  Widget _identityChoiceActions(BuildContext context, bool mobile) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('创建安全身份', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          '用于保护你的文件',
          style: Theme.of(context).textTheme.bodyLarge
              ?.copyWith(color: context.sboxColors.textMuted),
        ),
        const SizedBox(height: 22),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _busy ? null : _create,
            child: const Text('创建安全身份'),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _busy ? null : () => setState(() => _restoring = true),
            child: const Text('恢复已有身份'),
          ),
        ),
        const SizedBox(height: 15),
        const SboxLockHint(text: '恢复信息只保存在你手中'),
      ],
    );
  }

  Widget _buildPendingCloudCard(BuildContext context, bool mobile) {
    return SboxCard(
      padding: EdgeInsets.symmetric(
        horizontal: mobile ? 20 : 28,
        vertical: mobile ? 20 : 22,
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.cloud_upload_outlined,
            color: context.sboxColors.accent,
            size: 52,
          ),
          SizedBox(width: mobile ? 18 : 25),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('云端备份', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '完成身份设置后再连接云端',
                  style: Theme.of(context).textTheme.bodyLarge
                      ?.copyWith(color: context.sboxColors.textMuted),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              StatusPill(
                label: '待设置',
                icon: Icons.more_horiz,
                tone: context.sboxColors.textMuted,
                compact: true,
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: widget.controller.hasIdentity
                    ? (widget.onOpenSettings ?? widget.onFinished)
                    : () => _showFeedback('请先创建或恢复安全身份。', error: true),
                child: const Text('稍后设置  ›'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecoveryPhrase(BuildContext context, bool mobile) {
    final words = _mnemonic ?? const <String>[];
    return SboxCard(
      padding: EdgeInsets.fromLTRB(
        mobile ? 16 : 30,
        mobile ? 24 : 22,
        mobile ? 16 : 30,
        mobile ? 18 : 20,
      ),
      child: Column(
        children: <Widget>[
          Text('你的 12 个恢复词', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 5),
          const Text('这些词只显示一次，请抄写并妥善保管'),
          const SizedBox(height: 18),
          _WordGrid(words: words, inputs: false, mobile: mobile),
          const SizedBox(height: 14),
          const SecurityNotice(
            title: '不要截图或发送给任何人',
            message: '恢复词只保存在你手中。',
            compact: true,
            icon: Icons.shield_outlined,
          ),
          const SizedBox(height: 14),
          if (mobile)
            Column(
              children: <Widget>[
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _copyMnemonic,
                    child: const Text('复制恢复词'),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _busy ? null : () => setState(() => _step = 2),
                    child: const Text('我已妥善保存，继续'),
                  ),
                ),
              ],
            )
          else
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: _copyMnemonic,
                    child: const Text('复制恢复词'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _busy ? null : () => setState(() => _step = 2),
                    child: const Text('我已妥善保存，继续'),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 10),
          const Text('恢复词只显示一次，完成后请离线保管'),
        ],
      ),
    );
  }

  Widget _buildRestoreIdentity(BuildContext context, bool mobile) {
    return SboxCard(
      padding: EdgeInsets.fromLTRB(
        mobile ? 16 : 30,
        mobile ? 24 : 22,
        mobile ? 16 : 30,
        mobile ? 18 : 20,
      ),
      child: Column(
        children: <Widget>[
          Text('输入 12 个恢复词', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 5),
          const Text('按顺序输入恢复词，恢复词只保存在你手中'),
          const SizedBox(height: 18),
          _WordGrid(
            words: const <String>[],
            inputs: true,
            mobile: mobile,
            controllers: _restoreControllers,
          ),
          const SizedBox(height: 14),
          if (mobile)
            Column(
              children: <Widget>[
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _busy ? null : _pasteRecoveryPhrase,
                    child: const Text('粘贴恢复词'),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _busy ? null : _restore,
                    child: Text(_busy ? '正在恢复…' : '恢复身份'),
                  ),
                ),
              ],
            )
          else
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : _pasteRecoveryPhrase,
                    child: const Text('粘贴恢复词'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _busy ? null : _restore,
                    child: Text(_busy ? '正在恢复…' : '恢复身份'),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 10),
          const SboxLockHint(text: '恢复词仅用于本地恢复，不会上传'),
        ],
      ),
    );
  }

  Widget _buildCloudStep(BuildContext context, bool mobile) {
    return Column(
      children: <Widget>[
        SboxCard(
          padding: EdgeInsets.all(mobile ? 24 : 30),
          child: Column(
            children: <Widget>[
              Icon(
                Icons.cloud_done_outlined,
                color: context.sboxColors.accent,
                size: 78,
              ),
              const SizedBox(height: 14),
              Text('云端备份', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                '你的安全身份已经准备好。现在可以连接 GitHub 和 Gitee，保存文件的云端副本。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(color: context.sboxColors.textMuted),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: widget.onOpenSettings ?? widget.onFinished,
                  child: const Text('配置云端备份'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => setState(() => _step = 3),
                  child: const Text('稍后设置'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        _continueButton(
          context,
          mobile: mobile,
          label: '继续设置',
          onPressed: () => setState(() => _step = 3),
        ),
      ],
    );
  }

  Widget _buildCompleteStep(BuildContext context, bool mobile) {
    return Column(
      children: <Widget>[
        SboxCard(
          padding: EdgeInsets.all(mobile ? 28 : 40),
          child: Column(
            children: <Widget>[
              const SboxShieldMark(size: 104, filled: true),
              const SizedBox(height: 18),
              Text('一切准备就绪', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              const Text('之后只需拖入文件，SafeBox 会自动保护它们。'),
              const SizedBox(height: 24),
              SizedBox(
                width: mobile ? double.infinity : 280,
                child: ElevatedButton(
                  onPressed: widget.onFinished,
                  child: const Text('开始使用 SafeBox'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _continueButton(
    BuildContext context, {
    required bool mobile,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return Align(
      alignment: mobile ? Alignment.center : Alignment.centerRight,
      child: SizedBox(
        width: mobile ? double.infinity : 220,
        child: ElevatedButton.icon(
          onPressed: onPressed,
          icon: const Icon(Icons.arrow_forward_rounded),
          label: Text(label),
        ),
      ),
    );
  }

  Widget _buildBottomHint(BuildContext context, bool mobile) {
    return Align(
      alignment: mobile ? Alignment.centerLeft : Alignment.centerLeft,
      child: const SboxLockHint(text: '设置完成后即可开始上传文件'),
    );
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final mnemonic = await widget.controller.createIdentity();
      final words = mnemonic.trim().split(RegExp(r'\s+'));
      if (!mounted) return;
      setState(() {
        _mnemonic = words.length == 12 ? words : List<String>.filled(12, '—');
        _busy = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        _showFeedback('安全身份创建失败，请重试。', error: true);
      }
    }
  }

  Future<void> _restore() async {
    final words = _restoreControllers.map(
      (controller) => controller.text.trim(),
    );
    if (words.any((word) => word.isEmpty)) {
      _showFeedback('请按顺序填写全部 12 个恢复词。', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.controller.restoreIdentity(words.join(' '));
      if (!mounted) return;
      setState(() {
        _busy = false;
        _step = 2;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        _showFeedback('恢复词不正确，请检查后重试。', error: true);
      }
    }
  }

  Future<void> _copyMnemonic() async {
    final words = _mnemonic;
    if (words == null) return;
    await Clipboard.setData(ClipboardData(text: words.join(' ')));
    if (mounted) _showFeedback('恢复词已复制，请立即离线保存。');
  }

  Future<void> _pasteRecoveryPhrase() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    final words = text.trim().split(RegExp(r'\s+'));
    if (words.length != 12) {
      _showFeedback('剪贴板中没有找到 12 个恢复词。', error: true);
      return;
    }
    for (var index = 0; index < words.length; index++) {
      _restoreControllers[index].text = words[index];
    }
    if (mounted) setState(() {});
  }

  void _showFeedback(String message, {bool error = false}) {
    if (!mounted) return;
    showSboxFeedback(context, message, error: error);
  }
}

final class _StepProgress extends StatelessWidget {
  const _StepProgress({required this.step, required this.mobile});

  final int step;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    const labels = <String>['安全身份', '云端备份', '完成'];
    return SizedBox(
      width: mobile ? double.infinity : 600,
      child: Row(
        children: <Widget>[
          for (var index = 0; index < labels.length; index++) ...<Widget>[
            Expanded(
              child: Column(
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      if (index > 0)
                        Expanded(
                          child: Container(
                            height: 1.5,
                            color: index < step
                                ? context.sboxColors.accent
                                : context.sboxColors.border,
                          ),
                        ),
                      Container(
                        width: mobile ? 42 : 40,
                        height: mobile ? 42 : 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: index + 1 <= step
                              ? context.sboxColors.accent
                              : Colors.transparent,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: index + 1 <= step
                                ? context.sboxColors.accent
                                : context.sboxColors.border,
                            width: 1.4,
                          ),
                        ),
                        child: Text(
                          '${index + 1}',
                          style: TextStyle(
                            color: index + 1 <= step
                                ? const Color(0xFF03211D)
                                : context.sboxColors.textMuted,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (index < labels.length - 1)
                        Expanded(
                          child: Container(
                            height: 1.5,
                            color: index + 1 < step
                                ? context.sboxColors.accent
                                : context.sboxColors.border,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Text(
                    labels[index],
                    style: TextStyle(
                      color: index + 1 == step
                          ? context.sboxColors.accent
                          : context.sboxColors.textMuted,
                      fontSize: mobile ? 13 : 14,
                      fontWeight: index + 1 == step
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

final class _WordGrid extends StatelessWidget {
  const _WordGrid({
    required this.words,
    required this.inputs,
    required this.mobile,
    this.controllers,
  });

  final List<String> words;
  final bool inputs;
  final bool mobile;
  final List<TextEditingController>? controllers;

  @override
  Widget build(BuildContext context) {
    final columns = mobile ? 2 : 3;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 12,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: mobile ? 8 : 12,
        mainAxisSpacing: 8,
        childAspectRatio: mobile ? 2.4 : 3.7,
      ),
      itemBuilder: (context, index) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: context.sboxColors.panelRaised.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: context.sboxColors.border),
          ),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: index >= 9 ? 27 : 18,
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    color: context.sboxColors.accent,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (inputs)
                Expanded(
                  child: TextField(
                    controller: controllers![index],
                    decoration: InputDecoration(
                      hintText: '第 ${index + 1} 个词',
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      contentPadding: EdgeInsets.zero,
                      hintStyle: TextStyle(color: context.sboxColors.textMuted),
                    ),
                    style: TextStyle(color: context.sboxColors.text),
                  ),
                )
              else
                Expanded(
                  child: Text(
                    index < words.length ? words[index] : '—',
                    style: TextStyle(
                      color: context.sboxColors.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

final class _ShieldArt extends StatelessWidget {
  const _ShieldArt({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Container(
            width: size * 0.86,
            height: size * 0.32,
            decoration: BoxDecoration(
              border: Border.all(
                color: context.sboxColors.accent.withValues(alpha: 0.3),
              ),
              borderRadius: BorderRadius.all(
                Radius.elliptical(size, size * 0.3),
              ),
            ),
          ),
          Container(
            width: size * 0.7,
            height: size * 0.2,
            decoration: BoxDecoration(
              border: Border.all(
                color: context.sboxColors.accent.withValues(alpha: 0.18),
              ),
              borderRadius: BorderRadius.all(
                Radius.elliptical(size, size * 0.3),
              ),
            ),
          ),
          const SboxShieldMark(size: 136, filled: true),
          Positioned(
            bottom: size * 0.12,
            child: Container(
              width: size * 0.26,
              height: 5,
              decoration: BoxDecoration(
                color: context.sboxColors.accent,
                borderRadius: BorderRadius.circular(999),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: context.sboxColors.accent.withValues(alpha: 0.8),
                    blurRadius: 18,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
