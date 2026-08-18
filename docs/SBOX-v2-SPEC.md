# SBOX v2 无 Catalog 分片文件集协议与实施规范

| 项目 | 值 |
|---|---|
| 协议名称 | SafeBox Bundle Protocol |
| 协议标识 | `SBOX` |
| 当前版本 | `2.0` |
| 文档状态 | Draft / AI 实施基线 |
| 更新日期 | 2026-08-17 |
| 核心模型 | 一个逻辑文件对应一个不可变 Bundle；`shard_index = 0` 是根分片，其余是延续分片 |
| 全局目录 | 不存在；不得为 v2 创建或依赖 `catalog.sbox` |
| 默认分片明文大小 | 16 MiB，即 `16,777,216` 字节 |
| 内容加密 | AES-256-GCM 分块认证加密 |
| Bundle 密钥封装 | RSAES-OAEP，Hash=SHA-256，MGF1=SHA-256 |
| 分片密钥派生 | HKDF-SHA256 |
| 默认扩展名 | `.sbox` |
| 主要实现语言 | Flutter + Dart |

> 本文是给 AI 编码代理和人工实现者共同使用的可执行规范。除明确标记为“建议”或“未来扩展”的内容外，字段、字节布局、验证顺序、失败行为和资源上限均属于实现要求。实现者不得根据方便程度自行更换算法、忽略保留字段、放宽解析或提前发布未完成认证的明文。

## 0. 给 AI 编码代理的执行摘要

实现前必须先理解以下不可更改的设计决策：

1. SBOX v2 没有全局 `catalog.sbox`。每个逻辑文件都是一个独立、不可变的 Bundle。
2. 不分片文件在存储层是一个无分片后缀的根对象；只有 `shard_count >= 2` 时才使用分片文件名。
3. 每个 Bundle 在线协议中仍统一使用 `shard_index = 0` 的根对象；在 multipart 中它也称为“根分片”。根对象同时包含：
   - RSA-OAEP 封装的随机 `bundle_dek`；
   - 加密且认证的完整 Manifest；
   - 第 0 段文件内容。
4. `shard_index > 0` 的延续分片不包含 Manifest，也不包含 RSA 封装密钥，只包含最小公共头、加密数据记录和 Final 记录。
5. 每个分片使用从同一个 `bundle_dek` 和自身索引派生出的独立 AES-256-GCM 密钥。整个 Bundle 解密时只允许执行一次 RSA 私钥解封。
6. `bundle_id` 使用原始明文的 MD5（16 字节、32 位小写十六进制），用于内容寻址和重复文件去重；不得使用原始文件名：

   ```
   # 不分片
   <bundle_id>.sbox

   # 有分片
   <bundle_id>_<shard_index>_<shard_count>.sbox
   ```

7. 规范对象直接放在已配置的数据源根目录，规范数据源相对路径就是规范对象名：

   ```
   <规范对象名>
   ```

   不得创建 `objects/` 目录，也不得按 `bundle_id` 前缀建立子目录。

8. 发布 multipart 时必须先上传全部延续分片，最后上传根分片；不分片时只上传唯一根对象。根对象是该 Bundle 的提交标记。
9. 解密时可以并行下载，但必须按索引顺序解密到临时文件；只有全部分片、每片 Final、总长度和整体 SHA-256 都验证成功后才能发布最终明文。
10. 文件名和远端路径始终是不可信输入。`bundle_id`、`shard_index`、`shard_count` 必须以内嵌公共头和解密后的 Manifest 为准并交叉验证。
11. 生产代码只支持 SBOX 2.0；不得保留旧容器解析、Catalog、迁移、双写或 Legacy 模式。
12. 现有用户修改不得被覆盖。实施应分阶段进行，每个阶段都必须保持测试可运行。

## 1. 规范用语与记号

本文中的“必须（MUST）”“不得（MUST NOT）”“应该（SHOULD）”“不应该（SHOULD NOT）”和“可以（MAY）”按 RFC 2119 / RFC 8174 解释。

除非另有说明：

- 所有整数均为无符号整数。
- 多字节整数均使用大端序。
- 字节区间采用半开区间 `[start, end)`。
- `SHA-256(X)` 表示对字节串 `X` 计算 SHA-256。
- `ASCII("...")` 表示不含结尾 NUL 的 ASCII 字节。
- `I2OSP(x, n)` 表示将整数 `x` 编码为恰好 `n` 字节的大端字节串。
- `||` 表示字节串连接。
- `HEXLOWER(X)` 表示小写、无分隔符的十六进制编码。
- “逻辑文件”表示用户看到的完整文件或 UTF-8 文本。
- “Bundle”表示一个逻辑文件对应的全部 SBOX v2 分片集合。
- “根分片”表示 `shard_index = 0` 的分片。
- “延续分片”表示 `shard_index > 0` 的分片。
- “Data 记录分块”表示单个分片内部的 AES-GCM 记录；它与外层分片不是同一层级。
- “发布明文”表示把临时输出原子移动、复制或暴露到用户可访问的最终位置。

## 2. 产品目标

SBOX v2 的目标是把任意单个文件或 UTF-8 文本加密成一个可独立存放、列举、复制和恢复的不可变 Bundle，并删除全局 Catalog 带来的同步、合并和单点目录状态。

协议必须满足：

1. 没有对应 RSA 私钥的实体不能恢复文件内容或 Manifest 中的原始文件名、标题、说明和标签。
2. 存储方对头部、记录、分片内容的修改、截断、调换、重复或混入必须可被检测。
3. 每个 Bundle 自己携带恢复所需的完整信息，不依赖全局目录。
4. 大文件可以流式加密和解密，不需要把完整明文载入内存。
5. 一个 Bundle 只进行一次 RSA-OAEP 私钥解封；每片内容密钥由 HKDF 派生。
6. 同一明文重复上传时必须复用相同的 `bundle_id`；首次加密仍独立生成 `bundle_dek`、Nonce 和密文，重复内容应直接复用已存在的完整 Bundle，不得执行新的上传。
7. 根分片必须足以确定规范分片路径、分片总数、逻辑总长度和整体摘要。
8. 延续分片必须保持最小化，但仍可独立完成格式边界检查，并在获得根密钥后完成认证。
9. 不得因为后续分片认证失败而遗留或发布部分明文。
10. 本地目录、GitHub、Gitee 等可列举数据源必须能在没有 Catalog 的情况下发现根分片。
11. 不可列举的 HTTPS 数据源必须支持从一个已知根分片 URL 开始恢复其余分片，或明确报告不支持。
12. 任何版本号不是 `2.0` 的 SBOX 都必须报告“不支持的协议版本”；`catalog.sbox` 不得进入读取或写入流程。

## 3. 明确非目标

SBOX v2 基线不提供：

- 全局条目列表的一致快照；
- Catalog generation、哈希链、三方合并或墓碑；
- 跨设备逻辑删除传播；
- 原地修改标题、说明、标签或文件名；
- 对合法旧 Bundle 的独立回滚检测；
- 发布者身份真实性证明；
- 隐藏 Bundle 内各分片之间的关联；
- 隐藏分片数量、密文大小、上传时间和访问模式；
- 纠删码、缺片恢复或奇偶校验；
- 目录树打包、自动 ZIP 解压或解密后自动执行；
- 对非可列举 HTTPS 目录的全库浏览；
- 服务器到服务器的跨数据源自动镜像。

需要修改 Metadata 时，必须创建一个全新的 Bundle。需要删除时，执行针对特定 Bundle 的物理删除；删除不是可同步的逻辑事件。

## 4. 威胁模型与可见信息

### 4.1 攻击者能力

假定攻击者可以：

- 读取、复制、长期保存和离线分析全部 `.sbox`；
- 列举公开数据源中的对象路径；
- 修改、截断、替换、删除、遗漏、重复或调换任意分片；
- 把其他 Bundle 的分片混入当前 Bundle；
- 获得接收者 RSA 公钥和完整协议实现；
- 使用接收者公钥创建新的、可被接收者解密的 Bundle；
- 回滚到一个旧但密码学上合法的完整 Bundle；
- 观察密文长度、Bundle 分组、分片数量、上传和访问时间。

假定攻击者不能：

- 读取妥善离线保存的助记词；
- 在可信加解密操作期间读取应用进程内存；
- 控制正在运行的可信客户端；
- 破解 RSA-3072、AES-256-GCM、HKDF-SHA256 或 SHA-256。

### 4.2 公开可见字段

公开存储方可以看到：

- `bundle_id`；
- 各分片属于同一 Bundle；
- `shard_index` 和 `shard_count`；
- 每片声明的明文长度；
- 接收者 `recipient_key_id`；
- 分片对象大小和大致逻辑文件大小；
- 版本、算法 ID 和记录分块大小。

公开存储方不得从规范对象名或公共头中直接获得：

- 原始文件名；
- 标题、说明、标签；
- 媒体类型；
- 逻辑文件整体 SHA-256；
- 文件明文。

如果产品提供“可读文件名模式”，该模式属于非规范、降低隐私的导出模式，UI 必须明确警告。远端规范写入不得启用该模式。

### 4.3 真实性限制

SBOX v2 基线提供机密性和密文完整性，但不证明发布者身份。知道 RSA 公钥的任何人都可以创建一个新的合法 Bundle。客户端必须把解密后的内容继续视为不可信输入，不得显示“发布者签名有效”。

## 5. Bundle 总体模型

### 5.1 统一不分片与 multipart

所有逻辑文件统一使用 Bundle 模型：

- 空文件：`shard_count = 1`，唯一根对象的数据长度为 0，文件名没有分片后缀。
- 小文件：`shard_count = 1`，唯一根对象包含 Manifest 和全部内容，文件名没有分片后缀。
- 大文件：`shard_count >= 2`，根分片包含 Manifest 和第 0 片内容，后续分片只包含延续内容。

分片数计算：

```
if logical_plaintext_size == 0:
    shard_count = 1
else:
    shard_count = ceil(
        logical_plaintext_size / nominal_shard_plaintext_size
    )
```

第 `i` 片的期望偏移和长度：

```
offset_i = i * nominal_shard_plaintext_size

length_i = min(
    nominal_shard_plaintext_size,
    logical_plaintext_size - offset_i
)
```

multipart 中除最后一片外，每片长度必须恰好等于 `nominal_shard_plaintext_size`。multipart Bundle 的最后一片长度必须大于 0。

### 5.2 不可变性

`bundle_id` 一旦发布，其所有对象、公共头、Manifest 和内容都不可变。

- 不得覆盖同一路径下内容不同的对象。
- 重试上传相同字节是幂等操作。
- 修改任意 Metadata 或内容必须生成新的 `bundle_id` 和 `bundle_dek`。
- 不得复用旧 Bundle 的 `bundle_dek`、Nonce 或分片密钥。

### 5.3 根对象作为提交标记

一个 Bundle 只有在根对象存在时才被视为“可发现的已提交候选”。不分片时根对象是唯一对象；multipart 时根对象就是索引 0 的根分片。

写入顺序必须为：

1. 生成并本地验证全部对象；
2. 若 `N > 1`，提交或上传索引 `1..N-1` 的延续分片；
3. 最后提交或上传索引 `0` 的根对象。

删除顺序应该相反：

1. 先删除根对象，使 Bundle 不再被正常列举；
2. 再删除延续分片。

multipart 根分片存在不等于 Bundle 完整。读取端仍必须检查所有期望分片。

## 6. 密码套件与密钥层级

### 6.1 身份与 RSA

`key_profile_id = 1` 表示 SafeBox RSA Identity Profile 1。它是生产代码中唯一的身份 Profile，不得建立 Profile 选择器。该 Profile 保留现有确定性 RSA 映射，使身份模块成为独立的通用密码学组件；这不授权读取其他容器版本。

#### 6.1.1 助记词与 BIP39 Seed

新身份从操作系统 CSPRNG 读取 16 字节熵，按 BIP39 官方英文词表生成带校验码的 12 词助记词。恢复身份时必须执行同样的 BIP39 校验。单词和附加 passphrase 均先做 UTF-8 NFKD；本 Profile 的附加 passphrase 固定为空字符串。

```text
mnemonic_sentence = 12 个英文单词以单个 ASCII 空格连接

bip39_seed = PBKDF2-HMAC-SHA512(
    password   = NFKD(UTF8(mnemonic_sentence)),
    salt       = NFKD(UTF8("mnemonic")),
    iterations = 2048,
    output_len = 64
)
```

程序不得允许用户自行挑选新身份的单词。助记词等同于根私钥，不得进入日志、剪贴板历史、遥测、普通存储或 SBOX 对象。

#### 6.1.2 RSA DRBG

从 `bip39_seed` 派生 48 字节：

```text
drbg_okm = HKDF-SHA512(
    IKM  = bip39_seed,
    salt = ASCII("SBOX-v1/BIP39-to-RSA3072"),
    info = ASCII("HMAC-DRBG-SHA256/instantiate"),
    L    = 48
)

entropy_input = drbg_okm[0, 32)
nonce         = drbg_okm[32, 48)
personalization_string = ASCII("SBOX-v1/RSA-3072")
```

上述两个包含 `SBOX-v1` 的字面量是已冻结的 RSA Profile 1 算法输入字节，不是容器版本标识。最终代码必须把它们封装在中性命名的 `RsaIdentityProfile1` 中；不得保留 `SboxV1` 类型、版本分派或其他旧协议依赖，也不得修改这些字节后仍声称 `key_profile_id = 1`。

按 NIST SP 800-90A Rev.1 实例化 HMAC_DRBG-SHA256：

- 安全强度请求为 128 位；
- `prediction_resistance = false`；
- 不 reseed；
- 所有 Generate 的 `additional_input` 为空；
- 候选素数和 Miller-Rabin 底数使用同一个连续 DRBG 状态；
- 每次 Generate 后都执行标准状态更新，即使 `additional_input` 为空；
- 单次 Generate 最多输出 65,536 字节。

不得替换为操作系统 RNG、通用库默认 RSA KeyGen 或其他 DRBG，否则同一助记词将无法恢复同一身份。

#### 6.1.3 确定性 RSA-3072

固定参数：

```text
nlen = 3072
L = 1536
e = 65537
lower_bound = ceil(sqrt(2) * 2^1535)
```

每个候选素数必须按以下顺序处理：

1. 从连续 HMAC_DRBG 读取 192 字节，按大端整数解释为 `x`；若为偶数则加 1。
2. 要求 `lower_bound <= x < 2^1536`。
3. 要求 `GCD(x - 1, 65537) = 1`。
4. 使用 `3..65521` 的全部奇素数试除。
5. 按 FIPS 186-5 附录 B.3.1 做 4 轮 Miller-Rabin；每轮底数也从同一 DRBG 读取 192 字节，直到满足 `1 < b < x - 1`。
6. 按 FIPS 186-5 附录 B.3.3 做一次 General Lucas Probabilistic Primality Test；Lucas 测试不消耗 DRBG 输出。
7. 进入 Miller-Rabin 前被拒绝的候选不得额外消耗 DRBG 输出。

先生成 `p`，候选上限 `5 * nlen = 15,360`；再使用同一 DRBG 状态生成 `q`，候选上限 `10 * nlen = 30,720`，且必须满足：

```text
abs(p - q) > 2^1436
```

计算：

```text
lambda = LCM(p - 1, q - 1)
d      = e^(-1) mod lambda
```

若 `d <= 2^1536`，继续使用当前 DRBG 状态重新生成一对素数，外层最多 16 次。最终规范化为 `p > q`，要求 `bit_length(p * q) = 3072`，并计算 `dP`、`dQ` 和 `qInv = q^(-1) mod p`。任何上限耗尽或自检失败都必须终止，不得降级算法。

#### 6.1.4 公钥编码、Key ID 与持久化

RSA 公钥必须编码为 DER `SubjectPublicKeyInfo`：算法 OID `1.2.840.113549.1.1.1`，`AlgorithmIdentifier.parameters` 显式为 DER `NULL`。完整身份 ID 为：

```text
recipient_key_id = SHA-256(spki_der)
```

本地 RSA-only 公共身份记录必须恰好使用以下 Schema；`spki_der` 是无 padding 的 Base64url：

```json
{
  "schema": "SBOX-PUBLIC-IDENTITY-1",
  "key_profile_id": 1,
  "spki_der": "base64url-without-padding",
  "recipient_key_id": "64-lowercase-hex-characters"
}
```

读取时必须严格检查字段集合、DER 规范编码、3072 位模数、指数 `65537` 和 Key ID。PEM `PUBLIC KEY` 可以由 DER 派生，不需要重复持久化。旧公共身份记录不迁移；用户可以用助记词重新生成 RSA-only 记录。

公钥和 `recipient_key_id` 可以持久化。助记词、BIP39 Seed、HMAC_DRBG 状态、`p`、`q`、`d`、CRT 参数和私钥 DER 不得持久化。Profile 1 不派生 Ed25519；Catalog signer 字段和相关代码必须从最终生产代码中删除。

#### 6.1.5 RSA 身份固定向量

以下公开助记词只用于测试，绝对不得用于真实身份：

```text
abandon abandon abandon abandon abandon abandon
abandon abandon abandon abandon abandon about
```

期望值：

| 项目 | 值 |
|---|---|
| BIP39 passphrase | 空字符串 |
| `bip39_seed` | `5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4` |
| `drbg_okm` | `1abf8d87ee7320c33c1d5d567a1c095ee166f5c8563d4f3cb2347f09ccfc543be28e7fff1eebb75789d92fba9a0375da` |
| `p` 候选计数 | `2600` |
| `q` 候选计数 | `197` |
| `recipient_key_id` | `9549c41744d3b469c512aa2c845677940937fd20685220fb0eb00f15082b04ae` |

任一值不一致都表示实现不符合 `key_profile_id = 1`，不得生成生产身份。

### 6.2 Bundle 随机材料

每次创建 Bundle 必须从操作系统 CSPRNG 独立生成：

| 名称 | 长度 | 用途 |
|---|---:|---|
| `bundle_id` | 16 字节 | Bundle 唯一标识和规范路径 |
| `bundle_dek` | 32 字节 | Bundle 根密钥，只被 RSA 封装，不直接用于 GCM |
| `nonce_prefix_i` | 每片 4 字节 | 当前分片的 GCM Nonce 前缀 |

任何两次加密不得故意复用这些值。

### 6.3 RSA-OAEP 封装

只有根分片包含 RSA-OAEP 密文。

```
oaep_label =
    ASCII("SBOX-v2-bundle-DEK")
    || 0x00
    || bundle_id
    || recipient_key_id

wrapped_bundle_dek = RSAES-OAEP-ENCRYPT(
    public_key = recipient_rsa_public_key,
    message    = bundle_dek,
    hash       = SHA-256,
    mgf1_hash  = SHA-256,
    label      = oaep_label
)
```

RSA-3072 的 `wrapped_bundle_dek` 必须恰好为 384 字节。

### 6.4 分片密钥派生

`bundle_dek` 不得直接用作 AES-GCM 密钥。每片密钥按索引独立派生：

```
shard_info_i =
    ASCII("SBOX-v2/shard-key")
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

实现必须使用标准 HKDF-Extract + HKDF-Expand，不得把上述表达式替换为普通 SHA-256 拼接。

### 6.5 GCM Nonce

每条记录的 12 字节 Nonce 为：

```
nonce = nonce_prefix_i || I2OSP(record_index, 8)
```

同一分片内 `record_index` 不得重复。生成器必须在达到 `2^64 - 1` 前拒绝继续。

### 6.6 密钥生命周期

- 加密只需要 RSA 公钥，不得要求助记词。
- 解密根分片时只执行一次 RSA 私钥操作。
- RSA 解封成功并核对身份后，应立即释放 RSA 私钥、BIP39 Seed 和相关大整数引用。
- `bundle_dek` 只保留到当前 Bundle 解密结束、失败或取消。
- 每个 `shard_key_i` 应按片派生、使用并尽力覆盖，不应同时保留全部分片密钥。
- 任务结束后必须尽力覆盖可变密钥缓冲区并终止专用 Crypto Isolate。

## 7. 对象命名与目录布局

### 7.1 规范文件名

`bundle_id` 使用 32 位小写十六进制。分片索引和分片总数使用无前导零的规范十进制；数值 0 必须编码为 ASCII `0`。

不分片，即 `shard_count = 1`：

```
canonical_basename =
    HEXLOWER(bundle_id)
    || ".sbox"
```

有分片，即 `shard_count >= 2`：

```
canonical_basename =
    HEXLOWER(bundle_id)
    || "_"
    || DECIMAL_CANONICAL(shard_index)
    || "_"
    || DECIMAL_CANONICAL(shard_count)
    || ".sbox"
```

示例：

```
# 不分片
8f26b86b3d334223b18c2f65a263c91a.sbox

# 3 个分片
8f26b86b3d334223b18c2f65a263c91a_0_3.sbox
8f26b86b3d334223b18c2f65a263c91a_1_3.sbox
8f26b86b3d334223b18c2f65a263c91a_2_3.sbox
```

`shard_index` 范围为 `0..shard_count-1`，最大值为 `9999`。`shard_count` 范围为 `2..10000`。文件系统的字典序不是分片顺序；读取器必须解析十进制字段并按数值索引排序。

`<bundle_id>_0_1.sbox`、`<bundle_id>_00_3.sbox`、`<bundle_id>_0_03.sbox` 和省略 multipart 总数的名称都不是规范文件名。

ASCII 规范匹配表达式：

```
unsharded:
^[0-9a-f]{32}\.sbox$

multipart:
^([0-9a-f]{32})_(0|[1-9][0-9]*)_([1-9][0-9]*)\.sbox$
```

正则匹配后仍必须执行数值范围检查：multipart 总数至少为 2 且不超过 10,000，索引必须小于总数。不得使用大小写不敏感匹配，也不得接受 Unicode 数字。

### 7.2 规范数据源路径

```
canonical_source_path = canonical_basename
```

示例：

```
8f26b86b3d334223b18c2f65a263c91a.sbox
8f26b86b3d334223b18c2f65a263c91a_0_3.sbox
8f26b86b3d334223b18c2f65a263c91a_1_3.sbox
8f26b86b3d334223b18c2f65a263c91a_2_3.sbox
```

“数据源根目录”指用户选择的本地目录，或远端数据源配置的仓库/路径前缀。所有规范 SBOX 对象必须是该根目录的直接子文件。协议不得创建 `objects/`、Bundle 子目录或分片子目录；嵌套目录中的 `.sbox` 不属于该数据源的规范对象，也不得被递归列举。

数据源根目录不得创建或依赖 `catalog.sbox`。

### 7.3 路径验证

规范读取器必须：

1. 把数据源返回的相对路径视为不可信字符串；
2. 要求规范路径只包含一个 ASCII basename，拒绝绝对路径、正斜杠、反斜杠、NUL、空段、`.`、`..`、嵌套目录和 URL 编码绕过；
3. 解析 basename 中的候选 Bundle ID，以及可选的索引和总数；
4. 读取公共头后要求 basename、`bundle_id`、`shard_index` 和 `shard_count` 完全一致；
5. 从 Manifest 推导规范 basename，不得接受 Manifest 自带任意对象路径；
6. 不得因为 basename 看似合法而跳过头部认证。

文件名形式与公共头必须满足：

- 无分片后缀只允许对应 `flags = ROOT`、`shard_index = 0`、`shard_count = 1`；
- 带分片后缀时 `shard_count` 必须至少为 2，索引和总数必须与公共头一致；
- multipart 根分片的规范名称为 `<bundle_id>_0_<shard_count>.sbox`；
- 同一 multipart 的所有文件名必须重复相同的 `shard_count`；
- `shard_count = 1` 时不得写成 `_0_1.sbox`。

本地“散装导入”可以允许根对象被重命名，但只能把文件名作为定位提示。解析公共头后必须使用头部 Bundle ID 和总数，并要求用户选择或搜索其余规范分片。

## 8. SBOX v2 公共头

### 8.1 Magic 与版本

SBOX v2 复用 8 字节 Magic：

```
53 42 4f 58 0d 0a 1a 0a
```

版本字节必须为：

```
version_major = 2
version_minor = 0
```

解析器先读取 12 字节并要求版本恰好为 `2.0`，然后读取 `header_len`。任何其他版本必须立即报告 `unsupportedVersion`，不得进入第二套解析器。

### 8.2 公共前缀

所有 v2 分片都有恰好 128 字节的公共前缀：

| 偏移 | 长度 | 字段 | 规范值或含义 |
|---:|---:|---|---|
| 0 | 8 | `magic` | SBOX Magic |
| 8 | 1 | `version_major` | `2` |
| 9 | 1 | `version_minor` | `0` |
| 10 | 2 | `header_len` | 根分片 `512`；延续分片 `128` |
| 12 | 4 | `flags` | bit 0 为 `ROOT`；其余位必须为 0 |
| 16 | 2 | `key_profile_id` | `1` |
| 18 | 2 | `key_wrap_alg` | 根分片 `1`；延续分片 `0` |
| 20 | 2 | `payload_alg` | `1` = AES-256-GCM chunked |
| 22 | 2 | `shard_kdf_alg` | `1` = HKDF-SHA256 |
| 24 | 4 | `chunk_size` | 生成器必须写 `4,194,304` |
| 28 | 16 | `bundle_id` | 原始明文 MD5，用于 Bundle 内容寻址 |
| 44 | 4 | `shard_index` | `0..shard_count-1` |
| 48 | 4 | `shard_count` | `1..10,000` |
| 52 | 8 | `shard_plaintext_size` | 当前分片实际明文长度 |
| 60 | 32 | `recipient_key_id` | 接收者 RSA Key ID |
| 92 | 4 | `nonce_prefix` | 当前分片随机 Nonce 前缀 |
| 96 | 2 | `wrapped_key_len` | 根分片 `384`；延续分片 `0` |
| 98 | 2 | `reserved_0` | 必须为 0 |
| 100 | 28 | `reserved_1` | 必须全为 0 |

### 8.3 根分片扩展

根分片在公共前缀后追加 384 字节：

| 偏移 | 长度 | 字段 |
|---:|---:|---|
| 128 | 384 | `wrapped_bundle_dek` |

因此根分片 `header_len = 512`。

### 8.4 根分片约束

根分片必须同时满足：

- `flags = 0x00000001`；
- `shard_index = 0`；
- `header_len = 512`；
- `key_wrap_alg = 1`；
- `wrapped_key_len = 384`；
- 具有 384 字节根扩展。

### 8.5 延续分片约束

延续分片必须同时满足：

- `flags = 0`；
- `shard_index >= 1`；
- `header_len = 128`；
- `key_wrap_alg = 0`；
- `wrapped_key_len = 0`；
- 不得具有根扩展。

### 8.6 公共头验证顺序

解析器在任何 RSA 或大内存分配之前必须：

1. 检查最小长度；
2. 检查 Magic 和版本；
3. 检查 `header_len` 只可能是 128 或 512；
4. 检查全部算法 ID；
5. 检查全部保留字节为 0；
6. 检查根/延续角色组合；
7. 检查分片索引和总数；
8. 检查声明长度不超过平台和协议上限；
9. 如调用方提供预期身份，核对 `recipient_key_id`；
10. 读取完整头后计算：

```
header_hash = SHA-256(header[0, header_len))
```

SBOX v2.0 解码器必须要求 `chunk_size = 4,194,304`，不得把其他 2 的幂静默当作兼容值。`shard_plaintext_size` 必须不超过 512 MiB；延续分片必须大于 0，根分片只有在 `shard_count = 1` 时才可以为 0。涉及 64 位长度的解析和计算必须使用不会溢出的整数类型；Dart 实现应先使用 `BigInt` 验证范围，再转换为平台 `int`。

## 9. 加密记录

### 9.1 记录二进制布局

每条记录为：

| 偏移 | 长度 | 字段 |
|---:|---:|---|
| 0 | 1 | `record_type` |
| 1 | 8 | `record_index` |
| 9 | 4 | `plaintext_len` |
| 13 | `plaintext_len` | `ciphertext` |
| 13 + `plaintext_len` | 16 | GCM Tag |

记录头为前 13 字节：

```
record_header =
    record_type
    || I2OSP(record_index, 8)
    || I2OSP(plaintext_len, 4)
```

### 9.2 记录类型

| 值 | 名称 | 允许位置 |
|---:|---|---|
| `0x01` | Manifest | 仅根分片第一条记录 |
| `0x02` | Data | Manifest 后或延续分片开头 |
| `0xff` | Final | 每个分片最后一条记录 |

未知记录类型必须拒绝。

### 9.3 AAD

```
record_aad =
    ASCII("SBOX-v2-record")
    || 0x00
    || header_hash
    || record_header
```

`record_header` 必须使用密文中原始的 13 字节，不得解析后重新构造为宽松等价值。

记录加密必须恰好执行：

```
ciphertext, tag = AES-256-GCM-ENCRYPT(
    key       = shard_key_i,
    nonce     = nonce_prefix_i || I2OSP(record_index, 8),
    plaintext = record_plaintext,
    aad       = record_aad,
    tag_len   = 16
)
```

线上的记录体为 `ciphertext || tag`。不得截断 Tag，也不得在认证成功前把该记录明文交给不受控输出。

### 9.4 记录序列

根分片：

```
Manifest(index=0)
Data(index=1)
Data(index=2)
...
Final(index=data_record_count + 1)
EOF
```

延续分片：

```
Data(index=1)
Data(index=2)
...
Final(index=data_record_count + 1)
EOF
```

延续分片不使用 `record_index = 0`。

### 9.5 Manifest 记录

- 只允许出现在根分片；
- 必须是第一条记录；
- `record_index = 0`；
- 解密后长度必须在 `1..16,384` 字节；
- 明文必须是第 10 节定义的规范 UTF-8 JSON。

### 9.6 Data 记录

- `plaintext_len` 必须在 `1..chunk_size`；
- 除当前分片最后一个 Data 记录外，其余必须恰好为 `chunk_size`；
- 见到短 Data 记录后不得再出现 Data；
- 空文件根分片可以没有 Data；
- 延续分片必须至少有一条 Data。

### 9.7 Final 记录

Final 明文恰好 48 字节：

| 偏移 | 长度 | 字段 |
|---:|---:|---|
| 0 | 8 | `total_data_length` |
| 8 | 8 | `data_record_count` |
| 16 | 32 | `data_sha256` |

Final 解密后必须同时满足：

- `total_data_length` 等于当前分片实际认证的 Data 明文总长度；
- `data_record_count` 等于当前分片 Data 记录数；
- `data_sha256` 等于当前分片 Data 明文串联后的 SHA-256；
- `total_data_length` 等于公共头 `shard_plaintext_size`；
- Final 后立即 EOF，不得有尾随字节。

## 10. 根 Manifest

### 10.1 编码

Manifest 明文使用：

- UTF-8，无 BOM；
- JSON；
- RFC 8785 规范化；
- 不允许重复键；
- 不允许无效 Unicode；
- 不允许浮点数；
- 生成器输出必须是规范 JSON；
- 解析器重新规范化后必须与原始明文字节完全一致；
- 总长度不得超过 16 KiB。

### 10.2 JSON 结构

以下示例为便于阅读而格式化；线上的 Manifest 不包含空白：

```json
{
  "schema": "SBOX-MANIFEST-2",
  "bundle_id": "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf",
  "recipient_key_id": "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f",
  "content_kind": "text",
  "original_name": "hello.txt",
  "media_type": "text/plain; charset=utf-8",
  "title": "hello.txt",
  "description": "",
  "tags": [],
  "created_at": "2026-08-17T00:00:00Z",
  "logical_plaintext_size": "14",
  "logical_plaintext_sha256": "a50bbe28228e519e97002c9ae7df3705377ef8f9eb80aae317c497250d408922",
  "nominal_shard_plaintext_size": "16777216",
  "shard_count": 1
}
```

### 10.3 精确字段集合

Manifest 必须恰好包含以下字段，不得缺少或增加：

| 字段 | 类型 | 规则 |
|---|---|---|
| `schema` | string | 必须为 `SBOX-MANIFEST-2` |
| `bundle_id` | string | 32 位小写十六进制 |
| `recipient_key_id` | string | 64 位小写十六进制 |
| `content_kind` | string | `file` 或 `text` |
| `original_name` | string | NFC UTF-8 basename，1..1024 字节 |
| `media_type` | string | ASCII，0..255 字节 |
| `title` | string | NFC UTF-8，1..256 字节，不含 C0/C1 |
| `description` | string | NFC UTF-8，0..4096 字节，不含 NUL |
| `tags` | array | 0..32 个唯一 NFC 字符串，每个 1..64 字节 |
| `created_at` | string | UTC RFC 3339，秒精度 |
| `logical_plaintext_size` | string | 无前导零十进制 `0..2^64-1` |
| `logical_plaintext_sha256` | string | 64 位小写十六进制 |
| `nominal_shard_plaintext_size` | string | 1 MiB..512 MiB，整数 MiB |
| `shard_count` | integer | `1..10,000` |

### 10.4 字符串规则

`original_name`：

- 不得为空；
- 不得包含 NUL、`/` 或反斜杠；
- 不得为 `.` 或 `..`；
- 必须是 NFC；
- 只用于最终导出名称，不用于寻找分片；
- 发布明文前必须再次按当前平台规则清理冲突和保留名称。

`media_type`：

- 只允许字节 `0x20..0x7e`；
- 可以为空；
- 只作为显示和安全提示，不得触发自动执行。

`tags`：

- 必须按 UTF-8 字节序升序排列；
- 不得重复；
- 未知或恶意标签不得参与路径生成。

### 10.5 Manifest 与公共头交叉验证

解密 Manifest 后必须验证：

1. `bundle_id` 等于根公共头；
2. `recipient_key_id` 等于根公共头和调用方预期身份；
3. `shard_count` 等于根公共头；
4. 按逻辑总长度和名义分片大小重新计算出的分片数等于 `shard_count`；
5. 根公共头 `shard_plaintext_size` 等于第 0 片期望长度；
6. 空文件必须不分片，即 `shard_count = 1`、文件名无分片后缀且根长度为 0；
7. `content_kind = text` 时，完整解密结果必须是严格 UTF-8；
8. 整体 SHA-256 字段格式合法。

### 10.6 Metadata 不可变

Manifest 与内容属于同一个不可变 Bundle。以下操作都必须创建新 Bundle：

- 重命名；
- 修改标题、说明或标签；
- 修改媒体类型；
- 替换内容；
- 改变分片大小。

应用可以提供只保存在本地、不进入协议的显示别名，但不得把本地别名伪装成已认证 Manifest 字段。

### 10.7 为什么 Manifest 没有 `shards[]`

v2.0 Manifest 不保存逐片对象路径、密文摘要或逐片明文摘要数组。完整分片计划已经可以由以下固定信息唯一计算：

- `bundle_id`；
- `logical_plaintext_size`；
- `nominal_shard_plaintext_size`；
- `shard_count`；
- 第 7 节的规范路径公式。

每片 Final 认证当前片的实际长度和 SHA-256，Manifest 的 `logical_plaintext_sha256` 再认证重组结果。省略 `shards[]` 可以让根 Manifest 保持 O(1) 大小，避免 10,000 片时出现超大 Manifest，也避免把尚未生成的对象摘要反向写入根分片所造成的循环依赖。实现者不得自行重新引入一个等价的 Catalog 清单。

## 11. 规范大小与资源上限

| 项目 | 上限 |
|---|---:|
| Bundle 逻辑明文 | 字段为 `uint64`；v2.0 分片约束下实际最多 `5,368,709,120,000` 字节，同时受平台文件 API 限制 |
| 分片数 | 10,000 |
| 名义分片明文 | 1 MiB..512 MiB，整数 MiB |
| Data 记录明文 | 4 MiB |
| Manifest 明文 | 16 KiB |
| 原始文件名 | 1024 UTF-8 字节 |
| 标题 | 256 UTF-8 字节 |
| 说明 | 4096 UTF-8 字节 |
| 标签 | 32 个，每个 64 UTF-8 字节 |
| 单次对象传输并发 | 默认不超过 4 |
| 扫描对象候选 | 默认不超过 100,000 |

对象大小上界：

```
data_record_count(P) =
    0,                          if P == 0
    ceil(P / 4,194,304),        otherwise

continuation_upper_bound(P) =
    128
    + P
    + 29 * data_record_count(P)
    + 77

root_upper_bound(P, manifest_len) =
    512
    + manifest_len
    + 29
    + P
    + 29 * data_record_count(P)
    + 77
```

其中 29 字节为记录头和 GCM Tag，77 字节为 Final 的 48 字节明文加 29 字节开销。

生成器必须使用数据源 `maxObjectBytes` 检查根分片和延续分片；加密完成后还必须以实际密文长度再次检查。

## 12. 加密算法

### 12.1 输入前置条件

加密输入必须是：

- 可重复读取的文件或内存文本；或
- 能提供稳定长度和随机范围读取的抽象输入。

默认实现不得为了支持不可重放流而把未加密明文复制到长期目录。无法安全重放时应拒绝，或使用明确受管理且操作结束即删除的临时明文区。

### 12.2 分片规划

输入：

- 逻辑长度；
- 用户目标分片大小，默认 16 MiB；
- 数据源对象上限；
- 最大分片数 10,000。

规划器必须只考虑 1..512 MiB 的整数 MiB 候选值，并选择最接近用户目标、同时满足以下条件的值：

1. 分片数不超过 10,000；
2. 根分片大小上界不超过数据源对象上限；
3. 最大延续分片大小上界不超过数据源对象上限。

若用户目标值不可用，优先选择不大于目标值的最大可用候选；若因为分片数限制不存在该候选，可以选择大于目标值的最小可用候选。没有候选时必须拒绝，不得截断输入。

候选值会影响 Manifest 中的名义分片大小和分片数。规划器可以为每个候选构造一份“长度模板 Manifest”：把整体 SHA-256 暂时写成 64 个 ASCII `0`，其余字段使用最终值。真实 SHA-256 也是固定 64 字节，因此模板的规范 JSON 长度与最终 Manifest 完全相同。规划器必须用该精确长度或保守的 16 KiB 上限计算根对象上界，不得忽略 Manifest 开销。

### 12.3 两遍读取与变更检测

因为整体 SHA-256 位于根 Manifest，规范实现采用两遍读取：

第一遍：

1. 重新读取并核对输入声明长度；
2. 读取完整输入；
3. 计算实际长度和整体 SHA-256；
4. 要求实际长度等于规划长度；
5. 构造规范 Manifest。

第二遍：

1. 开始前再次核对输入声明长度；
2. 按分片范围重新读取；
3. 在加密同时再次计算整体 SHA-256 和总长度；
4. 全部分片生成后再次读取输入声明长度；
5. 要求第二遍长度和 SHA-256 与第一遍完全一致；
6. 任一长度或摘要不一致都表示输入在加密期间变化，必须丢弃整个任务。

只比较文件修改时间或长度不够，最终必须比较第二遍内容摘要。

### 12.4 生成流程

实现必须按以下顺序：

1. 校验输入 Metadata。
2. 规划分片大小和数量。
3. 第一遍读取并计算整体 SHA-256 与原始明文 MD5。
4. 使用明文 MD5 作为 `bundle_id`，再生成随机 `bundle_dek` 和每片 Nonce 前缀。
5. 构造并规范化 Manifest，检查 16 KiB 上限。
6. 使用 RSA 公钥封装 `bundle_dek`。
7. 为每片创建同一文件系统内的私有暂存对象。
8. 对每片：
   1. 构造公共头；
   2. 计算 `header_hash`；
   3. 派生 `shard_key_i`；
   4. 根分片先写 Manifest 记录；
   5. 流式写 Data 记录；
   6. 写 Final；
   7. flush、close，并计算完整 SBOX SHA-256；
   8. 尽力覆盖当前分片密钥。
9. 核对第二遍整体长度和 SHA-256。
10. 核对所有实际对象大小。
11. 本地提交延续分片。
12. 本地最后提交根分片。
13. 尽力覆盖 `bundle_dek`、随机缓冲区和中间明文。

### 12.5 加密失败与取消

在根分片提交前发生任何失败：

- 不得留下一个可见根分片；
- 必须删除当前任务的暂存文件；
- 已经远端上传的延续分片可以成为孤立密文，不得因此覆盖其他对象；
- 不得把部分 Bundle 加入本地已提交索引。

若本地根分片已提交而远端上传失败，本地完整 Bundle 是永久密文原件，不得自动删除。

### 12.6 断点与重试

断点只允许发生在完整分片对象边界：

- 已经完整生成、关闭并计算密文 SHA-256 的暂存分片可以继续上传；
- 上传重试必须重发完全相同的对象字节；
- 不得从一个 SBOX 分片的中间记录继续生成或改写；
- 不得在同一个 `bundle_id` 下重新加密某个索引并产生第二份不同密文；
- 一旦需要重新执行任何分片的加密，必须丢弃整个未发布 Bundle，重新生成 `bundle_id`、`bundle_dek` 和全部 Nonce；
- 远端已经存在的旧延续分片保持为孤立对象，后续只能通过显式垃圾清理处理。

## 13. 解密与重组算法

### 13.1 解密入口

解密必须从以下任一入口开始：

- 一个根分片本地路径；
- 一个规范根对象路径；
- 一个已知根分片 URL；
- 可列举数据源中的根分片候选。

单独给出延续分片时，应用只能显示：

```
这是 SBOX v2 延续分片，需要对应的
<bundle_id>_0_<shard_count>.sbox 根分片
```

不得尝试仅凭文件名猜测密钥或输出内容。

### 13.2 根分片解锁

1. 读取并严格验证根公共头。
2. 检查对象大小和安全上限。
3. 要求助记词并派生临时 RSA 身份。
4. 核对派生身份与预期 `recipient_key_id`。
5. 使用第 6.3 节 OAEP Label 解封 `bundle_dek`。
6. 立即释放 RSA 私钥和助记词派生材料。
7. 派生 `shard_key_0`。
8. 解密并认证 Manifest 记录。
9. 严格解析、规范化并执行全部交叉验证。
10. 根据 Manifest 推导全部规范分片路径。

OAEP、Key ID 和 GCM 失败对外必须合并为不会泄漏细节的安全错误。

### 13.3 下载和预检查

在创建任何输出明文前必须：

1. 定位全部 `0..shard_count-1` 分片；
2. 确保每个对象完整落入受管理的本地密文目录；
3. 解析每个公共头；
4. 检查：
   - Magic、版本和角色；
   - `bundle_id`；
   - `recipient_key_id`；
   - `shard_index`；
   - `shard_count`；
   - 按 Manifest 计算出的当前片长度；
   - 规范对象路径；
5. 拒绝缺片、重复索引和冲突副本。

下载可以并行，公共头检查可以并行，但不得并行写最终明文。

### 13.4 顺序解密

所有分片完整后：

1. 在受管理临时明文目录创建随机暂存文件。
2. 初始化整体 SHA-256 和总长度计数器。
3. 按 `shard_index = 0..N-1` 顺序：
   1. 派生当前 `shard_key_i`；
   2. 重新读取并验证公共头；
   3. 根分片重新认证 Manifest，或核对已认证 Manifest 对应的头部和记录边界；
   4. 按记录索引解密 Data；
   5. 只有单条 Data 的 GCM 认证成功后才将该记录追加到临时输出；
   6. 更新当前片和整体摘要；
   7. 认证 Final 和 EOF；
   8. 核对当前片长度、记录数和摘要；
   9. flush 临时输出；
   10. 覆盖并释放当前分片密钥。
4. 核对整体总长度与 Manifest。
5. 核对整体 SHA-256 与 Manifest。
6. 若 `content_kind = text`，严格验证完整结果为 UTF-8。
7. flush、close 临时文件。
8. 使用安全文件名规则原子发布。
9. 覆盖 `bundle_dek` 并结束 Crypto Isolate。

### 13.5 失败语义

发生以下任一情况必须删除临时明文并终止：

- 根分片缺失或角色错误；
- 任意分片缺失；
- Bundle ID、索引、总数、身份或长度不一致；
- Manifest 不是规范 JSON；
- OAEP 或任一 GCM Tag 失败；
- 记录索引不连续；
- Data 分块规则违反；
- Final 不匹配；
- EOF 前截断或 Final 后存在尾随数据；
- 整体长度或 SHA-256 不匹配；
- 文本不是严格 UTF-8；
- 用户取消。

任何失败都不得发布部分明文。

## 14. 数据源与同步

### 14.1 能力模型

v2 数据源能力至少包括：

| 能力 | 含义 |
|---|---|
| `canRead` | 可按路径读取对象 |
| `canWrite` | 可创建不可变对象 |
| `canDelete` | 可删除指定对象 |
| `canListObjects` | 可分页、非递归列举数据源根目录的直接子文件 |
| `supportsRangeRead` | 可读取对象前缀或字节范围 |
| `maxObjectBytes` | 单对象上限 |
| `maxParallelTransfers` | 最大并发传输 |

正常发布只创建不可变 Bundle 对象，不需要全局 CAS。最终数据源接口不得保留仅供 `catalog.sbox` 使用的 `compareAndSwap` 分支。

### 14.2 最终数据源接口

数据源 API 必须一次性收敛到不可变对象语义。不得保留已废弃方法、版本适配器或只服务于旧目录协议的能力字段。`listObjects` 和 `getRange` 通过职责单一的能力接口表达；不支持相应能力的数据源不实现该接口：

```dart
final class SourceObjectInfo {
  final SourcePath path;
  final int length;
  final RevisionToken revision;
}

final class SourceListPage {
  final List<SourceObjectInfo> objects;
  final String? nextCursor;
}

abstract interface class EnumerableDataSource implements DataSource {
  Future<SourceListPage> listObjects({
    String? cursor,
    int pageSize = 1000,
  });
}

abstract interface class RangeReadableDataSource implements DataSource {
  Future<SourceRead> getRange(
    SourcePath path, {
    required int start,
    required int endExclusive,
  });
}
```

最终 `DataSource` 基础接口保留 `get`、`putNew` 和 `deleteIfMatch`，删除 `compareAndSwap`。`SourceCapabilities` 删除只服务于可变目录提交的 `conditionalWrite`、`history` 等字段，并加入 `canListObjects`、`supportsRangeRead`。实现可以调整具体 Dart 类型，但必须保留不可变新建、分页、稳定路径、长度、修订令牌和范围边界语义。

所有本地、GitHub、Gitee 和 HTTPS Provider 必须在同一次重构中实现最终接口。不得通过 deprecated 方法、默认空实现、运行时版本判断或适配器继续承载旧调用方式。

`listObjects` 固定列举当前已配置的数据源根目录，因此不接收协议路径前缀。返回的 `SourceObjectInfo.path` 必须是相对于该根目录的单个 basename；SBOX 调用 `get`、`putNew` 和 `deleteIfMatch` 时也只传入 `SourcePath(canonical_basename)`。远端 Provider 可以在内部把配置的仓库路径前缀与 basename 安全连接，但该前缀不是 SBOX 协议路径的一部分。不得使用空 `SourcePath`、`objects/` 虚拟目录或递归列举来模拟根目录语义。

### 14.3 列举

列举器必须：

1. 只列举数据源根目录的直接子文件，不进入任何子目录；
2. 忽略目录项和非规范 basename，绝不把嵌套 `.sbox` 提升为根对象；
3. 支持分页，单页不得无界；
4. 对 basename 排序或在本地做确定性归并；
5. 识别两类根候选：
   - `<bundle_id>.sbox`，候选不分片根对象，必须读取公共头并确认版本为 `2.0`；
   - `<bundle_id>_0_<shard_count>.sbox`，候选 v2 multipart 根分片，且文件名总数必须至少为 2；
6. 限制总候选数；
7. 对重复 basename、相同 basename 不同修订或包含路径分隔符的结果报告冲突；
8. 不把没有根分片的延续对象显示为普通文件。

列举器不得仅凭 basename 宣称对象有效。必须读取 Magic 和版本字节；版本不是 `2.0` 的对象只能报告为不支持或忽略，不得分派到旧解析器。

未解锁时，UI 可以显示 Bundle ID、分片数和密文大小，但不得猜测原始名称。

### 14.4 Manifest 前缀读取

根 Manifest 是根头后的第一条记录，允许范围读取优化：

1. 读取前 512 字节根头；
2. 读取接下来的 13 字节记录头；
3. 检查类型、索引和 `plaintext_len <= 16 KiB`；
4. 再读取 `plaintext_len + 16` 字节；
5. 只认证 Manifest 记录。

成功认证 Manifest 只能表明“根头和 Manifest 已认证”，不能声称根分片 Data、Final 或整个 Bundle 已验证。UI 和缓存必须区分这两种状态。

不支持 Range 的数据源可以下载完整根分片。

### 14.5 各数据源要求

本地目录：

- 必须支持对所选根目录直接子文件的非递归列举和随机范围读取；
- 必须拒绝符号链接逃逸；
- 不得创建或扫描 SBOX 子目录；
- 写入使用同文件系统暂存和原子 rename；
- 根分片最后 rename。

GitHub / Gitee：

- 必须对配置的数据源根路径实现直接子对象的分页列举，不递归进入子目录；
- Provider 内部路径前缀只属于连接配置，SBOX 对象路径始终只是 basename；
- 对象写入使用“仅新建”语义；
- 内容相同的重试视为成功；
- 内容不同的同路径对象视为不可变冲突；
- 延续分片可并发上传；
- 根分片最后上传。

普通 HTTPS：

- 默认 `canListObjects = false`；
- 可以从用户提供的根 URL 进入；
- 若 URL 可以通过替换规范 basename 推导同目录兄弟对象，则可以恢复；
- 若每个对象需要不同且不可推导的签名 URL，必须要求调用方提供 URL 解析器或拒绝 multipart；
- 不得把 404 根分片误报为“空资料库”。

### 14.6 拉取

1. 列举或取得根路径。
2. 下载根前缀或完整根对象。
3. 解锁 Manifest。
4. 推导分片集合。
5. 对本地已有对象按完整哈希或稳定修订复用。
6. 下载缺失分片。
7. 所有密文完整后再允许解密。

### 14.7 发布

1. 所有分片先在本地生成并验证。
2. 并发上传延续分片。
3. 等待全部延续上传成功。
4. 最后上传根分片。
5. 根上传成功才报告远端发布完成。

任何提供方都不得通过覆盖根分片来模拟更新。

### 14.8 删除与孤立对象

删除 Bundle：

1. 从已认证 Manifest 得到分片总数；
2. 先条件删除根；
3. 再删除延续分片；
4. 更新本地派生索引。

孤立延续分片可能来自中断上传。远端不得默认自动垃圾回收。若实现显式清理：

- 必须重新列举；
- 必须使用足够长的宽限期；
- 必须排除本机活动上传任务；
- 必须向用户展示将删除的精确 Bundle ID 和对象数；
- 不得删除仍有根分片的对象；
- 不得把“未解锁”误判为“孤立”。

## 15. 本地派生索引与 UI

### 15.1 索引不是协议真相

为了避免每次浏览都执行大量 RSA 操作，应用可以维护本地明文派生索引：

```
<LocalCipherRoot>/.sbox-sync/index-v2.json
```

它：

- 不得上传；
- 不得包含助记词、RSA 私钥、`bundle_dek` 或分片密钥；
- 可以包含已经认证的 Manifest 字段；
- 必须绑定根头与完整 Manifest 加密记录的 SHA-256，即 `manifest_prefix_sha256`；
- 可以额外绑定根对象的稳定修订和完整密文 SHA-256；
- 绑定不匹配时必须忽略对应缓存项；
- 删除后必须可以通过重新列举和解锁根分片重建；
- UI 必须明确提示其包含文件名、标题、说明和标签等明文 Metadata。

`manifest_prefix_sha256` 的输入必须恰好为根对象从偏移 0 开始，到 Manifest GCM Tag 结束为止的原始字节。在线刷新后，只有重新读取该前缀并匹配摘要，缓存项才能标记为当前状态；离线时可以显示旧缓存，但必须标记“离线缓存”，不得用它证明远端对象仍存在或完整。

### 15.2 建议缓存结构

```json
{
  "schema": "SBOX-LOCAL-INDEX-2",
  "source_id": "local-application-source-id",
  "entries": [
    {
      "bundle_id": "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf",
      "root_basename": "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf.sbox",
      "root_revision_fingerprint": "provider-specific-stable-value",
      "manifest_prefix_sha256": "64-lowercase-hex-characters",
      "verification": "manifest",
      "manifest": {}
    }
  ]
}
```

`verification` 至少区分：

- `manifest`：只认证了根头和 Manifest；
- `complete`：完整 Bundle 最近一次解密验证成功。

缓存 JSON 的精确生产结构可以在实现阶段细化，但不得改变上述安全边界。

### 15.3 资料库 UI

资料库不再显示 Catalog generation、签名或合并状态。建议状态：

- 未解锁 Bundle；
- Manifest 已认证；
- 分片同步中；
- Bundle 完整；
- 缺少 N 个分片；
- 分片冲突；
- 完整解密验证通过；
- 本地 Metadata 缓存；
- 发布者未签名。

### 15.4 加密 UI

加密表单中的：

- 原始文件名；
- 标题；
- 说明；
- 标签；
- 媒体类型；

全部写入根 Manifest。保存完成后显示 Bundle ID、分片数和根对象路径。

### 15.5 Metadata 编辑

点击“编辑 Metadata”时必须明确提示：

```
SBOX v2 Bundle 不可变。保存修改会创建一个新的完整 Bundle；
旧 Bundle 不会自动删除。
```

实现不得只改写根 Manifest 后复用旧 GCM Nonce、旧根密钥或旧延续分片。

## 16. 唯一版本与不兼容策略

### 16.1 唯一受支持格式

生产应用只支持本文定义的 SBOX `2.0`：

- Magic 必须正确；
- `version_major` 必须为 `2`；
- `version_minor` 必须为 `0`；
- 任何其他版本统一返回 `unsupportedVersion`；
- 不得注册、保留或动态加载第二套容器解析器；
- 不得提供 Legacy 模式、自动迁移、导入转换或双写。

### 16.2 旧数据处理

遇到 `catalog.sbox`、其他版本 SBOX 或非规范旧对象时：

- 不得尝试解密；
- 不得把它们加入资料库；
- 不得从中恢复名称、索引或同步状态；
- 可以显示“当前版本不支持此文件”；
- 不得自动删除用户原文件。

支持旧数据的独立转换工具不属于本项目和本规范范围，生产应用不得内置该工具。

### 16.3 最终代码边界

最终生产代码必须只有一套容器领域模型和一套状态机：

- 一个 `BundleHeader`；
- 一个 `BundleManifest`；
- 一个 v2 Record Codec；
- 一个 Bundle 加密器；
- 一个 Bundle 解密器；
- 一个无 Catalog 的对象列举与同步实现。

最终代码中不得存在：

- `catalog` 模型、签名、状态、缓存或合并模块；
- Catalog 专用 CAS、generation、tombstone 或 conflict 逻辑；
- 旧 Header、Metadata、multipart manifest 或容器 Codec；
- Legacy 页面、设置、错误码、任务状态或数据源模式；
- 为不同容器版本选择实现的分支、适配器或工厂；
- Catalog Ed25519 身份字段和派生代码。

通用 RSA-OAEP、BIP39/RSA 身份派生、安全字节、文件暂存和网络传输代码可以保留，但必须去除旧协议命名和反向依赖。

## 17. 错误模型

实现可以复用现有 `SboxErrorCode`，但必须能表达以下语义：

| 建议错误 | 含义 |
|---|---|
| `invalidHeader` | SBOX 2.0 公共头或角色组合无效 |
| `invalidManifest` | Manifest JSON、规范化或字段无效 |
| `rootRequired` | 用户只提供了延续分片 |
| `shardMissing` | 缺少期望分片 |
| `shardConflict` | 同一 Bundle/索引存在不同内容 |
| `shardMismatch` | 头部与 Manifest 不一致 |
| `authentication` | OAEP 或 GCM 认证失败的统一外部错误 |
| `integrity` | Final、长度、摘要或 EOF 不匹配 |
| `immutableConflict` | 规范对象路径已存在不同内容 |
| `listingUnsupported` | 当前数据源不能列举，且没有已知根入口 |
| `sourceLimit` | 对象大小或分片数超限 |
| `inputChanged` | 两遍读取摘要不一致 |
| `unsupportedVersion` | 输入不是唯一受支持的 SBOX 2.0 |

日志不得记录：

- 助记词；
- Seed；
- 私钥；
- `bundle_dek`；
- 分片密钥；
- OAEP 内部失败细节；
- Manifest 明文，除非用户主动启用明确标记的诊断导出。

## 18. 代码实施方案

### 18.1 总体原则

实施采用一次性协议替换。开发过程中可以为了保持可编译而短暂保留旧文件，但最终合并结果必须只有 SBOX 2.0 一套领域模型，不得形成长期双架构。

建议最终目录：

```
lib/sbox/
├─ constants.dart
├─ format/
│  ├─ bundle_header.dart
│  ├─ bundle_manifest.dart
│  └─ bundle_record.dart
├─ crypto/
│  └─ shard_kdf.dart
├─ engine/
│  ├─ bundle_planner.dart
│  ├─ bundle_encryptor.dart
│  ├─ bundle_decryptor.dart
│  └─ bundle_probe.dart
├─ source/
│  ├─ bundle_listing.dart
│  └─ bundle_sync.dart
└─ storage/
   └─ bundle_store.dart
```

通用安全字节、RSA-OAEP、RSA 身份派生、临时明文存储和任务取消抽象可以重构后复用。任何复用模块都不得 import Catalog 或旧容器类型，也不得保留旧协议命名。

当前仓库的目标改造边界如下；这是最终状态要求，不是要求保留旧文件并在其旁边叠加新实现：

| 当前区域 | 最终动作 |
|---|---|
| `lib/sbox/catalog/` | 整目录删除 |
| `lib/sbox/format/header.dart`、`metadata.dart`、`record.dart` | 由 `BundleHeader`、`BundleManifest`、Bundle Record Codec 完整替换；不保留旧类型 |
| `lib/sbox/engine/container_codec.dart`、`streaming_container.dart`、`multipart.dart`、`multipart_decrypt.dart` | 由统一 Bundle planner/encryptor/decryptor 替换；不再存在“单文件容器”和“multipart 容器”两套流程 |
| `lib/sbox/source/cipher_sync.dart`、`local_scanner.dart` | 改写为数据源根目录直属 Bundle 的非递归列举、拉取、发布和删除流程 |
| `lib/sbox/source/data_source.dart` 及各 Provider | 删除 `compareAndSwap`、Catalog 路径特判、Catalog 锁和旧目录模式，直接实现第 14.2 节最终接口 |
| `lib/sbox/source/source_config.dart` | 删除 Catalog ID、generation、checkpoint、pending merge、signer key 与本地 Catalog mirror 字段；采用只描述数据源连接和本地 Bundle 索引的新配置 Schema |
| `lib/sbox/identity/bip39_identity.dart`、`rsa_models.dart`、`public_identity_record.dart` | 保留确定性 RSA-3072；删除 Ed25519 派生及字段；公共身份记录改为 RSA-only Schema，旧记录不在生产应用中迁移 |
| `lib/app/` 与 `lib/features/` | 删除 Catalog 状态、路由、冲突、解锁和编辑语义，改为 Bundle 列表、Manifest 解锁、缺片状态和“编辑即创建新 Bundle” |
| `README.md`、`pubspec.yaml`、`docs/` | 只描述 SBOX 2.0；删除旧协议规格、旧截图和旧示例，历史由 Git 保存 |
| `test/` | 删除旧容器/Catalog 测试与 fixture；保留并去协议耦合的 RSA 身份向量；建立第 19 节的新测试矩阵 |

若某个当前文件同时包含通用能力与旧协议逻辑，应先提取通用能力到中性命名模块，再删除原文件。不得以“仍有通用代码”为由保留旧领域类型。

### 18.2 阶段 0：盘点与隔离

1. 运行并记录现有测试。
2. 只保留仍属于 v2 的 RSA 身份和通用密码学测试向量。
3. 确认工作区已有用户修改，不覆盖无关文件。
4. 列出待删除的 Catalog、旧容器、旧 multipart 和 Legacy UI 文件。
5. 建立只接受版本 2.0 的协议入口。

完成条件：替换范围明确，用户现有修改已隔离保护。

### 18.3 阶段 1：纯模型和 Codec

实现：

- `SboxProtocol` 常量；
- `BundleId`、规范 basename 和路径；
- 根/延续公共头编码解析；
- Manifest 严格模型和规范 JSON；
- HKDF 分片密钥派生；
- v2 Record AAD 和序列验证；
- Final 模型。

此阶段不得接入 UI 或远端。

完成条件：

- 全部纯单元测试通过；
- 保留字段、角色组合和边界测试齐全；
- HKDF 向量通过。

### 18.4 阶段 2：本地加密

实现：

- 分片规划；
- 两遍输入读取；
- Manifest 生成；
- 单次 RSA 封装；
- 分片流式加密；
- 本地暂存；
- 延续先提交、根最后提交；
- 取消和失败清理。

完成条件：

- 空文件、小文件、边界文件和 multipart 可生成；
- 生成过程中输入变化会使整个任务失败；
- 不生成 `catalog.sbox`；
- 非根头不包含 RSA 密文。

### 18.5 阶段 3：本地解密

实现：

- 根入口探测；
- 单次 RSA 解封；
- Manifest 前缀认证；
- 分片定位和头部预检查；
- 顺序解密到临时文件；
- 每片 Final 和整体摘要验证；
- 原子发布；
- 失败清理。

完成条件：

- 每个逻辑文件解密只调用一次 RSA OAEP；
- 任一损坏或缺片都不产生最终明文；
- 临时明文清理测试通过。

### 18.6 阶段 4：数据源列举与同步

重构为最终数据源能力：

1. 本地根目录直接子文件的非递归列举；
2. GitHub 数据源根路径的非递归列举和范围读取；
3. Gitee 数据源根路径的非递归列举和范围读取；
4. HTTPS 已知根 URL 模式；
5. Bundle 拉取；
6. 延续先上传、根最后上传；
7. 不可变路径冲突处理。

完成条件：

- 分页和 100,000 对象上限生效；
- 上传中断不会留下可见根；
- 相同对象重试幂等；
- 不同对象同路径拒绝。

### 18.7 阶段 5：资料库与缓存

实现：

- Bundle 根候选列表；
- 批量或按需解锁 Manifest；
- 本地派生索引；
- 缺片状态；
- Bundle ID、分片数和验证状态 UI；
- Metadata 编辑改为“创建新 Bundle”。

注意：当前 `lib/features/library/library_page.dart` 可能包含用户工作区修改，实施者必须先检查 diff，再做最小合并。

### 18.8 阶段 6：旧实现删除与唯一版本切换

1. 删除 `lib/sbox/catalog/` 及其全部调用方。
2. 删除旧 Header、Metadata、Record、multipart 和 Catalog 容器 Codec。
3. 删除 Catalog 专用 `compareAndSwap`、缓存、同步、冲突和任务状态。
4. 删除 Catalog/Legacy UI、设置、错误提示和路由。
5. 删除 Catalog Ed25519 身份派生和持久化字段。
6. 删除不再适用的旧容器测试、fixture 和依赖。
7. 删除 `docs/SBOX-v1-SPEC.md`、`docs/assets/sbox-v1-*`、`test/goldens/sbox-v1-*`、`test/failures/sbox-v1-*`；历史资料由 Git 提供。
8. 更新 README、`pubspec.yaml` 描述、产品文案和示例目录，只描述本文协议。
9. 对 `lib/` 执行静态搜索，要求 `SboxV1`、旧协议类名、Catalog、Legacy、版本分派和 Ed25519 业务引用为零。唯一允许的旧版本文字是第 6.1.2 节冻结的两个 RSA Profile 1 输入字面量，且只能位于 `RsaIdentityProfile1`；对 `test/` 的其他命中逐项确认仅属于明确的拒绝性测试。
10. 运行完整测试和跨平台构建，并执行依赖审计，删除不再被使用的 package。

完成条件：生产代码只存在一套 SBOX 2.0 实现；删除任何“兼容层”都不再是后续工作。

### 18.9 不应采取的实现方式

禁止：

- 保留双解析器、Legacy 模式或迁移入口；
- 把旧容器类改名后继续作为隐藏兼容层；
- 在最终代码中保留只被旧协议使用的字段、错误码或依赖；
- 在延续分片重复 RSA 封装；
- 对所有分片执行 RSA 解封；
- 使用原始文件名作为规范远端对象名；
- 只根据文件名排序而不验证内嵌索引；
- 在延续分片完成之前上传根；
- 在整体摘要验证前 rename 临时明文；
- 为了编辑 Metadata 重用旧密钥和 Nonce；
- 把本地索引作为缺片或完整性的密码学证据；
- 把解析错误降级为“尽量打开”；
- 记录密钥或 Manifest 明文。

## 19. 测试与互操作

### 19.1 HKDF 固定向量

输入：

```
bundle_dek =
000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f

bundle_id =
a0a1a2a3a4a5a6a7a8a9aaabacadaeaf

recipient_key_id =
202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f
```

HKDF Extract 的 PRK：

```
e923d7ce41cdafb9ff36e7d38e640888600785351ef83c5adb8ea0c403881a5d
```

期望分片密钥：

| 索引 | `shard_key_i` |
|---:|---|
| 0 | `c538d3ee872b3575f579dd192efa6aef82ba4beb50668a66a8bbc35d0d113639` |
| 1 | `b30fab865d32c5974dae3dd8ffc437f394027438ee94b2f990f9aa6be6649dd4` |
| 9999 | `9a369d45ea14926a0272547f9798a0d0ff84a8230258bc13a69050e7b349faf7` |

### 19.2 OAEP Label 向量

使用上述 `bundle_id` 和 `recipient_key_id`：

```
SHA-256(oaep_label) =
3f9a847e5f091b2fbaa30d4cbf24b059c7df69d5da613f80dfbc819cd112721a
```

此值只用于验证 Label 构造，不是 OAEP 的输入替代品。

### 19.3 内容摘要向量

```
SHA-256(empty) =
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

SHA-256(UTF8("hello SBOX v2\n")) =
a50bbe28228e519e97002c9ae7df3705377ef8f9eb80aae317c497250d408922
```

### 19.4 必须覆盖的结构测试

- 根头编码/解析往返；
- 延续头编码/解析往返；
- 128/512 长度错配；
- ROOT flag 与索引错配；
- 延续分片带 wrapped key；
- 根分片缺 wrapped key；
- 非零保留字段；
- 越界分片数和索引；
- 不分片名称 `<bundle_id>.sbox`；
- multipart 名称 `<bundle_id>_<shard_index>_<shard_count>.sbox`；
- 文件名索引/总数与公共头不一致；
- `_0_1`、前导零、负数、缺少总数和多余分隔段；
- 两位以上索引按数值而不是字典序排序；
- 规范数据源路径恰好等于 basename，并直接位于数据源根目录；
- `objects/`、按 Bundle ID 分目录和任意嵌套 `.sbox` 均被拒绝或忽略；
- 路径穿越、Unicode 和 URL 编码绕过；
- Manifest 重复键、未知键、非规范 JSON；
- 非 NFC 字符串；
- 非法十进制和哈希；
- 分片数公式不匹配。

### 19.5 必须覆盖的加解密测试

- 0 字节；
- 1 字节；
- 4 MiB - 1；
- 4 MiB；
- 4 MiB + 1；
- 16 MiB；
- 16 MiB + 1；
- 恰好两片；
- 最大片数的规划边界；
- 文本严格 UTF-8；
- 二进制文件；
- 两遍读取期间输入变化；
- 取消发生在每个阶段。

### 19.6 必须覆盖的攻击测试

- 修改 Magic、版本、算法 ID；
- 修改 Bundle ID；
- 修改公共头索引或总数；
- 修改 Nonce；
- 修改 Manifest 密文或 Tag；
- 删除 Manifest；
- 根分片换成延续分片；
- 缺片；
- 重复片；
- 调换文件名；
- 把 Bundle A 的片混入 Bundle B；
- 截断 Data；
- 重复 Data 记录；
- 短 Data 后继续 Data；
- 修改 Final；
- Final 后追加字节；
- 替换完整但旧的同路径对象；
- 恶意超大长度；
- OAEP 失败；
- 整体 SHA-256 不匹配。

每项失败都必须验证：

- 没有最终明文；
- 暂存明文被删除；
- 密钥任务结束；
- 外部错误不泄漏 OAEP 细节。

### 19.7 发布顺序故障注入

对每个写入边界注入失败：

1. 第一个延续分片前；
2. 某个延续分片后；
3. 全部延续完成、根之前；
4. 根上传中；
5. 根上传成功后本地状态更新前。

验收要求：

- 1..3 不出现远端根；
- 4 只能是根不存在或完整存在，不得接受截断根；
- 5 可通过重新列举恢复为已发布状态；
- 孤立延续对象不显示为普通文件。

### 19.8 唯一版本与代码清理测试

- 现有 RSA 身份测试向量不变；
- Header 的 `(version_major, version_minor)` 不等于 `(2, 0)` 时返回 `unsupportedVersion`；
- 扫描、加密、解密、上传和删除流程均不读取、请求、创建或更新 `catalog.sbox`；
- 生产代码不存在旧容器解析器、版本分派、Legacy 模式、迁移入口或双写器；
- 生产代码不存在 Catalog 模型、Codec、签名、缓存、CAS、合并、冲突状态或专用 UI；
- `lib/` 中不存在 `SboxV1` 类型或引用；两个冻结的 RSA Profile 1 字面量只存在于 `RsaIdentityProfile1`；
- 对 `lib/` 和有效测试目录执行静态搜索，只允许在否定性测试夹具或本规范中出现旧对象名称。

### 19.9 最终互操作向量

在生产实现验收前，仓库必须冻结至少以下完整二进制向量：

1. 空的不分片 Bundle；
2. `hello SBOX v2\n` 不分片 Bundle；
3. 三分片 Bundle；
4. 每个向量的：
   - 身份输入；
   - 固定 `bundle_id`；
   - 固定 `bundle_dek`；
   - 固定 Nonce 前缀；
   - 固定 OAEP 随机种子；
   - 完整 Manifest 明文；
   - 每个分片完整十六进制或二进制 fixture；
   - 每个对象 SHA-256；
   - 最终明文 SHA-256。

向量生成器只能用于测试，不得把固定随机数路径带入生产代码。

## 20. 验收标准

只有全部满足时，SBOX 2.0 实现才可以验收并进入生产发布：

### 20.1 协议

- [ ] 新 Bundle 不创建、不读取也不更新 `catalog.sbox`。
- [ ] 不分片 Bundle 使用 `<bundle_id>.sbox`。
- [ ] multipart Bundle 使用 `<bundle_id>_<shard_index>_<shard_count>.sbox`。
- [ ] multipart 根分片使用 `<bundle_id>_0_<shard_count>.sbox`。
- [ ] 所有规范对象直接位于已配置的数据源根目录，路径恰好等于规范 basename。
- [ ] 不创建、不依赖也不递归扫描 `objects/` 或任何分片子目录。
- [ ] 文件名中的索引和总数与公共头、Manifest 完全一致。
- [ ] 不分片和 multipart 使用同一线协议模型。
- [ ] 根头 512 字节，延续头 128 字节。
- [ ] 只有根分片有 Manifest 和 RSA 封装。
- [ ] 延续分片没有原始文件名、标题、说明或标签。
- [ ] 每片密钥按规范 HKDF 派生。
- [ ] 每个 Bundle 解密恰好一次 RSA OAEP。
- [ ] 文件名和路径符合明文 MD5 Bundle ID 规范。

### 20.2 完整性

- [ ] 缺片、重复、调换、混入和截断均被拒绝。
- [ ] 每片 Final 均验证。
- [ ] 整体长度和 SHA-256 均验证。
- [ ] Final 后必须 EOF。
- [ ] 任何失败不发布部分明文。

### 20.3 存储和同步

- [ ] 延续分片先提交，根最后提交。
- [ ] 删除时根先删除。
- [ ] 对象写入不可变且重试幂等。
- [ ] 本地、GitHub、Gitee 能列举根对象。
- [ ] HTTPS 已知根入口可工作或明确拒绝。
- [ ] 本地索引可删除并重建，且永不上传。

### 20.4 安全

- [ ] 公共路径不含原始文件名。
- [ ] 助记词、私钥和 DEK 不持久化。
- [ ] 日志不含秘密或 Manifest 明文。
- [ ] RSA 材料在单次解封后尽快释放。
- [ ] 取消和错误路径清理暂存明文与密钥。
- [ ] UI 不宣称发布者真实性。

### 20.5 代码洁净度

- [ ] 生产代码只有 SBOX 2.0 的一套解析器、写入器和状态机。
- [ ] 任何非 `2.0` Header 都统一返回 `unsupportedVersion`。
- [ ] 不存在旧容器、Catalog、Legacy、迁移、导入转换或双写模块。
- [ ] 不存在 Catalog 专用 CAS、缓存、签名、合并、冲突、UI、错误码或任务状态。
- [ ] Catalog Ed25519 派生及其持久化字段已经删除。
- [ ] `SboxV1` 类型和引用为零；冻结的 RSA Profile 1 输入字面量只位于 `RsaIdentityProfile1`。
- [ ] `lib/` 与有效测试目录的静态搜索没有旧协议生产引用。
- [ ] 通用 RSA 身份与密码学模块不依赖任何容器协议类型。

## 21. AI 编码代理的完成定义

AI 编码代理不得以“主要流程可用”作为完成。一次实现任务只有在以下证据齐全时才可报告完成：

1. 列出新增和修改的文件。
2. 说明每个阶段实现了哪些规范条款。
3. 提供实际执行过的测试命令和结果。
4. 提供至少一个本地加密、扫描、解密的端到端结果。
5. 证明 multipart 解密只调用一次 RSA OAEP。
6. 证明缺任意分片时没有最终明文。
7. 证明发布故障注入中根分片保持最后提交。
8. 提供静态搜索和依赖检查结果，证明生产代码没有旧协议或 Catalog 遗留引用。
9. 检查并报告工作区中原有的用户修改是否被保留。
10. 若任何条款未实现，必须明确标记为未完成，不得用 TODO 静默代替。

## 22. 后续扩展的版本边界

以下变化必须提升协议版本或引入明确的新算法 ID，不得在 v2.0 中静默加入：

- 发布者签名；
- 隐藏分片关联的私密命名方案；
- 纠删码；
- 压缩；
- 多接收者密钥槽；
- 可变公共头扩展；
- Metadata 原地更新；
- Bundle 版本链或墓碑；
- 不同 AEAD；
- 不同 RSA 或后量子密钥封装；
- 目录树原生打包。

解析器必须拒绝未知算法、未知 flags 和非零保留字段。未来实现只有在明确识别新版本或新算法 ID 时才可以接受扩展。
