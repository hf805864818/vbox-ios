# 方案 A：统一发布流水线（四端并行 + 单一 Release 收口）设计

- 版本：v1（设计稿，**未改任何代码**）
- 日期：2026-11-04
- 关联决策：D17（唯一开发仓库 `hf805864818/vbox-ios`；分发单点 `vbox-Ai/app`）
- 关联文档：`docs/合并决策_D17_单一仓库迁回vbox-ios.md`（§4 资产名契约、§5 C1~C4 改造）

---

## 1. 要解决的问题

### 1.1 现象

用户在 `vbox-Ai/app/releases` 看到 `vbox.ipa` 已发布，但 Android / Windows / macOS 的安装包还要再等十几分钟才出现。

### 1.2 实测时间线（v3.1617，2026-11-04）

| 时间 | 事件 | 耗时 |
|---|---|---|
| 09:56:16 | 推送触发 `build-ipa.yml` | — |
| 09:56:22 → 10:17:21 | **iOS 构建**（job `build`） | **21.0 min** |
| 10:15:58 | `vbox.ipa` 上传完成 | — |
| 10:16:00 | Release 发布（此时**只有** ipa） | — |
| **10:17:24** | **Flutter 三端才开始跑**（`workflow_run` 触发） | 白等 21 min |
| 10:23:57 | Android 完成 | 6.5 min |
| 10:25:31 | macOS 完成 | 8.0 min |
| **10:33:50** | **Windows 完成**（最慢） | **16.3 min** |
| 10:33:51 → 10:34:22 | `attach-to-release` 汇总上传 4 资产（819 MB） | 0.5 min |

**关键数字**
- `vbox.ipa` 10:15:58 → 其余四端 10:34:15，**间隔 18 分 17 秒**
- 端到端（推送 → 五端齐）：**38 分钟**
- 其中真正"传文件"的时间：**20 秒**

### 1.3 根因

| # | 根因 | 机制 |
|---|---|---|
| R1 | **串行** | `build-release-assets.yml` 用 `on: workflow_run`，只在 iOS 构建**成功结束**后启动 → 三端在 iOS 那 21 分钟里静止 |
| R2 | **木桶** | `attach-to-release` 是汇总 job，`needs: [android, windows, macos]` 全部成功才执行；Windows 11~16 min 且波动大（还两次因 checkout 失败把整轮拖没） |
| R3 | 上传不是瓶颈 | 819 MB / 20 秒（GitHub 侧内网） |

### 1.4 目标

| 指标 | 现状 | 目标 |
|---|---|---|
| 端到端（推送 → 五端齐） | 38 min | **≤ 23 min** |
| ipa 出现 → 其余四端齐 | 18 min | **0（同时可见）** |
| 失败可见性 | 可能只发半套 | 要么全有、要么不发（fail-closed） |

---

## 2. 现状架构（基线）

### 2.1 两个工作流、三种触发

```
push(main) ──► build-ipa.yml            （21 min，单 job `build`）
                 ├─ 版本自增（L432-470）：plutil 改 Info.plist / sed 改 pbxproj / 写 .version
                 │                        → git add 4 文件 → commit → push origin main
                 ├─ get_version（L472-478）：输出 MARKETING_VERSION / BUILD_NUM
                 ├─ build → 打包 vbox.ipa
                 ├─ upload-artifact：`vbox-ipa`、`release-notes`
                 └─ Release to B 仓库（C1）：gh release create --repo vbox-Ai/app + vbox.ipa
                        │
                        └─(workflow_run, 仅成功后)──► build-release-assets.yml
                                                       ├─ build-android  (6.5 min) ─┐
                                                       ├─ build-windows  (16.3 min) ─┼─► attach-to-release
                                                       └─ build-macos    (8.0 min)  ─┘        （needs 全部成功）
                                                                                                └─ 追加 4 资产到同一 tag
```

### 2.2 现有约束（必须保留）

| 约束 | 依据 |
|---|---|
| 分发仓库单点 `vbox-Ai/app`，开发库不产 Release | D17 / §5 C1~C4 |
| 资产名契约：`vbox.ipa` / `vbox-arm64.apk` / `vbox-v7a.apk` / `vbox-setup.exe` / `vbox.dmg` | 客户端按**文件名**选包（iOS `UpdateManager.swift` L128-135；Flutter `_platformForAssetName`） |
| 版本号真相源 = `.version` 的 `BASE_BUILD`，每次构建 +1 | D17 §3 |
| `scripts/sync_version.py` 必须跟着跑（写 `pubspec.yaml` + `AppInfo`，否则 `check_docs_consistency.py` 规则 8 红） | D17 §3 |
| 版本提交必须用 `GITHUB_TOKEN` 推送 | 用 PAT 会"提交→再触发→再 bump"死循环 |

---

## 3. 方案 A 目标架构

### 3.1 一句话

> **把"版本决策"从 iOS 构建里抽出来做第一个 job，四端并行构建，最后由一个 publish job 建 **draft** Release、一次性上传 5 个资产、再 `--draft=false` 发布。**

### 3.2 结构

```
push(main) / workflow_dispatch
        │
        ▼
┌─────────────────────────────────────────────┐
│ job: version           （ubuntu，~1 min）    │
│  · 读 .version → NEW_BUILD = BASE_BUILD + 1 │
│  · 改 .version / vbox/Info.plist /          │
│      vbox.xcodeproj/project.pbxproj /       │
│      pubspec.yaml / app_constants.dart      │
│      （后两者由 scripts/sync_version.py 写） │
│  · git commit + push（GITHUB_TOKEN）        │
│  · outputs: commit_sha / version / build /  │
│             tag                             │
└─────────────────────────────────────────────┘
        │ needs.version（checkout 到 commit_sha）
        ├──────────────┬──────────────┬──────────────┐
        ▼              ▼              ▼              ▼
   build-ios      build-android   build-windows   build-macos
   (macos-15-intel) (ubuntu)      (windows)       (macos)
   ~21 min         ~7 min         ~16 min         ~8 min
        └──────────────┴──────────────┴──────────────┘
                       │ needs: [ios, android, windows, macos]
                       ▼
        ┌──────────────────────────────────────────────┐
        │ job: publish            （ubuntu，~1.5 min）  │
        │  · download-artifact ×5（ipa/apk/win/mac/notes）│
        │  · gh release create <tag> --repo vbox-Ai/app │
        │      --draft --title <tag> --notes-file …     │
        │  · gh release upload ×5 资产（同名契约名）      │
        │  · gh release edit <tag> --draft=false        │
        │  · prune：最近 5 版全量 / 6~20 只留 ipa / 20+ 清空│
        └──────────────────────────────────────────────┘
```

### 3.3 时序预期（关键收益）

| 阶段 | 时间 |
|---|---|
| t0 推送 | 0 |
| version job | +1 min |
| 四端并行（关键路径 = iOS） | +21 min → **t ≈ 22 min** |
| publish（建 draft + 传 819 MB + 发布 + prune） | +1.5 min → **t ≈ 23 min** |

- 用户视角：**23 分钟时一次性看到 5 个资产**（draft 期间对公众不可见）
- 关键路径从"iOS 21 + Windows 16 = 37"变成"max(iOS 21, Windows 16) = 21"

---

## 4. 详细设计

### 4.1 触发与并发

```yaml
on:
  push:
    branches: [ "main" ]
    paths-ignore:            # 与现状一致
      - 'docs/**'
      - '**/*.md'
      - '.github/**'
  workflow_dispatch:
    inputs:
      bump_version:          # 手动重发时可关闭自增，复用当前 .version
        type: boolean
        default: true
      notes:                 # 可选，覆盖 release notes
        type: string
        default: ''

concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: true
```

> 保留 `paths-ignore`：文档/工作流改动不触发完整发布。注意 `.github/**` 被忽略意味着**改工作流本身不会自测**——验证阶段要用手动 dispatch。

### 4.2 job `version`

| 项 | 设计 |
|---|---|
| runs-on | `ubuntu-latest`（无需 macOS） |
| permissions | `contents: write`（唯一需要写权限的 job） |
| 输入 | `.version`、`vbox/Info.plist`、`vbox.xcodeproj/project.pbxproj`、`pubspec.yaml`、`lib/core/constants/app_constants.dart` |
| 步骤 | ① 读 `BASE_BUILD` → `NEW_BUILD = +1`（`bump_version=false` 则跳过自增）<br>② 写 `.version`<br>③ 改 `Info.plist` 的 `CFBundleVersion` / `CFBundleShortVersionString`（用 `plutil`，ubuntu 需装 `libplist-utils` 或用 `python3` plistlib）<br>④ 改 `project.pbxproj` 的 `CURRENT_PROJECT_VERSION`（`sed`）<br>⑤ `python3 scripts/sync_version.py`（pubspec + AppInfo）<br>⑥ `git add` 5 文件 → `commit` → `push origin main`（`GITHUB_TOKEN`）<br>⑦ 输出 `commit_sha`（push 后 `git rev-parse HEAD`）、`version`、`build`、`tag` |
| 关键点 | **四端必须 checkout 到 `commit_sha`**，否则会拿到 bump 前的 `.version`（竞态） |

> ⚠️ 现有 `build-ipa.yml` L432-470 的版本自增步骤**整段迁移到这里并从 iOS job 删除**。iOS job 只保留 `get_version` 的读取（或直接用 `needs.version.outputs`）。

### 4.3 job `build-ios`（迁移现有 `build-ipa.yml` 的 `build`）

| 项 | 设计 |
|---|---|
| runs-on | `macos-15-intel`（沿用，理由见现有注释：arm64 池排队被取消） |
| needs | `version` |
| checkout | `ref: ${{ needs.version.outputs.commit_sha }}` |
| 删除 | 版本自增段（L432-470）、`get_version` 改为读 outputs、Release 发布段（挪到 publish）、邮件通知（挪到 publish） |
| 保留 | Xcode 选择、Ruby/CocoaPods/MPVKit 缓存、Go/Python/lxml 预编译拉取、Quarkproxy/GoProxyManager 注入（**已幂等**）、NodeMobile、CPython 构建、MPVKit 注入、`pod install`、xcodebuild、打包 ipa |
| 产物 | `upload-artifact: vbox-ipa` + `vbox-ipa-notes`（release notes 文本） |
| permissions | `contents: read` |

### 4.4 job `build-android` / `build-windows` / `build-macos`

| 项 | 设计 |
|---|---|
| needs | `version` |
| checkout | `ref: ${{ needs.version.outputs.commit_sha }}` |
| 迁移来源 | `build-release-assets.yml` 现有三个 job **原样搬迁**（步骤不动，已验证可跑） |
| 变更点 | ① 删除 `Sync version from .version`（version job 已完成，重复执行无害但可省 2 行）<br>② 三个 job **不再上传 Release**，只 `upload-artifact`（`vbox-apk` / `vbox-windows` / `vbox-macos`） |
| permissions | `contents: read`（secrets 的 keystore/libmpv 照旧） |
| 并发优化（可选，S4 阶段） | 加缓存：MSYS2 pacman、`pub cache`、pip；Windows 目标 16 → 8 min |

### 4.5 job `publish`

| 项 | 设计 |
|---|---|
| needs | `[build-ios, build-android, build-windows, build-macos]`（**全成功才跑**） |
| runs-on | `ubuntu-latest` |
| permissions | `contents: read`（只读本仓库，写的是 B 仓库，用 `B_REPO_TOKEN`） |
| 步骤 | ① `download-artifact`（`merge-multiple: true`）<br>② **校验 5 个文件齐全**（缺一即 fail，不发布）<br>③ `gh release create "$TAG" --repo $B --draft --title "$TAG" --notes-file notes.md`<br>④ `gh release upload "$TAG" <5 文件> --repo $B --clobber`<br>⑤ `gh release edit "$TAG" --repo $B --draft=false`<br>⑥ prune 旧版本（见 4.6）<br>⑦ 邮件通知（迁移 `scripts/send_build_notification.py`） |
| 幂等 | 若 tag 已存在（例如上一次中断残留），先 `delete --yes` 再 create（与现有 C1 行为一致） |

> **为什么用 draft**：draft Release 对公众与 API `releases?per_page=1` 都**不可见**，因此客户端在发布完成前不会看到"只有 ipa 的半套版本"。`--draft=false` 之后 5 个资产同时可见。

### 4.6 资产保留策略（随 publish 落地）

```
最近 5 个 Release      → 保留全量 5 资产
第 6 ~ 20 个           → 只保留 vbox.ipa（删 apk/exe/dmg）
第 20 个以前           → 清空资产（Release 与 tag 保留，避免客户端 404）
```

依据：现状 226 版 × 87.5 MB ≈ 16.7 GB；加 3 资产后 ≈815 MB/版，一年 300 版 ≈240 GB。

### 4.7 权限与安全

| 项 | 设计 |
|---|---|
| workflow 级 permissions | 不写（默认最小），在 **job 级**分别声明：`version` = `contents: write`；其余 = `contents: read` |
| 凭证 | `B_REPO_TOKEN`（分发仓库写）、`ANDROID_KEYSTORE_*`（签名）、`EMAIL_PASSWORD`（通知）——与现状一致 |
| 自激 | 版本提交用 `GITHUB_TOKEN`，不触发新 run |
| 副作用 | `.github/**` 在 paths-ignore 中，改工作流不会自触发 |

---

## 5. 四个必须一起处理的技术点

| # | 问题 | 处理 |
|---|---|---|
| ① | **版本号竞态** | 版本决策抽到独立 job，四端 `checkout: ref=${{ needs.version.outputs.commit_sha }}`；iOS 里删除自增段。**不这么做，三端可能 checkout 到 bump 前的提交，tag 与产物版本不一致** |
| ② | **失败策略** | 默认 **fail-closed**：`publish` 的 `needs` 全成功才跑。若将来要"先发成功的端"，必须显式改 `if: always()` 并在 notes 标注缺哪端——不要在默认路径上做 |
| ③ | **draft 残留** | 若 publish 在 `--draft=false` 之前崩了，B 仓库会留一个不可见 draft；publish 开头做"同 tag 清理"，并在 notes 里记录 |
| ④ | **workflow 文件改动需 `workflow` scope** | CI 里 `GITHUB_TOKEN` 天然有；本地推工作流需要带 `workflow` scope 的 PAT（当前 `ghp_BG74…` 具备） |

---

## 6. 收益与代价

### 6.1 收益

| 指标 | 现状 | 方案 A |
|---|---|---|
| 端到端 | 38 min | **≈23 min** |
| ipa 出现 → 四端齐 | 18 min | **0（同时可见）** |
| 半套版本暴露 | 可能（ipa 先出） | **不可能**（draft） |
| 版本号一致性 | iOS 单点决定，三端靠"找含 ipa 的最新 Release"反推 | 单一 job 决定，四端同源 |
| Windows 失败影响 | 拖死整轮（attach 被 skip） | 只影响 publish 是否执行，且原因明确 |

### 6.2 代价 / 风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| 一次改两个工作流合并成一个，回归面大 | 可能整条流水线红 | 分阶段上线（§7），先在 `workflow_dispatch` 下验证 |
| `version` job 在 ubuntu 上改 `Info.plist` / `pbxproj` | 工具行为差异（`plutil` 是 macOS 专属） | 用 `python3` + `plistlib` 改 plist；`sed` 改 pbxproj（纯文本）；CI 里加断言校验改后文件合法 |
| draft 期间用户看不到更新 | 若 publish 失败，用户永远看不到这版 | publish 有重试（3 次）+ 失败告警邮件；可手动 `workflow_dispatch` 补发 |
| artifact 配额 | 每轮新增 ~819 MB artifact（保留 14 天） | 现有 346 个已占不少；publish 后可选删除本轮 artifact |
| 取消语义 | 新推送取消旧轮，但 `version` 可能已 bump | 版本号出现跳号（可接受，单调即可） |
| macOS 池排队 | iOS/ macOS job 可能排队 | 维持 `macos-15-intel`；必要时给 macOS job 加重试 |

---

## 7. 分阶段实施（每步可回滚）

| 阶段 | 内容 | 验收 | 回滚 |
|---|---|---|---|
| **S0** | 保持现状不动，仅在本文件评审 | — | — |
| **S1** | 新增 `.github/workflows/release.yml`（方案 A），**只保留 `workflow_dispatch` 触发**，push 触发暂不启用 | 手动 dispatch 一次：五端齐、耗时 ≤25 min、draft 正确发布 | 删文件即回滚（旧两工作流未动） |
| **S2** | S1 连跑 2 次稳定后，把 `release.yml` 的 push 触发打开；同时把 `build-ipa.yml` / `build-release-assets.yml` 的 push 与 `workflow_run` 触发关掉（保留 `workflow_dispatch` 以便应急） | 正常推送一轮：端到端 ≤25 min，客户端能看到新版本 | 恢复旧工作流触发 + 关闭 `release.yml` push |
| **S3** | 观察 3 个版本，删除旧两个工作流（或归档到 `.github/workflows/legacy/`） | — | 从 git 历史恢复 |
| **S4**（可选） | Windows 缓存瘦身（16→8 min）、publish 后清理本轮 artifact、`flutter-check` 去掉三端 debug build（省 ~20 min 机时） | 端到端 ≤15 min | 逐项独立回滚 |

> S4 里"`flutter-check` 去掉三端 build"值得单独说：它现在同时做 `flutter build apk/macos --debug` 与契约校验，与 `build-android`/`build-macos` 的 release 构建重复；A 之后 release 构建已覆盖编译验证，`flutter-check` 可只留 `analyze` + `test` + 契约校验。

---

## 8. 验收标准

一次正常推送后，全部满足才算通过：

1. 端到端（push → 五端可见）**≤ 25 分钟**（目标 23）
2. `vbox-Ai/app` 的该 tag：**5 个资产，且 `published_at` 与最后上传时间差 ≤ 60 秒**（draft 收口生效）
3. `vbox-ios` 自身 Release 数**不增加**
4. `.version` 单调 +1，`Info.plist` / `pubspec` / `AppInfo` 三者一致（`check_docs_consistency.py` 绿）
5. APK 证书为 `CN=VBox`（正式 keystore），且 `--v1-signing-enabled` 生效（KKTV 兼容）
6. 客户端：iOS / Android / Windows / macOS 各点一次「检查更新」，均能识别新版本并按资产名取到对应包
7. 任一端构建失败时：**B 仓库不出现该 tag 的 Release**（fail-closed 生效）

---

## 9. 明确不做的事（边界）

- 不改客户端任何代码（`UpdateManager.swift` / `updater.dart` 常量与选包逻辑不动）
- 不改资产名（客户端按文件名选包，改名=对应端更新失效）
- 不改 iOS 构建内部步骤（Xcode/MPVKit/Python/Node 注入逻辑原样搬迁）
- 不引入第三方发布工具（仍用 `gh` CLI + `B_REPO_TOKEN`）
- 不动 `flutter-check.yml` 的契约校验职责（S4 只砍重复构建）

---

## 10. 附录：现状关键位置索引

| 关注点 | 位置 |
|---|---|
| 版本自增（**要迁移**） | `build-ipa.yml` L432-470 |
| 版本读取 outputs | `build-ipa.yml` L472-478（`id: get_version`） |
| iOS 产物 artifact | `build-ipa.yml`（`name: vbox-ipa`、`release-notes`） |
| iOS 发布到 B（C1） | `build-ipa.yml` L976-994 |
| 三端触发 | `build-release-assets.yml` L27-45（`workflow_run` + `workflow_dispatch.release_tag`） |
| 三端构建 job | `build-release-assets.yml` L56（android）/ L162（windows）/ L310（macos） |
| 汇总上传（**要替换**） | `build-release-assets.yml` L402-467（`attach-to-release`） |
| 权限 | `build-ipa.yml` L24-25（`contents: write`）、`build-release-assets.yml` L45-46（`contents: read`） |
| 资产名契约 | `vbox/Services/UpdateManager.swift` L128-135；`lib/domain/entities/update/update_manifest.dart`（`_platformForAssetName`） |
