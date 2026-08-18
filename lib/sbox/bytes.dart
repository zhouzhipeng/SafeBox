import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;

/// Captures the single digest emitted by a chunked crypto hash.
final class HashDigestSink implements Sink<crypto.Digest> {
  crypto.Digest? _digest;

  crypto.Digest get value => _digest!;

  @override
  void add(crypto.Digest value) {
    if (_digest != null) throw StateError('Digest already captured');
    _digest = value;
  }

  @override
  void close() {
    if (_digest == null) throw StateError('Digest was not emitted');
  }
}

Uint8List asciiBytes(String value) => Uint8List.fromList(ascii.encode(value));

Uint8List utf8Bytes(String value) => Uint8List.fromList(utf8.encode(value));

Uint8List concatBytes(Iterable<List<int>> chunks) {
  var length = 0;
  for (final chunk in chunks) {
    length += chunk.length;
  }
  final result = Uint8List(length);
  var offset = 0;
  for (final chunk in chunks) {
    result.setRange(offset, offset + chunk.length, chunk);
    offset += chunk.length;
  }
  return result;
}

Uint8List sha256Bytes(List<int> input) =>
    Uint8List.fromList(crypto.sha256.convert(input).bytes);

String hexLower(List<int> input) => hex.encode(input);

Uint8List decodeHex(String input) {
  if (input.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(input)) {
    throw const FormatException('Invalid hexadecimal string');
  }
  return Uint8List.fromList(hex.decode(input));
}

BigInt bytesToBigInt(List<int> bytes) {
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}

Uint8List bigIntToFixedBytes(BigInt value, int length) {
  if (value.isNegative || value.bitLength > length * 8) {
    throw ArgumentError.value(value, 'value', 'Does not fit requested length');
  }
  final result = Uint8List(length);
  var remaining = value;
  for (var index = length - 1; index >= 0; index--) {
    result[index] = (remaining & BigInt.from(0xff)).toInt();
    remaining >>= 8;
  }
  return result;
}

Uint8List secureRandomBytes(int length, {Random? random}) {
  if (length < 0) {
    throw ArgumentError.value(length, 'length');
  }
  final source = random ?? Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => source.nextInt(256), growable: false),
  );
}

bool constantTimeBytesEqual(List<int> left, List<int> right) {
  var difference = left.length ^ right.length;
  final length = min(left.length, right.length);
  for (var index = 0; index < length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

int readUint16BigEndian(List<int> bytes, int offset) => ByteData.sublistView(
  Uint8List.fromList(bytes),
  offset,
  offset + 2,
).getUint16(0, Endian.big);

int readUint32BigEndian(List<int> bytes, int offset) => ByteData.sublistView(
  Uint8List.fromList(bytes),
  offset,
  offset + 4,
).getUint32(0, Endian.big);

BigInt readUint64BigEndian(List<int> bytes, int offset) =>
    bytesToBigInt(bytes.sublist(offset, offset + 8));

void writeUint16BigEndian(Uint8List bytes, int offset, int value) {
  ByteData.sublistView(
    bytes,
    offset,
    offset + 2,
  ).setUint16(0, value, Endian.big);
}

void writeUint32BigEndian(Uint8List bytes, int offset, int value) {
  ByteData.sublistView(
    bytes,
    offset,
    offset + 4,
  ).setUint32(0, value, Endian.big);
}

void writeUint64BigEndian(Uint8List bytes, int offset, BigInt value) {
  bytes.setRange(offset, offset + 8, bigIntToFixedBytes(value, 8));
}

BigInt integerSquareRoot(BigInt value) {
  if (value.isNegative) {
    throw ArgumentError.value(value, 'value');
  }
  if (value < BigInt.two) {
    return value;
  }
  var estimate = BigInt.one << ((value.bitLength + 1) >> 1);
  while (true) {
    final next = (estimate + value ~/ estimate) >> 1;
    if (next >= estimate) {
      return estimate;
    }
    estimate = next;
  }
}

BigInt positiveMod(BigInt value, BigInt modulus) {
  final result = value % modulus;
  return result.isNegative ? result + modulus : result;
}
