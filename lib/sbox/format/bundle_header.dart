import 'dart:typed_data';

import '../bytes.dart';
import '../constants.dart';
import '../errors.dart';

final class BundleHeader {
  BundleHeader._({
    required this.isRoot,
    required List<int> bundleId,
    required this.shardIndex,
    required this.shardCount,
    required this.shardPlaintextSize,
    required List<int> recipientKeyId,
    required List<int> noncePrefix,
    required List<int> wrappedBundleDek,
  }) : bundleId = Uint8List.fromList(bundleId),
       recipientKeyId = Uint8List.fromList(recipientKeyId),
       noncePrefix = Uint8List.fromList(noncePrefix),
       wrappedBundleDek = Uint8List.fromList(wrappedBundleDek) {
    _validateFields();
  }

  factory BundleHeader.root({
    required List<int> bundleId,
    required int shardCount,
    required BigInt shardPlaintextSize,
    required List<int> recipientKeyId,
    required List<int> noncePrefix,
    required List<int> wrappedBundleDek,
  }) => BundleHeader._(
    isRoot: true,
    bundleId: bundleId,
    shardIndex: 0,
    shardCount: shardCount,
    shardPlaintextSize: shardPlaintextSize,
    recipientKeyId: recipientKeyId,
    noncePrefix: noncePrefix,
    wrappedBundleDek: wrappedBundleDek,
  );

  factory BundleHeader.continuation({
    required List<int> bundleId,
    required int shardIndex,
    required int shardCount,
    required BigInt shardPlaintextSize,
    required List<int> recipientKeyId,
    required List<int> noncePrefix,
  }) => BundleHeader._(
    isRoot: false,
    bundleId: bundleId,
    shardIndex: shardIndex,
    shardCount: shardCount,
    shardPlaintextSize: shardPlaintextSize,
    recipientKeyId: recipientKeyId,
    noncePrefix: noncePrefix,
    wrappedBundleDek: Uint8List(0),
  );

  final bool isRoot;
  final Uint8List bundleId;
  final int shardIndex;
  final int shardCount;
  final BigInt shardPlaintextSize;
  final Uint8List recipientKeyId;
  final Uint8List noncePrefix;
  final Uint8List wrappedBundleDek;

  int get headerLength =>
      isRoot ? SboxProtocol.rootHeaderLength : SboxProtocol.commonHeaderLength;

  String get canonicalBasename {
    final id = hexLower(bundleId);
    return shardCount == 1
        ? '$id.sbox'
        : '${id}_${shardIndex}_$shardCount.sbox';
  }

  Uint8List encode() {
    _validateFields();
    final bytes = Uint8List(headerLength);
    bytes.setRange(0, 8, SboxProtocol.magic);
    bytes[8] = SboxProtocol.versionMajor;
    bytes[9] = SboxProtocol.versionMinor;
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
    // The reserved area is zero-initialized by Uint8List.
    if (isRoot) bytes.setRange(128, 512, wrappedBundleDek);
    return bytes;
  }

  Uint8List get hash => sha256Bytes(encode());

  static BundleHeader parse(List<int> input) {
    if (input.length < 12) {
      throw const SboxException(SboxErrorCode.truncated, 'SBOX 公共头不完整');
    }
    final prefix = Uint8List.fromList(input.sublist(0, 12));
    if (!constantTimeBytesEqual(prefix.sublist(0, 8), SboxProtocol.magic)) {
      throw _invalidHeader();
    }
    if (prefix[8] != SboxProtocol.versionMajor ||
        prefix[9] != SboxProtocol.versionMinor) {
      throw const SboxException(
        SboxErrorCode.unsupportedVersion,
        '不支持此 SBOX 协议版本',
      );
    }
    final headerLength = readUint16BigEndian(prefix, 10);
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
    if (keyProfileId != SboxProtocol.keyProfileId ||
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
          shardCount == 0) {
        throw _invalidHeader();
      }
      if (shardCount >= 2 && shardPlaintextSize == BigInt.zero) {
        throw _invalidHeader();
      }
    } else {
      if (flags != 0 ||
          headerLength != SboxProtocol.commonHeaderLength ||
          keyWrapAlgorithm != SboxProtocol.continuationKeyWrapAlgorithm ||
          wrappedKeyLength != 0 ||
          shardIndex < 1 ||
          shardPlaintextSize == BigInt.zero) {
        throw _invalidHeader();
      }
    }
    return BundleHeader._(
      isRoot: isRoot,
      bundleId: bytes.sublist(28, 44),
      shardIndex: shardIndex,
      shardCount: shardCount,
      shardPlaintextSize: shardPlaintextSize,
      recipientKeyId: bytes.sublist(60, 92),
      noncePrefix: bytes.sublist(92, 96),
      wrappedBundleDek: isRoot ? bytes.sublist(128, 512) : Uint8List(0),
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
          wrappedBundleDek.length != SboxProtocol.wrappedBundleDekLength) {
        throw _invalidHeader();
      }
    } else if (shardIndex < 1 ||
        shardCount < 2 ||
        shardPlaintextSize == BigInt.zero ||
        wrappedBundleDek.isNotEmpty) {
      throw _invalidHeader();
    }
  }

  static SboxException _invalidHeader() =>
      const SboxException(SboxErrorCode.invalidHeader, 'SBOX 公共头无效');
}
