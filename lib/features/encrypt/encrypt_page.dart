import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../app/app_controller.dart';
import '../../app/sbox_theme.dart';
import '../../app/sbox_widgets.dart';
import '../../platform/cloud_backup_configuration_store.dart';
import '../../platform/preview_generation_result.dart';
import '../../platform/preview_generator.dart';
import '../../platform/secure_credential_store.dart';
import '../../sbox/bytes.dart';
import '../../sbox/constants.dart';
import '../../sbox/engine/bundle_encryptor.dart';
import '../../sbox/errors.dart';
import '../../sbox/format/bundle_preview.dart';
import '../../sbox/identity/public_identity_record.dart';
import '../../sbox/source/cloud_backup_config.dart';
import '../../sbox/source/cloud_bundle_uploader.dart';

final class EncryptPage extends StatefulWidget {
  const EncryptPage({
    super.key,
    required this.controller,
    this.onOpenCloudSettings,
  });

  final AppController controller;
  final VoidCallback? onOpenCloudSettings;

  @override
  State<EncryptPage> createState() => _EncryptPageState();
}

final class _EncryptPageState extends State<EncryptPage> {
  final _textController = TextEditingController();
  final _nameController = TextEditingController(text: 'message.txt');
  final _store = CloudBackupConfigurationStore();
  final _credentialStore = PlatformCredentialStore();
  CloudBackupConfiguration? _configuration;
  SboxContentKind _contentKind = SboxContentKind.file;
  bool _loading = true;
  bool _credentialsReady = false;
  bool _busy = false;
  bool _dragging = false;
  bool _generatePreview = true;
  XFile? _selectedFile;
  int? _selectedFileLength;
  CloudBundleUploadProgress? _uploadProgress;

  @override
  void initState() {
    super.initState();
    _loadConfiguration();
  }

  @override
  void dispose() {
    _textController.clear();
    _nameController.clear();
    _textController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        PageHeading(
          title: '上传到公开云',
          subtitle: 'SafeBox 只把加密后的 SBOX 文件提交到 GitHub 和 Gitee；本地目录保留一份加密副本。',
          trailing: ElevatedButton.icon(
            onPressed:
                _busy ||
                    _loading ||
                    !_credentialsReady ||
                    !widget.controller.hasIdentity
                ? null
                : _upload,
            icon: const Icon(Icons.cloud_upload_outlined),
            label: const Text('加密并上传'),
          ),
        ),
        const SizedBox(height: 24),
        if (!widget.controller.hasIdentity)
          const SecurityNotice(
            title: '需要先准备身份',
            message: '首次使用请创建或恢复 12 词身份。身份只用于解密，公开云端不会保存助记词或私钥。',
            warning: true,
          ),
        const SizedBox(height: 16),
        _buildCloudCard(context),
        const SizedBox(height: 14),
        SboxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('选择内容', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 14),
              DropdownButtonFormField<SboxContentKind>(
                initialValue: _contentKind,
                decoration: const InputDecoration(labelText: '内容类型'),
                items: const <DropdownMenuItem<SboxContentKind>>[
                  DropdownMenuItem(
                    value: SboxContentKind.file,
                    child: Text('本地文件'),
                  ),
                  DropdownMenuItem(
                    value: SboxContentKind.text,
                    child: Text('纯文本'),
                  ),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _contentKind = value);
                        }
                      },
              ),
              const SizedBox(height: 14),
              if (_contentKind == SboxContentKind.file)
                ...<Widget>[
                  _buildFilePicker(context),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    value: _generatePreview,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _generatePreview = value),
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.image_outlined),
                    subtitle: const Text(
                      '仅上传图片或视频时生效；持有完整公钥的人可以读取缩略图，完整文件仍需验证。',
                    ),
                  ),
                ]
              else ...<Widget>[
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: '文件名',
                    hintText: 'message.txt',
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _textController,
                  maxLines: 10,
                  decoration: const InputDecoration(
                    labelText: '文本内容',
                    alignLabelWithHint: true,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (_busy)
          SboxProgressCard(
            title: _uploadProgress == null
                ? '正在加密并同步双云'
                : _uploadStageTitle(_uploadProgress!),
            detail: _uploadProgress == null
                ? '先写入本地加密副本，再通过 GitHub、Gitee API 同时创建文件。相同 MD5 文件不会重新生成或上传。'
                : _uploadProgress!.detailLabel,
            value: _uploadProgress?.fraction,
            progressLabel: _uploadProgress?.overallLabel,
          )
        else
          const SecurityNotice(
            title: '公开云只会看到密文',
            message: '本地备份目录中的文件名是 MD5 Bundle ID；GitHub 和 Gitee 中保存的是同一组加密分片。',
          ),
      ],
    ),
  );

  Widget _buildFilePicker(BuildContext context) {
    final file = _selectedFile;
    final accent = SboxColors.accent;
    return DropTarget(
      enable: !_busy,
      onDragEntered: (_) {
        if (!_busy && mounted) setState(() => _dragging = true);
      },
      onDragExited: (_) {
        if (mounted) setState(() => _dragging = false);
      },
      onDragDone: (detail) async {
        if (_busy) return;
        if (mounted) setState(() => _dragging = false);
        if (detail.files.isNotEmpty) {
          await _setFile(detail.files.first);
        }
      },
      child: Semantics(
        button: true,
        label: file == null ? '选择本地文件' : '已选择 ${file.name}',
        child: InkWell(
          onTap: _busy ? null : _pickFile,
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            constraints: const BoxConstraints(minHeight: 124),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              color: _dragging
                  ? accent.withValues(alpha: 0.08)
                  : SboxColors.panelSoft,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _dragging ? accent : SboxColors.border,
                width: _dragging ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  file == null
                      ? Icons.file_upload_outlined
                      : Icons.verified_outlined,
                  size: 34,
                  color: accent,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        file == null ? '拖拽文件到这里' : file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 5),
                      _buildFileSelectionHint(context, file),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: _busy ? null : _pickFile,
                  child: Text(file == null ? '选择文件' : '更换文件'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFileSelectionHint(BuildContext context, XFile? file) {
    if (file == null) {
      return Text(
        '或点击打开文件选择器',
        style: Theme.of(context).textTheme.bodyMedium,
      );
    }

    return TextButton(
      onPressed: _busy ? null : _pickFile,
      style: TextButton.styleFrom(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        '${_formatBytes(_selectedFileLength ?? 0)} · 点击可更换文件',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }

  Future<void> _pickFile() async {
    if (_busy) return;
    final file = await openFile(confirmButtonText: '选择');
    if (file != null) await _setFile(file);
  }

  Future<void> _setFile(XFile file) async {
    final path = file.path.trim();
    if (path.isEmpty ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file) {
      if (mounted) widget.controller.setError('请选择一个本地文件，而不是文件夹。');
      return;
    }
    final length = await File(path).length();
    if (!mounted) return;
    setState(() {
      _selectedFile = file;
      _selectedFileLength = length;
    });
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

  Widget _buildCloudCard(BuildContext context) {
    final configuration = _configuration;
    final ready = configuration != null && _credentialsReady;
    return SboxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '双云备份',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              StatusPill(
                label: ready ? 'GitHub + Gitee 已就绪' : '需要配置',
                icon: ready
                    ? Icons.cloud_done_outlined
                    : Icons.settings_outlined,
                tone: ready ? Colors.green : Colors.orange,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (configuration == null)
            const Text('请先设置本地加密备份目录、GitHub 仓库和 Gitee 仓库。')
          else ...<Widget>[
            _cloudLine(
              Icons.folder_outlined,
              '本地加密备份',
              configuration.backupDirectory,
            ),
            const SizedBox(height: 7),
            _cloudLine(
              Icons.cloud_outlined,
              'GitHub',
              '${configuration.github.owner}/${configuration.github.repository}',
            ),
            const SizedBox(height: 7),
            _cloudLine(
              Icons.cloud_outlined,
              'Gitee',
              '${configuration.gitee.owner}/${configuration.gitee.repository}',
            ),
          ],
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : widget.onOpenCloudSettings,
              icon: const Icon(Icons.tune_outlined),
              label: const Text('配置双云'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cloudLine(IconData icon, String label, String value) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Icon(icon, size: 18),
      const SizedBox(width: 9),
      SizedBox(width: 94, child: Text(label)),
      Expanded(child: MonospaceValue(value, maxLines: 2)),
    ],
  );

  Future<void> _loadConfiguration() async {
    try {
      final configuration = await _store.load();
      var credentialsReady = false;
      if (configuration != null) {
        final githubToken = await _credentialStore.getAccessToken(
          configuration.github.credentialId,
        );
        final giteeToken = await _credentialStore.getAccessToken(
          configuration.gitee.credentialId,
        );
        credentialsReady = githubToken != null && giteeToken != null;
        githubToken?.dispose();
        giteeToken?.dispose();
      }
      if (!mounted) return;
      setState(() {
        _configuration = configuration;
        _credentialsReady = credentialsReady;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      widget.controller.setError(error);
    }
  }

  Future<void> _upload() async {
    final record = widget.controller.identityRecord;
    final configuration = _configuration;
    if (record == null) {
      widget.controller.setError('请先创建或恢复身份。');
      return;
    }
    if (configuration == null) {
      widget.controller.setError('请先配置 GitHub、Gitee 和本地加密备份目录。');
      return;
    }

    Uint8List? textBytes;
    late final BundleInput input;
    late final int declaredLength;
    late final String originalName;
    var mediaType = 'application/octet-stream';
    BundlePreview? preview;
    PreviewUnavailableReason? previewUnavailableReason;
    if (_contentKind == SboxContentKind.file) {
      final selectedFile = _selectedFile;
      if (selectedFile == null) {
        widget.controller.setError('请拖拽或选择要上传的本地文件。');
        return;
      }
      final file = File(selectedFile.path);
      if (!await file.exists() ||
          await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file) {
        widget.controller.setError('找不到要上传的本地文件。');
        return;
      }
      input = FileBundleInput(file);
      declaredLength = await file.length();
      originalName = selectedFile.name.trim().isEmpty
          ? p.basename(file.path)
          : selectedFile.name;
    } else {
      if (!_isWellFormedUtf16(_textController.text)) {
        widget.controller.setError('文本包含不完整的 Unicode 字符。');
        return;
      }
      final name = _nameController.text.trim();
      if (name.isEmpty) {
        widget.controller.setError('请填写文本文件名。');
        return;
      }
      textBytes = utf8Bytes(_textController.text);
      input = MemoryBundleInput(textBytes);
      declaredLength = textBytes.length;
      originalName = name;
      mediaType = 'text/plain; charset=utf-8';
    }

    setState(() {
      _busy = true;
      _uploadProgress = null;
    });
    try {
      if (_contentKind == SboxContentKind.file && _generatePreview) {
        final generated = await const PlatformPreviewGenerator().generate(
          File((_selectedFile!).path),
        );
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
      CloudBundleUploadResult result;
      try {
        result =
            await CloudBundleUploader(
              credentialStore: PlatformCredentialStore(),
              client: client,
              logger: widget.controller.logger,
            ).upload(
              input: input,
              declaredLength: declaredLength,
              options: BundleEncryptionOptions(
                recipient: identity,
                contentKind: _contentKind,
                originalName: originalName,
                mediaType: mediaType,
                title: originalName,
                preview: preview,
                previewRequested: _contentKind == SboxContentKind.file &&
                    _generatePreview,
                previewUnavailableReason: previewUnavailableReason,
              ),
              configuration: configuration,
              onProgress: _handleUploadProgress,
            );
      } finally {
        client.close();
      }
      if (!mounted) return;
      final pushed = result.uploadedSources;
      if (result.duplicate && pushed.isEmpty) {
        widget.controller.setStatus(
          '上传成功：MD5 ${result.bundleId} 已存在，根对象 ${result.rootObjectName} 已同步，未重复上传。',
        );
      } else if (result.duplicate) {
        widget.controller.setStatus(
          '文件已存在；已补齐 ${pushed.join('、')} 的云端副本。根对象：${result.rootObjectName}',
        );
      } else {
        widget.controller.setStatus(
          '上传成功：已同步到 GitHub 和 Gitee。根对象：${result.rootObjectName}（MD5：${result.bundleId}）',
        );
      }
      if (!result.previewEmbedded) {
        widget.controller.setStatus(
          '${widget.controller.statusMessage ?? '上传成功'}；未嵌入缩略图（${_previewReasonLabel(result.previewUnavailableReason!)}）。',
        );
      }
    } catch (error) {
      if (mounted) {
        widget.controller.setError(error, operation: '加密并上传文件失败');
        final message = error is SboxException
            ? error.message
            : '发生未知错误，请稍后重试。';
        _showErrorFeedback('上传失败：$message');
      }
    } finally {
      final bytes = textBytes;
      if (bytes != null) bytes.fillRange(0, bytes.length, 0);
      preview?.dispose();
      if (mounted) {
        setState(() {
          _busy = false;
          _uploadProgress = null;
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

  void _handleUploadProgress(CloudBundleUploadProgress progress) {
    if (!mounted) return;
    setState(() => _uploadProgress = progress);
  }

  static String _uploadStageTitle(CloudBundleUploadProgress progress) {
    return switch (progress.stage) {
      CloudBundleUploadStage.preparing => '正在准备上传',
      CloudBundleUploadStage.uploading => '正在上传加密分片',
      CloudBundleUploadStage.verifying => '正在核对云端分片',
      CloudBundleUploadStage.completed => '上传完成，正在收尾',
    };
  }

  void _showErrorFeedback(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
  }

  static bool _isWellFormedUtf16(String value) {
    final units = value.codeUnits;
    for (var index = 0; index < units.length; index++) {
      final unit = units[index];
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (index + 1 >= units.length ||
            units[index + 1] < 0xdc00 ||
            units[index + 1] > 0xdfff) {
          return false;
        }
        index++;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        return false;
      }
    }
    return true;
  }
}
