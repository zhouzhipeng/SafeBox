import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../app/app_controller.dart';
import '../../app/sbox_widgets.dart';
import '../../platform/cloud_backup_configuration_store.dart';
import '../../platform/secure_credential_store.dart';
import '../../sbox/source/cloud_backup_config.dart';
import '../../sbox/source/credential.dart';
import '../../sbox/source/gitee_source.dart';
import '../../sbox/source/github_source.dart';

final class SourcesPage extends StatefulWidget {
  const SourcesPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<SourcesPage> createState() => _SourcesPageState();
}

final class _SourcesPageState extends State<SourcesPage> {
  static final _githubCredential = SourceCredentialId('safebox-github-token');
  static final _giteeCredential = SourceCredentialId('safebox-gitee-token');

  final _directoryController = TextEditingController();
  final _githubOwnerController = TextEditingController();
  final _githubRepositoryController = TextEditingController();
  final _giteeOwnerController = TextEditingController();
  final _giteeRepositoryController = TextEditingController();
  final _pathPrefixController = TextEditingController();
  final _githubTokenController = TextEditingController();
  final _giteeTokenController = TextEditingController();
  final _store = CloudBackupConfigurationStore();
  final _credentialStore = PlatformCredentialStore();
  bool _busy = true;
  bool _testing = false;
  bool _githubTokenSaved = false;
  bool _giteeTokenSaved = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in <TextEditingController>[
      _directoryController,
      _githubOwnerController,
      _githubRepositoryController,
      _giteeOwnerController,
      _giteeRepositoryController,
      _pathPrefixController,
      _githubTokenController,
      _giteeTokenController,
    ]) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        PageHeading(
          title: '双云 API 设置',
          subtitle: 'GitHub 和 Gitee 是同一个 SafeBox 备份的两个 API 数据源；上传时按分片有限并发创建附件，不需要 pull 整个仓库。',
          trailing: ElevatedButton.icon(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('保存配置'),
          ),
        ),
        const SizedBox(height: 24),
        SboxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('本地加密副本', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text(
                '本地目录只保存加密后的 .sbox 文件，作为两个公开云 API 的缓存和恢复来源；不会创建或使用本地 Git 仓库。',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _directoryController,
                decoration: const InputDecoration(
                  labelText: '本地加密备份目录',
                  hintText: 'D:\\SafeBox\\encrypted-backup',
                  prefixIcon: Icon(Icons.folder_outlined),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _repositoryCard(
          context,
          title: 'GitHub API',
          icon: Icons.cloud_outlined,
          ownerController: _githubOwnerController,
          repositoryController: _githubRepositoryController,
          tokenController: _githubTokenController,
          tokenSaved: _githubTokenSaved,
          ownerHint: 'username',
          repositoryHint: 'private-box',
        ),
        const SizedBox(height: 14),
        _repositoryCard(
          context,
          title: 'Gitee API',
          icon: Icons.cloud_outlined,
          ownerController: _giteeOwnerController,
          repositoryController: _giteeRepositoryController,
          tokenController: _giteeTokenController,
          tokenSaved: _giteeTokenSaved,
          ownerHint: 'username',
          repositoryHint: 'private-box',
        ),
        const SizedBox(height: 14),
        SboxCard(
          child: Column(
            children: <Widget>[
              TextField(
                controller: _pathPrefixController,
                decoration: const InputDecoration(
                  labelText: '仓库目录（可选）',
                  hintText: 'backup',
                  prefixIcon: Icon(Icons.folder_copy_outlined),
                ),
              ),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: <Widget>[
                    ElevatedButton.icon(
                      onPressed: _busy ? null : _save,
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('保存并启用双云'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy || _testing ? null : _testConnections,
                      icon: const Icon(Icons.wifi_tethering_outlined),
                      label: Text(_testing ? '测试中…' : '测试 API 连接'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const SecurityNotice(
          title: '令牌安全',
          message: '令牌只写入系统安全存储，配置文件只保存仓库地址和令牌引用。上传时 GitHub、Gitee 两个 API 请求并发执行；任一失败都会明确报告，不会假装双云成功。',
        ),
        if (_busy) ...<Widget>[
          const SizedBox(height: 14),
          const SboxProgressCard(title: '读取双云配置', detail: '正在读取本地配置和安全存储状态。'),
        ],
      ],
    ),
  );

  Widget _repositoryCard(
    BuildContext context, {
    required String title,
    required IconData icon,
    required TextEditingController ownerController,
    required TextEditingController repositoryController,
    required TextEditingController tokenController,
    required bool tokenSaved,
    required String ownerHint,
    required String repositoryHint,
  }) => SboxCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(icon),
            const SizedBox(width: 10),
            Expanded(
              child: Text(title, style: Theme.of(context).textTheme.titleLarge),
            ),
            StatusPill(
              label: tokenSaved ? '令牌已保存' : '需要令牌',
              icon: tokenSaved ? Icons.key_outlined : Icons.key_off_outlined,
              tone: tokenSaved ? Colors.green : Colors.orange,
            ),
          ],
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 14,
          runSpacing: 14,
          children: <Widget>[
            SizedBox(
              width: 220,
              child: TextField(
                controller: ownerController,
                decoration: InputDecoration(
                  labelText: 'Owner',
                  hintText: ownerHint,
                ),
              ),
            ),
            SizedBox(
              width: 280,
              child: TextField(
                controller: repositoryController,
                decoration: InputDecoration(
                  labelText: 'Repository',
                  hintText: repositoryHint,
                ),
              ),
            ),
            SizedBox(
              width: 360,
              child: TextField(
                controller: tokenController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '访问令牌（留空表示保留已保存令牌）',
                  prefixIcon: Icon(Icons.password_outlined),
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Future<void> _load() async {
    try {
      final configuration = await _store.load();
      if (configuration != null) {
        _directoryController.text = configuration.backupDirectory;
        _githubOwnerController.text = configuration.github.owner;
        _githubRepositoryController.text = configuration.github.repository;
        _giteeOwnerController.text = configuration.gitee.owner;
        _giteeRepositoryController.text = configuration.gitee.repository;
        _pathPrefixController.text = configuration.github.pathPrefix;
        _githubTokenSaved = await _hasToken(configuration.github.credentialId);
        _giteeTokenSaved = await _hasToken(configuration.gitee.credentialId);
      }
      if (!mounted) return;
      setState(() => _busy = false);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      widget.controller.setError(error, operation: '读取双云配置失败');
    }
  }

  Future<void> _save() async {
    final directory = _directoryController.text.trim();
    final ownerGithub = _githubOwnerController.text.trim();
    final repositoryGithub = _githubRepositoryController.text.trim();
    final ownerGitee = _giteeOwnerController.text.trim();
    final repositoryGitee = _giteeRepositoryController.text.trim();
    final prefix = _pathPrefixController.text.trim();
    if (directory.isEmpty ||
        ownerGithub.isEmpty ||
        repositoryGithub.isEmpty ||
        ownerGitee.isEmpty ||
        repositoryGitee.isEmpty) {
      widget.controller.setError('本地目录和两个仓库地址都不能为空。');
      return;
    }
    late final CloudBackupConfiguration configuration;
    try {
      configuration = CloudBackupConfiguration(
        backupDirectory: directory,
        github: CloudRepositoryEndpoint(
          owner: ownerGithub,
          repository: repositoryGithub,
          pathPrefix: prefix,
          credentialId: _githubCredential,
        ),
        gitee: CloudRepositoryEndpoint(
          owner: ownerGitee,
          repository: repositoryGitee,
          pathPrefix: prefix,
          credentialId: _giteeCredential,
        ),
      );
    } catch (error) {
      widget.controller.setError(error, operation: '创建双云配置失败');
      return;
    }
    setState(() => _busy = true);
    try {
      await _saveToken(_githubCredential, _githubTokenController.text.trim());
      await _saveToken(_giteeCredential, _giteeTokenController.text.trim());
      await _store.save(configuration);
      final githubTokenSaved = await _hasToken(_githubCredential);
      final giteeTokenSaved = await _hasToken(_giteeCredential);
      if (!mounted) return;
      setState(() {
        _githubTokenSaved = githubTokenSaved;
        _giteeTokenSaved = giteeTokenSaved;
      });
      _githubTokenController.clear();
      _giteeTokenController.clear();
      widget.controller.setStatus(
        '双云 API 配置已保存。上传时会按 Bundle 分片有限并发调用 GitHub、Gitee API。',
      );
    } catch (error) {
      if (mounted) widget.controller.setError(error, operation: '保存双云配置失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testConnections() async {
    final configuration = await _readConfigurationFromFields();
    if (configuration == null) return;
    setState(() => _testing = true);
    final client = http.Client();
    try {
      final github = GitHubDataSource(
        config: configuration.github.repositoryConfig,
        client: client,
        credentialStore: _credentialStore,
        credentialId: configuration.github.credentialId,
        logger: widget.controller.logger,
      );
      final gitee = GiteeDataSource(
        config: configuration.gitee.repositoryConfig,
        client: client,
        credentialStore: _credentialStore,
        credentialId: configuration.gitee.credentialId,
        logger: widget.controller.logger,
      );
      await Future.wait(<Future<void>>[
        github.verifyRepository(),
        gitee.verifyRepository(),
      ]);
      if (mounted) widget.controller.setStatus('GitHub 和 Gitee API 连接正常。');
    } catch (error) {
      if (mounted) {
        widget.controller.setError(error, operation: '测试双云 API 连接失败');
      }
    } finally {
      client.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<CloudBackupConfiguration?> _readConfigurationFromFields() async {
    try {
      return CloudBackupConfiguration(
        backupDirectory: _directoryController.text.trim(),
        github: CloudRepositoryEndpoint(
          owner: _githubOwnerController.text.trim(),
          repository: _githubRepositoryController.text.trim(),
          pathPrefix: _pathPrefixController.text.trim(),
          credentialId: _githubCredential,
        ),
        gitee: CloudRepositoryEndpoint(
          owner: _giteeOwnerController.text.trim(),
          repository: _giteeRepositoryController.text.trim(),
          pathPrefix: _pathPrefixController.text.trim(),
          credentialId: _giteeCredential,
        ),
      );
    } catch (error) {
      widget.controller.setError(error, operation: '检查双云配置失败');
      return null;
    }
  }

  Future<void> _saveToken(SourceCredentialId id, String value) async {
    if (value.isEmpty) return;
    final token = SourceAccessToken.fromUtf8(value);
    try {
      await _credentialStore.putAccessToken(id, token);
    } finally {
      token.dispose();
    }
  }

  Future<bool> _hasToken(SourceCredentialId id) async {
    final token = await _credentialStore.getAccessToken(id);
    if (token == null) return false;
    token.dispose();
    return true;
  }
}
