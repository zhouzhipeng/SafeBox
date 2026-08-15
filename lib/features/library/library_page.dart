import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/app_controller.dart';
import '../../app/sbox_dialogs.dart';
import '../../app/sbox_theme.dart';
import '../../app/sbox_widgets.dart';
import '../../sbox/engine/crypto_task_runner.dart';
import '../../sbox/source/local_scanner.dart';
import '../../sbox/source/source_config.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.controller,
    required this.onOpenSources,
    required this.onDecryptEntry,
    required this.onStandaloneSelected,
  });

  final AppController controller;
  final VoidCallback onOpenSources;
  final ValueChanged<String> onDecryptEntry;
  final VoidCallback onStandaloneSelected;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _search = TextEditingController();
  String? _tag;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _openLocal() async {
    if (widget.controller.supportsAuthorizedDirectorySelection) {
      try {
        await widget.controller.chooseAndAddAuthorizedLocalSource();
      } catch (_) {}
      return;
    }
    final path = await widget.controller.chooseLocalCipherDirectory(
      confirmButtonText: '打开此 SBOX 目录',
    );
    if (path == null || !mounted) return;
    try {
      final probe = await widget.controller.inspectLocalDirectory(path);
      if (!mounted) return;
      final initialize =
          probe.catalogHeader == null &&
          await Directory(path).list(followLinks: false).isEmpty;
      await widget.controller.addLocalSource(
        displayName: '本地 SBOX 目录',
        path: path,
        requestWrite: true,
        initializeEmptyAsCanonical: initialize,
      );
    } catch (_) {}
  }

  Future<void> _openManagedLocal() async {
    try {
      await widget.controller.addManagedWritableLocalSource();
    } catch (_) {}
  }

  Future<void> _selectStandalone() async {
    const group = XTypeGroup(
      label: 'SBOX encrypted file',
      extensions: <String>['sbox'],
    );
    final file = await openFile(acceptedTypeGroups: const <XTypeGroup>[group]);
    if (file == null) return;
    try {
      await widget.controller.inspectStandalone(file.path);
      widget.onStandaloneSelected();
    } catch (_) {}
  }

  Future<void> _unlock() async {
    final mnemonic = await showMnemonicPrompt(
      context,
      title: '验证并打开加密目录',
      actionLabel: '验证目录',
    );
    if (mnemonic == null || !mounted) return;
    try {
      await widget.controller.unlockSelectedCatalog(mnemonic);
    } catch (_) {}
  }

  Future<void> _refreshOrSync() async {
    final source = widget.controller.selectedSource;
    if (source == null) return;
    try {
      if (!source.hasPendingCatalog) {
        await widget.controller.refreshSelectedSource();
        return;
      }
      final mnemonic = await showMnemonicPrompt(
        context,
        title: '同步本地待提交目录',
        actionLabel: '验证、合并并同步',
      );
      if (mnemonic == null || !mounted) return;
      await widget.controller.syncPendingCatalog(mnemonic);
    } catch (_) {}
  }

  Future<void> _discardPending() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放弃本地待同步目录版本？'),
        content: const Text(
          '将恢复最后一个已验证的远端 Catalog 基线。已加密的 SBOX 对象仍会永久保留，不会删除远端内容，也不会产生明文。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: SboxColors.danger),
            child: const Text('放弃目录改动'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.controller.discardPendingCatalogAndRestoreBase();
    } catch (_) {}
  }

  Future<void> _resolveConflicts() async {
    final resolutions = await _showCatalogConflictResolutionDialog(
      context,
      widget.controller.catalogConflicts,
    );
    if (resolutions == null || !mounted) return;
    final mnemonic = await showMnemonicPrompt(
      context,
      title: '应用冲突选择并重新签名',
      actionLabel: '签名并条件提交',
    );
    if (mnemonic == null || !mounted) return;
    try {
      await widget.controller.resolveCatalogConflicts(
        mnemonic: mnemonic,
        resolutions: resolutions,
      );
    } catch (_) {}
  }

  Future<void> _editEntry(CatalogEntryViewData entry) async {
    final edit = await _showCatalogMetadataDialog(context, entry);
    if (edit == null || !mounted) return;
    final mnemonic = await showMnemonicPrompt(
      context,
      title: '签名并加密 Catalog 修改',
      actionLabel: '保存修改',
    );
    if (mnemonic == null || !mounted) return;
    try {
      await widget.controller.updateCatalogEntryMetadata(
        entryId: entry.entryId,
        title: edit.title,
        description: edit.description,
        tags: edit.tags,
        mnemonic: mnemonic,
        syncRemote: widget.controller.selectedSource?.isRemote ?? false,
      );
    } catch (_) {}
  }

  Future<void> _deleteEntry(CatalogEntryViewData entry) async {
    final confirmed = await showDestructiveConfirmation(
      context,
      title: '从 Catalog 中删除“${entry.title}”？',
      message:
          '这会提交带墓碑的新加密 Catalog，使项目不再出现在资料库中。'
          '本地永久 SBOX 原件不会删除，公开仓库历史中的旧密文也可能永久保留。',
      actionLabel: '确认逻辑删除',
    );
    if (!confirmed || !mounted) return;
    final mnemonic = await showMnemonicPrompt(
      context,
      title: '签名并加密删除墓碑',
      actionLabel: '签名并删除',
    );
    if (mnemonic == null || !mounted) return;
    try {
      await widget.controller.deleteCatalogEntry(
        entryId: entry.entryId,
        mnemonic: mnemonic,
        syncRemote: widget.controller.selectedSource?.isRemote ?? false,
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final source = controller.selectedSource;
    final catalog = controller.catalog;
    final allEntries = catalog?.entries ?? const <CatalogEntryViewData>[];
    final query = _search.text.trim().toLowerCase();
    final entries = allEntries
        .where((entry) {
          final matchesText =
              query.isEmpty ||
              entry.title.toLowerCase().contains(query) ||
              entry.description.toLowerCase().contains(query) ||
              entry.originalName.toLowerCase().contains(query);
          return matchesText && (_tag == null || entry.tags.contains(_tag));
        })
        .toList(growable: false);
    final tags = allEntries.expand((entry) => entry.tags).toSet().toList()
      ..sort();

    return ListView(
      padding: const EdgeInsets.fromLTRB(34, 34, 34, 30),
      children: <Widget>[
        PageHeading(
          title: '资料库',
          subtitle: '只展示通过 Catalog 解密与 Ed25519 签名验证的可信索引',
          trailing: source == null
              ? null
              : ElevatedButton.icon(
                  onPressed: controller.isBusy ? null : _refreshOrSync,
                  icon: const Icon(Icons.sync_rounded, size: 18),
                  label: Text(
                    source.hasPendingCatalog
                        ? '同步待提交'
                        : source.provider == SourceProvider.local
                        ? '刷新目录'
                        : '立即同步',
                  ),
                ),
        ),
        const SizedBox(height: 26),
        if (source == null)
          EmptyState(
            icon: Icons.folder_off_outlined,
            title: '尚未打开 SBOX 数据源',
            message: '可以完全跳过云端，直接使用本地目录或选择单个 SBOX 文件。GitHub/Gitee 只是可选的公开密文存储。',
            actions: <Widget>[
              ElevatedButton.icon(
                onPressed: _openLocal,
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('打开本地 SBOX 目录'),
              ),
              if (controller.supportsAuthorizedDirectorySelection)
                OutlinedButton.icon(
                  onPressed: _openManagedLocal,
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('创建本机可写保险箱'),
                ),
              OutlinedButton.icon(
                onPressed: _selectStandalone,
                icon: const Icon(Icons.insert_drive_file_outlined),
                label: const Text('选择单个 SBOX 文件'),
              ),
              TextButton(
                onPressed: widget.onOpenSources,
                child: const Text('配置 GitHub/Gitee（可选）'),
              ),
            ],
          )
        else ...<Widget>[
          _SourceBar(controller: controller, source: source),
          const SizedBox(height: 18),
          if (controller.catalogConflicts.isNotEmpty) ...<Widget>[
            _CatalogConflictCard(
              conflicts: controller.catalogConflicts,
              onResolve: _resolveConflicts,
              onRetry: _refreshOrSync,
              onDiscard: _discardPending,
            ),
            const SizedBox(height: 18),
          ] else if (source.hasPendingCatalog) ...<Widget>[
            SecurityNotice(
              title: '本地 Catalog 等待条件同步',
              message: '本地密文和目录已永久保存。远端刷新不会覆盖该版本；同步时会先上传全部不可变 SBOX 对象，再条件提交 catalog.sbox。',
              warning: true,
              icon: Icons.cloud_upload_outlined,
            ),
            const SizedBox(height: 18),
          ],
          if (source.localDirectoryMode == ConfiguredLocalMode.looseReadOnly)
            _LooseLibrary(
              controller: controller,
              onSelected: (candidate) async {
                try {
                  await controller.inspectLooseCandidate(candidate);
                  widget.onStandaloneSelected();
                } catch (_) {}
              },
            )
          else if (catalog == null)
            EmptyState(
              icon: Icons.lock_outline_rounded,
              title:
                  File(
                    '${source.localSyncPath}${Platform.pathSeparator}catalog.sbox',
                  ).existsSync()
                  ? '加密目录尚未验证'
                  : '此规范目录还是空的',
              message:
                  File(
                    '${source.localSyncPath}${Platform.pathSeparator}catalog.sbox',
                  ).existsSync()
                  ? 'catalog.sbox 已作为密文永久保存在本地。输入本次助记词后才能显示标题、说明和原始文件名。'
                  : '首次“加密保存”会创建签名并加密的 catalog.sbox；也可以先从远端同步。',
              actions: <Widget>[
                if (File(
                  '${source.localSyncPath}${Platform.pathSeparator}catalog.sbox',
                ).existsSync())
                  ElevatedButton.icon(
                    onPressed: controller.isBusy ? null : _unlock,
                    icon: const Icon(Icons.verified_user_outlined),
                    label: const Text('验证并打开目录'),
                  ),
                OutlinedButton.icon(
                  onPressed: controller.isBusy ? null : _refreshOrSync,
                  icon: const Icon(Icons.sync_rounded),
                  label: Text(
                    source.hasPendingCatalog
                        ? '验证并同步待提交目录'
                        : source.isRemote
                        ? '拉取加密目录'
                        : '刷新目录',
                  ),
                ),
              ],
            )
          else ...<Widget>[
            _VerifiedSummary(controller: controller),
            const SizedBox(height: 18),
            LayoutBuilder(
              builder: (context, constraints) {
                final search = TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded),
                    hintText: '搜索标题、说明或原始文件名',
                  ),
                );
                final filter = DropdownButtonFormField<String?>(
                  initialValue: _tag,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.sell_outlined),
                    hintText: '全部标签',
                  ),
                  items: <DropdownMenuItem<String?>>[
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('全部标签'),
                    ),
                    for (final tag in tags)
                      DropdownMenuItem<String?>(value: tag, child: Text(tag)),
                  ],
                  onChanged: (value) => setState(() => _tag = value),
                );
                return constraints.maxWidth < 620
                    ? Column(
                        children: <Widget>[
                          search,
                          const SizedBox(height: 10),
                          filter,
                        ],
                      )
                    : Row(
                        children: <Widget>[
                          Expanded(child: search),
                          const SizedBox(width: 12),
                          SizedBox(width: 170, child: filter),
                        ],
                      );
              },
            ),
            const SizedBox(height: 14),
            if (entries.isEmpty)
              const EmptyState(
                icon: Icons.inventory_2_outlined,
                title: '没有匹配的项目',
                message: '调整搜索或标签筛选；空目录可以从“加密”页添加第一个文件。',
              )
            else
              ...entries.map(
                (entry) => Padding(
                  padding: const EdgeInsets.only(bottom: 11),
                  child: _CatalogRow(
                    entry: entry,
                    onDecrypt: () => widget.onDecryptEntry(entry.entryId),
                    onEdit:
                        source.isWritable &&
                            !controller.isBusy &&
                            controller.catalogConflicts.isEmpty
                        ? () => _editEntry(entry)
                        : null,
                    onDelete:
                        source.isWritable &&
                            !controller.isBusy &&
                            controller.catalogConflicts.isEmpty
                        ? () => _deleteEntry(entry)
                        : null,
                  ),
                ),
              ),
          ],
        ],
        if (controller.isBusy) ...<Widget>[
          const SizedBox(height: 18),
          SboxProgressCard(
            title: _operationLabel(controller.operation),
            detail: controller.syncProgress == null
                ? '密码学与大文件任务在一次性工作 Isolate 中执行。'
                : '${controller.syncProgress!.completed} / ${controller.syncProgress!.total}',
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
      ],
    );
  }
}

class _CatalogConflictCard extends StatelessWidget {
  const _CatalogConflictCard({
    required this.conflicts,
    required this.onResolve,
    required this.onRetry,
    required this.onDiscard,
  });

  final List<CatalogConflictViewData> conflicts;
  final VoidCallback onResolve;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    return SboxCard(
      borderColor: SboxColors.warning.withValues(alpha: 0.48),
      color: SboxColors.warning.withValues(alpha: 0.065),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SectionTitle(
            title: 'Catalog 并发冲突',
            subtitle: '未使用时间戳或最后写入者覆盖；本地待同步版本仍保持加密并永久保留',
          ),
          const SizedBox(height: 14),
          for (final conflict in conflicts) ...<Widget>[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: SboxColors.panelSoft,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: SboxColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    conflict.reason,
                    style: const TextStyle(
                      color: SboxColors.warning,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '本地：${conflict.localTitle} · ${conflict.localPartCount} 分片'
                    '${conflict.remoteTitle == null ? '' : '\n远端：${conflict.remoteTitle} · ${conflict.remotePartCount ?? 0} 分片'}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  MonospaceValue(
                    '${conflict.entryId}\nlocal ${conflict.localPayloadSha256}'
                    '${conflict.remotePayloadSha256 == null ? '' : '\nremote ${conflict.remotePayloadSha256}'}',
                    maxLines: 3,
                    color: SboxColors.textMuted,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              ElevatedButton.icon(
                onPressed: onResolve,
                icon: const Icon(Icons.rule_folder_outlined),
                label: const Text('逐条处理冲突'),
              ),
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重新验证并合并'),
              ),
              OutlinedButton.icon(
                onPressed: onDiscard,
                icon: const Icon(Icons.undo_rounded),
                label: const Text('放弃本地目录改动'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SourceBar extends StatelessWidget {
  const _SourceBar({required this.controller, required this.source});

  final AppController controller;
  final SourceConfiguration source;

  @override
  Widget build(BuildContext context) {
    final isLocal = source.provider == SourceProvider.local;
    return SboxCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final icon = Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: SboxColors.accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              isLocal ? Icons.folder_outlined : Icons.cloud_outlined,
              color: SboxColors.accent,
            ),
          );
          final selector = DropdownButtonHideUnderline(
            child: DropdownButton<SourceId>(
              value: source.sourceId,
              isExpanded: true,
              dropdownColor: SboxColors.panelRaised,
              items: controller.sources
                  .map(
                    (item) => DropdownMenuItem<SourceId>(
                      value: item.sourceId,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            item.displayName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            _providerLine(item),
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: SboxColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) controller.selectSource(value);
              },
            ),
          );
          final state = StatusPill(
            label: source.hasPendingCatalog
                ? '本地已保存 · 等待条件同步'
                : isLocal
                ? source.isAuthorizedDirectory
                      ? '系统目录 · 只读密文镜像'
                      : '本地目录 · 离线'
                : (source.isWritable ? '匿名读取 · 已授权写入' : '公开匿名读取'),
            icon: source.hasPendingCatalog
                ? Icons.cloud_upload_outlined
                : isLocal
                ? Icons.wifi_off_rounded
                : Icons.public_rounded,
            tone: source.hasPendingCatalog
                ? SboxColors.warning
                : SboxColors.accent,
          );
          final lastSync = source.lastLocalSyncAt == null
              ? null
              : Text(
                  '本地同步 ${DateFormat('MM-dd HH:mm').format(source.lastLocalSyncAt!.toLocal())}',
                  style: Theme.of(context).textTheme.bodyMedium,
                );
          if (constraints.maxWidth < 660) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    icon,
                    const SizedBox(width: 12),
                    Expanded(child: selector),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[state, ?lastSync],
                ),
              ],
            );
          }
          return Row(
            children: <Widget>[
              icon,
              const SizedBox(width: 12),
              Expanded(child: selector),
              const SizedBox(width: 14),
              state,
              if (lastSync != null) ...<Widget>[
                const SizedBox(width: 14),
                lastSync,
              ],
            ],
          );
        },
      ),
    );
  }
}

class _VerifiedSummary extends StatelessWidget {
  const _VerifiedSummary({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final catalog = controller.catalog!;
    return SboxCard(
      color: const Color(0xFF0E211F),
      borderColor: SboxColors.accent.withValues(alpha: 0.25),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Row(
        children: <Widget>[
          const Icon(Icons.verified_outlined, color: SboxColors.accent),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('目录已验证', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          Text(
            '${catalog.entries.length} 个项目',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(width: 18),
          MonospaceValue(
            'generation ${catalog.generation}',
            color: SboxColors.accent,
          ),
        ],
      ),
    );
  }
}

class _CatalogRow extends StatelessWidget {
  const _CatalogRow({
    required this.entry,
    required this.onDecrypt,
    this.onEdit,
    this.onDelete,
  });

  final CatalogEntryViewData entry;
  final VoidCallback onDecrypt;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return SboxCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final icon = Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: _fileColor(entry.mediaType).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              _fileIcon(entry.mediaType),
              color: _fileColor(entry.mediaType),
              size: 25,
            ),
          );
          final summary = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                entry.description.isEmpty ? '无说明' : entry.description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 5,
                children: entry.tags
                    .map(
                      (tag) => StatusPill(
                        label: tag,
                        icon: Icons.sell_outlined,
                        tone: SboxColors.info,
                        compact: true,
                      ),
                    )
                    .toList(),
              ),
            ],
          );
          final fileDetails = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                entry.originalName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: SboxColors.text,
                  fontFamily: 'RobotoMono',
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                '${_formatBytes(BigInt.parse(entry.plaintextSize))} · '
                '${_formatTime(entry.updatedAt)} · revision ${entry.revision}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          );
          final multipart = entry.partCount > 1
              ? StatusPill(
                  label: '${entry.partCount} 个加密分片',
                  icon: Icons.segment_rounded,
                  tone: SboxColors.warning,
                )
              : null;
          final action = OutlinedButton.icon(
            onPressed: onDecrypt,
            icon: const Icon(Icons.download_for_offline_outlined, size: 18),
            label: const Text('下载并解密'),
          );
          final menu = onEdit == null && onDelete == null
              ? null
              : _CatalogEntryMenu(onEdit: onEdit, onDelete: onDelete);
          if (constraints.maxWidth < 700) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    icon,
                    const SizedBox(width: 13),
                    Expanded(child: summary),
                    if (menu != null) ...<Widget>[
                      const SizedBox(width: 4),
                      menu,
                    ],
                  ],
                ),
                const SizedBox(height: 13),
                fileDetails,
                if (multipart != null) ...<Widget>[
                  const SizedBox(height: 11),
                  Align(alignment: Alignment.centerLeft, child: multipart),
                ],
                const SizedBox(height: 13),
                action,
              ],
            );
          }
          return Row(
            children: <Widget>[
              icon,
              const SizedBox(width: 15),
              Expanded(flex: 4, child: summary),
              const SizedBox(width: 16),
              Expanded(flex: 3, child: fileDetails),
              if (multipart != null) ...<Widget>[
                const SizedBox(width: 12),
                multipart,
              ],
              if (menu != null) ...<Widget>[const SizedBox(width: 4), menu],
              const SizedBox(width: 12),
              action,
            ],
          );
        },
      ),
    );
  }
}

enum _CatalogRowAction { edit, delete }

class _CatalogEntryMenu extends StatelessWidget {
  const _CatalogEntryMenu({required this.onEdit, required this.onDelete});

  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_CatalogRowAction>(
      tooltip: '更多目录操作',
      icon: const Icon(Icons.more_horiz_rounded, color: SboxColors.textMuted),
      onSelected: (action) {
        switch (action) {
          case _CatalogRowAction.edit:
            onEdit?.call();
            break;
          case _CatalogRowAction.delete:
            onDelete?.call();
            break;
        }
      },
      itemBuilder: (context) => <PopupMenuEntry<_CatalogRowAction>>[
        if (onEdit != null)
          const PopupMenuItem<_CatalogRowAction>(
            value: _CatalogRowAction.edit,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.edit_outlined),
              title: Text('编辑标题、说明与标签'),
            ),
          ),
        if (onDelete != null)
          const PopupMenuItem<_CatalogRowAction>(
            value: _CatalogRowAction.delete,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_outline, color: SboxColors.danger),
              title: Text(
                '从 Catalog 逻辑删除',
                style: TextStyle(color: SboxColors.danger),
              ),
            ),
          ),
      ],
    );
  }
}

class _LooseLibrary extends StatelessWidget {
  const _LooseLibrary({required this.controller, required this.onSelected});

  final AppController controller;
  final ValueChanged<ScannedSboxCandidate> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SecurityNotice(
          title: '未编目本地 SBOX · 不受信索引',
          message: '只显示公共头部信息。没有签名 Catalog 时不能显示原始文件名，也不能重组 content_kind = 4 的 multipart。',
          warning: true,
        ),
        const SizedBox(height: 14),
        if (controller.looseCandidates.isEmpty)
          const EmptyState(
            icon: Icons.find_in_page_outlined,
            title: '没有发现可识别的 SBOX',
            message: '扫描不会跟随符号链接，最大深度为 8，候选上限为 100,000。',
          )
        else
          ...controller.looseCandidates.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SboxCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 17,
                  vertical: 14,
                ),
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.lock_outline, color: SboxColors.accent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            item.relativePath,
                            style: const TextStyle(
                              fontFamily: 'RobotoMono',
                              color: SboxColors.text,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'file ID ${item.header.fileId.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()} · ${_formatBytes(BigInt.from(item.ciphertextSize))}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    if (item.hasFileIdConflict)
                      const StatusPill(
                        label: 'File ID 冲突',
                        icon: Icons.error_outline,
                        tone: SboxColors.danger,
                      ),
                    const SizedBox(width: 10),
                    OutlinedButton(
                      onPressed: () => onSelected(item),
                      child: const Text('验证并解密'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

String _providerLine(SourceConfiguration source) => switch (source.provider) {
  SourceProvider.local =>
    source.isAuthorizedDirectory
        ? '系统授权目录 · 只读永久密文镜像'
        : source.localDirectoryMode == ConfiguredLocalMode.canonicalCatalog
        ? '本地目录 · canonical_catalog'
        : '本地目录 · loose_read_only',
  SourceProvider.github =>
    'GitHub · ${source.owner}/${source.repository} · ${source.branchOrRef}',
  SourceProvider.gitee =>
    'Gitee · ${source.owner}/${source.repository} · ${source.branchOrRef}',
  SourceProvider.https => '只读 HTTPS · ${source.httpsBaseUri?.host}',
};

String _operationLabel(AppOperation operation) => switch (operation) {
  AppOperation.derivingIdentity => '正在恢复公开身份',
  AppOperation.inspecting => '正在安全检查',
  AppOperation.refreshing => '正在刷新加密目录',
  AppOperation.unlockingCatalog => '正在解密并验证 Catalog',
  AppOperation.syncingObjects => '正在同步全部密文分片到本地',
  AppOperation.encrypting => '正在加密并本地提交',
  AppOperation.updatingCatalog => '正在签名并加密 Catalog 修改',
  AppOperation.uploading => '正在上传密文并条件提交 Catalog',
  AppOperation.decrypting => '正在认证、解密与重组',
  AppOperation.exporting => '正在通过系统选择器导出文件',
  AppOperation.cleaning => '正在清理受管理临时明文',
  AppOperation.idle => '任务完成',
};

final class _CatalogMetadataEdit {
  const _CatalogMetadataEdit({
    required this.title,
    required this.description,
    required this.tags,
  });

  final String title;
  final String description;
  final List<String> tags;
}

Future<Map<String, CatalogConflictResolution>?>
_showCatalogConflictResolutionDialog(
  BuildContext context,
  List<CatalogConflictViewData> conflicts,
) {
  final selected = <String, CatalogConflictResolution>{};
  return showDialog<Map<String, CatalogConflictResolution>>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        backgroundColor: SboxColors.panel,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: SboxColors.border),
        ),
        title: const Text('逐条处理 Catalog 冲突'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700, maxHeight: 620),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SecurityNotice(
                  title: '禁止最后写入者自动覆盖',
                  message: '每个冲突都必须明确选择本地或远端。选择完成后会重新验证最新远端 Catalog、增加 revision/generation，并重新签名和加密。',
                  warning: true,
                ),
                const SizedBox(height: 14),
                for (final conflict in conflicts) ...<Widget>[
                  SboxCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(
                          conflict.reason,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '本地：${conflict.localTitle}\n'
                          '远端：${conflict.remoteTitle ?? '已删除或不存在'}',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 10),
                        SegmentedButton<CatalogConflictResolution>(
                          emptySelectionAllowed: true,
                          showSelectedIcon: false,
                          segments: <ButtonSegment<CatalogConflictResolution>>[
                            ButtonSegment<CatalogConflictResolution>(
                              value: CatalogConflictResolution.keepLocal,
                              icon: Icon(
                                conflict.localTitle == '本地删除'
                                    ? Icons.delete_outline
                                    : Icons.computer_outlined,
                              ),
                              label: Text(
                                conflict.localTitle == '本地删除'
                                    ? '确认本地删除'
                                    : '保留本地版本',
                              ),
                            ),
                            ButtonSegment<CatalogConflictResolution>(
                              value: CatalogConflictResolution.keepRemote,
                              icon: const Icon(Icons.cloud_outlined),
                              label: Text(
                                conflict.remoteTitle == null
                                    ? '采用远端删除'
                                    : '采用远端版本',
                              ),
                            ),
                          ],
                          selected: selected[conflict.entryId] == null
                              ? const <CatalogConflictResolution>{}
                              : <CatalogConflictResolution>{
                                  selected[conflict.entryId]!,
                                },
                          onSelectionChanged: (values) => setState(() {
                            if (values.isEmpty) {
                              selected.remove(conflict.entryId);
                            } else {
                              selected[conflict.entryId] = values.single;
                            }
                          }),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: selected.length == conflicts.length
                ? () => Navigator.of(context).pop(
                    Map<String, CatalogConflictResolution>.unmodifiable(
                      selected,
                    ),
                  )
                : null,
            child: Text('继续（${selected.length}/${conflicts.length}）'),
          ),
        ],
      ),
    ),
  );
}

Future<_CatalogMetadataEdit?> _showCatalogMetadataDialog(
  BuildContext context,
  CatalogEntryViewData entry,
) async {
  final title = TextEditingController(text: entry.title);
  final description = TextEditingController(text: entry.description);
  final tags = TextEditingController(text: entry.tags.join(', '));
  try {
    return await showDialog<_CatalogMetadataEdit>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          final normalizedTitle = title.text.trim();
          final normalizedDescription = description.text.trim();
          final parsedTags = tags.text
              .split(RegExp(r'[,，\s]+'))
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toSet()
              .toList(growable: false);
          final valid =
              normalizedTitle.isNotEmpty &&
              utf8.encode(normalizedTitle).length <= 256 &&
              utf8.encode(normalizedDescription).length <= 4096 &&
              parsedTags.length <= 32 &&
              parsedTags.every((tag) => utf8.encode(tag).length <= 64);
          return AlertDialog(
            backgroundColor: SboxColors.panel,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: SboxColors.border),
            ),
            title: const Text('编辑 Catalog 条目'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const SecurityNotice(
                      title: '修改需要重新签名',
                      message: '仅修改加密 Catalog 中的标题、说明和标签；原始 SBOX 密文对象不会被改写。',
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: title,
                      autofocus: true,
                      maxLength: 256,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(labelText: '标题'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: description,
                      minLines: 3,
                      maxLines: 6,
                      maxLength: 4096,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(labelText: '说明（可选）'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: tags,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: '标签（逗号或空格分隔）',
                        helperText: '最多 32 个标签；每个标签不超过 64 字节',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              ElevatedButton(
                onPressed: valid
                    ? () => Navigator.of(context).pop(
                        _CatalogMetadataEdit(
                          title: normalizedTitle,
                          description: normalizedDescription,
                          tags: parsedTags,
                        ),
                      )
                    : null,
                child: const Text('继续验证助记词'),
              ),
            ],
          );
        },
      ),
    );
  } finally {
    title.dispose();
    description.dispose();
    tags.dispose();
  }
}

String _formatTime(String value) {
  try {
    return DateFormat('yyyy-MM-dd HH:mm')
        .format(DateTime.parse(value).toLocal());
  } catch (_) {
    return value;
  }
}

String _formatBytes(BigInt bytes) {
  final value = bytes.toDouble();
  if (value >= 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
  }
  if (value >= 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(2)} MiB';
  }
  if (value >= 1024) return '${(value / 1024).toStringAsFixed(1)} KiB';
  return '${bytes.toString()} B';
}

IconData _fileIcon(String mediaType) {
  if (mediaType.startsWith('image/')) return Icons.image_outlined;
  if (mediaType.startsWith('text/')) return Icons.description_outlined;
  if (mediaType == 'application/pdf') return Icons.picture_as_pdf_outlined;
  if (mediaType.contains('zip')) return Icons.folder_zip_outlined;
  return Icons.insert_drive_file_outlined;
}

Color _fileColor(String mediaType) {
  if (mediaType == 'application/pdf') return SboxColors.danger;
  if (mediaType.startsWith('text/')) return SboxColors.info;
  if (mediaType.contains('zip')) return SboxColors.warning;
  return SboxColors.accent;
}
