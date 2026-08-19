import 'package:safebox/sbox/source/cloud_backup_config.dart';
import 'package:safebox/sbox/source/credential.dart';
import 'package:test/test.dart';

void main() {
  test('repository URL is persisted and restored exactly', () {
    const githubAddress = 'HTTPS://GitHub.com/zhouzhipeng/sbox-files.git/';
    const giteeAddress = 'https://gitee.com/zzp/sbox-files';
    final github = CloudRepositoryEndpoint.fromRepositoryUrl(
      githubAddress,
      credentialId: SourceCredentialId('github-token'),
      expectedHost: 'github.com',
    );
    final gitee = CloudRepositoryEndpoint.fromRepositoryUrl(
      giteeAddress,
      credentialId: SourceCredentialId('gitee-token'),
      expectedHost: 'gitee.com',
    );

    final restoredGithub = CloudRepositoryEndpoint.fromJson(github.toJson());
    final restoredGitee = CloudRepositoryEndpoint.fromJson(gitee.toJson());

    expect(restoredGithub.webUrl(host: 'github.com'), githubAddress);
    expect(restoredGitee.webUrl(host: 'gitee.com'), giteeAddress);
    expect(github.toJson().containsKey('branch'), isFalse);
    expect(gitee.toJson().containsKey('branch'), isFalse);
  });

  test('repository enabled state is persisted and old configs default to true', () {
    final disabled = CloudRepositoryEndpoint.fromRepositoryUrl(
      'https://github.com/example/disabled',
      credentialId: SourceCredentialId('github-token'),
      expectedHost: 'github.com',
      enabled: false,
    );
    final restored = CloudRepositoryEndpoint.fromJson(disabled.toJson());
    expect(restored.enabled, isFalse);

    final legacy = CloudRepositoryEndpoint.fromJson(<String, Object?>{
      'owner': 'example',
      'repository': 'legacy',
      'credential_id': 'github-token',
    });
    expect(legacy.enabled, isTrue);
  });
}
