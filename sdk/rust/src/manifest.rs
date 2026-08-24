use std::collections::{BTreeMap, HashSet};

use chrono::{NaiveDateTime, Utc};
use serde_json::Value;
use unicode_normalization::UnicodeNormalization;

use crate::{Error, Result, wire};

/// The logical content kind recorded in the SBOX Manifest.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ContentKind {
    /// Arbitrary file bytes.
    File,
    /// Strict UTF-8 text bytes.
    Text,
}

impl ContentKind {
    pub(crate) const fn wire_name(self) -> &'static str {
        match self {
            Self::File => "file",
            Self::Text => "text",
        }
    }
}

/// Metadata and sharding options for an encryption operation.
#[derive(Clone, Debug)]
pub struct EncryptOptions {
    /// Whether the plaintext represents a file or strict UTF-8 text.
    pub content_kind: ContentKind,
    /// Basename shown after decryption. Directory separators are forbidden.
    pub original_name: String,
    /// Printable-ASCII media type, for example `application/pdf`.
    pub media_type: String,
    /// Display title. When omitted, `original_name` is used.
    pub title: Option<String>,
    /// Optional user description.
    pub description: String,
    /// User tags. The SDK rejects duplicates and writes them in canonical
    /// UTF-8 byte order.
    pub tags: Vec<String>,
    /// UTC timestamp with second precision (`YYYY-MM-DDTHH:MM:SSZ`). The
    /// current UTC time is used when omitted.
    pub created_at: Option<String>,
    /// Target plaintext bytes per shard. Must be a whole MiB between 1 MiB
    /// and 512 MiB.
    pub target_nominal_shard_size: u64,
}

impl EncryptOptions {
    /// Creates file options with safe defaults and a 16 MiB shard target.
    pub fn new(original_name: impl Into<String>, media_type: impl Into<String>) -> Self {
        Self {
            content_kind: ContentKind::File,
            original_name: original_name.into(),
            media_type: media_type.into(),
            title: None,
            description: String::new(),
            tags: Vec::new(),
            created_at: None,
            target_nominal_shard_size: wire::DEFAULT_NOMINAL_SHARD_SIZE,
        }
    }
}

/// The canonical `SBOX-MANIFEST-3` metadata embedded in the root object.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Manifest {
    /// Lowercase MD5 content address.
    pub bundle_id: String,
    /// Lowercase SHA-256 recipient key ID.
    pub recipient_key_id: String,
    /// File or text content kind.
    pub content_kind: ContentKind,
    /// Original basename.
    pub original_name: String,
    /// Printable-ASCII media type.
    pub media_type: String,
    /// Display title.
    pub title: String,
    /// User description.
    pub description: String,
    /// Canonically ordered tags.
    pub tags: Vec<String>,
    /// UTC creation time at second precision.
    pub created_at: String,
    /// Complete plaintext length.
    pub logical_plaintext_size: u64,
    /// Complete plaintext SHA-256 as lowercase hexadecimal.
    pub logical_plaintext_sha256: String,
    /// Nominal plaintext size of each shard.
    pub nominal_shard_plaintext_size: u64,
    /// Number of SBOX objects in this Bundle.
    pub shard_count: u32,
}

impl Manifest {
    pub(crate) fn new(
        bundle_id: [u8; 16],
        recipient_key_id: [u8; 32],
        plaintext_sha256: [u8; 32],
        plaintext_size: u64,
        shard_count: u32,
        metadata: ValidatedMetadata,
    ) -> Result<Self> {
        let manifest = Self {
            bundle_id: hex::encode(bundle_id),
            recipient_key_id: hex::encode(recipient_key_id),
            content_kind: metadata.content_kind,
            original_name: metadata.original_name,
            media_type: metadata.media_type,
            title: metadata.title,
            description: metadata.description,
            tags: metadata.tags,
            created_at: metadata.created_at,
            logical_plaintext_size: plaintext_size,
            logical_plaintext_sha256: hex::encode(plaintext_sha256),
            nominal_shard_plaintext_size: metadata.nominal_shard_size,
            shard_count,
        };
        if manifest.canonical_json()?.len() > wire::MAX_MANIFEST_BYTES {
            return Err(Error::ManifestTooLarge);
        }
        Ok(manifest)
    }

    /// Returns the exact canonical UTF-8 JSON bytes encrypted into Metadata.
    pub fn canonical_json(&self) -> Result<Vec<u8>> {
        let mut value = BTreeMap::<String, Value>::new();
        value.insert("schema".into(), Value::String("SBOX-MANIFEST-3".into()));
        value.insert("bundle_id".into(), Value::String(self.bundle_id.clone()));
        value.insert(
            "recipient_key_id".into(),
            Value::String(self.recipient_key_id.clone()),
        );
        value.insert(
            "content_kind".into(),
            Value::String(self.content_kind.wire_name().into()),
        );
        value.insert(
            "original_name".into(),
            Value::String(self.original_name.clone()),
        );
        value.insert("media_type".into(), Value::String(self.media_type.clone()));
        value.insert("title".into(), Value::String(self.title.clone()));
        value.insert(
            "description".into(),
            Value::String(self.description.clone()),
        );
        value.insert(
            "tags".into(),
            Value::Array(self.tags.iter().cloned().map(Value::String).collect()),
        );
        value.insert("created_at".into(), Value::String(self.created_at.clone()));
        value.insert(
            "logical_plaintext_size".into(),
            Value::String(self.logical_plaintext_size.to_string()),
        );
        value.insert(
            "logical_plaintext_sha256".into(),
            Value::String(self.logical_plaintext_sha256.clone()),
        );
        value.insert(
            "nominal_shard_plaintext_size".into(),
            Value::String(self.nominal_shard_plaintext_size.to_string()),
        );
        value.insert("shard_count".into(), Value::from(self.shard_count));
        Ok(serde_json::to_vec(&value)?)
    }
}

#[derive(Clone, Debug)]
pub(crate) struct ValidatedMetadata {
    pub(crate) content_kind: ContentKind,
    pub(crate) original_name: String,
    pub(crate) media_type: String,
    pub(crate) title: String,
    pub(crate) description: String,
    pub(crate) tags: Vec<String>,
    pub(crate) created_at: String,
    pub(crate) nominal_shard_size: u64,
}

impl ValidatedMetadata {
    pub(crate) fn from_options(options: &EncryptOptions) -> Result<Self> {
        if options.target_nominal_shard_size < wire::MIN_NOMINAL_SHARD_SIZE
            || options.target_nominal_shard_size > wire::MAX_NOMINAL_SHARD_SIZE
            || options.target_nominal_shard_size % (1024 * 1024) != 0
        {
            return Err(Error::InvalidOptions("invalid nominal shard size"));
        }
        validate_nfc(&options.original_name, 1024, "original name")?;
        if options.original_name.is_empty()
            || options.original_name == "."
            || options.original_name == ".."
            || options.original_name.contains('\0')
            || options.original_name.contains('/')
            || options.original_name.contains('\\')
        {
            return Err(Error::InvalidOptions("invalid original name"));
        }
        if options.media_type.len() > 255
            || !options
                .media_type
                .bytes()
                .all(|value| (0x20..=0x7e).contains(&value))
        {
            return Err(Error::InvalidOptions("invalid media type"));
        }
        let title = options
            .title
            .clone()
            .unwrap_or_else(|| options.original_name.clone());
        validate_nfc(&title, 256, "title")?;
        if title.is_empty()
            || title
                .chars()
                .any(|value| matches!(value as u32, 0..=0x1f | 0x7f..=0x9f))
        {
            return Err(Error::InvalidOptions("invalid title"));
        }
        validate_nfc(&options.description, 4096, "description")?;
        if options.description.contains('\0') {
            return Err(Error::InvalidOptions("invalid description"));
        }
        if options.tags.len() > 32 {
            return Err(Error::InvalidOptions("too many tags"));
        }
        let mut tags = options.tags.clone();
        let unique: HashSet<&str> = tags.iter().map(String::as_str).collect();
        if unique.len() != tags.len() {
            return Err(Error::InvalidOptions("duplicate tags"));
        }
        for tag in &tags {
            validate_nfc(tag, 64, "tag")?;
            if tag.is_empty() {
                return Err(Error::InvalidOptions("empty tag"));
            }
        }
        tags.sort_by(|left, right| left.as_bytes().cmp(right.as_bytes()));
        let created_at = options
            .created_at
            .clone()
            .unwrap_or_else(|| Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string());
        validate_timestamp(&created_at)?;
        Ok(Self {
            content_kind: options.content_kind,
            original_name: options.original_name.clone(),
            media_type: options.media_type.clone(),
            title,
            description: options.description.clone(),
            tags,
            created_at,
            nominal_shard_size: options.target_nominal_shard_size,
        })
    }
}

fn validate_nfc(value: &str, max_bytes: usize, field: &'static str) -> Result<()> {
    if value.len() > max_bytes || value.nfc().collect::<String>() != value {
        return Err(Error::InvalidOptions(field));
    }
    Ok(())
}

fn validate_timestamp(value: &str) -> Result<()> {
    let bytes = value.as_bytes();
    let punctuation = [
        (4, b'-'),
        (7, b'-'),
        (10, b'T'),
        (13, b':'),
        (16, b':'),
        (19, b'Z'),
    ];
    if bytes.len() != 20
        || punctuation
            .iter()
            .any(|(index, expected)| bytes[*index] != *expected)
        || bytes.iter().enumerate().any(|(index, byte)| {
            !punctuation.iter().any(|(position, _)| *position == index) && !byte.is_ascii_digit()
        })
        || NaiveDateTime::parse_from_str(value, "%Y-%m-%dT%H:%M:%SZ").is_err()
    {
        return Err(Error::InvalidOptions("invalid creation timestamp"));
    }
    Ok(())
}
