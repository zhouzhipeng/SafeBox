import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import '../bytes.dart';
import '../errors.dart';
import 'credential.dart';
import 'data_source.dart';
import 'remote_config.dart';
import 'remote_http.dart';
import 'source_path.dart';

enum RepositoryCredentialPlacement { authorizationHeader, jsonBody }

abstract base class RepositoryDataSource implements DataSource {
  RepositoryDataSource({
    required this.config,
    required http.Client client,
    required this.credentialStore,
    required this.credentialId,
  }) : httpTransport = RemoteHttp(client);

  final RepositorySourceConfig config;
  final CredentialStore? credentialStore;
  final SourceCredentialId? credentialId;
  final RemoteHttp httpTransport;

  String get createMethod;
  String get updateMethod => 'PUT';
  String get deleteMethod => 'DELETE';
  String get authorizationScheme => 'Bearer';
  RepositoryCredentialPlacement get credentialPlacement =>
      RepositoryCredentialPlacement.authorizationHeader;
  String get apiAcceptHeader;

  Uri metadataUri(SourcePath path);
  Uri writeUri(SourcePath path);
  Uri rawUri(SourcePath path, RepositoryObjectMetadata metadata);

  /// URI used by the connection test to validate the repository and branch
  /// independently from the optional `catalog.sbox` object.
  Uri repositoryProbeUri();
  Map<String, String> publicHeaders({required bool raw});

  /// Verifies that the repository and configured branch are reachable.
  ///
  /// A repository can be valid but not initialized yet (for example, an
  /// otherwise empty public GitHub repository).  Keeping this probe separate
  /// from [get] lets the UI distinguish that state from a missing repository,
  /// branch, or directory prefix.
  Future<void> verifyRepository() async {
    final response = await httpTransport.get(
      repositoryProbeUri(),
      headers: publicHeaders(raw: false),
    );
    if (response.statusCode != 200) {
      await httpTransport.throwForStatus(response, RemoteFailureContext.read);
    }
    await httpTransport.readBounded(
      response.stream,
      maximumBytes: RemoteHttp.maximumMetadataBytes,
    );
  }

  @override
  Future<SourceRead> get(SourcePath path, {RevisionToken? ifNoneMatch}) async {
    final metadata = await _readMetadata(path);
    final revision = RevisionToken(ascii.encode(metadata.blobSha));
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
      headers: publicHeaders(raw: true),
    );
    if (response.statusCode != 200) {
      await httpTransport.throwForStatus(response, RemoteFailureContext.read);
    }
    final declared = response.contentLength;
    if (declared != null && declared != metadata.size) {
      await response.stream.drain<void>();
      throw const SboxException(SboxErrorCode.sourceNetwork, '远端对象长度与元数据不一致');
    }
    return SourceRead(
      body: _verifiedGitBlobStream(
        httpTransport.withIdleTimeout(response.stream),
        expectedLength: metadata.size,
        expectedBlobSha: metadata.blobSha,
      ),
      length: metadata.size,
      revision: revision,
    );
  }

  @override
  Future<RevisionToken> putNew(
    SourcePath path,
    Stream<List<int>> body, {
    required int length,
    required Uint8List sha256,
  }) async {
    _requireWritableLength(length);
    if (sha256.length != 32) {
      throw ArgumentError.value(sha256.length, 'sha256.length');
    }

    RepositoryObjectMetadata? existing;
    try {
      existing = await _readMetadata(path);
    } on SboxException catch (error) {
      if (error.code != SboxErrorCode.sourceNotFound) {
        rethrow;
      }
    }
    if (existing != null) {
      if (path.value == 'catalog.sbox') {
        throw const SboxException(
          SboxErrorCode.remoteChanged,
          '远端 catalog.sbox 已存在',
        );
      }
      final remote = await get(path);
      final remoteHash = await _sha256Of(remote.body, expectedLength: length);
      if (constantTimeBytesEqual(remoteHash, sha256)) {
        return remote.revision;
      }
      throw const SboxException(SboxErrorCode.remoteChanged, '远端对象路径已存在但内容不同');
    }

    return _writeContent(
      method: createMethod,
      path: path,
      body: body,
      length: length,
      expectedSha256: sha256,
      expectedRevision: null,
      message: 'sbox: add encrypted object',
      context: RemoteFailureContext.immutableCreate,
    );
  }

  @override
  Future<RevisionToken> compareAndSwap(
    SourcePath path,
    RevisionToken expected,
    Stream<List<int>> body, {
    required int length,
  }) async {
    if (path.value != 'catalog.sbox') {
      throw ArgumentError('compareAndSwap is reserved for catalog.sbox');
    }
    _requireWritableLength(length);
    final expectedSha = _decodeRevision(expected);
    return _writeContent(
      method: updateMethod,
      path: path,
      body: body,
      length: length,
      expectedRevision: expectedSha,
      message: 'sbox: update encrypted catalog',
      context: RemoteFailureContext.conditionalWrite,
    );
  }

  @override
  Future<void> deleteIfMatch(SourcePath path, RevisionToken expected) async {
    if (!capabilities.canDelete ||
        credentialPlacement !=
            RepositoryCredentialPlacement.authorizationHeader) {
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        '此数据源不允许安全的远程对象删除',
      );
    }
    _requireWriteCapability();
    final expectedSha = _decodeRevision(expected);
    final requestBody = utf8.encode(
      jsonEncode(<String, Object?>{
        'message': 'sbox: delete encrypted object',
        'sha': expectedSha,
        'branch': config.branch,
      }),
    );
    if (BigInt.from(requestBody.length) >
        (capabilities.maxRequestBodyBytes ?? BigInt.from(requestBody.length))) {
      throw _sourceLimit();
    }
    final response = await _withCredential((credentialValue) async {
      final request = http.Request(deleteMethod, writeUri(path))
        ..headers.addAll(publicHeaders(raw: false))
        ..headers.addAll(<String, String>{
          'Accept': apiAcceptHeader,
          'Authorization': '$authorizationScheme $credentialValue',
          'Content-Type': 'application/json; charset=utf-8',
        })
        ..bodyBytes = requestBody;
      return httpTransport.send(request);
    });
    if (response.statusCode != 200 && response.statusCode != 204) {
      await httpTransport.throwForStatus(
        response,
        RemoteFailureContext.conditionalWrite,
      );
    }
    await httpTransport.readBounded(
      response.stream,
      maximumBytes: RemoteHttp.maximumMetadataBytes,
    );
  }

  Future<RepositoryObjectMetadata> _readMetadata(SourcePath path) async {
    final response = await httpTransport.get(
      metadataUri(path),
      headers: publicHeaders(raw: false),
    );
    if (response.statusCode != 200) {
      await httpTransport.throwForStatus(response, RemoteFailureContext.read);
    }
    final value = await httpTransport.readJsonObject(response);
    final type = value['type'];
    final sha = value['sha'];
    final size = value['size'];
    if (type != 'file' ||
        sha is! String ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(sha) ||
        size is! int ||
        size < 0 ||
        BigInt.from(size) >
            (capabilities.maxObjectBytes ?? BigInt.from(size))) {
      throw const SboxException(SboxErrorCode.sourceNetwork, '数据源返回了无效对象元数据');
    }
    return RepositoryObjectMetadata(blobSha: sha, size: size);
  }

  Future<RevisionToken> _writeContent({
    required String method,
    required SourcePath path,
    required Stream<List<int>> body,
    required int length,
    required String message,
    required RemoteFailureContext context,
    Uint8List? expectedSha256,
    String? expectedRevision,
  }) async {
    _requireWriteCapability();
    final response = await _withCredential((credentialValue) async {
      final credentialField =
          credentialPlacement == RepositoryCredentialPlacement.jsonBody
          ? '"access_token":${jsonEncode(credentialValue)},'
          : '';
      final prefix = utf8.encode(
        '{$credentialField"message":${jsonEncode(message)},"content":"',
      );
      final suffix = utf8.encode(
        '",'
        '${expectedRevision == null ? '' : '"sha":${jsonEncode(expectedRevision)},'}'
        '"branch":${jsonEncode(config.branch)}}',
      );
      final base64Length = 4 * ((length + 2) ~/ 3);
      final requestLength = prefix.length + base64Length + suffix.length;
      final maxRequest = capabilities.maxRequestBodyBytes;
      if (maxRequest != null && BigInt.from(requestLength) > maxRequest) {
        throw _sourceLimit();
      }
      final request = http.StreamedRequest(method, writeUri(path))
        ..contentLength = requestLength
        ..headers.addAll(publicHeaders(raw: false))
        ..headers.addAll(<String, String>{
          'Accept': apiAcceptHeader,
          'Content-Type': 'application/json; charset=utf-8',
        });
      if (credentialPlacement ==
          RepositoryCredentialPlacement.authorizationHeader) {
        request.headers['Authorization'] =
            '$authorizationScheme $credentialValue';
      }
      final responseFuture = httpTransport.send(request);
      try {
        request.sink.add(prefix);
        await request.sink.addStream(
          _base64JsonContent(
            body,
            expectedLength: length,
            expectedSha256: expectedSha256,
          ),
        );
        request.sink.add(suffix);
        await request.sink.close();
        return await responseFuture;
      } on Object {
        await request.sink.close();
        rethrow;
      } finally {
        if (credentialPlacement == RepositoryCredentialPlacement.jsonBody) {
          prefix.fillRange(0, prefix.length, 0);
        }
      }
    });
    if (response.statusCode != 200 && response.statusCode != 201) {
      await httpTransport.throwForStatus(response, context);
    }
    final value = await httpTransport.readJsonObject(response);
    final content = value['content'];
    final sha = content is Map<String, Object?> ? content['sha'] : null;
    if (sha is! String || !RegExp(r'^[0-9a-f]{40}$').hasMatch(sha)) {
      throw const SboxException(SboxErrorCode.sourceNetwork, '数据源未返回有效版本令牌');
    }
    return RevisionToken(ascii.encode(sha));
  }

  Future<T> _withCredential<T>(
    Future<T> Function(String credentialValue) action,
  ) async {
    final store = credentialStore;
    final id = credentialId;
    if (store == null || id == null) {
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        '数据源尚未配置写入凭据',
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
      final credentialValue = token.useBytes(
        (bytes) => ascii.decode(bytes, allowInvalid: false),
      );
      return await action(credentialValue);
    } finally {
      token.dispose();
    }
  }

  void _requireWritableLength(int length) {
    _requireWriteCapability();
    if (length < 0) {
      throw ArgumentError.value(length, 'length');
    }
    final maximum = capabilities.maxObjectBytes;
    if (maximum != null && BigInt.from(length) > maximum) {
      throw _sourceLimit();
    }
  }

  void _requireWriteCapability() {
    if (!capabilities.canWrite) {
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        '此数据源不允许写入',
      );
    }
  }

  static String _decodeRevision(RevisionToken token) {
    String value;
    try {
      value = ascii.decode(token.bytes, allowInvalid: false);
    } on FormatException {
      throw const SboxException(SboxErrorCode.syncConflict, '数据源版本令牌无效');
    }
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(value)) {
      throw const SboxException(SboxErrorCode.syncConflict, '数据源版本令牌无效');
    }
    return value;
  }

  static Stream<List<int>> _base64JsonContent(
    Stream<List<int>> input, {
    required int expectedLength,
    Uint8List? expectedSha256,
  }) async* {
    var carry = Uint8List(0);
    var count = 0;
    final accumulator = AccumulatorSink<crypto.Digest>();
    final hashSink = crypto.sha256.startChunkedConversion(accumulator);
    await for (final sourceChunk in input) {
      if (sourceChunk.isEmpty) {
        continue;
      }
      count += sourceChunk.length;
      if (count > expectedLength) {
        hashSink.close();
        throw const SboxException(SboxErrorCode.integrity, '上传流超过声明长度');
      }
      hashSink.add(sourceChunk);
      final combined = Uint8List(carry.length + sourceChunk.length)
        ..setRange(0, carry.length, carry)
        ..setRange(
          carry.length,
          carry.length + sourceChunk.length,
          sourceChunk,
        );
      final completeLength = (combined.length ~/ 3) * 3;
      if (completeLength > 0) {
        yield ascii.encode(base64Encode(combined.sublist(0, completeLength)));
      }
      carry = Uint8List.fromList(combined.sublist(completeLength));
    }
    if (count != expectedLength) {
      hashSink.close();
      throw const SboxException(SboxErrorCode.truncated, '上传流提前结束');
    }
    hashSink.close();
    if (expectedSha256 != null &&
        !constantTimeBytesEqual(
          accumulator.events.single.bytes,
          expectedSha256,
        )) {
      throw const SboxException(SboxErrorCode.integrity, '上传对象摘要不匹配');
    }
    if (carry.isNotEmpty) {
      yield ascii.encode(base64Encode(carry));
    }
  }

  static Stream<List<int>> _verifiedGitBlobStream(
    Stream<List<int>> source, {
    required int expectedLength,
    required String expectedBlobSha,
  }) async* {
    final accumulator = AccumulatorSink<crypto.Digest>();
    final sink = crypto.sha1.startChunkedConversion(accumulator);
    sink.add(ascii.encode('blob $expectedLength\u0000'));
    var count = 0;
    await for (final chunk in source) {
      count += chunk.length;
      if (count > expectedLength) {
        sink.close();
        throw const SboxException(SboxErrorCode.sourceNetwork, '远端对象超过声明长度');
      }
      sink.add(chunk);
      yield chunk;
    }
    sink.close();
    if (count != expectedLength ||
        hexLower(accumulator.events.single.bytes) != expectedBlobSha) {
      throw const SboxException(SboxErrorCode.remoteChanged, '远端对象在读取期间发生变化');
    }
  }

  static Future<Uint8List> _sha256Of(
    Stream<List<int>> source, {
    required int expectedLength,
  }) async {
    final accumulator = AccumulatorSink<crypto.Digest>();
    final sink = crypto.sha256.startChunkedConversion(accumulator);
    var count = 0;
    await for (final chunk in source) {
      count += chunk.length;
      if (count > expectedLength) {
        sink.close();
        throw const SboxException(SboxErrorCode.remoteChanged, '远端对象长度冲突');
      }
      sink.add(chunk);
    }
    sink.close();
    if (count != expectedLength) {
      throw const SboxException(SboxErrorCode.remoteChanged, '远端对象长度冲突');
    }
    return Uint8List.fromList(accumulator.events.single.bytes);
  }

  static SboxException _sourceLimit() =>
      const SboxException(SboxErrorCode.sourceLimit, '对象超过数据源能力上限');
}

final class RepositoryObjectMetadata {
  const RepositoryObjectMetadata({required this.blobSha, required this.size});

  final String blobSha;
  final int size;
}
