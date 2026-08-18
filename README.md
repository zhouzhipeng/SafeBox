# SafeBox

SafeBox writes SBOX 3.1 Bundles with Metadata Format 2 and reads both SBOX 3.0 and 3.1. A static baseline-JPEG thumbnail may be embedded in the encrypted Metadata Block; it is readable by holders of the complete public SPKI key, while the file body still requires full authentication and decryption.

SafeBox 是 Flutter + Dart 实现的 SBOX 3.1 客户端，面向把隐私文件保存到公开云仓库的场景；读取器兼容既有 SBOX 3.0 文件。

核心行为：

- Bundle ID 使用原始明文的 MD5（32 位小写十六进制），不再随机生成。
- 本地目录只保存加密后的 `.sbox` 副本，不创建、不使用本地 Git 仓库。
- GitHub 和 Gitee 是一个“双云”目标。上传时通过两个仓库的 HTTP API 并发创建单个 `.sbox` 文件，不需要 pull 整个仓库。
- 两个 API 都成功后才报告上传成功；如果同一 MD5 已经在两个仓库完整存在，直接提示成功且不执行上传。
- 如果上次上传只完成了一边，下一次只补传缺失的一边；本地加密副本会保留用于重试和恢复。
- 新写入使用 SBOX 3.1 / Metadata Format 2；读取器同时支持 SBOX 3.0 和 3.1。图片可尽力生成一张静态基线 JPEG 缩略图，格式不支持或生成失败时仍继续上传无缩略图的合法 Bundle。
- 缩略图只保存在加密 Metadata Block 中，不写入仓库路径、日志或旁路文件；持有完整公钥的人可以读取缩略图和快速 Manifest 信息。
- GitHub/Gitee 访问令牌只保存到系统安全存储，普通配置只保存仓库地址、分支和令牌引用。

SBOX 对象仍使用 RSA-OAEP、HKDF-SHA256、AES-256-GCM、分片 Final 记录和整体 SHA-256 校验。MD5 只用于内容寻址和去重，不承担完整性或保密性职责。

协议定义见 [docs/SBOX-v3.1-THUMBNAIL-PREVIEW-UPGRADE-SPEC.md](docs/SBOX-v3.1-THUMBNAIL-PREVIEW-UPGRADE-SPEC.md)。

运行 Windows 桌面版：

```powershell
python run_safebox.py
```

验证：

```powershell
flutter analyze --no-pub
dart test test/sbox
```
