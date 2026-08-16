import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_controller.dart';
import '../../app/sbox_dialogs.dart';
import '../../app/sbox_theme.dart';
import '../../app/sbox_widgets.dart';
import '../../sbox/source/local_scanner.dart';
import '../../sbox/source/source_config.dart';

class SourcesPage extends StatefulWidget {
  const SourcesPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends State<SourcesPage> {
  Future<void> _addSource() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog.fullscreen(
        backgroundColor: SboxColors.background,
        child: AddSourceView(
          controller: widget.controller,
          onClose: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  Future<void> _test(SourceConfiguration source) async {
    try {
      await widget.controller.selectSource(source.sourceId);
      await widget.controller.refreshSelectedSource(
        verifyRemoteRepository: source.isRemote,
        allowMissingRemoteCatalog:
            source.provider == SourceProvider.github ||
            source.provider == SourceProvider.gitee,
      );
      if (!mounted ||
          source.localDirectoryMode == ConfiguredLocalMode.looseReadOnly) {
        return;
      }
      final catalog = File(
        '${source.localSyncPath}${Platform.pathSeparator}catalog.sbox',
      );
      if (!await catalog.exists()) {
        return;
      }
      if (!mounted) {
        return;
      }
      final mnemonic = await showMnemonicPrompt(
        context,
        title: source.isRemote ? '测试目录解密与签名验证' : '校验本地 Catalog',
        actionLabel: '完成验证',
      );
      if (mnemonic != null) {
        await widget.controller.unlockSelectedCatalog(
          mnemonic,
          syncObjects: false,
        );
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final selected = controller.selectedSource;
    return ListView(
      padding: const EdgeInsets.fromLTRB(34, 34, 34, 30),
      children: <Widget>[
        PageHeading(
          title: '数据源',
          subtitle: '本地目录优先；公开 GitHub、Gitee 与 HTTPS 只保存和传输加密 SBOX',
          trailing: ElevatedButton.icon(
            onPressed: controller.isBusy ? null : _addSource,
            icon: const Icon(Icons.add_rounded),
            label: const Text('添加数据源'),
          ),
        ),
        const SizedBox(height: 24),
        if (controller.sources.isEmpty)
          EmptyState(
            icon: Icons.storage_outlined,
            title: '没有数据源配置',
            message: '推荐先打开一个本地 SBOX 目录；不需要账号，不会访问网络。云端仓库可以以后再添加。',
            actions: <Widget>[
              ElevatedButton.icon(
                onPressed: _addSource,
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('打开本地 SBOX 目录'),
              ),
            ],
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 830;
              final list = _SourceList(controller: controller);
              final detail = selected == null
                  ? const EmptyState(
                      icon: Icons.touch_app_outlined,
                      title: '选择一个数据源',
                      message: '查看其本地镜像、授权状态、能力限制与同步策略。',
                    )
                  : _SourceDetail(
                      controller: controller,
                      source: selected,
                      onTest: () => _test(selected),
                    );
              return narrow
                  ? Column(
                      children: <Widget>[
                        list,
                        const SizedBox(height: 16),
                        detail,
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SizedBox(width: 340, child: list),
                        const SizedBox(width: 18),
                        Expanded(child: detail),
                      ],
                    );
            },
          ),
        if (controller.isBusy) ...<Widget>[
          const SizedBox(height: 16),
          SboxProgressCard(
            title: controller.operation == AppOperation.unlockingCatalog
                ? '正在验证加密目录'
                : '正在刷新或同步数据源',
            detail: controller.syncProgress == null
                ? '只处理加密对象；访问令牌与数据源身份不会混用。'
                : '${controller.syncProgress!.completed}/${controller.syncProgress!.total}',
            value:
                controller.syncProgress == null ||
                    controller.syncProgress!.total == 0
                ? null
                : controller.syncProgress!.completed /
                      controller.syncProgress!.total,
            onCancel: controller.cancelSensitiveWork,
          ),
        ],
      ],
    );
  }
}

class _SourceList extends StatelessWidget {
  const _SourceList({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      for (final source in controller.sources)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: InkWell(
            onTap: () => controller.selectSource(source.sourceId),
            borderRadius: BorderRadius.circular(13),
            child: SboxCard(
              color: controller.selectedSource?.sourceId == source.sourceId
                  ? const Color(0xFF102722)
                  : SboxColors.panel,
              borderColor:
                  controller.selectedSource?.sourceId == source.sourceId
                  ? SboxColors.accent.withValues(alpha: 0.42)
                  : SboxColors.borderSoft,
              padding: const EdgeInsets.all(15),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 43,
                    height: 43,
                    decoration: BoxDecoration(
                      color: _providerColor(source.provider)
                          .withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(
                      _providerIcon(source.provider),
                      color: _providerColor(source.provider),
                      size: 23,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          source.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _sourceSubtitle(source),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    controller.selectedSource?.sourceId == source.sourceId
                        ? Icons.chevron_right_rounded
                        : Icons.more_horiz_rounded,
                    color: SboxColors.textDim,
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}

class _SourceDetail extends StatefulWidget {
  const _SourceDetail({
    required this.controller,
    required this.source,
    required this.onTest,
  });
  final AppController controller;
  final SourceConfiguration source;
  final VoidCallback onTest;

  @override
  State<_SourceDetail> createState() => _SourceDetailState();
}

class _SourceDetailState extends State<_SourceDetail> {
  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final local = source.provider == SourceProvider.local;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SboxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      color: _providerColor(source.provider)
                          .withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(
                      _providerIcon(source.provider),
                      color: _providerColor(source.provider),
                      size: 27,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          source.displayName,
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _sourceSubtitle(source),
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  StatusPill(
                    label: local
                        ? '文件系统授权有效'
                        : (source.isWritable ? '匿名读 · 授权写' : '公开匿名读取'),
                    icon: local
                        ? Icons.folder_shared_outlined
                        : Icons.public_rounded,
                    tone: SboxColors.success,
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 12),
              _Detail(label: '提供方', value: _providerName(source.provider)),
              if (!local &&
                  source.provider != SourceProvider.https) ...<Widget>[
                _Detail(
                  label: '仓库',
                  value: '${source.owner}/${source.repository}',
                  mono: true,
                ),
                _Detail(
                  label: '分支 / Ref',
                  value: source.branchOrRef ?? 'main',
                  mono: true,
                ),
                _Detail(
                  label: '目录前缀',
                  value: source.pathPrefix.isEmpty
                      ? '仓库根目录'
                      : source.pathPrefix,
                  mono: true,
                ),
              ],
              if (source.provider == SourceProvider.https)
                _Detail(
                  label: '只读基址',
                  value: source.httpsBaseUri.toString(),
                  mono: true,
                ),
              if (local)
                _Detail(
                  label: '目录模式',
                  value:
                      source.localDirectoryMode ==
                          ConfiguredLocalMode.canonicalCatalog
                      ? 'canonical_catalog · ${source.isWritable ? '可读写' : '只读'}'
                      : 'loose_read_only · 只读',
                ),
              if (source.isAuthorizedDirectory)
                _Detail(
                  label: '系统授权来源',
                  value:
                      '${source.directoryAuthorizationDisplayName} · '
                      '${source.directoryAuthorizationPlatform} · 只读',
                ),
              _Detail(
                label: source.isAuthorizedDirectory ? '永久密文镜像' : '本地 SBOX 目录',
                value: source.localSyncPath,
                mono: true,
              ),
              _Detail(
                label: 'Catalog 路径',
                value: source.provider == SourceProvider.local
                    ? 'catalog.sbox（目录根部）'
                    : source.catalogPath,
                mono: true,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: <Widget>[
                  ElevatedButton.icon(
                    onPressed: widget.controller.isBusy ? null : widget.onTest,
                    icon: Icon(
                      local
                          ? Icons.refresh_rounded
                          : Icons.network_check_rounded,
                    ),
                    label: Text(local ? '刷新并校验本地密文' : '测试连接与目录验证'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      try {
                        await widget.controller.openLocalPath(
                          source.localSyncPath,
                        );
                      } catch (_) {}
                    },
                    icon: const Icon(Icons.folder_open_outlined),
                    label: const Text('打开本地目录'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        SboxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SectionTitle(
                title: local ? '本地目录刷新' : '自动同步',
                subtitle: local ? '本地源从不创建网络队列' : '只同步 SBOX 密文；移动后台受系统限制',
              ),
              const SizedBox(height: 16),
              if (local)
                SwitchListTile.adaptive(
                  value: false,
                  onChanged: (_) {},
                  contentPadding: EdgeInsets.zero,
                  title: const Text('目录变化时自动刷新'),
                  subtitle: const Text('默认关闭；手动“刷新目录”始终可用。'),
                )
              else ...<Widget>[
                SwitchListTile.adaptive(
                  value: source.syncPolicy != SourceSyncPolicy.manual,
                  onChanged: (enabled) => widget.controller.updateSyncPolicy(
                    source.sourceId,
                    enabled
                        ? SourceSyncPolicy.wifiOnly
                        : SourceSyncPolicy.manual,
                  ),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('自动同步'),
                  subtitle: const Text('只在没有私钥任务时同步公开密文。'),
                ),
                RadioGroup<SourceSyncPolicy>(
                  groupValue: source.syncPolicy,
                  onChanged: (value) {
                    if (value != null) {
                      widget.controller.updateSyncPolicy(
                        source.sourceId,
                        value,
                      );
                    }
                  },
                  child: Column(
                    children: const <Widget>[
                      RadioListTile<SourceSyncPolicy>(
                        value: SourceSyncPolicy.manual,
                        title: Text('仅手动'),
                      ),
                      RadioListTile<SourceSyncPolicy>(
                        value: SourceSyncPolicy.wifiOnly,
                        title: Text('仅 Wi-Fi / 有线网络'),
                      ),
                      RadioListTile<SourceSyncPolicy>(
                        value: SourceSyncPolicy.anyNetwork,
                        title: Text('任意网络（计量网络需确认）'),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        SboxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SectionTitle(title: '本地全量密文镜像', subtitle: '这里是用户数据，不是缓存'),
              const SizedBox(height: 14),
              FutureBuilder<SourceLocalStats>(
                future: widget.controller.sourceStats(source),
                builder: (context, snapshot) {
                  final stats = snapshot.data;
                  return Row(
                    children: <Widget>[
                      Expanded(
                        child: _Metric(
                          label: 'SBOX 对象',
                          value: stats == null ? '…' : '${stats.objectCount}',
                        ),
                      ),
                      Expanded(
                        child: _Metric(
                          label: '占用空间',
                          value: stats == null
                              ? '…'
                              : _formatBytes(stats.totalBytes),
                        ),
                      ),
                      Expanded(
                        child: _Metric(label: '分片明文边界', value: '16 MiB'),
                      ),
                      Expanded(
                        child: _Metric(
                          label: '并发传输上限',
                          value: local
                              ? '4'
                              : (source.provider == SourceProvider.gitee
                                    ? '2'
                                    : '4'),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 14),
              const SecurityNotice(
                title: '可安全备份或放入云盘',
                message: '此目录永久保存加密后的 .sbox 原件；不会保存助记词、私钥、解密 Catalog 或解密明文。',
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        SboxCard(
          borderColor: SboxColors.danger.withValues(alpha: 0.22),
          child: Row(
            children: <Widget>[
              const Icon(Icons.link_off_rounded, color: SboxColors.danger),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '断开数据源',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    SizedBox(height: 4),
                    Text(
                      '只删除应用内配置和访问令牌；不会删除仓库内容或本地 SBOX 原件。',
                      style: TextStyle(
                        color: SboxColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: SboxColors.danger,
                  side: const BorderSide(color: SboxColors.danger),
                ),
                onPressed: () async {
                  final confirmed = await showDestructiveConfirmation(
                    context,
                    title: '断开此数据源？',
                    message: '只移除配置和数据源访问令牌。远端仓库、用户选择的本地目录及其中全部 .sbox 原件将永久保留。',
                    actionLabel: '仅断开配置',
                  );
                  if (confirmed) {
                    await widget.controller.removeSource(source.sourceId);
                  }
                },
                child: const Text('断开连接'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class AddSourceView extends StatefulWidget {
  const AddSourceView({
    super.key,
    required this.controller,
    required this.onClose,
  });
  final AppController controller;
  final VoidCallback onClose;

  @override
  State<AddSourceView> createState() => _AddSourceViewState();
}

class _AddSourceViewState extends State<AddSourceView>
    with WidgetsBindingObserver {
  SourceProvider _provider = SourceProvider.local;
  final _displayName = TextEditingController(text: '本地 SBOX 目录');
  final _owner = TextEditingController();
  final _repository = TextEditingController();
  final _branch = TextEditingController(text: 'main');
  final _prefix = TextEditingController();
  final _httpsUrl = TextEditingController();
  final _token = TextEditingController();
  String? _localPath;
  String? _mirrorParent;
  LocalDirectoryProbe? _probe;
  bool _requestWrite = true;
  bool _initializeEmpty = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.defaultRemoteMirrorParent().then((path) {
      if (mounted) setState(() => _mirrorParent = path);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _token.clear();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _token.clear();
    for (final controller in <TextEditingController>[
      _displayName,
      _owner,
      _repository,
      _branch,
      _prefix,
      _httpsUrl,
      _token,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _chooseLocal() async {
    if (widget.controller.supportsAuthorizedDirectorySelection) {
      try {
        final added = await widget.controller
            .chooseAndAddAuthorizedLocalSource();
        if (added && mounted) Navigator.of(context).pop();
      } catch (_) {
        if (mounted) {
          setState(() => _error = widget.controller.errorMessage ?? '系统目录授权失败');
        }
      }
      return;
    }
    final path = await widget.controller.chooseLocalCipherDirectory(
      confirmButtonText: '选择此目录',
    );
    if (path == null) return;
    try {
      final probe = await widget.controller.inspectLocalDirectory(path);
      final empty =
          probe.catalogHeader == null &&
          await Directory(path).list(followLinks: false).isEmpty;
      setState(() {
        _localPath = path;
        _probe = probe;
        _initializeEmpty = empty;
        _error = null;
      });
    } catch (_) {
      setState(() => _error = widget.controller.errorMessage ?? '目录识别失败');
    }
  }

  Future<void> _chooseMirrorParent() async {
    final path = await widget.controller.chooseRemoteMirrorParentDirectory();
    if (path != null) setState(() => _mirrorParent = path);
  }

  Future<void> _createManagedLocal() async {
    try {
      await widget.controller.addManagedWritableLocalSource();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = widget.controller.errorMessage ?? '无法创建本机可写保险箱',
        );
      }
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_provider == SourceProvider.local) {
        if (_localPath == null) throw ArgumentError('请选择本地目录');
        await widget.controller.addLocalSource(
          displayName: _displayName.text.trim(),
          path: _localPath!,
          requestWrite: _requestWrite,
          initializeEmptyAsCanonical: _initializeEmpty,
        );
      } else {
        final mirror = _mirrorParent;
        if (mirror == null) throw ArgumentError('请选择本地密文镜像目录');
        await widget.controller.addRemoteSource(
          displayName: _displayName.text.trim(),
          provider: _provider,
          localMirrorParent: mirror,
          owner: _provider == SourceProvider.https ? null : _owner.text.trim(),
          repository: _provider == SourceProvider.https
              ? null
              : _repository.text.trim(),
          branch: _branch.text.trim(),
          pathPrefix: _prefix.text.trim(),
          httpsBaseUri: _provider == SourceProvider.https
              ? Uri.parse(_httpsUrl.text.trim())
              : null,
          accessToken:
              _provider == SourceProvider.https || _token.text.trim().isEmpty
              ? null
              : _token.text.trim(),
        );
        _token.clear();
      }
      widget.onClose();
    } catch (_) {
      if (mounted) {
        setState(() => _error = widget.controller.errorMessage ?? '请检查所有必填字段');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: <Widget>[
          Container(
            height: 70,
            padding: const EdgeInsets.symmetric(horizontal: 28),
            decoration: const BoxDecoration(
              color: SboxColors.sidebar,
              border: Border(bottom: BorderSide(color: SboxColors.borderSoft)),
            ),
            child: Row(
              children: <Widget>[
                IconButton(
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: '返回数据源',
                ),
                const SizedBox(width: 8),
                const SboxLogo(compact: true),
                const Spacer(),
                const StatusPill(
                  label: '配置不包含私钥',
                  icon: Icons.shield_outlined,
                  tone: SboxColors.accent,
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 30, 22, 42),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 980),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(
                        '添加数据源',
                        style: Theme.of(context).textTheme.displaySmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '本地目录是推荐主选项；GitHub、Gitee 与 HTTPS 都是可选的公开密文存储。',
                        style: Theme.of(context).textTheme.bodyLarge
                            ?.copyWith(color: SboxColors.textMuted),
                      ),
                      const SizedBox(height: 24),
                      const _AddSteps(),
                      const SizedBox(height: 20),
                      SboxCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            const SectionTitle(
                              title: '1. 选择数据源类型',
                              subtitle: '云端不是必经步骤',
                            ),
                            const SizedBox(height: 16),
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final width = constraints.maxWidth < 650
                                    ? constraints.maxWidth
                                    : (constraints.maxWidth - 12) / 2;
                                return Wrap(
                                  spacing: 12,
                                  runSpacing: 12,
                                  children: <Widget>[
                                    SizedBox(
                                      width: width,
                                      child: _ProviderChoice(
                                        provider: SourceProvider.local,
                                        title: '本地 SBOX 目录',
                                        subtitle: '不需要账号 · 完全离线',
                                        icon: Icons.folder_outlined,
                                        selected:
                                            _provider == SourceProvider.local,
                                        recommended: true,
                                        onTap: () => _selectProvider(
                                          SourceProvider.local,
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: width,
                                      child: _ProviderChoice(
                                        provider: SourceProvider.github,
                                        title: 'GitHub 公开仓库',
                                        subtitle: '匿名读取 · 可选授权写入',
                                        icon: Icons.code_rounded,
                                        selected:
                                            _provider == SourceProvider.github,
                                        onTap: () => _selectProvider(
                                          SourceProvider.github,
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: width,
                                      child: _ProviderChoice(
                                        provider: SourceProvider.gitee,
                                        title: 'Gitee 公开仓库',
                                        subtitle: '匿名读取 · 可选授权写入',
                                        icon: Icons.account_tree_outlined,
                                        selected:
                                            _provider == SourceProvider.gitee,
                                        onTap: () => _selectProvider(
                                          SourceProvider.gitee,
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: width,
                                      child: _ProviderChoice(
                                        provider: SourceProvider.https,
                                        title: '只读 HTTPS',
                                        subtitle: '无需账号 · 仅获取密文',
                                        icon: Icons.public_rounded,
                                        selected:
                                            _provider == SourceProvider.https,
                                        onTap: () => _selectProvider(
                                          SourceProvider.https,
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      SboxCard(
                        child: _provider == SourceProvider.local
                            ? _localForm(context)
                            : _remoteForm(context),
                      ),
                      const SizedBox(height: 16),
                      const SecurityNotice(
                        title: '本地永久密文与凭据边界',
                        message: '完整 .sbox 原件保存在所选本地目录。仓库访问令牌只进入系统安全存储；助记词、BIP39 Seed、RSA/Ed25519 私钥和 DEK 无法传入该接口。',
                      ),
                      if (_error != null) ...<Widget>[
                        const SizedBox(height: 14),
                        SecurityNotice(
                          title: '无法保存配置',
                          message: _error!,
                          warning: true,
                        ),
                      ],
                      const SizedBox(height: 20),
                      Row(
                        children: <Widget>[
                          OutlinedButton(
                            onPressed: _saving ? null : widget.onClose,
                            child: const Text('取消'),
                          ),
                          const Spacer(),
                          ElevatedButton.icon(
                            onPressed: _saving ? null : _save,
                            icon: _saving
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.check_rounded),
                            label: Text(
                              _provider == SourceProvider.local
                                  ? '打开本地目录'
                                  : '保存数据源',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _selectProvider(SourceProvider provider) {
    setState(() {
      _provider = provider;
      _displayName.text = switch (provider) {
        SourceProvider.local => '本地 SBOX 目录',
        SourceProvider.github => 'GitHub 资料库',
        SourceProvider.gitee => 'Gitee 资料库',
        SourceProvider.https => 'HTTPS 只读资料库',
      };
      _error = null;
    });
  }

  Widget _localForm(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      const SectionTitle(
        title: '2. 打开本地 SBOX 目录',
        subtitle: '只显示名称、目录、实际读写能力与识别结果',
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _displayName,
        decoration: const InputDecoration(labelText: '显示名称'),
      ),
      const SizedBox(height: 12),
      InkWell(
        onTap: _chooseLocal,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.all(17),
          decoration: BoxDecoration(
            color: SboxColors.panelSoft,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _localPath == null
                  ? SboxColors.border
                  : SboxColors.accent.withValues(alpha: 0.5),
            ),
          ),
          child: Row(
            children: <Widget>[
              const Icon(
                Icons.folder_open_outlined,
                color: SboxColors.accent,
                size: 28,
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _localPath ?? '选择目录',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _probe == null
                          ? '系统目录选择器会保留平台授权'
                          : (_probe!.catalogHeader != null
                                ? '识别结果：规范 Catalog 目录'
                                : (_initializeEmpty
                                      ? '识别结果：空目录，可初始化'
                                      : '识别结果：散装 SBOX，只读')),
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
      const SizedBox(height: 12),
      SwitchListTile.adaptive(
        value: _requestWrite,
        onChanged: (value) => setState(() => _requestWrite = value),
        contentPadding: EdgeInsets.zero,
        title: const Text('请求可写模式'),
        subtitle: const Text('平台或目录不支持可靠原子写入时会自动降级为只读。'),
      ),
      if (widget.controller.supportsAuthorizedDirectorySelection) ...<Widget>[
        const SizedBox(height: 4),
        OutlinedButton.icon(
          onPressed: _createManagedLocal,
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('改用应用管理目录（可写）'),
        ),
      ],
      if (_probe != null && _probe!.catalogHeader == null && _initializeEmpty)
        CheckboxListTile(
          value: _initializeEmpty,
          onChanged: (value) =>
              setState(() => _initializeEmpty = value ?? false),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('明确确认：将空目录作为 canonical_catalog 使用'),
          subtitle: const Text('首次加密时创建 catalog.sbox 与 objects/；不会创建云端配置。'),
        ),
    ],
  );

  Widget _remoteForm(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      const SectionTitle(title: '2. 仓库与本地密文镜像', subtitle: '远端公开读取与授权写入是两个独立状态'),
      const SizedBox(height: 16),
      TextField(
        controller: _displayName,
        decoration: const InputDecoration(labelText: '显示名称'),
      ),
      const SizedBox(height: 12),
      if (_provider == SourceProvider.https)
        TextField(
          controller: _httpsUrl,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'HTTPS 基址',
            hintText: 'https://example.com/safebox/',
          ),
        )
      else ...<Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _owner,
                decoration: const InputDecoration(labelText: 'Owner / 用户名'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _repository,
                decoration: const InputDecoration(labelText: '公开仓库名'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _branch,
                decoration: const InputDecoration(labelText: '分支 / Ref'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _prefix,
                decoration: const InputDecoration(
                  labelText: '目录前缀（可选）',
                  hintText: 'vault',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _token,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: null,
          keyboardType: TextInputType.visiblePassword,
          decoration: InputDecoration(
            labelText: '写入访问令牌（可选）',
            helperText: '留空时保持公开匿名只读。令牌只保存到系统 Keychain / Keystore。',
            suffixIcon: IconButton(
              onPressed: _token.clear,
              icon: const Icon(Icons.clear_rounded),
              tooltip: '清除令牌',
            ),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => launchUrl(
              Uri.parse(
                _provider == SourceProvider.github
                    ? 'https://github.com/settings/tokens'
                    : 'https://gitee.com/profile/personal_access_tokens',
              ),
            ),
            icon: const Icon(Icons.open_in_browser_rounded),
            label: const Text('在系统浏览器中创建写入令牌'),
          ),
        ),
      ],
      const SizedBox(height: 14),
      InkWell(
        onTap: _chooseMirrorParent,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: SboxColors.panelSoft,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: SboxColors.border),
          ),
          child: Row(
            children: <Widget>[
              const Icon(Icons.save_outlined, color: SboxColors.accent),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      '本地全量 SBOX 镜像根目录',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _mirrorParent ?? '正在准备应用支持目录…',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
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
      const SizedBox(height: 12),
      SecurityNotice(
        title: '能力预检',
        message: _provider == SourceProvider.gitee
            ? '单对象保守上限 20 MiB；默认 16 MiB 明文分片可用；Base64/JSON 请求开销已计入。'
            : _provider == SourceProvider.github
            ? '单对象上限 100 MiB；默认 16 MiB 明文分片可用；最多并发 4 个密文对象。'
            : '只读 HTTPS 要求 HTTPS、受限重定向和明确 Content-Length；不会发送 Authorization。',
      ),
    ],
  );
}

class _AddSteps extends StatelessWidget {
  const _AddSteps();
  @override
  Widget build(BuildContext context) => SboxCard(
    color: SboxColors.panelSoft,
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    child: Row(
      children: <Widget>[
        for (final item in const <(int, String)>[
          (1, '选择类型'),
          (2, '填写与检测'),
          (3, '确认保存'),
        ]) ...<Widget>[
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: SboxColors.accent,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${item.$1}',
                    style: const TextStyle(
                      color: Color(0xFF03211D),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    item.$2,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          if (item.$1 < 3)
            const SizedBox(width: 38, child: Divider(color: SboxColors.border)),
        ],
      ],
    ),
  );
}

class _ProviderChoice extends StatelessWidget {
  const _ProviderChoice({
    required this.provider,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.recommended = false,
  });
  final SourceProvider provider;
  final String title;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final bool recommended;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(11),
    child: Container(
      constraints: const BoxConstraints(minHeight: 92),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: selected
            ? SboxColors.accent.withValues(alpha: 0.09)
            : SboxColors.panelSoft,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: selected ? SboxColors.accent : SboxColors.border,
        ),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _providerColor(provider).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, color: _providerColor(provider)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (recommended) ...<Widget>[
                      const SizedBox(width: 8),
                      const StatusPill(
                        label: '推荐',
                        icon: Icons.star_outline,
                        tone: SboxColors.accent,
                        compact: true,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
          Icon(
            selected ? Icons.radio_button_checked : Icons.radio_button_off,
            color: selected ? SboxColors.accent : SboxColors.textDim,
          ),
        ],
      ),
    ),
  );
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.value, this.mono = false});
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
          width: 135,
          child: Text(
            label,
            style: const TextStyle(color: SboxColors.textDim, fontSize: 12),
          ),
        ),
        Expanded(
          child: Text(
            value,
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

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      Text(
        value,
        style: const TextStyle(
          color: SboxColors.text,
          fontSize: 19,
          fontWeight: FontWeight.w700,
          fontFamily: 'RobotoMono',
        ),
      ),
      const SizedBox(height: 4),
      Text(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(color: SboxColors.textMuted, fontSize: 11),
      ),
    ],
  );
}

IconData _providerIcon(SourceProvider provider) => switch (provider) {
  SourceProvider.local => Icons.folder_outlined,
  SourceProvider.github => Icons.code_rounded,
  SourceProvider.gitee => Icons.account_tree_outlined,
  SourceProvider.https => Icons.public_rounded,
};
Color _providerColor(SourceProvider provider) => switch (provider) {
  SourceProvider.local => SboxColors.accent,
  SourceProvider.github => SboxColors.text,
  SourceProvider.gitee => SboxColors.danger,
  SourceProvider.https => SboxColors.info,
};
String _providerName(SourceProvider provider) => switch (provider) {
  SourceProvider.local => '本地文件夹',
  SourceProvider.github => 'GitHub',
  SourceProvider.gitee => 'Gitee',
  SourceProvider.https => '只读 HTTPS',
};
String _sourceSubtitle(SourceConfiguration source) => switch (source.provider) {
  SourceProvider.local =>
    source.localDirectoryMode == ConfiguredLocalMode.canonicalCatalog
        ? '本地 · canonical_catalog'
        : '本地 · loose_read_only',
  SourceProvider.github => 'GitHub · ${source.owner}/${source.repository}',
  SourceProvider.gitee => 'Gitee · ${source.owner}/${source.repository}',
  SourceProvider.https => 'HTTPS · ${source.httpsBaseUri?.host}',
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
