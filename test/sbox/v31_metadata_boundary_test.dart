import 'dart:typed_data';
import 'dart:math' as math;

import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/errors.dart';
import 'package:safebox/sbox/format/bundle_header.dart';
import 'package:safebox/sbox/format/bundle_manifest.dart';
import 'package:safebox/sbox/format/metadata_block.dart';
import 'package:safebox/sbox/format/sbox_version.dart';
import 'package:test/test.dart';

void main() {
  test('value-equivalent supported versions select their fixed formats', () {
    expect(const SboxVersion(3, 0).metadataFormatId, 1);
    expect(const SboxVersion(3, 1).metadataFormatId, 2);
  });

  test('v3.1 Metadata Format 2 round-trips without a Preview', () {
    final manifest = _manifest();
    final bytes = manifest.encode();
    final block = MetadataBlockCodec.packV2(bytes);
    final decoded = MetadataBlockCodec.unpack(
      block,
      formatId: SboxProtocol.metadataFormatIdV31,
    );

    expect(decoded.manifest.toJson(), manifest.toJson());
    expect(decoded.preview, isNull);
    expect(
      MetadataBlockCodec.previewCapacity(bytes.length),
      math.min(
        SboxProtocol.maxPreviewBytes,
        SboxProtocol.metadataBlockLength -
            12 -
            SboxProtocol.previewDescriptorLength -
            bytes.length,
      ),
    );
  });

  test('non-zero v2 tail must begin with a complete Preview descriptor', () {
    final block = MetadataBlockCodec.packV2(_manifest().encode());
    block[12 + _manifest().encode().length] = 1;
    expect(
      () => MetadataBlockCodec.unpackV2(block),
      throwsA(
        isA<SboxException>().having(
          (error) => error.code,
          'code',
          SboxErrorCode.invalidManifest,
        ),
      ),
    );
  });

  test('version and Metadata Format 2 are an exact matrix', () {
    final v31 = _root(version: SboxVersion.v31);
    final v31Bytes = v31.encode();
    v31Bytes[516] = 1;
    expect(
      () => BundleHeader.parse(v31Bytes),
      throwsA(
        isA<SboxException>().having(
          (error) => error.code,
          'code',
          SboxErrorCode.invalidHeader,
        ),
      ),
    );

    final v30 = _root(version: SboxVersion.v30);
    final v30Bytes = v30.encode();
    v30Bytes[516] = 2;
    expect(
      () => BundleHeader.parse(v30Bytes),
      throwsA(
        isA<SboxException>().having(
          (error) => error.code,
          'code',
          SboxErrorCode.invalidHeader,
        ),
      ),
    );
  });
}

BundleManifest _manifest() => BundleManifest(
  bundleId: '00' * 16,
  recipientKeyId: '11' * 32,
  contentKind: SboxContentKind.file,
  originalName: 'empty.bin',
  mediaType: 'application/octet-stream',
  title: 'empty.bin',
  description: '',
  tags: const <String>[],
  createdAt: '2026-08-18T00:00:00Z',
  logicalPlaintextSize: BigInt.zero,
  logicalPlaintextSha256: Uint8List(32),
  nominalShardPlaintextSize: SboxProtocol.defaultNominalShardPlaintextSize,
  shardCount: 1,
);

BundleHeader _root({required SboxVersion version}) => BundleHeader.root(
  version: version,
  bundleId: Uint8List(16),
  shardCount: 1,
  shardPlaintextSize: BigInt.zero,
  recipientKeyId: Uint8List.fromList(List<int>.filled(32, 0x11)),
  noncePrefix: Uint8List.fromList(<int>[1, 2, 3, 4]),
  wrappedBundleDek: Uint8List.fromList(List<int>.filled(384, 0x55)),
  metadataSalt: Uint8List(32),
  metadataNonce: Uint8List(12),
  metadataCiphertext: Uint8List(16400),
  metadataTag: Uint8List(16),
);
