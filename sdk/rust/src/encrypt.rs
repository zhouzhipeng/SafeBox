use std::{
    fs::{self, File},
    io::{Cursor, Read, Write},
    path::{Path, PathBuf},
};

use md5::Md5;
use rand::{CryptoRng, RngCore, rngs::OsRng};
use sha2::{Digest, Sha256};
use tempfile::NamedTempFile;
use zeroize::{Zeroize, Zeroizing};

use crate::{
    Error, Result,
    identity::PublicIdentity,
    manifest::{ContentKind, EncryptOptions, Manifest, ValidatedMetadata},
    wire::{self, ShardPlan},
};

/// One encrypted SBOX object returned by [`encrypt_bytes`].
#[derive(Clone, Debug)]
pub struct EncryptedObject {
    /// Zero-based shard index.
    pub shard_index: u32,
    /// Canonical `.sbox` basename.
    pub basename: String,
    /// Complete header and encrypted records.
    pub bytes: Vec<u8>,
    /// SHA-256 of `bytes`.
    pub sha256: [u8; 32],
}

/// In-memory result from [`encrypt_bytes`].
#[derive(Clone, Debug)]
pub struct EncryptedBundle {
    /// Canonical encrypted Manifest.
    pub manifest: Manifest,
    /// Objects in increasing shard-index order; index zero is the root.
    pub objects: Vec<EncryptedObject>,
    /// SHA-256 of the complete logical plaintext.
    pub plaintext_sha256: [u8; 32],
}

/// One immutable object written by [`encrypt_file`].
#[derive(Clone, Debug)]
pub struct WrittenObject {
    /// Zero-based shard index.
    pub shard_index: u32,
    /// Canonical destination path.
    pub path: PathBuf,
}

/// Streaming file result from [`encrypt_file`].
#[derive(Clone, Debug)]
pub struct WrittenBundle {
    /// Canonical encrypted Manifest.
    pub manifest: Manifest,
    /// Objects in increasing shard-index order; index zero is the root.
    pub objects: Vec<WrittenObject>,
    /// SHA-256 of the complete logical plaintext.
    pub plaintext_sha256: [u8; 32],
}

/// Encrypts an in-memory plaintext using operating-system cryptographic
/// randomness and returns one or more complete SBOX 3.1 objects.
pub fn encrypt_bytes(
    identity: &PublicIdentity,
    plaintext: &[u8],
    options: &EncryptOptions,
) -> Result<EncryptedBundle> {
    encrypt_bytes_with_rng(identity, plaintext, options, &mut OsRng)
}

/// Same as [`encrypt_bytes`], but obtains all randomness from `rng`.
///
/// Production callers should normally use [`encrypt_bytes`]. This overload is
/// useful for controlled environments and protocol-vector tests; its RNG must
/// be cryptographically secure and must never repeat its state.
pub fn encrypt_bytes_with_rng<R: RngCore + CryptoRng>(
    identity: &PublicIdentity,
    plaintext: &[u8],
    options: &EncryptOptions,
    rng: &mut R,
) -> Result<EncryptedBundle> {
    let metadata = ValidatedMetadata::from_options(options)?;
    if options.content_kind == ContentKind::Text && std::str::from_utf8(plaintext).is_err() {
        return Err(Error::InvalidOptions("text plaintext is not strict UTF-8"));
    }
    let length =
        u64::try_from(plaintext.len()).map_err(|_| Error::InvalidOptions("input is too large"))?;
    let summary = HashSummary::from_bytes(plaintext);
    let shards = wire::plan_shards(length, metadata.nominal_shard_size)?;
    let prepared = PreparedBundle::new(identity, summary, &shards, metadata, rng)?;
    let mut reader = Cursor::new(plaintext);
    let mut objects = Vec::with_capacity(shards.len());
    for shard in &shards {
        if reader.position() != shard.offset {
            return Err(Error::Crypto);
        }
        let header = prepared.header_for(*shard)?;
        let data_records = if shard.length == 0 {
            0
        } else {
            shard.length.div_ceil(wire::CHUNK_SIZE as u64)
        };
        let estimated = u64::try_from(header.len())
            .ok()
            .and_then(|value| value.checked_add(shard.length))
            .and_then(|value| value.checked_add(data_records.checked_mul(29)?))
            .and_then(|value| value.checked_add(77))
            .and_then(|value| usize::try_from(value).ok())
            .ok_or(Error::InvalidOptions("encrypted object is too large"))?;
        let mut bytes = Vec::with_capacity(estimated);
        write_shard(&mut reader, &mut bytes, *shard, &header, &prepared, None)?;
        let basename =
            wire::canonical_basename(&prepared.bundle_id, shard.index, shards.len() as u32);
        objects.push(EncryptedObject {
            shard_index: shard.index,
            basename,
            sha256: wire::sha256(&bytes),
            bytes,
        });
    }
    if reader.position() != length {
        return Err(Error::Crypto);
    }
    Ok(EncryptedBundle {
        manifest: prepared.manifest.clone(),
        objects,
        plaintext_sha256: summary.sha256,
    })
}

/// Streams a source file through two integrity passes and atomically writes
/// immutable SBOX 3.1 objects into `output_directory`.
///
/// Existing destination objects are never overwritten. Continuation shards
/// are committed before the root object so the root acts as the publication
/// point for multipart Bundles.
pub fn encrypt_file(
    identity: &PublicIdentity,
    source: impl AsRef<Path>,
    output_directory: impl AsRef<Path>,
    options: &EncryptOptions,
) -> Result<WrittenBundle> {
    encrypt_file_with_rng(identity, source, output_directory, options, &mut OsRng)
}

/// Same as [`encrypt_file`], but obtains all randomness from `rng`.
///
/// Production callers should normally use [`encrypt_file`]. The supplied RNG
/// must be cryptographically secure and must never repeat its state.
pub fn encrypt_file_with_rng<R: RngCore + CryptoRng>(
    identity: &PublicIdentity,
    source: impl AsRef<Path>,
    output_directory: impl AsRef<Path>,
    options: &EncryptOptions,
    rng: &mut R,
) -> Result<WrittenBundle> {
    let source = source.as_ref();
    let output_directory = output_directory.as_ref();
    let metadata = ValidatedMetadata::from_options(options)?;
    let mut first_input = File::open(source)?;
    let declared_length = first_input.metadata()?.len();
    let first_pass = hash_reader(
        &mut first_input,
        declared_length,
        options.content_kind == ContentKind::Text,
    )?;
    if first_input.metadata()?.len() != declared_length {
        return Err(Error::InputChanged);
    }
    let shards = wire::plan_shards(declared_length, metadata.nominal_shard_size)?;
    let prepared = PreparedBundle::new(identity, first_pass, &shards, metadata, rng)?;

    fs::create_dir_all(output_directory)?;
    let destinations: Vec<PathBuf> = shards
        .iter()
        .map(|shard| {
            output_directory.join(wire::canonical_basename(
                &prepared.bundle_id,
                shard.index,
                shards.len() as u32,
            ))
        })
        .collect();
    for destination in &destinations {
        if destination.exists() {
            return Err(Error::OutputExists(destination.clone()));
        }
    }

    let mut second_input = File::open(source)?;
    let mut second_pass = RunningHashes::new();
    let mut staged = Vec::with_capacity(shards.len());
    for (position, shard) in shards.iter().enumerate() {
        if second_pass.length != shard.offset {
            return Err(Error::InputChanged);
        }
        let header = prepared.header_for(*shard)?;
        let mut temporary = NamedTempFile::new_in(output_directory)?;
        write_shard(
            &mut second_input,
            &mut temporary,
            *shard,
            &header,
            &prepared,
            Some(&mut second_pass),
        )?;
        temporary.as_file_mut().sync_all()?;
        staged.push(StagedObject {
            temporary: Some(temporary),
            destination: destinations[position].clone(),
        });
    }
    let mut extra = [0_u8; 1];
    if second_input.read(&mut extra)? != 0 || second_input.metadata()?.len() != declared_length {
        return Err(Error::InputChanged);
    }
    let second_pass = second_pass.finish();
    if second_pass != first_pass {
        return Err(Error::InputChanged);
    }

    let mut commit_order: Vec<usize> = (1..staged.len()).collect();
    commit_order.push(0);
    let mut committed = Vec::<PathBuf>::new();
    for position in commit_order {
        let temporary = staged[position].temporary.take().ok_or(Error::Crypto)?;
        match temporary.persist_noclobber(&staged[position].destination) {
            Ok(file) => {
                drop(file);
                committed.push(staged[position].destination.clone());
            }
            Err(error) => {
                for path in &committed {
                    let _ = fs::remove_file(path);
                }
                if error.error.kind() == std::io::ErrorKind::AlreadyExists {
                    return Err(Error::OutputExists(staged[position].destination.clone()));
                }
                return Err(Error::Io(error.error));
            }
        }
    }
    Ok(WrittenBundle {
        manifest: prepared.manifest.clone(),
        objects: destinations
            .into_iter()
            .enumerate()
            .map(|(index, path)| WrittenObject {
                shard_index: index as u32,
                path,
            })
            .collect(),
        plaintext_sha256: first_pass.sha256,
    })
}

struct StagedObject {
    temporary: Option<NamedTempFile>,
    destination: PathBuf,
}

struct PreparedBundle {
    manifest: Manifest,
    bundle_id: [u8; 16],
    recipient_key_id: [u8; 32],
    bundle_dek: Zeroizing<[u8; 32]>,
    nonce_prefixes: Vec<[u8; 4]>,
    root_header: Vec<u8>,
}

impl PreparedBundle {
    fn new<R: RngCore + CryptoRng>(
        identity: &PublicIdentity,
        summary: HashSummary,
        shards: &[ShardPlan],
        metadata: ValidatedMetadata,
        rng: &mut R,
    ) -> Result<Self> {
        let shard_count = u32::try_from(shards.len()).map_err(|_| Error::Crypto)?;
        let manifest = Manifest::new(
            summary.md5,
            *identity.recipient_key_id(),
            summary.sha256,
            summary.length,
            shard_count,
            metadata,
        )?;
        let manifest_bytes = manifest.canonical_json()?;
        let mut metadata_block = Zeroizing::new(wire::metadata_block(&manifest_bytes)?);
        let mut bundle_dek = Zeroizing::new([0_u8; 32]);
        rng.fill_bytes(&mut *bundle_dek);
        let mut nonce_prefixes = Vec::with_capacity(shards.len());
        for _ in shards {
            let mut prefix = [0_u8; 4];
            rng.fill_bytes(&mut prefix);
            nonce_prefixes.push(prefix);
        }
        let wrapped_bundle_dek = wire::wrap_bundle_dek(identity, &summary.md5, &bundle_dek, rng)?;
        let mut metadata_salt = [0_u8; 32];
        let mut metadata_nonce = [0_u8; 12];
        rng.fill_bytes(&mut metadata_salt);
        rng.fill_bytes(&mut metadata_nonce);
        let placeholder = wire::build_root_header(
            &summary.md5,
            shard_count,
            shards.first().ok_or(Error::Crypto)?.length,
            identity.recipient_key_id(),
            nonce_prefixes.first().ok_or(Error::Crypto)?,
            &wrapped_bundle_dek,
            &metadata_salt,
            &metadata_nonce,
            &vec![0_u8; wire::METADATA_BLOCK_LENGTH],
            &[0_u8; 16],
        )?;
        let aad = wire::metadata_aad(&placeholder[..576])?;
        let metadata_key = wire::derive_metadata_key(identity, &metadata_salt, &summary.md5)?;
        let metadata_tag =
            wire::encrypt_metadata(&metadata_key, &metadata_nonce, &mut metadata_block, &aad)?;
        let root_header = wire::build_root_header(
            &summary.md5,
            shard_count,
            shards[0].length,
            identity.recipient_key_id(),
            &nonce_prefixes[0],
            &wrapped_bundle_dek,
            &metadata_salt,
            &metadata_nonce,
            &metadata_block,
            &metadata_tag,
        )?;
        metadata_salt.zeroize();
        metadata_nonce.zeroize();
        Ok(Self {
            manifest,
            bundle_id: summary.md5,
            recipient_key_id: *identity.recipient_key_id(),
            bundle_dek,
            nonce_prefixes,
            root_header,
        })
    }

    fn header_for(&self, shard: ShardPlan) -> Result<Vec<u8>> {
        if shard.index == 0 {
            return Ok(self.root_header.clone());
        }
        wire::build_continuation_header(
            &self.bundle_id,
            shard.index,
            self.nonce_prefixes.len() as u32,
            shard.length,
            &self.recipient_key_id,
            &self.nonce_prefixes[shard.index as usize],
        )
    }
}

#[allow(clippy::too_many_arguments)]
fn write_shard<R: Read, W: Write>(
    reader: &mut R,
    output: &mut W,
    shard: ShardPlan,
    header: &[u8],
    prepared: &PreparedBundle,
    mut complete_hashes: Option<&mut RunningHashes>,
) -> Result<()> {
    output.write_all(header)?;
    let header_hash = wire::sha256(header);
    let shard_key = wire::derive_shard_key(
        &prepared.bundle_dek,
        &prepared.bundle_id,
        &prepared.recipient_key_id,
        shard.index,
    )?;
    let nonce_prefix = prepared
        .nonce_prefixes
        .get(shard.index as usize)
        .ok_or(Error::Crypto)?;
    let capacity =
        usize::try_from(shard.length.min(wire::CHUNK_SIZE as u64)).map_err(|_| Error::Crypto)?;
    let mut buffer = Zeroizing::new(vec![0_u8; capacity]);
    let mut shard_hash = Sha256::new();
    let mut remaining = shard.length;
    let mut data_records = 0_u64;
    while remaining > 0 {
        let take =
            usize::try_from(remaining.min(wire::CHUNK_SIZE as u64)).map_err(|_| Error::Crypto)?;
        read_exact_input(reader, &mut buffer[..take])?;
        shard_hash.update(&buffer[..take]);
        if let Some(hashes) = complete_hashes.as_deref_mut() {
            hashes.update(&buffer[..take]);
        }
        data_records = data_records.checked_add(1).ok_or(Error::Crypto)?;
        let (record_header, tag) = wire::encrypt_record(
            0x02,
            data_records,
            &mut buffer[..take],
            &shard_key,
            nonce_prefix,
            &header_hash,
        )?;
        output.write_all(&record_header)?;
        output.write_all(&buffer[..take])?;
        output.write_all(&tag)?;
        remaining -= take as u64;
    }
    let digest = shard_hash.finalize();
    let mut final_plaintext = Zeroizing::new([0_u8; 48]);
    final_plaintext[0..8].copy_from_slice(&shard.length.to_be_bytes());
    final_plaintext[8..16].copy_from_slice(&data_records.to_be_bytes());
    final_plaintext[16..48].copy_from_slice(&digest);
    let final_index = data_records.checked_add(1).ok_or(Error::Crypto)?;
    let (record_header, tag) = wire::encrypt_record(
        0xff,
        final_index,
        &mut final_plaintext[..],
        &shard_key,
        nonce_prefix,
        &header_hash,
    )?;
    output.write_all(&record_header)?;
    output.write_all(&final_plaintext[..])?;
    output.write_all(&tag)?;
    output.flush()?;
    Ok(())
}

fn read_exact_input(reader: &mut impl Read, buffer: &mut [u8]) -> Result<()> {
    match reader.read_exact(buffer) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => Err(Error::InputChanged),
        Err(error) => Err(Error::Io(error)),
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct HashSummary {
    length: u64,
    md5: [u8; 16],
    sha256: [u8; 32],
}

impl HashSummary {
    fn from_bytes(bytes: &[u8]) -> Self {
        let md5 = Md5::digest(bytes);
        let sha256 = Sha256::digest(bytes);
        let mut result = Self {
            length: bytes.len() as u64,
            md5: [0_u8; 16],
            sha256: [0_u8; 32],
        };
        result.md5.copy_from_slice(&md5);
        result.sha256.copy_from_slice(&sha256);
        result
    }
}

struct RunningHashes {
    length: u64,
    md5: Md5,
    sha256: Sha256,
}

impl RunningHashes {
    fn new() -> Self {
        Self {
            length: 0,
            md5: Md5::new(),
            sha256: Sha256::new(),
        }
    }

    fn update(&mut self, bytes: &[u8]) {
        self.length += bytes.len() as u64;
        self.md5.update(bytes);
        self.sha256.update(bytes);
    }

    fn finish(self) -> HashSummary {
        let md5 = self.md5.finalize();
        let sha256 = self.sha256.finalize();
        let mut result = HashSummary {
            length: self.length,
            md5: [0_u8; 16],
            sha256: [0_u8; 32],
        };
        result.md5.copy_from_slice(&md5);
        result.sha256.copy_from_slice(&sha256);
        result
    }
}

fn hash_reader(
    reader: &mut impl Read,
    declared_length: u64,
    validate_utf8: bool,
) -> Result<HashSummary> {
    let mut hashes = RunningHashes::new();
    let mut utf8 = Utf8Validator::new(validate_utf8);
    let mut buffer = vec![0_u8; 64 * 1024];
    loop {
        let count = reader.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        utf8.update(&buffer[..count])?;
        hashes.update(&buffer[..count]);
        if hashes.length > declared_length {
            buffer.zeroize();
            return Err(Error::InputChanged);
        }
    }
    buffer.zeroize();
    utf8.finish()?;
    let result = hashes.finish();
    if result.length != declared_length {
        return Err(Error::InputChanged);
    }
    Ok(result)
}

struct Utf8Validator {
    enabled: bool,
    pending: Vec<u8>,
}

impl Utf8Validator {
    fn new(enabled: bool) -> Self {
        Self {
            enabled,
            pending: Vec::new(),
        }
    }

    fn update(&mut self, input: &[u8]) -> Result<()> {
        if !self.enabled {
            return Ok(());
        }
        let mut combined = Vec::with_capacity(self.pending.len() + input.len());
        combined.extend_from_slice(&self.pending);
        combined.extend_from_slice(input);
        self.pending.clear();
        match std::str::from_utf8(&combined) {
            Ok(_) => Ok(()),
            Err(error) if error.error_len().is_some() => {
                Err(Error::InvalidOptions("text plaintext is not strict UTF-8"))
            }
            Err(error) => {
                let tail = &combined[error.valid_up_to()..];
                if tail.len() > 3 {
                    return Err(Error::InvalidOptions("text plaintext is not strict UTF-8"));
                }
                self.pending.extend_from_slice(tail);
                Ok(())
            }
        }
    }

    fn finish(self) -> Result<()> {
        if self.enabled && !self.pending.is_empty() {
            return Err(Error::InvalidOptions("text plaintext is not strict UTF-8"));
        }
        Ok(())
    }
}
