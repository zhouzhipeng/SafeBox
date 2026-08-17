import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../app/app_controller.dart';
import '../../app/sbox_dialogs.dart';
import '../../app/sbox_theme.dart';
import '../../app/sbox_widgets.dart';
import '../../sbox/engine/crypto_task_runner.dart';

class DecryptPage extends StatefulWidget {
  const DecryptPage({super.key, required this.controller, this.catalogEntryId});

  final AppController controller;
  final String? catalogEntryId;

  @override
  State<DecryptPage> createState() => _DecryptPageState();
}

class _DecryptPageState extends State<DecryptPage> {
  bool _dragging = false;

  CatalogEntryViewData? get _entry {
    final id = widget.catalogEntryId;
    if (id == null) return null;
    for (final entry
        in widget.controller.catalog?.entries ??
            const <CatalogEntryViewData>[]) {
      if (entry.entryId == id) return entry;
    }
    return null;
  }

  Future<void> _pickSbox() async {
    const group = XTypeGroup(
      label: 'SBOX encrypted file',
      extensions: <String>['sbox'],
    );
    final file = await openFile(acceptedTypeGroups: const <XTypeGroup>[group]);
    if (file == null) return;
    try {
      await widget.controller.inspectStandalone(file.path);
    } catch (_) {}
  }

  Future<void> _openDirectory() async {
    if (widget.controller.supportsAuthorizedDirectorySelection) {
      try {
        await widget.controller.chooseAndAddAuthorizedLocalSource();
      } catch (_) {}
      return;
    }
    final path = await widget.controller.chooseLocalCipherDirectory(
      confirmButtonText: '打开此 SBOX 目录',
    );
    if (path == null) return;
    try {
      final probe = await widget.controller.inspectLocalDirectory(path);
      final empty =
          probe.catalogHeader == null &&
          await Directory(path).list(followLinks: false).isEmpty;
      await widget.controller.addLocalSource(
        displayName: '本地 SBOX 目录',
        path: path,
        requestWrite: true,
        initializeEmptyAsCanonical: empty,
      );
    } catch (_) {}
  }

  Future<void> _decrypt() async {
    final mnemonic = await showMnemonicPrompt(
      context,
      title: '验证身份并解密',
      actionLabel: '验证并解密',
    );
    if (mnemonic == null || !mounted) return;
    try {
      if (_entry != null) {
        await widget.controller.decryptEntry(_entry!.entryId, mnemonic);
      } else {
        await widget.controller.decryptStandalone(mnemonic);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final entry = _entry;
    final inspection = controller.inspection;
    final catalogVerified =
        inspection != null &&
        controller.lastUnlockedCatalogPath == inspection.path;
    final hasInput = entry != null || inspection != null;
    final parts = entry?.partCount ?? (inspection == null ? 0 : 1);
    return ListView(
      padding: const EdgeInsets.fromLTRB(34, 34, 34, 30),
      children: <Widget>[
        const PageHeading(
          title: '下载与解密',
          subtitle: '先永久同步完整密文，再验证 Catalog、每个 SBOX 与整体摘要，最后发布临时明文',
        ),
        const SizedBox(height: 22),
        _StepStrip(
          active: catalogVerified || controller.lastDecryptedPath != null
              ? 3
              : controller.isBusy
              ? 2
              : hasInput
              ? 1
              : 0,
        ),
        const SizedBox(height: 20),
        if (entry != null)
          _EntrySourceCard(controller: controller, entry: entry)
        else
          _standalonePicker(context),
        if (hasInput) ...<Widget>[
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 760;
              final details = _detailsCard(context, entry, inspection);
              final local = _localStatusCard(context, entry, parts);
              return narrow
                  ? Column(
                      children: <Widget>[
                        details,
                        const SizedBox(height: 16),
                        local,
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(child: details),
                        const SizedBox(width: 16),
                        Expanded(child: local),
                      ],
                    );
            },
          ),
          const SizedBox(height: 16),
          SecurityNotice(
            title: catalogVerified ? 'Catalog 验证结果' : '临时解密目录',
            message: catalogVerified
                ? 'Catalog 已在解密后完成目录结构与身份认证；它不会作为普通临时明文发布。请前往“资料库”查看已验证条目。'
                : '认证通过的明文会保留到你导出、单独删除或执行“全部删除”。普通删除不等于物理安全擦除；本地 .sbox 原件始终保留。',
            icon: catalogVerified
                ? Icons.fact_check_outlined
                : Icons.folder_special_outlined,
          ),
          if (controller.isBusy) ...<Widget>[
            const SizedBox(height: 16),
            SboxProgressCard(
              title: _decryptOperation(controller.operation),
              detail: controller.syncProgress == null
                  ? (parts > 1
                        ? '验证全部 $parts 个完整分片 → 按索引重组 → 校验整体 SHA-256'
                        : 'OAEP 解封 → Metadata/Data/Final GCM 认证')
                  : '本地密文 ${controller.syncProgress!.completed}/${controller.syncProgress!.total}；下载成功不等于解密成功',
              value:
                  controller.syncProgress == null ||
                      controller.syncProgress!.total == 0
                  ? null
                  : controller.syncProgress!.completed /
                        controller.syncProgress!.total,
              onCancel: controller.operation == AppOperation.exporting
                  ? null
                  : controller.cancelSensitiveWork,
            ),
          ],
          const SizedBox(height: 18),
          if (controller.lastDecryptedPath == null && !catalogVerified)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed:
                    controller.isBusy || (inspection?.keyMatches == false)
                    ? null
                    : _decrypt,
                icon: const Icon(Icons.lock_open_outlined),
                label: Text(
                  _isCatalogInspection(inspection)
                      ? '验证并打开 Catalog'
                      : '验证并解密',
                ),
              ),
            )
          else if (catalogVerified)
            _verifiedCatalogResult(context)
          else
            _verifiedResult(context),
        ],
      ],
    );
  }

  Widget _standalonePicker(BuildContext context) {
    final inspection = widget.controller.inspection;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) async {
        setState(() => _dragging = false);
        if (detail.files.isNotEmpty) {
          try {
            await widget.controller.inspectStandalone(detail.files.first.path);
          } catch (_) {}
        }
      },
      child: SboxCard(
        color: _dragging ? const Color(0xFF102925) : SboxColors.panel,
        borderColor: _dragging ? SboxColors.accent : SboxColors.borderSoft,
        child: Column(
          children: <Widget>[
            Icon(
              inspection == null
                  ? Icons.lock_outline_rounded
                  : Icons.verified_outlined,
              size: 38,
              color: SboxColors.accent,
            ),
            const SizedBox(height: 12),
            Text(
              inspection == null
                  ? '拖放一个独立 .sbox 文件'
                  : inspection.path.split(Platform.pathSeparator).last,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            Text(
              inspection == null
                  ? 'Metadata 认证前不会显示原始文件名'
                  : '公共头部已解析 · ${_formatBytes(inspection.ciphertextBytes)}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: <Widget>[
                ElevatedButton.icon(
                  onPressed: _pickSbox,
                  icon: const Icon(Icons.insert_drive_file_outlined),
                  label: Text(inspection == null ? '选择 SBOX 文件' : '更换文件'),
                ),
                OutlinedButton.icon(
                  onPressed: _openDirectory,
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('打开本地 SBOX 目录'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailsCard(
    BuildContext context,
    CatalogEntryViewData? entry,
    StandaloneSboxInspection? inspection,
  ) {
    return SboxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SectionTitle(
            title: entry == null ? 'SBOX 公共头部' : '已验证 Catalog 项目',
            subtitle: entry == null ? '这些字段不包含加密 Metadata' : '标题与文件名来自已认证目录',
          ),
          const SizedBox(height: 16),
          if (entry != null) ...<Widget>[
            _InfoRow(label: '标题', value: entry.title),
            _InfoRow(label: '原始文件名', value: entry.originalName, mono: true),
            _InfoRow(
              label: '逻辑大小',
              value: _formatBytes(int.parse(entry.plaintextSize)),
            ),
            _InfoRow(
              label: '分片',
              value: entry.partCount == 1
                  ? 'single · 1 个完整 SBOX'
                  : 'multipart · ${entry.partCount} 个完整 SBOX',
            ),
          ] else if (inspection != null) ...<Widget>[
            _InfoRow(
              label: '版本',
              value: 'SBOX ${inspection.version}',
              mono: true,
            ),
            _InfoRow(label: 'File ID', value: inspection.fileId, mono: true),
            _InfoRow(
              label: '目标 Key ID',
              value: inspection.recipientKeyId,
              mono: true,
            ),
            _InfoRow(label: '原始文件名', value: '认证 Metadata 后显示'),
          ],
          const SizedBox(height: 6),
          StatusPill(
            label: inspection?.keyMatches == false ? '公钥指纹不匹配' : '当前公钥已匹配',
            icon: inspection?.keyMatches == false
                ? Icons.error_outline
                : Icons.key_outlined,
            tone: inspection?.keyMatches == false
                ? SboxColors.danger
                : SboxColors.success,
          ),
        ],
      ),
    );
  }

  Widget _localStatusCard(
    BuildContext context,
    CatalogEntryViewData? entry,
    int parts,
  ) {
    final source = widget.controller.selectedSource;
    final standaloneCatalog =
        entry == null && _isCatalogInspection(widget.controller.inspection);
    return SboxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SectionTitle(title: '本地永久密文', subtitle: '解密始终从本地全量 SBOX 镜像读取'),
          const SizedBox(height: 16),
          _InfoRow(
            label: '来源',
            value: source == null
                ? '直接选择的本地文件'
                : '${source.displayName} · ${source.provider.name}',
          ),
          _InfoRow(
            label: '本地路径',
            value:
                source?.localSyncPath ??
                widget.controller.inspection?.path ??
                '—',
            mono: true,
          ),
          _InfoRow(
            label: '分片状态',
            value: parts <= 1 ? '1/1 已就绪' : '$parts/$parts 已同步并待逐片认证',
          ),
          _InfoRow(
            label: 'Catalog 认证',
            value: entry != null
                ? '目录已认证'
                : standaloneCatalog
                ? '当前文件为 Catalog，待验证'
                : '不适用（独立 single）',
          ),
          const SizedBox(height: 6),
          const StatusPill(
            label: '密文永久保存',
            icon: Icons.save_outlined,
            tone: SboxColors.accent,
          ),
        ],
      ),
    );
  }

  Widget _verifiedResult(BuildContext context) {
    final controller = widget.controller;
    return SboxCard(
      color: const Color(0xFF0D2420),
      borderColor: SboxColors.success.withValues(alpha: 0.35),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SectionTitle(
            title: '完整认证通过',
            subtitle: '打开与导出操作现在可用；未发布任何部分明文',
          ),
          const SizedBox(height: 14),
          _InfoRow(
            label: '文件名',
            value: controller.lastDecryptedName ?? '已验证文件',
          ),
          _InfoRow(
            label: '临时位置',
            value: controller.lastDecryptedPath ?? '',
            mono: true,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              ElevatedButton.icon(
                onPressed: () async {
                  try {
                    await controller.openLastDecrypted();
                  } catch (_) {}
                },
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('打开文件'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  try {
                    await controller.exportLastDecrypted();
                  } catch (_) {}
                },
                icon: const Icon(Icons.save_alt_rounded),
                label: const Text('导出 / 另存为'),
              ),
              TextButton.icon(
                onPressed: () async {
                  final confirmed = await showDestructiveConfirmation(
                    context,
                    title: '删除该临时副本？',
                    message: '只删除当前受管理的临时解密明文，不删除本地 .sbox 密文原件，也不删除已经导出的文件。',
                    actionLabel: '删除临时副本',
                  );
                  if (confirmed) {
                    try {
                      await controller.deleteLastDecrypted();
                    } catch (_) {}
                  }
                },
                icon: const Icon(
                  Icons.delete_outline,
                  color: SboxColors.danger,
                ),
                label: const Text(
                  '删除该临时副本',
                  style: TextStyle(color: SboxColors.danger),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _verifiedCatalogResult(BuildContext context) {
    final controller = widget.controller;
    final catalog = controller.catalog;
    return SboxCard(
      color: const Color(0xFF0D2420),
      borderColor: SboxColors.success.withValues(alpha: 0.35),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SectionTitle(
            title: 'Catalog 认证通过',
            subtitle: '目录已解密并验证；没有把 catalog.json 当作普通临时文件发布',
          ),
          const SizedBox(height: 14),
          _InfoRow(
            label: 'Catalog ID',
            value: catalog?.catalogId ?? '已验证',
            mono: true,
          ),
          _InfoRow(
            label: '代数',
            value: '${catalog?.generation ?? 0}',
          ),
          _InfoRow(
            label: '已认证条目',
            value: '${catalog?.entries.length ?? 0}',
          ),
          _InfoRow(
            label: '密文原件',
            value: controller.inspection?.path ?? '',
            mono: true,
          ),
          const SizedBox(height: 8),
          const StatusPill(
            label: '目录内容已认证',
            icon: Icons.verified_outlined,
            tone: SboxColors.success,
          ),
        ],
      ),
    );
  }
}

bool _isCatalogInspection(StandaloneSboxInspection? inspection) =>
    inspection != null &&
    p.basename(inspection.path).toLowerCase() == 'catalog.sbox';

class _EntrySourceCard extends StatelessWidget {
  const _EntrySourceCard({required this.controller, required this.entry});
  final AppController controller;
  final CatalogEntryViewData entry;

  @override
  Widget build(BuildContext context) => SboxCard(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 17),
    child: Row(
      children: <Widget>[
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: SboxColors.info.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(
            Icons.insert_drive_file_outlined,
            color: SboxColors.info,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(entry.title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                '${entry.originalName} · ${_formatBytes(int.parse(entry.plaintextSize))}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
        StatusPill(
          label: '${entry.partCount} 个加密分片',
          icon: Icons.segment_rounded,
          tone: entry.partCount > 1 ? SboxColors.warning : SboxColors.accent,
        ),
        const SizedBox(width: 10),
        const StatusPill(
          label: 'Catalog 已认证',
          icon: Icons.verified_outlined,
          tone: SboxColors.success,
        ),
      ],
    ),
  );
}

class _StepStrip extends StatelessWidget {
  const _StepStrip({required this.active});
  final int active;
  @override
  Widget build(BuildContext context) {
    const items = <(IconData, String)>[
      (Icons.cloud_download_outlined, '同步密文'),
      (Icons.fact_check_outlined, '验证 Catalog 与对象'),
      (Icons.lock_open_outlined, '解密与重组'),
      (Icons.task_alt_rounded, '打开或导出'),
    ];
    return SboxCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
      color: SboxColors.panelSoft,
      child: Row(
        children: <Widget>[
          for (var index = 0; index < items.length; index++) ...<Widget>[
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: index <= active
                          ? SboxColors.accent
                          : SboxColors.borderSoft,
                    ),
                    child: Icon(
                      index < active ? Icons.check : items[index].$1,
                      size: 15,
                      color: index <= active
                          ? const Color(0xFF03211D)
                          : SboxColors.textDim,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      items[index].$2,
                      style: TextStyle(
                        color: index <= active
                            ? SboxColors.text
                            : SboxColors.textDim,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (index < items.length - 1)
              Container(
                width: 28,
                height: 1,
                color: index < active ? SboxColors.accent : SboxColors.border,
              ),
          ],
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.mono = false});
  final String label;
  final String value;
  final bool mono;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 108,
          child: Text(
            label,
            style: const TextStyle(color: SboxColors.textDim, fontSize: 12),
          ),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: mono ? 3 : 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: SboxColors.text,
              fontSize: 12,
              fontFamily: mono ? 'RobotoMono' : null,
            ),
          ),
        ),
      ],
    ),
  );
}

String _decryptOperation(AppOperation operation) => switch (operation) {
  AppOperation.syncingObjects || AppOperation.refreshing => '正在同步全部密文分片到本地',
  AppOperation.unlockingCatalog => '正在解密并验证 Catalog 与历史链',
  AppOperation.decrypting => '正在逐记录认证、解密与重组',
  AppOperation.exporting => '正在通过系统选择器导出已验证文件',
  _ => '正在准备安全任务',
};

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
