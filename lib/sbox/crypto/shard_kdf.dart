import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../bytes.dart';
import '../constants.dart';

/// SBOX v3 HKDF-SHA256 key derivation. This is deliberately independent of
/// identity and container classes so its fixed vectors can be tested alone.
abstract final class ShardKdf {
  static Uint8List extract({required List<int> salt, required List<int> ikm}) {
    final effectiveSalt = salt.isEmpty
        ? Uint8List(SboxProtocol.gcmTagLength * 2)
        : Uint8List.fromList(salt);
    return Uint8List.fromList(
      crypto.Hmac(crypto.sha256, effectiveSalt).convert(ikm).bytes,
    );
  }

  static Uint8List derive({
    required List<int> bundleDek,
    required List<int> bundleId,
    required List<int> recipientKeyId,
    required int shardIndex,
  }) {
    if (bundleDek.length != SboxProtocol.bundleDekLength ||
        bundleId.length != SboxProtocol.bundleIdLength ||
        recipientKeyId.length != SboxProtocol.recipientKeyIdLength ||
        shardIndex < 0 ||
        shardIndex >= SboxProtocol.maxShardCount) {
      throw ArgumentError('Invalid shard KDF inputs');
    }
    final prk = extract(salt: bundleId, ikm: bundleDek);
    final info = concatBytes(<List<int>>[
      asciiBytes('SBOX-v3/shard-key'),
      const <int>[0],
      recipientKeyId,
      bigIntToFixedBytes(BigInt.from(shardIndex), 4),
    ]);
    final message = concatBytes(<List<int>>[
      info,
      const <int>[1],
    ]);
    try {
      return Uint8List.fromList(
        crypto.Hmac(crypto.sha256, prk).convert(message).bytes,
      );
    } finally {
      prk.fillRange(0, prk.length, 0);
      info.fillRange(0, info.length, 0);
      message.fillRange(0, message.length, 0);
    }
  }
}
