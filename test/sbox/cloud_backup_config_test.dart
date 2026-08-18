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
}
