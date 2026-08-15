import 'source_path.dart';

final class RepositorySourceConfig {
  RepositorySourceConfig({
    required String owner,
    required String repository,
    required String branch,
    String pathPrefix = '',
  }) : owner = _repositoryComponent(owner, 'owner'),
       repository = _repositoryComponent(repository, 'repository'),
       branch = _branch(branch),
       pathPrefix = _prefix(pathPrefix);

  final String owner;
  final String repository;
  final String branch;
  final String pathPrefix;

  SourcePath resolve(SourcePath path) =>
      SourcePath(pathPrefix.isEmpty ? path.value : '$pathPrefix/${path.value}');

  static String _repositoryComponent(String value, String name) {
    if (value.length > 100 ||
        !RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9_])?$')
            .hasMatch(value) ||
        value == '.' ||
        value == '..') {
      throw ArgumentError.value(value, name, 'Invalid repository component');
    }
    return value;
  }

  static String _branch(String value) {
    if (value.isEmpty ||
        value.length > 255 ||
        value.startsWith('/') ||
        value.endsWith('/') ||
        value.contains('..') ||
        value.contains('@{') ||
        value.endsWith('.') ||
        value.endsWith('.lock') ||
        RegExp(r'[\x00-\x20\x7f~^:?*\\\[]').hasMatch(value)) {
      throw ArgumentError.value(value, 'branch', 'Invalid writable branch');
    }
    return value;
  }

  static String _prefix(String value) {
    if (value.isEmpty) {
      return '';
    }
    return SourcePath(value).value;
  }
}

final class HttpsSourceConfig {
  HttpsSourceConfig({
    required Uri baseUri,
    this.maxObjectBytes = 100 * 1024 * 1024,
  }) : baseUri = _validateBase(baseUri) {
    if (maxObjectBytes <= 0) {
      throw ArgumentError.value(maxObjectBytes, 'maxObjectBytes');
    }
  }

  final Uri baseUri;
  final int maxObjectBytes;

  Uri resolve(SourcePath path) {
    return Uri(
      scheme: 'https',
      host: baseUri.host,
      port: baseUri.hasPort ? baseUri.port : null,
      pathSegments: <String>[
        ...baseUri.pathSegments.where((segment) => segment.isNotEmpty),
        ...path.segments,
      ],
    );
  }

  static Uri _validateBase(Uri value) {
    if (value.scheme != 'https' ||
        value.host.isEmpty ||
        value.hasQuery ||
        value.hasFragment ||
        value.userInfo.isNotEmpty) {
      throw ArgumentError.value(value, 'baseUri', 'HTTPS base URL is invalid');
    }
    return value;
  }
}
