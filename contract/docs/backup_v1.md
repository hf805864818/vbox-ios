# 备份格式规范 v1.0

> **契约层文件** · `contract/docs/backup_v1.md`
> **来源**：从 `vboxapp/vbox/Services/BackupManager.swift`（831 行）逆向提取
> **冻结日期**：2026-09-29
> **约束**：Flutter 端必须产生**字节级兼容**的备份文件，实现 iOS ↔ Flutter 双向互通

---

## 1. 文件结构（BackupFileEnvelope）

来源：`BackupManager.swift` 第 96-103 行

```swift
struct BackupFileEnvelope: Codable, Sendable {
    var schemaVersion: Int
    var meta: BackupMeta
    var encrypted: Bool
    var cipher: String?
    var kdf: String?
    var salt: String?
    var iv: String?
    var authTag: String?
    var payload: String
}
```

| 字段 | 类型 | 可空 | 加密时 | 未加密时 |
|------|------|------|--------|---------|
| schemaVersion | `Int` | ❌ | `1` | `1` |
| meta | `BackupMeta` | ❌ | 有值 | 有值 |
| encrypted | `Bool` | ❌ | `true` | `false` |
| cipher | `String?` | ✅ | **`"AES-256-GCM"`** | `nil` |
| kdf | `String?` | ✅ | **`"PBKDF2-HMAC-SHA256"`** | `nil` |
| salt | `String?` | ✅ | base64 | `nil` |
| iv | `String?` | ✅ | base64 | `nil` |
| authTag | `String?` | ✅ | base64 | `nil` |
| payload | `String` | ❌ | base64(密文) | base64(明文) |

**⚠️ 关键**：`cipher` 与 `kdf` 的字面值必须**精确匹配**上述字符串（源码第 471-472 行）。

---

## 2. 元数据（BackupMeta）

来源：`BackupManager.swift` 第 88-94 行

```swift
struct BackupMeta: Codable, Sendable {
    var appName: String
    var appVersion: String
    var createdAt: Int64      // Unix 时间戳（秒）
    var account: String
    var username: String
    var device: String
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| appName | `String` | 应用名 |
| appVersion | `String` | 应用版本 |
| createdAt | `Int64` | Unix 秒级时间戳 |
| account | `String` | 账号标识 |
| username | `String` | 用户名 |
| device | `String` | 设备标识 |

---

## 3. 备份类目（9 个）

来源：`enum BackupCategory: String, CaseIterable, Identifiable`

| # | rawValue | 中文名 | 副标题 | 敏感 | 默认勾选 |
|---|----------|--------|--------|------|---------|
| 1 | `watchHistory` | 观看记录 | 播放历史与观看进度 | ❌ | ✅ |
| 2 | `favorites` | 我的收藏 | 收藏的剧集列表 | ❌ | ✅ |
| 3 | `downloads` | 下载记录 | 下载列表与进度（不含本地文件） | ❌ | ✅ |
| 4 | `subscriptions` | 订阅源 | 订阅的源地址列表 | ❌ | ✅ |
| 5 | `siteConfigs` | 站点配置 | 站点、解析设置等配置 | ❌ | ✅ |
| 6 | `personalSettings` | 个人设置 | 用户名、头像、外观、TMDB 等 | ❌ | ✅ |
| 7 | `remoteSources` | 远程源配置 | 远程源缓存配置 | ❌ | ✅ |
| 8 | `searchHistory` | 搜索历史 | 搜索关键词记录 | ❌ | ✅ |
| 9 | `cloudCredentials` | 网盘凭据 | 网盘授权令牌 | ✅ **是** | ❌ **否** |

**规则**（源码）：
```swift
var isSensitive: Bool { self == .cloudCredentials }
var defaultOn: Bool { !isSensitive }
```

---

## 4. 加密细节（关键，必须字节级复刻）

来源：`BackupManager.swift` 第 235-316 行

### 4.1 参数

```swift
static let supportedSchemaVersion = 1
private static let pbkdf2Iterations = 100_000
private static let saltLength = 16
private static let ivLength = 12
```

| 参数 | 值 | 位置 |
|------|-----|------|
| schemaVersion | `1` | 第 235 行 |
| **PBKDF2 迭代次数** | **100,000** | 第 237 行 |
| **salt 长度** | **16 字节** | 第 238 行 |
| **IV 长度** | **12 字节** | 第 239 行 |
| **AES 密钥长度** | **32 字节（AES-256）** | 第 272 行 `[UInt8](repeating: 0, count: 32)` |
| PRF 算法 | **HMAC-SHA256** | 第 285 行 `kCCPRFHmacAlgSHA256` |
| 加密模式 | **AES-GCM** | 第 306 行 `AES.GCM.seal` |
| AAD（附加认证数据） | **无** | 源码未传 additionalData |

### 4.2 密钥派生

```swift
CCKeyDerivationPBKDF(
    CCPBKDFAlgorithm(kCCPBKDF2),
    password,                    // 口令（UTF-8 C 字符串）
    password.utf8.count,         // 口令字节长度
    saltBase,                    // salt 原始字节
    salt.count,                  // salt 长度（16）
    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
    UInt32(pbkdf2Iterations),    // 100000
    &key,                        // 输出 32 字节
    key.count
)
```

**⚠️ 关键点**：
- 口令按 **UTF-8** 编码取字节
- `password.utf8.count` 是**字节长度**（非字符长度）
- 输出 32 字节作为 AES-256 密钥

### 4.3 加密流程

```
① salt  = 16 字节随机（源码用 `UInt8.random(in: .min ... .max)`）
② iv    = 12 字节随机（源码用 SecRandomCopyBytes）
③ key   = PBKDF2(password, salt, 100000, SHA256, 32 字节)
④ sealed = AES.GCM.seal(plaintext, key, nonce=iv)
⑤ 输出：(salt, iv, sealed.tag, sealed.ciphertext)
```

**⚠️ GCM tag 长度**：源码用 `CryptoKit` 的 `sealed.tag`，**未显式指定**。CryptoKit 默认 **16 字节**（128 bit）。

### 4.4 编码方式

| 字段 | 编码 |
|------|------|
| salt | Base64 |
| iv | Base64 |
| authTag | Base64 |
| payload | Base64（密文，不含 tag） |

**⚠️ 顺序注意**：`CryptoKit` 的 `sealed.ciphertext` **不含** GCM tag（tag 单独取）。Flutter `cryptography` 包的 `SecretBox` 结构与之一致（`cipherText` + `mac`），需按此拆分。

### 4.5 未加密模式

```swift
encrypted: false,
cipher: nil,
kdf: nil,
// salt/iv/authTag 均为 nil
payload: base64(明文 JSON)
```

---

## 5. Payload 结构

来源：`collectCategory(_:includeWelfare:)` 与各类 Snapshot 结构

### 5.1 顶层

```swift
struct BackupPayload: Codable, Sendable {
    var account: String
    var categories: [String: Data]      // key = category rawValue, value = 该类目 JSON
}
```

### 5.2 各类目内容

| 类目 | 内容 | 来源 |
|------|------|------|
| watchHistory | `[HistoryRecord]` JSON | `DatabaseManager.queryHistory()` |
| favorites | `[FavoriteRecord]` JSON | `queryFavorites()` |
| downloads | `[DownloadRecord]` JSON | `queryDownloads()` |
| subscriptions | `[SubscriptionRecord]` JSON | `querySubscriptions()` |
| siteConfigs | `SiteConfigsSnapshot` | 见下 |
| personalSettings | `PersonalSettingsSnapshot` | 见下 |
| remoteSources | `RemoteSourcesSnapshot` | 见下 |
| searchHistory | 搜索历史 JSON | — |
| cloudCredentials | `CredentialsSnapshot` | 见下 |

### 5.3 SiteConfigsSnapshot

```swift
struct SiteConfigsSnapshot: Codable {
    var zhanyuan: [ZhanyuanSite]
    var apiyuan: [ApiYuanSite]
    var jiexi: [JiexiSetting]
}
```

### 5.4 PersonalSettingsSnapshot

```swift
struct PersonalSettingsSnapshot: Codable {
    var username: String
    var avatarBase64: String?
    var defaults: [String: String]      // UserDefaults 白名单
}
```

**⚠️ 关键**：`defaults` 仅含**白名单键**（见第 7 节），**远程源缓存与同步状态不备份**。

### 5.5 CredentialsSnapshot

```swift
struct CredentialsSnapshot: Codable {
    var credentials: [String: CloudDriveCredential]
    var tokens: [DriveToken]
}
```

### 5.6 RemoteSourcesSnapshot（含版本兼容）

```swift
struct RemoteSourcesSnapshot: Codable {
    var version: String
    var manifest: Data?
    var allSources: Data?
    var spiderJS: [String: Data]
    var lxPlugins: [String: Data] = [:]     // A6 扩展，旧备份无此字段

    private enum CodingKeys: String, CodingKey {
        case version, manifest, allSources, spiderJS, lxPlugins
    }

    // 自定义解码：lxPlugins 缺失时回退空字典
    init(from decoder: Decoder) throws {
        ...
        lxPlugins = try c.decodeIfPresent([String: Data].self, forKey: .lxPlugins) ?? [:]
    }
}
```

**⚠️ 兼容要求**：`lxPlugins` **必须可缺省**（旧备份无此字段 → 空字典）。

---

## 6. 版本兼容规则

### 6.1 schemaVersion 检查

源码第 502-503 行：
```swift
guard envelope.schemaVersion <= Self.supportedSchemaVersion else {
    throw BackupError.schemaTooNew(envelope.schemaVersion)
}
```

**规则**：
| 备份版本 vs 当前支持版本 | 行为 |
|------------------------|------|
| `envelope.schemaVersion <= 1` | ✅ 允许还原 |
| `envelope.schemaVersion > 1` | ❌ 抛 `schemaTooNew`，提示升级 App |

**错误消息**（源码第 200 行）：
```
"备份文件格式版本 v\(v) 高于当前 App 支持的 v\(BackupManager.supportedSchemaVersion)，请先升级 App 再还原"
```

### 6.2 decodeIfPresent 用例（向后兼容）

| 位置 | 字段 | 行为 |
|------|------|------|
| RemoteSourcesSnapshot | `manifest` | 缺失 → nil |
| RemoteSourcesSnapshot | `allSources` | 缺失 → nil |
| RemoteSourcesSnapshot | `spiderJS` | 缺失 → `[:]` |
| RemoteSourcesSnapshot | `lxPlugins` | 缺失 → `[:]` |

---

## 7. 个人设置白名单（14 键）

来源：`settingsDefaultKeys`（源码第 249-266 行）

| # | 键 | 类型 | 福利标记 |
|---|-----|------|---------|
| 1 | `app_skin_mode` | string | — |
| 2 | `app_skin_follows_system` | bool | — |
| 3 | `app_enable_tmdb` | bool | — |
| 4 | `app_tmdb_proxy_url` | string | — |
| 5 | `app_tmdb_use_token` | bool | — |
| 6 | `app_tmdb_proxy_token` | string | — |
| 7 | `app_dev_log_enabled` | bool | — |
| 8 | `app_dev_log_level` | int | — |
| 9 | `remote_default_source_enabled` | bool | — |
| 10 | `bundle_sources_enabled` | bool | — |
| 11 | `remote_default_manifest_url` | string | — |
| 12 | `app_welfare_unlocked` | bool | ✅ **福利** |
| 13 | `app_welfare_password` | string | ✅ **福利** |
| 14 | `app_welfare_enabled` | bool | ✅ **福利** |

**⚠️ 关键规则**：
- 前 11 键：常态备份
- 后 3 键（福利）：**仅加密备份时采集与还原**（`includeWelfare` 参数控制）
- **远程源缓存与同步状态不备份**（还原后强制拉取最新）

---

## 8. 冲突策略

来源：`enum ConflictStrategy`

| 策略 | rawValue | 行为 |
|------|----------|------|
| 合并 | `merge` | 保留本机现有数据，把备份内容合并进来 |
| 覆盖 | `overwrite` | 先清空本机对应类目，再完整写入备份内容 |

---

## 9. 错误类型

```swift
enum BackupError: LocalizedError, Sendable {
    case wrongPassword                  // "口令错误，无法解密这份备份"
    case schemaTooNew(Int)              // "备份文件格式版本 vN 高于当前 App 支持的 vM..."
    case invalidFormat(String)
    case cryptoFailed(String)
    case emptyPassword
}
```

| 错误 | 触发条件 |
|------|---------|
| wrongPassword | AES-GCM 解密失败（tag 校验不过） |
| schemaTooNew | schemaVersion > 1 |
| cryptoFailed | 密钥派生失败 / 随机数生成失败 |
| emptyPassword | 空口令 |

---

## 10. Flutter 端实现要求（字节级一致性）

| 项 | 要求 | Flutter 实现 |
|----|------|-------------|
| PBKDF2 迭代 | **100,000** | `Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 100000, bits: 256)` |
| salt 长度 | **16 字节** | `randomBytes(16)` |
| IV 长度 | **12 字节** | `randomBytes(12)` |
| 密钥长度 | **32 字节（256 bit）** | `bits: 256` |
| 口令编码 | **UTF-8** | `utf8.encode(password)` |
| GCM tag | **16 字节** | `SecretBox` 的 `mac`（默认 macLength=16） |
| AAD | **无** | 不传 `aad` |
| Base64 | 标准（非 URL-safe） | `base64.encode()` |
| 时间戳 | Unix 秒 | `DateTime.now().millisecondsSinceEpoch ~/ 1000` |

### 10.1 双向兼容验证清单

- [ ] iOS 导出（加密）→ Flutter 导入成功
- [ ] Flutter 导出（加密）→ iOS 导入成功
- [ ] iOS 导出（未加密）→ Flutter 导入成功
- [ ] Flutter 导出（未加密）→ iOS 导入成功
- [ ] 含 `lxPlugins` 与不含 `lxPlugins` 的备份均可读
- [ ] 9 个类目逐个验证
- [ ] 错误口令 → `wrongPassword`
- [ ] schemaVersion=2 → `schemaTooNew`

### 10.2 潜在风险点

| 风险 | 说明 | 应对 |
|------|------|------|
| GCM tag 拆分方式 | CryptoKit 的 `ciphertext` 不含 tag；部分库把 tag 附加在密文尾部 | 明确按 `authTag` 字段独立存储 |
| Base64 变体 | 标准 vs URL-safe | 用标准 Base64 |
| 空口令处理 | 源码抛 `emptyPassword` | 保持一致 |
| 迭代次数性能 | 100,000 次在低端设备可能慢（>1s） | 放置于 isolate，避免阻塞 UI |
| 口令字节长度 | 中文口令的 UTF-8 字节数 ≠ 字符数 | 必须用字节长度 |

---

## 11. 源码未明确定义项

| 项 | 状态 | 建议 |
|----|------|------|
| GCM tag 的显式长度 | 源码未指定（CryptoKit 默认 16） | 固定 16 字节 |
| 备份文件扩展名 | 源码未定义 | 建议 `.vboxbak` |
| 备份文件 MIME | 未定义 | `application/json` |
| 大文件分片 | 未定义 | 备份通常 < 5MB，无需分片 |
| 口令强度校验 | 未定义（仅检查空） | 建议前端提示 |
| 备份文件压缩 | **未使用压缩** | 直接 JSON + Base64 |

**⚠️ 重要**：源码**未使用任何压缩算法**（无 gzip/zlib），payload 是**直接 Base64 的 JSON**。Flutter 端**不得引入压缩**，否则不兼容。
