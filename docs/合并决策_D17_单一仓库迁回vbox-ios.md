# D17：开发仓库迁回 `hf805864818/vbox-ios`（单一仓库）

- 决策日期：2026-11-04
- 状态：**已生效**（取代 D14「`q2787244398/vboxapp` 为唯一开发仓库」）
- 关联：`docs/VBOX_PLAN_v6.51.md`（顶部已加 D17 banner；正文 7 处 D14 表述已改指）

---

## 1. 决策与背景

| 项 | 内容 |
|---|---|
| 旧决策 D14 | `q2787244398/vboxapp` 为唯一开发仓库（含 iOS + Flutter 三端） |
| 新决策 D17 | **`hf805864818/vbox-ios` 为唯一开发仓库**（iOS + Flutter 四端）；vboxapp 冻结为历史 |
| 动机 | 开发与分发分离：vbox-ios 做唯一开发库；安装包统一由 `vbox-Ai/app` 分发 |
| 关键事实 | vboxapp 是 vbox-ios 的**严格超集**（404 同路径文件中 394 个逐字节相同，仅 10 个内容分叉 + 1 个权限位），两库**无共同祖先** |

## 2. 合并记录

| 项 | 值 |
|---|---|
| 改写前 vbox-ios HEAD | `b05b5a871eae125a83b12fc861e600216813c607`（`.version`=1613） |
| 合并来源 | `q2787244398/vboxapp` @ `34eb09c3d138b1c8e1b9dd94f244a94ac6ecd4bf`（3.1894） |
| 历史清洗 | `filter-repo --path .uploads --invert-paths`：**1908/1909 个提交 SHA 全部改变**；main 由 `b05b5a8` → `0fcd4cdc`；1241 个 tag 全部重写并强推 |
| 合并提交 | `c90b685f`（双父：`0fcd4cdc` + `34eb09c3`，`--allow-unrelated-histories`） |
| 清理提交 | `ea4b229c`（退库 `*.o`×6 / `check_project.py` / `fix_pbxproj*.py` / `pre-commit.sh` / 2 份重复 md） |
| CI 改造提交 | `5b649337`（P1：C1~C4） |
| 合并后规模 | 1689 文件；相对 vboxapp **丢失 0 / 新增 0 / 修改 5**（2 个工作流 + `.version` + `Info.plist` + 1 个权限位） |

### 2.1 11 处冲突及处置

| # | 文件 | 处置 | 原因 |
|---|---|---|---|
| 1 | `.version` | **ours（vbox-ios，1613）** | M1：版本主线以 vbox-ios 为准 |
| 2 | `vbox/Info.plist` | **ours（3.1613 / 1613）** | 必须与 #1 同源 |
| 3 | `.github/workflows/build-ipa.yml` | theirs（vboxapp） | 含 `paths-ignore` / `concurrency` / `macos-15-intel` / `sync_version.py` 版本联动 |
| 4 | `.github/workflows/build-quickjs.yml` | theirs | Windows/macOS 交叉编译 |
| 5 | `.gitignore` | theirs | 含 `*.o` / `.uploads/` / Flutter 产物 |
| 6 | `README.md` | theirs → 再按本决策重写 | 补「发布与分发（D17）」与资产名契约 |
| 7 | `vbox.xcodeproj/project.pbxproj` | theirs | 工程项更新（遗留问题见 §8） |
| 8 | `vbox/Models/SpiderModels.swift` | theirs | `VodCategory.subCategories`（`sub_categories`） |
| 9 | `vbox/Services/CloudDriveManager.swift` | theirs | 夸克：`client_id=386` / `sys=win32` / 新 UA / `pr,fr,sch,sve` |
| 10 | `vbox/WelfareRemote/WelfareResultMapper.swift` | theirs | 映射 `subCategories → FuliCategory` |
| 11 | `scripts/pack_python_artifacts.sh` | theirs（755） | 权限位 |

## 3. 版本主线

- 真相源：`.version` 的 `BASE_BUILD`（当前 **1613**，首发 **v3.1614**）。
- 联动：CI `+1`（`build-ipa.yml`）→ `scripts/sync_version.py` 写 `pubspec.yaml` + `lib/core/constants/app_constants.dart`（`AppInfo.version/buildNumber`）→ 三文件一起提交。
- 守卫：`scripts/check_docs_consistency.py` 规则 8 校验 pubspec 与 AppInfo 一致（**改版本逻辑时必须同时改这两处，否则 flutter-check 红**）。
- **版本提交必须用 `GITHUB_TOKEN` 推送**；若改用 PAT，会形成「版本提交 → 再触发构建 → 再 +1」死循环。
- 补救开关：若出现「本地版本高于远端、收不到更新」（例如曾手工装过 1614~1894 的构建），下次发版把 `BASE_BUILD` 直接跳到 ≥ 该用户版本再自增即可。

## 4. 分发单点：`vbox-Ai/app`

- 两端常量一致：iOS `vbox/Services/UpdateManager.swift`（`repoOwner="vbox-Ai"`、`repoName="app"`）、Flutter `lib/platform/update/updater.dart`（`defaultRepoOwner/defaultRepoName`）。
- 拉取口径：`releases?per_page=1` + 按**资产名**选包（不是 MIME）。**资产名是跨端契约**：

| 端 | 资产名 | 选择规则 |
|---|---|---|
| iOS | `vbox.ipa` | Release 中第一个 `.ipa` |
| Android arm64 | `vbox-arm64.apk` | `*.apk` 且不含 `v7a`/`armeabi` |
| Android v7a | `vbox-v7a.apk` | `*.apk` 且含 `v7a`/`armeabi` |
| Windows | `vbox-setup.exe` | `*.exe` |
| macOS | `vbox.dmg` | `*.dmg` |

- 发布方式：`build-ipa.yml` 建 Release（IPA 先落）→ `build-release-assets.yml` 的 `attach-to-release` 追加三端资产到**同一 tag**。
- **资产保留策略（必须执行，否则线性膨胀）**：现状 226 版 × 87.5 MB ≈ 16.7 GB；加 3 资产后 ≈815 MB/版。

```
最近 5 版    → 保留全量 5 资产
第 6~20 版   → 只保留 vbox.ipa（删 apk/exe/dmg）
第 20 版以前 → 清空资产（Release 与 tag 保留，避免更新检查 404）
```

## 5. 发布链改造（P1，C1~C4）

| 编号 | 文件 | 变更 |
|---|---|---|
| C1 | `build-ipa.yml`（job `build`） | 建 Release 加 `--repo "$B_REPO_OWNER/$B_REPO_NAME"`；`GH_TOKEN` 换 `secrets.B_REPO_TOKEN`；新增 `B_REPO_OWNER`/`B_REPO_NAME` 环境变量 |
| C2 | `build-ipa.yml` | **删除 `sync-b-repo` 整段**（与 C1 抢同一 tag 会 `tag already exists`） |
| C3 | `build-release-assets.yml`（`attach-to-release`） | tag 发现 `gh api repos/$B_REPO_OWNER/$B_REPO_NAME/releases`；`release view/upload/create` 全部加 `--repo`；两处 `GH_TOKEN` 换 `secrets.B_REPO_TOKEN` |
| C4 | `build-release-assets.yml` | `permissions` 由 `contents: write` 降为 `contents: read` |

**C4 的例外（重要）**：`build-ipa.yml` 的 `permissions` **保持 `contents: write`** —— 版本号自增后仍需 `git push` 回 `main`，降为 read 会直接让构建失败。

## 6. Secrets 与签名

`hf805864818/vbox-ios` 现有 5 个：`B_REPO_OWNER`、`B_REPO_NAME`、`B_REPO_TOKEN`、`EMAIL_PASSWORD`、`GH_TOKEN`（后者无任何工作流引用，可删）。

| 用途 | 需要的 secret | 说明 |
|---|---|---|
| 发布到分发仓库 | `B_REPO_OWNER`=`vbox-Ai`、`B_REPO_NAME`=`app`、`B_REPO_TOKEN` | PAT 必须对 `vbox-Ai/app` 有 Contents: RW + 可建 Release；实测可用（draft Release + 资产上传往返验证通过） |
| APK 签名 | `ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD` | **必须是 vboxapp 一直使用的同一把 keystore**：换 keystore = 签名变更 = 已装用户必须卸载重装（本地数据/登录态丢失） |
| 构建通知（可选） | `EMAIL_PASSWORD` | SMTP 授权码 |
| 依赖下载（可选） | `LIBMPV_DEPS_TOKEN` / `LIBMPV_DEPS_URL`、`MOBILE_VLC_KIT_URL` | 均有公开默认值 |

⚠️ 权限过大的风险：当前 `B_REPO_TOKEN` 为全量 PAT（含 `delete_repo` / `admin:org` / `workflow`）。缓解措施：`main` 开分支保护、`.github/workflows` 走 CODEOWNERS、限制 write 权限人数、季度轮换、`vbox-Ai` 账号启用 2FA。

## 7. 回滚

| 阶段 | 动作 |
|---|---|
| 历史改写后、合并前 | 用 `vbox-ios-pre-rewrite-20261104.bundle`（或服务端分支 `pre-merge-backup-20261104-0652`）还原 |
| 合并后、未推 main | `git reset --hard <改写后的备份点>` |
| 已发布 v3.1614 | `gh release delete v3.1614 --repo vbox-Ai/app`；`git revert` 合并提交；`.version` 手工回退。已发出的包无法收回，用户端只会「无更新」 |
| 转公开后 | Settings → 改回 Private（会立刻恢复 Actions 计费） |
| vboxapp / `q2787244398/app` 归档 | Unarchive（可逆） |
| `vbox-Ai/app-1` 删除 | **不可逆**（源 `q2787244398/app` 保留） |

## 8. 遗留与后续事项

1. **20 个历史特性分支未重写**（`origin/feature/*`、`origin/fix/*` 等仍指向旧 SHA，也是旧 blob 的临时保留处）→ 建议确认无用后统一删除。
2. **`vbox.xcodeproj/project.pbxproj` 存在脚本注入累积**：`GoProxyManager.swift` 在 Sources 阶段出现 **459** 次（vbox-ios 侧 178 次，差值 281 = 版本号差值 281）→ 每构建一次 +1，需要把 `scripts/configure_noderuntime_link.rb` / `scripts/fix_pushplay_pbxproj.py` 改成幂等并收敛为 1 条。
3. **`build-ipa.yml` 内仍有两处往本仓库建 Release**（`LXML_TAG` / `PYTHON_TAG`，是构建用 lxml/python 依赖产物，非 App 发布包）→ 是否一并收口到分发仓库待定。
4. `docs/ui_baseline/` 约 74.3 MB 参考截图 → 建议转 Git LFS 或压 webp。
5. 待办（需对应账号操作）：删除 `vbox-Ai/app-1`（`vbox-Ai` 账号）、归档 `q2787244398/vboxapp`、归档 `q2787244398/app`（`q2787244398` 账号）。
