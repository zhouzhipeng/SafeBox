import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/sbox_theme.dart';
import '../../app/sbox_widgets.dart';
import '../../sbox/constants.dart';
import '../../sbox/source/source_config.dart';

class EncryptPage extends StatefulWidget {
  const EncryptPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<EncryptPage> createState() => _EncryptPageState();
}

class _EncryptPageState extends State<EncryptPage> {
  bool _textMode = false;
  bool _dragging = false;
  XFile? _file;
  int? _fileLength;
  final _text = TextEditingController();
  final _name = TextEditingController(text: 'note.txt');
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _tags = TextEditingController();

  @override
  void dispose() {
    _text.clear();
    _text.dispose();
    _name.dispose();
    _title.dispose();
    _description.dispose();
    _tags.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final file = await openFile();
    if (file != null) await _setFile(file);
  }

  Future<void> _setFile(XFile file) async {
    final length = await File(file.path).length();
    if (!mounted) return;
    setState(() {
      _file = file;
      _fileLength = length;
      _title.text = _baseName(file.name);
    });
  }

  Future<void> _submit({required bool syncRemote}) async {
    final source = widget.controller.selectedSource;
    if (source == null || !source.isWritable) return;
    if ((!_textMode && _file == null) || (_textMode && _text.text.isEmpty)) {
      return;
    }
    final title = _title.text.trim();
    final originalName = _textMode ? _name.text.trim() : _file!.name;
    if (title.isEmpty || originalName.isEmpty) return;
    final plaintext = _textMode ? _text.text : null;
    try {
      await widget.controller.encryptAndSave(
        inputPath: _textMode ? null : _file!.path,
        text: plaintext,
        originalName: originalName,
        title: title,
        description: _description.text.trim(),
        tags: _tags.text
            .split(RegExp(r'[,，\s]+'))
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toSet()
            .toList(),
        syncRemote: syncRemote,
      );
      if (mounted) {
        setState(() {
          if (_textMode) _text.clear();
          _file = null;
          _fileLength = null;
          _title.clear();
          _description.clear();
          _tags.clear();
          _name.text = 'note.txt';
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final source = controller.selectedSource;
    final plaintextLength = _textMode
        ? utf8.encode(_text.text).length
        : (_fileLength ?? 0);
    final partCount = math.max(
      1,
      (plaintextLength + SboxV1.defaultPartPlaintextSize - 1) ~/
          SboxV1.defaultPartPlaintextSize,
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(34, 34, 34, 30),
      children: <Widget>[
        const PageHeading(
          title: '加密保存',
          subtitle: '所有明文只在本机处理；保存与上传的始终是完整认证的 SBOX 密文',
        ),
        const SizedBox(height: 22),
        Row(
          children: <Widget>[
            const StatusPill(
              label: '本地离线处理',
              icon: Icons.wifi_off_rounded,
              tone: SboxColors.accent,
            ),
            const SizedBox(width: 10),
            StatusPill(
              label: '默认分片 16 MiB · 内部记录 4 MiB',
              icon: Icons.segment_rounded,
              tone: SboxColors.info,
            ),
          ],
        ),
        const SizedBox(height: 20),
        SboxCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 17, 20, 0),
                child: Row(
                  children: <Widget>[
                    _ModeTab(
                      label: '文件',
                      icon: Icons.insert_drive_file_outlined,
                      selected: !_textMode,
                      onTap: () => setState(() => _textMode = false),
                    ),
                    const SizedBox(width: 8),
                    _ModeTab(
                      label: '文本',
                      icon: Icons.notes_rounded,
                      selected: _textMode,
                      onTap: () => setState(() => _textMode = true),
                    ),
                  ],
                ),
              ),
              const Divider(height: 22),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 20, 22),
                child: _textMode ? _textEditor(context) : _filePicker(context),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 760;
            final metadata = _metadataCard(context);
            final target = _targetCard(
              context,
              source,
              plaintextLength,
              partCount,
            );
            return narrow
                ? Column(
                    children: <Widget>[
                      metadata,
                      const SizedBox(height: 16),
                      target,
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(child: metadata),
                      const SizedBox(width: 16),
                      Expanded(child: target),
                    ],
                  );
          },
        ),
        const SizedBox(height: 16),
        _cryptoSummary(context, plaintextLength, partCount),
        if (controller.isBusy) ...<Widget>[
          const SizedBox(height: 16),
          SboxProgressCard(
            title: controller.operation == AppOperation.uploading
                ? '正在上传密文分片'
                : '正在加密并永久提交到本地',
            detail: controller.syncProgress == null
                ? '规划分片 → 读取 → AES-256-GCM → Final 认证 → 本地原子提交'
                : '分片 ${controller.syncProgress!.completed}/${controller.syncProgress!.total}；Catalog 永远最后提交',
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
        if (source == null)
          const SecurityNotice(
            title: '需要保存目标',
            message: '请先从“数据源”打开本地 SBOX 目录。云端配置可完全跳过。',
            warning: true,
          )
        else if (!source.isWritable)
          const SecurityNotice(
            title: '当前数据源只读',
            message: '请选择可写规范本地目录，或为 GitHub/Gitee 配置独立写入凭据。',
            warning: true,
          )
        else if (source.isRemote) ...<Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: controller.isBusy
                      ? null
                      : () => _submit(syncRemote: false),
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('仅加密到本地'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: controller.isBusy
                      ? null
                      : () => _submit(syncRemote: true),
                  icon: const Icon(Icons.lock_outline_rounded),
                  label: const Text('加密并同步'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            '先在本机完成加密并永久保存全部 SBOX，再上传不可变密文对象，最后条件提交 catalog.sbox。',
            textAlign: TextAlign.center,
            style: TextStyle(color: SboxColors.textMuted, fontSize: 12),
          ),
        ] else ...<Widget>[
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: controller.isBusy
                  ? null
                  : () => _submit(syncRemote: false),
              icon: const Icon(Icons.lock_outline_rounded),
              label: const Text('加密保存到本地'),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '密文直接保存到所选本地目录，不会进行 DNS、HTTP、登录或上传。',
            textAlign: TextAlign.center,
            style: TextStyle(color: SboxColors.textMuted, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _filePicker(BuildContext context) {
    return Column(
      children: <Widget>[
        DropTarget(
          onDragEntered: (_) => setState(() => _dragging = true),
          onDragExited: (_) => setState(() => _dragging = false),
          onDragDone: (detail) async {
            setState(() => _dragging = false);
            if (detail.files.isNotEmpty) await _setFile(detail.files.first);
          },
          child: InkWell(
            onTap: _pickFile,
            borderRadius: BorderRadius.circular(12),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 130),
              width: double.infinity,
              height: 186,
              decoration: BoxDecoration(
                color: _dragging
                    ? SboxColors.accent.withValues(alpha: 0.08)
                    : SboxColors.panelSoft,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _dragging ? SboxColors.accent : SboxColors.border,
                  width: _dragging ? 1.5 : 1,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(
                    _file == null
                        ? Icons.cloud_upload_outlined
                        : Icons.verified_outlined,
                    size: 38,
                    color: SboxColors.accent,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _file == null ? '拖放任意文件到这里' : _file!.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    _file == null
                        ? '或点击选择本地文件'
                        : '${_formatBytes(_fileLength ?? 0)} · 点击可重新选择',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _pickFile,
                    child: Text(_file == null ? '选择文件' : '更换文件'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _textEditor(BuildContext context) {
    return Column(
      children: <Widget>[
        TextField(
          controller: _text,
          minLines: 7,
          maxLines: 12,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'UTF-8 文本内容',
            hintText: '直接输入需要加密保存的文本…',
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '恢复文件名',
                  hintText: 'note.txt',
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '${_text.text.characters.length} 字符 · ${utf8.encode(_text.text).length} UTF-8 字节',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ],
    );
  }

  Widget _metadataCard(BuildContext context) {
    return SboxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SectionTitle(
            title: 'Catalog 项目信息',
            subtitle: '这些字段只存在于加密的 catalog.sbox 内；新建目录只需公钥',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            maxLength: 256,
            decoration: const InputDecoration(
              labelText: '标题 *',
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            maxLines: 3,
            maxLength: 4096,
            decoration: const InputDecoration(
              labelText: '说明（可选）',
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tags,
            decoration: const InputDecoration(
              labelText: '标签（可选）',
              hintText: '归档, 财务, 重要',
            ),
          ),
        ],
      ),
    );
  }

  Widget _targetCard(
    BuildContext context,
    SourceConfiguration? source,
    int bytes,
    int partCount,
  ) {
    return SboxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SectionTitle(title: '保存目标', subtitle: '本地目录永久保存 SBOX 原始密文'),
          const SizedBox(height: 16),
          DropdownButtonFormField<SourceId>(
            initialValue: source?.sourceId,
            decoration: const InputDecoration(labelText: '数据源'),
            items: widget.controller.sources
                .map(
                  (item) => DropdownMenuItem<SourceId>(
                    value: item.sourceId,
                    child: Text(
                      '${item.displayName}${item.isWritable ? '' : '（只读）'}',
                    ),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value != null) widget.controller.selectSource(value);
            },
          ),
          const SizedBox(height: 12),
          _DetailLine(
            icon: Icons.folder_outlined,
            label: '本地 SBOX 同步目录',
            value: source?.localSyncPath ?? '尚未选择',
          ),
          const SizedBox(height: 10),
          _DetailLine(
            icon: Icons.segment_rounded,
            label: '预计密文分片',
            value: '$partCount 个 · 有效明文边界 16 MiB',
          ),
          const SizedBox(height: 10),
          _DetailLine(
            icon: source?.isRemote == true
                ? Icons.cloud_upload_outlined
                : Icons.wifi_off_rounded,
            label: source?.isRemote == true ? '提交行为' : '网络行为',
            value: source?.isRemote == true ? '本地加密后可上传密文' : '完全离线，不会上传',
          ),
          const SizedBox(height: 12),
          StatusPill(
            label: source == null
                ? '未选择目标'
                : (source.isWritable ? '目标可写' : '目标只读'),
            icon: source?.isWritable == true
                ? Icons.check_circle_outline
                : Icons.info_outline,
            tone: source?.isWritable == true
                ? SboxColors.success
                : SboxColors.warning,
          ),
        ],
      ),
    );
  }

  Widget _cryptoSummary(BuildContext context, int bytes, int partCount) {
    return SboxCard(
      color: const Color(0xFF0E1C29),
      child: Row(
        children: <Widget>[
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: SboxColors.accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.enhanced_encryption_outlined,
              color: SboxColors.accent,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'SBOX v1 固定密码套件',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 5),
                Text(
                  'RSA-3072 OAEP-SHA256 封装随机 DEK · AES-256-GCM 记录认证 · 每片独立 DEK/File ID/Nonce',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              MonospaceValue(
                widget.controller.shortFingerprint,
                color: SboxColors.accent,
              ),
              const SizedBox(height: 5),
              Text(
                '${_formatBytes(bytes)} · $partCount ${partCount == 1 ? '个 SBOX' : '个完整 SBOX 分片'}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ModeTab extends StatelessWidget {
  const _ModeTab({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: Container(
      constraints: const BoxConstraints(minWidth: 108, minHeight: 44),
      padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 11),
      decoration: BoxDecoration(
        color: selected
            ? SboxColors.accent.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected
              ? SboxColors.accent.withValues(alpha: 0.35)
              : Colors.transparent,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            icon,
            size: 18,
            color: selected ? SboxColors.accent : SboxColors.textMuted,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: selected ? SboxColors.text : SboxColors.textMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    ),
  );
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Icon(icon, size: 18, color: SboxColors.textMuted),
      const SizedBox(width: 9),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              label,
              style: const TextStyle(color: SboxColors.textDim, fontSize: 11),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: SboxColors.text, fontSize: 12),
            ),
          ],
        ),
      ),
    ],
  );
}

String _baseName(String value) {
  final dot = value.lastIndexOf('.');
  return dot > 0 ? value.substring(0, dot) : value;
}

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
