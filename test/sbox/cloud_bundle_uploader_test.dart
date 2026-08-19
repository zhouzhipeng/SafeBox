import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/engine/bundle_encryptor.dart';
import 'package:safebox/sbox/source/cloud_bundle_uploader.dart';
import 'package:safebox/sbox/source/cloud_backup_config.dart';
import 'package:safebox/sbox/source/credential.dart';
import 'package:safebox/sbox/errors.dart';
import 'package:safebox/sbox/identity/bip39_identity.dart';
import 'package:test/test.dart';

void main() {
  test('upload progress reserves 100 percent for the terminal event', () {
    const sources = <String, CloudBundleSourceProgress>{
      'GitHub': CloudBundleSourceProgress(
        sourceName: 'GitHub',
        completedShards: 22,
        totalShards: 22,
      ),
      'Gitee': CloudBundleSourceProgress(
        sourceName: 'Gitee',
        completedShards: 22,
        totalShards: 22,
      ),
    };

    const uploading = CloudBundleUploadProgress(
      stage: CloudBundleUploadStage.uploading,
      sources: sources,
    );
    expect(uploading.isComplete, isFalse);
    expect(uploading.fraction, lessThan(1));
    expect(uploading.overallLabel, '44/44（正在核对）');

    const completed = CloudBundleUploadProgress(
      stage: CloudBundleUploadStage.completed,
      sources: sources,
    );
    expect(completed.isComplete, isTrue);
    expect(completed.fraction, 1);
    expect(completed.overallLabel, '44/44 (100.0%)');
  });

  test('upload progress keeps splitting and encryption labels stable', () {
    const splitting = CloudBundleUploadProgress(
      stage: CloudBundleUploadStage.splitting,
      sources: <String, CloudBundleSourceProgress>{},
      processedBytes: 1,
      totalBytes: 2,
    );
    const encrypting = CloudBundleUploadProgress(
      stage: CloudBundleUploadStage.encrypting,
      sources: <String, CloudBundleSourceProgress>{},
      processedBytes: 1,
      totalBytes: 2,
    );

    expect(splitting.overallLabel, '切分&加密文件 50.0%');
    expect(splitting.detailLabel, '正在切分&加密文件 · 正在切分&加密文件 1 B / 2 B');
    expect(encrypting.overallLabel, splitting.overallLabel);
    expect(encrypting.detailLabel, splitting.detailLabel);
  });

  test('upload cancellation exposes a stable cancelled error', () {
    final cancellation = CloudBundleUploadCancellation();
    var cleanupCalls = 0;
    final unregister = cancellation.registerOnCancel(() => cleanupCalls++);

    expect(cancellation.isCancelled, isFalse);
    cancellation.cancel();
    expect(cancellation.isCancelled, isTrue);
    expect(cleanupCalls, 1);
    unregister();
    cancellation.cancel();
    expect(cleanupCalls, 1);
    expect(
      cancellation.throwIfCancelled,
      throwsA(
        isA<SboxException>().having(
          (error) => error.code,
          'code',
          SboxErrorCode.cancelled,
        ),
      ),
    );
  });

  test(
    'upload publishes continuation assets concurrently and root last',
    () async {
      const mnemonic =
          'abandon abandon abandon abandon abandon abandon abandon abandon '
          'abandon abandon abandon about';
      final temporary = await Directory.systemTemp.createTemp('sbox-upload-');
      final identity = await SboxIdentityDeriver().deriveIdentity(mnemonic);
      final client = _ConcurrentGitHubReleaseClient();
      try {
        final credentialId = SourceCredentialId('github-test-token');
        final configuration = CloudBackupConfiguration(
          backupDirectory: temporary.path,
          github: CloudRepositoryEndpoint(
            owner: 'owner',
            repository: 'repo',
            credentialId: credentialId,
          ),
          gitee: CloudRepositoryEndpoint(
            owner: 'owner',
            repository: 'repo',
            credentialId: SourceCredentialId('gitee-test-token'),
            enabled: false,
          ),
        );
        final input = Uint8List.fromList(
          List<int>.generate(4 * 1024 * 1024, (index) => index & 0xff),
        );
        final uploader = CloudBundleUploader(
          credentialStore: _UploaderCredentialStore(),
          client: client,
          maxShardUploadRetries: 1,
        );

        final result = await uploader.upload(
          input: MemoryBundleInput(input),
          declaredLength: input.length,
          options: BundleEncryptionOptions(
            recipient: identity.publicIdentity,
            contentKind: SboxContentKind.file,
            originalName: 'parallel.bin',
            mediaType: 'application/octet-stream',
            targetNominalShardPlaintextSize: 1024 * 1024,
          ),
          configuration: configuration,
        );

        expect(result.objectNames.length, greaterThan(2));
        expect(client.maxUploadConcurrency, greaterThan(1));
        expect(client.uploadedNames.last, result.rootObjectName);
        expect(client.assets, hasLength(result.objectNames.length));
      } finally {
        identity.disposeControlledSecrets();
        if (await temporary.exists()) await temporary.delete(recursive: true);
      }
    },
  );
}

final class _UploaderCredentialStore implements CredentialStore {
  @override
  Future<void> deleteAccessToken(SourceCredentialId id) async {}

  @override
  Future<SourceAccessToken?> getAccessToken(SourceCredentialId id) async =>
      SourceAccessToken.fromUtf8('test-token');

  @override
  Future<void> putAccessToken(
    SourceCredentialId id,
    SourceAccessToken token,
  ) async {}
}

final class _ConcurrentAssetRecord {
  _ConcurrentAssetRecord(this.id, this.name, this.bytes);

  final int id;
  final String name;
  final Uint8List bytes;
}

final class _ConcurrentGitHubReleaseClient extends http.BaseClient {
  final List<_ConcurrentAssetRecord> assets = <_ConcurrentAssetRecord>[];
  final List<String> uploadedNames = <String>[];
  var releaseExists = false;
  var activeUploads = 0;
  var maxUploadConcurrency = 0;
  var nextAssetId = 1;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path.endsWith('/releases/tags/latest')) {
      if (!releaseExists) return _response(request, 404, const <int>[]);
      return _json(request, _releaseJson());
    }
    if (request.method == 'POST' && path.endsWith('/releases')) {
      releaseExists = true;
      return _json(request, _releaseJson(), status: 201);
    }
    if (request.method == 'GET' && path.endsWith('/assets')) {
      final page = int.parse(request.url.queryParameters['page'] ?? '1');
      final perPage = int.parse(
        request.url.queryParameters['per_page'] ?? '100',
      );
      final start = (page - 1) * perPage;
      final values = start >= assets.length
          ? <Object?>[]
          : assets.skip(start).take(perPage).map(_assetJson).toList();
      return _json(request, values);
    }
    if (request.method == 'POST' && request.url.host == 'uploads.github.com') {
      final name = request.url.queryParameters['name']!;
      activeUploads++;
      if (activeUploads > maxUploadConcurrency) {
        maxUploadConcurrency = activeUploads;
      }
      uploadedNames.add(name);
      try {
        await Future<void>.delayed(const Duration(milliseconds: 15));
        final upload = request as http.Request;
        final record = _ConcurrentAssetRecord(
          nextAssetId++,
          name,
          Uint8List.fromList(upload.bodyBytes),
        );
        assets.add(record);
        return _json(request, _assetJson(record), status: 201);
      } finally {
        activeUploads--;
      }
    }
    return _response(request, 404, const <int>[]);
  }

  Map<String, Object?> _releaseJson() => <String, Object?>{
    'id': 7,
    'tag_name': 'latest',
    'name': 'latest',
  };

  Map<String, Object?> _assetJson(_ConcurrentAssetRecord asset) =>
      <String, Object?>{
        'id': asset.id,
        'name': asset.name,
        'size': asset.bytes.length,
        'state': 'uploaded',
      };

  http.StreamedResponse _json(
    http.BaseRequest request,
    Object value, {
    int status = 200,
  }) => http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(jsonEncode(value))),
    status,
    headers: const <String, String>{'content-type': 'application/json'},
    request: request,
  );

  http.StreamedResponse _response(
    http.BaseRequest request,
    int status,
    List<int> bytes,
  ) => http.StreamedResponse(
    Stream<List<int>>.value(bytes),
    status,
    request: request,
  );
}
