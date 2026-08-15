import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../bytes.dart';

/// The exact HMAC_DRBG-SHA256 profile required by SBOX v1.
final class HmacDrbgSha256 {
  HmacDrbgSha256({
    required List<int> entropyInput,
    required List<int> nonce,
    required List<int> personalization,
  }) : _key = Uint8List(32),
       _value = Uint8List.fromList(List<int>.filled(32, 0x01)) {
    if (entropyInput.length < 32 || nonce.length < 16) {
      throw ArgumentError('Insufficient HMAC_DRBG instantiation material');
    }
    final seedMaterial = concatBytes(<List<int>>[
      entropyInput,
      nonce,
      personalization,
    ]);
    try {
      _update(seedMaterial);
    } finally {
      seedMaterial.fillRange(0, seedMaterial.length, 0);
    }
  }

  Uint8List _key;
  Uint8List _value;
  bool _disposed = false;

  Uint8List generate(int byteLength) {
    if (_disposed) {
      throw StateError('HMAC_DRBG has been disposed');
    }
    if (byteLength < 0 || byteLength > 65536) {
      throw ArgumentError.value(byteLength, 'byteLength');
    }

    final result = Uint8List(byteLength);
    var offset = 0;
    while (offset < byteLength) {
      _replaceValue(_hmac(_key, _value));
      final take = (byteLength - offset).clamp(0, _value.length);
      result.setRange(offset, offset + take, _value);
      offset += take;
    }

    // SP 800-90A Update is mandatory after every Generate request, including
    // when additional_input is the empty string.
    _update(Uint8List(0));
    return result;
  }

  void _update(Uint8List providedData) {
    final firstInput = concatBytes(<List<int>>[
      _value,
      const <int>[0x00],
      providedData,
    ]);
    try {
      _replaceKey(_hmac(_key, firstInput));
    } finally {
      firstInput.fillRange(0, firstInput.length, 0);
    }
    _replaceValue(_hmac(_key, _value));

    if (providedData.isEmpty) {
      return;
    }

    final secondInput = concatBytes(<List<int>>[
      _value,
      const <int>[0x01],
      providedData,
    ]);
    try {
      _replaceKey(_hmac(_key, secondInput));
    } finally {
      secondInput.fillRange(0, secondInput.length, 0);
    }
    _replaceValue(_hmac(_key, _value));
  }

  static Uint8List _hmac(List<int> key, List<int> input) =>
      Uint8List.fromList(crypto.Hmac(crypto.sha256, key).convert(input).bytes);

  void _replaceKey(Uint8List replacement) {
    _key.fillRange(0, _key.length, 0);
    _key = replacement;
  }

  void _replaceValue(Uint8List replacement) {
    _value.fillRange(0, _value.length, 0);
    _value = replacement;
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _key.fillRange(0, _key.length, 0);
    _value.fillRange(0, _value.length, 0);
    _disposed = true;
  }
}
