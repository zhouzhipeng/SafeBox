import 'dart:convert';
import 'dart:typed_data';

/// Mutable task-scoped mnemonic input. It intentionally has no serialization
/// API and must not be retained by application state.
final class EphemeralMnemonic {
  EphemeralMnemonic.fromString(String mnemonic)
    : _utf8Bytes = Uint8List.fromList(utf8.encode(mnemonic));

  Uint8List? _utf8Bytes;

  bool get isDisposed => _utf8Bytes == null;

  String revealForDerivation() {
    final value = _utf8Bytes;
    if (value == null) {
      throw StateError('Mnemonic has been disposed');
    }
    return utf8.decode(value, allowMalformed: false);
  }

  void dispose() {
    final value = _utf8Bytes;
    if (value != null) {
      value.fillRange(0, value.length, 0);
      _utf8Bytes = null;
    }
  }
}
