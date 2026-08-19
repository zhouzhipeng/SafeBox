import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../app/app_controller.dart';
import '../../app/sbox_widgets.dart';
import '../../platform/cloud_backup_configuration_store.dart';
import '../../sbox/bytes.dart';
import '../../sbox/errors.dart';
import '../../sbox/source/bundle_listing.dart';
import '../../sbox/source/bundle_sync.dart';
import '../../sbox/source/cloud_repository_pair.dart';
import '../../sbox/source/data_source.dart';
import '../../sbox/source/source_path.dart';

final class DecryptPage extends StatefulWidget {
  const DecryptPage({
    super.key,
    required this.controller,
    this.onOpenCloudSettings,
  });

  final AppController controller;
  final VoidCallback? onOpenCloudSettings;

  @override
  State<DecryptPage> createState() => _DecryptPageState();
}

final class _DecryptPageState extends State<DecryptPage> {
  final _rootController = TextEditingController();
  final _mnemonicController = TextEditingController();
  final _destinationController = TextEditingController();
  final _configurationStore = CloudBackupConfigurationStore();
  http.Client? _client;
  CloudRepositoryPair? _pair;
  bool _loading = true;
  bool _busy = false;
  BundleDownloadProgress? _downloadProgress;

  @override
  void initState() {
    super.initState();
    _loadConfiguration();
  }

  @override
  void dispose() {
    _rootController.clear();
    _mnemonicController.clear();
    _destinationController.clear();
    _rootController.dispose();
    _mnemonicController.dispose();
    _destinationController.dispose();
    _client?.close();
    _pair = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        PageHeading(
          title: '从公开云下载解密',
          subtitle: '通过 GitHub 和 Gitee API 读取单个 Bundle；校验所有分片后才会写入本地明文目标。',
          trailing: ElevatedButton.icon(
            onPressed:
                _busy ||
                    _loading ||
                    _pair == null ||
                    _pair!.enabledSources.isEmpty
                ? null
                : _decrypt,
            icon: const Icon(Icons.lock_open_outlined),
            label: const Text('下载并解密'),
          ),
        ),
        const SizedBox(height: 24),
        if (_loading)
          const SboxProgressCard(
            title: '读取双云设置',
            detail: '仅加载 API 地址和本地凭据引用，不下载云端文件。',
          )
        else if (_pair == null)
          SboxCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const SecurityNotice(
                  title: '请先配置 GitHub 和 Gitee',
                  message: '解密页面通过 HTTP API 读取云端密文，不使用本地 Git 仓库。',
                  warning: true,
                ),
                if (widget.onOpenCloudSettings != null) ...<Widget>[
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: widget.onOpenCloudSettings,
                    icon: const Icon(Icons.tune_outlined),
                    label: const Text('打开双云设置'),
                  ),
                ],
              ],
            ),
          ),
        const SizedBox(height: 16),
        SboxCard(
          child: Column(
            children: <Widget>[
              TextField(
                controller: _rootController,
                decoration: const InputDecoration(
                  labelText: '根对象名或 MD5',
                  hintText: '<md5>.sbox 或直接填写 32 位 MD5',
                  helperText: '填写上传成功后显示的根对象名；只填 MD5 时会从云端目录定位根分片。',
                  prefixIcon: Icon(Icons.inventory_2_outlined),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _mnemonicController,
                obscureText: true,
                maxLines: 1,
                decoration: const InputDecoration(
                  labelText: '12 词 BIP39 助记词',
                  prefixIcon: Icon(Icons.key_outlined),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _destinationController,
                decoration: const InputDecoration(
                  labelText: '明文保存路径',
                  hintText: 'D:\\restored\\original-name.txt',
                  helperText: '目标文件已存在时不会覆盖。',
                  prefixIcon: Icon(Icons.save_alt_outlined),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (_busy)
          SboxProgressCard(
            title: _downloadProgress == null
                ? '正在读取、校验并解密'
                : _downloadStageTitle(_downloadProgress!.stage),
            detail:
                _downloadProgress?.detailLabel ??
                '只有所有分片、Final 值、长度、SHA-256 和 UTF-8 校验通过后，才发布明文文件。',
            value: _downloadProgress?.fraction,
            progressLabel: _downloadProgress?.overallLabel,
          )
        else
          const SecurityNotice(
            title: '双云自动容错',
            message:
                '默认先尝试 GitHub；如果对象缺失或 API 暂时不可用，会自动尝试 Gitee。助记词只在本次操作中使用，不会上传。',
          ),
      ],
    ),
  );

  Future<void> _loadConfiguration() async {
    http.Client? nextClient;
    try {
      final configuration = await _configurationStore.load();
      if (configuration == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final client = http.Client();
      nextClient = client;
      final pair = CloudRepositoryPair.fromConfiguration(
        configuration: configuration,
        client: client,
        logger: widget.controller.logger,
      );
      if (!mounted) return;
      _client?.close();
      _client = client;
      _pair = pair;
      nextClient = null;
      setState(() => _loading = false);
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      widget.controller.setError(error, operation: '读取云端配置失败');
    } finally {
      nextClient?.close();
    }
  }

  Future<void> _decrypt() async {
    final rootName = _rootController.text.trim();
    final mnemonic = _mnemonicController.text.trim();
    final destinationPath = _destinationController.text.trim();
    final pair = _pair;
    if (pair == null) {
      widget.controller.setError('请先配置 GitHub 和 Gitee。');
      return;
    }
    if (rootName.isEmpty || mnemonic.isEmpty || destinationPath.isEmpty) {
      widget.controller.setError('根对象名、助记词和明文保存路径不能为空。');
      return;
    }

    late final SourcePath explicitRootPath;
    try {
      explicitRootPath = SourcePath(rootName);
    } on Object catch (error) {
      widget.controller.setError(error, operation: '检查云端对象名失败');
      return;
    }

    setState(() {
      _busy = true;
      _downloadProgress = null;
    });
    Object? lastError;
    final sources = pair.enabledSources
        .map<({String name, DataSource source})>(
          (source) => (name: source.name, source: source.source),
        )
        .toList(growable: false);
    try {
      for (final candidate in sources) {
        try {
          final rootPath = await _resolveRootPath(
            source: candidate.source,
            input: rootName,
            explicit: explicitRootPath,
          );
          await BundleSync.fetchAndDecryptToFileStreaming(
            source: candidate.source,
            rootPath: rootPath,
            mnemonic: mnemonic,
            destination: File(destinationPath),
            onProgress: _handleDownloadProgress,
          );
          if (mounted) {
            widget.controller.setStatus(
              '解密成功：已从 ${candidate.name} API 校验并保存到 ${File(destinationPath).path}。',
            );
          }
          return;
        } catch (error) {
          lastError = error;
          if (!_shouldTryOtherSource(error)) rethrow;
        }
      }
      throw lastError ?? StateError('没有可用的云数据源');
    } catch (error) {
      if (mounted) {
        widget.controller.setError(error, operation: '下载并解密云端文件失败');
      }
    } finally {
      _mnemonicController.clear();
      if (mounted) {
        setState(() {
          _busy = false;
          _downloadProgress = null;
        });
      }
    }
  }

  void _handleDownloadProgress(BundleDownloadProgress progress) {
    if (!mounted) return;
    setState(() => _downloadProgress = progress);
  }

  static String _downloadStageTitle(BundleDownloadStage stage) {
    return switch (stage) {
      BundleDownloadStage.preparing => '正在读取文件信息',
      BundleDownloadStage.downloading => '正在下载加密文件',
      BundleDownloadStage.decrypting => '正在解密文件',
      BundleDownloadStage.merging => '正在合并文件',
    };
  }

  static Future<SourcePath> _resolveRootPath({
    required DataSource source,
    required String input,
    required SourcePath explicit,
  }) async {
    if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(input)) return explicit;
    if (source is! EnumerableDataSource) {
      throw const SboxException(
        SboxErrorCode.listingUnsupported,
        '当前数据源不支持按 MD5 定位根对象',
      );
    }
    final roots = await BundleListing.listRoots(source, includePreview: false);
    final wanted = input.toLowerCase();
    final matches = roots
        .where((root) => hexLower(root.header.bundleId) == wanted)
        .toList(growable: false);
    if (matches.isEmpty) {
      throw const SboxException(
        SboxErrorCode.sourceNotFound,
        '未找到对应的 Bundle 根对象',
      );
    }
    if (matches.length > 1) {
      throw const SboxException(
        SboxErrorCode.immutableConflict,
        '同一 MD5 存在多个根对象版本',
      );
    }
    return matches.single.path;
  }

  static bool _shouldTryOtherSource(Object error) {
    if (error is! SboxException) return false;
    return switch (error.code) {
      SboxErrorCode.sourceNotFound ||
      SboxErrorCode.shardMissing ||
      SboxErrorCode.sourceAuthentication ||
      SboxErrorCode.sourceNetwork ||
      SboxErrorCode.sourceRateLimit ||
      SboxErrorCode.listingUnsupported ||
      SboxErrorCode.remoteChanged => true,
      _ => false,
    };
  }
}
