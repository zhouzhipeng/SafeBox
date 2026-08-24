use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use rsa::{
    RsaPublicKey,
    pkcs8::{DecodePublicKey, EncodePublicKey},
    traits::PublicKeyParts,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{Error, Result};

const PUBLIC_IDENTITY_SCHEMA: &str = "SBOX-PUBLIC-IDENTITY-1";
const COMPACT_PUBLIC_KEY_PREFIX: &str = "sboxpk1:";
const KEY_PROFILE_ID: u16 = 1;
const RSA_BITS: usize = 3072;
const RSA_EXPONENT: u32 = 65_537;
const RSA_MODULUS_BYTES: usize = RSA_BITS / 8;
const COMPACT_CHECKSUM_BYTES: usize = 4;

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct WirePublicIdentity {
    schema: String,
    key_profile_id: u16,
    spki_der: String,
    recipient_key_id: String,
}

/// A validated RSA-only SafeBox public identity.
///
/// This type contains public material only. It can be built directly from the
/// compact key copied by the SafeBox “复制公钥” button.
#[derive(Clone, Debug)]
pub struct PublicIdentity {
    spki_der: Vec<u8>,
    recipient_key_id: [u8; 32],
    public_key: RsaPublicKey,
}

impl PublicIdentity {
    /// Parses the compact `sboxpk1:` copied format or the legacy
    /// `SBOX-PUBLIC-IDENTITY-1` JSON representation.
    pub fn from_encoded(input: &str) -> Result<Self> {
        let value = input.trim();
        if value.starts_with(COMPACT_PUBLIC_KEY_PREFIX) {
            Self::from_compact(value)
        } else {
            Self::from_json(value)
        }
    }

    /// Parses the compact Profile 1 public key format. The profile fixes the
    /// RSA exponent and DER wrapper, so the wire value carries only the
    /// 3072-bit modulus plus a four-byte key-ID checksum.
    pub fn from_compact(input: &str) -> Result<Self> {
        let value = input.trim();
        let encoded =
            value
                .strip_prefix(COMPACT_PUBLIC_KEY_PREFIX)
                .ok_or(Error::InvalidPublicIdentity(
                    "invalid compact public key prefix",
                ))?;
        if encoded.is_empty()
            || encoded.contains('=')
            || !encoded
                .bytes()
                .all(|value| value.is_ascii_alphanumeric() || value == b'-' || value == b'_')
        {
            return Err(Error::InvalidPublicIdentity(
                "invalid compact public key encoding",
            ));
        }
        let payload = URL_SAFE_NO_PAD
            .decode(encoded.as_bytes())
            .map_err(|_| Error::InvalidPublicIdentity("invalid compact public key encoding"))?;
        if payload.len() != RSA_MODULUS_BYTES + COMPACT_CHECKSUM_BYTES
            || URL_SAFE_NO_PAD.encode(&payload) != encoded
        {
            return Err(Error::InvalidPublicIdentity(
                "invalid compact public key encoding",
            ));
        }
        if payload[RSA_MODULUS_BYTES - 1] & 1 == 0 {
            return Err(Error::InvalidPublicIdentity(
                "invalid compact RSA public key",
            ));
        }

        let public_key = RsaPublicKey::new(
            rsa::BigUint::from_bytes_be(&payload[..RSA_MODULUS_BYTES]),
            rsa::BigUint::from(RSA_EXPONENT),
        )
        .map_err(|_| Error::InvalidPublicIdentity("invalid compact RSA public key"))?;
        if public_key.n().bits() != RSA_BITS {
            return Err(Error::InvalidPublicIdentity(
                "invalid compact RSA public key",
            ));
        }
        let spki_der = public_key
            .to_public_key_der()
            .map_err(|_| Error::InvalidPublicIdentity("invalid compact RSA public key"))?;
        let identity = Self::from_spki_der(spki_der.as_bytes())?;
        if identity.recipient_key_id[..COMPACT_CHECKSUM_BYTES] != payload[RSA_MODULUS_BYTES..] {
            return Err(Error::InvalidPublicIdentity(
                "compact public key checksum mismatch",
            ));
        }
        Ok(identity)
    }

    /// Parses and strictly validates a copied `SBOX-PUBLIC-IDENTITY-1` JSON
    /// document.
    pub fn from_json(input: &str) -> Result<Self> {
        let wire: WirePublicIdentity = serde_json::from_str(input)?;
        if wire.schema != PUBLIC_IDENTITY_SCHEMA || wire.key_profile_id != KEY_PROFILE_ID {
            return Err(Error::InvalidPublicIdentity("unsupported identity profile"));
        }
        if wire.spki_der.is_empty()
            || wire.spki_der.contains('=')
            || !wire
                .spki_der
                .bytes()
                .all(|value| value.is_ascii_alphanumeric() || value == b'-' || value == b'_')
        {
            return Err(Error::InvalidPublicIdentity("non-canonical SPKI encoding"));
        }
        let spki_der = URL_SAFE_NO_PAD
            .decode(wire.spki_der.as_bytes())
            .map_err(|_| Error::InvalidPublicIdentity("invalid SPKI encoding"))?;
        if URL_SAFE_NO_PAD.encode(&spki_der) != wire.spki_der {
            return Err(Error::InvalidPublicIdentity("non-canonical SPKI encoding"));
        }
        if wire.recipient_key_id.len() != 64
            || !wire
                .recipient_key_id
                .bytes()
                .all(|value| value.is_ascii_digit() || (b'a'..=b'f').contains(&value))
        {
            return Err(Error::InvalidPublicIdentity("invalid recipient key ID"));
        }
        let key_id = hex::decode(&wire.recipient_key_id)
            .map_err(|_| Error::InvalidPublicIdentity("invalid recipient key ID"))?;
        let mut recipient_key_id = [0_u8; 32];
        recipient_key_id.copy_from_slice(&key_id);
        Self::from_parts(spki_der, recipient_key_id)
    }

    /// Builds an identity from canonical RSA SubjectPublicKeyInfo DER. The
    /// recipient key ID is derived as SHA-256 over the complete DER bytes.
    pub fn from_spki_der(spki_der: &[u8]) -> Result<Self> {
        let digest = Sha256::digest(spki_der);
        let mut recipient_key_id = [0_u8; 32];
        recipient_key_id.copy_from_slice(&digest);
        Self::from_parts(spki_der.to_vec(), recipient_key_id)
    }

    fn from_parts(spki_der: Vec<u8>, recipient_key_id: [u8; 32]) -> Result<Self> {
        let public_key = RsaPublicKey::from_public_key_der(&spki_der)
            .map_err(|_| Error::InvalidPublicIdentity("invalid RSA SPKI DER"))?;
        if public_key.n().bits() != RSA_BITS || public_key.e() != &rsa::BigUint::from(RSA_EXPONENT)
        {
            return Err(Error::InvalidPublicIdentity("RSA key is not Profile 1"));
        }
        let canonical = public_key
            .to_public_key_der()
            .map_err(|_| Error::InvalidPublicIdentity("invalid RSA SPKI DER"))?;
        if canonical.as_bytes() != spki_der {
            return Err(Error::InvalidPublicIdentity("non-canonical RSA SPKI DER"));
        }
        let derived = Sha256::digest(&spki_der);
        if derived.as_slice() != recipient_key_id {
            return Err(Error::InvalidPublicIdentity("recipient key ID mismatch"));
        }
        Ok(Self {
            spki_der,
            recipient_key_id,
            public_key,
        })
    }

    /// Returns the canonical SubjectPublicKeyInfo DER bytes.
    pub fn spki_der(&self) -> &[u8] {
        &self.spki_der
    }

    /// Returns the binary SHA-256 recipient key ID.
    pub fn recipient_key_id(&self) -> &[u8; 32] {
        &self.recipient_key_id
    }

    /// Returns the lowercase hexadecimal recipient key ID.
    pub fn recipient_key_id_hex(&self) -> String {
        hex::encode(self.recipient_key_id)
    }

    /// Encodes the identity as the compact single-line format copied by the
    /// SafeBox app.
    pub fn to_compact(&self) -> String {
        let modulus = self.public_key.n().to_bytes_be();
        debug_assert_eq!(modulus.len(), RSA_MODULUS_BYTES);
        let mut payload = Vec::with_capacity(RSA_MODULUS_BYTES + COMPACT_CHECKSUM_BYTES);
        payload.extend_from_slice(&modulus);
        payload.extend_from_slice(&self.recipient_key_id[..COMPACT_CHECKSUM_BYTES]);
        format!(
            "{COMPACT_PUBLIC_KEY_PREFIX}{}",
            URL_SAFE_NO_PAD.encode(payload)
        )
    }

    /// Re-encodes the identity as the legacy public-identity JSON document.
    pub fn to_json(&self) -> Result<String> {
        Ok(serde_json::to_string(&WirePublicIdentity {
            schema: PUBLIC_IDENTITY_SCHEMA.to_owned(),
            key_profile_id: KEY_PROFILE_ID,
            spki_der: URL_SAFE_NO_PAD.encode(&self.spki_der),
            recipient_key_id: self.recipient_key_id_hex(),
        })?)
    }

    pub(crate) fn rsa_public_key(&self) -> &RsaPublicKey {
        &self.public_key
    }
}
