import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:safebox/sbox/source/gitee_source.dart';
import 'package:safebox/sbox/source/github_source.dart';
import 'package:safebox/sbox/source/remote_config.dart';
import 'package:safebox/sbox/source/source_path.dart';
import 'package:test/test.dart';

void main() {
  final enabled = Platform.environment['SBOX_LIVE_REMOTE_TESTS'] == '1';

  test(
    'GitHub public repository can be read anonymously through the adapter',
    () async {
      final client = http.Client();
      try {
        final source = GitHubDataSource(
          config: RepositorySourceConfig(
            owner: 'octocat',
            repository: 'Hello-World',
            branch: 'master',
          ),
          client: client,
        );
        final result = await source.get(SourcePath('README'));
        final bytes = await _collect(result.body);
        expect(bytes, isNotEmpty);
        expect(String.fromCharCodes(result.revision.bytes), matches(_gitSha));
      } finally {
        client.close();
      }
    },
    skip: enabled ? false : 'Set SBOX_LIVE_REMOTE_TESTS=1 to use public APIs.',
  );

  test(
    'Gitee public repository can be read anonymously through the adapter',
    () async {
      final client = http.Client();
      try {
        final source = GiteeDataSource(
          config: RepositorySourceConfig(
            owner: 'openharmony',
            repository: 'docs',
            branch: 'master',
          ),
          client: client,
        );
        final result = await source.get(SourcePath('README.md'));
        final bytes = await _collect(result.body);
        expect(bytes, isNotEmpty);
        expect(String.fromCharCodes(result.revision.bytes), matches(_gitSha));
      } finally {
        client.close();
      }
    },
    skip: enabled ? false : 'Set SBOX_LIVE_REMOTE_TESTS=1 to use public APIs.',
  );
}

final RegExp _gitSha = RegExp(r'^[0-9a-f]{40}$');

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final output = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    output.add(chunk);
  }
  return output.takeBytes();
}
