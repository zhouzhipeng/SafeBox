import 'dart:typed_data';

/// Wire-level constants for the immutable SBOX v1 profile.
abstract final class SboxV1 {
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

  static const int versionMajor = 1;
  static const int versionMinor = 0;
  static const int headerLength = 468;
  static const int keyProfileId = 1;
  static const int keyWrapAlgorithm = 1;
  static const int payloadAlgorithm = 1;
  static const int rsaBits = 3072;
  static const int rsaPrimeBits = 1536;
  static const int rsaPublicExponent = 65537;
  static const int wrappedDekLength = 384;
  static const int dekLength = 32;
  static const int fileIdLength = 16;
  static const int recipientKeyIdLength = 32;
  static const int noncePrefixLength = 4;
  static const int gcmNonceLength = 12;
  static const int gcmTagLength = 16;
  static const int recordHeaderLength = 13;
  static const int internalChunkSize = 4 * 1024 * 1024;
  static const int defaultPartPlaintextSize = 16 * 1024 * 1024;
  static const int minPartPlaintextSize = 1 * 1024 * 1024;
  static const int maxPartPlaintextSize = 512 * 1024 * 1024;
  static const int maxCatalogCiphertextSize = 20 * 1024 * 1024;

  static const String rsaHkdfSalt = 'SBOX-v1/BIP39-to-RSA3072';
  static const String rsaHkdfInfo = 'HMAC-DRBG-SHA256/instantiate';
  static const String rsaPersonalization = 'SBOX-v1/RSA-3072';
  static const String catalogHkdfSalt = 'SBOX-v1/BIP39-to-CatalogSign';
  static const String catalogHkdfInfo = 'Ed25519/seed';
  static const String oaepLabelPrefix = 'SBOX-v1-DEK';
  static const String recordAadPrefix = 'SBOX-v1-record';
  static const String catalogSchema = 'SBOX-CATALOG-1';
  static const String catalogSignatureContext = 'SBOX-v1-catalog-signature';
}

enum SboxContentKind {
  file(1),
  text(2),
  catalog(3),
  multipartPart(4);

  const SboxContentKind(this.wireValue);

  final int wireValue;

  static SboxContentKind fromWireValue(int value) {
    return values.firstWhere(
      (kind) => kind.wireValue == value,
      orElse: () => throw ArgumentError.value(value, 'value'),
    );
  }
}

enum SboxRecordType {
  metadata(1),
  data(2),
  finalRecord(0xff);

  const SboxRecordType(this.wireValue);

  final int wireValue;

  static SboxRecordType fromWireValue(int value) {
    return values.firstWhere(
      (type) => type.wireValue == value,
      orElse: () => throw ArgumentError.value(value, 'value'),
    );
  }
}
