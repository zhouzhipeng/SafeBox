use std::{env, fs, io, path::Path};

use safebox_sdk::{EncryptOptions, PublicIdentity, encrypt_file};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let arguments: Vec<String> = env::args().collect();
    if !(4..=5).contains(&arguments.len()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "usage: encrypt_file <public-key.txt> <input-file> <output-directory> [media-type]",
        )
        .into());
    }
    let identity = PublicIdentity::from_encoded(&fs::read_to_string(&arguments[1])?)?;
    let source = Path::new(&arguments[2]);
    let original_name = source
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid input basename"))?;
    let media_type = arguments
        .get(4)
        .map(String::as_str)
        .unwrap_or("application/octet-stream");
    let options = EncryptOptions::new(original_name, media_type);
    let result = encrypt_file(&identity, source, &arguments[3], &options)?;
    for object in result.objects {
        println!("{}", object.path.display());
    }
    Ok(())
}
