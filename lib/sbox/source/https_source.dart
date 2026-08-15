import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../bytes.dart';
import '../errors.dart';
import 'data_source.dart';
import 'remote_config.dart';
import 'remote_http.dart';
import 'source_path.dart';

final class HttpsReadOnlyDataSource implements DataSource {
  HttpsReadOnlyDataSource({required this.config, required http.Client client})
    : _http = RemoteHttp(client);

  final HttpsSourceConfig config;
  final RemoteHttp _http;

  @override
  SourceCapabilities get capabilities => SourceCapabilities(
    canRead: true,
    canWrite: false,
    canDelete: false,
    conditionalWrite: false,
    history: false,
    maxObjectBytes: BigInt.from(config.maxObjectBytes),
    maxRequestBodyBytes: BigInt.one,
    uploadEncoding: UploadEncoding.binary,
    maxParallelObjectTransfers: 4,
    supportsStreamingDownload: true,
    supportsResumableObjectDownload: false,
  );

  @override
  Future<SourceRead> get(SourcePath path, {RevisionToken? ifNoneMatch}) async {
    final headers = <String, String>{
      'Accept': 'application/octet-stream',
      'User-Agent': 'SafeBox-v1',
    };
    final etag = ifNoneMatch == null ? null : _etagFrom(ifNoneMatch);
    if (etag != null) {
      headers['If-None-Match'] = etag;
    }
    final response = await _http.get(config.resolve(path), headers: headers);
    if (response.statusCode == 304 && ifNoneMatch != null) {
      await response.stream.drain<void>();
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
      await response.stream.drain<void>();
      throw const SboxException(
        SboxErrorCode.sourceLimit,
        'HTTPS 数据源未提供可接受的对象长度',
      );
    }
    final responseEtag = response.headers['etag'];
    final revision = responseEtag == null || responseEtag.length > 4096
        ? RevisionToken(<int>[0x72, ...secureRandomBytes(32)])
        : RevisionToken(utf8.encode('etag:$responseEtag'));
    return SourceRead(
      body: _verifiedLength(
        _http.withIdleTimeout(response.stream),
        expectedLength: length,
      ),
      length: length,
      revision: revision,
    );
  }

  @override
  Future<RevisionToken> putNew(
    SourcePath path,
    Stream<List<int>> body, {
    required int length,
    required Uint8List sha256,
  }) => throw _readOnly();

  @override
  Future<RevisionToken> compareAndSwap(
    SourcePath path,
    RevisionToken expected,
    Stream<List<int>> body, {
    required int length,
  }) => throw _readOnly();

  @override
  Future<void> deleteIfMatch(SourcePath path, RevisionToken expected) =>
      throw _readOnly();

  static String? _etagFrom(RevisionToken token) {
    try {
      final value = utf8.decode(token.bytes, allowMalformed: false);
      return value.startsWith('etag:') ? value.substring(5) : null;
    } on FormatException {
      return null;
    }
  }

  static Stream<List<int>> _verifiedLength(
    Stream<List<int>> source, {
    required int expectedLength,
  }) async* {
    var count = 0;
    await for (final chunk in source) {
      count += chunk.length;
      if (count > expectedLength) {
        throw const SboxException(
          SboxErrorCode.sourceNetwork,
          'HTTPS 对象超过声明长度',
        );
      }
      yield chunk;
    }
    if (count != expectedLength) {
      throw const SboxException(SboxErrorCode.sourceNetwork, 'HTTPS 对象提前结束');
    }
  }

  static SboxException _readOnly() => const SboxException(
    SboxErrorCode.sourceAuthentication,
    '通用 HTTPS 数据源仅支持读取',
  );
}
