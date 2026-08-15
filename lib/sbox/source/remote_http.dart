import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../catalog/strict_json.dart';
import '../errors.dart';

enum RemoteFailureContext { read, immutableCreate, conditionalWrite }

final class RemoteHttp {
  RemoteHttp(
    this.client, {
    this.requestTimeout = const Duration(seconds: 30),
    this.streamIdleTimeout = const Duration(seconds: 30),
  });

  static const int maximumRedirects = 5;
  static const int maximumHeaderBytes = 64 * 1024;
  static const int maximumErrorBodyBytes = 64 * 1024;
  static const int maximumMetadataBytes = 1024 * 1024;

  final http.Client client;
  final Duration requestTimeout;
  final Duration streamIdleTimeout;

  Future<http.StreamedResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    _requireHttps(uri);
    var current = uri;
    var currentHeaders = Map<String, String>.of(headers);
    for (var redirects = 0; ; redirects++) {
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll(currentHeaders);
      final response = await _send(request);
      _checkHeaderLimit(response.headers);
      if (!_isRedirect(response.statusCode)) {
        return response;
      }
      if (redirects >= maximumRedirects) {
        await _discard(response.stream);
        throw _networkError();
      }
      final location = response.headers['location'];
      if (location == null) {
        await _discard(response.stream);
        throw _networkError();
      }
      final next = current.resolve(location);
      _requireHttps(next);
      if (!_sameOrigin(current, next)) {
        currentHeaders.removeWhere((name, _) {
          final lower = name.toLowerCase();
          return lower == 'authorization' || lower == 'cookie';
        });
      }
      await _discard(response.stream);
      current = next;
    }
  }

  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _requireHttps(request.url);
    request.followRedirects = false;
    final response = await _send(request);
    _checkHeaderLimit(response.headers);
    if (_isRedirect(response.statusCode)) {
      await _discard(response.stream);
      // Upload streams cannot safely be replayed after a provider redirect.
      // Canonical API endpoints must not redirect writes, so fail closed.
      throw _networkError();
    }
    return response;
  }

  Stream<List<int>> withIdleTimeout(Stream<List<int>> source) => source.timeout(
    streamIdleTimeout,
    onTimeout: (sink) {
      sink.addError(_networkError());
      sink.close();
    },
  );

  Future<Map<String, Object?>> readJsonObject(
    http.StreamedResponse response, {
    int maximumBytes = maximumMetadataBytes,
  }) async {
    final bytes = await readBounded(
      response.stream,
      maximumBytes: maximumBytes,
    );
    try {
      final value = StrictJsonParser(
        utf8.decode(bytes, allowMalformed: false),
        maximumDepth: 16,
        maximumStringCodeUnits: maximumBytes,
      ).parse();
      if (value is! Map<String, Object?>) {
        throw const FormatException('Expected JSON object');
      }
      return value;
    } on FormatException {
      throw _networkError();
    }
  }

  Future<Uint8List> readBounded(
    Stream<List<int>> source, {
    required int maximumBytes,
  }) async {
    final output = BytesBuilder(copy: false);
    var count = 0;
    try {
      await for (final chunk in withIdleTimeout(source)) {
        count += chunk.length;
        if (count > maximumBytes) {
          throw _networkError();
        }
        output.add(chunk);
      }
      return output.takeBytes();
    } on SboxException {
      rethrow;
    } on TimeoutException {
      throw _networkError();
    } on http.ClientException {
      throw _networkError();
    }
  }

  Future<Never> throwForStatus(
    http.StreamedResponse response,
    RemoteFailureContext context,
  ) async {
    await _discard(response.stream);
    final code = response.statusCode;
    if (code == 401 || code == 403) {
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        '数据源授权缺失、过期或权限不足',
      );
    }
    if (code == 404) {
      throw const SboxException(SboxErrorCode.sourceNotFound, '数据源对象不存在');
    }
    if (code == 409 || code == 412) {
      if (context == RemoteFailureContext.immutableCreate) {
        throw const SboxException(SboxErrorCode.remoteChanged, '远端对象路径已被占用');
      }
      throw const SboxException(SboxErrorCode.syncConflict, '远端已变化，请处理同步冲突');
    }
    if (code == 429) {
      throw const SboxException(SboxErrorCode.sourceRateLimit, '数据源暂时限制请求频率');
    }
    if (code == 413) {
      throw const SboxException(SboxErrorCode.sourceLimit, '对象超过数据源请求上限');
    }
    if (code == 422 && context != RemoteFailureContext.read) {
      throw SboxException(
        context == RemoteFailureContext.conditionalWrite
            ? SboxErrorCode.syncConflict
            : SboxErrorCode.remoteChanged,
        context == RemoteFailureContext.conditionalWrite
            ? '远端条件更新被拒绝'
            : '远端对象创建被拒绝',
      );
    }
    throw _networkError();
  }

  Future<http.StreamedResponse> _send(http.BaseRequest request) async {
    try {
      return await client.send(request).timeout(requestTimeout);
    } on SboxException {
      rethrow;
    } on TimeoutException {
      throw _networkError();
    } on http.ClientException {
      throw _networkError();
    } on Object {
      // Socket/TLS implementations vary between native and web clients. Do
      // not expose their messages because they can include sensitive URLs.
      throw _networkError();
    }
  }

  Future<void> _discard(Stream<List<int>> stream) async {
    var count = 0;
    await for (final chunk in withIdleTimeout(stream)) {
      count += chunk.length;
      if (count > maximumErrorBodyBytes) {
        break;
      }
    }
  }

  static void _checkHeaderLimit(Map<String, String> headers) {
    var size = 0;
    for (final entry in headers.entries) {
      size += entry.key.length + entry.value.length + 4;
      if (size > maximumHeaderBytes) {
        throw _networkError();
      }
    }
  }

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  static bool _sameOrigin(Uri left, Uri right) =>
      left.scheme == right.scheme &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      left.port == right.port;

  static void _requireHttps(Uri uri) {
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw _networkError();
    }
  }

  static SboxException _networkError() =>
      const SboxException(SboxErrorCode.sourceNetwork, '无法安全连接数据源');
}
