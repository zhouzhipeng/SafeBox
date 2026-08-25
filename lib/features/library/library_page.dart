import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show PointerDeviceKind;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../app/app_controller.dart';
import '../../app/app_logger.dart';
import '../../app/sbox_feedback.dart';
import '../../app/sbox_theme.dart';
import '../../app/sbox_widgets.dart';
import '../../platform/cloud_backup_configuration_store.dart';
import '../../platform/browser_download.dart';
import '../../platform/file_opener.dart';
import '../../platform/flutter_video_poster_decoder.dart';
import '../../platform/preview_generation_result.dart';
import '../../platform/preview_generator.dart';
import '../../platform/secure_credential_store.dart';
import '../../platform/temporary_plaintext_platform.dart';
import '../../platform/video_poster_decoder.dart';
import '../../platform/web_runtime_limits.dart';
import '../../sbox/bytes.dart';
import '../../sbox/constants.dart';
import '../../sbox/engine/bundle_decryptor.dart';
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
import '../../sbox/source/credential.dart';
import '../../sbox/source/data_source.dart';
import '../../sbox/source/local_directory_source.dart';
import '../../sbox/source/repository_data_source.dart';
import '../../sbox/source/source_path.dart';
import '../../sbox/storage/io_hash.dart';
import '../../sbox/storage/local_bundle_index.dart';
import '../../sbox/storage/temporary_plaintext_store.dart';

final class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.controller,
    this.onOpenCloudSettings,
    this.videoPosterDecoder = const FlutterVideoPosterDecoder(),
    this.directoryOpener,
  });

  final AppController controller;
  final VoidCallback? onOpenCloudSettings;
  final VideoPosterDecoder videoPosterDecoder;
  final Future<void> Function(Directory directory)? directoryOpener;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

final class _LibraryPageState extends State<LibraryPage> {
  static const _initialListingCount = 5;
  static const _listingTimeout = Duration(minutes: 1);

  final _configurationStore = CloudBackupConfigurationStore();
  final _credentialStore = PlatformCredentialStore();
  final _temporaryStore = TemporaryPlaintextStore();
  final _searchController = TextEditingController();
  final _descriptionController = TextEditingController();
  List<_LibraryBundle> _bundles = const <_LibraryBundle>[];
  Map<String, int> _encryptedBytesBySource = const <String, int>{};
  Map<String, bool> _encryptedSizeUnknownBySource = const <String, bool>{};
  Map<String, Object> _listingErrors = const <String, Object>{};
  http.Client? _client;
  CloudBackupConfiguration? _configuration;
  XFile? _selectedFile;
  int? _selectedFileLength;
  bool _credentialsReady = false;
  // Foreground work only. Background listing has its own state so a refresh
  // cannot accidentally unlock or relock the upload controls.
  bool _busy = false;
  bool _loading = true;
  bool _listingInBackground = false;
  bool _scanQueued = false;
  bool _scanQueuedWithCloudSources = false;
  Timer? _hydrationRebuildTimer;
  int _scanGeneration = 0;
  bool _dragging = false;
  bool _generatePreview = true;
  final List<BundlePreview> _videoPreviewCandidates = <BundlePreview>[];
  int _selectedVideoPreviewIndex = 0;
  bool _videoFileDetected = false;
  bool _videoPreviewLoading = false;
  String? _videoPreviewError;
  String _videoPreviewMediaType = 'video/mp4';
  int _videoPreviewRequestId = 0;
  int _targetNominalShardPlaintextSize =
      SboxProtocol.defaultNominalShardPlaintextSize;
  bool _savingShardSize = false;
  int? _shardSizeBeforeDrag;
  _LibrarySource _selectedSource = kIsWeb
      ? _LibrarySource.github
      : _LibrarySource.local;
  // Reading authenticated metadata for every Bundle is expensive. The saved
  // preference is restored before this page is created, while cached JPEGs
  // let an enabled preview load without repeating Metadata decryption.
  late bool _showPreviewAndDetails;
  String _busyTitle = '正在准备';
  String _busyDetail = '请稍候。';
  CloudBundleUploadProgress? _uploadProgress;
  CloudBundleUploadCancellation? _uploadCancellation;
  http.Client? _uploadClient;
  bool _uploadCancelRequested = false;
  BundleDownloadProgress? _downloadProgress;
  BundleDownloadCancellation? _downloadCancellation;
  http.Client? _downloadClient;
  bool _downloadCancelRequested = false;

  @override
  void initState() {
    super.initState();
    _targetNominalShardPlaintextSize =
        widget.controller.targetNominalShardPlaintextSize;
    _showPreviewAndDetails = widget.controller.showPreviewAndDetails;
    PaintingBinding.instance.imageCache.maximumSizeBytes =
        SboxProtocol.maxRetainedPreviewBytes;
    _load();
  }

  @override
  void dispose() {
    _uploadCancellation?.cancel();
    _uploadClient?.close();
    _downloadCancellation?.cancel();
    _downloadClient?.close();
    _hydrationRebuildTimer?.cancel();
    _disposeVideoPreviewCandidates();
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
    final selectedSbox = _selectedFileIsSbox;
    return _DashedDropTarget(
      dragging: _dragging,
      onDragEntered: () {
        if (!_busy && !_savingShardSize && mounted) {
          setState(() => _dragging = true);
        }
      },
      onDragExited: () {
        if (mounted) setState(() => _dragging = false);
      },
      onDragDone: (files) async {
        if (_busy || _savingShardSize) return;
        if (mounted) setState(() => _dragging = false);
        if (files.isNotEmpty) await _setFile(files.first);
      },
      // Once a file is selected, only the explicit replacement link opens the
      // picker. Keeping the card-level InkWell out of the gesture arena makes
      // the nested upload button reliable across repeated selections.
      onTap: _busy || _savingShardSize || _selectedFile != null
          ? null
          : _pickFile,
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
                color: context.sboxColors.text,
              ),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: mobile ? 292 : 250,
              child: ElevatedButton.icon(
                key: ValueKey<String>(
                  _selectedFile == null
                      ? 'library-select-file-button'
                      : selectedSbox
                      ? 'library-save-sbox-button'
                      : 'library-upload-file-button',
                ),
                onPressed: _busy || _savingShardSize
                    ? null
                    : (_selectedFile == null
                          ? _pickFile
                          : selectedSbox
                          ? _saveSboxToLocal
                          : _upload),
                icon: Icon(
                  _selectedFile == null
                      ? Icons.file_upload_outlined
                      : selectedSbox
                      ? Icons.save_alt_outlined
                      : Icons.lock_outline,
                  size: 23,
                ),
                label: Text(
                  _busy
                      ? (selectedSbox ? '正在保存' : '正在准备')
                      : _selectedFile == null
                      ? '选择文件'
                      : selectedSbox
                      ? '保存到local'
                      : '加密并上传',
                ),
              ),
            ),
            const SizedBox(height: 18),
            _buildFileSelectionHint(context),
            if (!selectedSbox) ...<Widget>[
              const SizedBox(height: 22),
              TextField(
                controller: _descriptionController,
                enabled: !_busy && !_savingShardSize,
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
              Material(
                type: MaterialType.transparency,
                child: SwitchListTile(
                  value: _generatePreview,
                  onChanged: _busy || _savingShardSize
                      ? null
                      : _setGeneratePreview,
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.image_outlined),
                  title: const Text('嵌入缩略图；图片/视频文件专用'),
                ),
              ),
              _buildVideoPreviewPicker(context),
              const SizedBox(height: 8),
              _buildShardSizeControl(context),
            ],
            if (_busy) ...<Widget>[
              const SizedBox(height: 18),
              Text(
                _busyTitle,
                style: TextStyle(
                  color: context.sboxColors.accent,
                  fontSize: 13,
                ),
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
      color: _busy ? context.sboxColors.textDim : context.sboxColors.textMuted,
    );
    if (file == null) {
      return Text('文件会自动安全保存', style: textStyle, textAlign: TextAlign.center);
    }

    return TextButton(
      onPressed: _busy || _savingShardSize ? null : _pickFile,
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

  Widget _buildVideoPreviewPicker(BuildContext context) {
    final selectedFile = _selectedFile;
    final selectedFileLooksLikeVideo =
        selectedFile != null &&
        (_looksLikeVideoFile(selectedFile.name) ||
            _looksLikeVideoFile(selectedFile.path));
    if (!_generatePreview ||
        (!_videoFileDetected && !selectedFileLooksLikeVideo)) {
      return const SizedBox.shrink();
    }

    final candidates = _videoPreviewCandidates;
    final selectedIndex = candidates.isEmpty
        ? 0
        : _selectedVideoPreviewIndex.clamp(0, candidates.length - 1).toInt();
    final detail = _videoPreviewLoading
        ? '正在随机抽取视频画面，请稍候。'
        : candidates.isEmpty
        ? (_videoPreviewError ?? '暂时无法提取候选画面，上传时会继续尝试生成默认缩略图。')
        : '已随机抽取 ${candidates.length} 个画面，默认使用第 1 个；点击下方画面即可更换。';

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(
        key: const ValueKey<String>('library-video-preview-picker'),
        width: double.infinity,
        child: SboxCard(
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(Icons.video_library_outlined, size: 20),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      '选择视频缩略图',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (candidates.isNotEmpty)
                    Text(
                      '第 ${selectedIndex + 1} 帧',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: context.sboxColors.accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 7),
              Text(
                detail,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: context.sboxColors.textMuted),
              ),
              if (_videoPreviewLoading) ...<Widget>[
                const SizedBox(height: 12),
                const LinearProgressIndicator(minHeight: 4),
              ],
              if (candidates.isNotEmpty) ...<Widget>[
                const SizedBox(height: 14),
                SizedBox(
                  height: 112,
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context).copyWith(
                      dragDevices: <PointerDeviceKind>{
                        ...ScrollConfiguration.of(context).dragDevices,
                        PointerDeviceKind.mouse,
                      },
                    ),
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      primary: false,
                      physics: const ClampingScrollPhysics(),
                      itemCount: candidates.length,
                      separatorBuilder: (_, index) => const SizedBox(width: 10),
                      itemBuilder: (context, index) =>
                          _buildVideoPreviewCandidate(
                            context,
                            candidates[index],
                            index,
                            selectedIndex == index,
                          ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoPreviewCandidate(
    BuildContext context,
    BundlePreview preview,
    int index,
    bool selected,
  ) {
    final accent = context.sboxColors.accent;
    return Semantics(
      button: true,
      selected: selected,
      label: '视频缩略图候选 ${index + 1}',
      child: InkWell(
        key: ValueKey<String>('library-video-preview-candidate-$index'),
        onTap: _busy || _savingShardSize
            ? null
            : () => setState(() => _selectedVideoPreviewIndex = index),
        borderRadius: BorderRadius.circular(9),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 148,
          height: 108,
          padding: EdgeInsets.all(selected ? 2 : 1),
          decoration: BoxDecoration(
            color: context.sboxColors.panelRaised,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: selected ? accent : context.sboxColors.border,
              width: selected ? 2 : 1,
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(
                  // Image providers may retain the bytes after this build.
                  // Give Flutter an owned copy so a later scan can dispose the
                  // BundlePreview without zeroing an in-flight decode.
                  preview.encodedBytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (context, error, stackTrace) => Icon(
                    Icons.broken_image_outlined,
                    color: context.sboxColors.textMuted,
                  ),
                ),
              ),
              Positioned(
                left: 5,
                bottom: 5,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.68),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    child: Text(
                      '候选 ${index + 1}',
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: Colors.white),
                    ),
                  ),
                ),
              ),
              if (selected)
                Positioned(
                  right: 5,
                  top: 5,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 5,
                        ),
                      ],
                    ),
                    child: const Padding(
                      padding: EdgeInsets.all(3),
                      child: Icon(Icons.check, size: 16, color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildShardSizeControl(BuildContext context) {
    final megabytes = _targetNominalShardPlaintextSize ~/ _mebibyte;
    final disabled = _busy || _savingShardSize;
    return SizedBox(
      width: double.infinity,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 7),
        decoration: BoxDecoration(
          color: context.sboxColors.panelSoft,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.sboxColors.borderSoft),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.view_in_ar_outlined,
                  color: context.sboxColors.accent,
                  size: 23,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    '分片大小',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  '$megabytes MB',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: context.sboxColors.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              _savingShardSize ? '正在保存…' : '默认 16 MB，云端限制时自动适配',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: context.sboxColors.textMuted),
            ),
            SizedBox(
              width: double.infinity,
              child: Slider(
                // Keep the original 48px vertical layout while removing the
                // default horizontal inset from the track.
                padding: const EdgeInsets.symmetric(vertical: 14),
                value: megabytes.toDouble(),
                min: 1,
                max: 512,
                divisions: 511,
                label: '$megabytes MB',
                onChanged: disabled ? null : _handleShardSizeChanged,
                onChangeEnd: disabled
                    ? null
                    : (value) {
                        _saveShardSize(value);
                      },
              ),
            ),
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[Text('1 MB'), Text('512 MB')],
            ),
          ],
        ),
      ),
    );
  }

  void _handleShardSizeChanged(double value) {
    final next = value.round() * _mebibyte;
    if (next == _targetNominalShardPlaintextSize) return;
    _shardSizeBeforeDrag ??= _targetNominalShardPlaintextSize;
    setState(() => _targetNominalShardPlaintextSize = next);
  }

  Future<void> _saveShardSize(double value) async {
    final next = value.round() * _mebibyte;
    final previous = _shardSizeBeforeDrag;
    _shardSizeBeforeDrag = null;
    if (previous == null || previous == next) return;
    setState(() => _savingShardSize = true);
    try {
      await widget.controller.saveTargetNominalShardPlaintextSize(next);
      if (!mounted) return;
      setState(() => _savingShardSize = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _targetNominalShardPlaintextSize = previous;
        _savingShardSize = false;
      });
      widget.controller.setError(error, operation: '保存分片大小失败');
      _showFeedback('分片大小没有保存成功，请稍后重试。', error: true);
    }
  }

  static const _mebibyte = 1024 * 1024;

  Widget _buildFilesCard(BuildContext context, bool mobile) {
    final rows = _visibleRows;
    final totalEncryptedBytes =
        _encryptedBytesBySource[_selectedSource.label] ?? 0;
    final encryptedSizeUnknown =
        _encryptedSizeUnknownBySource[_selectedSource.label] ?? false;
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
                    _buildPreviewDetailsCheckbox(context, compact: true),
                    _buildRefreshButton(),
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
                _buildPreviewDetailsCheckbox(context),
                _buildRefreshButton(),
                const SizedBox(width: 12),
                _buildSourceSwitcher(context),
              ],
            ),
          SizedBox(height: mobile ? 22 : 20),
          Row(
            children: <Widget>[
              Expanded(
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
              SizedBox(width: mobile ? 10 : 14),
              StatusPill(
                label: mobile
                    ? '${rows.length} 个文件'
                    : '${rows.length} 个文件 · '
                          '${encryptedSizeUnknown ? '总加密大小：待读取' : '总加密大小：${_formatBytes(BigInt.from(totalEncryptedBytes))}'}',
                icon: Icons.verified_user_outlined,
                tone: context.sboxColors.accent,
                compact: true,
              ),
            ],
          ),
          if (_listingErrors.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            _buildListingErrorBanner(context),
          ],
          const SizedBox(height: 20),
          if (_busy && !_loading)
            SboxProgressCard(
              title: _busyTitle,
              detail: _busyDetail,
              value: _downloadProgress?.fraction ?? _uploadProgress?.fraction,
              progressLabel:
                  _downloadProgress?.overallLabel ??
                  _uploadProgress?.overallLabel,
              onCancel: _uploadCancellation != null
                  ? (_uploadCancelRequested ? null : _cancelUpload)
                  : _downloadCancellation != null
                  ? (_downloadCancelRequested ? null : _cancelDownload)
                  : null,
            )
          else if (_listingErrors.isNotEmpty)
            const SizedBox(height: 20)
          else if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 42),
              child: Center(
                child: Column(
                  children: <Widget>[
                    Icon(
                      Icons.folder_open_outlined,
                      color: context.sboxColors.textDim,
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
                      Divider(height: 1, color: context.sboxColors.borderSoft),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildListingErrorBanner(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: errorColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: errorColor.withValues(alpha: 0.42)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline_rounded, color: errorColor, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '读取文件失败',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: errorColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                for (final entry in _listingErrors.entries)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      _formatListingError(entry.key, entry.value),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatListingError(String sourceName, Object error) {
    if (error is SboxException) {
      final status = error.httpStatus == null
          ? ''
          : '（HTTP ${error.httpStatus}）';
      final retry = error.retryAfter == null
          ? ''
          : '，约 ${error.retryAfter!.inSeconds} 秒后可重试';
      return '$sourceName：${AppLogger.sanitize(error.message)}$status$retry';
    }
    return '$sourceName：${AppLogger.describeError(error)}';
  }

  Widget _buildRefreshButton() {
    final listing = _listingInBackground;
    final icon = listing
        ? SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: context.sboxColors.accent,
            ),
          )
        : const Icon(Icons.refresh_rounded);
    return Container(
      decoration: BoxDecoration(
        color: context.sboxColors.panelSoft,
        border: Border.all(color: context.sboxColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: IconButton(
        onPressed: _busy
            ? null
            : () => _scan(
                includeCloudSources: _selectedSource != _LibrarySource.local,
              ),
        icon: icon,
        tooltip: listing
            ? _scanQueued
                  ? '同步中，刷新已排队'
                  : '正在后台同步文件列表'
            : '刷新',
        color: context.sboxColors.accent,
        disabledColor: context.sboxColors.textDim,
        iconSize: 24,
        padding: const EdgeInsets.all(10),
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      ),
    );
  }

  Widget _buildPreviewDetailsCheckbox(
    BuildContext context, {
    bool compact = false,
  }) {
    const label = '显示预览图和附加信息';
    final tooltip = _showPreviewAndDetails ? '隐藏预览图和附加信息' : label;
    final checkbox = Checkbox(
      key: const ValueKey<String>('library-show-preview-details'),
      value: _showPreviewAndDetails,
      onChanged: _setShowPreviewAndDetails,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

    if (compact) {
      return Semantics(
        container: true,
        label: label,
        checked: _showPreviewAndDetails,
        child: Tooltip(message: tooltip, child: checkbox),
      );
    }

    return Semantics(
      container: true,
      label: label,
      checked: _showPreviewAndDetails,
      child: Tooltip(
        message: tooltip,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            checkbox,
            InkWell(
              onTap: () => _setShowPreviewAndDetails(!_showPreviewAndDetails),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
                child: Text(
                  '预览信息',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: context.sboxColors.textMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _setShowPreviewAndDetails(bool? value) {
    if (value == null || value == _showPreviewAndDetails || !mounted) return;
    final previous = _showPreviewAndDetails;
    final needsPreviewLoad =
        value && _bundles.any((bundle) => bundle.preview == null);
    setState(() => _showPreviewAndDetails = value);
    unawaited(_persistShowPreviewAndDetails(value, previous: previous));
    if (needsPreviewLoad) {
      unawaited(
        _scan(includeCloudSources: _selectedSource != _LibrarySource.local),
      );
    }
  }

  Future<void> _persistShowPreviewAndDetails(
    bool value, {
    required bool previous,
  }) async {
    try {
      await widget.controller.saveShowPreviewAndDetails(value);
    } catch (error) {
      if (!mounted) return;
      if (_showPreviewAndDetails == value) {
        setState(() => _showPreviewAndDetails = previous);
      }
      widget.controller.setError(error, operation: '保存预览信息设置失败');
      _showFeedback('预览信息设置暂时无法保存，请稍后重试。', error: true);
    }
  }

  bool _isSourceEnabled(_LibrarySource source) {
    final configuration = _configuration;
    if (source == _LibrarySource.local) return !kIsWeb;
    if (configuration == null) return false;
    return source == _LibrarySource.github
        ? configuration.github.enabled
        : configuration.gitee.enabled;
  }

  Widget _buildSourceSwitcher(BuildContext context, {bool mobile = false}) {
    final options = <Widget>[
      if (!kIsWeb)
        mobile
            ? Expanded(
                child: _buildSourceOption(
                  context,
                  source: _LibrarySource.local,
                  icon: Icons.folder_outlined,
                  mobile: mobile,
                ),
              )
            : _buildSourceOption(
                context,
                source: _LibrarySource.local,
                icon: Icons.folder_outlined,
                mobile: mobile,
              ),
      if (_isSourceEnabled(_LibrarySource.github))
        mobile
            ? Expanded(
                child: _buildSourceOption(
                  context,
                  source: _LibrarySource.github,
                  icon: Icons.code_outlined,
                  mobile: mobile,
                ),
              )
            : _buildSourceOption(
                context,
                source: _LibrarySource.github,
                icon: Icons.code_outlined,
                mobile: mobile,
              ),
      if (_isSourceEnabled(_LibrarySource.gitee))
        mobile
            ? Expanded(
                child: _buildSourceOption(
                  context,
                  source: _LibrarySource.gitee,
                  icon: Icons.cloud_outlined,
                  mobile: mobile,
                ),
              )
            : _buildSourceOption(
                context,
                source: _LibrarySource.gitee,
                icon: Icons.cloud_outlined,
                mobile: mobile,
              ),
    ];
    if (options.isEmpty) return const SizedBox.shrink();
    return Semantics(
      label: '选择文件来源',
      child: Container(
        width: mobile ? double.infinity : null,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: context.sboxColors.backgroundDeep.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: context.sboxColors.border),
        ),
        child: Row(
          mainAxisSize: mobile ? MainAxisSize.max : MainAxisSize.min,
          children: options,
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
    final color = selected
        ? context.sboxColors.accent
        : context.sboxColors.textMuted;
    final child = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      padding: EdgeInsets.symmetric(
        horizontal: mobile ? 12 : 14,
        vertical: mobile ? 9 : 8,
      ),
      decoration: BoxDecoration(
        color: selected
            ? context.sboxColors.accent.withValues(alpha: 0.14)
            : null,
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
        onTap: _busy ? null : () => _setSelectedSource(source),
        borderRadius: BorderRadius.circular(8),
        child: child,
      ),
    );
  }

  void _setSelectedSource(_LibrarySource source) {
    if (_selectedSource == source || !mounted) return;
    setState(() => _selectedSource = source);
    if (source != _LibrarySource.local) {
      // Cloud sources are intentionally lazy at startup. Selecting a cloud
      // tab is the explicit signal to begin its listing.
      unawaited(_scan());
    }
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
                      color: context.sboxColors.textMuted,
                      fontSize: mobile ? 14 : 15,
                    ),
                  ),
                  if (_showPreviewAndDetails &&
                      row.bundle?.manifest != null) ...<Widget>[
                    const SizedBox(height: 5),
                    Text(
                      '原始大小：${_formatBytes(row.bundle!.manifest!.logicalPlaintextSize)}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: context.sboxColors.textMuted,
                        fontSize: mobile ? 13 : 14,
                      ),
                    ),
                  ],
                  if (_showPreviewAndDetails &&
                      (row.bundle?.manifest?.description.isNotEmpty ??
                          false)) ...<Widget>[
                    const SizedBox(height: 5),
                    Text(
                      '附加信息：${row.bundle!.manifest!.description}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: context.sboxColors.textMuted,
                        fontSize: mobile ? 13 : 14,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
          final actions = _buildRowActions(context, row, mobile);
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
    if (!_showPreviewAndDetails) {
      return FileTypeBadge(type: row.type, color: row.color);
    }
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
                // Image providers may decode asynchronously while a refresh
                // replaces and disposes the source BundlePreview.
                preview.encodedBytes,
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

  Widget _buildRowActions(BuildContext context, _FileRow row, bool mobile) {
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
            label: const Text('解密'),
          ),
        ),
      ],
      _FileActionState.remoteOnly => <Widget>[
        SizedBox(
          width: buttonWidth,
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _download(row),
            icon: Icon(Icons.download_outlined, size: mobile ? 20 : 22),
            label: const Text('下载'),
          ),
        ),
      ],
    };
    final canOpenLocalFolder = _canOpenLocalFolder(row);
    final canCopyPublicLink = _canCopyPublicLink(row);
    final canDeleteCloudBundle = _canDeleteCloudBundle(row);
    if (canOpenLocalFolder || canCopyPublicLink || canDeleteCloudBundle) {
      final openFolderEnabled = !_busy;
      final deleteEnabled = !_busy && !_listingInBackground;
      buttons.add(
        SizedBox(
          width: mobile ? 48 : 52,
          height: mobile ? 48 : 52,
          child: PopupMenuButton<_FileRowMenuAction>(
            tooltip: '更多操作',
            icon: Icon(Icons.more_vert, size: mobile ? 21 : 23),
            padding: EdgeInsets.zero,
            onSelected: (action) {
              switch (action) {
                case _FileRowMenuAction.openLocalFolder:
                  _openLocalFolder(row);
                case _FileRowMenuAction.copyPublicLink:
                  _copyPublicLink(row);
                case _FileRowMenuAction.deleteCloudBundle:
                  _deleteCloudBundle(row);
              }
            },
            itemBuilder: (context) {
              final errorColor = Theme.of(context).colorScheme.error;
              return <PopupMenuEntry<_FileRowMenuAction>>[
                if (canOpenLocalFolder)
                  PopupMenuItem<_FileRowMenuAction>(
                    enabled: openFolderEnabled,
                    value: _FileRowMenuAction.openLocalFolder,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(Icons.folder_open_outlined, size: 20),
                        SizedBox(width: 10),
                        Text('打开文件夹'),
                      ],
                    ),
                  ),
                if (canOpenLocalFolder &&
                    (canCopyPublicLink || canDeleteCloudBundle))
                  const PopupMenuDivider(),
                if (canCopyPublicLink)
                  const PopupMenuItem<_FileRowMenuAction>(
                    value: _FileRowMenuAction.copyPublicLink,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(Icons.link_outlined, size: 20),
                        SizedBox(width: 10),
                        Text('复制链接'),
                      ],
                    ),
                  ),
                if (canCopyPublicLink && canDeleteCloudBundle)
                  const PopupMenuDivider(),
                if (canDeleteCloudBundle)
                  PopupMenuItem<_FileRowMenuAction>(
                    enabled: deleteEnabled,
                    value: _FileRowMenuAction.deleteCloudBundle,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(Icons.delete_outline, color: errorColor, size: 20),
                        const SizedBox(width: 10),
                        Text('删除云端文件', style: TextStyle(color: errorColor)),
                      ],
                    ),
                  ),
              ];
            },
          ),
        ),
      );
    }
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: buttons,
    );
  }

  bool _canOpenLocalFolder(_FileRow row) =>
      row.bundle?.source is LocalDirectoryDataSource;

  Future<void> _openLocalFolder(_FileRow row) async {
    final source = row.bundle?.source;
    if (source is! LocalDirectoryDataSource) return;
    try {
      await (widget.directoryOpener ?? FileOpener.openDirectory)(source.root);
      if (mounted) _showFeedback('文件夹已打开。');
    } catch (error) {
      if (!mounted) return;
      widget.controller.setError(error, operation: '打开本地备份文件夹失败');
      _showFeedback('文件夹暂时无法打开，请稍后重试。', error: true);
    }
  }

  bool _canCopyPublicLink(_FileRow row) =>
      row.bundle?.source is RepositoryDataSource;

  Future<void> _copyPublicLink(_FileRow row) async {
    final bundle = row.bundle;
    final source = bundle?.source;
    if (bundle == null || source is! RepositoryDataSource) return;
    final uri = source.publicReleaseAssetUri(bundle.root.path);
    try {
      await Clipboard.setData(ClipboardData(text: uri.toString()));
      if (mounted) _showFeedback('${bundle.sourceName} Release 公开链接已复制。');
    } catch (error) {
      if (!mounted) return;
      widget.controller.logger.warning(
        '复制云端公开链接失败',
        detail: AppLogger.describeError(error),
      );
      _showFeedback('复制链接失败，请稍后重试。', error: true);
    }
  }

  bool _canDeleteCloudBundle(_FileRow row) {
    final bundle = row.bundle;
    return bundle != null &&
        !bundle.isCached &&
        bundle.source.capabilities.canDelete;
  }

  Widget _buildFooter(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Icon(Icons.lock_outline, color: context.sboxColors.textMuted, size: 24),
        const SizedBox(width: 10),
        Text(
          '所有文件均经过加密，云端只保存密文',
          style: Theme.of(context).textTheme.bodyLarge
              ?.copyWith(color: context.sboxColors.textMuted),
        ),
      ],
    );
  }

  List<_FileRow> get _visibleRows {
    if (!_isSourceEnabled(_selectedSource)) return const <_FileRow>[];
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
      _ => context.sboxColors.accentStrong,
    };
    final date = manifest == null ? '已同步' : _formatDate(manifest.createdAt);
    return _FileRow(
      name: name,
      time: bundle.isCached ? '$date · 缓存' : date,
      type: type,
      color: color,
      actionState: bundle.actionState,
      bundle: bundle,
      thumbnail: bundle.preview,
    );
  }

  Future<bool> _confirmDeleteCloudBundle(_LibraryBundle bundle) async {
    final bundleId = hexLower(bundle.root.header.bundleId);
    final shardCount = bundle.root.header.shardCount;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('删除云端文件？'),
            content: Text(
              '将从 ${bundle.sourceName} 删除这个加密 Bundle：\n\n'
              'Bundle ID：$bundleId\n'
              '对象数：$shardCount 个\n\n'
              '此操作只删除云端密文，不删除本地缓存，且无法撤销。',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                child: const Text('确认删除'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _deleteCloudBundle(_FileRow row) async {
    final bundle = row.bundle;
    if (bundle == null ||
        bundle.isCached ||
        !_canDeleteCloudBundle(row) ||
        _busy ||
        _listingInBackground) {
      return;
    }
    final confirmed = await _confirmDeleteCloudBundle(bundle);
    if (!confirmed || !mounted) return;

    setState(() {
      _busy = true;
      _busyTitle = '正在删除云端文件';
      _busyDetail = '正在校验并删除 ${bundle.root.header.shardCount} 个云端对象，请稍候。';
      _uploadProgress = null;
      _downloadProgress = null;
    });
    try {
      final objects = await _listBundleObjectsForDeletion(bundle);
      await BundleSync.delete(bundle.source, objects);
      if (!mounted) return;
      _showFeedback('云端文件已删除。');
      setState(() {
        _busy = false;
        _uploadProgress = null;
        _downloadProgress = null;
      });
      unawaited(_scan());
    } catch (error) {
      if (!mounted) return;
      widget.controller.setError(error, operation: '删除云端文件失败');
      setState(() {
        _busy = false;
        _uploadProgress = null;
        _downloadProgress = null;
      });
      final message = error is SboxException ? error.message : '发生未知错误，请稍后重试。';
      _showFeedback('删除云端文件失败：$message', error: true);
    }
  }

  Future<List<({SourcePath path, RevisionToken revision, bool isRoot})>>
  _listBundleObjectsForDeletion(_LibraryBundle bundle) async {
    final source = bundle.source;
    if (source is! EnumerableDataSource ||
        !source.capabilities.canListObjects) {
      throw const SboxException(
        SboxErrorCode.listingUnsupported,
        '当前数据源不支持删除前的对象校验',
      );
    }

    final header = bundle.root.header;
    final expected = <String, int>{
      for (var index = 0; index < header.shardCount; index++)
        canonicalBundleBasename(
          bundleId: header.bundleId,
          shardIndex: index,
          shardCount: header.shardCount,
        ): index,
    };
    final found = <String, SourceObjectInfo>{};
    final seenPaths = <String>{};
    final seenCursors = <String>{};
    String? cursor;
    do {
      if (cursor != null && !seenCursors.add(cursor)) {
        throw const SboxException(
          SboxErrorCode.shardConflict,
          '数据源分页游标重复，未执行删除',
        );
      }
      final page = await source.listObjects(cursor: cursor);
      for (final object in page.objects) {
        if (!seenPaths.add(object.path.value)) {
          throw const SboxException(
            SboxErrorCode.shardConflict,
            '数据源返回了重复对象，未执行删除',
          );
        }
        if (expected.containsKey(object.path.value)) {
          found[object.path.value] = object;
        }
      }
      cursor = page.nextCursor;
    } while (cursor != null);

    if (found.length != expected.length) {
      throw const SboxException(SboxErrorCode.shardMissing, '云端文件分片不完整，未执行删除');
    }
    final rootName = bundle.root.path.value;
    final rootInfo = found[rootName];
    if (rootInfo == null) {
      throw const SboxException(SboxErrorCode.sourceNotFound, '云端根对象不存在，未执行删除');
    }
    if (!rootInfo.revision.matches(bundle.root.info.revision)) {
      throw const SboxException(
        SboxErrorCode.remoteChanged,
        '云端根对象已发生变化，未执行删除',
      );
    }

    final ordered = found.values.toList()
      ..sort(
        (left, right) =>
            expected[left.path.value]!.compareTo(expected[right.path.value]!),
      );
    return List<
      ({SourcePath path, RevisionToken revision, bool isRoot})
    >.unmodifiable(
      ordered.map(
        (object) => (
          path: object.path,
          revision: object.revision,
          isRoot: expected[object.path.value] == 0,
        ),
      ),
    );
  }

  Future<void> _load() async {
    // Do not start the first source walk in the same turn as the first page
    // build. This guarantees that the desktop window can paint and accept
    // scroll/tab input before any cache or source work begins.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await _scan(includeCloudSources: false);
  }

  Future<void> _loadConfiguration() async {
    try {
      final configuration = await _configurationStore.load();
      var credentialsReady = false;
      if (configuration != null) {
        final endpoints = <CloudRepositoryEndpoint>[
          if (configuration.github.enabled) configuration.github,
          if (configuration.gitee.enabled) configuration.gitee,
        ];
        final tokens = await Future.wait<SourceAccessToken?>(
          endpoints.map(
            (endpoint) =>
                _credentialStore.getAccessToken(endpoint.credentialId),
          ),
        );
        credentialsReady =
            endpoints.isNotEmpty && tokens.every((token) => token != null);
        for (final token in tokens) {
          token?.dispose();
        }
        final selectedEnabled = switch (_selectedSource) {
          _LibrarySource.local => !kIsWeb,
          _LibrarySource.github => configuration.github.enabled,
          _LibrarySource.gitee => configuration.gitee.enabled,
        };
        if (!selectedEnabled) {
          _selectedSource = configuration.github.enabled
              ? _LibrarySource.github
              : configuration.gitee.enabled
              ? _LibrarySource.gitee
              : (kIsWeb ? _LibrarySource.github : _LibrarySource.local);
        }
      } else if (kIsWeb) {
        _selectedSource = _LibrarySource.github;
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

  Future<void> _scanWeb({bool forceStart = false}) async {
    if (!mounted) return;
    if (_listingInBackground && !forceStart) {
      _scanQueued = true;
      _scanQueuedWithCloudSources = true;
      setState(() {});
      return;
    }

    _scanQueued = false;
    _scanQueuedWithCloudSources = false;
    final scanGeneration = ++_scanGeneration;
    setState(() {
      _listingInBackground = true;
      _listingErrors = const <String, Object>{};
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || scanGeneration != _scanGeneration) return;
    await _loadConfiguration();
    if (!mounted || scanGeneration != _scanGeneration) return;

    http.Client? nextClient;
    var listingTimedOut = false;
    final staged = <_LibraryBundle>[];
    final encryptedBytes = <String, int>{};
    final encryptedSizeUnknown = <String, bool>{};
    final listingErrors = <String, Object>{};
    try {
      final configuration = _configuration;
      if (configuration == null) {
        final previous = _bundles;
        final previousClient = _client;
        _client = null;
        previousClient?.close();
        setState(() {
          _bundles = const <_LibraryBundle>[];
          _encryptedBytesBySource = const <String, int>{};
          _encryptedSizeUnknownBySource = const <String, bool>{};
        });
        _disposeBundlePreviews(previous);
        return;
      }

      nextClient = http.Client();
      final pair = CloudRepositoryPair.fromConfiguration(
        configuration: configuration,
        client: nextClient,
        logger: widget.controller.logger,
      );
      final listings = <Future<void>>[];
      for (final configured in pair.enabledSources) {
        final sourceName = configured.name;
        listings.add(() async {
          final sourceBundles = <_LibraryBundle>[];
          final roots = await _listSource(
            configured.source,
            sourceName,
            includePreview: _showPreviewAndDetails,
            onRoot: (root) {
              sourceBundles.add(
                _LibraryBundle(
                  root: root,
                  source: configured.source,
                  sourceName: sourceName,
                  manifest: root.manifest,
                  preview: root.preview,
                  hasPreview: root.hasPreview,
                  isCached: root.isCached,
                  status: root.status,
                ),
              );
            },
            onObject: (object) {
              if (!object.path.value.endsWith('.sbox')) return;
              if (object.length <= 0) {
                encryptedSizeUnknown[sourceName] = true;
              } else {
                encryptedBytes.update(
                  sourceName,
                  (total) => total + object.length,
                  ifAbsent: () => object.length,
                );
              }
            },
            onError: (error) => listingErrors[sourceName] = error,
          );
          if (roots == null) {
            _disposeBundlePreviews(sourceBundles);
          } else {
            staged.addAll(sourceBundles);
          }
        }());
      }
      await Future.wait<void>(listings).timeout(_listingTimeout);
      if (!mounted || scanGeneration != _scanGeneration) return;

      final previous = _bundles;
      final previousClient = _client;
      _client = nextClient;
      nextClient = null;
      previousClient?.close();
      setState(() {
        _bundles = List<_LibraryBundle>.unmodifiable(staged);
        _encryptedBytesBySource = Map<String, int>.unmodifiable(encryptedBytes);
        _encryptedSizeUnknownBySource = Map<String, bool>.unmodifiable(
          encryptedSizeUnknown,
        );
        _listingErrors = Map<String, Object>.unmodifiable(listingErrors);
      });
      _disposeBundlePreviews(previous);
    } catch (error) {
      _disposeBundlePreviews(staged);
      if (mounted && scanGeneration == _scanGeneration) {
        listingTimedOut = error is TimeoutException;
        if (listingTimedOut) {
          listingErrors['数据源'] = const SboxException(
            SboxErrorCode.sourceNetwork,
            '读取文件超过 1 分钟，已停止后台读取',
          );
          _scanGeneration++;
        }
        setState(
          () =>
              _listingErrors = Map<String, Object>.unmodifiable(listingErrors),
        );
        widget.controller.logger.warning(
          '读取 Web 云端文件失败',
          detail: AppLogger.describeError(error),
        );
        _showFeedback('暂时无法读取云端文件，请检查仓库跨域访问和网络。', error: true);
      }
    } finally {
      nextClient?.close();
      if (mounted &&
          _scanQueued &&
          (scanGeneration == _scanGeneration || listingTimedOut)) {
        _scanQueued = false;
        _scanQueuedWithCloudSources = false;
        unawaited(_scanWeb(forceStart: true));
      } else if (mounted &&
          (scanGeneration == _scanGeneration || listingTimedOut)) {
        setState(() {
          _listingInBackground = false;
          _scanQueued = false;
          _scanQueuedWithCloudSources = false;
        });
      }
    }
  }

  Future<void> _scan({
    bool forceStart = false,
    bool includeCloudSources = true,
  }) async {
    if (kIsWeb) {
      await _scanWeb(forceStart: forceStart);
      return;
    }
    if (!mounted) return;
    if (_listingInBackground && !forceStart) {
      _scanQueued = true;
      _scanQueuedWithCloudSources =
          _scanQueuedWithCloudSources || includeCloudSources;
      setState(() {});
      return;
    }

    _scanQueued = false;
    _scanQueuedWithCloudSources = false;
    final scanGeneration = ++_scanGeneration;
    final includePreview = _showPreviewAndDetails;
    setState(() {
      // Listing is deliberately silent. The refresh button is the only
      // activity indicator; existing rows remain usable while sources update.
      _listingInBackground = true;
      _listingErrors = const <String, Object>{};
    });
    // Let the refresh frame paint before configuration and source work starts.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || scanGeneration != _scanGeneration) return;
    // Reload configuration so manual refreshes and lazy tab scans pick up
    // changes made in Settings.
    await _loadConfiguration();
    if (!mounted || scanGeneration != _scanGeneration) return;
    final configuration = _configuration;
    final backupDirectory =
        configuration?.backupDirectory ??
        p.join(Directory.systemTemp.path, 'SafeBox', 'backup');

    http.Client? nextClient;
    http.Client? displayClient;
    http.Client? scanClient;
    var listingTimedOut = false;
    final stagedBundlesBySource = <String, List<_LibraryBundle>>{};
    final encryptedBytesBySource = <String, int>{};
    final encryptedSizeUnknownBySource = <String, bool>{};
    final encryptedBytesByBundle = <String, Map<String, int>>{};
    final encryptedSizeUnknownByBundle = <String, Set<String>>{};
    final publishedSources = <String>{};
    final listingErrors = <String, Object>{};
    final metadataStores = <String, LocalBundleIndexStore>{};
    final metadataSourceIds = <String, String>{};
    final metadataCaches = <String, LocalBundleIndex>{};
    final identityRecord = widget.controller.identityRecord;
    final identityCacheKey = identityRecord == null
        ? 'identity:none'
        : 'identity:${hexLower(identityRecord.recipientKeyId)}';

    String metadataCacheSourceId(String sourceKey) =>
        hexLower(sha256Bytes(utf8.encode('SafeBox/bundle-index-v3|$sourceKey')))
            .substring(0, 32);

    LocalBundleIndexStore metadataStoreFor(
      String sourceName,
      String sourceKey,
    ) {
      metadataSourceIds[sourceName] = metadataCacheSourceId(sourceKey);
      final existing = metadataStores[sourceName];
      if (existing != null) return existing;
      final store = LocalBundleIndexStore(
        Directory(backupDirectory),
        fileName: 'index-${sourceName.toLowerCase()}-v3.json',
      );
      metadataStores[sourceName] = store;
      return store;
    }

    void handleObject(String sourceName, SourceObjectInfo object) {
      if (!object.path.value.endsWith('.sbox')) return;
      String? bundleId;
      try {
        bundleId = parseCanonicalBundleBasename(object.path.value).bundleId;
      } on SboxException {
        // Non-canonical .sbox files are counted in the source total but are
        // never included in a Bundle metadata cache entry.
      }
      if (object.length <= 0) {
        encryptedSizeUnknownBySource[sourceName] = true;
        if (bundleId != null) {
          encryptedSizeUnknownByBundle
              .putIfAbsent(sourceName, () => <String>{})
              .add(bundleId);
        }
        return;
      }
      encryptedBytesBySource.update(
        sourceName,
        (total) => total + object.length,
        ifAbsent: () => object.length,
      );
      if (bundleId != null) {
        encryptedBytesByBundle
            .putIfAbsent(sourceName, () => <String, int>{})
            .update(
              bundleId,
              (total) => total + object.length,
              ifAbsent: () => object.length,
            );
      }
    }

    void publishSource(String sourceName) {
      if (!mounted || scanGeneration != _scanGeneration) return;
      final replacement = List<_LibraryBundle>.of(
        stagedBundlesBySource[sourceName] ?? const <_LibraryBundle>[],
      );
      final previous = _bundles
          .where((bundle) => bundle.sourceName == sourceName)
          .toList(growable: false);
      final nextBundles = <_LibraryBundle>[
        for (final bundle in _bundles)
          if (bundle.sourceName != sourceName) bundle,
        ...replacement,
      ];
      final nextBytes = Map<String, int>.of(_encryptedBytesBySource);
      final nextUnknown = Map<String, bool>.of(_encryptedSizeUnknownBySource);
      final bytes = encryptedBytesBySource[sourceName];
      if (bytes == null) {
        nextBytes.remove(sourceName);
      } else {
        nextBytes[sourceName] = bytes;
      }
      final unknown = encryptedSizeUnknownBySource[sourceName];
      if (unknown == null) {
        nextUnknown.remove(sourceName);
      } else {
        nextUnknown[sourceName] = unknown;
      }
      if (sourceName != _LibrarySource.local.label &&
          displayClient != null &&
          nextClient != null) {
        final previousClient = _client;
        _client = displayClient;
        nextClient = null;
        previousClient?.close();
      }
      publishedSources.add(sourceName);
      setState(() {
        _bundles = List<_LibraryBundle>.unmodifiable(nextBundles);
        _encryptedBytesBySource = Map<String, int>.unmodifiable(nextBytes);
        _encryptedSizeUnknownBySource = Map<String, bool>.unmodifiable(
          nextUnknown,
        );
        _listingErrors = Map<String, Object>.unmodifiable(listingErrors);
      });
      _disposeBundlePreviews(previous);
    }

    void handleRoot(
      DataSource source,
      String sourceName,
      ListedBundleRoot root,
    ) {
      if (!mounted || scanGeneration != _scanGeneration) {
        root.preview?.dispose();
        return;
      }
      final bundle = _LibraryBundle(
        root: root,
        source: source,
        sourceName: sourceName,
        manifest: root.manifest,
        preview: root.preview,
        hasPreview: root.hasPreview,
        isCached: root.isCached,
        status: root.status,
      );
      stagedBundlesBySource
          .putIfAbsent(sourceName, () => <_LibraryBundle>[])
          .add(bundle);
      unawaited(
        _hydrateListedBundle(
          bundle,
          backupDirectory: backupDirectory,
          scanGeneration: scanGeneration,
        ),
      );
    }

    _LibraryBundle? bundleFromCache(
      LocalBundleIndexEntry entry,
      DataSource source,
      String sourceName,
    ) {
      final rootHeaderHex = entry.rootHeaderHex;
      if (rootHeaderHex == null) return null;
      try {
        final header = BundleHeader.parse(decodeHex(rootHeaderHex));
        validateBundlePathAgainstHeader(entry.rootBasename, header);
        if (!header.isRoot ||
            hexLower(header.hash) != entry.manifestPrefixSha256) {
          return null;
        }
        entry.manifest.validateAgainstHeader(header);
        final revisionBytes = decodeHex(entry.rootRevisionFingerprint);
        if (revisionBytes.isEmpty) return null;
        final path = SourcePath(entry.rootBasename);
        final preview = entry.preview?.copy();
        final root = ListedBundleRoot(
          path: path,
          info: SourceObjectInfo(
            path: path,
            length: entry.rootSize ?? header.headerLength,
            revision: RevisionToken(revisionBytes),
          ),
          header: header,
          manifest: entry.manifest,
          preview: preview,
          hasPreview: entry.hasPreview,
          status: BundleTrustStatus.metadataReadable,
          isCached: true,
        );
        return _LibraryBundle(
          root: root,
          source: source,
          sourceName: sourceName,
          manifest: entry.manifest,
          preview: preview,
          hasPreview: entry.hasPreview,
          status: BundleTrustStatus.metadataReadable,
          isCached: true,
        );
      } on Object {
        return null;
      }
    }

    Future<void> publishCachedSource(
      String sourceName,
      DataSource source,
      LocalBundleIndex cache,
    ) async {
      if (!mounted || scanGeneration != _scanGeneration) return;
      final replacement = <_LibraryBundle>[];
      var cachedBytes = 0;
      var cachedSizeUnknown = false;
      for (var index = 0; index < cache.entries.length; index++) {
        final entry = cache.entries[index];
        final bundle = bundleFromCache(entry, source, sourceName);
        if (bundle == null) {
          cachedSizeUnknown = true;
          continue;
        }
        replacement.add(bundle);
        final encryptedSize = entry.encryptedSize;
        if (encryptedSize == null) {
          cachedSizeUnknown = true;
        } else {
          cachedBytes += encryptedSize;
        }
        if ((index + 1) % 32 == 0) {
          // Cache conversion is synchronous work on the UI isolate. Yield in
          // bounded batches so refresh never monopolises pointer/scroll input.
          await Future<void>.delayed(Duration.zero);
          if (!mounted || scanGeneration != _scanGeneration) {
            _disposeBundlePreviews(replacement);
            return;
          }
        }
      }
      if (cache.entries.isNotEmpty && replacement.isEmpty) return;
      final previous = _bundles
          .where((bundle) => bundle.sourceName == sourceName)
          .toList(growable: false);
      final nextBundles = <_LibraryBundle>[
        for (final bundle in _bundles)
          if (bundle.sourceName != sourceName) bundle,
        ...replacement,
      ];
      final nextBytes = Map<String, int>.of(_encryptedBytesBySource)
        ..remove(sourceName);
      final nextUnknown = Map<String, bool>.of(_encryptedSizeUnknownBySource)
        ..remove(sourceName);
      if (!cachedSizeUnknown) nextBytes[sourceName] = cachedBytes;
      if (cachedSizeUnknown) nextUnknown[sourceName] = true;
      setState(() {
        _bundles = List<_LibraryBundle>.unmodifiable(nextBundles);
        _encryptedBytesBySource = Map<String, int>.unmodifiable(nextBytes);
        _encryptedSizeUnknownBySource = Map<String, bool>.unmodifiable(
          nextUnknown,
        );
      });
      _disposeBundlePreviews(previous);
      for (final bundle in replacement) {
        unawaited(
          _hydrateListedBundle(
            bundle,
            backupDirectory: backupDirectory,
            scanGeneration: scanGeneration,
          ),
        );
      }
    }

    Future<LocalBundleIndex?> loadMetadataCache(
      String sourceName,
      String sourceKey,
    ) async {
      final store = metadataStoreFor(sourceName, sourceKey);
      final cache = await store.load(
        expectedSourceId: metadataSourceIds[sourceName],
        includePreviews: includePreview,
      );
      if (cache != null) metadataCaches[sourceName] = cache;
      return cache;
    }

    Future<void> saveMetadataCache(String sourceName) async {
      if (identityRecord == null ||
          !mounted ||
          scanGeneration != _scanGeneration) {
        return;
      }
      final store = metadataStores[sourceName];
      final sourceId = metadataSourceIds[sourceName];
      if (store == null || sourceId == null) return;
      final unknownBundleSizes = encryptedSizeUnknownByBundle[sourceName];
      final cachedByBundleId = <String, LocalBundleIndexEntry>{
        for (final entry
            in metadataCaches[sourceName]?.entries ??
                const <LocalBundleIndexEntry>[])
          entry.bundleId: entry,
      };
      final entries = <LocalBundleIndexEntry>[];
      final staged =
          stagedBundlesBySource[sourceName] ?? const <_LibraryBundle>[];
      for (var index = 0; index < staged.length; index++) {
        final bundle = staged[index];
        final manifest = bundle.manifest;
        if (manifest == null) continue;
        try {
          manifest.validateAgainstHeader(bundle.root.header);
          final bundleId = manifest.bundleId;
          final cached = cachedByBundleId[bundleId];
          final matchingCachedPreview =
              bundle.hasPreview &&
              cached != null &&
              cached.rootRevisionFingerprint ==
                  hexLower(bundle.root.info.revision.bytes) &&
              cached.manifestPrefixSha256 ==
                  hexLower(bundle.root.header.hash) &&
              cached.hasCachedPreview &&
              (!includePreview || cached.preview != null);
          entries.add(
            LocalBundleIndexEntry(
              bundleId: bundleId,
              rootBasename: bundle.root.path.value,
              rootRevisionFingerprint: hexLower(
                bundle.root.info.revision.bytes,
              ),
              manifestPrefixSha256: hexLower(bundle.root.header.hash),
              verification: BundleVerification.manifest,
              manifest: manifest,
              rootHeaderHex: hexLower(bundle.root.header.rawBytes),
              rootSize: bundle.root.info.length > 0
                  ? bundle.root.info.length
                  : null,
              encryptedSize: unknownBundleSizes?.contains(bundleId) == true
                  ? null
                  : encryptedBytesByBundle[sourceName]?[bundleId],
              hasPreview: bundle.hasPreview,
              previewWidth: bundle.preview == null && matchingCachedPreview
                  ? cached.previewWidth
                  : null,
              previewHeight: bundle.preview == null && matchingCachedPreview
                  ? cached.previewHeight
                  : null,
              previewSha256: bundle.preview == null && matchingCachedPreview
                  ? cached.previewSha256
                  : null,
              preview: bundle.preview,
            ),
          );
        } on Object {
          // Invalid metadata never enters the performance cache.
        }
        if ((index + 1) % 32 == 0) {
          await Future<void>.delayed(Duration.zero);
          if (!mounted || scanGeneration != _scanGeneration) return;
        }
      }
      try {
        await store.save(
          LocalBundleIndex(
            sourceId: sourceId,
            entries: List<LocalBundleIndexEntry>.unmodifiable(entries),
          ),
        );
      } on Object catch (error) {
        // Metadata and previews are rebuildable performance caches. A local
        // cache write failure must not turn a successful source listing into
        // an application-visible listing failure.
        widget.controller.logger.warning(
          '$sourceName：保存文件信息缓存失败',
          detail: AppLogger.describeError(error),
        );
      }
    }

    void handleListingError(String sourceName, Object error) {
      listingErrors[sourceName] = error;
      if (mounted && scanGeneration == _scanGeneration) {
        setState(
          () =>
              _listingErrors = Map<String, Object>.unmodifiable(listingErrors),
        );
      }
    }

    try {
      // Keep listing traffic on a disposable client. If the one-minute
      // deadline expires, closing it stops in-flight directory/header reads
      // without invalidating the client used by already-published rows.
      final visibleClient = http.Client();
      final listingClient = http.Client();
      displayClient = visibleClient;
      scanClient = listingClient;
      nextClient = visibleClient;
      final sourceListings = <Future<List<ListedBundleRoot>?>>[];
      final listingPreparations = <Future<void>>[];
      void addListing(
        EnumerableDataSource source,
        EnumerableDataSource displaySource,
        String name,
        LocalBundleIndex? metadataCache,
      ) {
        final listing = _listSource(
          source,
          name,
          metadataCache: metadataCache,
          includePreview: includePreview,
          onRoot: (root) => handleRoot(displaySource, name, root),
          onObject: (object) => handleObject(name, object),
          onError: (error) => handleListingError(name, error),
        );
        sourceListings.add(
          listing.then((roots) async {
            if (roots != null) {
              publishSource(name);
              await saveMetadataCache(name);
            }
            return roots;
          }),
        );
      }

      Future<void> prepareListing({
        required EnumerableDataSource source,
        required EnumerableDataSource displaySource,
        required String name,
        required String cacheKey,
      }) async {
        final cache = await loadMetadataCache(name, cacheKey);
        if (cache != null) {
          await publishCachedSource(name, displaySource, cache);
        }
        addListing(source, displaySource, name, cache);
      }

      if (includeCloudSources && configuration != null) {
        final pair = CloudRepositoryPair.fromConfiguration(
          configuration: configuration,
          client: listingClient,
          logger: widget.controller.logger,
        );
        final displayPair = CloudRepositoryPair.fromConfiguration(
          configuration: configuration,
          client: visibleClient,
          logger: widget.controller.logger,
        );
        for (final configured in pair.enabledSources) {
          final displaySource = configured.name == 'Gitee'
              ? displayPair.gitee
              : displayPair.github;
          final endpoint = configured.name == 'Gitee'
              ? configuration.gitee
              : configuration.github;
          final cacheKey = [
            configured.name,
            endpoint.owner,
            endpoint.repository,
            endpoint.pathPrefix,
            endpoint.repositoryUrl ?? '',
            identityCacheKey,
          ].join('|');
          listingPreparations.add(
            prepareListing(
              source: configured.source,
              displaySource: displaySource,
              name: configured.name,
              cacheKey: cacheKey,
            ),
          );
        }
      }

      listingPreparations.add(() async {
        try {
          final localSource = await LocalDirectoryDataSource.attach(
            root: Directory(backupDirectory),
            mode: LocalDirectoryMode.readOnly,
            requestWrite: false,
          );
          final cache = await loadMetadataCache(
            _LibrarySource.local.label,
            'Local|$backupDirectory|$identityCacheKey',
          );
          if (cache != null) {
            await publishCachedSource(
              _LibrarySource.local.label,
              localSource,
              cache,
            );
          }
          addListing(
            localSource,
            localSource,
            _LibrarySource.local.label,
            cache,
          );
        } catch (error) {
          // A missing backup directory is a valid empty Local source. Publish
          // that result immediately instead of waiting for cloud listings.
          if (error is SboxException &&
              error.code == SboxErrorCode.sourceNotFound) {
            sourceListings.add(
              Future<List<ListedBundleRoot>>.value(const <ListedBundleRoot>[])
                  .then((roots) {
                    publishSource(_LibrarySource.local.label);
                    return roots;
                  }),
            );
          } else {
            handleListingError(_LibrarySource.local.label, error);
          }
        }
      }());
      await Future.wait<void>(listingPreparations);
      await Future.wait<List<ListedBundleRoot>?>(sourceListings)
          .timeout(_listingTimeout);
    } catch (error) {
      if (mounted && scanGeneration == _scanGeneration) {
        listingTimedOut = error is TimeoutException;
        if (listingTimedOut) {
          listingErrors['数据源'] = const SboxException(
            SboxErrorCode.sourceNetwork,
            '读取文件超过 1 分钟，已停止后台读取',
          );
        }
        setState(
          () =>
              _listingErrors = Map<String, Object>.unmodifiable(listingErrors),
        );
        if (listingTimedOut) _scanGeneration++;
        widget.controller.logger.warning(
          '读取文件失败',
          detail: AppLogger.describeError(error),
        );
        _showFeedback('暂时无法读取文件，请稍后重试。', error: true);
      }
    } finally {
      final disposedCachePreviews = <BundlePreview>{};
      for (final cache in metadataCaches.values) {
        for (final entry in cache.entries) {
          final preview = entry.preview;
          if (preview != null && disposedCachePreviews.add(preview)) {
            preview.dispose();
          }
        }
      }
      for (final entry in stagedBundlesBySource.entries) {
        if (!publishedSources.contains(entry.key)) {
          _disposeBundlePreviews(entry.value);
        }
      }
      nextClient?.close();
      scanClient?.close();
      if (mounted &&
          _scanQueued &&
          (scanGeneration == _scanGeneration || listingTimedOut)) {
        final queuedWithCloudSources = _scanQueuedWithCloudSources;
        _scanQueued = false;
        _scanQueuedWithCloudSources = false;
        // Keep the spinner active across queued scans.
        unawaited(
          _scan(forceStart: true, includeCloudSources: queuedWithCloudSources),
        );
      } else if (mounted &&
          (scanGeneration == _scanGeneration || listingTimedOut)) {
        setState(() {
          _listingInBackground = false;
          _scanQueued = false;
          _scanQueuedWithCloudSources = false;
        });
      }
    }
  }

  Future<void> _hydrateListedBundle(
    _LibraryBundle bundle, {
    required String backupDirectory,
    required int scanGeneration,
  }) async {
    try {
      await _hydrateLocalState(<_LibraryBundle>[bundle], backupDirectory);
    } catch (error) {
      widget.controller.logger.warning(
        '读取本地文件状态失败',
        detail: AppLogger.describeError(error),
      );
    }
    if (!mounted || scanGeneration != _scanGeneration) return;
    if (!_bundles.contains(bundle)) return;
    _scheduleHydrationRebuild();
  }

  void _scheduleHydrationRebuild() {
    if (!mounted || _hydrationRebuildTimer != null) return;
    _hydrationRebuildTimer = Timer(Duration.zero, () {
      _hydrationRebuildTimer = null;
      if (mounted) setState(() {});
    });
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
        if (await _temporaryStore.isAvailable(plaintext, manifest)) {
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
    String name, {
    LocalBundleIndex? metadataCache,
    bool includePreview = true,
    required void Function(ListedBundleRoot root) onRoot,
    required void Function(SourceObjectInfo object) onObject,
    required void Function(Object error) onError,
  }) async {
    try {
      final record = widget.controller.identityRecord;
      final identity = record?.toPublicIdentity();
      return await BundleListing.listRoots(
        source,
        identity: identity,
        initialRootLimit: _initialListingCount,
        includePreview: includePreview,
        metadataCache: metadataCache,
        onRoot: onRoot,
        onObject: onObject,
      );
    } catch (error) {
      widget.controller.logger.warning(
        '$name：读取文件失败',
        detail: AppLogger.describeError(error),
      );
      onError(error);
      return null;
    }
  }

  Future<void> _pickFile() async {
    final file = await openFile(confirmButtonText: '选择');
    if (file != null) await _setFile(file);
  }

  bool get _selectedFileIsSbox {
    final file = _selectedFile;
    return file != null && _isSboxFile(file);
  }

  static bool _isSboxFile(XFile file) =>
      p.extension(file.name).toLowerCase() == '.sbox' ||
      p.extension(file.path).toLowerCase() == '.sbox';

  Future<void> _setFile(XFile file) async {
    final path = file.path.trim();
    if ((!kIsWeb && path.isEmpty) ||
        (!kIsWeb &&
            await FileSystemEntity.type(path, followLinks: false) !=
                FileSystemEntityType.file)) {
      _showFeedback('请选择一个文件。', error: true);
      return;
    }
    final length = kIsWeb ? await file.length() : await File(path).length();
    if (kIsWeb && length > WebRuntimeLimits.maxFileBytes) {
      _showFeedback(
        'Web 版单文件上限为 ${WebRuntimeLimits.maxFileMiB} MiB；浏览器会同时保留明文和密文。',
        error: true,
      );
      return;
    }
    if (!mounted) return;
    final isSbox = _isSboxFile(file);
    final looksLikeVideo =
        !isSbox &&
        (_looksLikeVideoFile(file.name) || _looksLikeVideoFile(file.path));
    _videoPreviewRequestId++;
    _disposeVideoPreviewCandidates();
    setState(() {
      _selectedFile = file;
      _selectedFileLength = length;
      _selectedVideoPreviewIndex = 0;
      _videoFileDetected = looksLikeVideo;
      _videoPreviewLoading = looksLikeVideo && _generatePreview;
      _videoPreviewError = null;
      _videoPreviewMediaType = 'video/mp4';
    });
    if (_generatePreview && !isSbox) {
      await _prepareVideoPreviewCandidates(file);
    }
  }

  void _setGeneratePreview(bool value) {
    if (_generatePreview == value || _busy || _savingShardSize) return;
    if (!value) {
      _videoPreviewRequestId++;
      _disposeVideoPreviewCandidates();
      setState(() {
        _generatePreview = false;
        _videoPreviewLoading = false;
        _videoFileDetected = false;
        _videoPreviewError = null;
      });
      return;
    }

    setState(() => _generatePreview = true);
    final file = _selectedFile;
    if (file != null) _prepareVideoPreviewCandidates(file);
  }

  Future<void> _prepareVideoPreviewCandidates(XFile file) async {
    final requestId = ++_videoPreviewRequestId;
    final looksLikeVideo =
        _looksLikeVideoFile(file.name) || _looksLikeVideoFile(file.path);
    _disposeVideoPreviewCandidates();
    if (mounted) {
      setState(() {
        _videoFileDetected = looksLikeVideo;
        _videoPreviewLoading = looksLikeVideo && _generatePreview;
        _videoPreviewError = null;
        _selectedVideoPreviewIndex = 0;
      });
    }

    if (kIsWeb) {
      if (mounted && requestId == _videoPreviewRequestId) {
        setState(() {
          _videoPreviewLoading = false;
          _videoPreviewError = looksLikeVideo
              ? 'Web 版暂不生成视频缩略图，文件仍可正常加密上传。'
              : null;
        });
      }
      return;
    }

    final source = File(file.path);
    final generator = PlatformPreviewGenerator(
      videoPosterDecoder: widget.videoPosterDecoder,
    );
    if (!await generator.isVideo(source)) {
      if (mounted &&
          requestId == _videoPreviewRequestId &&
          _selectedFile?.path == file.path) {
        setState(() {
          _videoPreviewLoading = false;
          _videoPreviewError = looksLikeVideo ? '文件看起来像视频，但无法识别其视频格式。' : null;
        });
      }
      return;
    }
    if (!mounted ||
        requestId != _videoPreviewRequestId ||
        _selectedFile?.path != file.path) {
      return;
    }
    setState(() {
      _videoFileDetected = true;
      _videoPreviewLoading = true;
      _videoPreviewError = null;
    });

    List<PreviewGenerated> generated;
    try {
      generated = await generator.generateVideoCandidates(
        source,
        count: defaultVideoPosterCandidateCount,
      );
    } on Object {
      generated = <PreviewGenerated>[];
    }
    if (!mounted ||
        requestId != _videoPreviewRequestId ||
        _selectedFile?.path != file.path) {
      for (final item in generated) {
        item.preview.dispose();
      }
      return;
    }

    _videoPreviewCandidates.addAll(generated.map((item) => item.preview));
    if (generated.isNotEmpty) {
      _videoPreviewMediaType = generated.first.detectedSourceMediaType;
    }
    setState(() {
      _videoPreviewLoading = false;
      _selectedVideoPreviewIndex = 0;
      _videoPreviewError = generated.isEmpty
          ? '暂时无法提取候选画面，上传时会继续尝试生成默认缩略图。'
          : null;
    });
  }

  void _disposeVideoPreviewCandidates() {
    for (final preview in _videoPreviewCandidates) {
      preview.dispose();
    }
    _videoPreviewCandidates.clear();
    _selectedVideoPreviewIndex = 0;
  }

  BundlePreview? _selectedVideoPreview() {
    if (_videoPreviewCandidates.isEmpty ||
        _selectedVideoPreviewIndex < 0 ||
        _selectedVideoPreviewIndex >= _videoPreviewCandidates.length) {
      return null;
    }
    return _videoPreviewCandidates[_selectedVideoPreviewIndex];
  }

  static bool _looksLikeVideoFile(String path) {
    final extension = p.extension(path).toLowerCase();
    return const <String>{
      '.mp4',
      '.m4v',
      '.mov',
      '.webm',
      '.avi',
      '.wmv',
      '.mkv',
      '.3gp',
      '.3g2',
      '.mpeg',
      '.mpg',
      '.m2ts',
      '.mts',
    }.contains(extension);
  }

  Future<void> _saveSboxToLocal() async {
    if (_busy || _savingShardSize) return;
    final selected = _selectedFile;
    if (selected == null) {
      await _pickFile();
      return;
    }
    if (!_isSboxFile(selected)) {
      await _upload();
      return;
    }
    if (kIsWeb) {
      _showFeedback('Web 版暂不支持保存到 Local。', error: true);
      return;
    }

    setState(() {
      _busy = true;
      _busyTitle = '正在保存到 Local';
      _busyDetail = '正在检查并保存 SBOX 文件，请稍候。';
      _uploadProgress = null;
      _downloadProgress = null;
    });
    try {
      final source = File(selected.path);
      if (await FileSystemEntity.type(source.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const SboxException(
          SboxErrorCode.sourceNotFound,
          '找不到所选 SBOX 文件',
        );
      }
      final length = await source.length();
      final digest = await sha256File(source);
      if (await source.length() != length) {
        throw const SboxException(
          SboxErrorCode.inputChanged,
          '所选 SBOX 文件在读取时发生变化',
        );
      }
      final header = await _readSelectedSboxHeader(source, length);
      final configuration = _configuration ?? await _configurationStore.load();
      final backupDirectory =
          configuration?.backupDirectory ??
          p.join(Directory.systemTemp.path, 'SafeBox', 'backup');
      final destination = await LocalDirectoryDataSource.attach(
        root: Directory(backupDirectory),
        mode: LocalDirectoryMode.readWrite,
        requestWrite: true,
      );
      await destination.putNew(
        SourcePath(header.canonicalBasename),
        source.openRead(),
        length: length,
        sha256: digest,
      );
      if (!mounted) return;
      _videoPreviewRequestId++;
      _disposeVideoPreviewCandidates();
      setState(() {
        _selectedFile = null;
        _selectedFileLength = null;
        _videoFileDetected = false;
        _videoPreviewLoading = false;
        _videoPreviewError = null;
        _videoPreviewMediaType = 'video/mp4';
        _descriptionController.clear();
      });
      _showFeedback('SBOX 文件已保存到 Local。');
      unawaited(_scan(includeCloudSources: false));
    } catch (error) {
      if (!mounted) return;
      widget.controller.setError(error, operation: '保存 SBOX 文件到 Local 失败');
      final message = error is SboxException ? error.message : '发生未知错误，请稍后重试。';
      _showFeedback('保存失败：$message', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _uploadProgress = null;
          _downloadProgress = null;
        });
      }
    }
  }

  static Future<BundleHeader> _readSelectedSboxHeader(
    File file,
    int length,
  ) async {
    final readLength = length < SboxProtocol.rootHeaderLength
        ? length
        : SboxProtocol.rootHeaderLength;
    final handle = await file.open(mode: FileMode.read);
    try {
      final header = BundleHeader.parse(await handle.read(readLength));
      final minimumLength =
          header.headerLength +
          SboxProtocol.recordHeaderLength +
          SboxProtocol.finalPlaintextLength +
          SboxProtocol.gcmTagLength;
      if (length < minimumLength) {
        throw const SboxException(SboxErrorCode.truncated, 'SBOX 文件内容不完整');
      }
      return header;
    } finally {
      await handle.close();
    }
  }

  Future<void> _upload() async {
    if (_busy || _savingShardSize || _uploadCancellation != null) return;
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
    final sourceFile = kIsWeb ? null : File(file.path);
    final cancellation = CloudBundleUploadCancellation();
    setState(() {
      _busy = true;
      _busyTitle = '正在安全保存';
      _busyDetail = '文件正在加密并同步到云端，请稍候。';
      _uploadProgress = null;
      _downloadProgress = null;
      _uploadCancellation = cancellation;
      _uploadCancelRequested = false;
    });
    BundlePreview? preview;
    PreviewUnavailableReason? previewUnavailableReason;
    MemoryBundleInput? webInput;
    Uint8List? webBytes;
    int? webLength;
    var mediaType = 'application/octet-stream';
    try {
      if (kIsWeb) {
        final declaredLength = await file.length();
        if (declaredLength > WebRuntimeLimits.maxFileBytes) {
          throw SboxException(
            SboxErrorCode.sourceLimit,
            'Web 版单文件上限为 ${WebRuntimeLimits.maxFileMiB} MiB',
          );
        }
        final bytes = await file.readAsBytes();
        webBytes = bytes;
        if (bytes.length != declaredLength) {
          throw const SboxException(
            SboxErrorCode.inputChanged,
            '选择的文件在读取时发生变化',
          );
        }
        if (bytes.length > WebRuntimeLimits.maxFileBytes) {
          throw SboxException(
            SboxErrorCode.sourceLimit,
            'Web 版单文件上限为 ${WebRuntimeLimits.maxFileMiB} MiB',
          );
        }
        webInput = MemoryBundleInput.owned(bytes);
        webLength = bytes.length;
        mediaType = file.mimeType ?? 'application/octet-stream';
        previewUnavailableReason = _generatePreview
            ? PreviewUnavailableReason.platformUnsupported
            : PreviewUnavailableReason.userDisabled;
      } else {
        // Enter the busy state before touching the file system. A removable
        // drive disappearing must not leave a tap looking ignored.
        if (!await sourceFile!.exists()) {
          if (mounted) {
            _showFeedback('找不到要上传的文件，请重新选择。', error: true);
          }
          return;
        }
        cancellation.throwIfCancelled();
        if (_generatePreview) {
          final selectedCandidate = _selectedVideoPreview();
          if (selectedCandidate != null) {
            preview = selectedCandidate.copy();
            mediaType = _videoPreviewMediaType;
          } else {
            final generated = await PlatformPreviewGenerator(
              videoPosterDecoder: widget.videoPosterDecoder,
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
          }
        } else {
          previewUnavailableReason = PreviewUnavailableReason.userDisabled;
        }
      }
      cancellation.throwIfCancelled();
      final identity = PublicIdentityRecord(
        spkiDer: record.spkiDer,
        recipientKeyId: record.recipientKeyId,
      ).toPublicIdentity();
      final client = http.Client();
      _uploadClient = client;
      late final CloudBundleUploadResult uploadResult;
      try {
        uploadResult =
            await CloudBundleUploader(
              credentialStore: _credentialStore,
              client: client,
              logger: widget.controller.logger,
            ).upload(
              input: kIsWeb ? webInput! : FileBundleInput(sourceFile!),
              declaredLength: kIsWeb ? webLength! : await sourceFile!.length(),
              options: BundleEncryptionOptions(
                recipient: identity,
                contentKind: SboxContentKind.file,
                originalName: file.name.trim().isEmpty
                    ? (kIsWeb ? 'safebox-upload.bin' : p.basename(file.path))
                    : file.name,
                mediaType: mediaType,
                title: file.name.trim().isEmpty
                    ? (kIsWeb ? 'safebox-upload.bin' : p.basename(file.path))
                    : file.name,
                description: _descriptionController.text,
                targetNominalShardPlaintextSize:
                    widget.controller.targetNominalShardPlaintextSize,
                preview: preview,
                previewRequested: _generatePreview,
                previewUnavailableReason: previewUnavailableReason,
              ),
              configuration: configuration,
              onProgress: _handleUploadProgress,
              cancellation: cancellation,
            );
      } finally {
        client.close();
        if (identical(_uploadClient, client)) _uploadClient = null;
      }
      cancellation.throwIfCancelled();
      if (!mounted) return;
      _videoPreviewRequestId++;
      _disposeVideoPreviewCandidates();
      setState(() {
        _selectedFile = null;
        _selectedFileLength = null;
        _videoFileDetected = false;
        _videoPreviewLoading = false;
        _videoPreviewError = null;
        _videoPreviewMediaType = 'video/mp4';
        _descriptionController.clear();
      });
      _showFeedback(
        uploadResult.previewEmbedded
            ? '文件已安全保存，并已生成加密缩略图。'
            : '文件已安全保存，但未生成缩略图（${_previewReasonLabel(uploadResult.previewUnavailableReason!)}）。',
      );
      // Refreshing the file list is background work. Do not keep this upload
      // callback alive (or its state eligible to race with the next upload)
      // while a remote listing may take up to a minute.
      unawaited(_scan());
    } catch (error) {
      if (cancellation.isCancelled ||
          error is SboxException && error.code == SboxErrorCode.cancelled) {
        if (mounted) _showFeedback('上传已取消');
        return;
      }
      if (mounted) {
        widget.controller.setError(error, operation: '安全保存文件失败');
        final message = error is SboxException
            ? error.message
            : '发生未知错误，请稍后重试。';
        _showFeedback('上传失败：$message', error: true);
      }
    } finally {
      preview?.dispose();
      if (webInput != null) {
        webInput.dispose();
      } else {
        webBytes?.fillRange(0, webBytes.length, 0);
      }
      if (mounted && identical(_uploadCancellation, cancellation)) {
        setState(() {
          _busy = false;
          _uploadProgress = null;
          _downloadProgress = null;
          _uploadCancellation = null;
          _uploadCancelRequested = false;
        });
      }
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

  void _cancelUpload() {
    final cancellation = _uploadCancellation;
    if (cancellation == null || cancellation.isCancelled) return;
    cancellation.cancel();
    _uploadClient?.close();
    if (!mounted) return;
    setState(() {
      _uploadCancelRequested = true;
      _busyTitle = '正在取消上传';
      _busyDetail = '正在停止当前上传请求，请稍候。';
    });
  }

  void _cancelDownload() {
    final cancellation = _downloadCancellation;
    if (cancellation == null || cancellation.isCancelled) return;
    cancellation.cancel();
    _downloadClient?.close();
    if (!mounted) return;
    setState(() {
      _downloadCancelRequested = true;
      _busyTitle = '正在取消下载';
      _busyDetail = '正在停止当前下载请求，请稍候。';
    });
  }

  void _handleUploadProgress(CloudBundleUploadProgress progress) {
    if (!mounted || _uploadCancellation?.isCancelled == true) return;
    setState(() {
      _uploadProgress = progress;
      _busyTitle = switch (progress.stage) {
        CloudBundleUploadStage.preparing => '正在准备上传',
        CloudBundleUploadStage.splitting => '正在切分&加密文件',
        CloudBundleUploadStage.encrypting => '正在切分&加密文件',
        CloudBundleUploadStage.uploading => '正在上传加密分片',
        CloudBundleUploadStage.verifying => '正在核对云端分片',
        CloudBundleUploadStage.completed => '上传完成，正在收尾',
      };
      _busyDetail = progress.detailLabel;
    });
  }

  void _handleDownloadProgress(BundleDownloadProgress progress) {
    if (!mounted || _downloadCancellation?.isCancelled == true) return;
    setState(() {
      _downloadProgress = progress;
      _busyTitle = switch (progress.stage) {
        BundleDownloadStage.preparing => '正在读取文件信息',
        BundleDownloadStage.downloading => '正在下载加密文件',
        BundleDownloadStage.decrypting => '正在解密文件',
        BundleDownloadStage.merging => '正在合并文件',
      };
      _busyDetail = progress.detailLabel;
    });
  }

  void _handleMergeProgress(
    BundleDownloadProgress base,
    int processedBytes,
    int totalBytes, {
    BundleDownloadCancellation? cancellation,
  }) {
    if (cancellation?.isCancelled == true) return;
    _handleDownloadProgress(
      BundleDownloadProgress(
        stage: BundleDownloadStage.merging,
        downloadedBytes: base.downloadedBytes,
        completedObjects: base.completedObjects,
        totalObjects: base.totalObjects,
        progressUnits: base.progressUnits,
        processedBytes: processedBytes,
        totalProcessingBytes: totalBytes,
        processedShards: totalBytes == 0 || processedBytes >= totalBytes
            ? 1
            : 0,
        processingTotalShards: 1,
      ),
    );
  }

  Future<void> _decryptLocal(_FileRow row) async {
    final bundle = row.bundle;
    if (bundle == null) return;
    final configuration = _configuration ?? await _configurationStore.load();
    if (configuration == null) {
      _showFeedback('未找到本地加密备份，请先下载文件。', error: true);
      return;
    }
    final mnemonic = await _askMnemonic(actionLabel: '解密');
    if (mnemonic == null || mnemonic.trim().isEmpty) return;
    if (!mounted) return;
    final cancellation = BundleDownloadCancellation();
    setState(() {
      _busy = true;
      _busyTitle = '正在解密文件';
      _busyDetail = '正在从本地加密备份恢复文件，请稍候。';
      _downloadProgress = null;
      _downloadCancellation = cancellation;
      _downloadCancelRequested = false;
    });
    try {
      final source = await LocalDirectoryDataSource.attach(
        root: Directory(configuration.backupDirectory),
        mode: LocalDirectoryMode.readOnly,
        requestWrite: false,
      );
      BundleDownloadProgress? lastProgress;
      final decrypted = await BundleSync.fetchAndDecrypt(
        source: source,
        rootPath: bundle.root.path,
        mnemonic: mnemonic,
        expectedIdentity: widget.controller.identityRecord?.toPublicIdentity(),
        onProgress: (progress) {
          lastProgress = progress;
          _handleDownloadProgress(progress);
        },
        cancellation: cancellation,
      );
      final destination = await _cacheDecrypted(
        manifest: decrypted.manifest,
        plaintext: decrypted.plaintext,
        onProgress: (processedBytes, totalBytes) {
          final base = lastProgress ?? _downloadProgress;
          if (base != null) {
            _handleMergeProgress(
              base,
              processedBytes,
              totalBytes,
              cancellation: cancellation,
            );
          }
        },
        cancellation: cancellation,
      );
      cancellation.throwIfCancelled();
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
      if (cancellation.isCancelled ||
          error is SboxException && error.code == SboxErrorCode.cancelled) {
        if (mounted) _showFeedback('解密已取消');
        return;
      }
      if (mounted) {
        widget.controller.setError(error, operation: '解密文件失败');
        _showFeedback('文件暂时无法解密，请检查本地备份和恢复词。', error: true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _downloadProgress = null;
          if (identical(_downloadCancellation, cancellation)) {
            _downloadCancellation = null;
            _downloadCancelRequested = false;
          }
        });
      }
    }
  }

  Future<void> _openPlaintext(_FileRow row) async {
    final bundle = row.bundle;
    if (bundle == null || bundle.plaintextFile == null) {
      _showFeedback('本地明文不存在，请先解密文件。', error: true);
      return;
    }
    try {
      await FileOpener.open(bundle.plaintextFile!);
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
    if (bundle == null || bundle.plaintextFile == null) {
      _showFeedback('本地明文不存在，请先解密文件。', error: true);
      return;
    }
    try {
      await (widget.directoryOpener ?? FileOpener.openDirectory)(
        Directory(p.dirname(bundle.plaintextFile!.path)),
      );
      if (mounted) _showFeedback('文件夹已打开。');
    } catch (error) {
      if (mounted) {
        widget.controller.setError(error, operation: '打开文件夹失败');
        _showFeedback('文件夹暂时无法打开，请稍后重试。', error: true);
      }
    }
  }

  Future<void> _downloadWeb(
    _LibraryBundle bundle,
    CloudBackupConfiguration configuration,
  ) async {
    final knownSize =
        bundle.manifest?.logicalPlaintextSize ??
        bundle.root.header.shardPlaintextSize *
            BigInt.from(bundle.root.header.shardCount);
    if (knownSize > BigInt.from(WebRuntimeLimits.maxFileBytes)) {
      _showFeedback(
        'Web 版只能在内存中解密，单文件上限为 ${WebRuntimeLimits.maxFileMiB} MiB。',
        error: true,
      );
      return;
    }
    final mnemonic = await _askMnemonic(actionLabel: '下载');
    if (mnemonic == null || mnemonic.trim().isEmpty || !mounted) return;

    final cancellation = BundleDownloadCancellation();
    final downloadClient = http.Client();
    final downloadPair = CloudRepositoryPair.fromConfiguration(
      configuration: configuration,
      client: downloadClient,
      logger: widget.controller.logger,
    );
    final downloadSource = bundle.sourceName == 'Gitee'
        ? downloadPair.gitee
        : downloadPair.github;
    final unregisterDownloadCancellation = cancellation.registerOnCancel(
      downloadClient.close,
    );
    _downloadClient = downloadClient;
    setState(() {
      _busy = true;
      _busyTitle = '正在解密并下载';
      _busyDetail = '密文和明文仅保留在当前浏览器标签页内存中。';
      _downloadProgress = null;
      _downloadCancellation = cancellation;
      _downloadCancelRequested = false;
    });

    DecryptedBundle? decrypted;
    var previewAdopted = false;
    try {
      final result = await BundleSync.fetchAndDecrypt(
        source: downloadSource,
        rootPath: bundle.root.path,
        mnemonic: mnemonic,
        expectedIdentity: widget.controller.identityRecord?.toPublicIdentity(),
        maximumTotalObjectBytes: WebRuntimeLimits.maxCiphertextBytes,
        onProgress: _handleDownloadProgress,
        cancellation: cancellation,
      );
      decrypted = result;
      cancellation.throwIfCancelled();
      if (result.plaintext.length > WebRuntimeLimits.maxFileBytes) {
        throw SboxException(
          SboxErrorCode.sourceLimit,
          'Web 版单文件上限为 ${WebRuntimeLimits.maxFileMiB} MiB',
        );
      }
      await BrowserDownload.save(
        bytes: result.plaintext,
        name: result.manifest.originalName,
        mediaType: result.manifest.mediaType,
      );
      cancellation.throwIfCancelled();
      if (!mounted) return;
      setState(() {
        bundle.manifest = result.manifest;
        _adoptPreview(bundle, result.preview);
        previewAdopted = result.preview != null;
        bundle.status = result.status;
      });
      _showFeedback('文件已解密，浏览器下载已开始。');
    } catch (error) {
      if (cancellation.isCancelled ||
          error is SboxException && error.code == SboxErrorCode.cancelled) {
        if (mounted) _showFeedback('下载已取消');
        return;
      }
      if (mounted) {
        widget.controller.setError(error, operation: 'Web 解密下载失败');
        final message = error is SboxException
            ? error.message
            : '请检查恢复词、仓库跨域访问和网络。';
        _showFeedback('下载失败：$message', error: true);
      }
    } finally {
      if (!previewAdopted) decrypted?.preview?.dispose();
      decrypted?.plaintext.fillRange(0, decrypted.plaintext.length, 0);
      unregisterDownloadCancellation();
      downloadClient.close();
      if (identical(_downloadClient, downloadClient)) _downloadClient = null;
      if (mounted) {
        setState(() {
          _busy = false;
          _downloadProgress = null;
          if (identical(_downloadCancellation, cancellation)) {
            _downloadCancellation = null;
            _downloadCancelRequested = false;
          }
        });
      }
    }
  }

  Future<void> _download(_FileRow row) async {
    final bundle = row.bundle;
    if (bundle == null) return;
    if (bundle.sourceName == _LibrarySource.local.label) {
      _showFeedback('本地备份不完整，请切换到云端来源后下载。', error: true);
      return;
    }
    final configuration = _configuration ?? await _configurationStore.load();
    if (configuration == null) {
      _showFeedback('请先配置本地加密备份目录。', error: true);
      return;
    }
    if (kIsWeb) {
      await _downloadWeb(bundle, configuration);
      return;
    }
    if (!mounted) return;
    final cancellation = BundleDownloadCancellation();
    DataSource downloadSource = bundle.source;
    final downloadClient = http.Client();
    final downloadPair = CloudRepositoryPair.fromConfiguration(
      configuration: configuration,
      client: downloadClient,
      logger: widget.controller.logger,
    );
    downloadSource = bundle.sourceName == 'Gitee'
        ? downloadPair.gitee
        : downloadPair.github;
    final unregisterDownloadCancellation = cancellation.registerOnCancel(
      downloadClient.close,
    );
    _downloadClient = downloadClient;
    setState(() {
      _busy = true;
      _busyTitle = '正在下载';
      _busyDetail = '正在下载并保存加密文件，请稍候。';
      _downloadProgress = null;
      _downloadCancellation = cancellation;
      _downloadCancelRequested = false;
    });
    try {
      final destination = await LocalDirectoryDataSource.attach(
        root: Directory(configuration.backupDirectory),
        mode: LocalDirectoryMode.readWrite,
        requestWrite: true,
      );
      await BundleSync.downloadTo(
        source: downloadSource,
        rootPath: bundle.root.path,
        destination: destination,
        onProgress: _handleDownloadProgress,
        cancellation: cancellation,
      );
      cancellation.throwIfCancelled();
      if (!mounted) return;
      setState(() {
        bundle.encryptedBackupAvailable = true;
      });
      _showFeedback('文件已下载，已保存为本地加密备份。');
    } catch (error) {
      if (cancellation.isCancelled ||
          error is SboxException && error.code == SboxErrorCode.cancelled) {
        if (mounted) _showFeedback('下载已取消');
        return;
      }
      if (mounted) {
        widget.controller.setError(error, operation: '下载加密文件失败');
        _showFeedback('文件暂时无法下载，请稍后重试。', error: true);
      }
    } finally {
      unregisterDownloadCancellation();
      downloadClient.close();
      if (identical(_downloadClient, downloadClient)) _downloadClient = null;
      if (mounted) {
        setState(() {
          _busy = false;
          _downloadProgress = null;
          if (identical(_downloadCancellation, cancellation)) {
            _downloadCancellation = null;
            _downloadCancelRequested = false;
          }
        });
      }
    }
  }

  Future<File> _cacheDecrypted({
    required BundleManifest manifest,
    required Uint8List plaintext,
    void Function(int processedBytes, int totalBytes)? onProgress,
    BundleDownloadCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final destination = await _temporaryStore.fileFor(manifest);
    await TemporaryPlaintextPlatform.protectRoot(_temporaryStore.path);
    if (await _temporaryStore.isAvailable(destination, manifest)) {
      cancellation?.throwIfCancelled();
      onProgress?.call(plaintext.length, plaintext.length);
      plaintext.fillRange(0, plaintext.length, 0);
      return destination;
    }
    await _temporaryStore.deleteFile(destination);
    final stage = File(
      '${destination.path}.${hexLower(secureRandomBytes(8))}.part',
    );
    var renamed = false;
    IOSink? output;
    try {
      onProgress?.call(0, plaintext.length);
      output = stage.openWrite();
      var offset = 0;
      while (offset < plaintext.length) {
        cancellation?.throwIfCancelled();
        final end = offset + SboxProtocol.chunkSize < plaintext.length
            ? offset + SboxProtocol.chunkSize
            : plaintext.length;
        output.add(Uint8List.sublistView(plaintext, offset, end));
        await output.flush();
        offset = end;
        onProgress?.call(offset, plaintext.length);
      }
      await output.flush();
      await output.close();
      output = null;
      cancellation?.throwIfCancelled();
      await stage.rename(destination.path);
      renamed = true;
      return destination;
    } finally {
      await output?.close();
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

  Future<String?> _askMnemonic({String actionLabel = '打开'}) {
    return showDialog<String>(
      context: context,
      builder: (context) => _RecoveryPhraseDialog(actionLabel: actionLabel),
    );
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

final class _RecoveryPhraseDialog extends StatefulWidget {
  const _RecoveryPhraseDialog({required this.actionLabel});

  final String actionLabel;

  @override
  State<_RecoveryPhraseDialog> createState() => _RecoveryPhraseDialogState();
}

final class _RecoveryPhraseDialogState extends State<_RecoveryPhraseDialog> {
  static final RegExp _whitespace = RegExp(r'\s+');

  final _controllers = List<TextEditingController>.generate(
    12,
    (_) => TextEditingController(),
  );
  final _focusNodes = List<FocusNode>.generate(12, (_) => FocusNode());

  bool get _complete => _controllers.every((controller) {
    final word = controller.text.trim();
    return word.isNotEmpty && !_whitespace.hasMatch(word);
  });

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.clear();
      controller.dispose();
    }
    for (final focusNode in _focusNodes) {
      focusNode.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final compact = screenSize.width < 620;
    return Dialog(
      key: const Key('recovery-phrase-dialog'),
      insetPadding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 32,
        vertical: compact ? 16 : 24,
      ),
      backgroundColor: context.sboxColors.panelSoft,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: context.sboxColors.borderSoft),
        borderRadius: BorderRadius.circular(compact ? 16 : 13),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 800,
          maxHeight: screenSize.height - (compact ? 32 : 48),
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            compact ? 16 : 30,
            compact ? 24 : 22,
            compact ? 16 : 30,
            compact ? 18 : 20,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final gridWidth = constraints.maxWidth;
              final columns = gridWidth >= 720
                  ? 3
                  : gridWidth >= 280
                  ? 2
                  : 1;
              final mobileGrid = columns < 3;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    '输入 12 个恢复词',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '按顺序输入恢复词，恢复词只保存在你手中',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: context.sboxColors.textMuted,
                      fontSize: compact ? 13 : 14,
                    ),
                  ),
                  const SizedBox(height: 18),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: 12,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: mobileGrid ? 8 : 12,
                      mainAxisSpacing: 8,
                      childAspectRatio: columns == 3
                          ? 3.7
                          : columns == 2
                          ? 2.4
                          : 4.6,
                    ),
                    itemBuilder: (context, index) =>
                        _buildWordField(context, index, compact: compact),
                  ),
                  SizedBox(height: compact ? 20 : 24),
                  _buildActions(context, compact),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildWordField(
    BuildContext context,
    int index, {
    required bool compact,
  }) {
    return TextField(
      key: Key('recovery-word-${index + 1}'),
      controller: _controllers[index],
      focusNode: _focusNodes[index],
      autofocus: index == 0,
      maxLines: 1,
      textInputAction: index == 11
          ? TextInputAction.done
          : TextInputAction.next,
      autofillHints: const <String>[],
      autocorrect: false,
      enableSuggestions: false,
      textAlignVertical: TextAlignVertical.center,
      onChanged: (value) => _handleWordChanged(index, value),
      onSubmitted: (_) => _handleWordSubmitted(index),
      style: TextStyle(
        color: context.sboxColors.text,
        fontSize: compact ? 15 : 16,
        fontWeight: FontWeight.w600,
      ),
      decoration: InputDecoration(
        hintText: '第 ${index + 1} 个词',
        filled: true,
        fillColor: context.sboxColors.panelRaised.withValues(alpha: 0.62),
        prefixIconConstraints: BoxConstraints.tightFor(
          width: index >= 9 ? (compact ? 54 : 64) : (compact ? 48 : 58),
        ),
        prefixIcon: Center(
          child: Text(
            '${index + 1}',
            style: TextStyle(
              color: context.sboxColors.accent,
              fontSize: compact ? 15 : 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        contentPadding: EdgeInsets.only(right: compact ? 10 : 14),
        hintStyle: TextStyle(
          color: context.sboxColors.textMuted,
          fontSize: compact ? 14 : 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.sboxColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.sboxColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.sboxColors.accent, width: 1.5),
        ),
      ),
    );
  }

  Widget _buildActions(BuildContext context, bool compact) {
    final cancel = TextButton(
      key: const Key('recovery-phrase-cancel'),
      onPressed: () => Navigator.of(context).pop(),
      child: const Text('取消'),
    );
    final submit = ElevatedButton(
      key: const Key('recovery-phrase-submit'),
      onPressed: _complete ? _submit : null,
      child: Text(widget.actionLabel),
    );
    if (compact) {
      return Row(
        children: <Widget>[
          Expanded(child: cancel),
          const SizedBox(width: 12),
          Expanded(child: submit),
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: <Widget>[cancel, const SizedBox(width: 12), submit],
    );
  }

  void _handleWordChanged(int index, String value) {
    final trimmed = value.trim();
    final words = trimmed.isEmpty
        ? const <String>[]
        : trimmed.split(_whitespace);
    if (words.length > 1) {
      final startIndex = words.length == 12 ? 0 : index;
      if (startIndex + words.length <= _controllers.length) {
        for (var offset = 0; offset < words.length; offset++) {
          _setWord(startIndex + offset, words[offset]);
        }
        final nextIndex = startIndex + words.length < 12
            ? startIndex + words.length
            : 11;
        _focusNodes[nextIndex].requestFocus();
      } else {
        _setWord(index, words.first);
      }
    } else if (words.isNotEmpty && RegExp(r'\s$').hasMatch(value)) {
      _setWord(index, words.single);
      if (index < 11) _focusNodes[index + 1].requestFocus();
    }
    setState(() {});
  }

  void _setWord(int index, String word) {
    _controllers[index].value = TextEditingValue(
      text: word,
      selection: TextSelection.collapsed(offset: word.length),
    );
  }

  void _handleWordSubmitted(int index) {
    if (index < 11) {
      _focusNodes[index + 1].requestFocus();
    } else if (_complete) {
      _submit();
    }
  }

  void _submit() {
    final mnemonic = _controllers
        .map((controller) => controller.text.trim())
        .join(' ');
    Navigator.of(context).pop(mnemonic);
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
            color: dragging
                ? context.sboxColors.accent
                : context.sboxColors.border,
            radius: 14,
            dash: 8,
            gap: 6,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: dragging
                  ? context.sboxColors.accent.withValues(alpha: 0.06)
                  : context.sboxColors.panelSoft.withValues(alpha: 0.62),
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
            color: context.sboxColors.accentStrong,
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
    this.isCached = false,
    this.status = BundleTrustStatus.headerOnly,
  }) : hasPreview = hasPreview ?? preview != null;

  final ListedBundleRoot root;
  final DataSource source;
  final String sourceName;
  BundleManifest? manifest;
  BundlePreview? preview;
  bool hasPreview;
  bool isCached;
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

enum _FileRowMenuAction { openLocalFolder, copyPublicLink, deleteCloudBundle }

enum _LibrarySource {
  github('GitHub'),
  gitee('Gitee'),
  local('Local');

  const _LibrarySource(this.label);

  final String label;
}
