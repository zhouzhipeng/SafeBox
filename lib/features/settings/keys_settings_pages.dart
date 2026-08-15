import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/app_controller.dart';
import '../../app/sbox_dialogs.dart';
import '../../app/sbox_theme.dart';
import '../../app/sbox_widgets.dart';

class KeysPage extends StatelessWidget {
  const KeysPage({
    super.key,
    required this.controller,
    required this.onCreateIdentity,
  });

  final AppController controller;
  final VoidCallback onCreateIdentity;

  Future<void> _verify(BuildContext context) async {
    final mnemonic = await showMnemonicPrompt(
      context,
      title: '验证助记词恢复结果',
      actionLabel: '恢复并核对',
    );
    if (mnemonic == null) return;
    try {
      await controller.verifyMnemonic(mnemonic);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final history = controller.identityHistory;
    return ListView(
      padding: const EdgeInsets.fromLTRB(34, 34, 34, 30),
      children: <Widget>[
        const PageHeading(
          title: '密钥',
          subtitle: '永久保存公开身份；私钥只由本次输入的 12 词助记词临时恢复',
        ),
        const SizedBox(height: 22),
        SboxCard(
          color: const Color(0xFF0E2421),
          borderColor: SboxColors.accent.withValues(alpha: 0.3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      color: SboxColors.accent.withValues(alpha: 0.11),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: const Icon(
                      Icons.verified_user_outlined,
                      color: SboxColors.accent,
                      size: 31,
                    ),
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '当前公开身份',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 5),
                        Text(
                          controller.shortFingerprint,
                          style: const TextStyle(
                            color: SboxColors.accent,
                            fontFamily: 'RobotoMono',
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const StatusPill(
                    label: '仅保存公钥 · 私钥不落盘',
                    icon: Icons.shield_outlined,
                    tone: SboxColors.success,
                  ),
                ],
              ),
              const SizedBox(height: 22),
              const Text(
                'RSA-3072 Key ID',
                style: TextStyle(color: SboxColors.textDim, fontSize: 12),
              ),
              const SizedBox(height: 6),
              MonospaceValue(controller.recipientKeyId ?? '', maxLines: 3),
              const SizedBox(height: 16),
              const Text(
                'Catalog Ed25519 Signer Key ID',
                style: TextStyle(color: SboxColors.textDim, fontSize: 12),
              ),
              const SizedBox(height: 6),
              MonospaceValue(controller.signerKeyId ?? '', maxLines: 3),
              const SizedBox(height: 20),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: <Widget>[
                  ElevatedButton.icon(
                    onPressed: controller.isBusy
                        ? null
                        : () async {
                            try {
                              await controller.exportPublicIdentity();
                            } catch (_) {}
                          },
                    icon: const Icon(Icons.ios_share_rounded),
                    label: const Text('导出公钥'),
                  ),
                  OutlinedButton.icon(
                    onPressed: controller.isBusy
                        ? null
                        : () => _verify(context),
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('验证助记词恢复结果'),
                  ),
                  OutlinedButton.icon(
                    onPressed: controller.isBusy ? null : onCreateIdentity,
                    icon: const Icon(Icons.add_moderator_outlined),
                    label: const Text('新建身份'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const SecurityNotice(
          title: '没有私钥导入、导出或“保持解锁”',
          message: '每次 OAEP 解封与 Catalog 签名都使用新的一次性 Crypto Isolate。完整退出并重启 Release 应用进程是 Dart Heap 的最终清理边界。',
        ),
        const SizedBox(height: 16),
        SboxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SectionTitle(
                title: '历史公开身份',
                subtitle: '最多保留 20 个公钥记录；不含任何可逆私钥材料',
                trailing: StatusPill(
                  label: '${history.length} 个',
                  icon: Icons.history_rounded,
                  tone: SboxColors.info,
                ),
              ),
              const SizedBox(height: 14),
              if (history.isEmpty)
                Text('没有历史记录', style: Theme.of(context).textTheme.bodyMedium)
              else
                for (final item in history)
                  Container(
                    margin: const EdgeInsets.only(bottom: 9),
                    padding: const EdgeInsets.all(13),
                    decoration: BoxDecoration(
                      color: SboxColors.panelSoft,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: SboxColors.borderSoft),
                    ),
                    child: Row(
                      children: <Widget>[
                        const Icon(
                          Icons.key_outlined,
                          color: SboxColors.accent,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: MonospaceValue(
                            _short(
                              item.record.toJson()['recipient_key_id']!
                                  as String,
                            ),
                          ),
                        ),
                        Text(
                          item.createdAt.millisecondsSinceEpoch == 0
                              ? '迁移记录'
                              : DateFormat('yyyy-MM-dd HH:mm')
                                    .format(item.createdAt.toLocal()),
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          controller.recipientKeyId ==
                                  item.record.toJson()['recipient_key_id']
                              ? '当前'
                              : '历史',
                          style: const TextStyle(
                            color: SboxColors.accent,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        ),
        if (controller.isBusy) ...<Widget>[
          const SizedBox(height: 16),
          SboxProgressCard(
            title: '正在一次性恢复公开身份',
            detail: '确定性 RSA-3072 素数搜索可能耗时数秒；完成后只返回公钥。',
            onCancel: controller.cancelSensitiveWork,
          ),
        ],
      ],
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.controller,
    required this.onOpenSources,
  });

  final AppController controller;
  final VoidCallback onOpenSources;

  Future<void> _clear(BuildContext context) async {
    final stats = controller.temporaryStats;
    final confirmed = await showDestructiveConfirmation(
      context,
      title: '全部删除临时解密文件？',
      message:
          '将删除 ${stats?.fileCount ?? 0} 个受管理临时明文（${_formatBytes(stats?.totalBytes ?? 0)}）。只删除临时解密明文，不删除本地 .sbox 密文原件，也不删除已导出的文件。普通删除不等于安全擦除。',
      actionLabel: '全部删除临时明文',
    );
    if (confirmed) {
      try {
        await controller.clearTemporaryPlaintext();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats = controller.temporaryStats;
    return ListView(
      padding: const EdgeInsets.fromLTRB(34, 34, 34, 30),
      children: <Widget>[
        const PageHeading(title: '设置', subtitle: '存储管理、生命周期清理、无障碍与安全边界'),
        const SizedBox(height: 22),
        SboxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SectionTitle(
                title: '存储管理',
                subtitle: '永久密文与临时明文采用互不重叠的目录根',
              ),
              const SizedBox(height: 16),
              _StorageTile(
                icon: Icons.inventory_2_outlined,
                title: '本地 SBOX 密文',
                subtitle:
                    '${controller.sources.length} 个数据源目录 · 永久用户数据 · 缓存清理不触碰',
                action: OutlinedButton(
                  onPressed: onOpenSources,
                  child: const Text('进入数据源管理'),
                ),
              ),
              if (controller.temporaryCleanupFailures.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                SecurityNotice(
                  title:
                      '仍有 ${controller.temporaryCleanupFailures.length} 个路径删除失败',
                  message:
                      '${controller.temporaryCleanupFailures.take(20).join('\n')}'
                      '${controller.temporaryCleanupFailures.length > 20 ? '\n…其余路径已省略显示' : ''}',
                  warning: true,
                ),
              ],
              const SizedBox(height: 12),
              _StorageTile(
                icon: Icons.folder_special_outlined,
                title: '临时解密文件',
                subtitle:
                    '${stats?.fileCount ?? 0} 个明文 · ${_formatBytes(stats?.totalBytes ?? 0)}'
                    '${stats?.earliest == null ? '' : '\n最早 ${_formatDate(stats!.earliest!)} · 最近 ${_formatDate(stats.latest!)}'}'
                    '\n${controller.temporaryRoot ?? '正在准备受管理目录'}',
                action: OutlinedButton.icon(
                  onPressed: stats == null || stats.fileCount == 0
                      ? null
                      : () => _clear(context),
                  icon: const Icon(
                    Icons.delete_sweep_outlined,
                    color: SboxColors.danger,
                  ),
                  label: const Text(
                    '全部删除',
                    style: TextStyle(color: SboxColors.danger),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile.adaptive(
                value: controller.clearPlaintextOnExit,
                onChanged: controller.setClearPlaintextOnExit,
                contentPadding: EdgeInsets.zero,
                title: const Text('退出应用时自动清理临时明文'),
                subtitle: const Text('只清理带管理标记的临时目录；不删除 SBOX 原件或导出文件。'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SboxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SectionTitle(title: '安全与隐私', subtitle: 'SBOX v1 固定发布基线'),
              const SizedBox(height: 15),
              const _SettingLine(
                icon: Icons.dark_mode_outlined,
                title: '深色主题',
                subtitle: '固定启用；配色、间距与状态严格遵照规范效果图',
                state: '已启用',
              ),
              const _SettingLine(
                icon: Icons.visibility_off_outlined,
                title: '后台隐私遮罩',
                subtitle: '进入任务切换器前隐藏 Catalog 标题、文件名与输入内容',
                state: '已启用',
              ),
              const _SettingLine(
                icon: Icons.analytics_outlined,
                title: '敏感遥测与日志',
                subtitle: '助记词、DEK、令牌、路径和解密 Catalog 不会进入遥测',
                state: '关闭',
              ),
              const _SettingLine(
                icon: Icons.accessibility_new_rounded,
                title: '无障碍',
                subtitle: '主要目标 ≥44×44、键盘焦点可见、状态同时使用文字与图标',
                state: '支持 200%',
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SecurityNotice(
          title: kIsWeb ? 'Web 实验环境' : '原生一级平台安全边界',
          message: kIsWeb
              ? '浏览器版不具备与原生一次性 Isolate 和文件系统相同的私钥生命周期保证，不应在未知第三方网页输入主助记词。'
              : '应用进入后台会立即终止敏感任务并显示无敏感内容的遮罩。Hot Reload、Hot Restart 或仅最小化窗口不等于进程重启。',
          warning: kIsWeb,
        ),
        if (controller.isBusy) ...<Widget>[
          const SizedBox(height: 16),
          SboxProgressCard(
            title: '正在清理临时明文',
            detail: '删除遍历不跟随符号链接，并会重新检查管理标记与路径边界。',
          ),
        ],
      ],
    );
  }
}

class MorePage extends StatelessWidget {
  const MorePage({super.key, required this.onNavigate});
  final ValueChanged<AppSection> onNavigate;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 26, 20, 30),
    children: <Widget>[
      const PageHeading(title: '更多', subtitle: '数据源、公开密钥与本地存储设置'),
      const SizedBox(height: 22),
      for (final item in const <(AppSection, IconData, String, String)>[
        (
          AppSection.sources,
          Icons.storage_outlined,
          '数据源',
          '本地目录、GitHub、Gitee 与 HTTPS',
        ),
        (AppSection.keys, Icons.key_outlined, '密钥', '公钥、Key ID 与助记词恢复核对'),
        (AppSection.settings, Icons.settings_outlined, '设置', '临时明文清理与安全边界'),
      ])
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: InkWell(
            onTap: () => onNavigate(item.$1),
            borderRadius: BorderRadius.circular(13),
            child: SboxCard(
              child: Row(
                children: <Widget>[
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: SboxColors.accent.withValues(alpha: 0.09),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(item.$2, color: SboxColors.accent),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          item.$3,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.$4,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: SboxColors.textMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}

class _StorageTile extends StatelessWidget {
  const _StorageTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.action,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget action;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: SboxColors.panelSoft,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: SboxColors.borderSoft),
    ),
    child: Row(
      children: <Widget>[
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: SboxColors.accent.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icon, color: SboxColors.accent),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
        const SizedBox(width: 12),
        action,
      ],
    ),
  );
}

class _SettingLine extends StatelessWidget {
  const _SettingLine({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.state,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final String state;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      children: <Widget>[
        Icon(icon, color: SboxColors.textMuted, size: 22),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 3),
              Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
        StatusPill(
          label: state,
          icon: Icons.check_circle_outline,
          tone: SboxColors.success,
        ),
      ],
    ),
  );
}

String _short(String value) =>
    '${value.substring(0, 12)}…${value.substring(value.length - 12)}';
String _formatDate(DateTime value) =>
    DateFormat('yyyy-MM-dd HH:mm').format(value.toLocal());
String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MiB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '$bytes B';
}
