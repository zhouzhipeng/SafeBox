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
- 云端缩略图只位于加密 Metadata Block 中，不创建远端旁路对象或写入日志；读取后，应用可在本机 `.sbox-sync/previews/<bundle_id>.jpg` 中保存可清理的 JPG 性能缓存，每个不可变 Bundle ID 最多对应一个文件。持有完整公钥的人可以读取缩略图和快速 Manifest 信息。
- GitHub/Gitee 访问令牌只保存到系统安全存储，普通配置只保存仓库地址、分支和令牌引用。

SBOX 对象仍使用 RSA-OAEP、HKDF-SHA256、AES-256-GCM、分片 Final 记录和整体 SHA-256 校验。MD5 只用于内容寻址和去重，不承担完整性或保密性职责。

协议定义见 [docs/SBOX-v3.1-THUMBNAIL-PREVIEW-UPGRADE-SPEC.md](docs/SBOX-v3.1-THUMBNAIL-PREVIEW-UPGRADE-SPEC.md)。

运行 Windows 桌面版：

```powershell
python run_safebox.py
```

Rust SDK：

在“设置 → 安全身份”中点击“复制公钥”即可取得固定 526 字符的 `sboxpk1:` 单行公钥。仓库内的 [Rust SDK](sdk/rust/README.md) 可以直接使用该公钥流式加密文件，生成与客户端兼容的 SBOX 3.1 单对象或分片 Bundle；旧版公钥 JSON 仍可解析：

```powershell
cargo test --manifest-path sdk/rust/Cargo.toml
cargo run --manifest-path sdk/rust/Cargo.toml --example encrypt_file -- public-key.txt input.bin encrypted
```

导出 Web 版：

```powershell
python export_safebox_web.py
```

脚本会自动定位 Flutter，依次执行依赖解析、静态分析、测试和 release 构建，最终产物位于 `build/web`。产物使用随包导出的本地 CanvasKit，不依赖 Google CDN。部署在子路径时必须同步设置 base href，例如：

```powershell
python export_safebox_web.py --base-href /safebox/ --output build/web
```

本地运行应使用 SafeBox Web 服务器，它会同时提供静态文件和受限的同源云端代理：

```powershell
python serve_safebox_web.py
```

也可以在导出完成后直接启动：

```powershell
python export_safebox_web.py --serve
```

然后打开 `http://localhost:8080`。不要使用普通的 `python -m http.server`：GitHub Release 和 Gitee 附件的最终下载域名不允许浏览器跨域读取，纯静态服务器会导致 `net::ERR_FAILED`。`serve_safebox_web.py` 的代理只接受 SafeBox 使用的 GitHub/Gitee HTTPS 域名，不是开放代理，访问令牌只通过请求头或请求体转发，不写入代理 URL。

正式部署必须使用 HTTPS，并在同一站点提供 `/_safebox/proxy`（可在导出时用 `--proxy-path` 修改）对应的受限代理逻辑；只上传 `build/web` 到纯静态托管无法使用云端浏览、上传或下载功能。

Web 版没有可写的本地文件系统，上传、加密、云端分片修复、解密和下载均在当前标签页内存中完成。默认单文件上限是 128 MiB，可在导出时调整到 1–512 MiB：

```powershell
python export_safebox_web.py --max-file-mib 192
```

这个上限是浏览器内存安全阈值，不是 SBOX 协议上限。处理期间会同时存在明文、加密分片、网络缓冲区和算法工作区，实际峰值内存通常明显高于文件本身；提高上限前应在目标浏览器和设备上做压力测试。Web 版会直接触发明文浏览器下载，不保留本地解密缓存；缩略图生成暂不在 Web 中执行。如果某个云端只留下残缺 Bundle，Web 版只有在另一云端存在完整镜像时才会修复它，否则会安全中止，避免把不同随机密文混入同一个 Bundle。

常用导出参数：

- `--skip-checks`：跳过分析和测试，加快重复导出。
- `--no-pub`：跳过 `flutter pub get`。
- `--debug`：生成调试构建。
- `--source-maps`：输出 JavaScript source map。

验证：

```powershell
flutter analyze --no-pub
dart test test/sbox
```
