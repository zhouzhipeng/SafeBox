enum SboxErrorCode {
  invalidMnemonic('SBOX_E_MNEMONIC'),
  identityDerivation('SBOX_E_IDENTITY_DERIVATION'),
  keyMismatch('SBOX_E_KEY_MISMATCH'),
  invalidHeader('SBOX_E_HEADER'),
  unsupportedVersion('SBOX_E_VERSION'),
  invalidRecord('SBOX_E_RECORD'),
  authentication('SBOX_E_AUTH'),
  integrity('SBOX_E_INTEGRITY'),
  truncated('SBOX_E_TRUNCATED'),
  trailingData('SBOX_E_TRAILING_DATA'),
  limits('SBOX_E_LIMIT'),
  catalog('SBOX_E_CATALOG'),
  catalogRequired('SBOX_E_CATALOG_REQUIRED'),
  multipartManifest('SBOX_E_MULTIPART_MANIFEST'),
  multipartMissing('SBOX_E_MULTIPART_MISSING'),
  multipartAssembly('SBOX_E_MULTIPART_ASSEMBLY'),
  tooManyParts('SBOX_E_TOO_MANY_PARTS'),
  catalogSignature('SBOX_E_CATALOG_SIGNATURE'),
  catalogRollback('SBOX_E_CATALOG_ROLLBACK'),
  catalogFork('SBOX_E_CATALOG_FORK'),
  storageOverlap('SBOX_E_STORAGE_OVERLAP'),
  temporaryCleanup('SBOX_E_TEMP_CLEANUP'),
  cancelled('SBOX_E_CANCELLED'),
  sourceAuthentication('SBOX_E_SOURCE_AUTH'),
  sourceNetwork('SBOX_E_SOURCE_NETWORK'),
  sourceNotFound('SBOX_E_SOURCE_NOT_FOUND'),
  sourceRateLimit('SBOX_E_SOURCE_RATE_LIMIT'),
  sourceLimit('SBOX_E_SOURCE_LIMIT'),
  remoteChanged('SBOX_E_REMOTE_CHANGED'),
  syncConflict('SBOX_E_SYNC_CONFLICT');

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
