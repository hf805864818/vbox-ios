# Prefs 键契约修订说明 v1.0 → v1.1

> **⚠️ 本文档为历史修订记录**：文中键数（53 键 / 12 组）为 **v1.1 时期**的状态，
> 已由 v1.2 修订取代。**现行键数见 `contract/schema/prefs_keys_v1.json`（98 键 / 21 组）**，
> 口径澄清见 `docs/DEV_PLAN_v4_with_progress.md` P.6。


- **修订日期**：2026-09-29
- **修订类型**：缺陷修正（非功能变更）
- **依据**：D13 阶段质量门禁 · 契约修订流程
- **影响文件**：`contract/schema/prefs_keys_v1.json`、`lib/contract/prefs_keys.dart`

---

## 1. 修订原因

`prefs_keys_v1.json` v1.0 冻结了 **63 个键**，声称"从 iOS 源码逆向提取"。
第 1 轮迭代开发 `prefs_manager.dart` 前逐键核验时，发现其中 **10 个键并非 UserDefaults 偏好键**。

**根因**：v1.0 的提取脚本仅匹配 `forKey:` 模式，**未区分调用主体**：

```swift
// ✅ 真 prefs 键：UserDefaults 调用
UserDefaults.standard.set(value, forKey: "player_auto_play_next")

// ❌ 误抓：播放器对象的 KVC 属性访问（obj 是 AliPlayer/IJKPlayer 实例）
obj.value(forKey: "bufferedPosition")
obj.setValue(NSNumber(value: v), forKey: "networkTimeout")
```

两者语法相同（都是 `forKey:`），故被一并提取。

---

## 2. 移除键明细（10 键）

### 2.1 AliPlayer KVC 属性（7 键）

来源文件：`vbox/Views/AliPlayerRepresentable.swift`

| 键 | 源码位置 | 真实身份 |
|----|---------|---------|
| `bufferedPosition` | :350 | AliPlayer 缓冲位置属性 |
| `maxBufferDuration` | :419-420 | AliPlayer 最大缓冲属性 |
| `highBufferDuration` | :423-424 | AliPlayer 高水位缓冲属性 |
| `startBufferDuration` | :427-428 | AliPlayer 起始缓冲属性 |
| `maxDelayTime` | :415-416 | AliPlayer 最大延迟属性 |
| `networkTimeout` | :411-412 | AliPlayer 网络超时属性 |
| `positionTimerIntervalMs` | :431-432 | AliPlayer 进度轮询间隔属性 |

证据样例（`AliPlayerRepresentable.swift:410-412`）：

```swift
var networkTimeout: Int {
    get { (obj.value(forKey: "networkTimeout") as? NSNumber)?.intValue ?? 0 }
    set { obj.setValue(NSNumber(value: newValue), forKey: "networkTimeout") }
}
```

> `obj` 为 AliPlayer 实例，此处 `forKey:` 是 KVC 访问 SDK 对象属性，与 UserDefaults 无关。

### 2.2 IJKPlayer KVC 属性（1 键）

来源文件：`vbox/Views/IJKPlayerRepresentable.swift`

| 键 | 源码位置 | 真实身份 |
|----|---------|---------|
| `reconnect` | :99 | IJKPlayer 重连属性 |

### 2.3 CoreAnimation 动画 key（1 键）

来源文件：`vbox/Views/PlayerViewsV2_Extensions.swift`

| 键 | 源码位置 | 真实身份 |
|----|---------|---------|
| `danmaku_scroll` | :352 | CAAnimation 标识符 |

证据：

```swift
textLayer.add(animation, forKey: "danmaku_scroll")   // CAAnimation key，非 UserDefaults
```

### 2.4 分组影响

- `_group_buffer`：**整组移除**（6 键全部为 AliPlayer KVC 属性）
- `_group_player`：7 键 → 4 键（移除 `networkTimeout`/`positionTimerIntervalMs`/`reconnect`）
- `_group_danmaku`：3 键 → 2 键（移除 `danmaku_scroll`）

---

## 3. 修订后状态

| 项 | v1.0 | v1.1 |
|----|------|------|
| 键总数 | 63 | **53** |
| 分组数 | 13 | **12** |
| 敏感键 | 5 | 5（不变） |

---

## 4. 经核验保留的键（54 → 实际 53）

以下键**曾一度被误判为"源码中不存在"**，经二次核验确认**真实存在**（提取脚本需同时匹配键常量写法）：

| 键 | 证据 |
|----|------|
| `remote_default_source_enabled` 等 8 个 remote 键 | `RemoteSourceConfigManager.swift:8-16` `enum RemoteSourceConfigKeys` 键常量；`BackupManager.swift:259-261` 备份清单 |
| `subscribed_config_urls` / `active_subscription_index` / `cached_subscribe_config` | `SubscriptionManager.swift:14-16` 键常量 |
| `vbox_sqlite_migration_done` | `DatabaseManager.swift:220-222` |
| `user_parsers` | `SpiderManager.swift:286` 键常量 |
| `searchHistory` | `MainViews.swift:1803`（UserDefaults 实读） |

> 教训：核验脚本必须同时覆盖 `forKey:"k"`、`let xKey = "k"`、`enum XXXKeys` 三种写法。

---

## 5. 未决事项

以下键**无法在当前仓库找到 UserDefaults 证据，但也未找到明确反证**，暂予保留，标记为待确认：

- 无（经二次核验后全部 53 键均有源码证据）

---

## 6. 后续动作

1. `lib/contract/prefs_keys.dart` 同步至 53 键、12 组
2. `scripts/check_contract_sync.py` 适配（分组名映射移除 buffer）
3. `prefs_manager.dart` 按 53 键实现，5 敏感键走 `flutter_secure_storage`
4. 本文档随契约一并纳入版本控制
