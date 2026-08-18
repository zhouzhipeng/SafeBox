import 'dart:typed_data';

/// Wire constants for the only container format supported by production code.
abstract final class SboxProtocol {
  static final Uint8List magic = Uint8List.fromList(<int>[
    0x53,
    0x42,
    0x4f,
    0x58,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
  ]);

  static const int versionMajor = 3;
  static const int versionMinor = 0;
  static const int commonHeaderLength = 128;
  static const int rootHeaderLength = 16992;
  static const int wrappedBundleDekOffset = commonHeaderLength;
  static const int metadataDescriptionOffset = 512;
  static const int metadataDescriptionLength = 64;
  static const int metadataAadHeaderLength = 576;
  static const int metadataCiphertextOffset = 576;
  static const int metadataBlockLength = 16400;
  static const int metadataCiphertextLength = metadataBlockLength;
  static const int metadataTagOffset = 16976;
  static const int metadataSaltLength = 32;
  static const int metadataNonceLength = 12;
  static const int metadataAadPrefixLength = 16;
  static const int metadataFormatId = 1;
  static const int metadataKdfAlgorithm = 1;
  static const int metadataAeadAlgorithm = 1;
  static const int metadataFlags = 0;
  static const int keyProfileId = 1;
  static const int rootKeyWrapAlgorithm = 1;
  static const int continuationKeyWrapAlgorithm = 0;
  static const int payloadAlgorithm = 1;
  static const int shardKdfAlgorithm = 1;
  static const int chunkSize = 4 * 1024 * 1024;
  static const int rsaBits = 3072;
  static const int rsaPrimeBits = 1536;
  static const int rsaPublicExponent = 65537;
  static const int wrappedBundleDekLength = 384;
  static const int bundleIdLength = 16;
  static const int bundleDekLength = 32;
  static const int recipientKeyIdLength = 32;
  static const int noncePrefixLength = 4;
  static const int gcmNonceLength = 12;
  static const int gcmTagLength = 16;
  static const int recordHeaderLength = 13;
  static const int finalPlaintextLength = 48;
  static const int maxShardCount = 10000;
  static const int maxShardPlaintextSize = 512 * 1024 * 1024;
  static const int minNominalShardPlaintextSize = 1 * 1024 * 1024;
  static const int maxNominalShardPlaintextSize = 512 * 1024 * 1024;
  static const int defaultNominalShardPlaintextSize = 16 * 1024 * 1024;
  static const int maxManifestBytes = 16 * 1024;
  static const int maxOriginalNameBytes = 1024;
  static const int maxTitleBytes = 256;
  static const int maxDescriptionBytes = 4096;
  static const int maxTagCount = 32;
  static const int maxTagBytes = 64;
  static const int maxCandidateObjects = 100000;
  static const int defaultMaxParallelTransfers = 4;
}

enum SboxContentKind {
  file('file'),
  text('text');

  const SboxContentKind(this.wireName);

  final String wireName;

  static SboxContentKind fromWireName(String value) => values.firstWhere(
    (kind) => kind.wireName == value,
    orElse: () => throw ArgumentError.value(value, 'value'),
  );
}

enum BundleRecordType {
  data(0x02),
  finalRecord(0xff);

  const BundleRecordType(this.wireValue);

  final int wireValue;

  static BundleRecordType fromWireValue(int value) => values.firstWhere(
    (type) => type.wireValue == value,
    orElse: () => throw ArgumentError.value(value, 'value'),
  );
}
