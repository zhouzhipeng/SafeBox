# SafeBox Rust SDK

这个 crate 使用 SafeBox 客户端复制出的公钥加密明文，并生成与客户端兼容的 SBOX 3.1 文件。加密只需要公钥，不接收恢复词或私钥。

## 快速开始

在 SafeBox 的“设置 → 安全身份”中点击“复制公钥”，确认提示后将剪贴板内容保存为 `public-key.txt`。复制内容是固定 526 字符的 `sboxpk1:` 单行公钥；SDK 也继续接受旧版 `SBOX-PUBLIC-IDENTITY-1` JSON。

作为本地依赖使用：

```toml
[dependencies]
safebox-sdk = { path = "../SafeBox/sdk/rust" }
```

```rust
use std::fs;
use safebox_sdk::{EncryptOptions, PublicIdentity, encrypt_file};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let public_key = fs::read_to_string("public-key.txt")?;
    let identity = PublicIdentity::from_encoded(&public_key)?;
    let options = EncryptOptions::new("report.pdf", "application/pdf");

    let result = encrypt_file(
        &identity,
        "report.pdf",
        "encrypted",
        &options,
    )?;

    for object in result.objects {
        println!("{}", object.path.display());
    }
    Ok(())
}
```

仓库内也提供了可直接运行的示例：

```powershell
cargo run --manifest-path sdk/rust/Cargo.toml --example encrypt_file -- `
  public-key.txt report.pdf encrypted application/pdf
```

小数据可以使用 `encrypt_bytes` 在内存中取得完整对象。大文件应使用 `encrypt_file`：它流式执行两遍完整性检查，将临时对象写入目标目录，延续分片先提交、根分片最后提交，并且绝不覆盖已有 `.sbox` 文件。

## 输出与兼容性

- Bundle ID 是原始明文 MD5；单对象名为 `<bundle_id>.sbox`。
- 超过分片目标时自动输出 `<bundle_id>_<index>_<count>.sbox`。
- 默认分片目标为 16 MiB，可通过 `EncryptOptions::target_nominal_shard_size` 设置为 1–512 MiB 的整 MiB 值。
- Writer 固定生成 SBOX 3.1 / Metadata Format 2，使用 RSA-OAEP-SHA256、HKDF-SHA256 和 AES-256-GCM。
- 当前 Rust SDK 不生成可选 JPEG 缩略图；无 Preview 的 Metadata Format 2 是完整、合法的 SBOX 3.1 格式。
- `ContentKind::Text` 会在加密前执行严格 UTF-8 校验。

## 公钥可见性

获得这份完整公钥的人可以读取该身份历史和未来 SBOX 3.x 文件的文件名、说明、时间，以及文件内存在的缩略图预览；仅凭公钥不能解密文件正文。请仅将公钥交给需要为该身份加密文件的可信方。

## 验证

```powershell
cargo fmt --manifest-path sdk/rust/Cargo.toml -- --check
cargo clippy --manifest-path sdk/rust/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path sdk/rust/Cargo.toml
```
