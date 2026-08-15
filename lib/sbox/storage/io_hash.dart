import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;

Future<Uint8List> sha256File(File file) async {
  final accumulator = AccumulatorSink<crypto.Digest>();
  final sink = crypto.sha256.startChunkedConversion(accumulator);
  await for (final chunk in file.openRead()) {
    sink.add(chunk);
  }
  sink.close();
  return Uint8List.fromList(accumulator.events.single.bytes);
}

Future<Uint8List> sha256RandomAccessFile(RandomAccessFile handle) async {
  final accumulator = AccumulatorSink<crypto.Digest>();
  final sink = crypto.sha256.startChunkedConversion(accumulator);
  await handle.setPosition(0);
  while (true) {
    final chunk = await handle.read(1024 * 1024);
    if (chunk.isEmpty) break;
    sink.add(chunk);
  }
  sink.close();
  await handle.setPosition(0);
  return Uint8List.fromList(accumulator.events.single.bytes);
}
