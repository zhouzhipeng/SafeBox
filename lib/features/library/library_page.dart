import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../app/app_controller.dart';
import '../../app/app_logger.dart';
import '../../app/sbox_theme.dart';
import '../../app/sbox_widgets.dart';
import '../../platform/cloud_backup_configuration_store.dart';
import '../../platform/file_opener.dart';
import '../../platform/secure_credential_store.dart';
import '../../platform/temporary_plaintext_platform.dart';
import '../../sbox/constants.dart';
import '../../sbox/engine/bundle_probe.dart';
import '../../sbox/engine/bundle_encryptor.dart';
import '../../sbox/format/bundle_manifest.dart';
import '../../sbox/identity/public_identity_record.dart';
import '../../sbox/source/bundle_listing.dart';
import '../../sbox/source/bundle_sync.dart';
import '../../sbox/source/cloud_backup_config.dart';
import '../../sbox/source/cloud_bundle_uploader.dart';
import '../../sbox/source/cloud_repository_pair.dart';
import '../../sbox/source/data_source.dart';
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
  static const List<_PreviewFile> _previewFiles = <_PreviewFile>[
    _PreviewFile(
      name: '项目资料.pdf',
      time: '今天 14:30',
      type: 'PDF',
      color: Color(0xFFFF4E42),
    ),
    _PreviewFile(
      name: '照片.zip',
      time: '今天 10:18',
      type: 'ZIP',
      color: Color(0xFFFFB52E),
    ),
    _PreviewFile(
      name: '合同.docx',
      time: '昨天 16:45',
      type: 'W\nDOCX',
      color: Color(0xFF2E86F3),
    ),
  ];

  final _configurationStore = CloudBackupConfigurationStore();
  final _credentialStore = PlatformCredentialStore();
  final _temporaryStore = TemporaryPlaintextStore();
  final _searchController = TextEditingController();
  List<_LibraryBundle> _bundles = const <_LibraryBundle>[];
  http.Client? _client;
  CloudBackupConfiguration? _configuration;
  XFile? _selectedFile;
  int? _selectedFileLength;
  bool _credentialsReady = false;
  bool _busy = true;
  bool _loading = true;
  bool _dragging = false;
  bool _showPreview = true;
  String _busyTitle = '正在读取文件';
  String _busyDetail = '正在同步你的安全文件。';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
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
                  PageHeading(
                    title: '云端文件',
                    subtitle: '上传、查看和打开文件都在这里',
                    trailing: mobile
                        ? StatusPill(
                            label: _cloudStatus,
                            icon: Icons.cloud_upload_outlined,
                            tone: _cloudReady
                                ? SboxColors.accent
                                : SboxColors.warning,
                            compact: true,
                          )
                        : null,
                  ),
                  SizedBox(height: mobile ? 28 : 38),
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

  bool get _cloudReady => _configuration != null && _credentialsReady;

  String get _cloudStatus => _cloudReady ? '云端同步已开启' : '云端同步未设置';

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
            Text(
              _selectedFile == null
                  ? '文件会自动安全保存'
                  : '${_formatBytes(_selectedFileLength ?? 0)} · 点击可更换文件',
              style: Theme.of(context).textTheme.bodyLarge
                  ?.copyWith(color: SboxColors.textMuted),
              textAlign: TextAlign.center,
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child: Text(
                  '我的文件',
                  style: Theme.of(context).textTheme.headlineMedium
                      ?.copyWith(fontSize: mobile ? 25 : 27),
                ),
              ),
              Flexible(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: StatusPill(
                    label: '${rows.length} 个文件 · 已安全保存',
                    icon: Icons.verified_user_outlined,
                    tone: SboxColors.accent,
                    compact: true,
                  ),
                ),
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
            SboxProgressCard(title: _busyTitle, detail: _busyDetail)
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
                ],
              ),
            ),
          );
          final action = OutlinedButton.icon(
            onPressed: _busy ? null : () => _openRow(row),
            icon: Icon(
              mobile ? Icons.open_in_new : Icons.download_outlined,
              size: mobile ? 20 : 22,
            ),
            label: Text(mobile ? '打开' : '下载并打开'),
          );
          final status = Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.verified_user_rounded,
                color: SboxColors.accent,
                size: 25,
              ),
              const SizedBox(width: 7),
              Text(
                '已保护',
                style: TextStyle(
                  color: SboxColors.accent,
                  fontSize: mobile ? 15 : 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          );
          if (narrow) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                FileTypeBadge(type: row.type, color: row.color),
                details,
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    status,
                    const SizedBox(height: 10),
                    action,
                  ],
                ),
              ],
            );
          }
          return Row(
            children: <Widget>[
              FileTypeBadge(type: row.type, color: row.color),
              details,
              const SizedBox(width: 18),
              status,
              const SizedBox(width: 48),
              action,
            ],
          );
        },
      ),
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
    final source = _showPreview
        ? _previewFiles
              .map(
                (file) => _FileRow(
                  name: file.name,
                  time: file.time,
                  type: file.type,
                  color: file.color,
                  preview: true,
                ),
              )
              .toList(growable: false)
        : _bundles.map(_rowForBundle).toList(growable: false);
    if (query.isEmpty) return source;
    return source
        .where((file) => file.name.toLowerCase().contains(query))
        .toList(growable: false);
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
      bundle: bundle,
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
        _showPreview = configuration == null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _showPreview = true;
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
          _showPreview = true;
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
      final byPath = <String, _LibraryBundle>{};
      for (final root in listed[0] ?? const <ListedBundleRoot>[]) {
        byPath[root.path.value] = _LibraryBundle(
          root: root,
          source: pair.github,
          sourceName: 'GitHub',
        );
      }
      for (final root in listed[1] ?? const <ListedBundleRoot>[]) {
        byPath.putIfAbsent(
          root.path.value,
          () => _LibraryBundle(
            root: root,
            source: pair.gitee,
            sourceName: 'Gitee',
          ),
        );
      }
      if (!mounted) return;
      _client?.close();
      _client = client;
      nextClient = null;
      setState(() {
        _bundles = byPath.values.toList(growable: false);
        _showPreview = false;
        _busy = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _showPreview = false;
        });
        widget.controller.logger.warning(
          '读取云端文件失败',
          detail: AppLogger.describeError(error),
        );
        _showFeedback('暂时无法读取云端文件，请稍后重试。');
      }
    } finally {
      nextClient?.close();
    }
  }

  Future<List<ListedBundleRoot>?> _listSource(
    EnumerableDataSource source,
    String name,
  ) async {
    try {
      return await BundleListing.listRoots(source);
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
      _showFeedback('请选择一个文件。');
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
      _showFeedback('请先完成安全身份设置。');
      return;
    }
    if (configuration == null || !_credentialsReady) {
      _showFeedback('请先在设置中完成云端备份。');
      widget.onOpenCloudSettings?.call();
      return;
    }
    final sourceFile = File(file.path);
    if (!await sourceFile.exists()) {
      _showFeedback('找不到要上传的文件，请重新选择。');
      return;
    }
    setState(() {
      _busy = true;
      _busyTitle = '正在安全保存';
      _busyDetail = '文件正在加密并同步到云端，请稍候。';
    });
    try {
      final identity = PublicIdentityRecord(
        spkiDer: record.spkiDer,
        recipientKeyId: record.recipientKeyId,
      ).toPublicIdentity();
      final client = http.Client();
      try {
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
            mediaType: 'application/octet-stream',
            title: file.name.trim().isEmpty ? p.basename(file.path) : file.name,
          ),
          configuration: configuration,
        );
      } finally {
        client.close();
      }
      if (!mounted) return;
      setState(() {
        _selectedFile = null;
        _selectedFileLength = null;
        _busy = false;
      });
      _showFeedback('文件已安全保存。');
      await _scan();
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        widget.controller.setError(error, operation: '安全保存文件失败');
        _showFeedback('文件暂时没有保存成功，请稍后重试。');
      }
    }
  }

  Future<void> _openRow(_FileRow row) async {
    if (row.preview) {
      _showFeedback('这是预览文件；完成云端备份后即可打开你的文件。');
      return;
    }
    final bundle = row.bundle;
    if (bundle == null) return;
    if (bundle.manifest == null) {
      final mnemonic = await _askMnemonic();
      if (mnemonic == null || mnemonic.trim().isEmpty) return;
      await _authenticate(bundle, mnemonic);
      return;
    }
    await _open(bundle);
  }

  Future<void> _authenticate(_LibraryBundle bundle, String mnemonic) async {
    setState(() {
      _busy = true;
      _busyTitle = '正在准备文件';
      _busyDetail = '正在验证文件并准备打开。';
    });
    try {
      final read = await bundle.source.get(bundle.root.path);
      final bytes = await _read(read.body, read.length);
      final result = await BundleProbe.authenticateManifest(
        basename: bundle.root.path.value,
        objectPrefix: bytes,
        mnemonic: mnemonic,
      );
      final destination = await _ensurePlaintext(
        bundle: bundle,
        manifest: result.manifest!,
        mnemonic: mnemonic,
      );
      if (!mounted) return;
      setState(() {
        bundle.manifest = result.manifest;
        bundle.plaintextFile = destination;
        _busy = false;
      });
      await FileOpener.open(destination);
      _showFeedback('文件已准备好。');
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        widget.controller.setError(error, operation: '准备文件失败');
        _showFeedback('文件暂时无法打开，请检查恢复词后重试。');
      }
    }
  }

  Future<void> _open(_LibraryBundle bundle) async {
    final manifest = bundle.manifest;
    if (manifest == null) return;
    setState(() {
      _busy = true;
      _busyTitle = '正在准备文件';
      _busyDetail = '正在确认文件完整性。';
    });
    try {
      var destination = bundle.plaintextFile;
      if (destination == null ||
          !await _temporaryStore.matches(destination, manifest)) {
        final mnemonic = await _askMnemonic(
          title: '重新验证文件',
          actionLabel: '下载并打开',
        );
        if (mnemonic == null || mnemonic.trim().isEmpty) return;
        destination = await _ensurePlaintext(
          bundle: bundle,
          manifest: manifest,
          mnemonic: mnemonic,
        );
        if (mounted) bundle.plaintextFile = destination;
      }
      await FileOpener.open(destination);
      if (mounted) _showFeedback('文件已打开。');
    } catch (error) {
      if (mounted) {
        widget.controller.setError(error, operation: '打开文件失败');
        _showFeedback('文件暂时无法打开，请稍后重试。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<File> _ensurePlaintext({
    required _LibraryBundle bundle,
    required BundleManifest manifest,
    required String mnemonic,
  }) async {
    final destination = await _temporaryStore.fileFor(manifest);
    await TemporaryPlaintextPlatform.protectRoot(_temporaryStore.path);
    if (await _temporaryStore.matches(destination, manifest)) {
      return destination;
    }
    await _temporaryStore.deleteFile(destination);
    await BundleSync.fetchAndDecryptToFileStreaming(
      source: bundle.source,
      rootPath: bundle.root.path,
      mnemonic: mnemonic,
      destination: destination,
    );
    return destination;
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
            maxLines: 2,
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

  void _showFeedback(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  static Future<Uint8List> _read(Stream<List<int>> body, int length) async {
    final output = BytesBuilder(copy: false);
    var count = 0;
    await for (final chunk in body) {
      count += chunk.length;
      if (count > length) throw const FormatException('云端对象过长');
      output.add(chunk);
    }
    if (count != length) throw const FormatException('云端对象不完整');
    return output.takeBytes();
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MiB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
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

final class _PreviewFile {
  const _PreviewFile({
    required this.name,
    required this.time,
    required this.type,
    required this.color,
  });

  final String name;
  final String time;
  final String type;
  final Color color;
}

final class _FileRow {
  const _FileRow({
    required this.name,
    required this.time,
    required this.type,
    required this.color,
    this.bundle,
    this.preview = false,
  });

  final String name;
  final String time;
  final String type;
  final Color color;
  final _LibraryBundle? bundle;
  final bool preview;
}

final class _LibraryBundle {
  _LibraryBundle({
    required this.root,
    required this.source,
    required this.sourceName,
  });

  final ListedBundleRoot root;
  final DataSource source;
  final String sourceName;
  BundleManifest? manifest;
  File? plaintextFile;
}
