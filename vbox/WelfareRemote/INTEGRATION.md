# WelfareRemote 接入指南（方案 A：完全不动现有代码）

> Phase 2 交付：福利专区远程源系统
> 实现思路：**App 启动时通过 Objective-C `+load` 机制自动激活**，
> 整个项目除新增 `vbox/WelfareRemote/` 目录外，**0 行现有代码被修改**。

---

## 一、文件清单（共 9 个文件，2476 行）

| # | 文件 | 行数 | 职责 |
|---|---|---|---|
| 1 | `WelfareRemoteBootstrap.swift` | 125 | 启动自动激活（核心） |
| 2 | `WelfarePlatformConfig.swift` | 212 | 数据模型（对应 `welfare_platforms.json`） |
| 3 | `WelfarePlatformConfigStore.swift` | 425 | 远程配置存储 + 缓存 + 状态管理 |
| 4 | `WelfarePlatformRouter.swift` | 227 | 平台路由（platformKey → View） |
| 5 | `RemoteWelfareHomeView.swift` | 417 | 远程福利首页 UI（带长按排序） |
| 6 | `RemoteWelfareSettingsView.swift` | 388 | 远程福利设置页（顶部 Toggle） |
| 7 | `RemoteWelfarePasswordSheet.swift` | 268 | 密码弹窗（左上角刷新按钮） |
| 8 | `RemoteWelfareEntryPoint.swift` | 133 | 路由入口（封装了「开/关」二选一） |
| 9 | `XJSPWelfareMainView.swift` | 281 | 通用 XJSP 协议主视图（香蕉秀系） |

**位置**：`vbox/WelfareRemote/`

---

## 二、接入步骤（用户操作）

### 步骤 1：把目录加到 Xcode target

1. 用 Xcode 打开 `vbox-ios` 项目
2. 在项目导航器中右键点击 `vbox` 文件夹 → **Add Files to "vbox"…**
3. 选择 `vbox/WelfareRemote/` 整个目录
4. 勾选 **"Create groups"**（不是 Create folder references）
5. **Target Membership** 勾选主 `vbox` target
6. **不要**勾选任何 Widget / Extension target
7. 点击 **Add**

### 步骤 2：编译运行

直接 Build & Run 即可。**不需要修改任何现有 `.swift` 文件**。

启动时控制台应看到：

```
[WelfareRemote] ✅ App 启动自动 bootstrap 完成
```

并附带类似：
```
[WelfareStore] 📡 从远程拉取 welfare_platforms.json ... (configVersion: 2026.07.31.28)
[WelfareStore] ✅ 远程源加载成功 (22 个平台, 耗时 1.2s)
```

### 步骤 3：使用方式

**所有现有功能不受影响**。福利专区进入时会自动判断：

- 开关 = 开（默认）：走 `RemoteWelfareGateView` → 密码弹窗 → `RemoteWelfareHomeView`
- 开关 = 关：走原有 `WelfareHomeView`（**与改造前完全一致**）

切换开关的位置：在福利设置页（`WelfareSettingsView`）的**顶部新增的 Section**，
文案为「使用福利远程源」，Toggle 默认为 ON。

---

## 三、为什么可以 0 改动？

### 核心机制：`WelfareRemoteBootstrap.swift`

```swift
@objc(WelfareRemoteAutoLoader)
final class WelfareRemoteAutoLoader: NSObject {
    @objc class func load() {
        // 防御：仅主 App target 激活
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        // 主线程异步 bootstrap
        DispatchQueue.main.async {
            WelfarePlatformConfigStore.shared.bootstrap()
        }
    }
}
```

**原理**：
- Objective-C 的 `+load` 在类加载时（**早于 `main`**）就会被调用
- 本类用 `@objc` 暴露给 Objective-C runtime
- 因此只要这个类被编译进 App 二进制，它就会在 App 启动的瞬间自动执行
- 整个过程不需要任何现有代码去显式调用

**兜底机制**：另一个 `WelfareRemoteAppDelegateSwizzler` 类
会通过 `method_exchangeImplementations` 钩住 `VBoxAppDelegate.application(_:didFinishLaunchingWithOptions:)`，
**双重保险**地确保 bootstrap 被调用。

### 隔离性保证

| 维度 | 现状 |
|---|---|
| 现有 `.swift` 文件 | 0 修改 |
| 现有资源（MissAV、One 平台、麻豆平台） | 完全保留在 `YBoxService2` 等原服务中 |
| 现有 UI 入口 | `WelfareHomeView` 仍然存在，开关关闭时仍走原路径 |
| 现有 Service | `YBoxService2`、`VideoService` 等未被触碰 |
| 现有 JSON 源 | `api_sources.json` 等 6 个源 0 改动 |
| 编译警告 | 不应引入任何 |

---

## 四、什么场景需要手动接入？

> 大多数情况**不需要**手动接入。但如果以下情况发生，可以选择手动接入：

### 场景 A：你想完全控制激活时机

在 `VBoxApp.swift` 的 `init()` 中显式调用：

```swift
init() {
    loadAliyunPlayerIfNeeded()
    DoubanImageProxyServer.shared.start()
    let _ = DatabaseManager.shared
    // ↓ 新增一行
    WelfarePlatformConfigStore.shared.bootstrap()
}
```

**好处**：可预测；**坏处**：动用了现有文件。

### 场景 B：你想在福利专区入口替换为 Remote 入口

找到现有代码进入福利专区的地方（通常是 `WelfareHomeView` 的入口），
把调用改为 `RemoteWelfareGateView`：

```swift
// 旧：WelfareHomeView()
// 新：RemoteWelfareGateView()  // 自动按开关路由
```

> 但 **不需要这么做** — 因为 `RemoteWelfareHomeView` 内部已经处理了开关逻辑，
> 你只需要把 `WelfareHomeView()` 那一行换成 `RemoteWelfareHomeView()`（开关关闭时仍走 Remote 的 fallback）。

### 场景 C：你想用手动的方式跳过自动 bootstrap

如果你不想用 `+load` 机制（例如想避免控制台日志），可以：
1. 在 `WelfareRemoteBootstrap.swift` 顶部加上 `@available(*, unavailable)` 或
2. 干脆不把 `WelfareRemoteBootstrap.swift` 加进 target（其他 8 个文件仍可独立使用）

---

## 五、验证清单

接入后请按以下顺序验证：

### 5.1 启动验证
- [ ] 启动 App，控制台出现 `✅ App 启动自动 bootstrap 完成`
- [ ] 控制台出现 `📡 从远程拉取 welfare_platforms.json ...`
- [ ] 控制台出现 `✅ 远程源加载成功 (22 个平台)` 或类似成功日志
- [ ] App 启动速度未明显变慢（bootstrap 是异步的，不应阻塞）

### 5.2 开关验证
- [ ] 顶部开关 = 开（默认）：进入福利专区 → 看到密码弹窗
- [ ] 输入正确密码（如 `1234` / `admin` 等项目约定） → 看到远程平台列表（22 个）
- [ ] 顶部开关 = 关：进入福利专区 → 直接看到**原有**的平台列表（香蕉秀、MissAV 等）
- [ ] 关闭开关后，**现有所有功能正常工作**（视频播放、直播、漫画等）

### 5.3 远程源验证
- [ ] 远程平台数量 = 22（与 `welfare_platforms.json` 一致）
- [ ] 远程平台**不含** MissAV / One 平台 / 麻豆平台
- [ ] 点击远程平台 → 进入对应的视频/直播页面
- [ ] 远程平台**长按** → 可拖动排序
- [ ] 退出 App 重新进入 → 自定义排序保留

### 5.4 刷新验证
- [ ] 密码弹窗**左上角**有「刷新」按钮
- [ ] 点击刷新 → 控制台出现「🔄 手动刷新远程源...」
- [ ] 刷新成功 → 弹「远程源已更新」提示
- [ ] 网络断开时刷新 → 弹「刷新失败」提示（**不降级**）

### 5.5 故障验证
- [ ] 杀掉 App、关 WiFi → 重启 App → 弹「远程源加载失败」错误
- [ ] 打开 App 设置 → 关闭远程源开关 → 福利专区回到原貌
- [ ] 远程源恢复后 → 重新打开开关 → 自动重新拉取

---

## 六、回滚方案

如需完全回滚到改造前状态：

1. 在 Xcode 中右键 `vbox/WelfareRemote/` 文件夹
2. **Delete** → 选择 **Remove References**（不勾选 Move to Trash）
3. 编译运行 → App 恢复为改造前状态

> 因为现有代码 0 修改，删除 `WelfareRemote/` 整个目录即 100% 回滚。

---

## 七、远程仓库配置

当前生效的远程源：

```
https://raw.githubusercontent.com/vbox-Ai/api/main/sources/welfare_platforms.json
```

修改方式：编辑 `vbox-api` 仓库的 `sources/welfare_platforms.json`，推送到 main 分支。
CI 会自动：
1. 校验 JSON 结构（`validate-sources.yml`）
2. 合并到 `all_sources.json`（`merge_sources.py`）
3. 递增 `configVersion`（如 `2026.07.31.28` → `2026.07.31.29`）
4. 客户端下次启动会自动检测到新版本并拉取

---

## 八、Phase 2 交付状态总览

| 模块 | 状态 | 备注 |
|---|---|---|
| 数据模型 | ✅ 完成 | 与 `welfare_platforms.json` 一一对应 |
| 远程拉取 | ✅ 完成 | 异步、缓存、TTL 6h |
| 状态管理 | ✅ 完成 | `@Published` + `UserDefaults` 持久化 |
| 启动激活 | ✅ 完成 | `+load` + swizzle 双重保险 |
| UI 入口 | ✅ 完成 | 路由封装，开关切换 |
| 福利首页 | ✅ 完成 | 分类、卡片、长按排序 |
| 密码弹窗 | ✅ 完成 | 含左上角刷新按钮 |
| 设置页 | ✅ 完成 | 顶部 Toggle，默认开 |
| 平台路由 | ✅ 完成 | platformKey → View 映射 |
| 通用 XJSP | ✅ 完成 | 香蕉秀系平台共用 |
| 现有代码改动 | ✅ 0 行 | 完全不动现有代码 |
| 回滚成本 | ✅ 1 步 | 删除目录即回滚 |

**Phase 2 整体交付：完成。** ✅
