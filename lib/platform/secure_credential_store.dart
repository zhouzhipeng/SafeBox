import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../sbox/source/credential.dart';

/// The only platform persistence adapter for secret material. Its public API
/// accepts [SourceAccessToken], so SBOX mnemonic/private-key types cannot be
/// passed to it accidentally.
final class PlatformCredentialStore implements CredentialStore {
  PlatformCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const String _keyPrefix = 'sbox.source_token.';
  final FlutterSecureStorage _storage;

  @override
  Future<void> putAccessToken(SourceCredentialId id, SourceAccessToken token) {
    final encoded = token.useBytes(
      (bytes) => base64Url.encode(bytes).replaceAll('=', ''),
    );
    return _storage.write(key: _key(id), value: encoded);
  }

  @override
  Future<SourceAccessToken?> getAccessToken(SourceCredentialId id) async {
    final encoded = await _storage.read(key: _key(id));
    if (encoded == null) {
      return null;
    }
    try {
      final padding = '=' * ((4 - encoded.length % 4) % 4);
      final decoded = Uint8List.fromList(base64Url.decode('$encoded$padding'));
      if (base64Url.encode(decoded).replaceAll('=', '') != encoded) {
        throw const FormatException('Non-canonical token encoding');
      }
      return SourceAccessToken(decoded);
    } on FormatException {
      // A malformed secure-storage value is unusable and must not be returned
      // as a possibly different token.
      await _storage.delete(key: _key(id));
      return null;
    } on ArgumentError {
      await _storage.delete(key: _key(id));
      return null;
    }
  }

  @override
  Future<void> deleteAccessToken(SourceCredentialId id) =>
      _storage.delete(key: _key(id));

  static String _key(SourceCredentialId id) => '$_keyPrefix${id.value}';
}
