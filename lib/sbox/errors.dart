/// Stable external error categories. Error messages deliberately avoid
/// protocol secrets, RSA internals and untrusted paths.
enum SboxErrorCode {
  invalidMnemonic('SBOX_E_MNEMONIC'),
  identityDerivation('SBOX_E_IDENTITY_DERIVATION'),
  keyMismatch('SBOX_E_KEY_MISMATCH'),
  invalidHeader('SBOX_E_HEADER'),
  invalidManifest('SBOX_E_MANIFEST'),
  invalidRecord('SBOX_E_RECORD'),
  rootRequired('SBOX_E_ROOT_REQUIRED'),
  shardMissing('SBOX_E_SHARD_MISSING'),
  shardConflict('SBOX_E_SHARD_CONFLICT'),
  shardMismatch('SBOX_E_SHARD_MISMATCH'),
  authentication('SBOX_E_AUTH'),
  integrity('SBOX_E_INTEGRITY'),
  immutableConflict('SBOX_E_IMMUTABLE_CONFLICT'),
  listingUnsupported('SBOX_E_LISTING_UNSUPPORTED'),
  sourceLimit('SBOX_E_SOURCE_LIMIT'),
  inputChanged('SBOX_E_INPUT_CHANGED'),
  unsupportedVersion('SBOX_E_VERSION'),
  truncated('SBOX_E_TRUNCATED'),
  trailingData('SBOX_E_TRAILING_DATA'),
  cancelled('SBOX_E_CANCELLED'),
  sourceAuthentication('SBOX_E_SOURCE_AUTH'),
  sourceNetwork('SBOX_E_SOURCE_NETWORK'),
  sourceNotFound('SBOX_E_SOURCE_NOT_FOUND'),
  sourceRateLimit('SBOX_E_SOURCE_RATE_LIMIT'),
  remoteChanged('SBOX_E_REMOTE_CHANGED'),
  temporaryCleanup('SBOX_E_TEMP_CLEANUP'),
  storageOverlap('SBOX_E_STORAGE_OVERLAP');

  const SboxErrorCode(this.value);

  final String value;
}

/// A deliberately low-detail exception. Secret material and untrusted paths
/// must never be interpolated into [message].
final class SboxException implements Exception {
  const SboxException(this.code, this.message);

  final SboxErrorCode code;
  final String message;

  @override
  String toString() => '${code.value}: $message';
}
