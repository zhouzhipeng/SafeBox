import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../app/app_controller.dart';
import '../../app/sbox_feedback.dart';
import '../../app/sbox_theme.dart';
import '../../app/sbox_widgets.dart';
import '../../platform/app_settings_store.dart';
import '../../platform/cloud_backup_configuration_store.dart';
import '../../platform/file_opener.dart';
import '../../platform/secure_credential_store.dart';
import '../../platform/temporary_plaintext_platform.dart';
import '../../sbox/bytes.dart';
import '../../sbox/source/cloud_backup_config.dart';
import '../../sbox/source/credential.dart';
import '../../sbox/source/gitee_source.dart';
import '../../sbox/source/github_source.dart';
import '../../sbox/storage/local_bundle_index.dart';
import '../../sbox/storage/temporary_plaintext_store.dart';

final class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.controller,
    this.onOpenOnboarding,
    this.onCloudStateChanged,
    this.isLightTheme = false,
    this.onThemeChanged,
  });

  final AppController controller;
  final VoidCallback? onOpenOnboarding;
  final VoidCallback? onCloudStateChanged;
  final bool isLightTheme;
  final ValueChanged<bool>? onThemeChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

final class _SettingsPageState extends State<SettingsPage> {
  static final _githubCredential = SourceCredentialId('safebox-github-token');
  static final _giteeCredential = SourceCredentialId('safebox-gitee-token');

  final _configurationStore = CloudBackupConfigurationStore();
  final _credentialStore = PlatformCredentialStore();
  final _temporaryStore = TemporaryPlaintextStore();
  AppSettingsStore get _appSettingsStore => widget.controller.appSettingsStore;
  final _githubAddressController = TextEditingController(
    text: 'https://github.com/your-account/your-repository',
  );
  final _giteeAddressController = TextEditingController(
    text: 'https://gitee.com/your-account/your-repository',
  );
  final _githubTokenController = TextEditingController();
  final _giteeTokenController = TextEditingController();
  bool _cloudExpanded = false;
  bool _lightTheme = false;
  bool _loading = true;
  bool _saving = false;
  bool _githubConnected = false;
  bool _giteeConnected = false;
  bool _githubEnabled = true;
  bool _giteeEnabled = true;
  bool _removingIdentity = false;
  String? _testingProvider;
  String? _activeTokenField;

  @override
  void initState() {
    super.initState();
    _lightTheme = widget.isLightTheme;
    _load();
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isLightTheme != widget.isLightTheme &&
        _lightTheme != widget.isLightTheme) {
      setState(() => _lightTheme = widget.isLightTheme);
    }
  }

  @override
  void dispose() {
    for (final controller in <TextEditingController>[
      _githubAddressController,
      _giteeAddressController,
      _githubTokenController,
      _giteeTokenController,
    ]) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mobile = constraints.maxWidth < 760;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            mobile ? 24 : 32,
            mobile ? 28 : 40,
            mobile ? 24 : 32,
            mobile ? 32 : 44,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _buildIdentityCard(context, mobile),
                  const SizedBox(height: 14),
                  _buildCloudCard(context, mobile),
                  const SizedBox(height: 14),
                  _buildHabitsCard(context, mobile),
                  if (_loading) ...<Widget>[
                    const SizedBox(height: 14),
                    const LinearProgressIndicator(minHeight: 2),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildIdentityCard(BuildContext context, bool mobile) {
    final identityReady = widget.controller.hasIdentity;
    final details = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        SboxShieldMark(size: mobile ? 100 : 98),
        SizedBox(width: mobile ? 18 : 30),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                identityReady ? '已保护' : '待设置',
                style: TextStyle(
                  color: identityReady
                      ? context.sboxColors.accent
                      : context.sboxColors.warning,
                  fontSize: mobile ? 20 : 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                identityReady ? _identityLabel : '还没有安全身份',
                style: Theme.of(context).textTheme.headlineMedium
                    ?.copyWith(fontSize: mobile ? 24 : 23),
              ),
              const SizedBox(height: 5),
              Text(
                '用于保护你的文件',
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(color: context.sboxColors.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
    final copyButton = OutlinedButton.icon(
      onPressed: identityReady && !_removingIdentity ? _copyPublicKey : null,
      icon: const Icon(Icons.content_copy_rounded),
      label: const Text('复制公钥'),
    );
    final removeButton = OutlinedButton.icon(
      onPressed: identityReady && !_removingIdentity ? _removeIdentity : null,
      icon: const Icon(Icons.person_remove_outlined),
      label: Text(_removingIdentity ? '正在移除…' : '移除身份'),
    );
    final restoreButton = OutlinedButton.icon(
      onPressed: _removingIdentity ? null : widget.onOpenOnboarding,
      icon: const Icon(Icons.refresh_rounded),
      label: const Text('恢复身份'),
    );
    final actions = mobile
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              copyButton,
              const SizedBox(height: 10),
              removeButton,
              const SizedBox(height: 10),
              restoreButton,
            ],
          )
        : Row(
            children: <Widget>[
              Expanded(child: copyButton),
              const SizedBox(width: 14),
              Expanded(child: removeButton),
              const SizedBox(width: 14),
              Expanded(child: restoreButton),
            ],
          );
    return SboxCard(
      padding: EdgeInsets.fromLTRB(
        mobile ? 18 : 30,
        mobile ? 22 : 24,
        mobile ? 18 : 30,
        mobile ? 20 : 24,
      ),
      radius: mobile ? 16 : 14,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('安全身份', style: Theme.of(context).textTheme.headlineMedium),
          SizedBox(height: mobile ? 22 : 16),
          if (mobile) ...<Widget>[
            details,
            const SizedBox(height: 22),
            actions,
            const SizedBox(height: 14),
            const _LockHint(text: '恢复词只保存在你手中'),
          ] else
            Row(
              children: <Widget>[
                Expanded(flex: 2, child: details),
                const SizedBox(width: 44),
                Expanded(flex: 3, child: actions),
              ],
            ),
          if (!mobile) ...<Widget>[
            const SizedBox(height: 12),
            const Align(
              alignment: Alignment.centerRight,
              child: _LockHint(text: '恢复词只保存在你手中'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCloudCard(BuildContext context, bool mobile) {
    return SboxCard(
      padding: EdgeInsets.fromLTRB(
        mobile ? 18 : 30,
        mobile ? 22 : 24,
        mobile ? 18 : 24,
        mobile ? 20 : 24,
      ),
      radius: mobile ? 16 : 14,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            onTap: () => setState(() => _cloudExpanded = !_cloudExpanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.cloud_download_outlined,
                    color: context.sboxColors.accent,
                    size: 40,
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '云端备份',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '粘贴完整地址即可，不需要分别填写账号和仓库名',
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                color: context.sboxColors.textMuted,
                                fontSize: mobile ? 13 : 15,
                              ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _cloudExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: context.sboxColors.textMuted,
                    size: 28,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          if (_cloudExpanded)
            _buildCloudEditor(context, mobile)
          else
            _buildCloudSummary(context, mobile),
        ],
      ),
    );
  }

  Widget _buildCloudSummary(BuildContext context, bool mobile) {
    final children = <Widget>[
      _CloudSummaryLine(
        icon: Icons.cloud_outlined,
        label: '主备份',
        connected: _githubConnected,
      ),
      if (!mobile) const SizedBox(width: 36),
      if (!mobile)
        Container(width: 1, height: 34, color: context.sboxColors.textDim)
      else
        const Divider(height: 24),
      if (!mobile) const SizedBox(width: 36),
      _CloudSummaryLine(
        icon: Icons.cloud_outlined,
        label: '备用备份',
        connected: _giteeConnected,
      ),
    ];
    return mobile ? Column(children: children) : Row(children: children);
  }

  Widget _buildCloudEditor(BuildContext context, bool mobile) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        LayoutBuilder(
          builder: (context, constraints) {
            final width = mobile
                ? constraints.maxWidth
                : (constraints.maxWidth - 30) / 2;
            return Wrap(
              spacing: 30,
              runSpacing: 14,
              children: <Widget>[
                SizedBox(
                  width: width,
                  child: _buildRepositoryCard(
                    context,
                    provider: 'GitHub',
                    addressController: _githubAddressController,
                    tokenController: _githubTokenController,
                    connected: _githubConnected,
                    enabled: _githubEnabled,
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _buildRepositoryCard(
                    context,
                    provider: 'Gitee',
                    addressController: _giteeAddressController,
                    tokenController: _giteeTokenController,
                    connected: _giteeConnected,
                    enabled: _giteeEnabled,
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.center,
          child: SizedBox(
            width: mobile ? double.infinity : 250,
            child: ElevatedButton(
              onPressed: _saving ? null : _saveConfiguration,
              child: Text(_saving ? '保存中…' : '保存设置'),
            ),
          ),
        ),
        const SizedBox(height: 9),
        const _LockHint(text: '凭证仅保存在本机'),
      ],
    );
  }

  Widget _buildRepositoryCard(
    BuildContext context, {
    required String provider,
    required TextEditingController addressController,
    required TextEditingController tokenController,
    required bool connected,
    required bool enabled,
  }) {
    final tokenField = '$provider-token';
    final tokenVisible = _activeTokenField == tokenField;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        color: context.sboxColors.panelSoft,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.sboxColors.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              _ProviderMark(provider: provider),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  provider,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              StatusPill(
                label: connected ? '已连接' : '待设置',
                icon: connected ? Icons.check_circle_outline : Icons.more_horiz,
                tone: connected
                    ? context.sboxColors.accent
                    : context.sboxColors.warning,
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: addressController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '完整地址',
              hintText: 'https://github.com/your-account/your-repository',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: tokenController,
            obscureText: !tokenVisible,
            decoration: InputDecoration(
              labelText: '访问凭证',
              hintText: connected ? '••••••••••••••••' : '输入访问凭证',
              suffixIcon: IconButton(
                tooltip: tokenVisible ? '隐藏凭证' : '显示凭证',
                onPressed: () => setState(() {
                  _activeTokenField = tokenVisible ? null : tokenField;
                }),
                icon: Icon(
                  tokenVisible
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              OutlinedButton(
                onPressed: _testingProvider == provider
                    ? null
                    : () => _testConnection(provider),
                child: Text(_testingProvider == provider ? '测试中…' : '测试连接'),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Checkbox(
                    key: ValueKey<String>('$provider-enabled'),
                    value: enabled,
                    onChanged: _saving
                        ? null
                        : (value) {
                            if (value == null) return;
                            setState(() {
                              if (provider == 'GitHub') {
                                _githubEnabled = value;
                              } else {
                                _giteeEnabled = value;
                              }
                            });
                          },
                  ),
                  const Text('是否启用'),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHabitsCard(BuildContext context, bool mobile) {
    final themeRow = _HabitRow(
      icon: Icons.palette_outlined,
      title: '界面主题',
      value: _lightTheme ? '亮色' : '深色',
      onTap: _chooseTheme,
    );
    return SboxCard(
      padding: EdgeInsets.fromLTRB(
        mobile ? 18 : 30,
        mobile ? 22 : 24,
        mobile ? 18 : 30,
        mobile ? 22 : 24,
      ),
      radius: mobile ? 16 : 14,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('使用习惯', style: Theme.of(context).textTheme.headlineMedium),
          SizedBox(height: mobile ? 18 : 18),
          if (mobile) ...<Widget>[
            themeRow,
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: <Widget>[
                  if (!kIsWeb) _openCacheDirectoryButton(),
                  _clearTemporaryPlaintextButton(),
                ],
              ),
            ),
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(child: themeRow),
                const SizedBox(width: 40),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    if (!kIsWeb) ...<Widget>[
                      _openCacheDirectoryButton(),
                      const SizedBox(height: 12),
                    ],
                    _clearTemporaryPlaintextButton(),
                  ],
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _openCacheDirectoryButton() {
    return OutlinedButton.icon(
      onPressed: _openCacheDirectory,
      icon: const Icon(Icons.folder_open_outlined),
      label: const Text('打开缓存目录'),
    );
  }

  Widget _clearTemporaryPlaintextButton() {
    return OutlinedButton.icon(
      onPressed: _clearTemporaryPlaintext,
      icon: const Icon(Icons.delete_outline),
      label: const Text('清理缓存'),
    );
  }

  String get _identityLabel {
    final identity = widget.controller.identityRecord;
    if (identity == null) return '未设置';
    final id = hexLower(identity.recipientKeyId);
    return '••••${id.substring(id.length - 4).toUpperCase()}';
  }

  Future<void> _load() async {
    try {
      final configuration = await _configurationStore.load();
      if (configuration != null) {
        _githubAddressController.text = configuration.github.webUrl(
          host: 'github.com',
        );
        _giteeAddressController.text = configuration.gitee.webUrl(
          host: 'gitee.com',
        );
        _githubEnabled = configuration.github.enabled;
        _giteeEnabled = configuration.gitee.enabled;
        _githubConnected = await _hasToken(configuration.github.credentialId);
        _giteeConnected = await _hasToken(configuration.gitee.credentialId);
      }
      _lightTheme = await _appSettingsStore.loadLightTheme();
    } catch (error) {
      if (mounted) {
        widget.controller.setError(error, operation: '读取设置失败');
        _showFeedback('设置暂时无法读取，请稍后重试。', error: true);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveConfiguration() async {
    final existing = await _configurationStore.load();
    final githubUrl = _githubAddressController.text;
    final giteeUrl = _giteeAddressController.text;
    if (githubUrl.trim().isEmpty || giteeUrl.trim().isEmpty) {
      _showFeedback('请填写 GitHub 和 Gitee 的完整地址。', error: true);
      return;
    }
    late final CloudBackupConfiguration configuration;
    try {
      configuration = CloudBackupConfiguration(
        backupDirectory:
            existing?.backupDirectory ??
            (kIsWeb
                ? 'web-memory'
                : p.join(Directory.systemTemp.path, 'SafeBox', 'backup')),
        github: CloudRepositoryEndpoint.fromRepositoryUrl(
          githubUrl,
          credentialId: _githubCredential,
          expectedHost: 'github.com',
          enabled: _githubEnabled,
        ),
        gitee: CloudRepositoryEndpoint.fromRepositoryUrl(
          giteeUrl,
          credentialId: _giteeCredential,
          expectedHost: 'gitee.com',
          enabled: _giteeEnabled,
        ),
      );
    } catch (_) {
      _showFeedback('请填写有效的 GitHub / Gitee 完整地址。', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      await _saveToken(_githubCredential, _githubTokenController.text.trim());
      await _saveToken(_giteeCredential, _giteeTokenController.text.trim());
      await _configurationStore.save(configuration);
      _githubConnected = await _hasToken(_githubCredential);
      _giteeConnected = await _hasToken(_giteeCredential);
      _githubTokenController.clear();
      _giteeTokenController.clear();
      if (mounted) {
        setState(() {});
        _showFeedback('云端备份设置已保存。');
      }
      widget.onCloudStateChanged?.call();
    } catch (error) {
      if (mounted) {
        widget.controller.setError(error, operation: '保存云端备份设置失败');
        _showFeedback('设置暂时没有保存成功，请稍后重试。', error: true);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _testConnection(String provider) async {
    final isGithub = provider == 'GitHub';
    final address =
        (isGithub ? _githubAddressController : _giteeAddressController).text
            .trim();
    final tokenController = isGithub
        ? _githubTokenController
        : _giteeTokenController;
    final credential = isGithub ? _githubCredential : _giteeCredential;
    late final CloudRepositoryEndpoint endpoint;
    try {
      endpoint = CloudRepositoryEndpoint.fromRepositoryUrl(
        address,
        credentialId: credential,
        expectedHost: isGithub ? 'github.com' : 'gitee.com',
      );
    } catch (_) {
      _showFeedback('请先填写有效的完整地址。', error: true);
      return;
    }
    setState(() => _testingProvider = provider);
    final client = http.Client();
    try {
      await _saveToken(credential, tokenController.text.trim());
      if (isGithub) {
        await GitHubDataSource(
          config: endpoint.repositoryConfig,
          client: client,
          credentialStore: _credentialStore,
          credentialId: credential,
          logger: widget.controller.logger,
        ).verifyRepository();
      } else {
        await GiteeDataSource(
          config: endpoint.repositoryConfig,
          client: client,
          credentialStore: _credentialStore,
          credentialId: credential,
          logger: widget.controller.logger,
        ).verifyRepository();
      }
      if (mounted) {
        setState(() {
          if (isGithub) {
            _githubConnected = true;
          } else {
            _giteeConnected = true;
          }
        });
        _showFeedback('$provider 已连接。');
      }
    } catch (error) {
      if (mounted) {
        widget.controller.logger.warning(
          '$provider：测试连接失败',
          detail: error.toString(),
        );
        _showFeedback('$provider 暂时无法连接，请检查地址和凭证。', error: true);
      }
    } finally {
      client.close();
      if (mounted) setState(() => _testingProvider = null);
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

  Future<void> _copyPublicKey() async {
    final identity = widget.controller.identityRecord;
    if (identity == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('复制公钥？'),
        content: const Text(
          '将复制 sboxpk1: 单行精简公钥。获得此公钥的人可以读取文件名、说明、时间和缩略图预览，但不能仅凭公钥解密文件正文。请只分享给你信任的加密方。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('复制'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await Clipboard.setData(ClipboardData(text: identity.encode()));
      if (mounted) _showFeedback('公钥已复制。');
    } catch (error) {
      if (!mounted) return;
      widget.controller.setError(error, operation: '复制公钥失败');
      _showFeedback('公钥暂时无法复制，请稍后重试。', error: true);
    }
  }

  Future<void> _removeIdentity() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除身份？'),
        content: const Text(
          '这会删除本机保存的公钥、仓库地址、访问凭证、临时目录及其他相关设置，并返回首次设置界面。云端仓库中的文件不会被删除。此操作无法撤销。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _removingIdentity = true);
    try {
      await widget.controller.removeIdentity();
      if (!mounted) return;
      widget.onOpenOnboarding?.call();
    } catch (error) {
      if (mounted) {
        widget.controller.setError(error, operation: '移除安全身份失败');
        _showFeedback('身份相关数据没有完全清理，请稍后重试。', error: true);
      }
    } finally {
      if (mounted) setState(() => _removingIdentity = false);
    }
  }

  Future<void> _chooseTheme() async {
    final selected = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('界面主题'),
        content: RadioGroup<bool>(
          groupValue: _lightTheme,
          onChanged: (value) => Navigator.of(context).pop(value),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const RadioListTile<bool>(value: false, title: Text('深色')),
              const RadioListTile<bool>(value: true, title: Text('亮色')),
            ],
          ),
        ),
      ),
    );
    if (selected == null || selected == _lightTheme || !mounted) return;

    final previous = _lightTheme;
    setState(() => _lightTheme = selected);
    widget.onThemeChanged?.call(selected);
    try {
      await _appSettingsStore.saveLightTheme(selected);
    } catch (error) {
      if (!mounted) return;
      setState(() => _lightTheme = previous);
      widget.onThemeChanged?.call(previous);
      widget.controller.setError(error, operation: '保存界面主题失败');
      _showFeedback('界面主题暂时无法保存，请稍后重试。', error: true);
    }
  }

  Future<void> _clearTemporaryPlaintext() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理缓存？'),
        content: const Text('这会删除临时文件、文件信息索引、缩略图缓存和本地加密备份；云端安全文件不会受到影响。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (kIsWeb) {
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      _showFeedback('浏览器图片缓存已清理。');
      return;
    }
    final failures = <Object>[];
    try {
      try {
        await TemporaryPlaintextPlatform.protectRoot(_temporaryStore.path);
        await _temporaryStore.clearAll();
      } on Object catch (error) {
        failures.add(error);
      }

      CloudBackupConfiguration? configuration;
      try {
        configuration = await _configurationStore.load();
      } on Object catch (error) {
        failures.add(error);
      }
      final cacheRoots = <String>{
        p.join(
          Directory.systemTemp.path,
          TemporaryPlaintextStore.defaultDirectoryName,
          'backup',
        ),
        if (configuration != null) configuration.backupDirectory,
      };
      for (final root in cacheRoots) {
        try {
          await LocalBundleIndexStore.deleteAll(Directory(root));
        } on Object catch (error) {
          failures.add(error);
        }
      }
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      if (failures.isNotEmpty) {
        throw StateError('One or more cache stores could not be cleared');
      }
      if (mounted) _showFeedback('缓存已清理。');
    } catch (error) {
      if (mounted) {
        widget.controller.setError(error, operation: '清理缓存失败');
        _showFeedback('缓存没有完全清理，请稍后重试。', error: true);
      }
    }
  }

  Future<void> _openCacheDirectory() async {
    try {
      final plaintextDirectory = await _temporaryStore.ensureRoot();
      await FileOpener.openDirectory(plaintextDirectory.parent);
      if (mounted) _showFeedback('缓存目录已打开。');
    } catch (error) {
      if (!mounted) return;
      widget.controller.setError(error, operation: '打开缓存目录失败');
      _showFeedback(
        error is UnsupportedError ? '当前平台不支持打开缓存目录。' : '缓存目录暂时无法打开，请稍后重试。',
        error: true,
      );
    }
  }

  void _showFeedback(String message, {bool error = false}) {
    if (!mounted) return;
    showSboxFeedback(context, message, error: error);
  }
}

final class _CloudSummaryLine extends StatelessWidget {
  const _CloudSummaryLine({
    required this.icon,
    required this.label,
    required this.connected,
  });

  final IconData icon;
  final String label;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, color: context.sboxColors.textMuted, size: 40),
        const SizedBox(width: 18),
        Text(label, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(width: 12),
        Text(
          '·  ${connected ? '已连接' : '待设置'}',
          style: TextStyle(
            color: connected
                ? context.sboxColors.accent
                : context.sboxColors.warning,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

final class _ProviderMark extends StatelessWidget {
  const _ProviderMark({required this.provider});

  final String provider;

  @override
  Widget build(BuildContext context) {
    if (provider == 'GitHub') {
      return const CircleAvatar(
        radius: 21,
        backgroundColor: Colors.white,
        child: Icon(Icons.code_rounded, color: Color(0xFF142033), size: 29),
      );
    }
    return const CircleAvatar(
      radius: 21,
      backgroundColor: Color(0xFFE33B43),
      child: Text(
        'G',
        style: TextStyle(
          color: Colors.white,
          fontSize: 24,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

final class _HabitRow extends StatelessWidget {
  const _HabitRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: <Widget>[
            Icon(icon, color: context.sboxColors.textMuted, size: 38),
            const SizedBox(width: 18),
            Expanded(
              child: Text(
                '$title  ·  $value',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontSize: 17),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: context.sboxColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

final class _LockHint extends StatelessWidget {
  const _LockHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(Icons.lock_outline, color: context.sboxColors.textMuted, size: 20),
        const SizedBox(width: 8),
        Text(
          text,
          style: Theme.of(context).textTheme.bodyLarge
              ?.copyWith(color: context.sboxColors.textMuted),
        ),
      ],
    );
  }
}
