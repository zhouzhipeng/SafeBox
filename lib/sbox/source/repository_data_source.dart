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

/// The release used as SafeBox's repository-backed object store.
///
/// A dedicated tag keeps SafeBox assets isolated from unrelated releases in a
/// repository. The release is created lazily on the first writable operation.
const String safeBoxReleaseTag = 'latest';

final class RepositoryReleaseMetadata {
  const RepositoryReleaseMetadata({required this.id, required this.tagName});

  final int id;
  final String tagName;
}

/// Metadata for one release asset, represented in the generic DataSource
/// protocol as a repository object.
final class RepositoryObjectMetadata {
  const RepositoryObjectMetadata({
    required this.revision,
    required this.size,
    required this.downloadUri,
    this.releaseId = 0,
    this.assetId = 0,
    this.assetName = '',
  });

  final String revision;
  final int size;
  final Uri downloadUri;
  final int releaseId;
  final int assetId;
  final String assetName;
}

/// Shared Release/asset implementation for GitHub and Gitee.
///
/// The provider subclasses only describe their endpoint shapes and request
/// encodings. All object semantics live here: lazy creation of the dedicated
/// latest release, asset pagination, immutable uploads, range reads, and
/// revision-checked deletion.
abstract base class RepositoryDataSource
    implements EnumerableDataSource, RangeReadableDataSource {
  RepositoryDataSource({
    required this.config,
    required http.Client client,
    required this.credentialStore,
    required this.credentialId,
    this.logger,
    this.sourceName = 'Repository',
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

  /// Public web host used by provider Release download links.
  String get publicWebHost;

  /// Returns the public Release URL for one object in this repository.
  ///
  /// SafeBox uses a stable dedicated tag, so a known root-object URL can also
  /// be used to derive the URLs of the remaining Bundle shards.
  Uri publicReleaseAssetUri(SourcePath path) => Uri(
    scheme: 'https',
    host: publicWebHost,
    pathSegments: <String>[
      config.owner,
      config.repository,
      'releases',
      'download',
      safeBoxReleaseTag,
      _assetNameForPath(path),
    ],
  );

  /// Provider-specific release and asset endpoints.
  Uri latestReleaseUri();

  Uri createReleaseUri();

  Uri assetListUri({
    required int releaseId,
    required int page,
    required int perPage,
  });

  Uri assetDownloadUri({required int releaseId, required int assetId});

  Uri assetDeleteUri({required int releaseId, required int assetId});

  Uri repositoryProbeUri();

  Map<String, String> publicHeaders({required bool raw});

  /// Builds the provider-specific request for creating the SafeBox release.
  Future<http.BaseRequest> createLatestReleaseRequest(String token);

  /// Builds the provider-specific raw or multipart upload request.
  Future<http.BaseRequest> uploadAssetRequest({
    required RepositoryReleaseMetadata release,
    required String token,
    required String assetName,
    required Uint8List bytes,
  });

  /// Builds the provider-specific asset deletion request.
  http.BaseRequest deleteAssetRequest({
    required RepositoryObjectMetadata metadata,
    required String token,
  });

  RepositoryCredentialPlacement get credentialPlacement =>
      RepositoryCredentialPlacement.authorizationHeader;

  String get readAuthorizationScheme =>
      credentialPlacement == RepositoryCredentialPlacement.formBody
      ? 'token'
      : 'Bearer';

  int get providerPageSize => 100;

  Future<RepositoryReleaseMetadata>? _releaseCreation;
  RepositoryReleaseMetadata? _cachedRelease;

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

  /// Repository verification deliberately probes the repository itself. An
  /// empty repository has no Release yet, but it is still a valid target and
  /// must pass the settings-page connectivity check.
  Future<void> verifyRepository() async {
    final response = await httpTransport.get(
      repositoryProbeUri(),
      headers: await _requestHeaders(raw: false),
    );
    if (response.statusCode != 200) {
      await httpTransport.throwForStatus(response, RemoteFailureContext.read);
    }
    await httpTransport.discard(response.stream);
  }

  @override
  Future<SourceRead> get(SourcePath path, {RevisionToken? ifNoneMatch}) async {
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
      metadata.downloadUri,
      headers: await _requestHeaders(raw: true),
    );
    if (response.statusCode != 200) {
      await httpTransport.throwForStatus(response, RemoteFailureContext.read);
    }
    final responseSize = _responseSize(response);
    if (metadata.size < 0 ||
        capabilities.maxObjectBytes != null &&
            metadata.size > capabilities.maxObjectBytes!) {
      await httpTransport.discard(response.stream);
      throw const SboxException(
        SboxErrorCode.sourceLimit,
        'Remote object exceeds the source limit',
      );
    }
    if (responseSize != null && responseSize == metadata.size) {
      return SourceRead(
        body: _verifiedStream(response.stream, metadata.size),
        length: metadata.size,
        revision: revision,
      );
    }

    // Download redirects and Gitee attachment responses may omit a reliable
    // Content-Length. Buffer only this bounded fallback so the DataSource
    // contract still exposes an exact length and catches truncated downloads.
    final bytes = await httpTransport.readBounded(
      response.stream,
      maximumBytes: capabilities.maxObjectBytes ?? 100 * 1024 * 1024,
    );
    if (bytes.length != metadata.size) {
      throw const SboxException(
        SboxErrorCode.remoteChanged,
        'Remote asset length changed',
      );
    }
    return SourceRead(
      body: Stream<List<int>>.value(bytes),
      length: bytes.length,
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
      throw const SboxException(
        SboxErrorCode.invalidHeader,
        'Invalid remote object range',
      );
    }
    final requestedLength = endExclusive - start;
    final metadata = objectInfo?.downloadUri == null
        ? await _readMetadata(path)
        : RepositoryObjectMetadata(
            revision: _revisionString(objectInfo!.revision),
            size: objectInfo.length,
            downloadUri: objectInfo.downloadUri!,
          );
    final knownSize = metadata.size > 0 ? metadata.size : null;
    if (knownSize != null && endExclusive > knownSize) {
      throw const SboxException(
        SboxErrorCode.truncated,
        'Requested range exceeds remote asset length',
      );
    }
    final revision = RevisionToken(ascii.encode(metadata.revision));
    if (requestedLength == 0) {
      return SourceRead(
        body: const Stream<List<int>>.empty(),
        length: 0,
        revision: revision,
      );
    }

    final response = await httpTransport.get(
      metadata.downloadUri,
      headers: <String, String>{
        ...await _requestHeaders(raw: true),
        'Range': 'bytes=$start-${endExclusive - 1}',
      },
    );
    if (response.statusCode != 200 && response.statusCode != 206) {
      await httpTransport.throwForStatus(response, RemoteFailureContext.read);
    }
    final body = response.statusCode == 200
        ? _sliceStream(response.stream, start: start, length: requestedLength)
        : _verifiedStream(response.stream, requestedLength);
    return SourceRead(body: body, length: requestedLength, revision: revision);
  }

  @override
  Future<SourceListPage> listObjects({
    String? cursor,
    int pageSize = 1000,
    bool? resolveObjectSizes,
  }) async {
    if (pageSize < 1 || pageSize > 1000) {
      throw const SboxException(
        SboxErrorCode.sourceLimit,
        'Invalid remote listing page size',
      );
    }

    // A configured writable source creates its dedicated release lazily even
    // when the first operation is a listing. Read-only public sources simply
    // observe an empty store until a release exists.
    final release = capabilities.canWrite
        ? await _ensureLatestRelease()
        : await _findLatestRelease();
    if (release == null) {
      return const SourceListPage(
        objects: <SourceObjectInfo>[],
        nextCursor: null,
      );
    }

    final page = _pageNumber(cursor);
    final perPage = pageSize < providerPageSize ? pageSize : providerPageSize;
    final response = await httpTransport.get(
      assetListUri(releaseId: release.id, page: page, perPage: perPage),
      headers: await _requestHeaders(raw: false),
    );
    if (response.statusCode != 200) {
      await httpTransport.throwForStatus(response, RemoteFailureContext.read);
    }
    final values = await _readAssetValues(response);
    final objects = <SourceObjectInfo>[];
    for (final value in values) {
      final metadata = _parseAsset(value, release.id);
      if (metadata == null) continue;
      final path = _pathForAssetName(metadata.assetName);
      if (path == null) continue;
      objects.add(
        SourceObjectInfo(
          path: path,
          length: metadata.size,
          revision: RevisionToken(ascii.encode(metadata.revision)),
          downloadUri: metadata.downloadUri,
        ),
      );
    }
    objects.sort((left, right) => left.path.value.compareTo(right.path.value));
    final nextCursor = _hasNextPage(response, values, perPage)
        ? (page + 1).toString()
        : null;
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
      try {
        final existing = await _readMetadata(path);
        final remote = await get(path);
        if (remote.length != length) {
          await httpTransport.discard(remote.body);
          throw const SboxException(
            SboxErrorCode.immutableConflict,
            'A remote asset already exists with different content',
          );
        }
        final remoteBytes = await httpTransport.readBounded(
          remote.body,
          maximumBytes: length,
        );
        final remoteHash = sha256Bytes(remoteBytes);
        try {
          if (constantTimeBytesEqual(remoteHash, sha256)) {
            return RevisionToken(ascii.encode(existing.revision));
          }
        } finally {
          remoteHash.fillRange(0, remoteHash.length, 0);
        }
        throw const SboxException(
          SboxErrorCode.immutableConflict,
          'A remote asset already exists with different content',
        );
      } on SboxException catch (error) {
        if (error.code != SboxErrorCode.sourceNotFound) rethrow;
      }

      final release = await _ensureLatestRelease();
      final assetName = _assetNameForPath(path);
      try {
        final response = await _withCredential((token) async {
          final request = await uploadAssetRequest(
            release: release,
            token: token,
            assetName: assetName,
            bytes: bytes,
          );
          return httpTransport.send(request);
        });
        if (response.statusCode != 200 && response.statusCode != 201) {
          if (response.statusCode == 422) {
            await httpTransport.discard(response.stream);
            throw const SboxException(
              SboxErrorCode.immutableConflict,
              'A release asset with this name already exists',
              httpStatus: 422,
            );
          }
          await httpTransport.throwForStatus(
            response,
            RemoteFailureContext.immutableCreate,
          );
        }
        final value = await httpTransport.readJsonObject(response);
        final uploaded = _parseAsset(value, release.id);
        if (uploaded == null || uploaded.assetName != assetName) {
          throw const SboxException(
            SboxErrorCode.sourceNetwork,
            'Release upload returned invalid asset metadata',
          );
        }
        return RevisionToken(ascii.encode(uploaded.revision));
      } on SboxException catch (error) {
        // Upload requests can commit the asset before the client receives the
        // response. Confirm the immutable bytes before surfacing a retryable
        // failure or duplicate-name response.
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
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  @override
  Future<void> deleteIfMatch(SourcePath path, RevisionToken expected) async {
    _requireDelete();
    final metadata = await _readMetadata(path);
    final actual = RevisionToken(ascii.encode(metadata.revision));
    if (!actual.matches(expected)) {
      throw const SboxException(
        SboxErrorCode.shardConflict,
        'The remote asset revision no longer matches',
      );
    }
    await _withCredential((token) async {
      final response = await httpTransport.send(
        deleteAssetRequest(metadata: metadata, token: token),
      );
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
    final release = await _findLatestRelease();
    if (release == null) {
      throw const SboxException(
        SboxErrorCode.sourceNotFound,
        'The SafeBox latest release does not exist',
      );
    }
    final metadata = await _findAsset(release, path);
    if (metadata == null) {
      throw const SboxException(
        SboxErrorCode.sourceNotFound,
        'The remote asset does not exist',
      );
    }
    return metadata;
  }

  Future<RepositoryObjectMetadata?> _findAsset(
    RepositoryReleaseMetadata release,
    SourcePath path,
  ) async {
    final expectedAssetName = _assetNameForPath(path);
    for (var page = 1; page <= 1000; page++) {
      final values = await _fetchAssetPage(
        release,
        page: page,
        perPage: providerPageSize,
      );
      for (final value in values) {
        final metadata = _parseAsset(value, release.id);
        if (metadata != null && metadata.assetName == expectedAssetName) {
          return metadata;
        }
      }
      if (values.length < providerPageSize) return null;
    }
    throw const SboxException(
      SboxErrorCode.sourceLimit,
      'The release contains too many assets',
    );
  }

  Future<List<Object?>> _fetchAssetPage(
    RepositoryReleaseMetadata release, {
    required int page,
    required int perPage,
  }) async {
    final response = await httpTransport.get(
      assetListUri(releaseId: release.id, page: page, perPage: perPage),
      headers: await _requestHeaders(raw: false),
    );
    if (response.statusCode != 200) {
      await httpTransport.throwForStatus(response, RemoteFailureContext.read);
    }
    return _readAssetValues(response);
  }

  Future<List<Object?>> _readAssetValues(http.StreamedResponse response) async {
    final value = await httpTransport.readJsonValue(response);
    if (value is List) return value.cast<Object?>();
    if (value is Map<String, Object?>) {
      final assets = value['assets'];
      if (assets is List) return assets.cast<Object?>();
    }
    throw const SboxException(
      SboxErrorCode.sourceNetwork,
      'The release asset response is not a JSON list',
    );
  }

  static bool _hasNextPage(
    http.StreamedResponse response,
    List<Object?> values,
    int perPage,
  ) {
    final link = response.headers['link'];
    if (link != null) {
      return RegExp(
        r'''rel\s*=\s*["']next["']''',
        caseSensitive: false,
      ).hasMatch(link);
    }
    return values.length >= perPage;
  }

  RepositoryObjectMetadata? _parseAsset(Object? raw, int releaseId) {
    if (raw is! Map<String, Object?>) return null;
    final assetId = _integer(raw['id']);
    final assetName = raw['name'];
    final rawSize = raw['size'];
    if (assetId == null || assetId <= 0 || assetName is! String) return null;
    final size = rawSize == null ? 0 : _integer(rawSize);
    if (size == null || size < 0) return null;
    final path = _pathForAssetName(assetName);
    if (path == null || !path.value.endsWith('.sbox')) return null;
    return RepositoryObjectMetadata(
      revision: _assetRevision(releaseId, assetId),
      size: size,
      downloadUri: assetDownloadUri(releaseId: releaseId, assetId: assetId),
      releaseId: releaseId,
      assetId: assetId,
      assetName: assetName,
    );
  }

  String _assetRevision(int releaseId, int assetId) =>
      'release-asset:$releaseId:$assetId';

  String _assetNameForPath(SourcePath path) {
    if (config.pathPrefix.isEmpty) return path.value;
    final namespace = base64UrlEncode(utf8.encode(config.pathPrefix));
    return 'safebox-$namespace--${path.value}';
  }

  SourcePath? _pathForAssetName(String assetName) {
    final expectedPrefix = config.pathPrefix.isEmpty
        ? null
        : 'safebox-${base64UrlEncode(utf8.encode(config.pathPrefix))}--';
    final value = expectedPrefix == null
        ? assetName
        : assetName.startsWith(expectedPrefix)
        ? assetName.substring(expectedPrefix.length)
        : null;
    if (value == null) return null;
    try {
      return SourcePath(value);
    } on Object {
      return null;
    }
  }

  Future<RepositoryReleaseMetadata?> _findLatestRelease({
    bool refresh = false,
  }) async {
    if (!refresh && _cachedRelease != null) return _cachedRelease;
    final response = await httpTransport.get(
      latestReleaseUri(),
      headers: await _requestHeaders(raw: false),
    );
    if (response.statusCode == 404) {
      await httpTransport.discard(response.stream);
      return null;
    }
    if (response.statusCode != 200) {
      await httpTransport.throwForStatus(response, RemoteFailureContext.read);
    }
    final value = await httpTransport.readJsonValue(response);
    if (value == null) return null;
    if (value is! Map<String, Object?>) {
      throw const SboxException(
        SboxErrorCode.sourceNetwork,
        'The latest release response is invalid',
      );
    }
    final release = _parseRelease(value);
    _cachedRelease = release;
    return release;
  }

  RepositoryReleaseMetadata _parseRelease(Map<String, Object?> value) {
    final id = _integer(value['id']);
    final tagName = value['tag_name'];
    if (id == null || id <= 0 || tagName is! String || tagName.isEmpty) {
      throw const SboxException(
        SboxErrorCode.sourceNetwork,
        'The latest release response is invalid',
      );
    }
    return RepositoryReleaseMetadata(id: id, tagName: tagName);
  }

  Future<RepositoryReleaseMetadata> _ensureLatestRelease() async {
    final existing = await _findLatestRelease();
    if (existing != null) return existing;
    _requireWrite();
    final pending = _releaseCreation;
    if (pending != null) return pending;
    final creation = _createLatestRelease();
    _releaseCreation = creation;
    try {
      return await creation;
    } finally {
      if (identical(_releaseCreation, creation)) _releaseCreation = null;
    }
  }

  Future<RepositoryReleaseMetadata> _createLatestRelease() async {
    final response = await _withCredential((token) async {
      final request = await createLatestReleaseRequest(token);
      return httpTransport.send(request);
    });
    if (response.statusCode != 200 && response.statusCode != 201) {
      if (response.statusCode == 422) {
        await httpTransport.discard(response.stream);
        final raced = await _findLatestRelease(refresh: true);
        if (raced != null) return raced;
        throw const SboxException(
          SboxErrorCode.sourceNetwork,
          'Unable to create the SafeBox latest release',
          httpStatus: 422,
        );
      }
      await httpTransport.throwForStatus(response, RemoteFailureContext.read);
    }
    final release = _parseRelease(await httpTransport.readJsonObject(response));
    _cachedRelease = release;
    return release;
  }

  Future<RevisionToken?> _existingRevisionIfSame(
    SourcePath path, {
    required int length,
    required Uint8List expectedHash,
  }) async {
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
        final remoteHash = sha256Bytes(remoteBytes);
        try {
          if (constantTimeBytesEqual(remoteHash, expectedHash)) {
            return remote.revision;
          }
        } finally {
          remoteHash.fillRange(0, remoteHash.length, 0);
        }
        return null;
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

  Future<Map<String, String>> authenticatedRequestHeaders({
    required bool raw,
  }) => _requestHeaders(raw: raw);

  Future<Map<String, String>> _requestHeaders({required bool raw}) async {
    final headers = publicHeaders(raw: raw);
    final store = credentialStore;
    final id = credentialId;
    if (store == null || id == null) return headers;
    final token = await store.getAccessToken(id);
    if (token == null) return headers;
    try {
      return await token.useAuthorizationValue(
        readAuthorizationScheme,
        (authorization) => <String, String>{
          ...headers,
          'Authorization': authorization,
        },
      );
    } finally {
      token.dispose();
    }
  }

  Future<T> _withCredential<T>(Future<T> Function(String value) action) async {
    final store = credentialStore;
    final id = credentialId;
    if (store == null || id == null) {
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        'Write credentials are not configured',
      );
    }
    final token = await store.getAccessToken(id);
    if (token == null) {
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        'Write credentials are missing',
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
        'Write credentials are not configured',
      );
    }
  }

  void _requireDelete() {
    if (!capabilities.canDelete) {
      throw const SboxException(
        SboxErrorCode.sourceAuthentication,
        'Delete credentials are not configured',
      );
    }
  }

  static int _pageNumber(String? cursor) {
    final page = int.tryParse(cursor ?? '1') ?? 1;
    return page < 1 ? 1 : page;
  }

  static int? _integer(Object? value) {
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.truncate()) {
      return value.toInt();
    }
    return null;
  }

  static Future<Uint8List> _readBody(
    Stream<List<int>> body,
    int length,
    Uint8List expectedHash,
  ) async {
    // Do not retain caller-owned stream chunks. putNew clears its private
    // upload buffer after the request completes.
    final builder = BytesBuilder(copy: true);
    final accumulator = HashDigestSink();
    final sink = crypto.sha256.startChunkedConversion(accumulator);
    var count = 0;
    await for (final chunk in body) {
      count += chunk.length;
      if (count > length) {
        throw const SboxException(
          SboxErrorCode.integrity,
          'Upload body exceeds the declared length',
        );
      }
      builder.add(chunk);
      sink.add(chunk);
    }
    sink.close();
    if (count != length ||
        !constantTimeBytesEqual(accumulator.value.bytes, expectedHash)) {
      throw const SboxException(
        SboxErrorCode.integrity,
        'Upload body digest does not match',
      );
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
        throw const SboxException(
          SboxErrorCode.remoteChanged,
          'Remote asset is longer than declared',
        );
      }
      yield chunk;
    }
    if (count != expectedLength) {
      throw const SboxException(
        SboxErrorCode.remoteChanged,
        'Remote asset is shorter than declared',
      );
    }
  }

  static Stream<List<int>> _sliceStream(
    Stream<List<int>> source, {
    required int start,
    required int length,
  }) async* {
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
    throw const SboxException(
      SboxErrorCode.remoteChanged,
      'Remote asset is shorter than the requested range',
    );
  }

  static String _revisionString(RevisionToken token) {
    try {
      final value = ascii.decode(token.bytes, allowInvalid: false);
      if (value.isEmpty || value.length > 4096) throw const FormatException();
      return value;
    } on FormatException {
      throw const SboxException(
        SboxErrorCode.shardConflict,
        'Invalid remote asset revision',
      );
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
