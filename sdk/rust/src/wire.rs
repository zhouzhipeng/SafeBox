use aes_gcm::{
    Aes256Gcm, Nonce,
    aead::{AeadInPlace, KeyInit},
};
use hkdf::Hkdf;
use rand::{CryptoRng, RngCore};
use rsa::{BigUint, traits::PublicKeyParts};
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, Zeroizing};

use crate::{Error, Result, identity::PublicIdentity};

pub(crate) const MAGIC: [u8; 8] = [0x53, 0x42, 0x4f, 0x58, 0x0d, 0x0a, 0x1a, 0x0a];
pub(crate) const VERSION_MAJOR: u8 = 3;
pub(crate) const VERSION_MINOR: u8 = 1;
pub(crate) const COMMON_HEADER_LENGTH: usize = 128;
pub(crate) const ROOT_HEADER_LENGTH: usize = 16_992;
pub(crate) const METADATA_BLOCK_LENGTH: usize = 16_400;
pub(crate) const MAX_MANIFEST_BYTES: usize = 16 * 1024;
pub(crate) const CHUNK_SIZE: usize = 4 * 1024 * 1024;
pub(crate) const MAX_SHARD_COUNT: u32 = 10_000;
pub(crate) const MIN_NOMINAL_SHARD_SIZE: u64 = 1024 * 1024;
pub(crate) const MAX_NOMINAL_SHARD_SIZE: u64 = 512 * 1024 * 1024;
pub(crate) const DEFAULT_NOMINAL_SHARD_SIZE: u64 = 16 * 1024 * 1024;

const METADATA_FORMAT_ID: u16 = 2;
const KEY_PROFILE_ID: u16 = 1;
const ROOT_KEY_WRAP_ALGORITHM: u16 = 1;
const PAYLOAD_ALGORITHM: u16 = 1;
const SHARD_KDF_ALGORITHM: u16 = 1;
const METADATA_KDF_ALGORITHM: u16 = 1;
const METADATA_AEAD_ALGORITHM: u16 = 1;
const WRAPPED_DEK_LENGTH: usize = 384;

#[derive(Clone, Copy, Debug)]
pub(crate) struct ShardPlan {
    pub(crate) index: u32,
    pub(crate) offset: u64,
    pub(crate) length: u64,
}

pub(crate) fn plan_shards(length: u64, nominal_size: u64) -> Result<Vec<ShardPlan>> {
    if !(MIN_NOMINAL_SHARD_SIZE..=MAX_NOMINAL_SHARD_SIZE).contains(&nominal_size)
        || nominal_size % (1024 * 1024) != 0
    {
        return Err(Error::InvalidOptions("invalid nominal shard size"));
    }
    let count = if length == 0 {
        1
    } else {
        length
            .checked_add(nominal_size - 1)
            .ok_or(Error::InvalidOptions("input is too large"))?
            / nominal_size
    };
    if count == 0 || count > u64::from(MAX_SHARD_COUNT) {
        return Err(Error::InvalidOptions("input requires too many shards"));
    }
    Ok((0..count)
        .map(|index| {
            let offset = index * nominal_size;
            ShardPlan {
                index: index as u32,
                offset,
                length: length.saturating_sub(offset).min(nominal_size),
            }
        })
        .collect())
}

pub(crate) fn canonical_basename(bundle_id: &[u8; 16], index: u32, count: u32) -> String {
    let id = hex::encode(bundle_id);
    if count == 1 {
        format!("{id}.sbox")
    } else {
        format!("{id}_{index}_{count}.sbox")
    }
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn build_root_header(
    bundle_id: &[u8; 16],
    shard_count: u32,
    shard_plaintext_size: u64,
    recipient_key_id: &[u8; 32],
    nonce_prefix: &[u8; 4],
    wrapped_bundle_dek: &[u8],
    metadata_salt: &[u8; 32],
    metadata_nonce: &[u8; 12],
    metadata_ciphertext: &[u8],
    metadata_tag: &[u8; 16],
) -> Result<Vec<u8>> {
    if wrapped_bundle_dek.len() != WRAPPED_DEK_LENGTH
        || metadata_ciphertext.len() != METADATA_BLOCK_LENGTH
        || shard_count == 0
        || shard_count > MAX_SHARD_COUNT
        || (shard_count > 1 && shard_plaintext_size == 0)
    {
        return Err(Error::Crypto);
    }
    let mut header = vec![0_u8; ROOT_HEADER_LENGTH];
    write_common_header(
        &mut header,
        true,
        bundle_id,
        0,
        shard_count,
        shard_plaintext_size,
        recipient_key_id,
        nonce_prefix,
        WRAPPED_DEK_LENGTH as u16,
    );
    header[128..512].copy_from_slice(wrapped_bundle_dek);
    header[512..516].copy_from_slice(b"META");
    put_u16(&mut header, 516, METADATA_FORMAT_ID);
    put_u16(&mut header, 518, METADATA_KDF_ALGORITHM);
    put_u16(&mut header, 520, METADATA_AEAD_ALGORITHM);
    put_u16(&mut header, 522, 0);
    put_u32(&mut header, 524, METADATA_BLOCK_LENGTH as u32);
    put_u32(&mut header, 528, METADATA_BLOCK_LENGTH as u32);
    header[532..564].copy_from_slice(metadata_salt);
    header[564..576].copy_from_slice(metadata_nonce);
    header[576..16_976].copy_from_slice(metadata_ciphertext);
    header[16_976..16_992].copy_from_slice(metadata_tag);
    Ok(header)
}

pub(crate) fn build_continuation_header(
    bundle_id: &[u8; 16],
    shard_index: u32,
    shard_count: u32,
    shard_plaintext_size: u64,
    recipient_key_id: &[u8; 32],
    nonce_prefix: &[u8; 4],
) -> Result<Vec<u8>> {
    if !(2..=MAX_SHARD_COUNT).contains(&shard_count)
        || shard_index == 0
        || shard_index >= shard_count
        || shard_plaintext_size == 0
    {
        return Err(Error::Crypto);
    }
    let mut header = vec![0_u8; COMMON_HEADER_LENGTH];
    write_common_header(
        &mut header,
        false,
        bundle_id,
        shard_index,
        shard_count,
        shard_plaintext_size,
        recipient_key_id,
        nonce_prefix,
        0,
    );
    Ok(header)
}

#[allow(clippy::too_many_arguments)]
fn write_common_header(
    header: &mut [u8],
    root: bool,
    bundle_id: &[u8; 16],
    shard_index: u32,
    shard_count: u32,
    shard_plaintext_size: u64,
    recipient_key_id: &[u8; 32],
    nonce_prefix: &[u8; 4],
    wrapped_length: u16,
) {
    header[0..8].copy_from_slice(&MAGIC);
    header[8] = VERSION_MAJOR;
    header[9] = VERSION_MINOR;
    put_u16(header, 10, header.len() as u16);
    put_u32(header, 12, u32::from(root));
    put_u16(header, 16, KEY_PROFILE_ID);
    put_u16(header, 18, if root { ROOT_KEY_WRAP_ALGORITHM } else { 0 });
    put_u16(header, 20, PAYLOAD_ALGORITHM);
    put_u16(header, 22, SHARD_KDF_ALGORITHM);
    put_u32(header, 24, CHUNK_SIZE as u32);
    header[28..44].copy_from_slice(bundle_id);
    put_u32(header, 44, shard_index);
    put_u32(header, 48, shard_count);
    put_u64(header, 52, shard_plaintext_size);
    header[60..92].copy_from_slice(recipient_key_id);
    header[92..96].copy_from_slice(nonce_prefix);
    put_u16(header, 96, wrapped_length);
}

pub(crate) fn metadata_block(manifest: &[u8]) -> Result<Vec<u8>> {
    if manifest.is_empty() || manifest.len() > MAX_MANIFEST_BYTES {
        return Err(Error::ManifestTooLarge);
    }
    let mut block = vec![0_u8; METADATA_BLOCK_LENGTH];
    block[0..8].copy_from_slice(b"SBOXMETA");
    put_u32(&mut block, 8, manifest.len() as u32);
    block[12..12 + manifest.len()].copy_from_slice(manifest);
    Ok(block)
}

pub(crate) fn metadata_aad(root_header_prefix: &[u8]) -> Result<Vec<u8>> {
    if root_header_prefix.len() != 576 {
        return Err(Error::Crypto);
    }
    let mut aad = Vec::with_capacity(16 + 1 + 576);
    aad.extend_from_slice(b"SBOX-v3/metadata");
    aad.push(0);
    aad.extend_from_slice(root_header_prefix);
    Ok(aad)
}

pub(crate) fn derive_metadata_key(
    identity: &PublicIdentity,
    metadata_salt: &[u8; 32],
    bundle_id: &[u8; 16],
) -> Result<Zeroizing<[u8; 32]>> {
    let mut info = Vec::with_capacity(20 + 1 + 16 + 32 + 2);
    info.extend_from_slice(b"SBOX-v3/metadata-key");
    info.push(0);
    info.extend_from_slice(bundle_id);
    info.extend_from_slice(identity.recipient_key_id());
    info.extend_from_slice(&METADATA_FORMAT_ID.to_be_bytes());
    let hkdf = Hkdf::<Sha256>::new(Some(metadata_salt), identity.spki_der());
    let mut key = Zeroizing::new([0_u8; 32]);
    hkdf.expand(&info, &mut *key).map_err(|_| Error::Crypto)?;
    info.zeroize();
    Ok(key)
}

pub(crate) fn derive_shard_key(
    bundle_dek: &[u8; 32],
    bundle_id: &[u8; 16],
    recipient_key_id: &[u8; 32],
    shard_index: u32,
) -> Result<Zeroizing<[u8; 32]>> {
    let mut info = Vec::with_capacity(17 + 1 + 32 + 4);
    info.extend_from_slice(b"SBOX-v3/shard-key");
    info.push(0);
    info.extend_from_slice(recipient_key_id);
    info.extend_from_slice(&shard_index.to_be_bytes());
    let hkdf = Hkdf::<Sha256>::new(Some(bundle_id), bundle_dek);
    let mut key = Zeroizing::new([0_u8; 32]);
    hkdf.expand(&info, &mut *key).map_err(|_| Error::Crypto)?;
    info.zeroize();
    Ok(key)
}

pub(crate) fn encrypt_metadata(
    key: &[u8; 32],
    nonce: &[u8; 12],
    plaintext: &mut [u8],
    aad: &[u8],
) -> Result<[u8; 16]> {
    if plaintext.len() != METADATA_BLOCK_LENGTH {
        return Err(Error::Crypto);
    }
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| Error::Crypto)?;
    let tag = cipher
        .encrypt_in_place_detached(Nonce::from_slice(nonce), aad, plaintext)
        .map_err(|_| Error::Crypto)?;
    let mut result = [0_u8; 16];
    result.copy_from_slice(tag.as_slice());
    Ok(result)
}

pub(crate) fn wrap_bundle_dek<R: RngCore + CryptoRng>(
    identity: &PublicIdentity,
    bundle_id: &[u8; 16],
    bundle_dek: &[u8; 32],
    rng: &mut R,
) -> Result<Vec<u8>> {
    let mut label = Vec::with_capacity(19 + 1 + 16 + 32);
    label.extend_from_slice(b"SBOX-v3-bundle-DEK");
    label.push(0);
    label.extend_from_slice(bundle_id);
    label.extend_from_slice(identity.recipient_key_id());

    let key = identity.rsa_public_key();
    let modulus_length = key.size();
    let hash_length = 32;
    if bundle_dek.len() > modulus_length - 2 * hash_length - 2 {
        return Err(Error::Crypto);
    }
    let label_hash = Sha256::digest(&label);
    let data_block_length = modulus_length - hash_length - 1;
    let mut data_block = Zeroizing::new(vec![0_u8; data_block_length]);
    data_block[..hash_length].copy_from_slice(&label_hash);
    let separator = data_block_length - bundle_dek.len() - 1;
    data_block[separator] = 1;
    data_block[separator + 1..].copy_from_slice(bundle_dek);

    let mut seed = Zeroizing::new([0_u8; 32]);
    rng.fill_bytes(&mut *seed);
    let data_mask = Zeroizing::new(mgf1(&seed[..], data_block_length));
    for (value, mask) in data_block.iter_mut().zip(data_mask.iter()) {
        *value ^= *mask;
    }
    let seed_mask = Zeroizing::new(mgf1(&data_block, hash_length));
    for (value, mask) in seed.iter_mut().zip(seed_mask.iter()) {
        *value ^= *mask;
    }

    let mut encoded = Zeroizing::new(vec![0_u8; modulus_length]);
    encoded[1..1 + hash_length].copy_from_slice(&seed[..]);
    encoded[1 + hash_length..].copy_from_slice(&data_block);
    let representative = BigUint::from_bytes_be(&encoded);
    if &representative >= key.n() {
        return Err(Error::Crypto);
    }
    let encrypted = representative.modpow(key.e(), key.n()).to_bytes_be();
    if encrypted.len() > modulus_length {
        return Err(Error::Crypto);
    }
    let mut ciphertext = vec![0_u8; modulus_length];
    ciphertext[modulus_length - encrypted.len()..].copy_from_slice(&encrypted);
    label.zeroize();
    Ok(ciphertext)
}

fn mgf1(seed: &[u8], length: usize) -> Vec<u8> {
    let mut output = vec![0_u8; length];
    let mut offset = 0;
    let mut counter = 0_u32;
    while offset < length {
        let mut digest = Sha256::new();
        digest.update(seed);
        digest.update(counter.to_be_bytes());
        let digest = digest.finalize();
        let take = (length - offset).min(digest.len());
        output[offset..offset + take].copy_from_slice(&digest[..take]);
        offset += take;
        counter = counter.wrapping_add(1);
    }
    output
}

pub(crate) fn encrypt_record(
    record_type: u8,
    index: u64,
    plaintext: &mut [u8],
    shard_key: &[u8; 32],
    nonce_prefix: &[u8; 4],
    header_hash: &[u8; 32],
) -> Result<([u8; 13], [u8; 16])> {
    if index == 0
        || (record_type == 0x02 && (plaintext.is_empty() || plaintext.len() > CHUNK_SIZE))
        || (record_type == 0xff && plaintext.len() != 48)
        || (record_type != 0x02 && record_type != 0xff)
    {
        return Err(Error::Crypto);
    }
    let mut record_header = [0_u8; 13];
    record_header[0] = record_type;
    record_header[1..9].copy_from_slice(&index.to_be_bytes());
    record_header[9..13].copy_from_slice(&(plaintext.len() as u32).to_be_bytes());
    let mut nonce = [0_u8; 12];
    nonce[0..4].copy_from_slice(nonce_prefix);
    nonce[4..12].copy_from_slice(&index.to_be_bytes());
    let mut aad = Vec::with_capacity(14 + 1 + 32 + 13);
    aad.extend_from_slice(b"SBOX-v3-record");
    aad.push(0);
    aad.extend_from_slice(header_hash);
    aad.extend_from_slice(&record_header);
    let cipher = Aes256Gcm::new_from_slice(shard_key).map_err(|_| Error::Crypto)?;
    let tag = cipher
        .encrypt_in_place_detached(Nonce::from_slice(&nonce), &aad, plaintext)
        .map_err(|_| Error::Crypto)?;
    let mut result = [0_u8; 16];
    result.copy_from_slice(tag.as_slice());
    aad.zeroize();
    Ok((record_header, result))
}

pub(crate) fn sha256(input: &[u8]) -> [u8; 32] {
    let digest = Sha256::digest(input);
    let mut output = [0_u8; 32];
    output.copy_from_slice(&digest);
    output
}

fn put_u16(bytes: &mut [u8], offset: usize, value: u16) {
    bytes[offset..offset + 2].copy_from_slice(&value.to_be_bytes());
}

fn put_u32(bytes: &mut [u8], offset: usize, value: u32) {
    bytes[offset..offset + 4].copy_from_slice(&value.to_be_bytes());
}

fn put_u64(bytes: &mut [u8], offset: usize, value: u64) {
    bytes[offset..offset + 8].copy_from_slice(&value.to_be_bytes());
}
