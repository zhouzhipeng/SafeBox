import 'dart:typed_data';

import '../bytes.dart';
import '../constants.dart';
import '../errors.dart';
import 'sbox_version.dart';

/// The v3 public header. A parsed header retains the exact bytes received on
/// the wire so Metadata AAD and the root record binding never depend on a
/// reconstructed representation.
final class BundleHeader {
  BundleHeader._({
    required this.isRoot,
    required this.version,
    required List<int> bundleId,
    required this.shardIndex,
    required this.shardCount,
    required this.shardPlaintextSize,
    required List<int> recipientKeyId,
    required List<int> noncePrefix,
    required List<int> wrappedBundleDek,
    required this.metadataFormatId,
    required this.metadataKdfAlg,
    required this.metadataAeadAlg,
    required this.metadataFlags,
    required this.metadataPlaintextLength,
    required this.metadataCiphertextLength,
    required List<int> metadataSalt,
    required List<int> metadataNonce,
    required List<int> metadataCiphertext,
    required List<int> metadataTag,
    List<int>? rawBytes,
  }) : bundleId = Uint8List.fromList(bundleId),
       recipientKeyId = Uint8List.fromList(recipientKeyId),
       noncePrefix = Uint8List.fromList(noncePrefix),
       wrappedBundleDek = Uint8List.fromList(wrappedBundleDek),
       metadataSalt = Uint8List.fromList(metadataSalt),
       metadataNonce = Uint8List.fromList(metadataNonce),
       metadataCiphertext = Uint8List.fromList(metadataCiphertext),
       metadataTag = Uint8List.fromList(metadataTag),
       _rawBytes = rawBytes == null ? null : Uint8List.fromList(rawBytes) {
    _validateFields();
  }

  factory BundleHeader.root({
    required List<int> bundleId,
    required int shardCount,
    required BigInt shardPlaintextSize,
    required List<int> recipientKeyId,
    required List<int> noncePrefix,
    required List<int> wrappedBundleDek,
    required List<int> metadataSalt,
    required List<int> metadataNonce,
    required List<int> metadataCiphertext,
    required List<int> metadataTag,
    SboxVersion version = SboxVersion.v30,
    int? metadataFormatId,
    int metadataKdfAlg = SboxProtocol.metadataKdfAlgorithm,
    int metadataAeadAlg = SboxProtocol.metadataAeadAlgorithm,
    int metadataFlags = SboxProtocol.metadataFlags,
    int metadataPlaintextLength = SboxProtocol.metadataBlockLength,
    int metadataCiphertextLength = SboxProtocol.metadataCiphertextLength,
  }) => BundleHeader._(
    isRoot: true,
    version: version,
    bundleId: bundleId,
    shardIndex: 0,
    shardCount: shardCount,
    shardPlaintextSize: shardPlaintextSize,
    recipientKeyId: recipientKeyId,
    noncePrefix: noncePrefix,
    wrappedBundleDek: wrappedBundleDek,
    metadataFormatId: metadataFormatId ?? version.metadataFormatId,
    metadataKdfAlg: metadataKdfAlg,
    metadataAeadAlg: metadataAeadAlg,
    metadataFlags: metadataFlags,
    metadataPlaintextLength: metadataPlaintextLength,
    metadataCiphertextLength: metadataCiphertextLength,
    metadataSalt: metadataSalt,
    metadataNonce: metadataNonce,
    metadataCiphertext: metadataCiphertext,
    metadataTag: metadataTag,
  );

  factory BundleHeader.continuation({
    required List<int> bundleId,
    required int shardIndex,
    required int shardCount,
    required BigInt shardPlaintextSize,
    required List<int> recipientKeyId,
    required List<int> noncePrefix,
    SboxVersion version = SboxVersion.v30,
  }) => BundleHeader._(
    isRoot: false,
    version: version,
    bundleId: bundleId,
    shardIndex: shardIndex,
    shardCount: shardCount,
    shardPlaintextSize: shardPlaintextSize,
    recipientKeyId: recipientKeyId,
    noncePrefix: noncePrefix,
    wrappedBundleDek: Uint8List(0),
    metadataFormatId: 0,
    metadataKdfAlg: 0,
    metadataAeadAlg: 0,
    metadataFlags: 0,
    metadataPlaintextLength: 0,
    metadataCiphertextLength: 0,
    metadataSalt: Uint8List(0),
    metadataNonce: Uint8List(0),
    metadataCiphertext: Uint8List(0),
    metadataTag: Uint8List(0),
  );

  final bool isRoot;
  final SboxVersion version;
  final Uint8List bundleId;
  final int shardIndex;
  final int shardCount;
  final BigInt shardPlaintextSize;
  final Uint8List recipientKeyId;
  final Uint8List noncePrefix;
  final Uint8List wrappedBundleDek;
  final int metadataFormatId;
  final int metadataKdfAlg;
  final int metadataAeadAlg;
  final int metadataFlags;
  final int metadataPlaintextLength;
  final int metadataCiphertextLength;
  final Uint8List metadataSalt;
  final Uint8List metadataNonce;
  final Uint8List metadataCiphertext;
  final Uint8List metadataTag;
  final Uint8List? _rawBytes;

  int get headerLength =>
      isRoot ? SboxProtocol.rootHeaderLength : SboxProtocol.commonHeaderLength;

  String get canonicalBasename {
    final id = hexLower(bundleId);
    return shardCount == 1
        ? '$id.sbox'
        : '${id}_${shardIndex}_$shardCount.sbox';
  }

  /// Exact received/encoded header bytes. The returned array is a copy.
  Uint8List get rawBytes => Uint8List.fromList(_rawBytes ?? encode());

  Uint8List get rawHeaderBytes => rawBytes;

  Uint8List get hash => sha256Bytes(rawBytes);

  /// The bytes used as Metadata AAD, before the encrypted block and tag.
  Uint8List get metadataAadBytes =>
      Uint8List.fromList(rawBytes.sublist(0, SboxProtocol.metadataAadHeaderLength));

  Uint8List encode() {
    _validateFields();
    final bytes = Uint8List(headerLength);
    bytes.setRange(0, 8, SboxProtocol.magic);
    bytes[8] = version.major;
    bytes[9] = version.minor;
    writeUint16BigEndian(bytes, 10, headerLength);
    writeUint32BigEndian(bytes, 12, isRoot ? 1 : 0);
    writeUint16BigEndian(bytes, 16, SboxProtocol.keyProfileId);
    writeUint16BigEndian(
      bytes,
      18,
      isRoot
          ? SboxProtocol.rootKeyWrapAlgorithm
          : SboxProtocol.continuationKeyWrapAlgorithm,
    );
    writeUint16BigEndian(bytes, 20, SboxProtocol.payloadAlgorithm);
    writeUint16BigEndian(bytes, 22, SboxProtocol.shardKdfAlgorithm);
    writeUint32BigEndian(bytes, 24, SboxProtocol.chunkSize);
    bytes.setRange(28, 44, bundleId);
    writeUint32BigEndian(bytes, 44, shardIndex);
    writeUint32BigEndian(bytes, 48, shardCount);
    writeUint64BigEndian(bytes, 52, shardPlaintextSize);
    bytes.setRange(60, 92, recipientKeyId);
    bytes.setRange(92, 96, noncePrefix);
    writeUint16BigEndian(bytes, 96, wrappedBundleDek.length);
    // 98..128 is the all-zero reserved common-prefix area.
    if (isRoot) {
      bytes.setRange(128, 512, wrappedBundleDek);
      bytes.setRange(512, 516, _metadataMagic);
      writeUint16BigEndian(bytes, 516, metadataFormatId);
      writeUint16BigEndian(bytes, 518, metadataKdfAlg);
      writeUint16BigEndian(bytes, 520, metadataAeadAlg);
      writeUint16BigEndian(bytes, 522, metadataFlags);
      writeUint32BigEndian(bytes, 524, metadataPlaintextLength);
      writeUint32BigEndian(bytes, 528, metadataCiphertextLength);
      bytes.setRange(532, 564, metadataSalt);
      bytes.setRange(564, 576, metadataNonce);
      bytes.setRange(576, 16976, metadataCiphertext);
      bytes.setRange(16976, 16992, metadataTag);
    }
    return bytes;
  }

  static BundleHeader parse(List<int> input) {
    if (input.length < 12) {
      throw const SboxException(SboxErrorCode.truncated, 'SBOX 公共头不完整');
    }
    if (!constantTimeBytesEqual(input.sublist(0, 8), SboxProtocol.magic)) {
      throw _invalidHeader();
    }
    final version = SboxVersion.parse(input[8], input[9]);
    final headerLength = readUint16BigEndian(input, 10);
    if (headerLength != SboxProtocol.commonHeaderLength &&
        headerLength != SboxProtocol.rootHeaderLength) {
      throw _invalidHeader();
    }
    if (input.length < headerLength) {
      throw const SboxException(SboxErrorCode.truncated, 'SBOX 公共头不完整');
    }
    final bytes = Uint8List.fromList(input.sublist(0, headerLength));
    final flags = readUint32BigEndian(bytes, 12);
    final keyProfileId = readUint16BigEndian(bytes, 16);
    final keyWrapAlgorithm = readUint16BigEndian(bytes, 18);
    final payloadAlgorithm = readUint16BigEndian(bytes, 20);
    final shardKdfAlgorithm = readUint16BigEndian(bytes, 22);
    final chunkSize = readUint32BigEndian(bytes, 24);
    final shardIndex = readUint32BigEndian(bytes, 44);
    final shardCount = readUint32BigEndian(bytes, 48);
    final shardPlaintextSize = readUint64BigEndian(bytes, 52);
    final wrappedKeyLength = readUint16BigEndian(bytes, 96);
    if ((flags != 0 && flags != 1) ||
        keyProfileId != SboxProtocol.keyProfileId ||
        payloadAlgorithm != SboxProtocol.payloadAlgorithm ||
        shardKdfAlgorithm != SboxProtocol.shardKdfAlgorithm ||
        chunkSize != SboxProtocol.chunkSize ||
        readUint16BigEndian(bytes, 98) != 0 ||
        bytes.sublist(100, 128).any((value) => value != 0) ||
        shardCount < 1 ||
        shardCount > SboxProtocol.maxShardCount ||
        shardIndex >= shardCount ||
        shardPlaintextSize > BigInt.from(SboxProtocol.maxShardPlaintextSize)) {
      throw _invalidHeader();
    }
    final isRoot = flags == 1;
    if (isRoot) {
      if (headerLength != SboxProtocol.rootHeaderLength ||
          keyWrapAlgorithm != SboxProtocol.rootKeyWrapAlgorithm ||
          shardIndex != 0 ||
          wrappedKeyLength != SboxProtocol.wrappedBundleDekLength ||
          (shardCount >= 2 && shardPlaintextSize == BigInt.zero)) {
        throw _invalidHeader();
      }
      _validateRootMetadata(bytes, version);
    } else if (headerLength != SboxProtocol.commonHeaderLength ||
        keyWrapAlgorithm != SboxProtocol.continuationKeyWrapAlgorithm ||
        wrappedKeyLength != 0 ||
        shardIndex < 1 ||
        shardPlaintextSize == BigInt.zero) {
      throw _invalidHeader();
    }
    return BundleHeader._(
      isRoot: isRoot,
      version: version,
      bundleId: bytes.sublist(28, 44),
      shardIndex: shardIndex,
      shardCount: shardCount,
      shardPlaintextSize: shardPlaintextSize,
      recipientKeyId: bytes.sublist(60, 92),
      noncePrefix: bytes.sublist(92, 96),
      wrappedBundleDek: isRoot ? bytes.sublist(128, 512) : const <int>[],
      metadataFormatId: isRoot ? readUint16BigEndian(bytes, 516) : 0,
      metadataKdfAlg: isRoot ? readUint16BigEndian(bytes, 518) : 0,
      metadataAeadAlg: isRoot ? readUint16BigEndian(bytes, 520) : 0,
      metadataFlags: isRoot ? readUint16BigEndian(bytes, 522) : 0,
      metadataPlaintextLength: isRoot ? readUint32BigEndian(bytes, 524) : 0,
      metadataCiphertextLength: isRoot ? readUint32BigEndian(bytes, 528) : 0,
      metadataSalt: isRoot ? bytes.sublist(532, 564) : const <int>[],
      metadataNonce: isRoot ? bytes.sublist(564, 576) : const <int>[],
      metadataCiphertext: isRoot ? bytes.sublist(576, 16976) : const <int>[],
      metadataTag: isRoot ? bytes.sublist(16976, 16992) : const <int>[],
      rawBytes: bytes,
    );
  }

  void _validateFields() {
    if (bundleId.length != SboxProtocol.bundleIdLength ||
        recipientKeyId.length != SboxProtocol.recipientKeyIdLength ||
        noncePrefix.length != SboxProtocol.noncePrefixLength ||
        shardCount < 1 ||
        shardCount > SboxProtocol.maxShardCount ||
        shardIndex < 0 ||
        shardIndex >= shardCount ||
        shardPlaintextSize.isNegative ||
        shardPlaintextSize > BigInt.from(SboxProtocol.maxShardPlaintextSize)) {
      throw _invalidHeader();
    }
    if (isRoot) {
      if (shardIndex != 0 ||
          (shardCount >= 2 && shardPlaintextSize == BigInt.zero) ||
          wrappedBundleDek.length != SboxProtocol.wrappedBundleDekLength ||
          metadataFormatId != version.metadataFormatId ||
          metadataKdfAlg != SboxProtocol.metadataKdfAlgorithm ||
          metadataAeadAlg != SboxProtocol.metadataAeadAlgorithm ||
          metadataFlags != SboxProtocol.metadataFlags ||
          metadataPlaintextLength != SboxProtocol.metadataBlockLength ||
          metadataCiphertextLength != SboxProtocol.metadataCiphertextLength ||
          metadataSalt.length != SboxProtocol.metadataSaltLength ||
          metadataNonce.length != SboxProtocol.metadataNonceLength ||
          metadataCiphertext.length != SboxProtocol.metadataCiphertextLength ||
          metadataTag.length != SboxProtocol.gcmTagLength) {
        throw _invalidHeader();
      }
    } else if (shardIndex < 1 ||
        shardCount < 2 ||
        shardPlaintextSize == BigInt.zero ||
        wrappedBundleDek.isNotEmpty ||
        metadataFormatId != 0 ||
        metadataKdfAlg != 0 ||
        metadataAeadAlg != 0 ||
        metadataFlags != 0 ||
        metadataPlaintextLength != 0 ||
        metadataCiphertextLength != 0 ||
        metadataSalt.isNotEmpty ||
        metadataNonce.isNotEmpty ||
        metadataCiphertext.isNotEmpty ||
        metadataTag.isNotEmpty) {
      throw _invalidHeader();
    }
  }

  static void _validateRootMetadata(List<int> bytes, SboxVersion version) {
    if (!constantTimeBytesEqual(bytes.sublist(512, 516), _metadataMagic) ||
        readUint16BigEndian(bytes, 516) != version.metadataFormatId ||
        readUint16BigEndian(bytes, 518) != SboxProtocol.metadataKdfAlgorithm ||
        readUint16BigEndian(bytes, 520) != SboxProtocol.metadataAeadAlgorithm ||
        readUint16BigEndian(bytes, 522) != SboxProtocol.metadataFlags ||
        readUint32BigEndian(bytes, 524) != SboxProtocol.metadataBlockLength ||
        readUint32BigEndian(bytes, 528) !=
            SboxProtocol.metadataCiphertextLength) {
      throw _invalidHeader();
    }
  }

  static final Uint8List _metadataMagic = asciiBytes('META');

  static SboxException _invalidHeader() =>
      const SboxException(SboxErrorCode.invalidHeader, 'SBOX 公共头无效');
}
