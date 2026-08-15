import 'dart:convert';
import 'dart:typed_data';

import '../crypto/secret_bytes.dart';

final class SourceCredentialId {
  SourceCredentialId(String value) : value = _validate(value);

  final String value;

  static String _validate(String value) {
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$').hasMatch(value)) {
      throw ArgumentError.value(value, 'value', 'Invalid credential ID');
    }
    return value;
  }

  @override
  bool operator ==(Object other) =>
      other is SourceCredentialId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// A deliberately narrow, disposable wrapper for repository access tokens.
///
/// Converting the bytes to an HTTP header necessarily creates a short-lived
/// immutable String in the Dart/http stack. The owned mutable buffer is still
/// overwritten as soon as the request has been submitted.
final class SourceAccessToken {
  SourceAccessToken(Uint8List value) : _bytes = SecretBytes.copyOf(value) {
    if (value.isEmpty || value.length > 4096) {
      _bytes.dispose();
      throw ArgumentError('Access token length is invalid');
    }
    for (final byte in value) {
      if (byte < 0x21 || byte > 0x7e) {
        _bytes.dispose();
        throw ArgumentError('Access token must contain visible ASCII only');
      }
    }
  }

  factory SourceAccessToken.fromUtf8(String value) =>
      SourceAccessToken(Uint8List.fromList(utf8.encode(value)));

  final SecretBytes _bytes;

  bool get isDisposed => _bytes.isDisposed;

  T useBytes<T>(T Function(Uint8List bytes) action) => _bytes.use(action);

  T useAuthorizationValue<T>(String scheme, T Function(String value) action) {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,31}$').hasMatch(scheme)) {
      throw ArgumentError.value(scheme, 'scheme');
    }
    return _bytes.use(
      (bytes) => action('$scheme ${ascii.decode(bytes, allowInvalid: false)}'),
    );
  }

  void dispose() => _bytes.dispose();

  @override
  String toString() => 'SourceAccessToken(<redacted>)';
}

abstract interface class CredentialStore {
  Future<void> putAccessToken(SourceCredentialId id, SourceAccessToken token);

  Future<SourceAccessToken?> getAccessToken(SourceCredentialId id);

  Future<void> deleteAccessToken(SourceCredentialId id);
}
