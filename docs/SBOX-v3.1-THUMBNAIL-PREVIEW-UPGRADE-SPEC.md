# SBOX v3.1 加密缩略图预览升级与实施规范

> 状态：可直接交给编码代理实施的冻结规范  
> 日期：2026-08-18  
> 目标版本：SBOX `3.1`  
> 基线版本：当前仓库已经实现的 SBOX `3.0`  
> 基线文档：`docs/SBOX-v3-METADATA-UPGRADE-SPEC.md`

## 0. 给 AI 编码代理的执行摘要

本文中的“必须”“不得”“应当”“可以”分别对应 MUST、MUST NOT、SHOULD、MAY。实现者不得把“必须”降级为建议。

编码代理必须先完整阅读本文和基线 v3.0 规范，再修改生产代码。本文未明确改写的密码算法、分片、对象命名、不可变上传、正文记录和身份派生规则继续沿用 v3.0。

本升级的核心结论如下：

1. 新写入格式为 SBOX `3.1`，读取器必须同时读取既有 `3.0` 和新 `3.1`；
2. 根头长度仍为 `16,992` 字节，云端列表仍只请求 `Range: bytes=0-16991`；
3. Metadata 明文块和密文仍恰好为 `16,400` 字节，不增加根对象固定开销；
4. v3.1 使用 `metadata_format_id = 2`，在 Manifest 后面的原零填充区保存一个可选的二进制 Preview Record；
5. Preview 只能是一张静态、基线 JPEG；图片使用缩略图，视频使用单帧 poster；
6. JPEG 编码数据最大为 `10 KiB = 10,240` 字节，此上限不包括 24 字节 Preview Record 描述头；
7. `description` 继续是纯 UTF-8 文本，禁止把缩略图 Base64、Hex、Data URI 或其他二进制表示塞入 Manifest JSON；
8. Preview 与 Manifest 一起由现有 Metadata AES-256-GCM 加密，并被完整根头哈希绑定到正文记录；
9. Preview 与快速 Manifest 具有相同的 `metadataReadable` 信任等级，不是签名，也不能证明缩略图在视觉上与正文相同；
10. 缩略图生成是尽力而为的产品能力；生成失败、格式不支持、超时或空间不足时必须继续上传无缩略图的合法 v3.1 Bundle；
11. 不新增 `preview.sbox`、旁路 JSON、GitHub/Gitee sidecar、Catalog 或必须存在的本地索引；
12. 现有 v3.0 Bundle 不原地修改，不能因为升级而覆盖同一 MD5 路径上的不可变对象。

任何偏离上述 12 点的实现都不符合本规范。

## 1. 目标与非目标

### 1.1 目标

SBOX v3.1 必须实现：

- 图片文件在资料库列表中可以显示低分辨率静态缩略图；
- 视频文件在资料库列表中可以显示一个静态 poster frame；
- 获取预览不要求助记词、RSA 私钥、`bundle_dek` 或正文下载；
- 获取预览不增加现有根头 Range 长度；
- 缩略图不以明文出现在仓库路径、Git 元数据、日志或旁路文件中；
- 无缩略图、旧 v3.0、生成失败和 UI 解码失败均有安全回退；
- 解析、内存、图片尺寸和候选并发具有明确上限；
- 新格式有固定向量和完整负向测试。

### 1.2 明确非目标

本次升级不得实现：

- 视频片段、GIF、动画 WebP、Live Photo 或多帧 Preview；
- 多尺寸缩略图、响应式图片集合或海报轮播；
- SVG、HTML、PDF 页面、Office 页面或脚本型预览；
- OCR、人脸识别、内容标签、成人内容分类或服务端转码；
- 把 Preview 上传成独立对象；
- 让 GitHub/Gitee 在不知道 SPKI DER 时读取 Preview；
- 通过 Preview 自动执行、自动打开或决定最终导出路径；
- 对既有 v3.0 对象做原地 Metadata 重写；
- 改变明文 MD5 `bundle_id`、对象 basename 或 multipart 命名规则。

PDF、Office、压缩包和未知格式在本版本中一律不生成嵌入式 Preview。未来若支持，必须通过新的 Preview codec/kind 或新的容器次版本扩展，不得偷偷复用当前 JPEG 语义。

## 2. 版本、兼容与迁移策略

### 2.1 读取和写入矩阵

新实现必须采用以下矩阵：

| 容器版本 | 根 `metadata_format_id` | Metadata Block | Preview | 新读取器 | 新写入器 |
|---|---:|---|---|---:|---:|
| `3.0` | `1` | Manifest Block v1 | 不存在 | 必须读取 | 不再写入 |
| `3.1` | `2` | Metadata Block v2 | 可选单张 JPEG | 必须读取 | 必须写入 |

旧 v3.0 客户端会拒绝 v3.1，这是预期的次版本边界。新客户端必须读取已有 v3.0 文件，不能要求用户重新上传。

### 2.2 Header 版本匹配

所有整数仍使用大端编码。新解析器必须保留收到的版本字段，不得继续把版本只表示为全局常量。

根头合法组合只有：

```text
version = 3.0  AND metadata_format_id = 1
version = 3.1  AND metadata_format_id = 2
```

下列组合必须返回 `invalidHeader`：

```text
version = 3.0  AND metadata_format_id != 1
version = 3.1  AND metadata_format_id != 2
```

主版本不是 `3`，或次版本不是 `0`、`1`，必须返回 `unsupportedVersion`。

同一 Bundle 的根分片与全部延续分片必须具有完全相同的 `(version_major, version_minor)`。混合 `3.0` 与 `3.1` 分片必须返回 `shardMismatch`，即使其他头字段和密码认证碰巧可通过。

### 2.3 旧 v3.0 Metadata Block

v3.0 的 `metadata_format_id = 1` 必须继续按现有 `ManifestBlock` 规则解析：

```text
0             8       ASCII SBOXMETA
8             4       manifest_len
12            N       manifest_bytes
12 + N        剩余    全零 padding
```

v3.0 非零 padding 仍然必须拒绝。新代码不得把旧 v3.0 padding 当作 Preview 扩展。

### 2.4 不可变对象与同内容重复上传

`bundle_id` 继续是原始明文 MD5，所以同一明文在 v3.0 和 v3.1 中仍使用相同远端路径。Preview、说明、标题和创建时间不参与对象命名。

因此必须遵守：

- 如果 GitHub/Gitee 已完整存在同一 MD5 的 v3.0 Bundle，重复上传必须复用既有不可变对象；不能为增加 Preview 覆盖它；
- 如果本地 `backup` 已完整存在同一 MD5 的 v3.0 Bundle，且云端尚未完整存在，上传器也必须复用并上传这组既有 v3.0 字节；不能在同一规范路径重新加密成 v3.1；
- UI 可以提示“现有安全文件创建于旧格式，因此没有嵌入式预览”；
- 重复上传结果中的 `previewEmbedded` 必须描述最终实际复用/发布的根对象，而不是用户本次是否打开了 Preview 开关；复用 v3.0 时该值为 `false`，原因使用 `existingV30`；
- 如果本地同路径 v3.1 字节与远端既有 v3.0 字节冲突，必须报告 `immutableConflict`，不得把路径相同误认为字节相同；
- 如果远端是混合版本、缺片或同路径不同内容，继续使用现有冲突/缺片语义；
- 本规范不提供自动删除重建迁移，尤其不得假设所有云端都支持安全删除；
- 既有 v3.0 文件保持可读、可下载、可完整解密，只是没有 Preview。

### 2.5 本地索引兼容

`BundleManifest` Schema 不变，所以现有 Manifest 本地索引可以继续读取。第一阶段不得把 JPEG Base64 写进 `index-v3.json`。

Preview 的协议真相只存在于根头 Metadata 密文中。预览缓存只能是可删除的性能缓存，删除后必须能够从根头重建。

## 3. 固定常量

### 3.1 保持不变的常量

| 名称 | 固定值 |
|---|---:|
| SBOX Magic | `53 42 4f 58 0d 0a 1a 0a` |
| `version_major` | `3` |
| v3.1 `version_minor` | `1` |
| 公共前缀长度 | `128` |
| 根头长度 | `16,992` |
| 延续分片头长度 | `128` |
| Metadata 明文块长度 | `16,400` |
| Metadata 密文长度 | `16,400` |
| Metadata GCM Tag 长度 | `16` |
| Manifest JSON 最大长度（无 Preview） | `16,384` |
| 根头 Range | `bytes=0-16991` |

根对象与延续对象的大小公式、正文 Data/Final 记录开销和分片规划公式全部保持 v3.0 不变。

### 3.2 新常量

| 名称 | 固定值 | 含义 |
|---|---:|---|
| `metadataFormatIdV31` | `2` | Metadata Block v2 |
| `metadataFlagsV31` | `0` | 不公开泄漏 Preview 是否存在 |
| `previewMagic` | ASCII `SBOXPRVW` | 8 字节 Preview Record Magic |
| `previewRecordVersion` | `1` | Preview Record 版本 |
| `previewCodecBaselineJpeg` | `1` | 静态基线 JPEG |
| `previewDescriptorLength` | `24` | 不含 JPEG 数据 |
| `maxPreviewBytes` | `10,240` | JPEG 编码数据上限，恰好 10 KiB |
| `maxPreviewDimension` | `320` | 宽、高各自上限 |
| `maxPreviewPixels` | `102,400` | 解码像素上限，320 × 320 |
| `maxRetainedPreviewBytes` | `33,554,432` | UI 编码 Preview 内存预算，32 MiB |

“10k”在本规范中固定解释为二进制 `10 KiB = 10 × 1024 = 10,240` 字节，不得实现成 10,000 字节，也不得把 24 字节描述头计入该上限。

### 3.3 动态容量公式

设：

```text
M = len(manifest_bytes)
P = len(preview_jpeg_bytes)
D = 24
B = 16400
```

无 Preview 时：

```text
1 <= M <= 16384
12 + M <= B
```

有 Preview 时：

```text
1 <= M <= 16384
1 <= P <= 10240
12 + M + D + P <= B
```

等价的 Preview 可用容量：

```text
preview_capacity(M) = min(10240, 16400 - 12 - 24 - M)
```

当 `P = 10240` 时，Manifest 最大只能为：

```text
16400 - 12 - 24 - 10240 = 6124 bytes
```

所有加法必须在检查溢出后执行。不得根据攻击者字段创建超过固定块大小的切片或分配。

## 4. 数据模型与信任边界

### 4.1 Manifest 保持不变

`BundleManifest` 的 Schema 继续是：

```json
"schema": "SBOX-MANIFEST-3"
```

字段集合、规范 JSON、NFC、长度、时间和交叉验证规则全部保持不变。不得增加 `thumbnail_base64`、`preview_url`、`poster` 或其他新 JSON 键。

Preview 必须是 Metadata Block 的独立二进制扩展，而不是 Manifest 字符串的一部分。这样可以避免：

- Base64 约 33% 的膨胀；
- `description` 4 KiB 限制被滥用；
- JSON 规范化和文本转义对二进制的额外复杂度；
- 搜索、复制说明或日志时意外传播图像数据。

### 4.2 建议的内存模型

实现应新增等价模型：

```dart
enum BundlePreviewCodec { baselineJpeg }

final class BundlePreview {
  final BundlePreviewCodec codec;
  final int width;
  final int height;
  final Uint8List encodedBytes;
}

final class BundleMetadata {
  final BundleManifest manifest;
  final BundlePreview? preview;
}
```

构造器必须复制或取得明确所有权，禁止暴露可修改内部数组。持有方不再使用时应尽力覆盖由明文文件派生的 Preview 缓冲区。

### 4.3 可见性

Preview 与快速 Manifest 使用同一个 `metadata_key` 和同一 AEAD，因此可见性完全一致：

| 实体能力 | 可见 Preview |
|---|---:|
| 只有 `.sbox`、路径或 Key ID | 否 |
| 持有完整规范 SPKI DER | 是 |
| 持有匹配 RSA 私钥 | 是 |

公钥不是秘密。任何获得完整 SPKI DER 且能读取根对象的人，都可以读取历史和未来 v3.1 Preview。产品导出公钥时的警告必须扩展为：

> 获得此公钥的人可以读取文件名、说明、时间和缩略图预览，但不能仅凭公钥解密文件正文。

### 4.4 信任状态

Preview 不新增信任枚举，继承其所在 Bundle 的状态：

- `metadataReadable`：Metadata GCM 与结构校验成功，可用于列表展示；
- `rootAuthenticated`：完整根头（含 Preview）被根正文记录 AAD 绑定；
- `complete`：全部正文和整体摘要通过。

即使状态为 `complete`，协议也只能证明“这些 Preview 字节与该 Bundle 一起被创建和绑定”，不能数学证明 Preview 在视觉语义上一定来自正文。合法创建者可以故意嵌入一张无关图片。因此 Preview 永远不得作为文件类型、恶意内容、安全分类或自动执行的可信证据。

### 4.5 UI 文案要求

UI 可以显示缩略图，但不得使用以下文案：

- “已验证图片内容”；
- “官方封面”；
- “发布者签名预览”；
- “安全扫描通过”。

可访问性语义建议为“快速缩略图预览；完整文件尚未验证”。

## 5. Metadata Block v2 精确二进制布局

### 5.1 总体布局

Metadata Block v2 解密后的明文恰好为 `16,400` 字节：

| 块内偏移 | 长度 | 字段 | 规则 |
|---:|---:|---|---|
| `0` | `8` | `block_magic` | ASCII `SBOXMETA` |
| `8` | `4` | `manifest_len` | 大端 uint32，`1..16,384` |
| `12` | `manifest_len` | `manifest_bytes` | 规范 `SBOX-MANIFEST-3` JSON |
| `12 + manifest_len` | `0` 或 `24 + preview_data_len` | `preview_record` | 可选，见下节 |
| Preview 后 | 剩余 | `padding` | 必须全部为 `0x00` |

Preview 不存在时，`manifest_bytes` 后的全部剩余字节必须为零。

Preview 存在时，它必须紧跟 Manifest，不允许对齐字节、前导零、第二个 Preview、TLV 列表或未知扩展。

### 5.2 Preview Record 描述头

令：

```text
preview_offset = 12 + manifest_len
```

Preview Record 的前 24 字节为：

| 相对 Preview 偏移 | 长度 | 字段 | v3.1 固定规则 |
|---:|---:|---|---|
| `0` | `8` | `preview_magic` | ASCII `SBOXPRVW` |
| `8` | `2` | `preview_version` | 大端 uint16，固定 `1` |
| `10` | `2` | `preview_codec_id` | 大端 uint16，固定 `1`（基线 JPEG） |
| `12` | `2` | `preview_flags` | 大端 uint16，固定 `0` |
| `14` | `2` | `preview_width` | 大端 uint16，`1..320` |
| `16` | `2` | `preview_height` | 大端 uint16，`1..320` |
| `18` | `2` | `preview_reserved` | 必须为 `0` |
| `20` | `4` | `preview_data_len` | 大端 uint32，`1..10,240` |
| `24` | `preview_data_len` | `preview_data` | 规范静态基线 JPEG |

要求：

```text
preview_width * preview_height <= 102400
preview_offset + 24 + preview_data_len <= 16400
```

Preview 数据后的全部剩余块字节必须为零。

### 5.3 Preview 缺失表示

Preview 缺失没有描述头，也没有单独布尔字段。解析器检查 Manifest 后面的尾部：

- 如果尾部全部为零，Preview 缺失；
- 如果尾部存在任何非零字节，则必须从第一个尾部字节开始完整解析 `SBOXPRVW`；
- 禁止用全零描述头、`preview_data_len = 0`、未知 Magic 或非零前导 padding 表示缺失。

`metadata_flags` 固定为零，所以只持有 `.sbox` 但没有 SPKI 的存储方不能从公共头判断 Preview 是否存在。

### 5.4 JPEG 编码子集

v3.1 只允许 codec ID `1`，表示一张独立、单帧、单扫描的基线顺序 DCT JPEG。实现必须在把 Preview 交给 UI 前执行有界结构检查；仅检查 SOI/EOI 或调用平台解码器不符合规范。

外层 Marker 语法必须满足：

- SOI `ff d8` 恰好位于偏移 0；EOI `ff d9` 恰好是最后两个字节，EOI 后不得有附加数据；
- SOF0 和 SOS 各恰好一个；SOS 后除熵编码数据、`ff 00` 字节填充、RST0..RST7 和最终 EOI 外，不允许其他 Marker，因此不允许第二个扫描；
- SOS 前只允许 APP0、DQT、DHT、DRI 和 SOF0；APP0 最多一个，DQT 和 DHT 至少各一个，DRI 最多一个；
- APP0 如果存在，必须是长度恰好 16 的 JFIF 段，标识为 `JFIF\0`，内嵌缩略图宽高都为 0；
- 禁止 APP1..APP15、COM、DAC、DNL、DHP、EXP、TEM、JPG 扩展、所有非 SOF0 的 SOF、重复 SOI、保留 Marker 和未知 Marker；
- 每个带长度 Marker 的长度字段必须至少为 2，段末不得超过 `preview_data_len`；整个文件最多处理 256 个 Marker，循环每次必须严格前进；
- `ff` 填充字节只能按 JPEG 语法出现，熵编码中的字面 `ff` 必须写成 `ff 00`。

SOF0 和 SOS 必须满足：

- SOF0 采样精度固定为 8 bit，宽高必须分别等于描述头字段；
- 分量数只能是 1 或 3，SOF0 段长度必须恰好为 `8 + 3 × component_count`；
- 分量 ID 必须唯一；每个水平/垂直采样因子均为 `1..4`，所有分量的 `H × V` 之和不得超过 10；量化表 ID 为 `0..3`；
- SOS 必须一次包含 SOF0 的全部分量，每个分量恰好一次，段长度必须恰好为 `6 + 2 × component_count`；DC/AC Huffman 表 ID 均为 `0..3`；
- 基线顺序扫描参数必须为 `Ss = 0`、`Se = 63`、`Ah = 0`、`Al = 0`。

表段必须满足：

- DQT 只允许 8-bit 表，表 ID 为 `0..3` 且不得重复定义；每项定义恰好包含 64 个非零值，段内容必须正好耗尽；
- DHT 的表类别只能是 DC `0` 或 AC `1`，表 ID 为 `0..3`，同一 `(类别, ID)` 不得重复定义；16 个码长计数之和必须在 `1..256`，符号数据必须恰好耗尽段内容，码长计数不得构成过度订阅的 Huffman 树；
- SOS 引用的全部量化表和 Huffman 表必须已在 SOS 前定义；
- DRI 如果存在，段长度必须为 4；出现 RST Marker 时必须存在非零 restart interval，并从 RST0 开始按 RST0..RST7 循环递增。

生成器必须删除 APP1..APP15、Exif、XMP、ICC、IPTC、GPS 和 COM 注释，不得依赖 Exif Orientation；像素方向必须在编码前烘焙。平台解码后尺寸仍必须在 320 × 320 和 102,400 像素上限内。

协议解析器不需要自己实现 JPEG IDCT 或颜色转换，但必须在调用平台图片解码器前完成上述 Marker、表、长度、引用和 SOF0 尺寸检查。Marker 扫描输入上限天然为 10,240 字节。

结构检查通过但平台解码仍失败时，资料库 UI 必须只丢弃该 Preview 并显示原文件类型图标；已经成功解析的 Manifest 可以继续显示。此 UI 解码失败不得被描述为正文损坏。

### 5.5 Metadata Block v2 打包算法

```text
function pack_metadata_v2(manifest_bytes, optional_preview):
    require 1 <= len(manifest_bytes) <= 16384
    strictly_parse_and_reencode_manifest(manifest_bytes)

    block = ZEROES(16400)
    block[0, 8) = ASCII("SBOXMETA")
    block[8, 12) = I2OSP(len(manifest_bytes), 4)
    block[12, 12 + len(manifest_bytes)) = manifest_bytes

    if optional_preview is absent:
        return block

    validate_preview_descriptor_and_jpeg(optional_preview)
    P = len(optional_preview.encoded_bytes)
    require 1 <= P <= 10240

    O = 12 + len(manifest_bytes)
    require O + 24 + P <= 16400

    block[O, O + 8) = ASCII("SBOXPRVW")
    block[O + 8,  O + 10) = I2OSP(1, 2)
    block[O + 10, O + 12) = I2OSP(1, 2)
    block[O + 12, O + 14) = I2OSP(0, 2)
    block[O + 14, O + 16) = I2OSP(preview.width, 2)
    block[O + 16, O + 18) = I2OSP(preview.height, 2)
    block[O + 18, O + 20) = I2OSP(0, 2)
    block[O + 20, O + 24) = I2OSP(P, 4)
    block[O + 24, O + 24 + P) = preview.encoded_bytes
    return block
```

协议层不得截断 JPEG 来满足长度。产品层应重新缩放/压缩或省略 Preview。

### 5.6 Metadata Block v2 解包算法

实现必须在 Metadata AES-GCM Tag 验证成功后按以下顺序解析：

```text
1. 要求 block 长度恰好为 16400。
2. 严格比较 block_magic == ASCII("SBOXMETA")。
3. 读取 manifest_len，并要求 1..16384。
4. 以溢出安全方式计算 manifest_end = 12 + manifest_len。
5. 要求 manifest_end <= 16400。
6. 严格解析、规范重编码 Manifest，并逐字节比较。
7. 令 tail = block[manifest_end, 16400)。
8. 如果 tail 全零，返回 BundleMetadata(manifest, preview=null)。
9. 否则要求 len(tail) >= 24，并逐项验证 Preview 描述头。
10. 检查尺寸、像素数、data_len 和 preview_end 全部上限。
11. 要求 preview_end 后全部为零。
12. 有界检查 JPEG 子集和 JPEG 内尺寸。
13. 一次性返回完整 BundleMetadata。
```

除“平台图片解码失败”的 UI 回退外，Block 结构失败必须映射为 `invalidManifest`，不得返回部分文件名、部分说明或未经结构验证的 Preview。

## 6. v3.1 公共头与密码绑定

### 6.1 根头变化

根头总长度和全部偏移保持 v3.0。v3.1 只改变以下固定值：

| 绝对偏移 | 字段 | v3.0 | v3.1 |
|---:|---|---:|---:|
| `9` | `version_minor` | `0` | `1` |
| `516` | `metadata_format_id` | `1` | `2` |

下列值保持：

```text
header_len = 16992
metadata_kdf_alg = 1
metadata_aead_alg = 1
metadata_flags = 0
metadata_plaintext_len = 16400
metadata_ciphertext_len = 16400
```

### 6.2 延续分片

v3.1 延续分片仍为 128 字节，不含 Metadata。其 `version_minor` 必须为 `1`。同一 Bundle 的所有分片版本必须匹配根分片。

### 6.3 Metadata KDF

KDF 算法和域字符串保持 v3.0：

```text
metadata_info =
    ASCII("SBOX-v3/metadata-key")
    || 0x00
    || bundle_id
    || recipient_key_id
    || I2OSP(metadata_format_id, 2)
```

v3.1 的 `metadata_format_id = 2` 已进入 KDF，因此在其他输入相同时会得到不同于 v3.0 的 `metadata_key`。不得把 Format ID 固定写死为 1。

### 6.4 Metadata AAD

AAD 规则保持：

```text
metadata_aad =
    ASCII("SBOX-v3/metadata")
    || 0x00
    || root_header[0, 576)
```

原始 `[0,576)` 已包含版本 `3.1` 和 `metadata_format_id = 2`。不得解析后以默认常量重新编码 AAD。

### 6.5 正文绑定

根：

```text
header_hash = SHA-256(root_header[0, 16992))
```

Metadata 密文包含 Manifest 和 Preview，Metadata Tag 认证完整 16,400 字节明文，完整根头哈希又进入根 Data/Final 记录 AAD。因此修改 Preview 的任意字节将导致：

1. 未重算 Metadata Tag 时，快速 Metadata 认证失败；
2. 持有 SPKI 的攻击者即使重算 Metadata 密文和 Tag，完整根头哈希仍变化；
3. 没有 `bundle_dek` 时，攻击者不能让既有根正文记录继续通过认证。

OAEP Label、分片 KDF、记录 AAD 和正文记录类型全部保持 v3.0 的 `SBOX-v3/...` 域，不因次版本升级改名。

## 7. Preview 生成规范

### 7.1 分层要求

Preview 生成属于产品/平台层，不属于密码格式层。

- 平台层负责从用户选择的原始图片或视频取得像素；
- 产品层负责缩放、JPEG 编码、10 KiB 预算和用户开关；
- SBOX 格式层只接受已经生成的 `BundlePreview`，严格验证并打包；
- `BundleEncryptor`、`MetadataKdf` 和 `MetadataCipher` 不得依赖视频解码器、UI 或文件扩展名。

建议定义：

```dart
abstract interface class PreviewGenerator {
  Future<PreviewGenerationResult> generate(File source);
}

sealed class PreviewGenerationResult {}
final class PreviewGenerated extends PreviewGenerationResult {
  final BundlePreview preview;
  final String detectedSourceMediaType;
}
final class PreviewUnavailable extends PreviewGenerationResult {
  final PreviewUnavailableReason reason;
  final String? detectedSourceMediaType;
}
```

产品层原因枚举至少必须区分以下语义；名称可以按项目风格调整，但不得把它们写入 SBOX 或 Manifest：

```dart
enum PreviewUnavailableReason {
  userDisabled,
  unsupportedMediaType,
  platformUnsupported,
  decodeFailed,
  encodeFailed,
  timeout,
  resourceLimit,
  metadataCapacity,
  existingV30,
  existingV31WithoutPreview,
}
```

该枚举只用于低敏感度 UI/日志和上传结果，不得携带异常文本、路径或 codec 私有信息。`detectedSourceMediaType` 只有通过内容探测得到可信结果时才返回；Preview 失败不应迫使 Manifest 永远使用 `application/octet-stream`。

### 7.2 是否生成

只有同时满足以下条件才尝试生成：

- 用户没有关闭“生成加密缩略图预览”；
- 内容探测器确认源文件是受支持的静态图片或视频；
- 当前平台提供安全、有界的解码/取帧能力；
- 输入是可稳定重复读取的本地文件或等价快照。

不得只凭扩展名生成。扩展名、用户提供的 MIME 和实际解码结果冲突时，应省略 Preview，并继续上传。

GIF、APNG、动画 WebP、Live Photo、burst/多页图片和其他多帧图片不得偷偷取第一帧；它们在 v3.1 中按 `unsupportedMediaType` 省略 Preview。视频只走第 7.4 节的独立 poster 流程。

成功生成 Preview 时，Manifest 的 `media_type` 必须使用探测到的原始文件 MIME，并以 `image/` 或 `video/` 开头。未知或不可信格式继续使用安全的通用 MIME，且不生成 Preview。

### 7.3 图片处理

图片生成器必须：

1. 在完整像素分配前读取并检查源图尺寸；
2. 使用支持下采样的解码路径，避免为超大图片先分配完整位图；
3. 应用源文件方向，使输出不依赖 Exif Orientation；
4. 保持宽高比，最长边不超过 320；
5. 不放大原图；
6. 对透明像素使用固定不透明 sRGB 背景合成，建议 `#101820`；
7. 转为 8-bit 灰度或 sRGB 三通道；
8. 删除全部源 Metadata、色彩配置、GPS、注释和文件名；
9. 编码为非渐进基线 JPEG；
10. 验证最终字节、SOF0 尺寸和 10 KiB 上限。

编码器可以在以下候选内调整，不要求不同平台产生逐字节相同 JPEG：

```text
最大边候选：320, 288, 256, 224, 192, 160, 128, 96
质量候选：72, 64, 56, 48, 40, 32
```

实现应优先选择视觉质量较高且不超过 10,240 字节的候选。若所有候选均失败，返回 `PreviewUnavailable`，不得截断 JPEG。

### 7.4 视频 poster 取帧

视频只生成一张静态 poster。平台取帧器应按以下顺序选择时间：

```text
if duration is unknown or invalid:
    尝试首个可解码关键帧
else if duration < 2 seconds:
    target = duration / 2
else:
    target = clamp(duration * 0.10, 1 second, 10 seconds)
    target = min(target, duration - 100 milliseconds)
```

在目标时间失败时，可以回退到首个可解码关键帧。取出的像素继续执行第 7.3 节的缩放和 JPEG 编码规则。

不得把音轨、字幕、容器 Metadata、视频文件名或原始编码片段写入 Preview Record。

平台缺少视频解码器、codec 不支持、文件损坏、受 DRM 保护或取帧超时时，必须省略 Preview，不得阻止加密上传。

### 7.5 输入稳定性

Preview 应来自与最终加密正文相同的输入快照。文件实现至少应：

1. 在 Preview 生成前记录长度、最后修改时间和可用的平台文件标识；
2. Preview 生成后重新检查；
3. 继续执行现有两遍长度/SHA-256 输入变化检测；
4. 任一稳定性检查失败时丢弃 Preview，并按现有 `inputChanged` 语义终止本次上传。

本规则减少无意错配，但不把 Preview 提升为正文语义证明。

### 7.6 失败和超时

Preview 生成必须是非关键路径：

- 格式不支持、解码失败、编码失败、超时、空间不足时继续生成合法无 Preview v3.1 Bundle；
- 产品层可以显示“文件已上传，但未生成缩略图”；
- 日志只记录低敏感度原因枚举，不得记录源路径、文件名、图像字节或解码器转储；
- 若平台 API 创建临时帧文件，必须放入受保护临时目录，并在成功、失败、取消时删除；
- 优先使用内存管线，不得把未加密 Preview 保存到 `backup` 目录。

### 7.7 用户控制

图片/视频上传界面应提供“生成加密缩略图预览”开关。可以默认开启，但必须在设置或帮助中说明：持有完整公钥的人可以读取缩略图。

用户关闭后必须写入无 Preview 的 v3.1 Metadata Block，不能把本次选择持久化成独立旁路 Metadata。

## 8. 写入流程

v3.1 生成器必须按以下顺序执行：

1. 读取并验证用户 Preview 开关；
2. 捕获输入快照；
3. 尽力生成 `BundlePreview?`；
4. 再次验证输入快照；
5. 执行现有第一遍明文长度、MD5 和 SHA-256；
6. 构造并规范编码一次 `SBOX-MANIFEST-3`；
7. 验证 Preview 结构、JPEG 和 `maxPreviewBytes`；
8. 计算 Metadata Block 剩余容量；
9. 如果合法 Preview 放不下，省略 Preview，并向产品层返回 `previewEmbedded = false` 和原因 `metadataCapacity`；
10. 使用 Metadata Block v2 打包 Manifest 与可选 Preview；
11. 创建版本 `3.1`、`metadata_format_id = 2` 的根头前 576 字节；
12. 用 Format ID 2 派生 Metadata Key；
13. AEAD 加密完整 16,400 字节 Block；
14. 完成根头并计算完整根头哈希；
15. 按现有 v3 Data/Final 规则加密正文与延续分片；
16. 执行第二遍输入一致性检查；
17. 原子提交本地不可变对象；
18. 延续分片先上传，根分片最后上传；
19. 覆盖 Preview 像素、JPEG、Metadata Block、Metadata Key、`bundle_dek` 和分片密钥缓冲区。

如果调用格式层的 `BundlePreview` 本身超过 10,240 字节、尺寸非法或 JPEG 非法，格式层必须拒绝参数；“重新编码或省略”应由产品层明确处理，不能在底层静默截断。

建议扩展上传结果：

```dart
final class CloudBundleUploadResult {
  // existing fields...
  final bool previewRequested;
  final bool previewEmbedded;
  final PreviewUnavailableReason? previewUnavailableReason;
}
```

结果必须满足：`previewEmbedded == true` 时原因是 `null`；`previewEmbedded == false` 时原因非空。`previewRequested` 表示用户本次是否选择尝试生成，`previewEmbedded` 表示最终实际发布/复用对象是否含有 Preview，两者不得混为一个字段。

原因优先级必须稳定：复用既有对象时优先报告 `existingV30` 或 `existingV31WithoutPreview`；新建对象时，用户关闭优先为 `userDisabled`，否则依次报告实际生成失败原因或 `metadataCapacity`。不得因为 UI 开关关闭而把一个实际含 Preview 的既有 v3.1 对象报告成无 Preview。

## 9. 快速读取与完整解密

### 9.1 快速读取

快速读取流程必须：

```text
1. Range 读取根对象 [0, 16992)。
2. 解析版本和完整根头。
3. 检查路径、Bundle ID、分片角色和版本/Format ID 矩阵。
4. 用本地 SPKI 验证 recipient_key_id。
5. 按根头 metadata_format_id 派生 Metadata Key。
6. 用收到的原始 [0,576) 构造 AAD。
7. AES-GCM 认证解密 16400 字节 Metadata Block。
8. v3.0/Format 1 调用 Block v1 解析器，得到 manifest + preview=null。
9. v3.1/Format 2 调用 Block v2 解析器，得到 manifest + optional preview。
10. Manifest 与根头交叉验证。
11. 返回 BundleMetadata 和 metadataReadable。
```

仍然不得调用助记词、RSA 私钥、`bundle_dek` 或正文读取。

### 9.2 完整解密

完整解密必须重新读取当前根头，按版本选择正确 Metadata Block 解析器，并继续执行现有根头哈希、RSA、Data/Final、分片和整体摘要认证。

不得因为列表阶段已有 Preview 或 Manifest 缓存而跳过当前根头认证。缓存至少必须绑定到稳定远端 revision 和完整根头 SHA-256，才能作为性能提示。

### 9.3 Range 与数据源

GitHub、Gitee、本地目录和 HTTPS 数据源的 Range 请求长度不变。若某提供方忽略 `Range` 并返回 HTTP 200，现有有界切片兼容逻辑继续适用；本次 Preview 升级不能宣称此情况下网络一定只传输 16,992 字节。

### 9.4 无 SPKI 或 Preview 缺失

- 无匹配 SPKI：保留 `headerOnly`，显示通用文件图标；
- v3.0：显示 Manifest 信息和类型图标，不显示 Preview；
- v3.1 无 Preview：显示 Manifest 信息和类型图标；
- Preview JPEG UI 解码失败：显示 Manifest 信息和类型图标；
- 任何回退都不得自动要求助记词。

## 10. UI、缓存与资源预算

### 10.1 资料库行

有 Preview 时，资料库行应把现有 `FileTypeBadge` 替换为有圆角裁剪的缩略图区域：

- 桌面建议 72 × 72 逻辑像素；
- 移动端建议 56 × 56 逻辑像素；
- 使用 `BoxFit.cover`；
- 原始 Manifest `media_type` 为 `video/*` 时，可以叠加一个非交互播放图标；
- `errorBuilder` 必须回退到原文件类型 Badge；
- 缩略图本身不得触发自动打开或执行。

### 10.2 延迟解码

编码 JPEG 可以随 BundleMetadata 保存在内存中，但只允许为可见列表项调用平台图片解码。禁止在扫描 100,000 个候选时一次性解码全部 Preview。

### 10.3 内存预算

资料库层必须设置编码 Preview 总预算，默认最大 32 MiB：

```text
maxRetainedPreviewBytes = 32 * 1024 * 1024
```

超过预算时：

- 保留 Manifest；
- 可以保留 `hasPreview` 和描述头，但丢弃 JPEG 字节；
- 可见行需要时允许重新 Range 读取该根头；
- 不得因为预算不足把 Bundle 判为损坏。

解码图像应使用独立有界 LRU 或 Flutter `ImageCache` 限额。不得为每次 Widget rebuild 复制 10 KiB 字节数组。

### 10.4 磁盘缓存

第一阶段实现不得持久化未加密 JPEG 副本。后续如增加磁盘缓存，必须：

- 位于平台受保护缓存目录；
- 以远端 source ID、revision 和 root header hash 绑定；
- 可以随时清空；
- 不写入 Git 仓库、`backup` 根目录或云端；
- 不成为协议正确性的依赖。

## 11. 错误与降级语义

| 情况 | 处理 |
|---|---|
| 版本不是 3.0/3.1 | `unsupportedVersion` |
| 版本与 Metadata Format ID 不匹配 | `invalidHeader` |
| Metadata GCM Tag 失败 | `authentication` |
| Block Magic、长度、Preview 描述头或 padding 非法 | `invalidManifest` |
| Preview 超过 10,240 字节 | 写入参数拒绝；读取为 `invalidManifest` |
| Preview 尺寸或 JPEG Marker 非法 | 写入参数拒绝；读取为 `invalidManifest` |
| 平台 JPEG 解码失败 | 只回退图标，不丢弃已验证 Manifest |
| 本地 Preview 生成失败 | 无 Preview 继续上传，返回原因枚举 |
| Preview 因 Manifest 太大放不下 | 无 Preview 继续上传，返回 `metadataCapacity` |
| 编码 Preview 内存预算不足 | 丢弃 JPEG 字节，可按需重读 |
| 同 MD5 远端存在不同不可变字节 | `immutableConflict` |
| 同 Bundle 分片版本混合 | `shardMismatch` |

外部错误消息不得包含源文件名、路径、JPEG 数据、SPKI、派生密钥或云端私有 URL。

## 12. 文件级实施清单

以下清单按当前仓库结构编写。编码代理可以调整类名，但不得改变职责和协议行为。

### 12.1 `lib/sbox/constants.dart`

- 把单一 `versionMinor` 改为可表示读取版本集合和当前写入版本；
- 增加 v3.0/v3.1、Format 1/2、Preview Magic、描述头、10 KiB、尺寸和内存预算常量；
- 保持 `rootHeaderLength = 16992`、`metadataBlockLength = 16400`；
- 保持所有正文密码常量和 `SBOX-v3` 域字符串不变。

### 12.2 新增版本模型

建议新增 `lib/sbox/format/sbox_version.dart`：

```dart
final class SboxVersion {
  const SboxVersion(this.major, this.minor);
  static const v30 = SboxVersion(3, 0);
  static const v31 = SboxVersion(3, 1);
}
```

必须实现值相等、支持矩阵和当前写入版本，禁止在解析器各处散落 `minor == 0 || minor == 1`。

### 12.3 `lib/sbox/format/bundle_header.dart`

- `BundleHeader` 保存收到的版本；
- 编码构造器显式接收版本，默认只用于当前写入 v3.1；
- 解析器接受 3.0 和 3.1；
- 根头执行版本/Format ID 矩阵；
- 延续头保存版本，完整解密时与根头比较；
- AAD 和 `rawBytes` 仍使用线上原始字节；
- 根头和延续头长度不变；
- 不接受 v3.1 + Format 1 的宽松降级。

### 12.4 Metadata Block 模块

建议：

```text
lib/sbox/format/bundle_preview.dart
lib/sbox/format/baseline_jpeg_inspector.dart
lib/sbox/format/metadata_block.dart
```

职责：

- `BundlePreview`：不可变模型和基本上限；
- `BaselineJpegInspector`：10 KiB 内有界 Marker/尺寸检查；
- `MetadataBlockCodec`：按 Format ID 分派 v1/v2，负责精确 Block 布局；
- 现有 `ManifestBlock` 可以保留为 v1 私有实现，或迁移为 `MetadataBlockCodec._v1`；
- 不得在 Codec 中调用 UI 图片解码器。

### 12.5 `lib/sbox/format/bundle_manifest.dart`

- Schema 和字段集合不变；
- 不添加 Preview JSON 字段；
- 保持最大 16,384 字节；
- 继续返回唯一规范编码。

### 12.6 `lib/sbox/crypto/metadata_kdf.dart`

- 允许经过版本矩阵验证的 Format ID 1 或 2；
- KDF info 必须使用实际 Format ID；
- 保持 SPKI DER 为 IKM；
- 增加 Format 2 固定向量测试。

### 12.7 `lib/sbox/engine/bundle_encryptor.dart`

- `BundleEncryptionOptions` 增加可选 `BundlePreview`；
- 新写入一律使用版本 3.1、Format 2；
- Manifest 仍只编码一次；
- 使用 Metadata Block v2；
- Preview 放不下时遵守产品层降级契约；
- Preview 不进入正文记录；
- finally 覆盖 Preview 与 Block 明文缓冲区。

### 12.8 `lib/sbox/engine/background_bundle_crypto.dart`

- `_EncryptionRequest` 传递 Preview 描述和最多 10 KiB 字节；
- `readManifest` 应升级为返回 `BundleMetadata`，或新增 `readMetadata`；
- 后台 isolate 返回 Preview 时避免多次复制，可使用 `TransferableTypedData`；
- 保留兼容调用名时，不得悄悄丢掉 Preview。

### 12.9 `lib/sbox/engine/bundle_probe.dart`

- `BundleProbeResult` 增加 `BundlePreview?` 或统一 `BundleMetadata?`；
- 根据 Header Format ID 调用 v1/v2 Codec；
- Preview 只有 Metadata Tag 和结构全部通过后才返回；
- 快速读取继续不 import BIP39 或私钥派生。

### 12.10 `lib/sbox/engine/bundle_decryptor.dart`

- 完整解密支持 v3.0/v3.1；
- 所有分片版本必须与根一致；
- 按 Format ID 解析 Metadata；
- 根头哈希自然覆盖 Preview；
- 完整认证流程和原子明文发布保持。

### 12.11 `lib/sbox/source/bundle_listing.dart`

- Range 仍为 16,992；
- `ListedBundleRoot` 携带可选 Preview；
- 有界并发保持；
- 增加编码 Preview 32 MiB 保留预算或把预算交给资料库层；
- 预算丢弃不得丢 Manifest。

### 12.12 `lib/sbox/source/local_scanner.dart`

- `BundleCandidate` 携带可选 Preview 或统一的 `BundleMetadata`；
- 本地扫描与远端列表调用同一 Format 1/2 Metadata Codec，不能形成第二套宽松解析；
- 仍只读取根文件的 16,992 字节头来取得 Metadata，不为显示 Preview 读取正文；
- 与远端列表共享编码 Preview 内存预算和 UI 回退语义。

### 12.13 `lib/sbox/source/cloud_bundle_uploader.dart`

- 对已存在远端对象不能只按 basename 宣称与新 v3.1 字节相同；
- 保持不可变内容验证；
- 现有 v3.0 完整重复对象按第 2.4 节处理；
- 上传结果报告 Preview 是否嵌入；
- Preview 生成失败不改变双云成功语义。

### 12.14 Preview 平台层

建议新增：

```text
lib/platform/preview_generator.dart
lib/platform/preview_generation_result.dart
```

各平台实现可以使用安全的原生 API 或经过审查并固定版本的依赖。必须满足第 7 节，而不是由包的默认行为决定协议输出。

视频取帧支持可以按平台逐步交付；某平台暂不支持时必须返回 `PreviewUnavailable(platformUnsupported)`，不能伪造空 Preview。

### 12.15 上传入口

必须同时修改当前两个上传入口：

```text
lib/features/encrypt/encrypt_page.dart
lib/features/library/library_page.dart
```

- 上传前调用 PreviewGenerator；
- 增加 Preview 开关和低敏感度说明；
- 把 Preview 传给加密选项；
- 文件行显示 `Image.memory` 或等价内存图像；
- 解码失败回退 `FileTypeBadge`；
- 视频叠加静态播放标识；
- 不为 Preview 请求助记词；
- Preview 不参与文件路径、自动执行和 MIME 信任决策。

### 12.16 `lib/sbox/storage/local_bundle_index.dart`

- 第一阶段继续只缓存 Manifest；
- 不把 JPEG Base64 写入 JSON；
- 如缓存模型需要记录 `has_preview`，该值只能是性能提示，必须与 source revision 绑定；
- 删除索引后仍可从根头恢复 Preview。

### 12.17 项目元数据

- `pubspec.yaml` 描述更新为 SBOX 3.1；
- 如新增图片/视频依赖，必须固定精确版本并经过许可证与平台体积审查；
- README 说明新写入 3.1、读取 3.0/3.1；
- CI 增加纯 Dart 协议测试，平台取帧测试与协议测试分离。

## 13. 实施阶段

### 阶段 A：纯格式与兼容读取

- 引入版本模型；
- BundleHeader 读 3.0/3.1；
- 实现 BundlePreview、JPEG Inspector、Metadata Block v2；
- 保持全部 v3.0 固定向量通过；
- 新增 v3.1 固定向量。

### 阶段 B：加密与完整解密

- Writer 切换 3.1；
- Preview 进入 Block v2；
- Decryptor 支持两个版本并检查分片版本一致；
- 证明根头哈希绑定 Preview；
- 实现容量降级和缓冲区清理。

### 阶段 C：快速列表

- Probe/Background/ListedBundleRoot 返回 Preview；
- Range 长度保持；
- 增加内存预算；
- v3.0 和无 Preview 回退。

### 阶段 D：生成器和 UI

- 图片缩略图生成；
- 平台视频 poster 生成；
- 上传开关与状态反馈；
- 列表展示、延迟解码和错误回退。

### 阶段 E：云端重复对象与回归

- v3.0 重复上传语义；
- 同路径不同字节冲突；
- GitHub/Gitee Range/HTTP 200 回退；
- 双云、恢复本地副本、multipart 和空文件回归。

每一阶段必须独立通过静态分析和对应测试，不能等 UI 完成后才验证协议层。

## 14. 必测矩阵

### 14.1 正常路径

- 读取 v3.0 Format 1，Preview 为 null；
- 写入并读取 v3.1 无 Preview；
- 写入并读取 v3.1 图片 Preview；
- 写入并读取 v3.1 视频 poster Preview；
- Preview 恰好 10,240 字节；
- 中文 Manifest + Preview；
- 空文件、单分片、multipart；
- GitHub/Gitee/本地 Range 列举；
- 无助记词快速列表；
- 完整解密后 Preview 所在根头获得 `rootAuthenticated`；
- 删除本地索引后重建 Preview。

### 14.2 容量边界

- 无 Preview，Manifest 长度 16,384 成功；
- Preview 10,240 + Manifest 6,124 恰好填满成功；
- Preview 10,240 + Manifest 6,125 触发产品层省略 Preview；
- Preview 10,241 被格式层拒绝；
- Preview 1 字节最终因 JPEG 非法被拒绝；
- 所有长度加法溢出和越界被拒绝；
- Preview 后一个非零 padding 被拒绝。

### 14.3 Preview 描述头负向测试

逐项篡改并要求 `invalidManifest`：

- `SBOXPRVW` 任一字节；
- Preview version；
- codec ID；
- flags；
- width、height 为 0 或 321；
- 像素乘积超过 102,400；
- reserved 非零；
- data_len 为 0、10,241 或越界；
- 描述头截断；
- JPEG 数据截断；
- 第二个 Preview Record；
- Manifest 与 Preview 之间插入零或非零间隙。

### 14.4 JPEG 负向测试

- 缺 SOI 或 EOI；
- EOI 后附加字节；
- 缺 SOF0；
- 重复 SOF0、重复 SOS 或第二个扫描；
- SOF0 尺寸与描述头不同；
- 渐进式 SOF2；
- 16-bit 精度；
- 组件数不是 1/3；
- SOF0/SOS 段长度、分量 ID、采样因子或扫描参数非法；
- 缺失、截断、重复定义或格式非法的 DQT/DHT，零量化值、过度订阅 Huffman 树，或 SOS 引用未定义表；
- DRI 长度非法、没有有效 DRI 时出现 RST，或 RST 顺序错误；
- APP0 不是无内嵌缩略图的标准 JFIF；
- APP1 Exif、APP2 ICC、APP13 IPTC、APP14 或 COM；
- DAC、DNL、DHP、EXP、TEM、未知或保留 Marker；
- 熵数据中未转义的 `ff`，以及超过 256 个 Marker；
- Marker 长度越界、零长度、循环或截断；
- 结构合法但平台解码失败时 UI 回退而 Manifest 保留。

### 14.5 密码和信任负向测试

- 修改 Preview 密文导致 Metadata Tag 失败；
- 持有 SPKI 重算 Preview Metadata 后，旧根正文记录认证失败；
- 错误 SPKI 不返回 Manifest 或 Preview；
- 只持有 Key ID 不能读取 Preview；
- v3.1 + Format 1、v3.0 + Format 2 均拒绝；
- 根 3.1 + 延续 3.0 混合拒绝；
- Preview 不提升到 `rootAuthenticated`，直到全部根记录通过。

### 14.6 生成器与产品测试

- 透明图片按固定背景合成；
- Exif 方向被烘焙且 Exif 被删除；
- GIF、APNG、动画 WebP 或其他多帧图片不取第一帧，上传无 Preview；
- 超大图片使用下采样而不是完整像素分配；
- 质量/尺寸降级最终不超过 10 KiB；
- 所有候选过大时上传无 Preview；
- 视频目标时间和首帧回退；
- 视频 codec 不支持时上传继续；
- 用户关闭开关时不生成 Preview；
- 输入生成 Preview 期间变化时返回 `inputChanged`；
- 临时帧文件在成功、失败、取消后清理。

### 14.7 资源与 UI 测试

- 100,000 候选不一次解码全部 Preview；
- 编码 Preview 达到 32 MiB 后执行丢弃/按需重读；
- Widget rebuild 不复制每个 JPEG；
- 图片解码异常显示类型 Badge；
- v3.0、无 Preview、无 SPKI 均有正确回退；
- 搜索仍只使用 Manifest 文本，不扫描 JPEG 字节。

### 14.8 不可变与迁移测试

- 远端完整 v3.0 + 同明文新上传：复用旧对象且无 Preview；
- 本地 `backup` 完整 v3.0 + 云端缺失：上传既有 v3.0，结果为 `existingV30`，不原地生成 v3.1；
- 本地 v3.1 + 远端同路径 v3.0 不同字节：`immutableConflict`；
- 双云一边 v3.0、一边 v3.1 同路径不同字节：冲突，不自动覆盖；
- 旧本地 v3.0 备份仍可解密；
- 不创建 preview sidecar、Catalog 或额外远端对象。

## 15. v3.1 Metadata 固定向量

### 15.1 向量用途

本向量验证：

- Metadata Block v2 的动态 Preview 偏移；
- 24 字节 Preview 描述头；
- Format ID 2 的 HKDF；
- v3.1 Header AAD；
- AES-256-GCM 输出和完整根头哈希。

它不表示完整可解密 Bundle：`wrapped_bundle_dek` 使用 `0x55` 占位，逻辑正文摘要也只是固定测试字段。Preview JPEG 字节是冻结输入；实现不得尝试通过自己的 JPEG 编码器重新生成相同字节。

### 15.2 公共身份和根头输入

公共身份沿用 v3.0 固定向量：

```text
spki_der_len = 422
recipient_key_id = 9549c41744d3b469c512aa2c845677940937fd20685220fb0eb00f15082b04ae
```

SPKI DER 无 Padding Base64url：

```text
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAuuLMXcnG7m37vzI1006K27P077n8a7rS5BKwP4E60rXTjHedUcDRlg_4O0CQgFCjnaB3VEtKk7VZJX0ucD76N-agPrjGOuV5T0WQ4uw3g9914tSPJol8G9AkXZlYgU8RVCTnkgYNCkuR3TRsaP_5oW80ELOskT52PZ_OEKFusm8eBU0yDLpNkgRKNIqLmxL1saBtGGbY4v-sfcNwNT6XKLX505WqEzA3Ig6XQs6a7wR3KFP9uKettKLBiLlC3WO0WJF9BpRrNNtSo-UE8xA8Y6uYLQYuDlXYf2tzsIv6jh3aC1-UQW9HX1ljRsB7qUrmpf55QfRzUt_cdIBWTf8M7utQHGZhv30mQilNcwwNdnaLH4vdqHjH1bqJQrIhPzAqmbDjarZ-CCc1QpamATcoY9rN9-g1_qDd-DqfYPVm3vdhA2hc5jKQgf99LEP3Lbv6sPc8g6GmzX7n6yffyy0JyCDqAaxNRKokr1ZjDpKZDR4DGeX89UH18-CP857_w0XHAgMBAAE
```

根头输入：

```text
version = 3.1
bundle_id = a0a1a2a3a4a5a6a7a8a9aaabacadaeaf
shard_index = 0
shard_count = 1
shard_plaintext_size = 12345
nonce_prefix = a0a1a2a3
wrapped_bundle_dek = 0x55 repeated 384 times
metadata_format_id = 2
metadata_kdf_alg = 1
metadata_aead_alg = 1
metadata_flags = 0
metadata_salt = 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
metadata_nonce = 202122232425262728292a2b
```

### 15.3 规范 Manifest

以下 JSON 必须是一行、不带 BOM、使用 UTF-8 规范编码：

```json
{"bundle_id":"a0a1a2a3a4a5a6a7a8a9aaabacadaeaf","content_kind":"file","created_at":"2026-08-18T02:30:00Z","description":"固定缩略图向量","logical_plaintext_sha256":"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f","logical_plaintext_size":"12345","media_type":"image/jpeg","nominal_shard_plaintext_size":"16777216","original_name":"预览.jpg","recipient_key_id":"9549c41744d3b469c512aa2c845677940937fd20685220fb0eb00f15082b04ae","schema":"SBOX-MANIFEST-3","shard_count":1,"tags":["image","测试"],"title":"预览向量"}
```

```text
manifest_len = 546
manifest_sha256 = 85cb14f4f0c3382ee287f52e9a5aecfa41d0ad96dc19ddfd18b742f58a485f7f
preview_offset = 12 + 546 = 558
preview_data_offset = 558 + 24 = 582
```

### 15.4 冻结 Preview JPEG

Preview 描述：

```text
preview_version = 1
preview_codec_id = 1
preview_flags = 0
preview_width = 16
preview_height = 9
preview_reserved = 0
preview_data_len = 660
preview_data_sha256 = 8ae556f4b67c8b7e527364153bf9b659863959d364a24e5feb2455bf1f6cd7f1
preview_descriptor_hex = 53424f585052565700010001000000100009000000000294
preview_marker_sequence = SOI APP0 DQT DQT SOF0 DHT DHT DHT DHT SOS EOI
```

JPEG 标准 Base64（单行，无空格）：

```text
/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8lJCIfIiEmKzcvJik0KSEiMEExNDk7Pj4+JS5ESUM8SDc9Pjv/2wBDAQoLCw4NDhwQEBw7KCIoOzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozv/wAARCAAJABADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDntP8AB/T93+ldRp/g/p+7/StnTu1dTp/aow1eZw5NnGI01P/Z
```

### 15.5 Metadata Block 与 KDF

```text
metadata_block_sha256 = 5b0373f598149c300112960cb0dd1ac95b3c21af7beaa463df75261f79768204

metadata_prk = 811a337c0e308c48af62cbbb5cf4606cb3eb979f9a855db5d7e08761f28b7cde

metadata_info =
53424f582d76332f6d657461646174612d6b657900
a0a1a2a3a4a5a6a7a8a9aaabacadaeaf
9549c41744d3b469c512aa2c845677940937fd20685220fb0eb00f15082b04ae
0002

metadata_key = d23d95f7e18c515fc3850cfc7b7d326f0562169a7f38382c7de5fbd661f044b8
```

展示换行不属于 `metadata_info`。

### 15.6 AAD 与 AES-GCM 输出

```text
metadata_aad_len = 593
metadata_aad_sha256 = 7d3906954dcbab672543c0608860c307e86fce0194ed653ad03bb834dabf4736

metadata_ciphertext_sha256 = 69ec08e599dfc17c19b0881b9e3814a0e07059041455e8db717fcd0d9bcd82c2

metadata_ciphertext_first_64 =
e460ea5132161c52ea6dad509bd4bb00da5195a550c93b62bda7e89761323bac
05dc7d2773620e8702fde3170ac739aba3bfa725948710edd8612ccd7cf98efd

metadata_ciphertext_last_64 =
96b7da8338c2f9793c09e66106f871eaa8afd5a263da498997fe31a14d4cfaca
4ba02ed14519a4731945a4762777f8153416bc3e6942d233882239e66449a043

metadata_tag = bb0ee4bc1566639d64ef8c7b31811736
root_header_sha256 = 135b04ae5b2199a7fa99fde8b996c39d3cc4d50730a74008bc6db621976177ff
```

## 16. 明确禁止的实现方式

编码代理不得：

- 把 JPEG 写入 `description`、`title`、`tags` 或任何 Manifest JSON 字段；
- 使用 Base64、Hex、Data URI 作为协议内 Preview 表示；
- 创建 `*.preview`, `thumbnail.json`, `preview.sbox` 或其他远端 sidecar；
- 增大根头、改变 Range 长度或把 Preview 放入正文第一条 Data；
- 让 `metadata_flags` 暴露 Preview 是否存在；
- 支持任意 MIME、SVG、GIF 或未知 codec 的宽松解码；
- 遇到未知 Preview codec 时猜测格式；
- 仅凭文件扩展名生成或信任 Preview；
- 生成失败时让原文件上传失败；
- 为给旧 v3.0 文件增加 Preview 而覆盖不可变对象；
- 在列表阶段要求助记词或下载正文；
- 把 Preview 当作已验证正文、签名或恶意内容检测结果；
- 在日志、崩溃上报或分析事件中记录 Preview 字节或 Base64；
- 在验证长度前分配攻击者声明的图片尺寸；
- 删除 v3.0 读取能力或改写既有 v3.0 固定向量。

## 17. 完成定义

只有以下条件全部满足，本升级才算完成：

- [ ] 新 writer 只生成 SBOX 3.1 / Metadata Format 2；
- [ ] reader 同时严格读取 SBOX 3.0 和 3.1；
- [ ] 根头仍为 16,992 字节，Range 仍为 0..16,991；
- [ ] Metadata Block 仍为 16,400 字节；
- [ ] Preview JPEG 编码数据绝不超过 10,240 字节；
- [ ] Preview 描述头恰好 24 字节并按本文布局编码；
- [ ] 无 Preview 时尾部继续全零；
- [ ] `description` 和 Manifest JSON 不承载二进制 Preview；
- [ ] Manifest Schema 与字段集合保持 `SBOX-MANIFEST-3`；
- [ ] Format ID 2 正确进入 Metadata KDF；
- [ ] Preview 被 Metadata Tag 和完整根头哈希覆盖；
- [ ] 快速读取不调用助记词、RSA 私钥或正文下载；
- [ ] 图片和视频生成失败时上传无 Preview 继续成功；
- [ ] UI 对 v3.0、无 Preview、无 SPKI、解码失败均安全回退；
- [ ] UI 只延迟解码可见行并执行 32 MiB 编码预算；
- [ ] 不创建远端 sidecar、Catalog 或必须存在的 Preview 索引；
- [ ] 同 MD5 v3.0/v3.1 不可变冲突按本文处理；
- [ ] 全部 v3.0 既有测试和固定向量继续通过；
- [ ] 本文 v3.1 固定向量全部通过；
- [ ] 10 KiB、容量、JPEG、版本混合、密码篡改和资源测试全部通过；
- [ ] 静态分析和目标平台测试通过；
- [ ] README、版本说明和公钥隐私提示已更新。
