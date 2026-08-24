use std::{fs, io::Write as _};

use aes_gcm::{
    Aes256Gcm, Nonce,
    aead::{AeadInPlace, KeyInit},
};
use rand::{RngCore, SeedableRng};
use rand_chacha::ChaCha20Rng;

use crate::{
    ContentKind, EncryptOptions, Error, PublicIdentity, encrypt_bytes_with_rng,
    encrypt_file_with_rng,
    manifest::{Manifest, ValidatedMetadata},
    wire,
};

const SPKI: &str = "MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAuuLMXcnG7m37vzI1006K27P077n8a7rS5BKwP4E60rXTjHedUcDRlg_4O0CQgFCjnaB3VEtKk7VZJX0ucD76N-agPrjGOuV5T0WQ4uw3g9914tSPJol8G9AkXZlYgU8RVCTnkgYNCkuR3TRsaP_5oW80ELOskT52PZ_OEKFusm8eBU0yDLpNkgRKNIqLmxL1saBtGGbY4v-sfcNwNT6XKLX505WqEzA3Ig6XQs6a7wR3KFP9uKettKLBiLlC3WO0WJF9BpRrNNtSo-UE8xA8Y6uYLQYuDlXYf2tzsIv6jh3aC1-UQW9HX1ljRsB7qUrmpf55QfRzUt_cdIBWTf8M7utQHGZhv30mQilNcwwNdnaLH4vdqHjH1bqJQrIhPzAqmbDjarZ-CCc1QpamATcoY9rN9-g1_qDd-DqfYPVm3vdhA2hc5jKQgf99LEP3Lbv6sPc8g6GmzX7n6yffyy0JyCDqAaxNRKokr1ZjDpKZDR4DGeX89UH18-CP857_w0XHAgMBAAE";
const KEY_ID: &str = "9549c41744d3b469c512aa2c845677940937fd20685220fb0eb00f15082b04ae";

fn identity_json() -> String {
    format!(
        r#"{{"schema":"SBOX-PUBLIC-IDENTITY-1","key_profile_id":1,"spki_der":"{SPKI}","recipient_key_id":"{KEY_ID}"}}"#
    )
}

fn identity() -> PublicIdentity {
    PublicIdentity::from_json(&identity_json()).expect("fixture identity")
}

#[test]
fn copied_public_identity_round_trips_and_detects_tampering() {
    let identity = identity();
    assert_eq!(identity.recipient_key_id_hex(), KEY_ID);
    let compact = identity.to_compact();
    assert!(compact.starts_with("sboxpk1:"));
    assert_eq!(compact.len(), 526);
    assert_eq!(
        hex::encode(wire::sha256(compact.as_bytes())),
        "b6d9e085207e617655e703bf9a835e4b9d3ad09480742661a7ac0f4fc8f94f51"
    );
    assert_eq!(
        PublicIdentity::from_encoded(&compact).unwrap().spki_der(),
        identity.spki_der()
    );
    assert_eq!(
        PublicIdentity::from_encoded(&identity.to_json().unwrap())
            .unwrap()
            .spki_der(),
        identity.spki_der()
    );

    let mut compact_tampered = compact.into_bytes();
    let last = compact_tampered.last_mut().unwrap();
    *last = if *last == b'A' { b'B' } else { b'A' };
    assert!(PublicIdentity::from_encoded(std::str::from_utf8(&compact_tampered).unwrap()).is_err());

    let tampered = identity_json().replace("9549", "0549");
    assert!(matches!(
        PublicIdentity::from_json(&tampered),
        Err(Error::InvalidPublicIdentity("recipient key ID mismatch"))
    ));
}

#[test]
fn v31_metadata_inputs_match_the_dart_fixed_vector() {
    let identity = identity();
    let mut options = EncryptOptions::new("预览.jpg", "image/jpeg");
    options.title = Some("预览向量".into());
    options.description = "固定缩略图向量".into();
    options.tags = vec!["image".into(), "测试".into()];
    options.created_at = Some("2026-08-18T02:30:00Z".into());
    let metadata = ValidatedMetadata::from_options(&options).unwrap();
    let bundle_id: [u8; 16] = hex::decode("a0a1a2a3a4a5a6a7a8a9aaabacadaeaf")
        .unwrap()
        .try_into()
        .unwrap();
    let plaintext_sha256: [u8; 32] =
        hex::decode("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
            .unwrap()
            .try_into()
            .unwrap();
    let manifest = Manifest::new(
        bundle_id,
        *identity.recipient_key_id(),
        plaintext_sha256,
        12_345,
        1,
        metadata,
    )
    .unwrap();
    let manifest_bytes = manifest.canonical_json().unwrap();
    assert_eq!(manifest_bytes.len(), 546);
    assert_eq!(
        hex::encode(wire::sha256(&manifest_bytes)),
        "85cb14f4f0c3382ee287f52e9a5aecfa41d0ad96dc19ddfd18b742f58a485f7f"
    );

    let salt: [u8; 32] =
        hex::decode("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
            .unwrap()
            .try_into()
            .unwrap();
    let metadata_nonce: [u8; 12] = hex::decode("202122232425262728292a2b")
        .unwrap()
        .try_into()
        .unwrap();
    let nonce_prefix = [0xa0, 0xa1, 0xa2, 0xa3];
    let key = wire::derive_metadata_key(&identity, &salt, &bundle_id).unwrap();
    assert_eq!(
        hex::encode(*key),
        "d23d95f7e18c515fc3850cfc7b7d326f0562169a7f38382c7de5fbd661f044b8"
    );
    let placeholder = wire::build_root_header(
        &bundle_id,
        1,
        12_345,
        identity.recipient_key_id(),
        &nonce_prefix,
        &[0x55; 384],
        &salt,
        &metadata_nonce,
        &[0_u8; wire::METADATA_BLOCK_LENGTH],
        &[0_u8; 16],
    )
    .unwrap();
    let aad = wire::metadata_aad(&placeholder[..576]).unwrap();
    assert_eq!(
        hex::encode(wire::sha256(&aad)),
        "7d3906954dcbab672543c0608860c307e86fce0194ed653ad03bb834dabf4736"
    );
}

#[test]
fn in_memory_writer_encrypts_metadata_records_and_multipart_objects() {
    let identity = identity();
    let mut empty_options = EncryptOptions::new("empty.bin", "application/octet-stream");
    empty_options.created_at = Some("2026-08-24T01:02:03Z".into());
    let mut empty_rng = ChaCha20Rng::from_seed([0x24_u8; 32]);
    let empty = encrypt_bytes_with_rng(&identity, &[], &empty_options, &mut empty_rng).unwrap();
    assert_eq!(empty.objects.len(), 1);
    assert_eq!(
        empty.objects[0].bytes[wire::ROOT_HEADER_LENGTH],
        0xff,
        "an empty shard starts directly with its Final record"
    );

    let plaintext = b"Rust SDK -> SafeBox\n";
    let mut options = EncryptOptions::new("rust.txt", "text/plain; charset=utf-8");
    options.content_kind = ContentKind::Text;
    options.created_at = Some("2026-08-24T01:02:03Z".into());
    let seed = [0x42_u8; 32];
    let mut rng = ChaCha20Rng::from_seed(seed);
    let encrypted = encrypt_bytes_with_rng(&identity, plaintext, &options, &mut rng).unwrap();
    assert_eq!(encrypted.objects.len(), 1);
    let root = &encrypted.objects[0].bytes;
    assert_eq!(&root[..8], &wire::MAGIC);
    assert_eq!(&root[8..10], &[3, 1]);
    assert_eq!(u16::from_be_bytes(root[10..12].try_into().unwrap()), 16_992);

    let salt: [u8; 32] = root[532..564].try_into().unwrap();
    let nonce: [u8; 12] = root[564..576].try_into().unwrap();
    let key =
        wire::derive_metadata_key(&identity, &salt, &root[28..44].try_into().unwrap()).unwrap();
    let aad = wire::metadata_aad(&root[..576]).unwrap();
    let mut block = root[576..16_976].to_vec();
    let tag = root[16_976..16_992].into();
    Aes256Gcm::new_from_slice(&*key)
        .unwrap()
        .decrypt_in_place_detached(Nonce::from_slice(&nonce), &aad, &mut block, tag)
        .unwrap();
    assert_eq!(&block[..8], b"SBOXMETA");
    let manifest_length = u32::from_be_bytes(block[8..12].try_into().unwrap()) as usize;
    assert_eq!(
        &block[12..12 + manifest_length],
        encrypted.manifest.canonical_json().unwrap()
    );
    assert!(
        block[12 + manifest_length..]
            .iter()
            .all(|value| *value == 0)
    );

    let mut repeated_rng = ChaCha20Rng::from_seed(seed);
    let mut bundle_dek = [0_u8; 32];
    repeated_rng.fill_bytes(&mut bundle_dek);
    let bundle_id: [u8; 16] = root[28..44].try_into().unwrap();
    let shard_key =
        wire::derive_shard_key(&bundle_dek, &bundle_id, identity.recipient_key_id(), 0).unwrap();
    let offset = wire::ROOT_HEADER_LENGTH;
    assert_eq!(root[offset], 0x02);
    let record_header: [u8; 13] = root[offset..offset + 13].try_into().unwrap();
    let length = u32::from_be_bytes(record_header[9..13].try_into().unwrap()) as usize;
    let mut ciphertext = root[offset + 13..offset + 13 + length].to_vec();
    let record_tag = (&root[offset + 13 + length..offset + 29 + length]).into();
    let mut record_nonce = [0_u8; 12];
    record_nonce[..4].copy_from_slice(&root[92..96]);
    record_nonce[4..].copy_from_slice(&1_u64.to_be_bytes());
    let mut record_aad = Vec::new();
    record_aad.extend_from_slice(b"SBOX-v3-record");
    record_aad.push(0);
    record_aad.extend_from_slice(&wire::sha256(&root[..wire::ROOT_HEADER_LENGTH]));
    record_aad.extend_from_slice(&record_header);
    Aes256Gcm::new_from_slice(&*shard_key)
        .unwrap()
        .decrypt_in_place_detached(
            Nonce::from_slice(&record_nonce),
            &record_aad,
            &mut ciphertext,
            record_tag,
        )
        .unwrap();
    assert_eq!(ciphertext, plaintext);

    let multipart_plaintext = vec![0x5a; 1024 * 1024 + 1];
    options.content_kind = ContentKind::File;
    options.original_name = "multi.bin".into();
    options.title = None;
    options.media_type = "application/octet-stream".into();
    options.target_nominal_shard_size = 1024 * 1024;
    let mut multipart_rng = ChaCha20Rng::from_seed([7_u8; 32]);
    let multipart = encrypt_bytes_with_rng(
        &identity,
        &multipart_plaintext,
        &options,
        &mut multipart_rng,
    )
    .unwrap();
    assert_eq!(multipart.objects.len(), 2);
    assert!(multipart.objects[0].bytes.len() >= wire::ROOT_HEADER_LENGTH);
    assert_eq!(
        u16::from_be_bytes(multipart.objects[1].bytes[10..12].try_into().unwrap()),
        128
    );
    assert!(multipart.objects[0].basename.ends_with("_0_2.sbox"));
    assert!(multipart.objects[1].basename.ends_with("_1_2.sbox"));
}

#[test]
fn streaming_writer_commits_immutable_output_and_rejects_invalid_text() {
    let identity = identity();
    let temporary = tempfile::tempdir().unwrap();
    let source = temporary.path().join("input.txt");
    fs::write(&source, "跨块 UTF-8 from Rust").unwrap();
    let output = temporary.path().join("out");
    let mut options = EncryptOptions::new("input.txt", "text/plain; charset=utf-8");
    options.content_kind = ContentKind::Text;
    options.created_at = Some("2026-08-24T01:02:03Z".into());
    let mut rng = ChaCha20Rng::from_seed([9_u8; 32]);
    let written = encrypt_file_with_rng(&identity, &source, &output, &options, &mut rng).unwrap();
    assert_eq!(written.objects.len(), 1);
    assert!(written.objects[0].path.is_file());

    let mut second_rng = ChaCha20Rng::from_seed([10_u8; 32]);
    assert!(matches!(
        encrypt_file_with_rng(&identity, &source, &output, &options, &mut second_rng),
        Err(Error::OutputExists(_))
    ));

    let invalid = temporary.path().join("invalid.txt");
    let mut file = fs::File::create(&invalid).unwrap();
    file.write_all(&[0xf0, 0x9f, 0x92]).unwrap();
    let mut invalid_rng = ChaCha20Rng::from_seed([11_u8; 32]);
    assert!(matches!(
        encrypt_file_with_rng(
            &identity,
            &invalid,
            temporary.path().join("invalid-out"),
            &options,
            &mut invalid_rng,
        ),
        Err(Error::InvalidOptions("text plaintext is not strict UTF-8"))
    ));
}
