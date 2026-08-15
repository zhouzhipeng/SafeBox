import 'dart:typed_data';

/// Mutable secret bytes with an explicit best-effort overwrite operation.
///
/// Dart and third-party libraries may retain copies. SBOX therefore also runs
/// private-key operations in disposable isolates; this class makes no claim of
/// deterministic physical memory erasure.
final class SecretBytes {
  SecretBytes(List<int> bytes) : _bytes = Uint8List.fromList(bytes);

  factory SecretBytes.copyOf(List<int> bytes) => SecretBytes(bytes);

  Uint8List? _bytes;

  bool get isDisposed => _bytes == null;

  Uint8List get bytes {
    final value = _bytes;
    if (value == null) {
      throw StateError('Secret bytes have been disposed');
    }
    return value;
  }

  T use<T>(T Function(Uint8List bytes) action) => action(bytes);

  void dispose() {
    final value = _bytes;
    if (value != null) {
      value.fillRange(0, value.length, 0);
      _bytes = null;
    }
  }
}
