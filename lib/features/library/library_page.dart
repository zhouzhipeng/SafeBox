import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../app/app_controller.dart';
import '../../app/app_logger.dart';
import '../../app/sbox_feedback.dart';
import '../../app/sbox_theme.dart';
import '../../app/sbox_widgets.dart';
import '../../platform/cloud_backup_configuration_store.dart';
import '../../platform/file_opener.dart';
import '../../platform/flutter_video_poster_decoder.dart';
import '../../platform/preview_generation_result.dart';
import '../../platform/preview_generator.dart';
import '../../platform/secure_credential_store.dart';
import '../../platform/temporary_plaintext_platform.dart';
import '../../sbox/bytes.dart';
import '../../sbox/constants.dart';
import '../../sbox/engine/bundle_probe.dart';
import '../../sbox/engine/bundle_encryptor.dart';
import '../../sbox/errors.dart';
import '../../sbox/format/bundle_header.dart';
import '../../sbox/format/bundle_manifest.dart';
import '../../sbox/format/bundle_path.dart';
import '../../sbox/format/bundle_preview.dart';
import '../../sbox/identity/public_identity_record.dart';
import '../../sbox/source/bundle_listing.dart';
import '../../sbox/source/bundle_sync.dart';
import '../../sbox/source/cloud_backup_config.dart';
import '../../sbox/source/cloud_bundle_uploader.dart';
import '../../sbox/source/cloud_repository_pair.dart';
import '../../sbox/source/data_source.dart';
import '../../sbox/source/local_directory_source.dart';
import '../../sbox/storage/temporary_plaintext_store.dart';

final class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.controller,
    this.onOpenCloudSettings,
  });

  final AppController controller;
  final VoidCallback? onOpenCloudSettings;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

final class _LibraryPageState extends State<LibraryPage> {
  final _configurationStore = CloudBackupConfigurationStore();
  final _credentialStore = PlatformCredentialStore();
  final _temporaryStore = TemporaryPlaintextStore();
  final _searchController = TextEditingController();
  final _descriptionController = TextEditingController();
  List<_LibraryBundle> _bundles = const <_LibraryBundle>[];
  http.Client? _client;
  CloudBackupConfiguration? _configuration;
  XFile? _selectedFile;
  int? _selectedFileLength;
  bool _credentialsReady = false;
  bool _busy = true;
  bool _loading = true;
  bool _dragging = false;
  bool _generatePreview = true;
  _LibrarySource _selectedSource = _LibrarySource.github;
  String _busyTitle = '正在读取文件';
  String _busyDetail = '正在同步你的安全文件。';
  CloudBundleUploadProgress? _uploadProgress;
  BundleDownloadProgress? _downloadProgress;

  @override
  void initState() {
    super.initState();
    PaintingBinding.instance.imageCache.maximumSizeBytes =
        SboxProtocol.maxRetainedPreviewBytes;
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _descriptionController.clear();
    _descriptionController.dispose();
    _disposeBundlePreviews(_bundles);
    _client?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mobile = constraints.maxWidth < 760;
        final content = Padding(
          padding: EdgeInsets.fromLTRB(
            mobile ? 24 : 32,
            mobile ? 28 : 52,
            mobile ? 24 : 32,
            mobile ? 28 : 38,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1360),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (mobile)
                    _buildMobileContent(context)
                  else
                    _buildDesktopContent(context),
                  const SizedBox(height: 28),
                  _buildFooter(context),
                ],
              ),
            ),
          ),
        );
        return SingleChildScrollView(child: content);
      },
    );
  }

  Widget _buildDesktopContent(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(flex: 4, child: _buildUploadArea(context, false)),
        const SizedBox(width: 40),
        Expanded(flex: 8, child: _buildFilesCard(context, false)),
      ],
    );
  }

  Widget _buildMobileContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildUploadArea(context, true),
        const SizedBox(height: 34),
        _buildFilesCard(context, true),
      ],
    );
  }

  Widget _buildUploadArea(BuildContext context, bool mobile) {
    return _DashedDropTarget(
      dragging: _dragging,
      onDragEntered: () {
        if (!_busy && mounted) setState(() => _dragging = true);
      },
      onDragExited: () {
        if (mounted) setState(() => _dragging = false);
      },
      onDragDone: (files) async {
        if (_busy) return;
        if (mounted) setState(() => _dragging = false);
        if (files.isNotEmpty) await _setFile(files.first);
      },
      onTap: _busy ? null : _pickFile,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        constraints: BoxConstraints(minHeight: mobile ? 452 : 454),
        padding: EdgeInsets.symmetric(
          horizontal: mobile ? 22 : 18,
          vertical: mobile ? 38 : 30,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            _UploadFolderIcon(size: mobile ? 104 : 92),
            SizedBox(height: mobile ? 28 : 22),
            Text(
              _selectedFile == null ? '拖入文件或点击选择' : _selectedFile!.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontSize: mobile ? 25 : 22,
                color: SboxColors.text,
              ),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: mobile ? 292 : 250,
              child: ElevatedButton.icon(
                onPressed: _busy
                    ? null
                    : (_selectedFile == null ? _pickFile : _upload),
                icon: Icon(
                  _selectedFile == null
                      ? Icons.file_upload_outlined
                      : Icons.lock_outline,
                  size: 23,
                ),
                label: Text(_busy ? '正在准备' : '上传文件'),
              ),
            ),
            const SizedBox(height: 18),
            _buildFileSelectionHint(context),
            const SizedBox(height: 22),
            TextField(
              controller: _descriptionController,
              enabled: !_busy,
              minLines: 3,
              maxLines: 3,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                labelText: '附加信息（可选）',
                hintText: '为文件添加说明',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              value: _generatePreview,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _generatePreview = value),
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.image_outlined),
              subtitle: const Text('仅上传图片或视频时生效；持有完整公钥的人可以读取缩略图，完整文件仍需验证。'),
            ),
            if (_busy) ...<Widget>[
              const SizedBox(height: 18),
              Text(
                _busyTitle,
                style: const TextStyle(color: SboxColors.accent, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFileSelectionHint(BuildContext context) {
    final file = _selectedFile;
    final textStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
      color: _busy ? SboxColors.textDim : SboxColors.textMuted,
    );
    if (file == null) {
      return Text(
        '文件会自动安全保存',
        style: textStyle,
        textAlign: TextAlign.center,
      );
    }

    return TextButton(
      onPressed: _busy ? null : _pickFile,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        '${_formatBytes(BigInt.from(_selectedFileLength ?? 0))} · 点击可更换文件',
        style: textStyle,
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildFilesCard(BuildContext context, bool mobile) {
    final rows = _visibleRows;
    return SboxCard(
      padding: EdgeInsets.fromLTRB(
        mobile ? 16 : 22,
        mobile ? 22 : 25,
        mobile ? 16 : 22,
        mobile ? 0 : 0,
      ),
      radius: mobile ? 16 : 14,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (mobile)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '我的文件',
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(fontSize: 25),
                      ),
                    ),
                    _buildRefreshButton(),
                    const SizedBox(width: 8),
                    StatusPill(
                      label: '${rows.length} 个文件',
                      icon: Icons.verified_user_outlined,
                      tone: SboxColors.accent,
                      compact: true,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _buildSourceSwitcher(context, mobile: true),
              ],
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(
                  child: Text(
                    '我的文件',
                    style: Theme.of(context).textTheme.headlineMedium
                        ?.copyWith(fontSize: 27),
                  ),
                ),
                _buildRefreshButton(),
                const SizedBox(width: 12),
                _buildSourceSwitcher(context),
                const SizedBox(width: 14),
                StatusPill(
                  label: '${rows.length} 个文件 · 已安全保存',
                  icon: Icons.verified_user_outlined,
                  tone: SboxColors.accent,
                  compact: true,
                ),
              ],
            ),
          SizedBox(height: mobile ? 22 : 20),
          SizedBox(
            width: mobile ? double.infinity : 330,
            child: TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: '搜索文件',
                prefixIcon: Icon(Icons.search, size: 30),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          if (_busy && !_loading)
            SboxProgressCard(
              title: _busyTitle,
              detail: _busyDetail,
              value: _downloadProgress?.fraction ?? _uploadProgress?.fraction,
              progressLabel:
                  _downloadProgress?.overallLabel ??
                  _uploadProgress?.overallLabel,
            )
          else if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 42),
              child: Center(
                child: Column(
                  children: <Widget>[
                    const Icon(
                      Icons.folder_open_outlined,
                      color: SboxColors.textDim,
                      size: 40,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '没有找到文件',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 5),
                    const Text('试试其他名称，或上传一个新文件。'),
                  ],
                ),
              ),
            )
          else
            ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(14),
              ),
              child: Column(
                children: <Widget>[
                  for (var index = 0; index < rows.length; index++) ...<Widget>[
                    _buildFileRow(context, rows[index], mobile),
                    if (index != rows.length - 1)
                      const Divider(height: 1, color: SboxColors.borderSoft),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRefreshButton() {
    return Container(
      decoration: BoxDecoration(
        color: SboxColors.panelSoft,
        border: Border.all(color: SboxColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: IconButton(
        onPressed: _busy ? null : _scan,
        icon: const Icon(Icons.refresh_rounded),
        tooltip: '刷新',
        color: SboxColors.accent,
        disabledColor: SboxColors.textDim,
        iconSize: 24,
        padding: const EdgeInsets.all(10),
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      ),
    );
  }

  Widget _buildSourceSwitcher(BuildContext context, {bool mobile = false}) {
    return Semantics(
      label: '选择文件来源',
      child: Container(
        width: mobile ? double.infinity : null,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: SboxColors.backgroundDeep.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: SboxColors.border),
        ),
        child: Row(
          mainAxisSize: mobile ? MainAxisSize.max : MainAxisSize.min,
          children: <Widget>[
            if (mobile)
              Expanded(
                child: _buildSourceOption(
                  context,
                  source: _LibrarySource.github,
                  icon: Icons.code_outlined,
                  mobile: mobile,
                ),
              )
            else
              _buildSourceOption(
                context,
                source: _LibrarySource.github,
                icon: Icons.code_outlined,
                mobile: mobile,
              ),
            if (mobile)
              Expanded(
                child: _buildSourceOption(
                  context,
                  source: _LibrarySource.gitee,
                  icon: Icons.cloud_outlined,
                  mobile: mobile,
                ),
              )
            else
              _buildSourceOption(
                context,
                source: _LibrarySource.gitee,
                icon: Icons.cloud_outlined,
                mobile: mobile,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceOption(
    BuildContext context, {
    required _LibrarySource source,
    required IconData icon,
    required bool mobile,
  }) {
    final selected = _selectedSource == source;
    final color = selected ? SboxColors.accent : SboxColors.textMuted;
    final child = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      padding: EdgeInsets.symmetric(
        horizontal: mobile ? 12 : 14,
        vertical: mobile ? 9 : 8,
      ),
      decoration: BoxDecoration(
        color: selected ? SboxColors.accent.withValues(alpha: 0.14) : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: mobile ? MainAxisSize.max : MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 17, color: color),
          const SizedBox(width: 7),
          Text(
            source.label,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: '${source.label} 文件',
      child: InkWell(
        onTap: _busy
            ? null
            : () {
                if (_selectedSource == source || !mounted) return;
                setState(() => _selectedSource = source);
              },
        borderRadius: BorderRadius.circular(8),
        child: child,
      ),
    );
  }

  Widget _buildFileRow(BuildContext context, _FileRow row, bool mobile) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: mobile ? 6 : 14,
        vertical: mobile ? 18 : 20,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 570;
          final details = Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    row.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    semanticsLabel: row.name,
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontSize: mobile ? 17 : 18),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    row.time,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: SboxColors.textMuted,
                      fontSize: mobile ? 14 : 15,
                    ),
                  ),
                  if (row.bundle?.manifest != null) ...<Widget>[
                    const SizedBox(height: 5),
                    Text(
                      '原始大小：${_formatBytes(row.bundle!.manifest!.logicalPlaintextSize)}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: SboxColors.textMuted,
                        fontSize: mobile ? 13 : 14,
                      ),
                    ),
                  ],
                  if (row.bundle?.manifest?.description.isNotEmpty ??
                      false) ...<Widget>[
                    const SizedBox(height: 5),
                    Text(
                      '附加信息：${row.bundle!.manifest!.description}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: SboxColors.textMuted,
                        fontSize: mobile ? 13 : 14,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
          final actions = _buildRowActions(row, mobile);
          if (narrow) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                _buildRowLeading(context, row, mobile),
                details,
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[actions],
                ),
              ],
            );
          }
          return Row(
            children: <Widget>[
              _buildRowLeading(context, row, mobile),
              details,
              const SizedBox(width: 18),
              actions,
            ],
          );
        },
      ),
    );
  }

  Widget _buildRowLeading(BuildContext context, _FileRow row, bool mobile) {
    final preview = row.thumbnail;
    if (preview == null) {
      return FileTypeBadge(type: row.type, color: row.color);
    }
    final size = mobile ? 56.0 : 72.0;
    final fallback = FileTypeBadge(type: row.type, color: row.color);
    final isVideo =
        row.bundle?.manifest?.mediaType.toLowerCase().startsWith('video/') ??
        false;
    return Semantics(
      image: true,
      label: '快速缩略图预览；完整文件尚未验证',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Image.memory(
                preview.encodedBytesView,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                    .round(),
                cacheHeight: (size * MediaQuery.devicePixelRatioOf(context))
                    .round(),
                errorBuilder: (context, error, stackTrace) => fallback,
              ),
              if (isVideo)
                const Center(
                  child: IgnorePointer(
                    child: Icon(
                      Icons.play_circle_fill_rounded,
                      color: Colors.white,
                      size: 30,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRowActions(_FileRow row, bool mobile) {
    final buttonWidth = mobile ? null : 136.0;
    final buttons = switch (row.actionState) {
      _FileActionState.localPlaintext => <Widget>[
        SizedBox(
          width: buttonWidth,
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _openPlaintext(row),
            icon: Icon(Icons.open_in_new, size: mobile ? 20 : 22),
            label: const Text('打开文件'),
          ),
        ),
        SizedBox(
          width: buttonWidth,
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _openPlaintextFolder(row),
            icon: Icon(Icons.folder_open_outlined, size: mobile ? 20 : 22),
            label: const Text('打开文件夹'),
          ),
        ),
      ],
      _FileActionState.localEncrypted => <Widget>[
        SizedBox(
          width: buttonWidth,
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _decryptLocal(row),
            icon: Icon(Icons.lock_open_outlined, size: mobile ? 20 : 22),
            label: const Text('解密文件'),
          ),
        ),
      ],
      _FileActionState.remoteOnly => <Widget>[
        SizedBox(
          width: buttonWidth,
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _downloadAndDecrypt(row),
            icon: Icon(Icons.download_outlined, size: mobile ? 20 : 22),
            label: const Text('下载并解密'),
          ),
        ),
      ],
    };
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: buttons,
    );
  }

  Widget _buildFooter(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        const Icon(Icons.lock_outline, color: SboxColors.textMuted, size: 24),
        const SizedBox(width: 10),
        Text(
          '所有文件均经过加密，安全存储在云端',
          style: Theme.of(context).textTheme.bodyLarge
              ?.copyWith(color: SboxColors.textMuted),
        ),
      ],
    );
  }

  List<_FileRow> get _visibleRows {
    final query = _searchController.text.trim().toLowerCase();
    final source =
        _bundles
            .where((bundle) => bundle.sourceName == _selectedSource.label)
            .map(_rowForBundle)
            .toList()
          ..sort(_compareFileRowsByCreatedAt);
    if (query.isEmpty) return source;
    return source
        .where((file) {
          final description = file.bundle?.manifest?.description;
          return file.name.toLowerCase().contains(query) ||
              (description != null &&
                  description.toLowerCase().contains(query));
        })
        .toList(growable: false);
  }

  static int _compareFileRowsByCreatedAt(_FileRow left, _FileRow right) {
    final leftCreatedAt = left.bundle?.manifest?.createdAt;
    final rightCreatedAt = right.bundle?.manifest?.createdAt;
    final leftDate = leftCreatedAt == null
        ? null
        : DateTime.tryParse(leftCreatedAt);
    final rightDate = rightCreatedAt == null
        ? null
        : DateTime.tryParse(rightCreatedAt);

    if (leftDate == null && rightDate == null) {
      return _compareFileRowsByPath(left, right);
    }
    if (leftDate == null) return 1;
    if (rightDate == null) return -1;

    final byCreatedAt = rightDate.compareTo(leftDate);
    return byCreatedAt != 0 ? byCreatedAt : _compareFileRowsByPath(left, right);
  }

  static int _compareFileRowsByPath(_FileRow left, _FileRow right) {
    final leftPath = left.bundle?.root.path.value ?? '';
    final rightPath = right.bundle?.root.path.value ?? '';
    return leftPath.compareTo(rightPath);
  }

  _FileRow _rowForBundle(_LibraryBundle bundle) {
    final manifest = bundle.manifest;
    final name = manifest?.originalName ?? '安全文件';
    final extension = p.extension(name).replaceFirst('.', '').toUpperCase();
    final type = extension.isEmpty ? 'FILE' : extension;
    final color = switch (extension) {
      'PDF' => const Color(0xFFFF4E42),
      'ZIP' || 'RAR' || '7Z' => const Color(0xFFFFB52E),
      'DOC' || 'DOCX' => const Color(0xFF2E86F3),
      _ => SboxColors.accentStrong,
    };
    final date = manifest == null ? '已同步' : _formatDate(manifest.createdAt);
    return _FileRow(
      name: name,
      time: date,
      type: type,
      color: color,
      actionState: bundle.actionState,
      bundle: bundle,
      thumbnail: bundle.preview,
    );
  }

  Future<void> _load() async {
    await _loadConfiguration();
    await _scan();
  }

  Future<void> _loadConfiguration() async {
    try {
      final configuration = await _configurationStore.load();
      var credentialsReady = false;
      if (configuration != null) {
        final github = await _credentialStore.getAccessToken(
          configuration.github.credentialId,
        );
        final gitee = await _credentialStore.getAccessToken(
          configuration.gitee.credentialId,
        );
        credentialsReady = github != null && gitee != null;
        github?.dispose();
        gitee?.dispose();
      }
      if (!mounted) return;
      setState(() {
        _configuration = configuration;
        _credentialsReady = credentialsReady;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
      widget.controller.logger.warning(
        '读取云端配置失败',
        detail: AppLogger.describeError(error),
      );
    }
  }

  Future<void> _scan() async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _busyTitle = '正在读取文件';
      _busyDetail = '正在同步你的安全文件。';
    });
    final configuration = _configuration ?? await _configurationStore.load();
    if (configuration == null) {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
      return;
    }
    http.Client? nextClient;
    try {
      final client = http.Client();
      nextClient = client;
      final pair = CloudRepositoryPair.fromConfiguration(
        configuration: configuration,
        client: client,
        logger: widget.controller.logger,
      );
      final listed = await Future.wait<List<ListedBundleRoot>?>(
        <Future<List<ListedBundleRoot>?>>[
          _listSource(pair.github, 'GitHub'),
          _listSource(pair.gitee, 'Gitee'),
        ],
      );
      final bundles = <_LibraryBundle>[];
      for (final root in listed[0] ?? const <ListedBundleRoot>[]) {
        bundles.add(
          _LibraryBundle(
            root: root,
            source: pair.github,
            sourceName: 'GitHub',
            manifest: root.manifest,
            preview: root.preview,
            hasPreview: root.hasPreview,
            status: root.status,
          ),
        );
      }
      for (final root in listed[1] ?? const <ListedBundleRoot>[]) {
        bundles.add(
          _LibraryBundle(
            root: root,
            source: pair.gitee,
            sourceName: 'Gitee',
            manifest: root.manifest,
            preview: root.preview,
            hasPreview: root.hasPreview,
            status: root.status,
          ),
        );
      }
      await _hydrateLocalState(bundles, configuration.backupDirectory);
      if (!mounted) {
        _disposeBundlePreviews(bundles);
        return;
      }
      final previousBundles = _bundles;
      _client?.close();
      _client = client;
      nextClient = null;
      setState(() {
        _bundles = List<_LibraryBundle>.unmodifiable(bundles);
        _busy = false;
      });
      _disposeBundlePreviews(previousBundles);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
        });
        widget.controller.logger.warning(
          '读取云端文件失败',
          detail: AppLogger.describeError(error),
        );
        _showFeedback('暂时无法读取云端文件，请稍后重试。', error: true);
      }
    } finally {
      nextClient?.close();
    }
  }

  static void _disposeBundlePreviews(Iterable<_LibraryBundle> bundles) {
    final disposed = <BundlePreview>{};
    for (final bundle in bundles) {
      final preview = bundle.preview;
      if (preview != null && disposed.add(preview)) preview.dispose();
    }
  }

  Future<void> _hydrateLocalState(
    Iterable<_LibraryBundle> bundles,
    String backupDirectory,
  ) async {
    for (final bundle in bundles) {
      bundle.encryptedBackupAvailable = await _hasLocalEncryptedBundle(
        bundle.root.header,
        backupDirectory,
      );
      final manifest = bundle.manifest;
      if (manifest == null) continue;
      try {
        final plaintext = await _temporaryStore.fileFor(manifest);
        if (await _temporaryStore.matches(plaintext, manifest)) {
          bundle.plaintextFile = plaintext;
        }
      } on Object catch (error) {
        widget.controller.logger.warning(
          '读取本地明文状态失败',
          detail: AppLogger.describeError(error),
        );
      }
    }
  }

  static Future<bool> _hasLocalEncryptedBundle(
    BundleHeader header,
    String backupDirectory,
  ) async {
    try {
      final root = Directory(backupDirectory);
      if (await FileSystemEntity.type(root.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return false;
      }
      for (var index = 0; index < header.shardCount; index++) {
        final basename = canonicalBundleBasename(
          bundleId: header.bundleId,
          shardIndex: index,
          shardCount: header.shardCount,
        );
        final file = File(p.join(root.path, basename));
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
          return false;
        }
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  Future<List<ListedBundleRoot>?> _listSource(
    EnumerableDataSource source,
    String name,
  ) async {
    try {
      final record = widget.controller.identityRecord;
      final identity = record?.toPublicIdentity();
      return await BundleListing.listRoots(source, identity: identity);
    } catch (error) {
      widget.controller.logger.warning(
        '$name：读取云端文件失败',
        detail: AppLogger.describeError(error),
      );
      return null;
    }
  }

  Future<void> _pickFile() async {
    final file = await openFile(confirmButtonText: '选择');
    if (file != null) await _setFile(file);
  }

  Future<void> _setFile(XFile file) async {
    final path = file.path.trim();
    if (path.isEmpty ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file) {
      _showFeedback('请选择一个文件。', error: true);
      return;
    }
    final length = await File(path).length();
    if (!mounted) return;
    setState(() {
      _selectedFile = file;
      _selectedFileLength = length;
    });
  }

  Future<void> _upload() async {
    final file = _selectedFile;
    final record = widget.controller.identityRecord;
    final configuration = _configuration;
    if (file == null) {
      await _pickFile();
      return;
    }
    if (record == null) {
      _showFeedback('请先完成安全身份设置。', error: true);
      return;
    }
    if (configuration == null || !_credentialsReady) {
      _showFeedback('请先在设置中完成云端备份。', error: true);
      widget.onOpenCloudSettings?.call();
      return;
    }
    final sourceFile = File(file.path);
    if (!await sourceFile.exists()) {
      _showFeedback('找不到要上传的文件，请重新选择。', error: true);
      return;
    }
    setState(() {
      _busy = true;
      _busyTitle = '正在安全保存';
      _busyDetail = '文件正在加密并同步到云端，请稍候。';
      _uploadProgress = null;
      _downloadProgress = null;
    });
    BundlePreview? preview;
    PreviewUnavailableReason? previewUnavailableReason;
    var mediaType = 'application/octet-stream';
    try {
      if (_generatePreview) {
        final generated = await const PlatformPreviewGenerator(
          videoPosterDecoder: FlutterVideoPosterDecoder(),
        ).generate(sourceFile);
        switch (generated) {
          case PreviewGenerated(
            preview: final generatedPreview,
            detectedSourceMediaType: final detected,
          ):
            preview = generatedPreview;
            mediaType = detected;
          case PreviewUnavailable(
            reason: final reason,
            detectedSourceMediaType: final detected,
          ):
            previewUnavailableReason = reason;
            if (detected != null) mediaType = detected;
        }
      } else {
        previewUnavailableReason = PreviewUnavailableReason.userDisabled;
      }
      final identity = PublicIdentityRecord(
        spkiDer: record.spkiDer,
        recipientKeyId: record.recipientKeyId,
      ).toPublicIdentity();
      final client = http.Client();
      late final CloudBundleUploadResult uploadResult;
      try {
        uploadResult =
            await CloudBundleUploader(
              credentialStore: _credentialStore,
              client: client,
              logger: widget.controller.logger,
            ).upload(
              input: FileBundleInput(sourceFile),
              declaredLength: await sourceFile.length(),
              options: BundleEncryptionOptions(
                recipient: identity,
                contentKind: SboxContentKind.file,
                originalName: file.name.trim().isEmpty
                    ? p.basename(file.path)
                    : file.name,
                mediaType: mediaType,
                title: file.name.trim().isEmpty
                    ? p.basename(file.path)
                    : file.name,
                description: _descriptionController.text,
                preview: preview,
                previewRequested: _generatePreview,
                previewUnavailableReason: previewUnavailableReason,
              ),
              configuration: configuration,
              onProgress: _handleUploadProgress,
            );
      } finally {
        client.close();
      }
      if (!mounted) return;
      setState(() {
        _selectedFile = null;
        _selectedFileLength = null;
        _descriptionController.clear();
        _busy = false;
        _uploadProgress = null;
        _downloadProgress = null;
      });
      _showFeedback(
        uploadResult.previewEmbedded
            ? '文件已安全保存，并已生成加密缩略图。'
            : '文件已安全保存，但未生成缩略图（${_previewReasonLabel(uploadResult.previewUnavailableReason!)}）。',
      );
      await _scan();
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _uploadProgress = null;
          _downloadProgress = null;
        });
        widget.controller.setError(error, operation: '安全保存文件失败');
        final message = error is SboxException
            ? error.message
            : '发生未知错误，请稍后重试。';
        _showFeedback('上传失败：$message', error: true);
      }
    } finally {
      preview?.dispose();
    }
  }

  static String _previewReasonLabel(PreviewUnavailableReason reason) {
    return switch (reason) {
      PreviewUnavailableReason.userDisabled => '用户已关闭预览',
      PreviewUnavailableReason.unsupportedMediaType => '格式不支持',
      PreviewUnavailableReason.platformUnsupported => '当前平台不支持此媒体',
      PreviewUnavailableReason.decodeFailed => '媒体解码失败',
      PreviewUnavailableReason.encodeFailed => '缩略图编码失败',
      PreviewUnavailableReason.timeout => '生成超时',
      PreviewUnavailableReason.resourceLimit => '资源限制',
      PreviewUnavailableReason.metadataCapacity => '元数据空间不足',
      PreviewUnavailableReason.existingV30 => '复用旧版安全文件',
      PreviewUnavailableReason.existingV31WithoutPreview => '复用的文件没有缩略图',
      PreviewUnavailableReason.inputChanged => '输入文件发生变化',
    };
  }

  void _handleUploadProgress(CloudBundleUploadProgress progress) {
    if (!mounted) return;
    setState(() {
      _uploadProgress = progress;
      _busyTitle = switch (progress.stage) {
        CloudBundleUploadStage.preparing => '正在准备上传',
        CloudBundleUploadStage.uploading => '正在上传加密分片',
        CloudBundleUploadStage.verifying => '正在核对云端分片',
        CloudBundleUploadStage.completed => '上传完成，正在收尾',
      };
      _busyDetail = progress.detailLabel;
    });
  }

  void _handleDownloadProgress(BundleDownloadProgress progress) {
    if (!mounted) return;
    setState(() {
      _downloadProgress = progress;
      _busyTitle = switch (progress.stage) {
        BundleDownloadStage.preparing => '正在读取文件信息',
        BundleDownloadStage.downloading => '正在下载加密文件',
        BundleDownloadStage.decrypting => '正在校验并解密',
      };
      _busyDetail = progress.detailLabel;
    });
  }

  Future<void> _decryptLocal(_FileRow row) async {
    final bundle = row.bundle;
    if (bundle == null) return;
    final configuration = _configuration ?? await _configurationStore.load();
    if (configuration == null) {
      _showFeedback('未找到本地加密备份，请使用下载并解密。', error: true);
      return;
    }
    final mnemonic = await _askMnemonic(title: '解密文件', actionLabel: '解密文件');
    if (mnemonic == null || mnemonic.trim().isEmpty) return;
    if (!mounted) return;
    setState(() {
      _busy = true;
      _busyTitle = '正在解密文件';
      _busyDetail = '正在从本地加密备份恢复文件，请稍候。';
      _downloadProgress = null;
    });
    try {
      final source = await LocalDirectoryDataSource.attach(
        root: Directory(configuration.backupDirectory),
        mode: LocalDirectoryMode.readOnly,
        requestWrite: false,
      );
      final decrypted = await BundleSync.fetchAndDecrypt(
        source: source,
        rootPath: bundle.root.path,
        mnemonic: mnemonic,
        expectedIdentity: widget.controller.identityRecord?.toPublicIdentity(),
        onProgress: _handleDownloadProgress,
      );
      final destination = await _cacheDecrypted(
        manifest: decrypted.manifest,
        plaintext: decrypted.plaintext,
      );
      if (!mounted) return;
      setState(() {
        bundle.manifest = decrypted.manifest;
        _adoptPreview(bundle, decrypted.preview);
        bundle.status = decrypted.status;
        bundle.plaintextFile = destination;
        bundle.encryptedBackupAvailable = true;
      });
      _showFeedback('文件已解密，可以打开文件或文件夹。');
    } catch (error) {
      if (mounted) {
        widget.controller.setError(error, operation: '解密文件失败');
        _showFeedback('文件暂时无法解密，请检查本地备份和恢复词。', error: true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _downloadProgress = null;
        });
      }
    }
  }

  Future<void> _openPlaintext(_FileRow row) async {
    final bundle = row.bundle;
    final plaintext = bundle?.plaintextFile;
    if (bundle == null || plaintext == null) {
      _showFeedback('本地明文不存在，请先解密文件或下载并解密。', error: true);
      return;
    }
    try {
      await FileOpener.open(plaintext);
      if (mounted) _showFeedback('文件已打开。');
    } catch (error) {
      if (mounted) {
        widget.controller.setError(error, operation: '打开文件失败');
        _showFeedback('文件暂时无法打开，请稍后重试。', error: true);
      }
    }
  }

  Future<void> _openPlaintextFolder(_FileRow row) async {
    final bundle = row.bundle;
    final plaintext = bundle?.plaintextFile;
    if (bundle == null || plaintext == null) {
      _showFeedback('本地明文不存在，请先解密文件或下载并解密。', error: true);
      return;
    }
    try {
      await FileOpener.openDirectory(Directory(p.dirname(plaintext.path)));
      if (mounted) _showFeedback('文件夹已打开。');
    } catch (error) {
      if (mounted) {
        widget.controller.setError(error, operation: '打开文件夹失败');
        _showFeedback('文件夹暂时无法打开，请稍后重试。', error: true);
      }
    }
  }

  Future<void> _downloadAndDecrypt(_FileRow row) async {
    final bundle = row.bundle;
    if (bundle == null) return;
    final mnemonic = await _askMnemonic(
      title: '下载并解密文件',
      actionLabel: '下载并解密',
    );
    if (mnemonic == null || mnemonic.trim().isEmpty) return;
    if (!mounted) return;
    setState(() {
      _busy = true;
      _busyTitle = '正在下载并解密';
      _busyDetail = '正在下载、校验并保存解密后的文件，请稍候。';
      _downloadProgress = null;
    });
    try {
      final decrypted = await BundleSync.fetchAndDecrypt(
        source: bundle.source,
        rootPath: bundle.root.path,
        mnemonic: mnemonic,
        expectedIdentity: widget.controller.identityRecord?.toPublicIdentity(),
        onProgress: _handleDownloadProgress,
      );
      final destination = await _cacheDecrypted(
        manifest: decrypted.manifest,
        plaintext: decrypted.plaintext,
      );
      if (!mounted) return;
      setState(() {
        bundle.manifest = decrypted.manifest;
        _adoptPreview(bundle, decrypted.preview);
        bundle.status = decrypted.status;
        bundle.plaintextFile = destination;
      });
      _showFeedback('文件已下载并解密，可以打开文件或文件夹。');
    } catch (error) {
      if (mounted) {
        widget.controller.setError(error, operation: '下载并解密文件失败');
        _showFeedback('文件暂时无法下载并解密，请检查恢复词后重试。', error: true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _downloadProgress = null;
        });
      }
    }
  }

  Future<File> _cacheDecrypted({
    required BundleManifest manifest,
    required Uint8List plaintext,
  }) async {
    final destination = await _temporaryStore.fileFor(manifest);
    await TemporaryPlaintextPlatform.protectRoot(_temporaryStore.path);
    if (await _temporaryStore.matches(destination, manifest)) {
      plaintext.fillRange(0, plaintext.length, 0);
      return destination;
    }
    await _temporaryStore.deleteFile(destination);
    final stage = File(
      '${destination.path}.${hexLower(secureRandomBytes(8))}.part',
    );
    var renamed = false;
    try {
      await stage.writeAsBytes(plaintext, flush: true);
      await stage.rename(destination.path);
      renamed = true;
      return destination;
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
      if (!renamed && await stage.exists()) await stage.delete();
    }
  }

  static void _adoptPreview(_LibraryBundle bundle, BundlePreview? preview) {
    if (preview == null) return;
    final previous = bundle.preview;
    if (previous != null && !identical(previous, preview)) previous.dispose();
    bundle.preview = preview;
    bundle.hasPreview = true;
  }

  Future<String?> _askMnemonic({
    String title = '验证文件',
    String actionLabel = '打开',
  }) async {
    final input = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: input,
            autofocus: true,
            obscureText: true,
            maxLines: 1,
            decoration: const InputDecoration(labelText: '输入 12 个恢复词'),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(input.text),
              child: Text(actionLabel),
            ),
          ],
        ),
      );
    } finally {
      input.clear();
      input.dispose();
    }
  }

  void _showFeedback(String message, {bool error = false}) {
    if (!mounted) return;
    showSboxFeedback(context, message, error: error);
  }

  static String _formatBytes(BigInt bytes) {
    final kib = BigInt.from(1024);
    final mib = kib * kib;
    final gib = mib * kib;
    if (bytes >= gib) {
      return '${(bytes.toDouble() / gib.toDouble()).toStringAsFixed(2)} GiB';
    }
    if (bytes >= mib) {
      return '${(bytes.toDouble() / mib.toDouble()).toStringAsFixed(2)} MiB';
    }
    if (bytes >= kib) {
      return '${(bytes.toDouble() / kib.toDouble()).toStringAsFixed(1)} KiB';
    }
    return '$bytes B';
  }

  static String _formatDate(String value) {
    final local = DateTime.tryParse(value)?.toLocal();
    if (local == null) return '已同步';
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.month}月${local.day}日 ${two(local.hour)}:${two(local.minute)}';
  }
}

final class _DashedDropTarget extends StatelessWidget {
  const _DashedDropTarget({
    required this.child,
    required this.dragging,
    required this.onTap,
    required this.onDragEntered,
    required this.onDragExited,
    required this.onDragDone,
  });

  final Widget child;
  final bool dragging;
  final VoidCallback? onTap;
  final VoidCallback onDragEntered;
  final VoidCallback onDragExited;
  final ValueChanged<List<XFile>> onDragDone;

  @override
  Widget build(BuildContext context) {
    final target = DropTarget(
      onDragEntered: (_) => onDragEntered(),
      onDragExited: (_) => onDragExited(),
      onDragDone: (detail) => onDragDone(detail.files),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: CustomPaint(
          painter: _DashedBorderPainter(
            color: dragging ? SboxColors.accent : SboxColors.border,
            radius: 14,
            dash: 8,
            gap: 6,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: dragging
                  ? SboxColors.accent.withValues(alpha: 0.06)
                  : SboxColors.panelSoft.withValues(alpha: 0.62),
              borderRadius: BorderRadius.circular(14),
            ),
            child: child,
          ),
        ),
      ),
    );
    return target;
  }
}

final class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({
    required this.color,
    required this.radius,
    required this.dash,
    required this.gap,
  });

  final Color color;
  final double radius;
  final double dash;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.82)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      );
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + dash).clamp(0, metric.length).toDouble();
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color;
}

final class _UploadFolderIcon extends StatelessWidget {
  const _UploadFolderIcon({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size * 0.76,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Icon(
            Icons.folder_rounded,
            color: SboxColors.accentStrong,
            size: size,
          ),
          Positioned(
            top: size * 0.2,
            child: Icon(
              Icons.arrow_upward_rounded,
              color: const Color(0xFF075F59),
              size: size * 0.48,
            ),
          ),
        ],
      ),
    );
  }
}

final class _FileRow {
  const _FileRow({
    required this.name,
    required this.time,
    required this.type,
    required this.color,
    required this.actionState,
    this.bundle,
    this.thumbnail,
  });

  final String name;
  final String time;
  final String type;
  final Color color;
  final _FileActionState actionState;
  final _LibraryBundle? bundle;
  final BundlePreview? thumbnail;
}

final class _LibraryBundle {
  _LibraryBundle({
    required this.root,
    required this.source,
    required this.sourceName,
    this.manifest,
    this.preview,
    bool? hasPreview,
    this.status = BundleTrustStatus.headerOnly,
  }) : hasPreview = hasPreview ?? preview != null;

  final ListedBundleRoot root;
  final DataSource source;
  final String sourceName;
  BundleManifest? manifest;
  BundlePreview? preview;
  bool hasPreview;
  BundleTrustStatus status;
  File? plaintextFile;
  bool encryptedBackupAvailable = false;

  _FileActionState get actionState {
    if (plaintextFile != null) return _FileActionState.localPlaintext;
    if (encryptedBackupAvailable) return _FileActionState.localEncrypted;
    return _FileActionState.remoteOnly;
  }
}

enum _FileActionState { localPlaintext, localEncrypted, remoteOnly }

enum _LibrarySource {
  github('GitHub'),
  gitee('Gitee');

  const _LibrarySource(this.label);

  final String label;
}
