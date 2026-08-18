import 'source_path.dart';

final class RepositorySourceConfig {
  RepositorySourceConfig({
    required String owner,
    required String repository,
    String pathPrefix = '',
  }) : owner = _component(owner, 'owner'),
       repository = _component(repository, 'repository'),
       pathPrefix = _prefix(pathPrefix);

  final String owner;
  final String repository;
  final String pathPrefix;

  String resolveBasename(SourcePath path) =>
      pathPrefix.isEmpty ? path.value : '$pathPrefix/${path.value}';

  static String _component(String value, String name) {
    if (value.isEmpty ||
        value.length > 100 ||
        !RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9_])?$')
            .hasMatch(value) ||
        value == '.' ||
        value == '..') {
      throw ArgumentError.value(value, name, 'Invalid repository component');
    }
    return value;
  }

  static String _prefix(String value) {
    if (value.isEmpty) return '';
    if (value.startsWith('/') ||
        value.endsWith('/') ||
        value.contains('\\') ||
        value.contains('%')) {
      throw ArgumentError.value(value, 'pathPrefix', 'Invalid path prefix');
    }
    final segments = value.split('/');
    if (segments.any(
      (segment) => segment.isEmpty || segment == '.' || segment == '..',
    )) {
      throw ArgumentError.value(value, 'pathPrefix', 'Invalid path prefix');
    }
    return value;
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

  Uri resolve(SourcePath path) => Uri(
    scheme: 'https',
    host: baseUri.host,
    port: baseUri.hasPort ? baseUri.port : null,
    pathSegments: <String>[
      ...baseUri.pathSegments.where((segment) => segment.isNotEmpty),
      path.value,
    ],
  );

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
