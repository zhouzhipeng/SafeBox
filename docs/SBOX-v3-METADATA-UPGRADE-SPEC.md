# SBOX v3.0 公钥可读私密元信息升级规范

> 状态：实现规范草案，供下一阶段直接编码使用  
> 日期：2026-08-18  
> 目标版本：SBOX `3.0`  
> 基线实现：当前仓库中的 SBOX v2.0 代码与 `docs/SBOX-v2-SPEC.md`

## 0. 规范地位与实施边界

### 0.1 规范关键词

本文中的“必须”“不得”“应当”“可以”分别对应 MUST、MUST NOT、SHOULD、MAY。实现者不得把“必须”降级为建议。

### 0.2 本文解决的问题

SBOX v3.0 必须同时满足：

1. `.sbox` 自身携带文件名、标题、创建时间等 Manifest 信息；
2. 仅持有 `.sbox`、对象路径和 `recipient_key_id` 的存储方不能读取 Manifest；
3. 客户端只使用本地已经持久化的完整 RSA 公钥 SPKI DER，即可快速读取 Manifest；
4. 快速读取 Manifest 不得要求助记词、RSA 私钥操作或 `bundle_dek` 解封；
5. 文件正文仍然只能由 RSA 私钥解封 `bundle_dek` 后恢复；
6. 加密仍只需要接收者 RSA 公钥，不得要求助记词；
7. 不引入第二套身份密钥、全局 Catalog 或必须存在的本地 Metadata 索引；
8. 完整解密时必须通过正文记录 AAD 中的完整根头哈希，认证头部唯一 Manifest 与正文属于同一 Bundle；
9. 根分片仍然是 Bundle 唯一的发现入口和提交标志。

### 0.3 不兼容策略

本次升级不考虑任何旧格式兼容性：

- 生产解析器只接受版本 `3.0`；
- 版本 `2.0`、其他主版本、其他次版本一律返回 `unsupportedVersion`；
- 不建立双解析器、迁移读取器、Legacy 类型或版本自动探测分支；
- 不原地升级旧 `.sbox`；旧对象必须由产品层重新导入明文并生成新 Bundle；
- 容器扩展名仍为 `.sbox`，Magic 保持不变，因此版本字节是唯一格式分界；
- 实现完成后，`docs/SBOX-v2-SPEC.md` 只可作为 Git 历史资料，不得继续作为生产行为依据。

### 0.4 与 v2 规范的关系

本文是面向现有代码库的升级实施规范。下列内容保持 v2 的语义，除非本文明确改写：

- 明文 MD5 作为 `bundle_id`；
- Bundle 路径和 multipart 命名；
- 根分片最后提交、最先删除；
- RSA Identity Profile 1 的确定性派生；
- RSA-3072、指数 `65537` 和规范 SPKI DER；
- RSA-OAEP-SHA256 封装 32 字节 `bundle_dek`；
- HKDF-SHA256 派生逐分片密钥；
- AES-256-GCM 分块记录、Data 和 Final 语义；
- 两遍读取、输入变更检测、临时文件和原子发布；
- Manifest 字段语义、Unicode/NFC、路径清理和资源上限；
- 数据源列举、不可变对象和缺片检测。

下列内容由本文完整替换：

- 容器版本和所有容器域分离字符串；
- 根分片头部长度与布局；
- 记录类型与根分片记录序列；
- 无私钥快速 Manifest 读取流程；
- 根对象大小计算；
- 本地索引在 UI 中的必要性；
- 与元信息可见性相关的威胁模型。

## 1. 设计摘要

v3.0 在根头中增加一个固定长度的“快速 Manifest 密文”。它是 Bundle 中唯一的 Manifest 持久化位置，并使用以下方式保护：

```text
完整、规范的 RSA SubjectPublicKeyInfo DER
        │
        ├─ HKDF-SHA256 + 每 Bundle 随机 salt
        │
        └─ metadata_key
                 │
                 └─ AES-256-GCM(固定长度 Manifest Block)
```

Manifest 必须只规范编码一次、只打包成一个固定长度 `manifest_block`，并且只使用由完整 SPKI DER 派生的 `metadata_key` 加密一次后写入根头。根分片正文不得再写 Manifest 记录；正文只包含 Data 和 Final 记录。

完整根头的 SHA-256 会进入根分片每条 Data/Final 记录的 AAD。私钥成功解封 `bundle_dek` 且根分片全部记录通过认证后，头部唯一 Manifest 即被正文密钥域绑定；空文件由唯一的 Final 记录完成该绑定。因此完整解密不需要、也不得查找第二份 Manifest 进行比较。

因为头部保存的是完整 Manifest，快速读取可以得到 `original_name`、`title`、`description`、`tags`、`created_at`、`media_type`、逻辑大小和摘要等全部现有字段。根头中不得出现这些字段的明文字节。

本方案没有执行“私钥加密、公钥解密”，也没有把 RSA 公钥直接当作 AES 密钥。

## 2. 安全边界

### 2.1 可见性等级

| 实体能力 | 可见公共头 | 可读快速 Manifest | 可解密正文 |
|---|---:|---:|---:|
| 只有 `.sbox` 和对象路径 | 是 | 否 | 否 |
| 额外持有 `recipient_key_id` | 是 | 否 | 否 |
| 持有完整规范 RSA SPKI DER | 是 | 是 | 否 |
| 持有匹配 RSA 私钥 | 是 | 是 | 是 |

### 2.2 关键安全声明

本方案只保证“对没有完整 SPKI DER 的存储方隐藏元信息”，不保证“对所有知道接收者公钥的人隐藏元信息”。

RSA 公钥在标准公钥密码学中不是秘密。本协议有意把完整 SPKI DER 额外当作一个低敏感度的元信息访问凭据。因此：

- 任何获得完整 SPKI DER 且能读取 `.sbox` 的实体，都可以读取该身份全部 v3 Bundle 的快速 Manifest；
- 后续分享公钥会追溯性地暴露旧 Bundle 的快速 Manifest；
- `metadata_salt` 不提供撤销、前向保密或公钥泄露后的历史保护；
- 公钥泄露不会直接帮助恢复 `bundle_dek` 或正文；
- 产品导出、复制或展示公钥时，必须提示“获得此公钥的人可以读取文件名和其他快速元信息，但不能读取文件内容”。

### 2.3 完整 SPKI 持有者可以伪造快速 Manifest

持有 SPKI DER 的实体可以派生 `metadata_key`，因此也可以生成新的有效快速 Manifest GCM Tag。这意味着快速 Manifest：

- 对不持有 SPKI 的存储方具有机密性和篡改检测；
- 对持有 SPKI 的实体不提供发布者真实性；
- 不得被 UI 描述为“发布者签名有效”或“文件内容已验证”；
- 只允许用于列表、检索、排序、图标和安全提示；
- 不得在完整解密认证前直接作为最终导出路径、自动执行依据或可信 MIME 决策。

快速 Manifest 位于完整根头内，而完整根头的 SHA-256 又进入所有正文记录的 AAD。持有 SPKI 但没有 `bundle_dek` 的攻击者可以伪造列表信息，却无法修改一个既有 Bundle 后仍通过正文 GCM 认证。

### 2.4 信任状态

客户端至少区分以下状态：

| 状态 | 含义 |
|---|---|
| `headerOnly` | 只通过公共头结构和路径检查 |
| `metadataReadable` | SPKI 派生密钥成功解密快速 Manifest，且 Manifest 规范合法 |
| `rootAuthenticated` | RSA 解封成功，根分片全部 Data/Final 记录及其序列通过认证，头部唯一 Manifest 已由正文密钥域绑定 |
| `complete` | 全部分片的 Data/Final、长度约束和整体 SHA-256 均验证成功 |

`metadataReadable` 不得显示为签名、发布者认证或完整文件认证。`rootAuthenticated` 只表示“当前 Manifest、根头和根正文由同一个 `bundle_dek` 绑定”，仍不表示发布者身份；任何持有接收者公钥的人都可以创建一个全新的合法 Bundle。

### 2.5 上线前安全评审门槛

把完整 RSA 公钥 SPKI 当作低敏感度访问凭据并不是常规公钥机密性模型，而是本产品有意选择的折中。固定向量、单元测试和代码审查不能替代密码协议评审。正式发布前必须由未参与实现的密码工程人员至少复核：

- SPKI 的实际存储、导出、日志和云同步路径；
- HKDF 域分离与 AES-GCM Nonce 生命周期；
- 快速 Metadata 可伪造与正文 AAD 绑定的边界；
- 公钥泄露后的追溯性 Metadata 暴露是否符合产品承诺；
- 各平台本地公共身份记录是否会被意外上传。

## 3. 算法与固定常量

### 3.1 外层容器

| 名称 | v3.0 固定值 |
|---|---:|
| Magic | `53 42 4f 58 0d 0a 1a 0a` |
| `version_major` | `3` |
| `version_minor` | `0` |
| 公共前缀长度 | `128` |
| 根头长度 | `16,992`，十六进制 `0x4260` |
| 延续分片头长度 | `128` |
| 根 RSA 密文长度 | `384` |
| Metadata 描述区长度 | `64` |
| Metadata 明文块长度 | `16,400` |
| Metadata 密文长度 | `16,400` |
| Metadata GCM Tag 长度 | `16` |
| Manifest JSON 最大长度 | `16,384` |
| GCM Nonce 长度 | `12` |
| 派生密钥长度 | `32` |

### 3.2 Metadata 算法 ID

| 字段 | 值 | 含义 |
|---|---:|---|
| `metadata_format_id` | `1` | 固定长度 Header Manifest Block |
| `metadata_kdf_alg` | `1` | HKDF-SHA256，IKM 为规范 SPKI DER |
| `metadata_aead_alg` | `1` | AES-256-GCM，12 字节 Nonce，16 字节 Tag |
| `metadata_flags` | `0` | v3.0 不定义任何 Flag |

未知 ID、非零 Flag 或不符合固定长度的描述区必须拒绝，不得尝试降级。

### 3.3 容器域分离字符串

v3.0 必须使用以下 ASCII 字节，不得使用本地化文本、末尾空格或隐式终止符：

| 用途 | ASCII 字符串 |
|---|---|
| Metadata KDF info 前缀 | `SBOX-v3/metadata-key` |
| Metadata AAD 前缀 | `SBOX-v3/metadata` |
| RSA-OAEP Label 前缀 | `SBOX-v3-bundle-DEK` |
| 分片 KDF info 前缀 | `SBOX-v3/shard-key` |
| 记录 AAD 前缀 | `SBOX-v3-record` |

每个前缀在与二进制字段拼接前都必须追加一个字节 `0x00`。禁止复用 v2 字符串。

RSA Identity Profile 1 内冻结的两个 `SBOX-v1` 派生字面量属于身份算法，不是容器域分离字符串，必须保持原值。

## 4. RSA 公共身份要求

### 4.1 规范 SPKI DER

Metadata KDF 的 IKM 必须是当前 `PublicIdentity.spkiDer` 的原始规范 DER 字节：

- DER 类型为 `SubjectPublicKeyInfo`；
- 算法 OID 为 RSA Encryption `1.2.840.113549.1.1.1`；
- `AlgorithmIdentifier.parameters` 必须显式为 DER `NULL`；
- 模数必须恰好 3072 位；
- 指数必须为 `65537`；
- DER 必须通过重新编码一致性检查；
- 不得使用 PEM 文本、Base64url 文本、RSA modulus、JSON 字符串或 Key ID 代替。

完整身份 ID 继续定义为：

```text
recipient_key_id = SHA-256(spki_der)
```

### 4.2 为什么禁止使用 Key ID 派生

`recipient_key_id` 已经写在每个公共头中，因此是公开值。实现不得执行以下任何形式：

```text
metadata_key = KDF(recipient_key_id)
metadata_key = SHA-256(recipient_key_id || ...)
metadata_key = KDF(PEM 文本)
```

只有完整、规范、逐字节一致的 `spki_der` 可以作为 Metadata HKDF 的 IKM。

### 4.3 公共身份持久化

现有 `SBOX-PUBLIC-IDENTITY-1` Schema 可以继续使用，因为身份 Profile 没有改变。客户端为了实现无助记词列表，必须在本地保留：

- `spki_der`；
- `recipient_key_id`。

不得为了快速元信息持久化 RSA 私钥、助记词、BIP39 Seed、`bundle_dek` 或分片密钥。

## 5. Manifest v3

### 5.1 JSON Schema

字段集合、类型和语义保持 v2 不变，唯一 Schema 字面量改为：

```json
"schema": "SBOX-MANIFEST-3"
```

Manifest 仍必须：

- 使用 UTF-8，无 BOM；
- 使用 RFC 8785 规范 JSON；
- 拒绝重复键、浮点数、无效 Unicode 和非规范表示；
- 重新编码后与输入字节完全一致；
- 长度为 `1..16,384` 字节；
- 严格校验 NFC、字段长度、路径字符、标签排序和 UTC 时间；
- 与根公共头的 Bundle ID、Key ID、分片数和根分片明文长度交叉验证。

### 5.2 唯一编码与唯一存储

生成器必须只调用一次规范 Manifest 编码，并得到：

```text
manifest_bytes = RFC8785_UTF8(BundleManifest)
```

生成器必须把 `manifest_bytes` 打包一次得到 `manifest_block`。该块在协议中的唯一持久化位置是根头中的 `metadata_ciphertext` 与 `metadata_tag`；根分片正文和延续分片不得保存第二份 Manifest、Manifest Block 或等价 JSON 副本。

实现可以在单次加密调用期间保留内存对象，但不得通过再次序列化来生成另一个协议副本。

## 6. 固定长度 Header Manifest Block

### 6.1 明文布局

`manifest_block` 恰好为 `16,400` 字节：

| 块内偏移 | 长度 | 字段 | 规则 |
|---:|---:|---|---|
| 0 | 8 | `block_magic` | ASCII `SBOXMETA` |
| 8 | 4 | `manifest_len` | 大端 uint32，`1..16,384` |
| 12 | `manifest_len` | `manifest_bytes` | 规范 Manifest v3 JSON |
| `12 + manifest_len` | 剩余 | `padding` | 必须全部为 `0x00` |

即使 Manifest 达到最大值，块末尾仍有 4 字节零填充。

### 6.2 打包算法

```text
require 1 <= len(manifest_bytes) <= 16384

manifest_block = ZEROES(16400)
manifest_block[0, 8) = ASCII("SBOXMETA")
manifest_block[8, 12) = I2OSP(len(manifest_bytes), 4)
manifest_block[12, 12 + len(manifest_bytes)) = manifest_bytes
```

### 6.3 解包算法

实现必须在 AEAD 认证成功后按以下顺序解析：

1. 要求明文长度恰好为 `16,400`；
2. 常量时间或等价严格比较 `block_magic`；
3. 读取大端 `manifest_len`；
4. 要求 `1 <= manifest_len <= 16,384`；
5. 要求 `12 + manifest_len <= 16,400`；
6. 要求其余字节全部为 `0x00`；
7. 严格解析 Manifest；
8. 重新规范化并与块内 `manifest_bytes` 逐字节比较；
9. 与根头交叉验证。

任何一步失败均不得返回部分文件名、部分 JSON 或容错解析结果。

## 7. Metadata 密钥派生

### 7.1 随机输入

每次创建新 Bundle，必须从操作系统 CSPRNG 独立生成：

| 名称 | 长度 |
|---|---:|
| `metadata_salt` | 32 字节 |
| `metadata_nonce` | 12 字节 |

不得从 `bundle_id`、文件名、时间、Key ID、`bundle_dek` 或分片 Nonce 派生这两个值。

重复上传若直接复用既有完整 Bundle，必须复用该 Bundle 的原始字节；如果重新执行加密，则必须重新生成全部随机值。

对同一规范 SPKI DER 和同一 `bundle_id`，生成器不得故意复用相同的 `(metadata_salt, metadata_nonce)` 组合。

### 7.2 HKDF-SHA256

Metadata KDF 必须按 [RFC 5869](https://www.rfc-editor.org/rfc/rfc5869.html) 执行标准 Extract + Expand：

```text
metadata_info =
    ASCII("SBOX-v3/metadata-key")
    || 0x00
    || bundle_id
    || recipient_key_id
    || I2OSP(metadata_format_id, 2)

metadata_prk = HKDF-Extract-SHA256(
    salt = metadata_salt,
    IKM  = spki_der
)

metadata_key = HKDF-Expand-SHA256(
    PRK  = metadata_prk,
    info = metadata_info,
    L    = 32
)
```

由于 `L = HashLen = 32`，Expand 的等价单块表达式是：

```text
metadata_key = HMAC-SHA256(
    key     = metadata_prk,
    message = metadata_info || 0x01
)
```

实现必须使用 HMAC-HKDF，不得替换为普通 SHA-256 拼接。

### 7.3 生命周期

`metadata_prk`、`metadata_key`、`metadata_info` 和解密后的 `manifest_block` 应在使用结束、失败或取消时尽力覆盖。`spki_der` 是可持久化公共身份材料，不要求覆盖。

## 8. v3 公共头二进制布局

本节全部无符号整数字段均使用大端编码。偏移为从当前分片第一个字节开始的绝对字节偏移，区间采用左闭右开表示。

### 8.1 128 字节公共前缀

| 偏移 | 长度 | 字段 | v3.0 规则 |
|---:|---:|---|---|
| 0 | 8 | `magic` | 固定 SBOX Magic |
| 8 | 1 | `version_major` | `3` |
| 9 | 1 | `version_minor` | `0` |
| 10 | 2 | `header_len` | 根 `16,992`；延续 `128` |
| 12 | 4 | `flags` | 根 `1`；延续 `0` |
| 16 | 2 | `key_profile_id` | `1` |
| 18 | 2 | `key_wrap_alg` | 根 `1`；延续 `0` |
| 20 | 2 | `payload_alg` | `1`，AES-256-GCM chunked |
| 22 | 2 | `shard_kdf_alg` | `1`，HKDF-SHA256 |
| 24 | 4 | `chunk_size` | `4,194,304` |
| 28 | 16 | `bundle_id` | 明文 MD5，保持现有规则 |
| 44 | 4 | `shard_index` | `0..shard_count-1` |
| 48 | 4 | `shard_count` | `1..10,000` |
| 52 | 8 | `shard_plaintext_size` | 当前分片明文长度 |
| 60 | 32 | `recipient_key_id` | SHA-256(SPKI DER) |
| 92 | 4 | `nonce_prefix` | 当前分片记录 Nonce 前缀 |
| 96 | 2 | `wrapped_key_len` | 根 `384`；延续 `0` |
| 98 | 2 | `reserved_0` | 必须为 0 |
| 100 | 28 | `reserved_1` | 必须全 0 |

### 8.2 根头扩展

根头总长度固定为 `16,992` 字节：

| 绝对偏移 | 长度 | 字段 | 固定值或含义 |
|---:|---:|---|---|
| 128 | 384 | `wrapped_bundle_dek` | RSA-OAEP 密文 |
| 512 | 4 | `metadata_magic` | ASCII `META` |
| 516 | 2 | `metadata_format_id` | `1` |
| 518 | 2 | `metadata_kdf_alg` | `1` |
| 520 | 2 | `metadata_aead_alg` | `1` |
| 522 | 2 | `metadata_flags` | `0` |
| 524 | 4 | `metadata_plaintext_len` | `16,400` |
| 528 | 4 | `metadata_ciphertext_len` | `16,400` |
| 532 | 32 | `metadata_salt` | CSPRNG |
| 564 | 12 | `metadata_nonce` | CSPRNG |
| 576 | 16,400 | `metadata_ciphertext` | AES-GCM 密文，不含 Tag |
| 16,976 | 16 | `metadata_tag` | AES-GCM Tag |

长度恒等式：

```text
128 + 384 + 64 + 16400 + 16 = 16992
```

### 8.3 延续分片

延续分片仍只有 128 字节公共前缀：

- `header_len = 128`；
- `flags = 0`；
- `shard_index >= 1`；
- `wrapped_key_len = 0`；
- 不包含 RSA 密文；
- 不包含 Metadata 描述区或 Metadata 密文。

### 8.4 头部解析顺序

解析器在任何 KDF、AES、RSA 或大内存操作前必须：

1. 读取至少 12 字节；
2. 检查 Magic；
3. 要求版本恰好为 `3.0`；
4. 要求 `header_len` 只能为 `128` 或 `16,992`；
5. 按 `header_len` 有界读取完整头；
6. 检查算法 ID、分片范围、长度范围和全部保留字节；
7. 检查根/延续角色组合；
8. 根头必须逐项检查 Metadata 描述区固定值；
9. 如调用方提供预期身份，先核对 `recipient_key_id`；
10. 只有上述检查全部成功后，才允许执行 Metadata KDF 或 AES-GCM。

实现不得根据未验证的 `metadata_plaintext_len` 或 `metadata_ciphertext_len` 分配内存；v3.0 只接受固定值。

## 9. 快速 Metadata AEAD

### 9.1 AAD

Metadata AAD 必须使用根对象中收到的原始头字节，不得解析后重新编码：

```text
metadata_aad =
    ASCII("SBOX-v3/metadata")
    || 0x00
    || root_header[0, 576)
```

AAD 长度固定为：

```text
16 + 1 + 576 = 593 bytes
```

`root_header[0,576)` 已包含版本、Bundle ID、Key ID、分片信息、根 Nonce 前缀、完整 `wrapped_bundle_dek`、Metadata 算法 ID、Salt 和 Nonce。

### 9.2 加密

使用 [NIST SP 800-38D](https://csrc.nist.gov/pubs/sp/800/38/d/final) 定义的 AES-GCM：

```text
metadata_ciphertext, metadata_tag = AES-256-GCM-ENCRYPT(
    key       = metadata_key,
    nonce     = metadata_nonce,
    plaintext = manifest_block,
    aad       = metadata_aad,
    tag_len   = 16
)
```

输出必须满足：

- `len(metadata_ciphertext) = 16,400`；
- `len(metadata_tag) = 16`；
- Tag 单独写在偏移 `16,976`；
- 不得截断 Tag；
- 不得把 Tag 拼入 `metadata_ciphertext_len`。

### 9.3 解密

客户端快速读取必须：

1. 从本地公共身份记录取得原始 `spki_der`；
2. 验证 `SHA-256(spki_der) == recipient_key_id`；
3. 从根头原始字节构造 KDF 输入和 AAD；
4. 执行 AES-GCM 认证解密；
5. 只有 Tag 验证成功后才解析 `manifest_block`；
6. 只有 Manifest 完整校验成功后才向 UI 返回字段。

通过 Key ID 检查后发生的 Tag 失败、错误 Salt、错误 Nonce、错误 AAD 和密文损坏应对外合并为低细节认证错误。显式 Key ID 不匹配仍按 `keyMismatch` 处理。日志不得记录文件名、SPKI DER、派生密钥或解密后的块。

## 10. 正文密码套件的 v3 域分离

### 10.1 RSA-OAEP Label

```text
oaep_label =
    ASCII("SBOX-v3-bundle-DEK")
    || 0x00
    || bundle_id
    || recipient_key_id
```

其他 RSA-OAEP 参数不变：RSA-3072、SHA-256、MGF1-SHA256、32 字节明文、384 字节密文。

### 10.2 分片 KDF

```text
shard_info_i =
    ASCII("SBOX-v3/shard-key")
    || 0x00
    || recipient_key_id
    || I2OSP(shard_index, 4)

shard_key_i = HKDF-SHA256(
    IKM  = bundle_dek,
    salt = bundle_id,
    info = shard_info_i,
    L    = 32
)
```

### 10.3 头哈希

```text
header_hash = SHA-256(header[0, header_len))
```

根分片必须哈希完整 `16,992` 字节，因此 Metadata 描述区、唯一 Manifest 密文和 Tag 全部被正文记录间接绑定。延续分片仍哈希 128 字节。

只有使用 `shard_key_0` 验证完根分片的完整合法记录序列后，客户端才可以把该头部 Manifest 的状态从 `metadataReadable` 提升为 `rootAuthenticated`。仅验证 Metadata GCM Tag 不得完成此状态提升。

### 10.4 记录 AAD

```text
record_aad =
    ASCII("SBOX-v3-record")
    || 0x00
    || header_hash
    || record_header
```

记录头必须使用线上原始 13 字节。

## 11. 正文记录序列

### 11.1 v3 记录类型

v3.0 正文只定义两种记录：

- `0x02` Data；
- `0xff` Final。

旧值 `0x01` 在 v3.0 中保留但未定义，解析器遇到它必须返回 `invalidRecord`。`BundleRecordType` 不得保留 Manifest 枚举值，`BundleRecordCodec` 也不得包含 Manifest 长度或解密分支。任何其他未知类型同样必须拒绝。

根分片第一条正文记录从绝对偏移 `16,992` 开始，延续分片第一条正文记录从绝对偏移 `128` 开始。Data 明文只承载文件内容；Final 只承载既有的分片完整性汇总字段。

### 11.2 根分片序列

非空根分片必须是：

```text
Data(index=1)
Data(index=2)
...
Data(index=data_record_count)
Final(index=data_record_count + 1, plaintext_len=48)
EOF
```

空文件的根分片必须是：

```text
Final(index=1, plaintext_len=48)
EOF
```

正文不使用记录索引 0。Data 索引必须从 1 连续递增，每条 Data 的明文长度必须为 `1..chunk_size`；Final 必须紧随最后一条 Data，或在空文件中成为第一条记录。Final 后必须立即 EOF。

### 11.3 延续分片序列

延续分片必须包含至少一条 Data，并采用与非空根分片相同的索引规则：

```text
Data(index=1)
...
Final(index=data_record_count + 1, plaintext_len=48)
EOF
```

延续分片不得为空，不得包含索引 0，也不得包含 Manifest 或其他记录类型。

### 11.4 唯一 Manifest 的正文绑定

Manifest 只存在于根头中，但根分片每条 Data 和 Final 的 AAD 都包含完整根 `header_hash`。完整解密必须验证预期的全部根记录、连续索引、Final 和 EOF；全部成功后，头部唯一 Manifest 才获得 `rootAuthenticated` 状态。

修改 Manifest 密文、Tag 或根头任意其他字节都会改变 `header_hash`，并使既有根 Data/Final 记录认证失败。空文件没有 Data，由 Final 记录承担同样的绑定。实现不得因为“至少一条记录已通过”就提前发布明文或跳过其余根记录。

## 12. v3 加密流程

生成器必须按以下顺序执行：

1. 严格验证输入 Metadata 和接收者公共身份；
2. 要求 SPKI DER 规范合法，并核对 Key ID；
3. 规划分片大小和数量；
4. 第一遍读取输入，计算实际长度、整体 SHA-256 和明文 MD5；
5. 使用 MD5 作为 `bundle_id`；
6. 构造 `SBOX-MANIFEST-3`，规范编码一次得到 `manifest_bytes`；
7. 打包一次得到固定 `manifest_block`；
8. 生成新的 `bundle_dek`、逐片 `nonce_prefix`、`metadata_salt` 和 `metadata_nonce`；
9. 使用 v3 OAEP Label 封装 `bundle_dek`；
10. 构造根头的字节区间 `[0,576)`；
11. 使用完整 SPKI DER 派生 `metadata_key`；
12. 使用 Metadata AAD 加密 `manifest_block`，填入根头密文和 Tag；
13. 计算完整根 `header_hash`；
14. 从 `Data(index=1)` 开始流式写根正文，并写 Final；空文件直接写 `Final(index=1)`；
15. 对延续分片按第 11 节写 Data 和 Final；
16. 完成第二遍整体长度和 SHA-256 检查；
17. 核对对象实际大小；
18. 先提交或上传延续分片；
19. 最后提交或上传根分片；
20. 尽力覆盖 Metadata 派生材料、Manifest Block、`bundle_dek` 和分片密钥。

生成器不得：

- 要求助记词来创建快速 Metadata；
- 从私钥派生 Metadata Key；
- 用 Key ID 代替 SPKI DER；
- 在正文中写入 Manifest 记录、Manifest Block 或 Manifest JSON 副本；
- 对同一 Bundle 规范编码或打包 Manifest 超过一次；
- 在 Metadata 加密完成后修改根头 `[0,576)`；
- 在计算 `header_hash` 后修改根头任意字节。

## 13. 无私钥快速读取流程

### 13.1 输入

快速读取只需要：

- 根对象规范 basename；
- 根对象前 `16,992` 字节；
- 本地 `PublicIdentity`，包含 SPKI DER 和 Key ID。

### 13.2 算法

```text
1. 严格解析 basename。
2. 严格解析完整根头。
3. 验证路径、bundle_id、shard_index、shard_count。
4. 验证本地 SHA-256(spki_der) 等于头中 recipient_key_id。
5. 派生 metadata_key。
6. 用原始 root_header[0,576) 构造 AAD。
7. AES-GCM 解密 metadata_ciphertext。
8. 严格解包 manifest_block。
9. 严格解析 BundleManifest。
10. Manifest 与根头交叉验证。
11. 返回 manifest 和状态 metadataReadable。
```

快速读取不得：

- 调用 BIP39 或 RSA 身份派生；
- 调用 RSA 私钥操作；
- 解封 `bundle_dek`；
- 下载 Data 记录；
- 自动打开、执行或导出文件；
- 在认证完成前逐步显示未验证 JSON 字段。

### 13.3 无本地 SPKI 的行为

如果本地没有匹配 `recipient_key_id` 的完整 SPKI DER：

- 对象仍可作为 `headerOnly` Bundle 列出；
- UI 显示通用名称，例如“加密文件”；
- 不得因为快速 Metadata 不可读而删除、隔离或判定对象损坏；
- 不得自动要求助记词；用户主动打开文件时再进入完整解锁流程。

## 14. 完整解密与头部 Manifest 认证

完整解密必须：

1. 严格读取并解析根头；
2. 优先从本地公共身份记录取得匹配 SPKI DER；
3. 如果本地没有 SPKI，本次操作必须是用户主动发起的完整解密，此时要求助记词并只派生一次临时 RSA 身份，使用其公共部分作为 SPKI；不得为了后台列表自动提示；
4. 使用该 SPKI DER 解密唯一 `manifest_block`，并严格解包、解析和交叉验证 Manifest；
5. 如果第 3 步尚未派生临时 RSA 身份，现在要求助记词并派生一次；
6. 要求临时身份的 `recipient_key_id` 与根头一致；若第 2 步使用了持久化 SPKI，还必须要求临时身份的 SPKI DER 与其逐字节一致；
7. 使用 v3 OAEP Label 解封 `bundle_dek`；
8. 立即释放 RSA 私钥和 BIP39 派生材料；
9. 从收到的原始 `16,992` 字节根头计算 `header_hash`，并派生 `shard_key_0`；
10. 按第 11 节解析根记录序列，拒绝 `0x01`、未知类型、索引 0、索引间隙和 Final 后附加字节；
11. 把根 Data 解密到受控临时输出，验证每条记录的 GCM Tag、AAD、索引和长度；空文件不得出现 Data；
12. 验证根 Final、根分片明文总长度、记录总数、EOF 以及 Manifest/根头交叉约束；
13. 只有全部根记录均成功后，才把唯一 Manifest 的状态提升为 `rootAuthenticated`；此时仍不得向最终路径发布明文；
14. 定位并严格验证全部延续分片的公共头；
15. 顺序解密全部延续分片，验证每片 Data、Final、明文长度和 EOF；
16. 验证完整逻辑明文长度、整体 SHA-256 和所有 Manifest 全局约束；
17. 只有全部成功后才原子发布明文，并把状态提升为 `complete`。

即使调用方已经在列表阶段缓存了解密后的 Manifest，完整解密仍必须重新读取当前根头，或证明缓存与当前根对象的稳定修订及完整根头哈希绑定。不得把陈旧缓存直接当作当前认证输入，也不得因为 Metadata Tag 已通过就跳过根 Data/Final 认证。

## 15. 对象大小与分片规划

### 15.1 固定开销

```text
record_overhead = 13 + 16 = 29
final_record_size = 13 + 48 + 16 = 77
```

### 15.2 上界公式

```text
data_record_count(P) =
    0,                         if P == 0
    ceil(P / 4,194,304),       otherwise

continuation_upper_bound(P) =
    128
    + P
    + 29 * data_record_count(P)
    + 77

root_upper_bound(P) =
    16,992
    + P
    + 29 * data_record_count(P)
    + 77

  = 17,069
    + P
    + 29 * data_record_count(P)
```

规划器不再接收 `manifestLength` 参数，因为唯一 Manifest 已包含在固定长度根头中，正文没有 Manifest 记录。

### 15.3 数据源检查

分片规划必须用新公式检查 `maxObjectBytes`。上传前还必须按实际文件长度再次检查。空文件根对象的最小长度为 `17,069` 字节。

## 16. 数据源列举与 UI

### 16.1 根头范围读取

v3.0 列举根对象时必须取得完整 `16,992` 字节根头。推荐流程：

1. 从规范 basename 筛选根候选；
2. 发起 `Range: bytes=0-16991`；
3. 要求响应长度恰好为 `16,992`；
4. 严格解析根头；
5. 用本地公共身份快速解密 Manifest；
6. 将可读字段交给资料库 UI。

实现可以按数据源 `maxParallelTransfers` 做有界并发，默认不超过 4。不得对最多 100,000 个候选无限并发。

### 16.2 检索

文件名、标题、说明、标签和时间检索可以直接使用 `metadataReadable` Manifest。实现可以建立内存索引或本地缓存，但协议正确性不得依赖缓存存在。

删除本地缓存后，只要本地 SPKI DER 仍存在，客户端必须能够从每个根头重新构建文件列表，且不要求助记词。

### 16.3 安全显示

- 所有字符串必须按不可信文本转义；
- `original_name` 只用于列表显示，完整认证前不得用于最终路径；
- `media_type` 只用于图标和提示，不得触发自动执行；
- 描述和标签不得解释为 Markdown、HTML 或命令；
- 日志不得记录 Manifest 明文、SPKI DER、派生密钥或带敏感路径的 URL。

## 17. 错误映射

v3.0 不要求增加新的外部错误码。推荐映射：

| 失败 | `SboxErrorCode` |
|---|---|
| 版本不是 3.0 | `unsupportedVersion` |
| 固定头或 Metadata 描述区非法 | `invalidHeader` |
| AEAD 成功后 Manifest Block 布局非法 | `invalidManifest` |
| 本地 SPKI 的 Key ID 不匹配 | `keyMismatch` |
| Metadata GCM Tag 失败 | `authentication` |
| `0x01`、未知记录类型、索引或记录序列非法 | `invalidRecord` |
| Manifest JSON 非规范 | `invalidManifest` |
| 路径、分片索引或 Manifest 交叉验证失败 | `shardMismatch` |
| 根头或 Metadata 密文截断 | `truncated` |

对外错误消息不得区分“错误 SPKI”和“Metadata Tag 被篡改”的密码学细节；应用内部可以保留不含秘密的阶段标识。

## 18. 代码改造清单

以下是实现模型必须覆盖的最小文件级工作。

### 18.1 常量与类型

`lib/sbox/constants.dart`

- 版本改为 `3.0`；
- `rootHeaderLength = 16992`；
- 增加 Metadata 描述区、块、密文、Salt、Nonce 和 Tag 常量；
- `maxManifestBytes` 保持 `16384`；
- 增加 `manifestBlockLength = 16400`；
- 删除 Manifest 记录类型；正文记录类型只保留 Data 和 Final；
- 注释和域名称全部改为 v3。

### 18.2 新模块

建议新增：

```text
lib/sbox/crypto/metadata_kdf.dart
lib/sbox/crypto/metadata_cipher.dart
lib/sbox/format/manifest_block.dart
```

职责必须分离：

- `MetadataKdf` 只接受验证后的 SPKI DER、Salt、Bundle ID、Key ID 和 Format ID；
- `MetadataCipher` 只负责固定 AES-GCM 输入输出和原始 AAD；
- `ManifestBlock` 只负责固定块打包、零填充校验和 Manifest 字节提取。

### 18.3 公共头

`lib/sbox/format/bundle_header.dart`

- 根构造器增加 Metadata 描述和密文字段；
- 根编码器写完整固定布局；
- 延续头保持 128 字节；
- 解析器严格验证所有 Metadata 固定字段；
- 提供原始头字节或不会丢失线上字节的解析结果，供 AAD 使用；
- 不得通过重新编码宽松解析对象来构造 Metadata AAD。

### 18.4 Manifest 与记录

`lib/sbox/format/bundle_manifest.dart`

- Schema 改为 `SBOX-MANIFEST-3`；
- 其他字段规则保持；
- 编码后仍检查 16 KiB。

`lib/sbox/format/bundle_record.dart`

- 记录 AAD 域改为 v3；
- 删除 Manifest 枚举、编码、加密、解密和长度分支；
- `0x01` 与其他未知类型一律返回 `invalidRecord`；
- Data 和 Final 索引从 1 开始并严格连续；
- 实现第 11 节的根/延续记录序列约束。

### 18.5 密码域

`lib/sbox/crypto/rsa_oaep.dart`

- OAEP Label 改为 v3。

`lib/sbox/crypto/shard_kdf.dart`

- KDF info 域改为 v3；
- 固定向量全部重算。

不得修改 `RsaIdentityProfile1` 内冻结的身份派生字面量。

### 18.6 引擎

`lib/sbox/engine/bundle_encryptor.dart`

- Manifest 编码一次；
- 构造一次 Manifest Block；
- 构造 `[0,576)` 后加密 Metadata；
- 完成根头后再计算 `header_hash`；
- 根正文直接从 `Data(index=1)` 开始；空文件直接写 `Final(index=1)`；
- 不生成任何正文 Manifest 记录或副本；
- 失败和 finally 路径覆盖所有新敏感缓冲区。

`lib/sbox/engine/bundle_probe.dart`

- 保留无密钥公共头探测；
- 新增只接受 `PublicIdentity` 的快速 Manifest API；
- 该 API 不得 import 或调用 BIP39/RSA 私钥派生；
- 返回明确的 `metadataReadable` 信任状态。

`lib/sbox/engine/bundle_decryptor.dart`

- 完整解密前先认证并解析头部唯一 Manifest Block；
- 根正文只接受 Data/Final 序列；
- 全部根记录认证成功后才返回 `rootAuthenticated`；
- 全 Bundle 验证前不得产生任何受控范围外明文；
- 其余分片重组保持。

`lib/sbox/engine/bundle_planner.dart`

- 使用固定根开销；
- 删除 `manifestLength` 规划参数；
- 更新边界测试。

### 18.7 数据源与 UI

`lib/sbox/source/bundle_listing.dart`

- 根 Range 长度从 512 改为 16992；
- 有界并发；
- 保留路径与头绑定检查。

`lib/features/library/library_page.dart`

- 扫描后使用 `controller.identityRecord` 转换出的 `PublicIdentity` 快速解密；
- 直接显示文件名、类型和时间；
- 不为列表要求助记词；
- 打开文件时仍进入 RSA 私钥解锁；
- UI 不把快速 Metadata 标成发布者认证。

`lib/sbox/storage/local_bundle_index.dart`

- 可以保留为性能缓存；
- 不得成为列表恢复的必要条件；
- 删除缓存后必须能仅凭根头和本地 SPKI 重建。

### 18.8 清理要求

实现完成后对 `lib/` 和 `test/` 静态搜索：

- 容器代码不得残留 `SBOX-v2` 域字符串；
- 不得存在 v2 解析分支；
- 不得存在“私钥加密 Metadata”实现；
- 不得用 `recipient_key_id` 作为 Metadata KDF 的 IKM；
- 唯一允许保留的旧版本文字是身份 Profile 1 中冻结的 `SBOX-v1` 字面量及明确的版本拒绝测试。

## 19. 必测安全与格式矩阵

### 19.1 正常路径

- 空文件、单分片和 multipart 往返；
- 文件和 UTF-8 文本；
- 中文文件名、标题、说明和标签；
- 最大合法 Manifest；
- 仅公钥快速读取不调用 RSA 私钥；
- 删除本地索引后仍能快速重建列表；
- 非空根分片第一条记录是 `Data(index=1)`；
- 空文件根分片唯一记录是 `Final(index=1)`；
- 根记录全部认证后状态为 `rootAuthenticated`；
- 根最后提交和 multipart 缺片检测。

### 19.2 Header 负向测试

逐项篡改并要求拒绝：

- 版本、`header_len`、Flags 和算法 ID；
- `metadata_magic`；
- Format/KDF/AEAD ID；
- 非零 Metadata Flag；
- 两个固定长度字段；
- Salt、Nonce、密文和 Tag；
- RSA 密文、Bundle ID、Key ID 或根 Nonce 前缀；
- 根/延续角色与长度组合；
- 截断到 `16,991` 字节。

### 19.3 Manifest Block 负向测试

- 错误 `SBOXMETA`；
- `manifest_len = 0`；
- `manifest_len > 16384`；
- 长度越界；
- 非零 Padding；
- 非 UTF-8；
- 重复 JSON 键；
- 非规范 JSON；
- Schema 不是 `SBOX-MANIFEST-3`；
- Manifest 与头字段不一致。

### 19.4 正文记录负向测试

- 出现旧 Manifest 类型 `0x01`；
- 出现任何未知记录类型；
- 出现索引 0、首个索引不为 1、重复索引或索引间隙；
- Data 明文长度为 0 或超过 `chunk_size`；
- 空文件出现 Data；
- 延续分片没有 Data；
- Final 缺失、重复、索引错误或明文长度不是 48；
- Final 后存在附加字节；
- 只提供完整根头而不提供 Final；
- 修改根头任意字节后复用原正文记录。

### 19.5 密钥边界测试

- 正确 SPKI 成功；
- 只给 Key ID 不能调用 Metadata KDF；
- 同一 RSA modulus 的非规范 SPKI 编码被身份解析器拒绝；
- PEM 文本不得产生相同接口调用；
- 错误 SPKI 返回认证/Key mismatch，不泄漏更多细节；
- 相同 SPKI、不同 Salt 派生不同 Key；
- 相同 Bundle、不同 Salt/Nonce 产生不同 Metadata 密文；
- SPKI 持有者能读 Metadata，但不能解封 `bundle_dek`；
- SPKI 持有者修改快速 Metadata 后，既有正文记录必须因完整头哈希变化而认证失败。

### 19.6 资源与模糊测试

- 解析器在验证固定长度前不分配攻击者声明大小；
- 100,000 候选对象不无限并发；
- Metadata 解密失败不保留部分 Manifest；
- 取消、异常和超时路径清理派生 Key 与明文 Block；
- Header、Block 和 Record 解析器执行随机字节 fuzz；
- 所有长度加法先检查溢出。

## 20. Metadata 固定向量

### 20.1 向量用途

该向量只验证 SPKI KDF、固定 Manifest Block、Metadata AAD、AES-GCM 和根头哈希。`wrapped_bundle_dek` 使用占位字节，不是有效 OAEP 密文，因此该向量不是完整可解密 Bundle。

### 20.2 公共身份

助记词使用现有 Profile 1 固定向量：

```text
abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about
```

规范 SPKI DER 的无 Padding Base64url：

```text
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAuuLMXcnG7m37vzI1006K27P077n8a7rS5BKwP4E60rXTjHedUcDRlg_4O0CQgFCjnaB3VEtKk7VZJX0ucD76N-agPrjGOuV5T0WQ4uw3g9914tSPJol8G9AkXZlYgU8RVCTnkgYNCkuR3TRsaP_5oW80ELOskT52PZ_OEKFusm8eBU0yDLpNkgRKNIqLmxL1saBtGGbY4v-sfcNwNT6XKLX505WqEzA3Ig6XQs6a7wR3KFP9uKettKLBiLlC3WO0WJF9BpRrNNtSo-UE8xA8Y6uYLQYuDlXYf2tzsIv6jh3aC1-UQW9HX1ljRsB7qUrmpf55QfRzUt_cdIBWTf8M7utQHGZhv30mQilNcwwNdnaLH4vdqHjH1bqJQrIhPzAqmbDjarZ-CCc1QpamATcoY9rN9-g1_qDd-DqfYPVm3vdhA2hc5jKQgf99LEP3Lbv6sPc8g6GmzX7n6yffyy0JyCDqAaxNRKokr1ZjDpKZDR4DGeX89UH18-CP857_w0XHAgMBAAE
```

```text
spki_der_len = 422
recipient_key_id = 9549c41744d3b469c512aa2c845677940937fd20685220fb0eb00f15082b04ae
```

### 20.3 根头输入

```text
bundle_id = a0a1a2a3a4a5a6a7a8a9aaabacadaeaf
shard_index = 0
shard_count = 1
shard_plaintext_size = 12345
nonce_prefix = a0a1a2a3
wrapped_bundle_dek = 0x55 repeated 384 times
metadata_format_id = 1
metadata_kdf_alg = 1
metadata_aead_alg = 1
metadata_flags = 0
metadata_salt = 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
metadata_nonce = 202122232425262728292a2b
```

### 20.4 规范 Manifest

以下必须是一行 UTF-8，Markdown 中仅为阅读换行展示；实现测试应通过规范编码器生成：

```json
{"bundle_id":"a0a1a2a3a4a5a6a7a8a9aaabacadaeaf","content_kind":"file","created_at":"2026-08-18T02:30:00Z","description":"","logical_plaintext_sha256":"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f","logical_plaintext_size":"12345","media_type":"application/pdf","nominal_shard_plaintext_size":"16777216","original_name":"报告.pdf","recipient_key_id":"9549c41744d3b469c512aa2c845677940937fd20685220fb0eb00f15082b04ae","schema":"SBOX-MANIFEST-3","shard_count":1,"tags":["archive","报告"],"title":"年度报告"}
```

```text
manifest_len = 532
manifest_sha256 = d871d24b5e8d29a657e5fd61451303611e8cdee672c164d02e2cf17d216fc02c
manifest_block_sha256 = 1b3cad3851adf15a0a884688e932bca2a74d7050406374984e4fdf9ff4148332
```

### 20.5 KDF 结果

```text
metadata_prk = 811a337c0e308c48af62cbbb5cf4606cb3eb979f9a855db5d7e08761f28b7cde

metadata_info =
53424f582d76332f6d657461646174612d6b657900
a0a1a2a3a4a5a6a7a8a9aaabacadaeaf
9549c41744d3b469c512aa2c845677940937fd20685220fb0eb00f15082b04ae
0001

metadata_key = a71cf966c2d3fa3d24208547744ae0c954e4520d32875d318baaaeb4cbf640cf
```

拼接后的 `metadata_info` 不包含上面展示用的换行。

### 20.6 AAD 与 AES-GCM 结果

```text
metadata_aad_len = 593
metadata_aad_sha256 = 447d8dafe8682c43ee6a7167c0b3547c4906d85f9ac8de85091b33887e0bab8a

metadata_ciphertext_sha256 = c3cdebb4884045c47a7090158a71255d3ea13296212b1793e77a58723e89f1d9

metadata_ciphertext_first_64 =
ef16d9992d5e3691ff65bb706c89a2a25682cb6854cd9916e7a03587906c2d48
837fdbf60c6e81ebaea02270853fc18f7a8b0c7fc3663631558acc628873c021

metadata_ciphertext_last_64 =
be31263dcec8f4a7778a6f3ccdf95bb9c8aa26a0b33e667dea0544948a223006
f00e911bbfe596f5e9b3f29658692453815fd68b1b4601309dfad97125bec34e

metadata_tag = b7db6863c4307b75c0caf65a59c9caa6
root_header_sha256 = 83d445f2b9ce12ea7f5938260955019feac1b508a80e0d38fafe69d8992e52d3
```

## 21. 完成定义

实现只有在以下条件全部满足时才算完成：

- [ ] 生产代码只接受 SBOX 3.0；
- [ ] 根头恰好为 16,992 字节，延续头恰好为 128 字节；
- [ ] Metadata KDF 只使用规范 SPKI DER 作为 IKM；
- [ ] Key ID 不能单独解密快速 Metadata；
- [ ] 快速列表完全不调用助记词或 RSA 私钥；
- [ ] Manifest 只规范编码一次，并且只在根头中持久化一份；
- [ ] 正文不存在 Manifest 记录，`0x01` 和其他未知类型均被拒绝；
- [ ] 非空根正文从 `Data(index=1)` 开始，空文件从 `Final(index=1)` 开始；
- [ ] 根 `header_hash` 覆盖完整 Metadata 密文和 Tag；
- [ ] 全部根 Data/Final 认证成功后才进入 `rootAuthenticated`；
- [ ] OAEP、分片 KDF 和记录 AAD 全部使用 v3 域字符串；
- [ ] 规划器使用 17,069 字节根固定开销公式；
- [ ] 删除本地 Metadata 索引后仍可仅凭 SPKI 重建列表；
- [ ] 错误、取消和异常路径不泄漏派生 Key 或 Manifest；
- [ ] 固定向量全部通过；
- [ ] 空文件、单分片、multipart、云端 Range 列举和 UI 检索测试全部通过；
- [ ] 不存在 v2 兼容分支或私钥反向加密实现；
- [ ] UI 明确区分 `metadataReadable`、`rootAuthenticated` 与 `complete`。
