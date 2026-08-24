/// Browser-specific safety limits for workflows that keep both plaintext and
/// encrypted SBOX objects in memory.
abstract final class WebRuntimeLimits {
  static const int defaultMaxFileMiB = 128;
  static const int maximumConfigurableFileMiB = 512;
  static const int _ciphertextOverheadAllowanceBytes = 16 * 1024 * 1024;

  static const int _configuredMaxFileMiB = int.fromEnvironment(
    'SBOX_WEB_MAX_FILE_MIB',
    defaultValue: defaultMaxFileMiB,
  );

  static int get maxFileMiB {
    if (_configuredMaxFileMiB < 1) return defaultMaxFileMiB;
    if (_configuredMaxFileMiB > maximumConfigurableFileMiB) {
      return maximumConfigurableFileMiB;
    }
    return _configuredMaxFileMiB;
  }

  static int get maxFileBytes => maxFileMiB * 1024 * 1024;

  /// Maximum aggregate ciphertext retained before browser decryption starts.
  ///
  /// A valid SBOX Bundle is only slightly larger than its plaintext. The
  /// allowance covers headers, record authentication tags, and the maximum
  /// protocol shard overhead while preventing a malformed remote Bundle from
  /// making the tab retain an unbounded number of objects.
  static int get maxCiphertextBytes =>
      maxFileBytes + _ciphertextOverheadAllowanceBytes;
}
