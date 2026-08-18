import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../app/app_logger.dart';
import '../errors.dart';
import 'data_source.dart';
import 'remote_config.dart';
import 'remote_http.dart';
import 'source_path.dart';

/// Read-only HTTPS source. It intentionally cannot list unknown siblings; a
/// known root URL is required before multipart recovery can begin.
final class HttpsReadOnlyDataSource implements RangeReadableDataSource {
  HttpsReadOnlyDataSource({
    required this.config,
    required http.Client client,
    AppLogger? logger,
  }) : _http = RemoteHttp(client, logger: logger, sourceName: 'HTTPS 数据源');

  final HttpsSourceConfig config;
  final RemoteHttp _http;

  @override
  SourceCapabilities get capabilities => SourceCapabilities(
    canRead: true,
    canWrite: false,
    canDelete: false,
    canListObjects: false,
    supportsRangeRead: true,
    maxObjectBytes: config.maxObjectBytes,
    maxParallelTransfers: 4,
  );

  @override
  Future<SourceRead> get(SourcePath path, {RevisionToken? ifNoneMatch}) async {
    final headers = <String, String>{
      'Accept': 'application/octet-stream',
      'User-Agent': 'SafeBox',
      if (ifNoneMatch != null) 'If-None-Match': _etag(ifNoneMatch),
    };
    final response = await _http.get(config.resolve(path), headers: headers);
    if (response.statusCode == 304 && ifNoneMatch != null) {
      await _http.discard(response.stream);
      return SourceRead(
        body: const Stream<List<int>>.empty(),
        length: 0,
        revision: ifNoneMatch,
        notModified: true,
      );
    }
    if (response.statusCode != 200) {
      await _http.throwForStatus(response, RemoteFailureContext.read);
    }
    final length = response.contentLength;
    if (length == null || length < 0 || length > config.maxObjectBytes) {
      await _http.discard(response.stream);
      throw const SboxException(SboxErrorCode.sourceLimit, 'HTTPS 对象缺少可接受长度');
    }
    final revision = _revision(response.headers['etag'], length);
    return SourceRead(
      body: _verified(response.stream, length),
      length: length,
      revision: revision,
    );
  }

  @override
  Future<SourceRead> getRange(
    SourcePath path, {
    required int start,
    required int endExclusive,
  }) async {
    if (start < 0 || endExclusive <= start) {
      throw const SboxException(SboxErrorCode.invalidHeader, 'HTTPS 范围读取边界无效');
    }
    final response = await _http.get(
      config.resolve(path),
      headers: <String, String>{
        'Accept': 'application/octet-stream',
        'User-Agent': 'SafeBox',
        'Range': 'bytes=$start-${endExclusive - 1}',
      },
    );
    if (response.statusCode != 200 && response.statusCode != 206) {
      await _http.throwForStatus(response, RemoteFailureContext.read);
    }
    final length = response.contentLength;
    final expected = endExclusive - start;
    if (length != null && length != expected) {
      await _http.discard(response.stream);
      throw const SboxException(SboxErrorCode.remoteChanged, 'HTTPS 范围响应长度不一致');
    }
    return SourceRead(
      body: _verified(response.stream, expected),
      length: expected,
      revision: _revision(response.headers['etag'], expected),
    );
  }

  @override
  Future<RevisionToken> putNew(
    SourcePath path,
    Stream<List<int>> body, {
    required int length,
    required Uint8List sha256,
  }) => throw const SboxException(
    SboxErrorCode.sourceAuthentication,
    'HTTPS 数据源为只读',
  );

  @override
  Future<void> deleteIfMatch(SourcePath path, RevisionToken expected) =>
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        'HTTPS 数据源为只读',
      );

  static RevisionToken _revision(String? etag, int length) => RevisionToken(
    utf8.encode(etag == null ? 'length:$length' : 'etag:$etag'),
  );

  static String _etag(RevisionToken token) =>
      ascii.decode(token.bytes, allowInvalid: false);

  static Stream<List<int>> _verified(
    Stream<List<int>> source,
    int expected,
  ) async* {
    var count = 0;
    await for (final chunk in source) {
      count += chunk.length;
      if (count > expected) {
        throw const SboxException(
          SboxErrorCode.remoteChanged,
          'HTTPS 对象超过声明长度',
        );
      }
      yield chunk;
    }
    if (count != expected) {
      throw const SboxException(SboxErrorCode.remoteChanged, 'HTTPS 对象长度不一致');
    }
  }
}
