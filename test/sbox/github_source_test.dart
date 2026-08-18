import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:safebox/sbox/source/github_source.dart';
import 'package:safebox/sbox/source/remote_config.dart';
import 'package:test/test.dart';

void main() {
  test(
    'GitHub directory listings do not request a synthetic next page',
    () async {
      final client = _DirectoryClient(
        List<Object?>.generate(
          100,
          (index) => <String, Object?>{
            'type': 'file',
            'name': '${index.toRadixString(16).padLeft(32, '0')}.sbox',
            'sha': 'revision-$index',
            'size': 16992,
          },
        ),
      );
      final source = GitHubDataSource(
        config: RepositorySourceConfig(
          owner: 'zhouzhipeng',
          repository: 'sbox-files',
        ),
        client: client,
      );

      final page = await source.listObjects(pageSize: 1000);

      expect(page.objects, hasLength(100));
      expect(page.nextCursor, isNull);
      expect(client.requests, hasLength(1));
      expect(client.requests.single.url.queryParameters, isEmpty);
    },
  );
}

final class _DirectoryClient extends http.BaseClient {
  _DirectoryClient(this.entries);

  final List<Object?> entries;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(entries))),
      200,
      request: request,
    );
  }
}
