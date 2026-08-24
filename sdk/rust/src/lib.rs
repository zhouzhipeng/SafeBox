//! SafeBox public-key encryption SDK for Rust.
//!
//! The crate accepts the compact `sboxpk1:` public key copied by the SafeBox
//! app (and the legacy `SBOX-PUBLIC-IDENTITY-1` JSON) and writes SBOX 3.1 /
//! Metadata Format 2 Bundles. Only public key material is needed to encrypt.
//! Recovery words and private keys are never accepted by this API.
//!
//! The current SDK writer deliberately omits the optional JPEG Preview record;
//! the resulting Metadata Block is still a complete, canonical SBOX 3.1 block.

#![forbid(unsafe_code)]

mod encrypt;
mod error;
mod identity;
mod manifest;
mod wire;

pub use encrypt::{
    EncryptedBundle, EncryptedObject, WrittenBundle, WrittenObject, encrypt_bytes,
    encrypt_bytes_with_rng, encrypt_file, encrypt_file_with_rng,
};
pub use error::{Error, Result};
pub use identity::PublicIdentity;
pub use manifest::{ContentKind, EncryptOptions, Manifest};

/// Default plaintext shard target used by [`EncryptOptions::new`] (16 MiB).
pub const DEFAULT_NOMINAL_SHARD_SIZE: u64 = wire::DEFAULT_NOMINAL_SHARD_SIZE;

/// Smallest protocol-compliant plaintext shard target (1 MiB).
pub const MIN_NOMINAL_SHARD_SIZE: u64 = wire::MIN_NOMINAL_SHARD_SIZE;

/// Largest protocol-compliant plaintext shard target (512 MiB).
pub const MAX_NOMINAL_SHARD_SIZE: u64 = wire::MAX_NOMINAL_SHARD_SIZE;

#[cfg(test)]
mod tests;
