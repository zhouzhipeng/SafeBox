import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../errors.dart';
import '../format/strict_json.dart';
import '../logging.dart';

enum RemoteFailureContext { read, immutableCreate, delete }

final class RemoteHttp {
  RemoteHttp(
    this.client, {
    this.requestTimeout = const Duration(seconds: 30),
    this.streamIdleTimeout = const Duration(seconds: 30),
    this.logger,
    this.sourceName = '云端数据源',
  });

  static const int maximumRedirects = 5;
  static const int maximumHeaderBytes = 64 * 1024;
  static const int maximumErrorBodyBytes = 64 * 1024;
  static const int maximumMetadataBytes = 1024 * 1024;

  final http.Client client;
  final Duration requestTimeout;
  final Duration streamIdleTimeout;
  final SboxLogger? logger;
  final String sourceName;

  Future<http.StreamedResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    try {
      _requireHttps(uri);
    } on Object catch (error) {
      _logError(
        error,
        operation: '$sourceName：检查 HTTPS 地址',
        context: _endpoint(uri),
      );
      rethrow;
    }
    var current = uri;
    var currentHeaders = Map<String, String>.of(headers);
    for (var redirects = 0; ; redirects++) {
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll(currentHeaders);
      final response = await _send(request);
      _checkHeaderLimit(response.headers);
      if (!_isRedirect(response.statusCode)) return response;
      if (redirects >= maximumRedirects) {
        await discard(response.stream);
        logger?.warning(
          '$sourceName：重定向次数超过上限',
          detail: 'GET ${_endpoint(uri)} · 最多允许 $maximumRedirects 次',
        );
        throw _networkError();
      }
      final location = response.headers['location'];
      if (location == null) {
        await discard(response.stream);
        logger?.warning(
          '$sourceName：响应缺少重定向地址',
          detail: 'GET ${_endpoint(current)} · HTTP ${response.statusCode}',
        );
        throw _networkError();
      }
      late final Uri next;
      try {
        next = current.resolve(location);
        _requireHttps(next);
      } on Object catch (error) {
        await discard(response.stream);
        _logError(
          error,
          operation: '$sourceName：拒绝不安全重定向',
          context: 'GET ${_endpoint(current)} · HTTP ${response.statusCode}',
        );
        rethrow;
      }
      if (!_sameOrigin(current, next)) {
        currentHeaders.removeWhere(
          (key, _) =>
              key.toLowerCase() == 'authorization' ||
              key.toLowerCase() == 'cookie',
        );
      }
      logger?.info(
        '$sourceName：跟随 HTTPS 重定向',
        detail: '${_endpoint(current)} → ${_endpoint(next)}',
      );
      await discard(response.stream);
      current = next;
    }
  }

  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    try {
      _requireHttps(request.url);
    } on Object catch (error) {
      _logError(
        error,
        operation: '$sourceName：检查 HTTPS 地址',
        context: '${request.method} ${_endpoint(request.url)}',
      );
      rethrow;
    }
    request.followRedirects = false;
    final response = await _send(request);
    _checkHeaderLimit(response.headers);
    if (_isRedirect(response.statusCode)) {
      await discard(response.stream);
      logger?.warning(
        '$sourceName：写入请求被重定向',
        detail:
            '${request.method} ${_endpoint(request.url)} · HTTP ${response.statusCode}',
      );
      throw _networkError();
    }
    return response;
  }

  Stream<List<int>> withIdleTimeout(Stream<List<int>> source) => source.timeout(
    streamIdleTimeout,
    onTimeout: (sink) {
      logger?.error(
        _networkError(),
        operation: '$sourceName：读取云端响应超时',
        context: '响应流连续 $streamIdleTimeout 无数据',
      );
      sink.addError(_networkError());
      sink.close();
    },
  );

  Future<Map<String, Object?>> readJsonObject(
    http.StreamedResponse response, {
    int maximumBytes = maximumMetadataBytes,
  }) async {
    final value = await readJsonValue(response, maximumBytes: maximumBytes);
    if (value is! Map<String, Object?>) {
      logger?.warning('$sourceName：云端对象响应格式错误', detail: '期望 JSON 对象');
      throw const SboxException(SboxErrorCode.sourceNetwork, '数据源返回了无效对象响应');
    }
    return value;
  }

  Future<List<Object?>> readJsonList(
    http.StreamedResponse response, {
    int maximumBytes = maximumMetadataBytes,
  }) async {
    final value = await readJsonValue(
      response,
      maximumBytes: maximumBytes,
      parseInBackground: true,
    );
    if (value is! List<Object?>) {
      logger?.warning('$sourceName：云端列表响应格式错误', detail: '期望 JSON 列表');
      throw const SboxException(SboxErrorCode.sourceNetwork, '数据源返回了无效列表响应');
    }
    return value;
  }

  Future<Object?> readJsonValue(
    http.StreamedResponse response, {
    int maximumBytes = maximumMetadataBytes,
    bool parseInBackground = false,
  }) async {
    final bytes = await readBounded(
      response.stream,
      maximumBytes: maximumBytes,
    );
    try {
      final value = parseInBackground
          ? await Isolate.run<Object?>(
              () => _parseJsonWorker(bytes, maximumBytes),
              debugName: 'safebox-parse-file-list',
            )
          : _parseJsonWorker(bytes, maximumBytes);
      return value;
    } on Object catch (error) {
      _logError(
        error,
        operation: '$sourceName：解析云端 JSON 失败',
        context: '响应体未记录',
      );
      throw const SboxException(
        SboxErrorCode.sourceNetwork,
        '数据源返回了无效 JSON 响应',
      );
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
          logger?.warning(
            '$sourceName：云端响应超过大小上限',
            detail: '读取上限 $maximumBytes 字节',
          );
          throw _networkError();
        }
        output.add(chunk);
      }
    } on SboxException {
      rethrow;
    } on Object catch (error) {
      _logError(
        error,
        operation: '$sourceName：读取云端响应失败',
        context: '已读取 $count 字节',
      );
      throw _networkError();
    }
    return output.takeBytes();
  }

  Future<void> discard(Stream<List<int>> source) async {
    var count = 0;
    try {
      await for (final chunk in withIdleTimeout(source)) {
        count += chunk.length;
        if (count > maximumErrorBodyBytes) break;
      }
    } on Object catch (error) {
      // Draining an error body is cleanup. Preserve the original HTTP status
      // classification even if the provider closes the body unexpectedly.
      _logError(
        error,
        operation: '$sourceName：清理云端错误响应失败',
        context: '已读取 $count 字节',
      );
    }
  }

  Future<Never> throwForStatus(
    http.StreamedResponse response,
    RemoteFailureContext context,
  ) async {
    final statusCode = response.statusCode;
    logger?.warning(
      '$sourceName：云端请求返回错误',
      detail:
          '${response.request?.method ?? 'REQUEST'} ${_endpoint(response.request?.url)} · '
          'HTTP $statusCode · 阶段 ${context.name}',
    );
    await discard(response.stream);
    switch (statusCode) {
      case 401:
      case 403:
        throw const SboxException(
          SboxErrorCode.sourceAuthentication,
          '数据源授权失败',
        );
      case 404:
        throw const SboxException(SboxErrorCode.sourceNotFound, '数据源对象不存在');
      case 409:
      case 412:
        throw SboxException(
          context == RemoteFailureContext.immutableCreate
              ? SboxErrorCode.immutableConflict
              : SboxErrorCode.shardConflict,
          '远端对象状态发生冲突',
        );
      case 429:
        throw const SboxException(SboxErrorCode.sourceRateLimit, '数据源暂时限制请求频率');
      case 413:
        throw const SboxException(SboxErrorCode.sourceLimit, '对象超过数据源上限');
      default:
        throw SboxException(
          SboxErrorCode.sourceNetwork,
          '数据源请求失败（HTTP $statusCode）',
        );
    }
  }

  Future<http.StreamedResponse> _send(http.BaseRequest request) async {
    try {
      return await client.send(request).timeout(requestTimeout);
    } on SboxException {
      rethrow;
    } on Object catch (error) {
      _logError(
        error,
        operation: '$sourceName：建立 HTTPS 请求失败',
        context:
            '${request.method} ${_endpoint(request.url)} · 请求超时 ${requestTimeout.inSeconds}s',
      );
      throw _networkError();
    }
  }

  void _checkHeaderLimit(Map<String, String> headers) {
    var total = 0;
    for (final entry in headers.entries) {
      total += entry.key.length + entry.value.length + 4;
      if (total > maximumHeaderBytes) {
        logger?.warning(
          '$sourceName：云端响应头超过大小上限',
          detail: '读取上限 $maximumHeaderBytes 字节',
        );
        throw _networkError();
      }
    }
  }

  void _logError(
    Object error, {
    required String operation,
    required String context,
  }) {
    logger?.error(error, operation: operation, context: context);
  }

  static String _endpoint(Uri? uri) {
    if (uri == null || uri.host.isEmpty) return '未知地址';
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
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

Object? _parseJsonWorker(Uint8List bytes, int maximumStringCodeUnits) {
  return StrictJsonParser(
    utf8.decode(bytes, allowMalformed: false),
    maximumStringCodeUnits: maximumStringCodeUnits,
  ).parse();
}
