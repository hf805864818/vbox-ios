# vbox - 多端聚合视频播放器

iOS 端：基于 Myapp3.1 (TVBox 架构) 逆向分析的 iOS 移植版本（`vbox/`，Swift / SwiftUI）。
Flutter 端：Android / Android TV / Windows / macOS 四端重构（`lib/`）。

> 本仓库为**唯一开发仓库**（iOS + Flutter 四端）。
> 2026-11-04 由 `q2787244398/vboxapp` 迁回本仓库，决策编号 **D17**（原 D14 指向已作废）。
> 规划与进度见 [`docs/VBOX_PLAN_v6.51.md`](docs/VBOX_PLAN_v6.51.md)；
> 迁移决策与回滚方式见 [`docs/合并决策_D17_单一仓库迁回vbox-ios.md`](docs/合并决策_D17_单一仓库迁回vbox-ios.md)。

## 仓库结构（顶层）

| 目录 | 说明 |
|------|------|
| `vbox/` | iOS 代码（Swift / SwiftUI），兼作**契约来源（唯一真相源）** |
| `lib/` | Flutter 多端共享 Dart 代码（契约 / 核心 / 数据 / 领域 / 表现 / 平台） |
| `android/` · `macos/` · `windows/` | Flutter 平台壳（`flutter create` 官方模板，包名 `com.vbox.player`） |
| `contract/` | 跨端契约层（SQLite DDL / Prefs 键 / JSON Schema / Spider ABI / 备份格式） |
| `conformance/` | 一致性样本与 runner |
| `scripts/` | 校验（`check_*.py`）与构建/运维脚本 |
| `go-proxy/` · `quickjs/` · `jsc/` | 脚本运行时与代理（Spider 引擎依赖） |
| `assets/` | 字体、品牌图、noderuntime、python-stdlib |
| `docs/` | 方案、对齐清单与决策记录 |

## 发布与分发（D17）

本仓库**只做开发与构建，不产出 App Release**。所有安装包统一发布到分发仓库
**`vbox-Ai/app`** —— App 内「检查更新」读取的就是它（iOS `UpdateManager.swift` 与
Flutter `lib/platform/update/updater.dart` 的仓库常量一致，均为 `vbox-Ai/app`）。

每次 push 到 `main`：

1. `build-ipa.yml` 构建 iOS，把 `vbox.ipa` 发到 `vbox-Ai/app` 的 `v<版本>` Release；
2. `build-release-assets.yml` 构建三端，把 `vbox-arm64.apk` / `vbox-v7a.apk` /
   `vbox-setup.exe` / `vbox.dmg` 追加到**同一个** Release；
3. `flutter-check.yml` 跑契约校验 + `flutter analyze` + `flutter test` + 三端 `flutter build`。

**资产名是跨端契约**（App 内按**文件名**选包），改名会直接让对应端更新失效：

| 端 | 资产名 | 选择规则 |
|---|---|---|
| iOS | `vbox.ipa` | 取 Release 中第一个 `.ipa` |
| Android arm64 | `vbox-arm64.apk` | `*.apk` 且不含 `v7a`/`armeabi` |
| Android v7a | `vbox-v7a.apk` | `*.apk` 且含 `v7a`/`armeabi` |
| Windows | `vbox-setup.exe` | `*.exe` |
| macOS | `vbox.dmg` | `*.dmg` |

版本号真相源是 `.version` 的 `BASE_BUILD`（CI 每次构建 +1，再由
`scripts/sync_version.py` 同步到 `pubspec.yaml` 与 `AppInfo`）。

安装：下载对应平台安装包；iOS 用 TrollStore 打开 `vbox.ipa`。

## Flutter 端校验

推送后由 GitHub Actions `.github/workflows/flutter-check.yml` 执行：
契约校验脚本 + conformance runner + `flutter analyze` + `flutter test`（含覆盖率门槛）
+ 三端 `flutter build`（`build-android` / `build-macos` / `build-windows`）。

> ⚠️ **本机无需安装 Flutter SDK**：沙箱为**按会话创建**的微虚拟机，工作区**不跨会话保留**，
> 本地安装的 Flutter SDK **无法留存**且会诱导每个新会话**重复下载安装数 GB**。
> Dart 侧的**编译 / 静态分析 / 单测 / 构建一律由 CI**（`flutter-check.yml`）承担；
> 本机**仅跑纯 Python 守卫**（`scripts/check_*.py`）与 conformance runner。

## 架构（iOS 侧）

```
┌──────────────────────────────────────┐
│  SwiftUI Views                       │
│  首页 / 搜索 / 详情 / 播放器 / 设置   │
├──────────────────────────────────────┤
│  SpiderRepository (多站点聚合搜索)    │
├──────────────────────────────────────┤
│  JSSpiderEngine (JavaScriptCore)     │
│  ├─ cheerio.min.js (HTML解析)        │
│  ├─ crypto-js.js (加密)              │
│  ├─ 模板.js (TVBox站点模板)          │
│  └─ 蜘蛛脚本 (用户配置)              │
├──────────────────────────────────────┤
│  JSHTTPBridge (原生HTTP桥接)         │
│  AVPlayer (视频播放)                 │
└──────────────────────────────────────┘
```

## 手动触发构建

在 GitHub Actions 页面点 **Run workflow** 即可手动触发（`build-ipa.yml` 支持传入
`mobile_vlc_url` 备用源地址）。

## 技术栈

- Swift 5 / SwiftUI（iOS）
- JavaScriptCore (JS引擎)
- AVFoundation / libmpv / MDK（多内核播放）
- Flutter / Dart 3（Android · Android TV · Windows · macOS）
- iOS 15.0+（`IPHONEOS_DEPLOYMENT_TARGET=16.0`）
- arm64（巨魔）

TG：https://t.me/hfkj520