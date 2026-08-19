import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import '../bytes.dart';
import '../errors.dart';
import '../logging.dart';
import 'credential.dart';
import 'data_source.dart';
import 'remote_config.dart';
import 'remote_http.dart';
import 'source_path.dart';

enum RepositoryCredentialPlacement { authorizationHeader, jsonBody, formBody }

abstract base class RepositoryDataSource
    implements EnumerableDataSource, RangeReadableDataSource {
  RepositoryDataSource({
    required this.config,
    required http.Client client,
    required this.credentialStore,
    required this.credentialId,
    this.logger,
    this.sourceName = '云端仓库',
  }) : httpTransport = RemoteHttp(
         client,
         logger: logger,
         sourceName: sourceName,
       );

  final RepositorySourceConfig config;
  final CredentialStore? credentialStore;
  final SourceCredentialId? credentialId;
  final SboxLogger? logger;
  final RemoteHttp httpTransport;

  final String sourceName;

  String get createMethod;
  String get deleteMethod => 'DELETE';
  String get apiAcceptHeader;
  RepositoryCredentialPlacement get credentialPlacement =>
      RepositoryCredentialPlacement.authorizationHeader;

  /// Some repository APIs return an empty JSON array instead of HTTP 404 for
  /// a missing file. Providers opt in because an empty array is invalid
  /// metadata for the default repository response contract.
  bool get emptyMetadataListMeansNotFound => false;

  Uri metadataUri(SourcePath path);
  Uri listUri({String? cursor, int pageSize = 1000});
  Uri writeUri(SourcePath path);
  Uri rawUri(SourcePath path, RepositoryObjectMetadata metadata);

  /// Providers may expose a raw endpoint whose response headers contain all
  /// information needed for a read. This avoids metadata endpoints that
  /// inline the entire file as Base64 content.
  Uri? rawUriWithoutMetadata(SourcePath path) => null;

  Uri repositoryProbeUri();
  Map<String, String> publicHeaders({required bool raw});

  int get providerPageSize => 100;

  /// Whether [listUri] supports the page/per-page cursor contract used by
  /// [listObjects]. Some provider directory endpoints return the complete
  /// directory in one response and ignore those query parameters.
  bool get supportsListPagination => true;

  /// Repository reads and probes intentionally use only public headers. A
  /// credential is loaded only by write operations below, so public
  /// repositories remain usable even when no token is configured.
  Future<void> verifyRepository() async {
    logger?.info('$sourceName：开始测试 API 连接');
    final response = await httpTransport.get(
      repositoryProbeUri(),
      headers: await _requestHeaders(raw: false),
    );
    if (response.statusCode != 200) {
      await httpTransport.throwForStatus(response, RemoteFailureContext.read);
    }
    await httpTransport.discard(response.stream);
    logger?.info('$sourceName：API 连接正常');
  }

  @override
  SourceCapabilities get capabilities => SourceCapabilities(
    canRead: true,
    canWrite: credentialStore != null && credentialId != null,
    canDelete: credentialStore != null && credentialId != null,
    canListObjects: true,
    supportsRangeRead: true,
    maxObjectBytes: 100 * 1024 * 1024,
    maxParallelTransfers: 4,
  );

  @override
  Future<SourceRead> get(SourcePath path, {RevisionToken? ifNoneMatch}) async {
    final directUri = rawUriWithoutMetadata(path);
    if (directUri != null) {
      final headers = await _requestHeaders(raw: true);
      if (ifNoneMatch != null) {
        headers['If-None-Match'] = _revisionString(ifNoneMatch);
      }
      final response = await httpTransport.get(directUri, headers: headers);
      if (response.statusCode == 304 && ifNoneMatch != null) {
        await httpTransport.discard(response.stream);
        return SourceRead(
          body: const Stream<List<int>>.empty(),
          length: 0,
          revision: ifNoneMatch,
          notModified: true,
        );
      }
      if (response.statusCode != 200) {
        await httpTransport.throwForStatus(response, RemoteFailureContext.read);
      }
      final size = _responseSize(response);
      final revision = _responseRevision(response);
      if (size != null &&
          (size < 0 ||
              capabilities.maxObjectBytes != null &&
                  size > capabilities.maxObjectBytes!)) {
        await httpTransport.discard(response.stream);
        throw const SboxException(SboxErrorCode.sourceLimit, '对象超过数据源上限');
      }
      if (size == null || revision == null) {
        // Raw repository endpoints are not required to return both
        // Content-Length and ETag. This is common for large Gitee objects.
        // Buffer only this bounded fallback response so callers still get a
        // verified length and a stable revision token without accepting an
        // unbounded stream.
        return _bufferRawResponse(
          response,
          expectedLength: size,
          revision: revision,
        );
      }
      return SourceRead(
        body: _verifiedStream(response.stream, size),
        length: size,
        revision: revision,
      );
    }
    final metadata = await _readMetadata(path);
    final revision = RevisionToken(ascii.encode(metadata.revision));
    if (ifNoneMatch != null && revision.matches(ifNoneMatch)) {
      return SourceRead(
        body: const Stream<List<int>>.empty(),
        length: 0,
        revision: revision,
        notModified: true,
      );
    }
    final response = await httpTransport.get(
      rawUri(path, metadata),
      headers: await _requestHeaders(raw: true),
    );
    if (response.statusCode != 200) {
      await httpTransport.throwForStatus(response, RemoteFailureContext.read);
    }
    return SourceRead(
      body: _verifiedStream(response.stream, metadata.size),
      length: metadata.size,
      revision: revision,
    );
  }

  @override
  Future<SourceRead> getRange(
    SourcePath path, {
    required int start,
    required int endExclusive,
    SourceObjectInfo? objectInfo,
  }) async {
    if (start < 0 || endExclusive < start) {
      throw const SboxException(SboxErrorCode.invalidHeader, '范围读取边界无效');
    }
    logger?.info('$sourceName：读取对象范围', detail: '读取公共头范围');
    final directUri = rawUriWithoutMetadata(path);
    late final Uri requestUri;
    late final RevisionToken? knownRevision;
    int? knownSize;
    if (directUri != null) {
      requestUri = directUri;
      knownRevision = objectInfo?.revision;
      if (objectInfo != null && objectInfo.length > 0) {
        knownSize = objectInfo.length;
      }
    } else {
      final metadata =
          objectInfo == null ||
              objectInfo.length == 0 ||
              objectInfo.downloadUri == null
          ? await _readMetadata(path)
          : RepositoryObjectMetadata(
              revision: _revisionString(objectInfo.revision),
              size: objectInfo.length,
              downloadUri: objectInfo.downloadUri,
            );
      requestUri = rawUri(path, metadata);
      knownRevision = RevisionToken(ascii.encode(metadata.revision));
      knownSize = metadata.size;
    }
    if (knownSize != null && endExclusive > knownSize) {
      throw const SboxException(SboxErrorCode.truncated, '范围读取超过对象长度');
    }
    final response = await httpTransport.get(
      requestUri,
      headers: <String, String>{
        ...await _requestHeaders(raw: true),
        'Range': 'bytes=$start-${endExclusive - 1}',
      },
    );
    if (response.statusCode != 200 && response.statusCode != 206) {
      await httpTransport.throwForStatus(response, RemoteFailureContext.read);
    }
    final requestedLength = endExclusive - start;
    final revision = knownRevision ?? _responseRevision(response);
    if (revision == null) {
      final body = response.statusCode == 200
          ? _sliceStream(response.stream, start: start, length: requestedLength)
          : _verifiedStream(response.stream, requestedLength);
      final bytes = await httpTransport.readBounded(
        body,
        maximumBytes: requestedLength,
      );
      if (bytes.length != requestedLength) {
        throw const SboxException(SboxErrorCode.remoteChanged, '范围读取响应长度不一致');
      }
      return SourceRead(
        body: Stream<List<int>>.value(bytes),
        length: requestedLength,
        revision: _fallbackRevision(bytes),
      );
    }
    final body = response.statusCode == 200
        ? _sliceStream(response.stream, start: start, length: requestedLength)
        : _verifiedStream(response.stream, requestedLength);
    return SourceRead(body: body, length: requestedLength, revision: revision);
  }

  Future<SourceRead> _bufferRawResponse(
    http.StreamedResponse response, {
    required int? expectedLength,
    required RevisionToken? revision,
  }) async {
    final maximumBytes =
        expectedLength ?? capabilities.maxObjectBytes ?? 100 * 1024 * 1024;
    final bytes = await httpTransport.readBounded(
      response.stream,
      maximumBytes: maximumBytes,
    );
    if (expectedLength != null && bytes.length != expectedLength) {
      throw const SboxException(SboxErrorCode.remoteChanged, '远端对象长度不一致');
    }
    return SourceRead(
      body: Stream<List<int>>.value(bytes),
      length: bytes.length,
      revision: revision ?? _fallbackRevision(bytes),
    );
  }

  static RevisionToken _fallbackRevision(List<int> bytes) {
    final digest = sha256Bytes(bytes);
    try {
      return RevisionToken(ascii.encode('raw-sha256:${hexLower(digest)}'));
    } finally {
      digest.fillRange(0, digest.length, 0);
    }
  }

  @override
  Future<SourceListPage> listObjects({
    String? cursor,
    int pageSize = 1000,
  }) async {
    if (pageSize < 1 || pageSize > 1000) {
      throw const SboxException(SboxErrorCode.sourceLimit, '列举分页大小无效');
    }
    logger?.info('$sourceName：开始列举云端对象', detail: '分页 ${cursor ?? '1'}');
    final response = await httpTransport.get(
      listUri(cursor: cursor, pageSize: pageSize),
      headers: await _requestHeaders(raw: false),
    );
    if (response.statusCode != 200) {
      await httpTransport.throwForStatus(response, RemoteFailureContext.read);
    }
    final values = await httpTransport.readJsonList(response);
    final objects = <SourceObjectInfo>[];
    for (final value in values) {
      if (value is! Map<String, Object?> || value['type'] != 'file') continue;
      final name = value['name'];
      final revision = value['sha'];
      final size = value['size'];
      final downloadUri = _parseDownloadUri(value['download_url']);
      if (name is! String ||
          revision is! String ||
          (size is! int && size != null) ||
          size is int && size < 0) {
        continue;
      }
      try {
        final path = SourcePath(name);
        if (!name.endsWith('.sbox')) continue;
        objects.add(
          SourceObjectInfo(
            path: path,
            // Some provider directory responses omit size even for files.
            // Providers with a direct raw endpoint can read without it;
            // other providers retrieve metadata on demand.
            length: size is int ? size : 0,
            revision: RevisionToken(ascii.encode(revision)),
            downloadUri: downloadUri,
          ),
        );
      } on Object {
        continue;
      }
      if (objects.length > 100000) {
        throw const SboxException(SboxErrorCode.sourceLimit, '数据源对象数量超过上限');
      }
    }
    objects.sort((left, right) => left.path.value.compareTo(right.path.value));
    final pageNumber = int.tryParse(cursor ?? '1') ?? 1;
    final nextCursor =
        supportsListPagination && values.length >= providerPageSize
        ? (pageNumber + 1).toString()
        : null;
    logger?.info(
      '$sourceName：云端对象列举完成',
      detail: '本页识别 ${objects.length} 个 SBOX 对象',
    );
    return SourceListPage(
      objects: List.unmodifiable(objects),
      nextCursor: nextCursor,
    );
  }

  @override
  Future<RevisionToken> putNew(
    SourcePath path,
    Stream<List<int>> body, {
    required int length,
    required Uint8List sha256,
  }) async {
    _requireWrite();
    if (length < 0 || sha256.length != 32) {
      throw ArgumentError('Invalid object dimensions');
    }
    final bytes = await _readBody(body, length, sha256);
    try {
      final remote = await get(path);
      final remoteBytes = await httpTransport.readBounded(
        remote.body,
        maximumBytes: length,
      );
      if (constantTimeBytesEqual(sha256Bytes(remoteBytes), sha256)) {
        return remote.revision;
      }
      throw const SboxException(
        SboxErrorCode.immutableConflict,
        '远端对象路径已存在但内容不同',
      );
    } on SboxException catch (error) {
      if (error.code != SboxErrorCode.sourceNotFound) rethrow;
    }
    try {
      final response = await _withCredential((token) async {
        final request = http.Request(createMethod, writeUri(path))
          ..headers.addAll(publicHeaders(raw: false));
        final fields = <String, String>{
          'message': 'sbox: add immutable object',
          'content': base64Encode(bytes),
          if (credentialPlacement == RepositoryCredentialPlacement.jsonBody ||
              credentialPlacement == RepositoryCredentialPlacement.formBody)
            'access_token': token,
        };
        if (credentialPlacement == RepositoryCredentialPlacement.formBody) {
          request.bodyFields = fields;
        } else {
          request
            ..headers['Content-Type'] = 'application/json; charset=utf-8'
            ..bodyBytes = utf8.encode(jsonEncode(fields));
        }
        if (credentialPlacement ==
            RepositoryCredentialPlacement.authorizationHeader) {
          request.headers['Authorization'] = 'Bearer $token';
        }
        return httpTransport.send(request);
      });
      if (response.statusCode != 200 && response.statusCode != 201) {
        await httpTransport.throwForStatus(
          response,
          RemoteFailureContext.immutableCreate,
        );
      }
      final value = await httpTransport.readJsonObject(response);
      final content = value['content'];
      final providerRevision =
          content is Map<String, Object?> && content['sha'] is String
          ? content['sha']! as String
          : hexLower(sha256);
      return RevisionToken(ascii.encode(providerRevision));
    } on SboxException catch (error) {
      // A PUT can have an ambiguous outcome: the provider may commit the
      // object and then lose or reject the response. Confirm the immutable
      // bytes before allowing the caller to retry the write. This covers the
      // GitHub Contents API's HTTP 422 response after a path becomes visible,
      // as well as transport failures after the request was submitted.
      if (error.code == SboxErrorCode.immutableConflict ||
          error.code == SboxErrorCode.sourceNetwork) {
        final existingRevision = await _existingRevisionIfSame(
          path,
          length: length,
          expectedHash: sha256,
        );
        if (existingRevision != null) return existingRevision;
      }
      rethrow;
    }
  }

  Future<RevisionToken?> _existingRevisionIfSame(
    SourcePath path, {
    required int length,
    required Uint8List expectedHash,
  }) async {
    // Directory and object metadata endpoints can briefly disagree after a
    // successful commit. A short bounded confirmation window prevents a
    // successful immutable upload from being reported as a failure.
    const maxAttempts = 4;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final remote = await get(path);
        if (remote.length != length) {
          await httpTransport.discard(remote.body);
          return null;
        }
        final remoteBytes = await httpTransport.readBounded(
          remote.body,
          maximumBytes: length,
        );
        return constantTimeBytesEqual(sha256Bytes(remoteBytes), expectedHash)
            ? remote.revision
            : null;
      } on SboxException catch (error) {
        if (error.code == SboxErrorCode.cancelled) rethrow;
        if (error.code != SboxErrorCode.sourceNotFound &&
            error.code != SboxErrorCode.sourceNetwork) {
          return null;
        }
      } on Object {
        return null;
      }
      if (attempt + 1 < maxAttempts) {
        await Future<void>.delayed(
          Duration(milliseconds: 100 * (1 << attempt)),
        );
      }
    }
    return null;
  }

  @override
  Future<void> deleteIfMatch(SourcePath path, RevisionToken expected) async {
    if (!capabilities.canDelete) {
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        '当前数据源不允许删除',
      );
    }
    final revision = _revisionString(expected);
    await _withCredential((token) async {
      final request = http.Request(deleteMethod, writeUri(path))
        ..headers.addAll(publicHeaders(raw: false))
        ..headers['Content-Type'] =
            credentialPlacement == RepositoryCredentialPlacement.formBody
            ? 'application/x-www-form-urlencoded'
            : 'application/json; charset=utf-8';
      final fields = <String, String>{
        'message': 'sbox: delete immutable object',
        'sha': revision,
        if (credentialPlacement == RepositoryCredentialPlacement.jsonBody ||
            credentialPlacement == RepositoryCredentialPlacement.formBody)
          'access_token': token,
      };
      if (credentialPlacement == RepositoryCredentialPlacement.formBody) {
        request.bodyFields = fields;
      } else {
        request.body = jsonEncode(fields);
      }
      if (credentialPlacement ==
          RepositoryCredentialPlacement.authorizationHeader) {
        request.headers['Authorization'] = 'Bearer $token';
      }
      final response = await httpTransport.send(request);
      if (response.statusCode != 200 && response.statusCode != 204) {
        await httpTransport.throwForStatus(
          response,
          RemoteFailureContext.delete,
        );
      }
      await httpTransport.discard(response.stream);
    });
  }

  Future<RepositoryObjectMetadata> _readMetadata(SourcePath path) async {
    final response = await httpTransport.get(
      metadataUri(path),
      headers: await _requestHeaders(raw: false),
    );
    if (response.statusCode != 200) {
      await httpTransport.throwForStatus(response, RemoteFailureContext.read);
    }
    final value = await httpTransport.readJsonValue(response);
    if (emptyMetadataListMeansNotFound &&
        value is List<Object?> &&
        value.isEmpty) {
      throw const SboxException(SboxErrorCode.sourceNotFound, '数据源对象不存在');
    }
    if (value is! Map<String, Object?>) {
      logger?.warning('$sourceName：对象元数据格式错误');
      throw const SboxException(SboxErrorCode.sourceNetwork, '数据源返回了无效对象响应');
    }
    final type = value['type'];
    final revision = value['sha'];
    final size = value['size'];
    final downloadUri = _parseDownloadUri(value['download_url']);
    if (type != 'file' ||
        revision is! String ||
        revision.isEmpty ||
        size is! int ||
        size < 0 ||
        (capabilities.maxObjectBytes != null &&
            size > capabilities.maxObjectBytes!)) {
      logger?.warning('$sourceName：对象元数据字段无效');
      throw const SboxException(SboxErrorCode.sourceNetwork, '数据源返回了无效对象元数据');
    }
    return RepositoryObjectMetadata(
      revision: revision,
      size: size,
      downloadUri: downloadUri,
    );
  }

  Uri? _parseDownloadUri(Object? value) {
    if (value is! String || value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return uri;
  }

  Uri resolvedDownloadUri(RepositoryObjectMetadata metadata) {
    final uri = metadata.downloadUri;
    if (uri == null) {
      throw const SboxException(SboxErrorCode.sourceNetwork, '远端文件响应缺少下载地址');
    }
    return uri;
  }

  Future<Map<String, String>> _requestHeaders({required bool raw}) async {
    final headers = publicHeaders(raw: raw);
    final store = credentialStore;
    final id = credentialId;
    if (store == null || id == null) return headers;
    final token = await store.getAccessToken(id);
    if (token == null) return headers;
    try {
      final authenticated = token.useAuthorizationValue(
        readAuthorizationScheme,
        (authorization) => <String, String>{
          ...headers,
          'Authorization': authorization,
        },
      );
      return authenticated;
    } finally {
      token.dispose();
    }
  }

  /// Gitee's v5 API expects the legacy `token` authorization scheme, while
  /// GitHub accepts `Bearer`. Writes keep their provider-specific body format;
  /// this scheme applies to read and probe requests.
  String get readAuthorizationScheme =>
      credentialPlacement == RepositoryCredentialPlacement.formBody
      ? 'token'
      : 'Bearer';

  Future<T> _withCredential<T>(Future<T> Function(String value) action) async {
    final store = credentialStore;
    final id = credentialId;
    if (store == null || id == null) {
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        '数据源未配置写入凭据',
      );
    }
    final token = await store.getAccessToken(id);
    if (token == null) {
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        '数据源写入凭据不存在',
      );
    }
    try {
      return await token.useBytes(
        (bytes) => action(ascii.decode(bytes, allowInvalid: false)),
      );
    } finally {
      token.dispose();
    }
  }

  void _requireWrite() {
    if (!capabilities.canWrite) {
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        '当前数据源不允许写入',
      );
    }
  }

  static Future<Uint8List> _readBody(
    Stream<List<int>> body,
    int length,
    Uint8List expectedHash,
  ) async {
    final builder = BytesBuilder(copy: false);
    final accumulator = HashDigestSink();
    final sink = crypto.sha256.startChunkedConversion(accumulator);
    var count = 0;
    await for (final chunk in body) {
      count += chunk.length;
      if (count > length) {
        throw const SboxException(SboxErrorCode.integrity, '上传对象超过声明长度');
      }
      builder.add(chunk);
      sink.add(chunk);
    }
    sink.close();
    if (count != length ||
        !constantTimeBytesEqual(accumulator.value.bytes, expectedHash)) {
      throw const SboxException(SboxErrorCode.integrity, '上传对象摘要不匹配');
    }
    return builder.takeBytes();
  }

  static Stream<List<int>> _verifiedStream(
    Stream<List<int>> source,
    int expectedLength,
  ) async* {
    var count = 0;
    await for (final chunk in source) {
      count += chunk.length;
      if (count > expectedLength) {
        throw const SboxException(SboxErrorCode.remoteChanged, '远端对象超过声明长度');
      }
      yield chunk;
    }
    if (count != expectedLength) {
      throw const SboxException(SboxErrorCode.remoteChanged, '远端对象长度不一致');
    }
  }

  /// Some raw repository endpoints ignore Range and return HTTP 200 with the
  /// complete object. Expose only the requested window in that case.
  static Stream<List<int>> _sliceStream(
    Stream<List<int>> source, {
    required int start,
    required int length,
  }) async* {
    if (length == 0) return;
    var skipped = 0;
    var emitted = 0;
    await for (final chunk in source) {
      var offset = 0;
      if (skipped < start) {
        final remainingToSkip = start - skipped;
        if (remainingToSkip >= chunk.length) {
          skipped += chunk.length;
          continue;
        }
        skipped += remainingToSkip;
        offset = remainingToSkip;
      }
      final remainingToEmit = length - emitted;
      final available = chunk.length - offset;
      final take = remainingToEmit < available ? remainingToEmit : available;
      if (take > 0) {
        yield chunk.sublist(offset, offset + take);
        emitted += take;
      }
      if (emitted == length) return;
    }
    throw const SboxException(SboxErrorCode.remoteChanged, '远端对象长度不一致');
  }

  static String _revisionString(RevisionToken token) {
    try {
      final value = ascii.decode(token.bytes, allowInvalid: false);
      if (value.isEmpty || value.length > 4096) throw const FormatException();
      return value;
    } on FormatException {
      throw const SboxException(SboxErrorCode.shardConflict, '数据源修订令牌无效');
    }
  }

  static RevisionToken? _responseRevision(http.StreamedResponse response) {
    final etag = response.headers['etag'];
    if (etag == null || etag.isEmpty) return null;
    try {
      return RevisionToken(ascii.encode(etag));
    } on FormatException {
      return null;
    }
  }

  static int? _responseSize(http.StreamedResponse response) {
    final size = response.contentLength;
    if (size != null) return size;
    final header = response.headers['content-length'];
    final parsed = header == null ? null : int.tryParse(header);
    return parsed != null && parsed >= 0 ? parsed : null;
  }
}

final class RepositoryObjectMetadata {
  const RepositoryObjectMetadata({
    required this.revision,
    required this.size,
    this.downloadUri,
  });

  final String revision;
  final int size;
  final Uri? downloadUri;
}
