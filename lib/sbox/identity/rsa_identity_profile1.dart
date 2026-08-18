/// The frozen deterministic RSA identity profile. Its two frozen algorithm
/// input strings are not a container-version compatibility path.
abstract final class RsaIdentityProfile1 {
  static const int keyProfileId = 1;
  static const int rsaBits = 3072;
  static const int primeBits = 1536;
  static const int publicExponent = 65537;
  static const String drbgHkdfSalt = 'SBOX-v1/BIP39-to-RSA3072';
  static const String drbgHkdfInfo = 'HMAC-DRBG-SHA256/instantiate';
  static const String personalization = 'SBOX-v1/RSA-3072';
}
