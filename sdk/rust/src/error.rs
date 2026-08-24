use std::path::PathBuf;

/// Errors returned by the SafeBox SDK.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// The copied public identity is malformed or unsupported.
    #[error("invalid SafeBox public identity: {0}")]
    InvalidPublicIdentity(&'static str),

    /// An encryption option violates the SBOX profile.
    #[error("invalid encryption option: {0}")]
    InvalidOptions(&'static str),

    /// The source changed while its two streaming passes were running.
    #[error("the input changed while it was being encrypted")]
    InputChanged,

    /// The generated Manifest cannot fit in the fixed Metadata Block.
    #[error("the SBOX Manifest exceeds the protocol size limit")]
    ManifestTooLarge,

    /// A cryptographic primitive rejected an otherwise validated operation.
    #[error("a cryptographic operation failed")]
    Crypto,

    /// Immutable output is already present and will not be overwritten.
    #[error("SBOX output already exists: {0}")]
    OutputExists(PathBuf),

    /// JSON decoding failed.
    #[error(transparent)]
    Json(#[from] serde_json::Error),

    /// A filesystem operation failed.
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

/// Result type used by the SafeBox SDK.
pub type Result<T> = std::result::Result<T, Error>;
