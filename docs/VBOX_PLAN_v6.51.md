# vbox 项目全面分析与 Flutter 多端重构方案（**v6 定稿版** · AI 全量开发）

> 基于仓库 `https://github.com/q2787244398/app` commit `1f95d10` (2026-09-29)
> 与远程源仓库 `https://github.com/vbox-Ai/api` main 分支 (2026-09-29) 的完整代码审查
>
> **v3 变更**：确认 iOS 采用方案 A4（契约共享，零改造）；Android TV 同一 APK 双形态；
> ~~TV 最低 Android 5.0 (API 21)~~（已被 D12 覆盖为 API 24）；三端全平台并行；新增第 0 阶段契约层产物。
>
> **v4 定稿变更（重大）**：**全部代码由 AI 编写，人力只做测试**（D8）。
> 关键路径由「插件层编码」改为「人测验证」（D9）；验收改为「自动化测试 + conformance 自证」（D10）；
> 工期重估为 8-12 周（乐观）/ **11-16 周（保守，含 D12 定稿后省 3 周）**；新增第 E 章 AI 全量开发执行计划与 Bug 反馈闭环。
>
> **v4 补充**：确认**全部分发走侧载，不提交任何应用商店**（D11）；新增第 V 章 Android TV 版本分布调研；
> 新增第 S 章侧载分发方案。
>
> **D13 已确认**：每阶段完成后必须**先做遗漏检查**（六类扫描），通过后才能进入下一阶段（见 E.10b）。
>
> **D14/D15/D16 已确认**：**`q2787244398/vboxapp` 为项目唯一开发仓库**（含 iOS + Flutter 三端）；
> **每阶段完成后推送**；源仓库 **`q2787244398/app` 冻结归档**（仅历史备份，改动不回流）。
> 迁移已于 2026-09-29 完成（迁入时全仓 **481 项**；其中 `vbox/` 主工程 **274 项**），Commit `bef4e9e`。
>
> **v5 变更**：**文档合并**——原 `PROGRESS.md`、`PROJECT_LAYOUT.md`、
> 附录 C 三份附属文档**全部并入本方案**（附录 A / B / C），全项目**仅此一份文档**；
> 新增 P.1–P.11 实际开发进度与核查章节；conformance runner 交付（45/45）；
> 新增文档漂移守护脚本；E.10b 不达标项 12 → 9。
>
> **v6 定稿变更**：**全量体检入库**（新增 **P.13**：15 项问题、1 项高危缺陷修复、6 项待办）；
> 第 1 轮进度 65% → **70%**；交付**核心层**（`lib/core/` 21 文件）、**用例层与远程数据源**
> （`lib/domain` 24 + `lib/data` 18 文件）；单测 **143 用例**（CI 全绿：`analyze` 0 issues ·
> 10 个校验脚本 · conformance 45/45）；修复**高危**缺陷（`.version` 被本地旧值回推，导致 CI 版本号回退）；
> 本文件名随修订版本递增（**D25**）：`VBOX_PLAN_v5.md` → `VBOX_PLAN_v6.md`（v6 系列首版，现已废弃）
> → `VBOX_PLAN_v6.9.md` → `VBOX_PLAN_v6.10.md` → `VBOX_PLAN_v6.11.md` → `VBOX_PLAN_v6.12.md` → `VBOX_PLAN_v6.13.md` → `VBOX_PLAN_v6.14.md` → `VBOX_PLAN_v6.15.md` → `VBOX_PLAN_v6.16.md` → `VBOX_PLAN_v6.17.md` → `VBOX_PLAN_v6.18.md` → `VBOX_PLAN_v6.19.md` → `VBOX_PLAN_v6.20.md` → `VBOX_PLAN_v6.21.md` → `VBOX_PLAN_v6.22.md` → `VBOX_PLAN_v6.23.md` → `VBOX_PLAN_v6.24.md` → `VBOX_PLAN_v6.25.md` → `VBOX_PLAN_v6.26.md` → `VBOX_PLAN_v6.27.md` → `VBOX_PLAN_v6.28.md` → `VBOX_PLAN_v6.29.md` → `VBOX_PLAN_v6.30.md` → `VBOX_PLAN_v6.31.md` → `VBOX_PLAN_v6.32.md` → `VBOX_PLAN_v6.33.md` → `VBOX_PLAN_v6.34.md` → `VBOX_PLAN_v6.35.md` → `VBOX_PLAN_v6.36.md` → `VBOX_PLAN_v6.37.md` → `VBOX_PLAN_v6.38.md` → `VBOX_PLAN_v6.39.md` → `VBOX_PLAN_v6.40.md` → `VBOX_PLAN_v6.41.md` → `VBOX_PLAN_v6.42.md` → `VBOX_PLAN_v6.43.md` → `VBOX_PLAN_v6.44.md` → `VBOX_PLAN_v6.45.md` → `VBOX_PLAN_v6.46.md` → `VBOX_PLAN_v6.47.md` → `VBOX_PLAN_v6.48.md` → `VBOX_PLAN_v6.49.md` → **`VBOX_PLAN_v6.50.md`**（当前版）。
>
> **v6.2 变更**：**三轮独立复核（新增 P.15）** —— 独立实测推翻 v6.1「守卫 0 漂移」结论，
> 又发现 **12 项**遗漏并全部处置或登记：① 堵住文档守卫的**表格 / 加粗 / 合计**数值逃逸
> （§C.3 曾以 `| **合计** | **57** |` 长期绕过）；② §C.3 按契约 v1.2 实况重写；③ 文件数 / 脚本数
> 逐处对齐 `git ls-files` 实测；④ 形态判定 §2.4 ↔ §T.1 ↔ 实现 三处口径统一（实现标注为**占位**）；
> ⑤ 清除 `freezed` 残留、修正 `TODO(D21)` 决策号语义碰撞；⑥ 守卫新增 **Dart 源码**失效引用扫描；
> ⑦ README / CI 注释对齐多端现状。
>
> **v6.3 变更**：**契约 D19 闭环** —— 消除 `prefs_keys_v1.json` 键对象异构：为前 12 组的
> **53 键**补齐 `storage: userdefaults`，**当时 98/98 键**均显式标注 `storage`（v1.4 已扩为 **99 键**）
> （`userdefaults | keychain | credential_extra`）；`check_contract_sync.py` 新增
> 「3d. storage 完整性 + Dart↔JSON 逐键比对」防回归（经负向测试验证可拦截）。对应 P.15 #11
> （v6.2 登记待办，本轮闭环）。
>
> **v6.4 变更**：**高风险层单测补齐（P.15 #10 闭环）** —— 新增 **7 个测试文件 / 103 用例**，
> 覆盖此前**零 Dart 单测**的高风险层：`lib/contract`（98 键镜像 / 9 表 DDL）、`lib/data/models`（9 模型）、
> `lib/data/datasources/local`（database / prefs / **backup**）、`lib/presentation/ui_mode`。
> 单测总数 **143 → 246**，`flutter analyze` **0 issues**，离线守卫 10 脚本 + conformance 45/45 全绿。
> 同轮新增 **P.16 深度遗漏复核**（7 项新发现，含 1 项 🔴 敏感键迁移读取丢值）。
>
> **v6.5 变更**：**本机实测复核 + 覆盖率首次测量（部分闭环 P.16 #5 / P.13 §4-3）** ——
> 本轮在本机（`/opt/flutter`，Flutter **3.47.5**，非 CI）**独立复现** v6.4 全部声明：
> `flutter analyze` **0 issues**、`flutter test` **246 用例全通过**、守卫 **10/10** + conformance **45/45**。
> 首次执行 `flutter test --coverage`：**触达文件口径 83.4%**（1240/1487 行 · 41 文件），
> 但 **69 个 lib 文件中 28 个零触达**（含 `lib/domain/entities/spider/` 整层 789 行、`lib/core/network/network_info.dart`、`lib/app.dart`）
> → **整体口径仍 < 70%，E.10b 门禁 ⑤ 由「不可判」转为「明确不达标」**。
> 新增 **P.17 五轮（本地实测）遗漏复核**（8 项：2 🔴 / 5 🟡 / 1 🟢）；`.gitignore` 补 `coverage/`。
> 门禁项未变，**第 1 轮仍不得标记完成**。
>
> **v6.6 变更**：**收口批次 + 覆盖率门禁做实（闭环 P.17 #1 / #2 / #3 / #4）** ——
> ① **Spider 实体层单测补齐**（P.17 #2 唯一 🔴 风险项闭环）：新增 `test/domain/entities/spider/`
> **5 文件 / 98 用例**（`engine_type` / `http_bridge` / `site_config` / `spider_engine` / `spider_models`），
> 该层 789 行由 **0% 触达 → 5/5 文件全部触达**；
> ② 单测总数 **246 → 344**（测试文件 **19 → 24**），`flutter analyze` **0 issues**；
> ③ 覆盖率复测：触达口径 **83.4% → 85.6%**（1479/1727 行），**零触达文件 28 → 23**，
> **全 lib 整体口径 ≈ 70.6%（保守下界）→ E.10b 门禁 ⑤「明确不达标」转为「达标（临界）」**；
> ④ 新增校验脚本 `check_coverage.py`（**历史**：序号 10 → 11）：按**全 lib 行数口径**重算并硬门槛 70%，
> 堵住 P.17 #1「lcov 只算触达文件」的口径陷阱；⑤ `flutter-check.yml` 增 `flutter test --coverage`
> + 覆盖率门槛步骤（P.17 #4：CI 从此可判）；⑥ `pubspec.lock` 入库（P.17 #6）。
> 新增 **P.18 六轮（收口）复核**。**注意**：整体口径为启发式**保守下界**（零触达文件按非空非注释行估行），
> 真实值更高；且 23 个零触达文件仍在，**收口不等于第 1 轮完成**。
>
> **v6.7 变更**：**仓储实现批次（闭环 P.13 §4-1 / §5-1，即 P.18 结论所指「第 1 轮最后功能缺口」）** ——
> ① 新增 `lib/data/repositories/` **四个仓储实现 + barrel**（favorite / history / subscription / remote_source），
> 绑定 `DatabaseManager` / `PrefsManager`，统一返回 `Result`；② `lib/app.dart` 完成组装并注入用例层（`MultiProvider`）；
> ③ 新增 `test/data/repositories/` **4 文件**：单测 **344 → 365**、测试文件 **24 → 28**、lib 文件 **69 → 74**；
> 覆盖率触达 **85.6% → 86.4%**、全 lib 整体 **≈70.6% → 71.1%（门槛达标）**，零触达 **23 → 24**
> （新增 barrel `repositories.dart` 未被触达）；④ **实测揪出并修复契约漂移**（P.19 #1）——`subscription` 的
> 友好判重键原写成 `(dyname, dyurl)`，与 DDL `dyurl UNIQUE` 不符，同址异名会绕过前置判重直撞 DB 约束；
> 已统一为 `findByUrl` 并补回归用例；⑤ 新增 **P.19 七轮复核**（3 项：2 🟡 / 1 🟢，其中 2 项本轮已修）。
> `flutter analyze` 0 issues · 11 守卫脚本 + conformance 45/45 全绿。
>
> **v6.8 变更**：**文档版本治理固化** —— 新增决策 **D24**：每次修改本方案文档**必须先递增修订版本号**
> （v6.x → v6.x+1）**再交付 / 推送**；递增须同步 ① 顶部「本版变更」块、② 版本历史表「（现行）」行、
> ③ 受影响的计数与口径引用。同时**修正一处历史遗留漂移**：v6.6 变更块的「（本版）」标记未随 v6.7 交付移除，
> 导致同一标记重复出现两次（v6.6 / v6.7），现予清除（v6.8 为该标记唯一持有者）。
> 本版**不含代码 / 契约改动**，故各项事实计数（74 lib / 28 测试文件 / 365 用例 / 11 脚本 / conformance 45/45 /
> 覆盖率 71.1%）**全部不变**。
>
> **v6.9 变更**：**文档文件名版本化（新增 D25）+ 守卫加固** ——
> ① 主方案文档**重命名** `VBOX_PLAN_v6.md` → **`VBOX_PLAN_v6.9.md`**：文件名版本须与文档修订版本、
> 顶部「本版变更」块**三处一致**（D25）；全部引用同步更新（`README.md`、`lib/app.dart`、
> `lib/core/**` 3 处注释、`flutter-check.yml`、守卫脚本），并把**旧文件名纳入 `DEAD_DOCS`** 防回流；
> ② `check_docs_consistency.py` 新增**规则 6**（文件名 ↔ 版本历史「（现行）」行 ↔ 顶部「本版变更」块 三处版本一致）
> 与**规则 7**（决策编号**唯一性** + 全文 `D<编号>` 引用**无悬空**）；
> ③ 修正一处**决策号误引**：末章「唯一现行文档（D17–D20）」与实际 D17–D20
> （契约键范围 / 目录结构 / storage / 阶段完成判定）无关，实为 **v5 文档合并结论**，已改注（P.20）；
> ④ 本版**无代码 / 契约改动**（仅注释级引用更新），各项事实计数不变。
>
> **v6.10 变更**：**清账批次（文档漂移归零 + 守卫加固 + 代码小修）** ——
> ① **修复守卫结构性漏洞**：主方案「版本历史」块的 `<!-- docs-guard:history -->` **缺闭合标记**，
> 致其后 **L104–L3158 整段**（含 §C.3、§2.x、E.10b、P.1–P.9）长期被判为历史区，**数值 / 失效路径
> 规则整体静默失效**；补闭合标记后当场再抓出 **2 处陈旧键数**（`57` / `44`）与 **1 处旧文件名引用**，均已修正；
> ② 守卫新增**规则 8**（`pubspec.yaml` ↔ `AppInfo.version` / `buildNumber` 一致）与**规则 9**
> （目录声明须可验证：`git` 不跟踪无文件的目录，故该类断言一律失败）；并从历史标记中移除过泛的
> 「遗漏 / 冗余」（曾让清单行凭「无遗漏」自我豁免）；
> ③ **代码小修**：`AppInfo.version` / `buildNumber` 由 `1.0.0` / `1` 对齐 `pubspec.yaml` 的 `3.1621.0+1621`；
> `pubspec.yaml` 移除**零引用**依赖 `dio` / `collection`；
> ④ **修正多处目录 / 路径漂移**：`data/repositories`（v6.7 已交付，文档曾误标未实现）、
> `platform/*` 与 `presentation/{phone,tv,desktop,…}`（实为**未创建**）、`android-min-sdk21-compat.md`
> （实际 `contract/docs/android-compat.md`）、`vbox_flutter/`、`flutter/`、`KNOWN_GAPS` 引用、`app.dart` 行号；
> ⑤ 新增 **D26**（守卫结构性漏洞须闭环）与 **P.21 本轮清账复核**；旧文件名 `VBOX_PLAN_v6.9.md` 入 `DEAD_DOCS`。
>
> **v6.11 变更**：**平台壳批次（三端编译门禁解锁）** ——
> ① **交付 Flutter 三端平台壳** `android/` / `macos/` / `windows/`（`flutter create` 官方模板，共 **66 文件**：`android/` 20 · `macos/` 28 · `windows/` 18）；
> 落地方式**非侵入**：在临时目录生成后**仅拷贝平台目录 + `.metadata`**，不改动 `lib/` / `test/` / `pubspec.yaml`；
> ② **标识对齐**：Android `namespace` / `applicationId` 与 macOS `PRODUCT_BUNDLE_IDENTIFIER` 统一为
> **`com.vbox.player`**（与 §A21.3 一致；`MainActivity.kt` 同步迁至 `com/vbox/player/`）；`minSdk` **显式锁 24**（D12，
> 避免随 `flutter.minSdkVersion` 隐式漂移）；
> ③ `flutter-check.yml` 新增 **build-android / build-macos / build-windows** 三个 job
> （`flutter build {apk,macos,windows} --debug`），门禁 E.10b ③/⑤「三端编译」由**无平台壳、无 build job**
> 转为**已具备三端编译通道（待 CI 首跑确认）**；触发路径补 `android/**` / `macos/**` / `windows/**`；
> ④ 新增 **D27**（平台壳与包名基线）与 **P.22 十轮复核**；文档更名 `VBOX_PLAN_v6.10.md` → **`VBOX_PLAN_v6.11.md`**（D25）；
> ⑤ 本版**未改动 `lib/` / 契约 / 测试**，各项事实计数不变（74 lib 文件 / 28 测试文件 / 365 用例）。
>
> **v6.12 变更**：**CI 首跑验证（门禁 ③/⑤ 由「待确认」转「✅ 已通过」）** ——
> ① 平台壳批次推送后触发 **Flutter Check**（run `36600564607`，commit `f59d04e`），**5 个 job 全部 success**：
> `contract-checks` · `flutter-analyze`（含覆盖率门槛）· `build-android` · `build-macos` · `build-windows`；
> ② E.10b 门禁 **③/⑤「三端编译通过」由「已具备编译通道（待 CI 首跑确认）」升级为「✅ 已通过」**，
> 全文相应表述同步（P.3 / P.13 / P.22 / 附录 A）；
> ③ 顺带修正 **P.14** 遗留的一处状态漂移（`pubspec.lock` 记为「⬜ 待办」，实为 v6.6 已入库）；
> ④ **无代码 / 契约 / 平台壳改动**，各项事实计数不变（74 lib / 28 测试 / 365 用例 / 11 脚本 / 66 平台壳文件）；
> 文档更名 `VBOX_PLAN_v6.11.md` → **`VBOX_PLAN_v6.12.md`**（D25）。
>
> **v6.13 变更**：**P0 清障批次（闭环 P.13 §4 #4 / #5 / #6 与 P.16 #1）** ——
> ① **启用 `analysis_options.yaml`**（`include: package:flutter_lints/flutter.yaml`，排除平台壳与 `build/`），
> `flutter_lints` 由「已声明但零生效」转为**真正门禁**；`dart fix --apply` 清掉 **79 条** lint
> （73 `prefer_const_constructors` / 5 `use_super_parameters` / 1 `prefer_const_declarations` /
> 1 `prefer_iterable_wheretype`），并手改 **1 条** `unrelated_type_equality_checks` → `flutter analyze` **0 issues**；
> ② **消除 DB 路径双真相源**（P.13 §4 #4）：`database_manager.dart` 不再用 sqflite `getDatabasesPath()`，
> 统一取核心层 `StoragePaths.databaseFile`；`DatabaseManager.dbFileName` 改为引用 `DbConstants.fileName`（去第二真相源）；
> ③ **`prefs_manager` 接入核心层抽象**（P.13 §4 #5）：新增数据层适配器
> `lib/data/datasources/local/secure_store_adapter.dart`（`SecureStore` 接口的 `flutter_secure_storage` 实现），
> `PrefsManager` 改依赖 `SecureStore` 抽象、**不再直接导入插件**；`check_prefs_manager.py` 规则 3 同步升级为
> 「须经 `SecureStore` 抽象且不得 `import package:flutter_secure_storage`」；
> ④ **敏感键回退读取**（P.16 #1，唯一 🔴）：`PrefsManager.get` 安全分支在安全存储为空时**回退读 SharedPreferences**，
> 命中即**迁移**进安全存储并清除明文 —— 修复 iOS 迁移后 5 个敏感键首读丢值；
> ⑤ 计数变化：lib **74 → 75**（+adapter）、测试文件 **28 → 29**（+3 adapter 直测）、单测 **365 → 371**、
> 触达口径 **86.4% → 86.5%**，全 lib 整体 **71.1%（不变，达标）**、零触达仍 **24/75**；新增 **P.23 清障批次复核**；
> 文档更名 `VBOX_PLAN_v6.12.md` → **`VBOX_PLAN_v6.13.md`**（D25）。
>
> **v6.14 变更**：**P0 前置收口批次（闭环 P.16 #2 与 P.23 §4 #2）** ——
> ① **B1 普通分支读取防崩溃**（P.16 #2 闭环）：`PrefsManager.get` 普通键分支捕获历史类型不符抛出的 `TypeError`，
> **静默回退契约默认值**（此前首读即崩）；对应单测由「断言抛 TypeError」改写为「断言回退默认值」；
> ② **应用名大小写裁定**（P.23 §4 #2 闭环）：三端平台壳实际已统一为小写 `vbox`，**裁定维持小写**，
> `app.dart` 的 `title` / `AppBar` 对齐小写 `vbox`（此前与平台壳不一致）；
> ③ **登记（不动代码）**：CmsV10Datasource 裁定「实现但未接线，暂接入待 UI 批次决定」、
> 云盘凭据敏感标注（P.16 #3 / #4）裁定**维持现状**（明文），登记待 UI 批次复核；
> ④ 修正 **P.13 §4 #13** 过期登记：`file_store` 实已被 `remote_source_repository_impl` 接线（清单缓存），移出零引用清单；
> ⑤ 计数不变：lib **75**、测试文件 **29**、单测 **371**、零触达 **24/75**、全 lib 整体 **71.1%**；新增 **P.24 前置收口复核**；
> 文档更名 `VBOX_PLAN_v6.13.md` → **`VBOX_PLAN_v6.14.md`**（D25）。
>
> **v6.15 变更**：**G-01 phone 形态书架交付（第 1 轮 UI 首块）** ——
> ① 新增 `lib/presentation/phone/home_shelf_page.dart`：**收藏 / 历史双 Tab**，状态接入**直连 UseCase**
> （D21 轻量路线），覆盖空态 / 错误重试 / 移除 / 清空确认，条目展示来源 · 相对时间 · 集数 · 进度条；
> ② `app.dart` 形态路由按 `UiMode` 分发：**phone → HomeShelfPage**，desktop / tv 保持占位（渐进交付，随各形态批次）；
> ③ 新增 widget 测试 `test/presentation/phone/home_shelf_page_test.dart`（**7 用例**，注入内存仓储 fakes 走真用例链路）；
> ④ 计数变化：lib **75 → 76**、测试文件 **29 → 30**、单测 **371 → 378**、触达口径 **86.5% → 86.3%**、
> 全 lib 整体 **71.1% → 71.8%**、零触达 **24/75 → 24/76**（新增文件有测试触达）；
> ⑤ 门禁（E.10b）：G-01 **部分解除**（phone 书架块交付，TV / desktop 形态与详情·播放链路仍待）；
> 新增 **P.25 书架复核**；文档更名 `VBOX_PLAN_v6.14.md` → **`VBOX_PLAN_v6.15.md`**（D25）。
>
> **v6.16 变更**：**G-01 phone 远程源列表交付（第 1 轮 UI 第二块）** ——
> ① 新增 `lib/presentation/phone/remote_source_page.dart`：**清单状态卡**（对齐 iOS `LoadState`：
> idle / loadedCache / loadedRemote / failed + 强制刷新）+ **订阅列表**（添加对话框、重复地址拒绝、
> 单条删除、空态、错误重试）；书架 AppBar 新增「远程源」入口（push 跳转）；
> ② 新增 widget 测试 `test/presentation/phone/remote_source_page_test.dart`（**8 用例**）；
> ③ 计数变化：lib **76 → 77**、测试文件 **30 → 31**、单测 **378 → 386**、触达口径 **86.3% → 87.0%**、
> 全 lib 整体 **71.8% → 73.1%**、零触达 **24/76 → 24/77**（新增文件有测试触达）；
> ④ 门禁（E.10b）：G-01 **继续解除**（phone 书架 + 远程源列表交付，desktop / TV 与详情·播放链路仍待）；
> 新增 **P.26 远程源复核**；文档更名 `VBOX_PLAN_v6.15.md` → **`VBOX_PLAN_v6.16.md`**（D25）。
>
> **v6.17 变更**：**G-01 desktop 形态交付（第 1 轮 UI 第三块）+ 三形态共享视图抽取** ——
> ① 新增 `lib/presentation/widgets/library_views.dart`：从书架页抽取 **FavoritesView / HistoryView** 为
> 三形态共享组件（直连 UseCase），phone 壳与 desktop 复用同一套列表逻辑；
> ② 新增 `lib/presentation/desktop/desktop_home_page.dart`：**NavigationRail 宽屏布局**（书架 / 远程源切换），
> 远程源直接内嵌 `RemoteSourcePage`（复用）；`app.dart`：`UiMode.desktop → DesktopHomePage`（占位解除）；
> ③ 新增 widget 测试 `test/presentation/desktop/desktop_home_page_test.dart`（**5 用例**）；
> ④ 计数变化：lib **77 → 79**（+library_views / +desktop_home_page）、测试文件 **31 → 32**、单测 **386 → 391**、
> 触达口径 **87.0% → 87.1%**、全 lib 整体 **73.1% → 73.2%**、零触达 **24/77 → 24/79**（新增文件有测试触达）；
> ⑤ 门禁（E.10b）：G-01 **继续解除**（phone 书架 + 远程源 + desktop 已交付，仅余 TV 形态与详情·播放链路）；
> 新增 **P.27 desktop 复核**；文档更名 `VBOX_PLAN_v6.16.md` → **`VBOX_PLAN_v6.17.md`**（D25）。
>
> **v6.18 变更**：**G-01 tv 形态交付（第 1 轮 UI 收官）** ——
> ① 新增 `lib/presentation/tv/tv_home_page.dart`：**T.7 焦点规范**（`FocusTraversalGroup` +
> TabBar autofocus）+ 顶部三 Tab（收藏 / 历史 / 远程源）导航，复用三形态共享视图；
> ② `app.dart`：`UiMode.tv → TvHomePage`（占位解除），**三形态占位全部解除**；
> ③ 新增 widget 测试 `test/presentation/tv/tv_home_page_test.dart`（**5 用例**：三 Tab 切换 /
> 书架展示 / T.7 焦点结构断言）；
> ④ 计数变化：lib **79 → 80**、测试文件 **32 → 33**、单测 **391 → 396**、触达口径 **87.1% → 87.2%**、
> 全 lib 整体 **73.2% → 73.5%**、零触达 **24/79 → 24/80**（新增文件有测试触达）；
> ⑤ 门禁（E.10b）：**G-01 UI 三形态解除（phone + desktop + tv 均已交付）**；TV D-pad 真机行为归 **G-10**（人工验收）；
> 新增 **P.28 tv 形态复核**；文档更名 `VBOX_PLAN_v6.17.md` → **`VBOX_PLAN_v6.18.md`**（D25）。
>
> **v6.19 变更**：**G-03 可行性评估登记（不改码）** ——
> ① 完成 **5 引擎 × Flutter 三端可行性矩阵**评估（详见 P.29）：**Node/NodeLX 桥（HTTP 到本地端口）与 Python 桥（子进程 stdio ABI）为纯 Dart 可交付**；QuickJS 需 FFI 原生绑定；JSC 三端不可用（iOS 原生保留，Flutter 以 QuickJS 顶替）；
> ② 三个关键判断：ABI（§4.5）已把引擎差异收敛到适配层；QuickJS 原生绑定与 Node/Python **运行时分发**需先行决策（对应 E1 工期翻倍风险）；
> ③ 推荐路线：**G-03-A**（引擎工厂 + NodeBridge + PythonBridge + ABI conformance，纯 Dart 可验）→ **G-03-B**（QuickJS FFI + 运行时分发方案，待决策）；
> ④ 本轮**不改码**（纯登记），计数不变（80 / 33 / 396 / 73.5% / 24/80）；
> 新增 **P.29 G-03 评估登记**；文档更名 `VBOX_PLAN_v6.18.md` → **`VBOX_PLAN_v6.19.md`**（D25）。
>
> **v6.20 变更**：**G-02 平台插件层可行性评估登记（含播放器插件）+ 门禁编号纠偏（不改码）** ——
> ① 完成 **G-02 × 三端平台壳**评估（详见 P.30）：**Android 播放器插件（Media3 + libVLC）为纯 Gradle 依赖
> （零 NDK，libVLC aar 自带原生库）**，CI build-android 可直接编译验证；macOS **AVPlayer 零原生依赖**可交付，
> libmpv 回退需 dylib 分发；Windows libmpv 需 dll 分发（最重）；
> ② 播放器回退路径（E.10b ④）三端齐备（A21.5 已设计 selectBackend：Android Media3→libVLC、macOS AVPlayer→libmpv、Windows libmpv）；
> ③ **门禁编号纠偏**：修正 P.28 / P.29 误记 —— **G-06 = iOS 参照实现（已✅）、G-07 = 编译环境（已✅），均非播放器 / 三端对齐**；
> 播放器插件属 **G-02**（PlayerPlugin.kt / .swift / .cpp）；E.10b 真实余项 = **G-02 / G-03 / G-05（零触达收尾）/ G-09 / G-10**；
> ④ 推荐路线：**G-02-A**（Dart PlayerController 抽象 + 平台通道桥 + Android Gradle 接线，CI 编译可验）→
> **G-02-B**（macOS AVPlayer 接线 + Windows/macOS libmpv 二进制分发决策）；
> ⑤ 本轮**不改码**（纯登记），计数不变（80 / 33 / 396 / 73.5% / 24/80）；
> 新增 **P.30 G-02 评估登记**；文档更名 `VBOX_PLAN_v6.19.md` → **`VBOX_PLAN_v6.20.md`**（D25）。
>
> **v6.21 变更**：**G-03-A 桥接协议层交付（G-03 从「未开始」推进到「桥接协议层交付」）** ——
> ① 交付 `lib/platform/spider/` **6 文件**（ABI 编解码 `spider_abi.dart` / Node·NodeLX HTTP 桥 `node_bridge_engine.dart` /
> Node 客户端 `node_http_client.dart` / Python 子进程桥 `python_bridge_engine.dart` / 引擎工厂 `spider_engine_factory.dart` / barrel `spider.dart`），
> 引擎差异收敛到适配层（契约 §4.5），Node/NodeLX/Python 三引擎走 ABI 统一编解码；
> ② 新增 **4 个测试文件 / 27 用例**（ABI 编解码 7 / Node 桥 7 / Python 桥 8（真实 python3 子进程）/ 引擎工厂 5）；
> ③ 本机全量校验：`flutter analyze` **0 issues**、`flutter test` **423 用例全通过**、conformance **45/45**、
> 11 守卫脚本全绿（含覆盖率：触达口径 **86.9%**、全 lib 整体 **74.0%（达标）**、零触达 **25/86**）；
> ④ 计数变化：lib **80 → 86**、测试文件 **33 → 37**、单测 **396 → 423**、整体覆盖 **73.5% → 74.0%**、零触达 **24/80 → 25/86**（新增文件均有测试触达）；
> ⑤ 门禁（E.10b）：**G-03 部分解除** —— G-03-A（桥接协议层：Node/NodeLX/Python + 引擎工厂 + ABI conformance）**交付**；
> G-03-B（QuickJS FFI + 运行时分发）**待决策**；
> 新增 **P.31 G-03-A 交付复核**；文档更名 `VBOX_PLAN_v6.20.md` → **`VBOX_PLAN_v6.21.md`**（D25）。
>
> **v6.41 变更**：**批次 F 第三段 —— F-02 登录模式收官（网页兜底 + Node 账号）+ F-03 Node 凭据同步** ——
> ① **F-02 余项（领域 + 表现）**：新增网页兜底领域模型 `CloudDriveWebLogin`（官方登录页地址逐档对齐 iOS 各 `*LoginHelper`：UC/夸克/百度/115/123/139/189/迅雷；`credentialHint` 分 Cookie / Cookie+Token 两档）· 网页兜底 Sheet `CloudDriveWebLoginSheet`（`url_launcher` 拉起系统浏览器 + 复制链接 + 多行 Token/Cookie 粘贴 + 落安全存储 + 成功态）· Node 账号 Sheet `CloudDriveAccountLoginSheet`（账号 / 密码表单 + 状态卡）· 控制器补 `loginWithAccount` · `CloudDriveLoginMode.webFallback` 由轻提示改真实链路 · `auth_center.dart` 登录 Sheet 关闭后自动 `load()` 刷新凭据卡态；
> ② **F-03（领域 + 数据）**：新增 `lib/domain/entities/cloud/node_credential_sync.dart`（11 家 Node 托管盘字段映射 `nodeManagedProviders` + 7 家拉取映射 `nodePullableProviders` + `cookie`/`extra:<key>` 槽位读写 + `NodeCredentialSyncSummary`，逐档对齐 iOS `NodeCredentialSyncService.managedProviders` / `pullable`）· 新增 `lib/data/datasources/remote/node_credential_sync_service.dart`（`NodeCredentialApiClient` 接缝 + `UnavailableNodeCredentialApiClient` 缺省 + `LocalNodeCredentialApiClient`（`127.0.0.1:58080`，3 次退避重试，校验 `code==0`）+ `NodeCredentialSyncService`：`push` / `pull` / `deleteNodeCredential` / `syncNow`，结果落契约安全存储 `cloud_drive_credentials_v1`）；
> ③ **测试**：新增 2 个测试文件 / 25 用例（领域模型 12 + 数据服务 13，替身网关驱动 push/pull/级联删除）；
> ④ **自检**：`flutter analyze` 0 issues · `flutter test` **1285 用例全通过**（1260 → 1285）· **13 个守卫脚本全绿**；
> ⑤ **文档**：文档更名 `VBOX_PLAN_v6.40.md` → **`VBOX_PLAN_v6.41.md`**（D25），任务级 WBS 更名 `v1.15` → **`v1.16`**，开发方案更名 `v2.11` → **`v2.12`**。
>
> **v6.51 变更（本版）**：**文档口径修正 —— 明确「本机不安装 Flutter SDK」** ——
> ① **背景**：Trae 沙箱为**按会话创建**的 Kata 微虚拟机，工作区**不跨会话保留**；历史文档中「本沙箱已安装 Flutter 3.47.5」
> /「SDK 位于 `/workspace/.flutter-sdk/flutter`（**持久目录**）」等表述与事实不符，会诱导后续会话**每次重复下载安装数 GB**；
> ② **口径统一**：本机**不安装** Flutter SDK —— Dart 侧的编译 / 静态分析 / 单测 / 构建**一律由 CI**
> （`flutter-check.yml`，Flutter 3.47.5）承担；本机仅跑纯 Python 守卫与 conformance runner；
> ③ **落点**：本方案 **P.7**（补「现行口径」块）+ **A.4**（环境约束摘要改口径）· `README.md`（新增「本机无需安装 Flutter SDK」）·
> `docs/后期开发方案_v1.1~v1.4.md`（环境声明去掉「持久目录」）· `docs/第1轮核心骨架全面检查报告_v6.32.md` /
> `docs/第2轮细分实施WBS_v1.38.md` / `docs/UI对齐_H_I开工前置_v1.11.md`（补口径指针）；
> ④ **无代码 / 契约 / 计数改动**：lib / 测试 / 用例 / 守卫 / conformance 各项计数不变；
> ⑤ 文档更名 `VBOX_PLAN_v6.50.md` → **`VBOX_PLAN_v6.51.md`**（D25），旧文件名入 `DEAD_DOCS` 防回流。
>
> **v6.50 变更**：**批次 H 续段 —— H-04 福利三重隔离 + 守卫** ——
> ① **领域层**：新增 `lib/domain/entities/welfare/welfare_isolation.dart`（`WelfareIsolationPolicy` 纯静态策略：`normalizeScriptPath`（反斜杠归一 + 剥离 `./`）+ `isAllowedScriptPath`（`contains("sources/welfare-js/") || hasPrefix("welfare-js/")`，逐档对齐 iOS `WelfareSpiderLoader.isAllowedWelfareScriptPath`）+ `isWelfareSpider` / `satisfiesTripleIsolation`（仅 `welfare_spider` 校验三字段，非 Spider 视为合规）+ `violationFor`（三重隔离违规列明字段 / 脚本路径越界提示）/ `violationsForAll`（全量校验））；修改 `lib/domain/entities/welfare/welfare_platform_config.dart`（`WelfarePlatform` 增 `api` + `visibleInNormalSpider` / `visibleInGlobalSearch` / `visibleInHome` 三字段（缺省 false，toJson 显式回写）+ `copyWith`）；
> ② **表现层**：修改 `lib/presentation/welfare/welfare_platform_router.dart`（`welfare_spider` 分支前置 `WelfareIsolationPolicy.violationFor`：违规平台一律进 `WelfareUnsupportedRoute` 并携带原因，杜绝进入普通链路）；
> ③ **守卫**：新增 `scripts/check_welfare_isolation.py`（CI 常驻，6 项：契约 `allOf` 约束 / 领域层实现一致性 / 模型层三字段解析 / 路由接入 / sources 目录越界扫描（`welfare-js/` 扩展名 · `welfare_platforms.json` 逐项隔离校验 · `spider_sources`/`api_sources`/`cloud_sources` 混入福利平台键扫描 · manifest 引用存在性）· 普通 Spider 链路（`lib/platform/spider` + `lib/domain/spider`）不得引用 `sources/welfare-js/`；`--selftest` 负向自测（脚本路径 10 例 + 三重隔离 7 例 + `violationFor` 4 例））；
> ④ **测试**：新增 `test/domain/entities/welfare/welfare_isolation_test.dart`（**17 用例**：路径规范化 / 脚本路径正负 / 三重隔离判定（含非 Spider 合规）/ `violationFor` 组合 / `violationsForAll` 混合配置 / 模型字段解析与 JSON 往返）+ 路由测试增 **2 用例**（三重隔离违规拦截 / 脚本路径越界拦截）；
> ⑤ **自检**：`flutter analyze` **0 issue** · `flutter test` **1634 用例全通过**（1607 → 1634，新增 27）· **14 个契约/一致性 Python 脚本全绿**（新增福利隔离守卫，含 `--selftest` 负向自测；文档一致性 0 漂移）· UI 令牌 / Dart 导入路径守卫通过；
> ⑥ **文档**：文档更名 `VBOX_PLAN_v6.49.md` → **`VBOX_PLAN_v6.50.md`**（D25），任务级 WBS 更名 `v1.25` → **`v1.26`**，开发方案更名 `v2.20` → **`v2.21`**（UI 对齐清单无 UI 变更不升版）；
> ⑦ **交付边界**：三重隔离**策略层 + 运行时拦截 + CI 守卫**三层落地；脚本实际加载 / 引擎执行归 **H-03**（其代码从第一天起受本守卫约束）。
> **批次 H 八项（H-01 ~ H-08）已交付 H-01 / H-02 / H-04 / H-06（首段），余项 H-03 / H-05（记录过滤）/ H-07 / H-08 待续**。
>
> **v6.49 变更**：**批次 H 续段 —— H-02 福利平台路由（5 类 serviceType + 基类抽象）** ——
> ① **领域层**：新增 `lib/domain/entities/welfare/welfare_service_type.dart`（`WelfareServiceType` 枚举：8 已知 case（`ybox_special` / `daily_battle` / `kanliao` / `aidan_video` / `fuli_base` / `remote_cms_v10` / `welfare_spider` / `python_spider`）+ `unknown` 兜底，`fromRaw` 未命中回退 `unknown` **不兜底到其他平台**，对齐 iOS `WelfarePlatformConfig.swift` L268-L284）；修改 `lib/domain/entities/welfare/welfare_platform_config.dart`（`WelfarePlatform` 增 `scriptType` 字段 + `service` / `isJavaScriptSpider` / `primaryHost` 派生 getter）；新增 `lib/domain/services/fuli_base_service.dart`（`FuliContentCategory` 枚举 + `FuliBaseService` 抽象基类：`platformKey` / `platformName` / `defaultHosts` / `currentHost` / `isHostReady` / `contentCategory` / `imageReferer` / `imageSSLBypass` / `reprobe()` / `resetDomain()` + `FuliBaseServiceRegistry` 单例注册表，对齐 iOS `FuliPlatformService.swift`）；
> ② **表现层**：新增 `lib/presentation/welfare/welfare_platform_router.dart`（`WelfareRoute` **密封类族** + `WelfarePlatformRouter.resolve(platform)`：按 `serviceType` 分发到原生专用（`WelfareNativeRoute` × 3 kind）/ `WelfareAidanVideoRoute` / `WelfareFuliBaseRoute`（按 `platformKey` 查注册表，未注册 → 未支持）/ `WelfareRemoteCmsV10Route` / `WelfareWelfareSpiderRoute`（JS）/ `WelfareSpiderHomeRoute`（非 JS）/ `WelfarePythonSpiderRoute` / `WelfareUnsupportedRoute`（`unknown` + 未注册，携带原因））；新增 `lib/presentation/pages/welfare/unsupported_platform_page.dart`（`UnsupportedPlatformPage`：橙警示头 + 平台信息卡 + 排查建议卡，对齐 iOS `UnsupportedPlatformView.swift`，额外展示路由 `reason`）；
> ③ **接线**：修改 `lib/presentation/pages/welfare/welfare_home_page.dart`（平台网格点击经 `WelfarePlatformRouter` 路由：未支持 → `UnsupportedPlatformPage`，其余提示目标页面族）；修改 `lib/presentation/widgets/vbox/vbox_welfare.dart`（`VboxWelfarePlatform` 增可选 `platformKey` 供路由回查）；
> ④ **测试**：新增 `test/presentation/welfare/welfare_platform_router_test.dart`（**10 用例**：`fromRaw` 已知串 / 空未知回退 / `isWelfareSpider`·`isRoutable` 口径 / 原生三类 kind / `aidan_video`·`remote_cms_v10`·`python_spider` / JS 与非 JS Spider 分流（含大小写不敏感）/ `fuli_base` 注册命中与未注册 / `unknown` 两种原因 / 注册表空 key 与注销）；`test/presentation/pages/welfare/welfare_home_page_test.dart` 增 **2 用例**（未支持平台 → 未支持页 / 已支持平台 → 目标页面族提示）；
> ⑤ **自检**：`flutter analyze` **0 issue** · `flutter test` **1618 用例全通过**（1607 → 1618）· 13 个契约/一致性 Python 脚本全绿（含文档一致性 0 漂移）· UI 令牌守卫（R-2/R-3/R-4）通过 · Dart 导入路径守卫通过（433 文件）；
> ⑥ **文档**：文档更名 `VBOX_PLAN_v6.48.md` → **`VBOX_PLAN_v6.49.md`**（D25，并补记 v6.48 内容），任务级 WBS 更名 `v1.24` → **`v1.25`**，开发方案更名 `v2.19` → **`v2.20`**，UI 对齐清单更名 `v1.9` → **`v1.10`**；
> ⑦ **交付边界**：本批交付 `fuli_base` 路由所需的**抽象面**（服务基类 + 注册表 + 路由描述），目标页面（`FuliPlatformMainView` 等）与各原生平台服务实现随「福利原生平台 / H-03 Spider」批次落地。
> **批次 H 八项（H-01 ~ H-08）已交付 H-01 / H-02 / H-06（首段），余项 H-03 / H-04 / H-05 / H-07 / H-08 待续**。
>
> **v6.48 变更**：**批次 H 首段 —— H-01 平台配置加载 + H-06 三栏目 + 平台网格页**（本版补记，v6.48 文件名于交付时已重命名、内容于 v6.49 一并登记） ——
> ① **H-01**：领域 `lib/domain/entities/welfare/welfare_platform_config.dart`（`WelfarePlatformCategory`（video/live/comic）+ `WelfarePlatform` + `WelfarePlatformCategoryMeta` + `WelfarePlatformConfig` 严格 `tryParse`（`schemaVersion=1` / 未知 key 剔除 / 逐项过滤），对齐契约 `welfare_v1.json`）+ 数据源 `lib/data/datasources/remote/welfare_platform_datasource.dart`（manifest → `files.welfarePlatforms` → 平台配置，两级均走 `RemoteSourceStrategy` 代理降级链）+ 本地缓存 `lib/data/datasources/local/welfare_platform_cache.dart` + 控制器 `lib/presentation/welfare/welfare_platform_controller.dart`（缓存先出 → 后台刷新；`fuli_remote_source_enabled` 开关 + 上次成功时间/版本落 Prefs；`platformsIn(category)` 按 `sortOrder` 排序）；
> ② **H-06**：页面 `lib/presentation/pages/welfare/welfare_home_page.dart`（三段栏目 `VboxWelfareTabs` + 4 列平台网格 `VboxWelfarePlatformGrid` + 加载 / 失败 / 空态 + 刷新）+ `welfare_gate_page.dart` 门控接线 + `app.dart` `MultiProvider` 注册；
> ③ **测试**：新增 4 测试文件 / **35 用例**（领域 12 + 数据源 8 + 控制器 10 + 页面 4）+ 金色基线 `welfare_live_portrait`（SSIM **0.819**）；
> ④ **自检**：`flutter analyze` **0 issue** · `flutter test` **1607 用例全通过**（1572 → 1607）· 覆盖率 **78.0% ≥ 70%** · 11 守卫全绿 · conformance **83/83** · 视觉回归门禁 exit 0；
> ⑤ **交付边界**：H-01 平台配置加载全链 + H-06 三栏目/网格页（平台点击 5 类路由归 **H-02**、长按编辑排序归 **H-07**、额外视图待续）。
>
> **v6.47 变更**：**批次 G 首段 —— G-01 音乐（队列 + 迷你播放器）** ——
> ① **领域层**：新增 `lib/domain/entities/music/music.dart`（`MusicPlatform` **五平台枚举**（网易云 / QQ 音乐 / 酷狗 / 酷我 / 咪咕，对齐 iOS `MusicPlatformType`）+ `MusicQueueItem`（队列项：`id` / `name` / `artist` / `coverURL` / `playURL` / `sourceName` / `engineKey` + 扩展 `quality` / `qualityIndex` / `lyric` / `duration` / `albumName` / `availQualities` / `musicPlatform` / `lxMusicInfo` + `fromJson` / `toJson` 容错往返，对齐 iOS `MusicQueueItem`））与 `lib/domain/entities/music/music_queue.dart`（`MusicQueue` 纯逻辑：`setQueue` / `addToQueue`（去重追加）/ `removeFromQueue`（移除当前项 → stop 语义清空）/ `replaceCurrent`（音质切换保留索引与进度）/ `next` / `previous`（进度 > 3s 回本曲开头）/ `current` / `isEmpty` / `isNotEmpty`，逐档对齐 iOS `AudioPlayerManager` 队列逻辑）；
> ② **数据层**：新增 `lib/data/datasources/local/music_queue_store.dart`（`MusicQueueStore`：`load` / `save` / `clear`，落契约键 `music_queue_items`（JSON 数组）+ `music_queue_index`（int）；非法 JSON 容忍为空、越界索引回退 -1）；
> ③ **平台层**：新增 `lib/platform/player/music_player.dart`（`MusicAudioEngine` 引擎抽象（`setURL` / `play` / `pause` / `seek` / `stop` + 状态流）+ `UnavailableMusicAudioEngine` 缺省 + `MusicPlayerController` 队列状态机：`setQueue` / `playAt` / `playNext` / `playPrevious` / `togglePlay` / `seek` / `removeFromQueue` / `replaceCurrent` / `stop` / `restore`，含**自动连播**、**连续失败保护**（引擎异常 → 提示并自动跳下一首）、进度回补与落盘）；
> ④ **表现层**：新增 `lib/presentation/widgets/music/mini_player.dart`（`MiniPlayerBar` 全局迷你浮层（320×60）+ `MiniPlayerCloseButton`：封面 / 歌名 + 进度条 + 播放暂停 + 下一首（单曲禁用），逐档对齐 iOS `MiniPlayerBar`（`MusicPlayerViews.swift:11`）—— **左滑**浮现关闭钮（松手点击关闭 → 停播并清空队列）/ **右滑**折叠为 52×52 胶囊（点击展开）/ 点击主体触发展开回调；宽度动画期间以 `OverflowBox + ClipRect` 裁剪，消除伸缩过渡的 `Row` 溢出）；
> ⑤ **测试**：新增 4 个测试文件 / **54 用例**（领域 + 存储 + 播放器合计 **46**：平台枚举 / 队列项 JSON 往返 / 队列增删改 / 上一首回本曲开头 / 音质替换保留索引 / 持久化 / 越界索引 / 非法 JSON / 状态机 / 自动连播 / 失败保护 / 进度回补 / `restore`；迷你播放器组件 **8**：空队列不渲染 / 渲染与控件 / 单曲禁用下一首 / 播放暂停切换 / 切歌 / 折叠展开 / 左滑关闭清空 / 展开回调）；
> ⑥ **自检**：`flutter analyze` 0 issues · `flutter test` **1527 用例全通过**（1473 → 1527）· 13 个契约/一致性 Python 脚本全绿（含文档一致性 0 漂移）· UI 令牌守卫（R-2/R-3/R-4）通过 · Dart 导入路径守卫通过（401 文件）；
> ⑦ **交付边界**：G-01 首段交付「队列模型 + 播放状态机 + 迷你播放器浮层」；音乐页（歌单广场 / 排行榜 / 搜索）与**全屏播放器**、五平台内容服务（`MusicPlaylistService`）留待 **G-01 续段**；原生音频引擎接线归平台批次（D28 口径）；**G-10 真机验收**归批次 J（D30）。
> **下一批 = 批次 G 续段（G-01 音乐页 / 全屏播放器 → G-02 下载）**。
>
> **v6.46 变更**：**批次 F 收官 —— F-09 PG 自动化 + F-10 批次自检** ——
> ① **领域层**：新增 `lib/domain/entities/cloud/pg_auto.dart`（`PgVodQuality`（五档画质：原画 4K `4kz|auto` / 高清 FHD / 高清 HD / 标清 SD / 流畅 LD + `fromFlags` 前缀解析，对齐 iOS `PgPlayConfigSection` 的 Picker tag）· `PgAutoConfig`（PG 自动化配置，对齐 iOS `AliyunPgConfig` 的 **9 个契约键**：`enabled` / `isVip` / `threadLimit` / `threadNight` / `vodFlags` / `transferDir` / `autoCleanup` / `cleanupDelaySeconds` / `proxyPort` + `defaults` / `copyWith`）· `PgAutoRules`（取值规则：`resolvedVodFlags` 空串回退 `4kz|auto` · `vodQuality` · `is4kz` · `resolvedTransferDir` 空串回退 `vbox_pg_temp` · `isNightWindow`（19:00–23:00）· `currentThreadLimit`（非 VIP 收敛 1；VIP 夜间取 `threadNight`、日间取 `threadLimit`）· `cleanupDelay`（负值收敛 0）· `shouldScheduleCleanup`（启用 + 自动清理同时为真）· `proxyUrl`（`http://127.0.0.1:<port>`，对齐 iOS `aliproxyUrl`））· `PgCredentialMark`（PG 凭据标记：`pg_source=qr_scan` 写读判定，对齐 iOS `AliyunPgConfig.pgSourceKey/pgSourceValue`））；
> ② **数据层**：新增 `lib/data/datasources/local/pg_auto_store.dart`（`PgAutoStore`：`load` / `save` / `reset`，落契约 9 键 `pg_ali_enabled` / `pg_ali_is_vip` / `pg_ali_thread_limit` / `pg_ali_thread_night` / `pg_ali_vod_flags` / `pg_ali_transfer_dir` / `pg_ali_auto_cleanup` / `pg_ali_cleanup_delay` / `pg_ali_proxy_port`（userdefaults 明文），缺省按契约补齐）；
> ③ **表现层**：新增 `lib/presentation/pages/cloud/pg_auto.dart`（`PgAutoPage`：PG 播放路链开关卡 + 播放参数卡（VIP 开关 → 并发线程 / 夜间线程 Stepper（1–64）+ 画质选择）+ 转存目录卡（目录输入 + 自动清理开关 + 清理延迟 Stepper（0–600s，步长 30）+ 代理端口）+ **当前生效卡**（线程 / 画质 / 转存目录 / 清理 / 代理地址实时预览）+ 恢复默认 + 保存，逐档对齐 iOS `AliyunPgConfigView`）；
> ④ **测试**：新增 3 个测试文件 / **29 用例**（领域 17：画质解析 / 取值规则 / 线程档 / 清理规则 / 凭据标记；存储 6：缺省 / 持久化 / 9 键落盘 / reset / 部分补齐 / allKeys 覆盖；页面 6：渲染三块 + 当前生效卡 / VIP Stepper 生效 / 画质切换 / 保存提示 / 夜间线程注入 / 恢复默认）；
> ⑤ **自检（F-10 批次自检）**：`flutter analyze` 0 issues · `flutter test` **1473 用例全通过**（1444 → 1473）· 13 个契约/一致性 Python 脚本全绿 · conformance **83/83** · 文档一致性守卫（规则 1–10）0 漂移；
> ⑥ **文档**：文档更名 `VBOX_PLAN_v6.45.md` → **`VBOX_PLAN_v6.46.md`**（D25），任务级 WBS 更名 `v1.20` → **`v1.21`**，开发方案更名 `v2.16` → **`v2.17`**；
> ⑦ **交付边界**：F-09 交付 PG 自动化配置（领域 + 存储 + 设置 UI）与 9 个契约键接线；阿里云盘 PG 4kz 路链的**播放编排**（线程池实转 + 代理起服）归真机联调（D28 口径），`pan_player.dart` 的 `pgAli` 通道守卫留待后续批次接线。
> **批次 F 十项（F-01 ~ F-10）全部交付**。**下一批 = 批次 G 余项 / 第 2 轮收口**。
>
> **v6.45 变更**：**批次 F 第七段 —— F-08 网盘播放（pan 模式）** ——
> ① **领域层**：新增 `lib/domain/entities/cloud/node_pan.dart`（`NodePanPaths`（`/spider/push/4/detail` + `/spider/push/4/play`）· `NodePanEntry`（base64 播放 ID + 展示名）· `NodePanShare` / `NodePanPlayData`（url / headers / format）· `NodePanErrorKind` 三档 + `NodePanException`（`displayMessage` 逐档对齐 iOS `errorDescription`）· `NodePanRouting`（10 家 Node 托管盘 `managedProviders` + `isNodeManaged`，对齐 iOS `resolvePlayURL` 的 Node 分支）· `NodePanParser`（`vod_play_url` 名`$`id 解析，多播放组 `$$$` 仅取第一主组 + base64 JSON 取名 `decodeName`），逐档对齐 iOS `NodePanResolver.swift`）与 `lib/domain/entities/cloud/cloud_play_item.dart`（`CloudPlayItem`（统一缓存条目 + `cacheKey` / `hasPlayURL` / `isExpiredAt` / `copyWith`（含 `clearPlayURL` / `clearExpiresAt`）/ JSON 往返）· `CloudPlayItemSummary`（总数 / 有效 / 过期 / 占用字节 / 最近更新）· `CloudPlayItemCache` 纯逻辑（键 `provider|sourceKey` · 上限 **260** 按 `updatedAt` 倒序裁剪 · `invalidate`（清 `playURL` / `expiresAt` 并追加原因后缀，键不存在短路）· `clearExpired`（仅目标 provider，无变化原引用返回）· `clear` · `summary`），逐档对齐 iOS `CloudDriveManager.CloudPlayItem` / `cloudPlayItemCacheKey` / `storeUnifiedCloudPlayItem` / `invalidateUnifiedCloudPlayItem` / `clearExpiredUnifiedCloudPlayItems` / `clearUnifiedCloudPlayItems` / `cloudPlayItemSummary`）；
> ② **数据层**：新增 `lib/data/datasources/remote/node_pan_client.dart`（`NodePanTransport` 传输接缝 + `NodePanHttpResponse` + `UnavailableNodePanTransport` 缺省 + `LocalNodePanTransport`（`127.0.0.1:58080`，分享链接清洗去零宽字符，502/503/404 → Node 未就绪）+ `NodePanClient`：`resolveShare` / `resolvePlay` / `_ensureOk` / 相对路径补 base）与 `lib/data/datasources/local/cloud_play_item_cache_store.dart`（契约键 `cloud_play_item_cache_v1`：`load` / `save` / `store`（upsert + 裁剪）· `invalidate`（键不存在不落盘）· `clearExpired` / `clear` / `summary`，非法 JSON / 非数组容忍为空）；
> ③ **平台层**：新增 `lib/platform/player/pan_player.dart`（`PanPlayChannel` 四档路由判定 `nodePan` / `pgAli` / `native` / `unsupported` + `PanPlayException` + `PanPlayer`：`channelFor` · `resolveShare` · `prepare`（解析播放地址并落统一缓存）· `open`（以**显式 `pan` 路由**交 `PlayerController.open`）· `summary` / `invalidate` / `clearExpired` / `clear` · `_guardChannel` 通道守卫）· 修改 `lib/platform/player/player_controller.dart`（`open` 增可选 `route` 显式路由覆盖，为 null 时按 `PlaybackRouteResolver` 推导）· `lib/domain/entities/cloud/cloud.dart` 导出接线；
> ④ **测试**：新增 5 个测试文件 / 51 用例（领域 `cloud_play_item_test` + `node_pan_test`：缓存键 / 裁剪 / 失效 / 过期清理 / 汇总 / `vod_play_url` 解析 / base64 取名 / 路由判定；存储 `cloud_play_item_cache_store_test`：持久化 / 键缺失不写 / 容错；客户端 `node_pan_client_test`：分享清洗 / 条目解析 / 直链 / 相对路径补全 / 各错误档；平台 `pan_player_test`：通道判定 / 守卫报错 / 解析落缓存 / 显式 pan 路由打开 / 汇总与失效）；
> ⑤ **自检**：`flutter analyze` 0 issues · `flutter test` **1444 用例全通过**（1393 → 1444）· 13 个契约/一致性 Python 脚本全绿 · conformance **83/83**；
> ⑥ **文档**：文档更名 `VBOX_PLAN_v6.44.md` → **`VBOX_PLAN_v6.45.md`**（D25），任务级 WBS 更名 `v1.19` → **`v1.20`**，开发方案更名 `v2.15` → **`v2.16`**；
> ⑦ **交付边界**：F-08 交付 Node 托管盘 pan 播放全链路（分享解析 → 播放入口 → 统一缓存 → 显式 pan 路由）；阿里 PG 4kz / 原生盘路链在 `_guardChannel` 明确报错，留待 F-09 / 后续批次接线（D28 口径：Node 常驻系统就绪后真机联调）。
> **下一批 = 批次 F 余项（F-09 PG 自动化 / F-10 批次自检）**。
>
> **v6.44 变更**：**批次 F 第六段 —— F-07 文件列表 / 转存 / 清理队列** ——
> ① **领域层**：新增 `lib/domain/entities/cloud/cloud_drive_files.dart`（`CloudDriveFileEntry`：`fileId`/`name`/`isFolder`/`size`/`parentId`/`updatedAt` + `isVideo` 扩展名判定 + 文件夹优先 `compareTo` + JSON 兼容 `fileId`/`fsId`/`fid` 三键）· `CloudDriveCleanupItem`（去重键 `drive|tokenName|fileId` + `isDue`）· `CloudDriveCleanupQueue` 纯逻辑（`enqueue`：去重 + 空 fileId 忽略 + 上限 300 按 `createdAt` 倒序保留最新；`due` / `groupByDrive`（按 `drive|tokenName` 分组）/ `remove` / `_trim`，逐档对齐 iOS `CloudDriveManager.CleanupQueueItem` 与 `enqueueCleanup` / `flushCleanupQueue`）· `CloudDriveTransferResult`（转存目标目录 + 顶层文件 ID）；
> ② **数据层**：新增 `lib/data/datasources/local/cloud_drive_cleanup_queue_store.dart`（契约键 `cloud_drive_cleanup_queue_v1`：`load` / `save` / `enqueue` / `due` / `removeDue` / `count` / `clear`，非法 JSON / 非数组 / 缺 fileId 容忍为空，默认延迟 180s）；
> ③ **表现层**：新增 `lib/presentation/pages/cloud/files_controller.dart`（`CloudDriveFileLister` 列举接缝 + `UnavailableCloudDriveFileLister` 缺省直报错 + `CloudDriveFilesController`：目录列举 / 文件夹优先排序 / 面包屑 / 进出目录 + `transferAndSchedule` 转存入队 + `cleanupDue` 立即清理）与 `lib/presentation/pages/cloud/files.dart`（`CloudDriveFilesPage`：顶栏刷新 + 面包屑 + 文件 / 文件夹行（文件夹进入、文件转存）+ 清理队列卡「待清理 N 项 / 立即清理」+ `formatFileSize`）；`pages.dart` / `cloud.dart` 导出接线；
> ④ **测试**：新增 3 个测试文件 / 29 用例（领域 14 + 存储 8 + 页面 7）；
> ⑤ **自检**：`flutter analyze` 0 issues · `flutter test` **1393 用例全通过**（1364 → 1393）· 13 个契约/一致性 Python 脚本全绿；
> ⑥ **文档**：文档更名 `VBOX_PLAN_v6.43.md` → **`VBOX_PLAN_v6.44.md`**（D25），任务级 WBS 更名 `v1.18` → **`v1.19`**，开发方案更名 `v2.14` → **`v2.15`**；
> ⑦ **交付边界**：F-07 交付「文件列表 + 转存 + 清理队列」；目录列举器缺省「未接入」直报错，真机联调待 Node 常驻系统就绪（D28 口径）。
> **下一批 = 批次 F 余项（F-08 pan 播放 / F-09 PG 自动化 / F-10 批次自检）**。
>
> **v6.43 变更**：**批次 F 第五段 —— F-05 B站扫码 + 百度专用代理** ——
> ① **领域层**：新增 `lib/domain/entities/cloud/bili_auth.dart`（`BiliAuthStatus` 五态 + `fromWire`（`waiting` + msg「已扫码」合并为 scanned 档）+ `BiliQrStart`（服务端直出 `qrImage` data URL）+ `BiliAuthPaths` 路径常量 + `BiliAuthException`）与 `lib/domain/entities/cloud/baidu_proxy.dart`（`BaiduProxyEndpoints` + `BaiduProxySigner`（HMAC-SHA256：`path+timestamp+nonce+body` 小写 hex）+ `BaiduProxyPlayData` / `BaiduProxyResponse` + `BaiduProxyException`），逐档对齐 iOS `BiliAuthManager.swift` / `BaiduProxyClient.swift`；
> ② **数据层**：新增 `lib/data/datasources/remote/bili_auth_client.dart`（`BiliAuthTransport` 传输接缝 + `UnavailableBiliAuthTransport` + `LocalBiliAuthTransport`（`127.0.0.1:58080`，3 次退避重试）+ `BiliAuthClient`：`startQrLogin` / `pollQrLogin` / `cancelQrLogin` / `saveCookie` / `clearCookie`）与 `lib/data/datasources/remote/baidu_proxy_client.dart`（`BaiduProxyTransport` 接缝 + `HttpBaiduProxyTransport`（原样发送已签名 body）+ `BaiduProxyClient`：`parseShareLink` / `getPlayURL` + `BaiduPcsDeviceId` 稳定设备指纹，落契约敏感键 `baidu_local_pcs_device_id`）；
> ③ **表现层**：新增 `lib/presentation/pages/cloud/node_login_gateway.dart`（`NodeCloudDriveLoginGateway` 覆盖 B 站扫码，成功后调 `NodeCredentialSyncService.saveProfile()` 回收 Cookie；`defaultCloudDriveLoginGateway` 按网盘 / 方式路由工厂），`login_sheet.dart` 三处缺省网关改走该工厂（B 站扫码接入真实链路，其余档回退「未接入」）；
> ④ **测试**：新增 5 个测试文件 / 51 用例（领域 22 + 数据 18 + 表现 11，含 HMAC-SHA256 固定向量**回归锚点**与 PCS 设备指纹持久化）；
> ⑤ **文档**：文档更名 `VBOX_PLAN_v6.42.md` → **`VBOX_PLAN_v6.43.md`**（D25），任务级 WBS 更名 `v1.17` → **`v1.18`**，开发方案更名 `v2.13` → **`v2.14`**；
> ⑥ **交付边界**：F-05 交付「API 契约 + 登录网关接线」，端到端扫码真机联调待 Node 常驻系统就绪后验收（D28 口径）。
> **下一批 = 批次 F 余项（F-07 文件列表 / F-08 pan 播放 / F-09 PG 自动化 / F-10 批次自检）**。
>
> **v6.42 变更**：**批次 F 第四段 —— F-04 阿里 extscreen 加密链路** ——
> ① **领域层**：新增 `lib/domain/entities/cloud/aliyun_extscreen.dart`（`ExtscreenCrypto`：设备指纹参数字典 `akv/apv/b/d/m/mac/n/t/wifiMac` · `h()` 字符变换 · MD5 密钥派生 `generateKey`/`generateKeyWithTimestamp` · AES-256-CBC 加解密（明文按 key 升序紧凑序列化，复用 `MdtvAes`）· SHA-256 签名 `computeSign` · 请求头 `headers` + `ExtscreenException`），逐档对齐 iOS `ExtscreenCrypto.swift`；
> ② **数据层**：新增 `lib/data/datasources/remote/aliyun_extscreen_client.dart`（`ExtscreenTransport` 传输接缝 + `CoreExtscreenTransport`（核心层 `HttpClient`）+ `ExtscreenApiClient`：`getTimestamp` / `getQrcode` / `pollQrcodeStatus` / `getRefreshToken` / `refresh` / `makeCrypto` + `ExtscreenToken`），对齐 iOS `ExtscreenAPIClient.swift`；
> ③ **测试**：新增 2 个测试文件 / 28 用例（加密链路 15：设备指纹 / `h()` / 密钥 / AES 往返 / 签名 / 请求头，含固定输入密钥与签名的**回归锚点**；客户端 13：时间戳 / 二维码 / 轮询 / 换 token / 刷新，替身传输驱动成功与失败分支）；
> ④ **自检**：`flutter analyze` 0 issues · `flutter test` **1313 用例全通过**（1285 → 1313）· **13 个守卫脚本全绿**；
> ⑤ **文档**：文档更名 `VBOX_PLAN_v6.41.md` → **`VBOX_PLAN_v6.42.md`**（D25），任务级 WBS 更名 `v1.16` → **`v1.17`**，开发方案更名 `v2.12` → **`v2.13`**。
> ⑥ **交付边界**：F-04 交付「加密链路 + API 客户端」；原生扫码接入 UI 的**二维码渲染**（需新增 QR 编码依赖）留待 F-05 一并接线。
> **下一批 = 批次 F 余项（F-04 阿里 extscreen / F-05 B站·百度 / F-07 文件列表 / F-08 pan 播放 / F-09 PG 自动化 / F-10 批次自检）**。
>
> **v6.40 变更**：**批次 F 第二段 —— F-02 登录模式首段（登录态机 + 网关接缝 + 扫码 / 短信验证码登录 Sheet）** ——
> ① **领域层**：新增 `lib/domain/entities/cloud/cloud_drive_login.dart`（`CloudDriveLoginMode` 六档：原生扫码 / Node 扫码 / Node 短信 / Node 账号 / 网页兜底 / PG 扫码；`CloudDriveLoginPhase` 八阶段：idle → loading → waitingScan → scanned → exchanging → saving → success / failed；`CloudDriveLoginTone` 六配色档，逐档对齐 iOS `qrLoginState` 与 `NodeGuangyaSMSLoginView`）；
> ② **表现层**：新增登录网关接缝 `pages/cloud/login_gateway.dart`（`CloudDriveLoginGateway` 抽象 + 缺省 `UnavailableCloudDriveLoginGateway`，未就绪文案分档对齐 iOS「Node 常驻系统未就绪 / 原生登录链路尚未接入」）· 登录会话控制器 `pages/cloud/login_controller.dart`（扫码轮询态机 + 短信 60s 倒计时 + 取消幂等）· 登录 Sheet `pages/cloud/login_sheet.dart`（扫码类对齐 iOS `NativeCloudQRLoginView`（220×220 二维码卡 + 状态卡 + 提示卡 + 主按钮）；短信类对齐 `NodeGuangyaSMSLoginView`（手机号 + 获取验证码 + 验证码 + 状态卡））· 授权中心动作接入 `openCloudDriveLoginSheet`；颜色令牌新增 `VboxColors.pending`（待确认黄，对齐 iOS `scanned` 档）；
> ③ **测试**：新增 3 个测试文件（领域模型 / 会话控制器（替身网关驱动状态机）/ 登录 Sheet Widget）；
> ④ **文档**：文档更名 `VBOX_PLAN_v6.39.md` → **`VBOX_PLAN_v6.40.md`**（D25），任务级 WBS 更名 `v1.14` → **`v1.15`**，开发方案更名 `v2.10` → **`v2.11`**。
> **下一批 = 批次 F 余项（F-02 余项 网页兜底·Token WebView / F-03 凭据同步 / F-04 阿里 extscreen / F-05 B站·百度 / F-07 文件列表 / F-08 pan 播放 / F-09 PG 自动化 / F-10 批次自检）**。
>
> **v6.39 变更**：**批次 D 收口 + 批次 E 全交付（E-01~E-06）+ 批次 F 首段（F-01 授权中心 / F-06 排序）** ——
> ① **批次 D 收口**：D-04 短剧页（源扫描 + 源标签切源 + 三列网格 + 搜索 + 详情跳转，新增「短剧」导航入口）· D-05 详情页扩展（头图 / 元信息 / 演职 chips / 线路 chips / 剧集宫格折叠展开 / 下载选集 sheet）· D-07 源发现页（源下拉 + 分类栏 + 分页网格）· D-08 批次自检；
> ② **批次 E 全交付（直播）**：E-01 直播页（频道源胶囊 + 分类胶囊 + 双列频道卡）· E-02 频道播放接入（线路 Sheet + 自动连接首线路）· E-03 EPG 节目单解析 + 长按频道卡唤出 Sheet · E-04 自定义源 + 本地导入/导出/分享（M3U/TXT + Android `LiveFilePlugin` + FileProvider）· E-05 MDTV 子系统全链路（动态 Tab/推荐/分类/标签 + 视频列表/详情 + 设置/域名设置 + AES 五模式加解密 + 数据模型 + `postJson`）· E-06 批次自检（守卫全绿 + 修复 3 处 player 子系统硬编码 UI 令牌越界）；
> ③ **批次 F 首段（网盘）**：F-01 网盘账号授权中心页（Node 常驻状态横幅 + 12 家网盘账号卡 + 检测/测试，对齐 iOS `CloudAuthCenterView`）· F-06 网盘排序页（长按拖拽 + 恢复默认 + `cloud_drive_sort_order_v1` 持久化，对齐 iOS `CloudDriveSortManager`）· 配套：云盘凭据安全存储（`cloud_drive_credentials_v1`）· 底部导航新增「网盘」入口 · 修复 `mdtv_crypto` AES 密钥扩展 Rcon 越界缺陷；
> ④ **文档**：文档更名 `VBOX_PLAN_v6.38.md` → **`VBOX_PLAN_v6.39.md`**（D25），任务级 WBS 更名 `v1.13` → **`v1.14`**，开发方案更名 `v2.9` → **`v2.10`**。
> **下一批 = 批次 F 余项（F-02 登录模式 / F-03 凭据同步 / F-04 阿里 extscreen / F-05 B站·百度 / F-07 文件列表 / F-08 pan 播放 / F-09 PG 自动化 / F-10 批次自检）**。
>
> **v6.38 变更**：**批次 C 全交付（C-01~C-12）+ 批次 D 首段（D-01 / D-02 / D-03 / D-06）** ——
> ① **批次 C 播放器核心链全交付**：路由→后端降级链（C-01）· 横竖双态控制层 UI（C-02）· 弹幕（C-03）· 选集/画质/倍速/后端菜单（C-04）· 自动连播控制器 + PiP 多策略（5 策略判定 + 系统桥 + 编排）+ 后台播放（前台媒体服务桥）+ 长按倍速（C-05）· 回退可观测（C-06）· 转封装代理（C-07）· 字幕解析（C-08）· 投屏/浮窗（C-09）· Go 代理三端绑定（C-10，含 MainActivity 接线核查修复）· Windows libmpv 插件（C-11）· URL 探测与后端矩阵（C-12）；
> ② **批次 D 首段（内容浏览 UI）**：D-01 首页（轮播 + 分类胶囊 + 横向列表 + 切换源浮层）· D-02 搜索（空态历史/榜单 + 结果态左源列表 + 结果卡 + 搜索历史去重/持久化/清除）· D-03 豆瓣（首页聚合 / 榜单分页 / 分类浏览，rexxar + chart 双 API 并发拉取）· D-06 分类网格（源下拉 + 分类胶囊 + 响应式海报网格）；
> ③ **测试与自检**：新增 8 个测试文件 + 49 用例 + 3 张 Golden 基线（douban_home / douban_ranking / douban_category）；`flutter analyze` 0 issues · `flutter test` **1061 用例全通过** · 整体覆盖率 **80.4% ≥ 70%** · 守卫全绿 · 零触达代码文件 2 个（`app.dart` / `main.dart`）；
> ④ **文档**：文档更名 `VBOX_PLAN_v6.37.md` → **`VBOX_PLAN_v6.38.md`**（D25），任务级 WBS 更名 `v1.8` → **`v1.9`**，开发方案更名 `v2.8` → **`v2.9`**。
> **下一批 = 批次 D 余项（D-04 短剧 / D-05 详情页 / D-07 源发现 / D-08 批次自检）**。
>
> **v6.35 变更**：**第 2 轮批次收口——批次 A 全量 + 批次 B（远程源与 Spider）+ 批次 Q（JavaScriptCore 三端集成 D6）三批次全交付** ——
> ① **批次 A 收口（A-07~A-13）**：自适应框架（`AdaptiveScaffold` / `ResponsiveGrid` / `ContentPanel` / `AdaptiveDialog`）· 页面树收敛（`lib/presentation/shell/home_shell_page.dart` 单一页树双排布，三套旧页树删除，`_RootRouter` 临时载体移除）· 输入适配（焦点环 / hover / 快捷键 / 十英尺缩放，D-pad 焦点框架层就绪）· 图片加载组件（平台封面分支）· UI 守卫 R-4 主色不散落 · 视觉回归基线（**35 图归档** `docs/ui_baseline/ios_ref/` + manifest 19 族映射 + Golden 4 张 + SSIM ≥0.95 机制就绪）· 品牌资源入包（字体 / 启动页字母图）。批次 A 自检：`flutter analyze` 0 issues · **658 用例全通过** · 覆盖 **75.6%** · 11 守卫全绿 · conformance **45/45**（详见 WBS §1）；
> ② **批次 B 全交付（B-01~B-12 + B-05a）**：远程源配置管理器（七出口状态机 / 代理降级链 / 6 合 1 聚合）· 站点模式判定 · JS 全局桥（`console`·`print` / `atob`·`btoa` / `req` / 对象式 `options`，6 项）· QuickJS 引擎接入 · **B-05 引擎映射定稿**（JSC 主 / QuickJS 降级备份，`createForJsSite` 入口）· **B-09 HTTP 桥**（5 级编码链唯一真相源 + 超时 15s + `sslBypass` 仅福利 + cookie 按域分组，JSC/QuickJS 双引擎接线）· **B-10 容错解码**（`url` 数组形态三端对齐：`urls` 取全列表 / `url` 取首元素，conformance **45 → 48**）· **B-11 站源原生搜索 + 腾讯原生 Spider**（最小 XPath 子集引擎 + `ZhanyuanSearchService` + `TencentVideoNativeSpider` 移植）· **B-12 conformance 收口**（5 套件 **83/83**：扩五操作 data 形状 + 站点模式 15 例 + manifest 契约 + 双引擎一致性 `engine_abi_v1`；`vj_free_string` 2 参签名对齐 C）（详见 WBS §2）；
> ③ **批次 Q 全交付（Q-01~Q-06，D6 三端 JSC，D31）**：Q-01 门禁（Windows 可行性 ✅ 可行）→ **Q-02 Android**（RN 生态 `jsc-android` 四 ABI 预编译 `.so` + JNI/CMake 交叉编译 wrapper + 预加载）· **Q-03 Windows**（Playwright WebKit 预编译 `JavaScriptCore.dll` + MSVC 编译 `vbox_jsc.dll` wrapper + runner 预加载 + 安装包打包 + CI）· **Q-04 macOS**（系统 `JavaScriptCore.framework` 零构建 + dylib 入 App Bundle + 预加载）· **Q-05 引擎统一封装**（`jsc_ffi.dart` `vj_*` 与 `vq_*` 同 ABI + `jsc_bridge_engine.dart` 与 QuickJS 同形状 + 工厂 D6 降级链（JSC 主 → QuickJS 自动降级 + `onLog` 可观测））· **Q-06 双引擎体积/许可核销**（`cross_engine_v1.json` 36 探针 + `double_run.c`/`double_run.py` 双跑 5/5 + `check_engine_bundle.py` 许可/体积 8/8，LGPL-2.1 动态链接合规）（详见 WBS §16 与 `评估_JSC_Windows可行性.md`）；
> ④ **文档**：新增 **P.38 二十六轮复核（批次 A/B/Q 收口）**；刷新 **A.1 阶段总览**与**第 2 轮进度口径**（三批次全交付，C–P 未开始）；文档更名 `VBOX_PLAN_v6.34.md` → **`VBOX_PLAN_v6.35.md`**（D25），旧文件名入 `DEAD_DOCS` 防回流。
> **下一批 = 批次 C（播放器 C-01~C-12）**。
>
> **v6.34 变更**：**第 2 轮批次 A「设计基座」续交付（A-05 / A-06）** ——
> ① **形态模型改造**（A-05）：`lib/presentation/ui_mode/` 由 `UiMode{phone,tv,desktop}` **三形态**收敛为
> `UiForm{portrait,landscape}` **双形态** + `InputModality{touch,remote,mouseKeyboard}`（只加焦点 / 交互反馈层，**不改版式**）；
> `UiFormResolver.resolve` 按 **① 用户开关 → ② 平台特征（TV / PC / mac 恒横屏）→ ③ 最短边 ≥ 600dp → ④ 方向** 四级判定，
> `UiFormController.resolveAt` 在 build 时注入 `MediaQuery` 视口（响应式，**不在 build 改状态**），
> `UiFormPlatform` 隔离平台分支（单测可注入）；原三形态语义改由「形态 + 模态」共同表达
> （手机竖 → portrait/touch · 手机横 → landscape/touch · 桌面 → landscape/mouseKeyboard · TV → landscape/remote）；
> `app.dart` `_RootRouter` 过渡映射：portrait → `HomeShelfPage` · landscape+remote → `TvHomePage` · landscape+其余 → `DesktopHomePage`
> （**A-08「页面树收敛」前的临时载体**，交付后移除）；
> ② **显示模式契约键**（A-06）：新增 `app_ui_form_override`（`_group_app_settings`，string，`userdefaults`，默认 `auto`；
> 取值 `auto|portrait|landscape`）—— 依 **D17 契约变更门禁**主动扩键（**非 iOS 逆向来源**，iOS 侧无此设置）；
> 契约 `schemaVersion 1.3 → 1.4`、键数 **98 → 99**（`_group_app_settings` 4 → 5 键），
> Dart 镜像 `prefs_keys.dart` + `prefs_manager.uiFormOverride()` 便捷方法 + `check_contract_sync.py` 同步；
> ③ **文档**：键数口径 98 → **99** 逐处订正（§2.4 注记 / §2.7 / §C.1 / §C.3 / E.10b 检查清单 / P.3 / P.6 / P.8 / P.10 / 目录树 /
> 决策表 **D17**），迁移策略标注契约升 **v1.4**；§2.4 形态判定注记由「实现仅为占位」订正为 **A-05 已交付**；
> ④ **计数（`git ls-files` + 磁盘实测口径）**：lib **125** · 测试 **57** · 静态用例 **600 → 614** · 守卫 **12** · conformance **45/45** 不变
> （A-05 / A-06 均为**改造**，无新增 lib / 测试文件）；⑤ **本版运行时验证待补**：沙箱 Flutter 3.47.5 SDK 下载未完成，
> `flutter analyze` / `flutter test` 留待 CI 首跑确认；Python 守卫（含 `check_docs_consistency` / `check_contract_sync`）已本地实测通过；
> ⑥ 文档更名 `VBOX_PLAN_v6.33.md` → **`VBOX_PLAN_v6.34.md`**（D25），旧文件名入 `DEAD_DOCS` 防回流。
> **G-09 / G-10 真机验收**（D30）仍后移至第 2 轮末；下一批 = **A-07（自适应框架）**。
>
> **v6.33 变更**：**第 2 轮批次 A「设计基座」首批交付（A-01 / A-02 / A-03 / A-04 / A-11）** ——
> ① **设计令牌**（A-01 / A-02）：新增 `lib/presentation/theme/tokens/` **5 文件** ——
> `colors.dart`（四皮肤主色 + 语义色 + 分类色板 10 色 + 品牌渐变）· `typography.dart`（字号 **10 档**）·
> `radii.dart`（圆角档位 `{4,6,8,10,12,14,16,20}`）· `spacing.dart` · `shadows.dart`；
> ② **主题工厂 + 皮肤控制器**（A-03）：`vbox_theme.dart`（`VboxTheme.build` / `preferredBrightness`，对齐 iOS
> `preferredColorScheme` 口径）+ `vbox_skin_controller.dart`（消费 `app_skin_mode` / `app_skin_follows_system`，
> 持久化并广播变更）；`lib/app.dart` 接线 `theme` / `darkTheme` / `themeMode` 并对齐 `ChangeNotifierProvider`；
> ③ **统一组件库**（A-04）：新增 `lib/presentation/widgets/vbox/` **11 文件**（barrel + Card / Chip / SectionHeader /
> EpisodeChip / Button / Toast / Nav（BottomNav + Rail）/ Dialog / PosterCard / SourceBadge），全部消费令牌；
> ④ **UI 守卫**（A-11）：新增 `scripts/check_ui_tokens.py`（**R-2 圆角受控 · R-3 字号受控 · R-4 主色不散落**），
> 125 个源文件扫描通过 → **校验脚本 11 → 12**；
> ⑤ **测试**：新增 `test/presentation/theme/` **3 文件** + `test/presentation/widgets/vbox/` **1 文件** +
> 视觉基线截图测试 `test/_ui_baseline_shots_test.dart`，共 **5 文件 / 47 静态用例**；
> ⑥ **计数（`git ls-files` 实测口径）**：lib **125** · 测试 **57** · 静态用例 **600** · 守卫 **12** · conformance **45/45** 不变；
> ⑦ **计数口径订正（D26 类漂移）**：v6.32 文档沿用的「lib 100 / 测试 46」与 `git ls-files` 实测（基线 **106 / 52**）
> 不符（疑为 v6.27–v6.30 批次未同步），本轮起改用实测口径并在变更块标注方法；
> ⑧ **本版运行时验证待补**：沙箱无可用 Flutter（下载未完成），`flutter analyze` / `flutter test` / 覆盖率复测
> **留待 CI 首跑确认**；`check_ui_tokens.py` 与既有 Python 守卫已在沙箱本地实测通过；
> 文档更名 `VBOX_PLAN_v6.32.md` → **`VBOX_PLAN_v6.33.md`**（D25）。
>
> **v6.32 变更**：**Spider 引擎口径落定（新增 D31）+ 订正三处残留漂移** ——
> ① **新增 D31（引擎口径）**：第 2 轮复核实测修正 —— iOS `SpiderEngineType` 枚举实为 **4 类**（`javaScriptCore` / `quickJS` / `node` / `nodeLX`），
> `PythonSpiderEngine` 为第 5 个实现但**不在枚举内**；`SpiderManager` 实测为「**JSC 为主 → QuickJS 降级**」（`for engineType in [.javaScriptCore, .quickJS]`）。
> 实测 **JSC 桥能力显著强于 QuickJS 桥**（GBK/Big5 编码链 · `sslBypass` · `atob`/`btoa` · 真实 `console`/`print` · `req` 别名 · 对象式 `options`，共 **6 项**），
> 且此 6 项**与引擎选择无关、无论选谁均须实现**。经决策确认：**三端（Android / Windows / macOS）均集成 JavaScriptCore** 作为 JS 站点脚本主引擎，
> **QuickJS 保留为降级备份**；**代价集中于 Windows**（无成熟预编译 JSC）→ 设 **Q-01 可行性评估门禁**，不通过则触发降级预案（Windows 改用 QuickJS）并回老板重新确认。
> ② **漂移订正 1（D26 类结构性残留）**：顶部文件名沿革链长期停在「**`VBOX_PLAN_v6.30.md`（当前版）**」，与 v6.31 实际不符，现补 v6.31 / v6.32 两环；
> ③ **漂移订正 2**：正文「决策记录追加」表误留「**D20 第 1 轮当前不可标记完成**」（D30 已修订 D20 为「代码侧交付 + 自动化门禁通过」），现予订正；
> ④ **漂移订正 3（跨文档计数 / 进度口径残留）**：第 1 轮检查报告仍停在 v6.26 计数与旧进度口径（用例 **504** · 全 lib 覆盖 **76.1%** · 进度 **73%**），与 A.1（D30 后 **100% 代码侧**）及现行计数（**555** · **73.6%** · 守卫 **11**）矛盾，随报告更名 `_v6.31.md` → `_v6.32.md` 一并刷新；
> ⑤ **本版为文档批次**：无代码 / 契约改动，各项计数不变（lib **100** / 测试 **46** / 用例 **555** / 覆盖率 **73.6%** / 守卫 **11** / conformance **45/45**）；
> 文档更名 `VBOX_PLAN_v6.31.md` → **`VBOX_PLAN_v6.32.md`**（D25），第 1 轮检查报告同步更名 `_v6.31.md` → `_v6.32.md`。
>
> **v6.31 变更**：**真机验收排期修订（G-09 / G-10 整体后移至第 2 轮末，新增 D30）** ——
> ① **决策依据**：第 1 轮核心骨架**代码侧已全部交付**（v6.30 已确认），唯一余项为 **G-09（侧载链路 / 自更新 / 播放器回退真机）**
> 与 **G-10（TV 焦点与遥控真机）**，二者均为**真机人测**（D8）；第 2 轮「功能补全」将补齐**搜索 / 直播 / 网盘 / Spider / 播放器**
> 等模块，真机验收在功能齐备后进行**更完整、更有意义**（且避免对不全功能重复测试）；
> ② **修订 D20**：第 1 轮完成判定由「真机验收通过」调整为「**代码侧交付 + 自动化门禁（E.10b 六类扫描）通过**」；
> **G-09 / G-10 整体后移至第 2 轮末**，并入第 2 轮 E.10b 门禁（新增 **D30** 记录本次排期变更）；
> ③ **口径同步**：E.7 第 1 轮人测由「三端安装启动 + 核心流程冒烟」改为「**延后（并入第 2 轮末真机批次）**」，
> 第 2 轮人测改为「**全功能 + TV 遥控 + 老设备 + G-09/G-10 全量真机验收**」；E.10b.5 各阶段检查重点同步；
> ④ **报告刷新**：`stage_check_report_stage1.yaml` verdict 由 **blocked** 改为 **pass**（真机类检查项改为后移登记），
> 第 1 轮检查报告同步更名 `第1轮核心骨架全面检查报告_v6.30.md` → `第1轮核心骨架全面检查报告_v6.31.md`；
> `docs/真机验收清单_G09_G10.md` 范围标注由「第 1 轮」改为「第 2 轮末」；
> ⑤ **风险登记**：真机验收后移意味着**地基类问题（安装链路 / 播放器后端回退 / TV 焦点）延后暴露**，
> 若第 2 轮末才发现阻断性问题则返工面较大；已登记为已知风险，真机批次须**优先覆盖地基项**（清单 §2.1 安装 / §2.3 回退 / §3 焦点）；
> 文档更名 `VBOX_PLAN_v6.30.md` → **`VBOX_PLAN_v6.31.md`**（D25）。
>
> **v6.30 变更**：**CI 反馈修复第二轮（flutter test 2 处失败清零）** ——
> ① v6.29 重推（commit `70e231e`）后 Flutter Check（run `36760297112`）中的 **`Analyze` 步骤已通过**（10 处提示确认清零），
> 但**同一 job 的 `flutter test` 失败 2 处**（553 通过 / 2 失败）—— 经本机 Flutter 3.47.5 复现，两处均为
> **`test/presentation/widgets/backup_page_test.dart` 的测试侧缺陷**（**生产代码零改动**）：
>   - **①-1 视口过小**：导出 Tab 的「9 个类目 + 口令 + 导出按钮」总高超出 `testWidgets` 默认 **800×600** 视口，
>     `ListView` 仅构建可见子项，使 `搜索历史` / `网盘凭据` 缺席 widget 树 → `find.text` 找不到（测试 1 失败）；
>   - **①-2 FakeAsync 下的真实 I/O 死锁**：测试 3 在 `testWidgets` 体内直接 `await svc.writeBackupFile(...)` 触碰真实文件系统，
>     而 `testWidgets` 运行在 **FakeAsync** 时钟下，真实文件 I/O 的 `Future` **永不完成** → 一直挂到 **10 分钟**测试超时（测试 3 失败）。
> ② 修复（仅测试文件）：`backup_page_test.dart` 改为注入**测试替身** `_FakeBackupService`（仅覆盖 `listBackupFiles`，
> 真实采集 / 写回仍由 `test/data/datasources/local/backup_service_test.dart` 覆盖），彻底避开真实 I/O；
> 并把视口放大到 **1200×1600**，使 9 个类目一次性构建；
> ③ 本机 Flutter 3.47.5 全量复现并验证：`flutter analyze` **0 issues**、`flutter test --coverage` **555 用例全通过**（原 553 通过 + 2 失败）、
> 覆盖率门槛 **73.6% ≥ 70%** 达标；Python 守卫 **10/10** + conformance **45/45** 全绿；
> ④ 环境说明：本沙箱本轮已安装 Flutter 3.47.5 独立复现 CI 全链路（P.7 原「本机无 SDK」约束本轮解除）；
> 文档更名 `VBOX_PLAN_v6.29.md` → **`VBOX_PLAN_v6.30.md`**（D25）；检查报告同步更名 `第1轮核心骨架全面检查报告_v6.29.md` → `_v6.30.md`。
>
> **v6.29 变更**：**推送 + CI 反馈修复（Flutter analyze 10 处清零）** ——
> ① 本批次 `main` 推送成功（commit `738b3b7`）；Flutter Check（run `36759261677`）**flutter-analyze 失败**：新增代码引入 **10 处** analyze 提示；其余 5 job（contract-checks / build-android / build-macos / build-windows / build-native-quickjs）**全绿**；
> ② 修复 `backup_service.dart` 冗余字符串插值（`_stringifyPref` 已返回 `String`）；
> ③ 修复 `backup_payload.dart` **潜在运行期缺陷**：原 `const BackupPayload` 以 `const <String, String>{}` 作 `categories` 默认值，多实例将共享**不可变**映射，`putCategory` 写入抛 `UnsupportedError` —— 构造改为**非 const** + 默认值改为每次新建可变映射；连带消除 **9 处** `prefer_const_constructors`（8 处 `backup_payload_test.dart` + 1 处 `backup_service_test.dart` 去除 `const`）；
> ④ 校验：Python 守卫 **10/10** 本地全绿；Dart `analyze` / `test` 以重推后的 CI 为准（本沙箱无 SDK，P.7）；
> 文档更名 `VBOX_PLAN_v6.28.md` → **`VBOX_PLAN_v6.29.md`**（D25）。
>
> **v6.28 变更**：**A2/A3/B4 接线交付（网络可达性 / 日志落盘 / 备份还原）** ——
> ① **A2 网络可达性**：新增平台层 `lib/platform/system/connectivity_network_info.dart`（`connectivity_plus`，**失败开放**语义：探针缺失 / 通道异常一律判在线），`lib/core/network/http_client.dart` 注入 `NetworkInfo` 后**离线短路**（避免无谓重试），`app.dart` 启动时构造并注入全部 HTTP 客户端；
> ② **A3 日志**：`app.dart` 按契约键 `app_log_enabled` / `app_log_min_level` 配置 `AppLog` 门控并启动落盘；关键模块（启动 / HTTP / 仓储 / 桥）埋点；新增 `lib/data/datasources/local/log_file_sink.dart`（按日文件 `yyyy-MM-dd.log` + 3 小时保留，对齐 iOS `persistDays = 0.125`）异步落盘；新增 `lib/presentation/widgets/log_viewer_page.dart`（级别过滤 / 关键字 / 导出）并接入 phone / desktop / tv 三形态；
> ③ **B4 备份还原**：新增 `lib/data/datasources/local/backup_service.dart`（9 类目 dump / restore，**merge / overwrite** 冲突策略）+ `backup_payload.dart`（Payload 值 = Base64(UTF-8 JSON)，契约 §5.1）+ `lib/presentation/widgets/backup_page.dart`（导出 / 导入双 Tab，三形态入口）；备份扩展名统一 **`.vboxbak`**（契约 §11）；
> ④ **守卫加固**：`check_backup_contract.py` 新增 **§6**（B4 契约核对：9 类目 / 冲突策略 / 白名单 11 + 3 / 表映射 / Payload 编解码 / 扩展名），并修复 §7 白名单解析把正文行内代码 `settingsDefaultKeys` 误抓为契约键的缺陷（Dart 白名单本已正确）；
> ⑤ **测试**：新增 5 个测试文件（`connectivity_network_info` / `log_file_sink` / `backup_payload` / `backup_service` / `backup_page`），并更新 `logger` / `network` / `backup_manager` / `app_constants` 既有用例；
> ⑥ **校验**：基础守卫 **10/10** + conformance **45/45** 本地实测全绿（Flutter `analyze` / `test` 由 CI 承担，见 P.7）；E.10b 余项仍为 **G-09 / G-10（真机人测）**，`stage_check_report_stage1.yaml` verdict 保持 **blocked**（D20）；
> 文档更名 `VBOX_PLAN_v6.27.md` → **`VBOX_PLAN_v6.28.md`**（D25）。
>
> **v6.27 变更**：**P2 遗留清理全批次闭环（A4/B2/B3/D1/D2）+ E.10b 代码侧收口（第 1 轮只剩真机验收）** ——
> ① **A4 死代码裁定**：移除 `lib/data/models/db_model.dart` 中零继承零使用的 `DbModel` 抽象基类，保留 SQLite 读写辅助函数（`check_docs_consistency` 引用同步更新）；
> ② **D1 依赖冗余**：`pubspec.yaml` 移除零引用的 `dev_dependencies.test`（^1.25.8，pubspec.lock 同步）；
> ③ **D2 脚本归并**：以 `api_push2.py` 为基底归并为 `scripts/api_push.py`（保留 diff 模式），删除 `api_push2.py`，全文引用（含 P.13 风险表）改为唯一脚本；
> ④ **B2 存储策略裁定**：`prefs_manager.dart` `_isSecure` 纳入 `storage == PrefsStorage.credentialExtra` —— PG 凭据 extra 字段（`pg_source` / `qr_scan`）由明文 SharedPreferences 改为经核心层 SecureStore 抽象走安全存储（与 keychain 键同级），契约 §2.5 与 `check_prefs_manager.py` 同步；
> ⑤ **B3 敏感键复核裁定**：契约 `prefs_keys_v1.json` 升 **v1.3** —— `sensitiveKeys` 5 → **7**（新增 `baidu_local_pcs_device_id` 百度 PCS 本地设备指纹 / `saved_drive_tokens` 网盘 token 存储键），Dart 镜像 `prefs_keys.dart` 逐键同步 `sensitive: true`；
> ⑥ 测试：`prefs_manager_test.dart` 更新安全键集合口径（**11 键** = 7 敏感 + 2 keychain + 2 credential_extra），新增断言覆盖 B2/B3 裁定键；`check_prefs_manager.py` 静态检查同步收紧；
> ⑥' CI 反馈修复（推送后 Flutter Check 暴露 2 处）：**build-macos** —— `PlayerPlugin.swift` 使用 iOS-only 属性 `AVPlayer.automaticallyWaitsForMinimizeStallingPlayback`，macOS 无该成员 → 移除并注释（默认策略即等待最小化卡顿）；**flutter test** —— `prefs_keys_test.dart` 仍断言 `jsonSensitive.length == 5`，未随 B3 同步 → 改为 7（505 通过 + 1 失败 → 修复）；
> ⑦ 门禁（E.10b）：P2 遗留清理闭环后，第 1 轮（核心骨架）**代码侧已全部交付**；E.10b 余项收敛为 **G-09 / G-10（真机人测）**；`stage_check_report_stage1.yaml` verdict 仍 **blocked**（D20：真机验收通过前不得标记完成、不得进入第 2 轮）；
> 新增 **P.37（P2 遗留清理全批次复核）**；文档更名 `VBOX_PLAN_v6.26.md` → **`VBOX_PLAN_v6.27.md`**（D25）。
>
> **v6.26 变更**：**G-02-C Android 平台补全 + G-05 零触达收尾 + G-09/G-10 真机验收清单交付（第 1 轮 E.10b 余项最后一批可落地代码）** ——
> ① **G-02-C Android 代码交付**：`android/.../com/vbox/player/SystemPlugin.kt`（UiMode 三重判定通道 `com.vbox.system/system`：`getUiModeType` / `hasLeanbackFeature` / `hasTouchscreen`，对齐方案 §T.1）；`android/.../player/MediaPlaybackService.kt`（Media3 `MediaSessionService` 前台媒体服务：后台 / 锁屏保活 + 任务移除停止）；`AndroidManifest.xml` 双形态特性声明（touchscreen / leanback 均非必需）+ 前台服务注册 + TV LEANBACK_LAUNCHER 入口；`build.gradle.kts` 加 `media3-session`；Dart 侧 `lib/platform/system/system_bridge.dart`（`SystemBridge` 抽象 + `MethodChannelSystemBridge`，异常安全回退 false 不抛）+ `ui_mode_resolver.dart` 增 `resolveModeWithBridge` / `resolveAndroidMode` 纯逻辑 + `app.dart` 注入接线；`scripts/fetch_libmpv.sh` + `scripts/libmpv_external_dependencies.json`（D28 落地：GitHub Release 资产下载 + SHA256 校验）；
> ② **G-05 零触达收尾**：零触达 **29 → 27**（补测 `test/platform/system/system_bridge_test.dart` 7 用例 / `test/core/network/network_info_test.dart` 2 用例 / `test/core/constants/app_constants_test.dart` 6 用例 / `test/presentation/ui_mode/ui_mode_resolver_test.dart` 7 用例）；**修复缺陷**：`MethodChannelSystemBridge._invoke` 补 `TypeError` 兜底（原生回传非布尔值时 `invokeMethod<bool>` 类型转换抛错，违反「异常安全回退不抛」契约——由补测暴露）；静态用例 **482 → 504**、测试文件 **43 → 46**；剩余 **27 个零触达全部登记排除**：20 barrel + 4 领域仓储接口（纯抽象）+ 2 入口（`main.dart` / `app.dart`）+ 1 纯常量（`app_constants.dart`，编译期内联 lcov 无法记录命中，已有单测验证值）；
> ③ **G-09/G-10 真机验收清单**：新增 `docs/真机验收清单_G09_G10.md` —— G-09 侧载链路 24 项（安装链路 9-1~9-7 / 自更新 9-8~9-14 / 播放器端到端回退 9-15~9-24）+ G-10 TV 焦点与遥控 17 项（焦点 5 铁律 / 按键映射 / D-pad 全流程），含前置物料 P1~P8 与执行记录表；人测职责（D8），解除条件对照 E.10b；
> ④ 门禁（E.10b）：**G-02-C 代码交付**（端到端回退真机验收并入 G-09 清单）；**G-05 收尾交付**（零触达 27/100 全分类排除，整体覆盖 **76.1%** ≥ 70%）；E.10b 余项 = **G-09 / G-10（真机人测）**；
> 新增 **P.36（G-02-C 代码批次 + G-05 收尾 + 真机清单交付复核）**；文档更名 `VBOX_PLAN_v6.25.md` → **`VBOX_PLAN_v6.26.md`**（D25）。
>
> **v6.25 变更**：**详情页·播放入口接线交付（第 1 轮 E.10b 余项最后一块 UI / 播放数据链路）** ——
> ① 交付 **5 个 lib 文件**：`lib/domain/entities/playback/`（`playback_detail.dart`：`PlaybackDetail` / `PlaybackEpisode` / `ParsedPlayUrl` / `PlaybackUrlParser`（契约 §3.4 `vod_play_from`（`$$$` 线路）/ `vod_play_url`（`#` 剧集 / `$` 名址）解析 + 直链媒体判定）+ barrel `playback.dart`）；`lib/data/datasources/remote/all_sources_datasource.dart`（清单 → allSources **代理降级链**拉取 + `findSite` 按 key 查找站点）；`lib/domain/usecases/detail_playback_usecases.dart`（站点解析 → 模式判定 → CMS V10（apiEndpoint/zhanyuan `?ac=detail&ids=`）或 Spider 引擎（node 免脚本 / jsSpider 由 **QuickJS 顶替 JSC** / pythonSpider 加载脚本）详情拉取 → `resolvePlayUrl` 直链 / API 地址即直链 / 引擎 `playerContent` 二次解析三分支）；`lib/presentation/widgets/detail_page.dart`（详情页：影片信息 / 线路 ChoiceChip / 剧集 ActionChip / 播放按钮，续播 `initialIndex` 钳制到线路内索引 + 线路切换 + 失败重试）；
> ② 接线：`lib/presentation/widgets/library_views.dart` 收藏 / 历史列表项 onTap → `DetailPage`（`siteKey=laiyuan` / `vodId=detailurl` / `initialIndex=jishu`）；`lib/app.dart` 装配 `AllSourcesDatasource` / `CmsV10Datasource` / `DetailPlaybackUseCases` 并注册 Provider；barrel 导出（`remote.dart` / `usecases.dart`）；
> ③ 测试：新增 **3 个测试文件 / 32 用例**（`playback_detail_test.dart` 9：契约 §3.4 双线路多剧集 / 名址含 `$` / 直链判定；`detail_playback_usecases_test.dart` 15：参数校验 / 站点解析 / CMS 路径 / 蜘蛛路径（node 免脚本、QuickJS 顶替、python 脚本加载、注册失败、详情为空）/ `resolvePlayUrl` 三分支；`detail_page_test.dart` 8：加载中 / 失败重试 / 线路切换 / 续播高亮 / 播放按钮驱动 `PlayerController.open·play` / 解析失败提示 / 无剧集禁用）；静态用例 **450 → 482**、测试文件 **40 → 43**、lib 文件 **93 → 98**；
> ④ 门禁（E.10b）：**详情页·播放入口接线解除** —— 第 1 轮 UI / 播放数据链路闭环（G-01 三形态 + 书架 / 远程源 + 详情页均交付）；E.10b 余项 = **G-02-C / G-05 / G-09 / G-10**；
> 新增 **P.35（详情页·播放入口接线交付复核）**；文档更名 `VBOX_PLAN_v6.24.md` → **`VBOX_PLAN_v6.25.md`**（D25）。
>
> **v6.24 变更**：**G-02-B / G-03-B 平台插件与 Spider 运行时交付（三端决策 D28/D29 定稿）** ——
> ① **G-02-B-1 macOS AVPlayer 接线交付**：`macos/Runner/PlayerPlugin.swift`（AVFoundation 主后端，MethodChannel `com.vbox.player/player` + EventChannel `com.vbox.player/player/events`，open/play/pause/seekTo/setVolume/setSpeed/dispose + state/progress/error 事件流，A21.5 复杂封装（MKV/FLV）返回 `E_BACKEND_UNAVAILABLE` 供降级链捕获）；`MainFlutterWindow.swift` 手动注册插件；`project.pbxproj` 纳入 Swift 编译（CI build-macos 可验）；
> ② **D28 libmpv 原生二进制分发决策**：**原生二进制不入 git 仓库**，由构建脚本从 GitHub Release 资产下载（沿用 iOS `mpvkit-deps-0.0.1` 模式，新增 `libmpv-{os}-{arch}-{ver}` 资产），随 DMG/EXE 侧载产物分发（D11）；CI 仅验证下载 + 链接（smoke），端到端回退真机验收归 G-02-C；
> ③ **G-03-B-1 QuickJS FFI 绑定交付**：`quickjs/wrapper.{h,c}`（纯 C 封装 `vq_create_runtime/vq_create_context/vq_eval/...`，三端可编译）+ `scripts/build_quickjs_wrapper.sh`（产物 `libvbox_quickjs.{so,dylib,dll}`）+ CI 新增 `build-native-quickjs` job（ubuntu gcc 实测编译通过）；
> ④ **G-03-B-2 QuickJS 引擎交付**：`lib/platform/runtime/` **3 文件**（`quickjs_ffi.dart` Dart FFI 抽象（`QuickJsNativeBridge` / `DartFfiQuickJsBridge` / `UnavailableQuickJsBridge`）/ `quickjs_bridge_engine.dart`（实现 `SpiderEngine`：loadScript / registerSpider / 5 操作，对齐 iOS `QJSSpiderEngine` 语义）/ barrel `runtime.dart`）；`spider_engine_factory.dart` quickJS 分派接入（javaScriptCore 仍抛 unimplemented，iOS 原生保留）；
> ⑤ **D29 Node/Python 运行时分发决策**：**Python 三端内置 + 桌面系统探测**（Android 用 Chaquopy Gradle 依赖零 NDK / iOS 原生 python-stdlib 3.14 / 桌面探测系统 python3，缺失 → `E_BACKEND_UNAVAILABLE`）；**Node 仅桌面系统探测 + iOS 原生常驻**（Android NodeMobile 嵌入成本高，登记待评估）；**不采用首次下载**（D11 侧载无商店更新通道，运行时网络依赖与校验不可控）；
> ⑥ 测试：新增 `test/platform/runtime/quickjs_bridge_engine_test.dart`（**13 用例**：FFI mock 注入，生命周期 / 错误检测 / 注册 / 5 操作双返回路径 / init 恰一次 / URL 加载（真实 HttpServer）/ dispose 幂等）；工厂测试更新（quickJS → QuickJSBridgeEngine + javaScriptCore → unimplemented，5 → 6 用例）；静态用例 **436 → 450**、测试文件 **39 → 40**、lib 文件 **90 → 93**；
> ⑦ 门禁（E.10b）：**G-02 继续解除**（G-02-B 交付，余 G-02-C 需真机）；**G-03 继续解除**（G-03-B 交付，QuickJS 顶替 JSC 落地）；E.10b 余项 = **G-02-C / G-05 / G-09 / G-10 / 详情页·播放入口接线**；
> 新增 **P.33（G-02-B 交付复核）/ P.34（G-03-B 交付复核）**；文档更名 `VBOX_PLAN_v6.23.md` → **`VBOX_PLAN_v6.24.md`**（D25）。
>
> **v6.23 变更**：**第 1 轮（核心骨架）全面检查报告交付（stage_check_report_stage1.yaml + 报告文档刷新）** ——
> ① 按 E.10b.2 六类扫描逐项输出**第 1 轮阶段遗漏检查报告**（`contract/docs/stage_check_report_stage1.yaml`，依据模板
> `stage_check_template.yaml`，与 `stage0` 报告同目录留档）；同步**刷新** `docs/第1轮核心骨架全面检查报告_v6.23.md`
> （v6.13 首版 → v6.23 现版：计数 lib 75→90 / 测试 29→39 / 用例 371→436、门禁 G-01✅/G-02·G-03 部分解除、
> 遗留问题闭环 3 项 B1/C1/C3、下一步 G-02-B 优先）：契约一致性 ✅ / 数据与状态 ✅ / 平台差异 ⚠️ 部分
> （macOS AVPlayer + libmpv 分发（G-02-B）与 TV D-pad 真机（G-10）待）/ 功能完整性 ⚠️ 部分（Spider 桥接 G-03-A 已交付、
> QuickJS FFI（G-03-B）与详情页·播放入口接线待）/ 质量基线 ✅（v6.21 实测覆盖 74.0% 达标）/ 交付物 ✅；
> ② 结论 **verdict: blocked** —— 第 1 轮 70% 进行中（D20 不得标记完成、不得进入第 2 轮）；阻断项 =
> G-02（B/C）/ G-03（B）/ G-05（零触达收尾）/ G-09（真机）/ G-10（TV D-pad）/ 详情页·播放入口接线；
> ③ 计数不变（lib **90** / 测试 **39** / 单测 **438**（静态声明））；conformance **45/45** + Python 守卫 **10/10** 本地实测通过；
> ④ 文档更名 `VBOX_PLAN_v6.22.md` → **`VBOX_PLAN_v6.23.md`**（D25）；下一批 = **G-02-B**（macOS AVPlayer 接线 + libmpv 分发决策）。
>
> **v6.22 变更**：**G-02-A 平台插件层首批交付（G-02 从「未开始」推进到「部分解除」）** ——
> ① 交付 `lib/platform/player/` **4 文件**（通道桥 `player_channel_bridge.dart`（MethodChannel + EventChannel 适配，`backendWireValue` 与原生 wire 值对齐）/ 通道播放器 `channel_player.dart`（实现 `Player`，`PlayerOpenException` 透传原生错误码）/ 统一控制层 `player_controller.dart`（后端降级链 + 状态 / 进度 / 错误转发 + `togglePlay`）/ barrel `player.dart`），
> 对齐 iOS `PlayerEngine` 协议（type/state/event）与契约 §2.5 / A21.5 回退策略；
> ② Android 接线：`PlayerPlugin.kt`（MethodChannel/EventChannel 双通道，Media3/ExoPlayer 主后端，`open/play/pause/seekTo/setVolume/setSpeed/dispose` + state/progress/error 事件流）、
> `CodecCapability.kt`（A21.5 `selectBackend`：MKV / HEVC 无硬解 → libVLC 回退判定，纯 JVM 零 NDK）、
> `build.gradle.kts` 加 media3 + libvlc-all 依赖、`MainActivity.kt` 注册插件；libVLC 回退实现在 G-02-B/C 交付（本批返回 `E_BACKEND_UNAVAILABLE` 供降级链捕获）；
> ③ 新增 **2 个测试文件 / 15 用例**（`channel_player_test.dart` 7：open 参数组装 / 原生异常映射 / 控制转发 / 事件分发；`player_controller_test.dart` 8：回退链接管 / 全败 E_NO_BACKEND / MKV 直选 libVLC / 状态转发 / togglePlay / 未 open 空操作 / 错误逐级上报 / error 事件透传）；
> ④ 修复两处收口缺陷：`PlayerController` 上误标的 `@override`（未实现 `Player` 接口，analyze 必报）移除；`CodecCapability.kt` 补 `android.media` 导入（`MediaCodecList` 未解析会编译失败）；
> ⑤ 计数变化：lib **86 → 90**（+platform/player 4）、测试文件 **37 → 39**（+2）、单测 **423 → 438**（+15）、覆盖率口径与 CI 复核详见 P.32；
> ⑥ 门禁（E.10b）：**G-02 部分解除** —— G-02-A（Dart `PlayerController` 抽象 + 平台通道桥 + Android Gradle 接线 + Dart 单测）**交付**；
> G-02-B（macOS AVPlayer 接线 + libmpv 分发决策）/ G-02-C（SystemPlugin + MediaPlaybackService + 真机验收）**待决策**；
> 新增 **P.32 G-02-A 交付复核**；文档更名 `VBOX_PLAN_v6.21.md` → **`VBOX_PLAN_v6.22.md`**（D25）。

## 版本历史

<!-- docs-guard:history -->

| 版本 | 主要变更 |
|------|---------|
| v3 | 确认 iOS 方案 A4（契约共享，零改造）；TV 同一 APK 双形态；新增第 0 阶段契约层 |
| v4 | **全部代码由 AI 编写，人力只做测试**（D8）；验收改为自动化 + conformance 自证（D10）；新增第 E 章执行计划、第 V 章 TV 调研、第 S 章侧载方案 |
| v5 | **三份附属文档并入（附录 A/B/C），全项目仅一份文档**；补 P.1–P.11 实际进度与核查；conformance runner 交付；文档漂移治理（16→0） |
| v5 增补 | 2026-09-29 增补：**Flutter CI 验证通道落地**（`.github/workflows/flutter-check.yml`，解除 G-07/G-08）；**P.12 核心层交付**（`lib/core/` 5 模块 20 文件 + 7 文件 78 单测，补齐 P.9 第 4 项）；`http_bridge` 编码探测链上移核心层去重 |
| v6 | 2026-09-29：**全量体检入库**（P.13：各层清点 + 15 项问题 + 待办）；核心层 21 文件 / 用例层 4 组 / 远程数据源 2 个交付；单测 143 用例（CI 全绿）；修复 `.version` 回退高危缺陷；**第 10 个校验脚本** `check_dart_imports.py`；全部数字口径刷新；文档更名 `VBOX_PLAN_v5.md` → `VBOX_PLAN_v6.md`（v6.9 起更名为 `VBOX_PLAN_v6.9.md`） |
| **v6.1** | 2026-09-29：**收尾批次** —— ① 堵住文档守护脚本的历史豁免漏洞（移除弱标记 + 块级历史标记 + 脚本数改**硬失败**），并修正其抓出的 **4 处**残留漂移；② 追加 **D21–D23**（provider / 3.47.5 / sqflite 对齐实现）；③ 修订 §2.3 技术选型表与 §2.7 的 freezed 引用；④ 新增 **P.14 二轮独立复核清单（22 项遗漏）**；⑤ 根目录清理（`.o` ×6 删除、游离脚本归入 `scripts/legacy/`、两份游离 md 归档 `docs/archive/`）；⑥ `.gitignore` 补 `*.o` / `build/` / `.dart_tool/`；⑦ `pubspec.yaml` 版本对齐为 `3.1621.0+1621` |
| **v6.2** | 2026-09-29：**三轮独立复核**（新增 P.15：**12 项**遗漏，v6.1「守卫 0 漂移」结论被推翻）。① 文档守卫堵「表格 / 加粗 / 合计」数值逃逸，并新增 **Dart 源码**失效引用扫描；② §C.3 按契约 v1.2 重写（原 v1.0 口径 14 组 / 57 键，含已删 `buffer` 组）；③ 文件数 / 脚本数逐处对齐 `git ls-files`；④ 形态判定 §2.4 ↔ §T.1 ↔ 实现口径统一（实现标注为**占位**）；⑤ 清除 `freezed` 残留、`TODO(D21→G-01)`；⑥ README / CI 注释对齐多端现状；⑦ `merge_docs_v5.py` 归档 `scripts/legacy/` |
| **v6.3** | 2026-09-29：**契约 D19 闭环**（P.15 #11）—— `prefs_keys_v1.json` 键对象去异构：前 12 组 **53 键**补齐 `storage: userdefaults`，现 **98/98** 键显式标注（userdefaults / keychain / credential_extra）；`check_contract_sync.py` 新增规则 **3d**（storage 完整性 + Dart↔JSON 逐键比对）并经负向测试验证；修正该脚本陈旧 docstring（63 → 98 键） |
| **v6.4** | 2026-09-29：**高风险层单测补齐**（P.15 #10 闭环）—— 新增 `test/contract`（2）、`test/data/models`（1）、`test/data/datasources/local`（3）、`test/presentation/ui_mode`（1）共 **7 个测试文件 / 103 用例**；单测 **143 → 246**、`flutter analyze` 0 issues、10 脚本 + conformance 45/45 全绿；新增 **P.16 深度遗漏复核（7 项，1 🔴）** |
| **v6.5** | 2026-09-29：**本机实测复核 + 覆盖率首次测量** —— 本机 Flutter 3.47.5 独立复现 v6.4 声明（analyze 0 issues / 246 用例 / 10 脚本 / 45/45）；首次 `flutter test --coverage`：触达口径 **83.4%**，但 **28/69 文件零触达**（含 `lib/domain/entities/spider/` 789 行）→ 整体未达 70%，门禁 ⑤ 转为**明确不达标**；新增 **P.17（8 项：2 🔴 / 5 🟡 / 1 🟢）**；`.gitignore` 补 `coverage/` |
| **v6.6** | 2026-09-29：**收口批次 + 覆盖率门禁做实** —— ① Spider 实体层单测 **5 文件 / 98 用例**补齐（P.17 #2 闭环，该层 0% → 5/5 触达）；② 单测 **246 → 344**（测试文件 **19 → 24**），`flutter analyze` 0 issues；③ 覆盖率复测：触达 **85.6%**、零触达 **28 → 23**、**全 lib 整体口径 ≈ 70.6%（保守下界）→ 门禁 ⑤ 转为「达标（临界）」**；④ 新增**第 11 个校验脚本** `check_coverage.py`（全 lib 口径 + 70% 硬门槛，堵 P.17 #1 口径陷阱）；⑤ CI 增 `flutter test --coverage` + 覆盖率门槛步骤（P.17 #4）；⑥ `pubspec.lock` 入库；新增 **P.18 六轮收口复核** |
| **v6.7** | 2026-09-29：**仓储实现批次**（闭环 P.13 §4-1 / §5-1）—— ① `lib/data/repositories/` **四个实现 + barrel**（favorite / history / subscription / remote_source），绑定 `DatabaseManager` / `PrefsManager` 统一返回 `Result`；② `app.dart` 组装并注入用例层（`MultiProvider`）；③ 新增 `test/data/repositories/` **4 文件**：单测 **344 → 365**（测试文件 **24 → 28**、lib **69 → 74**）；覆盖率触达 **86.4%**、全 lib 整体 **71.1%（达标）**、零触达 **24/74**；④ **修复契约漂移**（P.19 #1）：`subscription` 判重键由 `(dyname, dyurl)` 统一为 `findByUrl`（对齐 DDL `dyurl UNIQUE`）；新增 **P.19 七轮复核（3 项）** |
| **v6.8** | 2026-09-29：**文档版本治理固化** —— 新增 **D24**：文档每次变更**必须先递增修订版本号再交付 / 推送**（同步顶部变更块 + 版本历史「（现行）」行 + 计数口径）；清除 v6.6 变更块残留的「（本版）」标记（唯一性收归 v6.8）；**无代码 / 契约改动**，各项计数不变 |
| **v6.9** | 2026-09-29：**文档文件名版本化 + 守卫加固** —— 新增 **D25**：文件名须携带修订版本号（`VBOX_PLAN_v6.9.md`）且与「（现行）」行 / 「本版变更」块三处一致；**重命名主方案文档**并同步全部引用（README / Dart 注释 / CI / 守卫），旧文件名入 `DEAD_DOCS`；`check_docs_consistency.py` 新增**规则 6 / 规则 7**（版本三处一致 + D 编号唯一性与引用无悬空）；修正「唯一现行文档（D17–D20）」误引（实为 v5 文档合并结论）；**无代码 / 契约改动** |
| **v6.10** | 2026-09-29：**清账批次** —— ① 修复 `docs-guard:history` 块**缺闭合**致 L104–L3158 数值 / 路径规则静默失效的结构性漏洞（闭合后再抓 2 处陈旧键数 + 1 处旧文件名并修正）；② 守卫新增**规则 8**（`pubspec` ↔ `AppInfo` 版本一致）/ **规则 9**（禁不可验证的目录声明），并从历史标记移除过泛的「遗漏 / 冗余」、补「NN 个」写法检测；③ `AppInfo` 版本对齐 `pubspec`（`3.1621.0+1621`）、`pubspec.yaml` 移除零引用依赖 `dio` / `collection`；④ 修正 `data/repositories` / `platform/*` / `presentation/*` / `android-compat.md` / `vbox_flutter/` / `flutter/` / `app.dart` 行号等目录路径漂移；⑤ 新增 **D26**、**P.21**；旧文件名入 `DEAD_DOCS` |
| **v6.11** | 2026-09-29：**平台壳批次（三端编译门禁解锁）** —— ① 交付 `android/` `macos/` `windows/` 三端平台壳（`flutter create` 官方模板，**66 文件**，非侵入落地）；② 标识统一 **`com.vbox.player`**（Android namespace/applicationId + macOS bundle id + `MainActivity.kt` 迁移）、`minSdk` 锁 **24**；③ `flutter-check.yml` 新增 **build-android / build-macos / build-windows** 三个 build job，门禁 E.10b ③/⑤「三端编译」转为**已具备编译通道（待 CI 首跑确认）**；④ 新增 **D27**、**P.22**；文档更名 `VBOX_PLAN_v6.10.md` → `VBOX_PLAN_v6.11.md` |
| **v6.12** | 2026-09-29：**CI 首跑验证** —— Flutter Check（run `36600564607`，`f59d04e`）**5 job 全绿**（`contract-checks` / `flutter-analyze` / `build-android` / `build-macos` / `build-windows`）；门禁 **③/⑤「三端编译通过」由「待首跑确认」转为「✅ 已通过」**；修正 P.14 `pubspec.lock` 状态漂移；**无代码 / 契约 / 平台壳改动**，计数不变；文档更名 `VBOX_PLAN_v6.11.md` → `VBOX_PLAN_v6.12.md` |
| v6.13 | 2026-09-29：**P0 清障批次**（闭环 P.13 §4 #4 / #5 / #6 与 P.16 #1）—— ① 启用 `analysis_options.yaml`（`flutter_lints`）并 `dart fix --apply`（80 条告警 → `flutter analyze` 0 issues）；② 消除 DB 路径双真相源（`database_manager` 统一取 `StoragePaths.databaseFile`）；③ `prefs_manager` 接入核心层 `SecureStore` 抽象（新增 `secure_store_adapter.dart`，不再直连插件）；④ 敏感键回退读取 + 迁移（修复 iOS 迁移后 5 键首读丢值）；lib **74 → 75**、测试文件 **28 → 29**、单测 **365 → 371**、全 lib 整体 **71.1%（达标）**；新增 **P.23**；文档更名 `VBOX_PLAN_v6.12.md` → `VBOX_PLAN_v6.13.md` |
| v6.14 | 2026-09-30：**P0 前置收口批次** —— ① B1 普通分支读取防崩溃（P.16 #2 闭环：类型不符 `TypeError` → 静默回退契约默认值）；② 应用名大小写裁定**维持小写 `vbox`**（P.23 §4 #2 闭环，`app.dart` title / AppBar 对齐平台壳）；③ CmsV10 裁定「实现但未接线，暂接入待 UI 批次」+ 云盘凭据敏感标注维持现状登记（P.16 #3/#4）；④ 修正 `file_store` 已接线登记（P.13 §4 #13）；计数不变（75 / 29 / 371 / 71.1%）；新增 **P.24**；文档更名 `VBOX_PLAN_v6.13.md` → `VBOX_PLAN_v6.14.md` |
| **v6.15** | 2026-09-30：**G-01 phone 形态书架交付（第 1 轮 UI 首块）** —— ① 新增 `lib/presentation/phone/home_shelf_page.dart`（收藏 / 历史双 Tab，直连 UseCase，空态 / 重试 / 移除 / 清空确认）；② `app.dart` 按 `UiMode` 分发：phone → HomeShelfPage（desktop / tv 占位渐进交付）；③ 新增 widget 测试 **7 用例**（内存仓储 fakes 走真用例链路）；lib **75 → 76**、测试 **29 → 30**、单测 **371 → 378**、整体覆盖 **71.1% → 71.8%**、零触达 **24/76**；E.10b **G-01 部分解除**；新增 **P.25**；文档更名 `VBOX_PLAN_v6.14.md` → `VBOX_PLAN_v6.15.md` |
| **v6.16** | 2026-09-30：**G-01 phone 远程源列表交付（第 1 轮 UI 第二块）** —— ① 新增 `lib/presentation/phone/remote_source_page.dart`（清单状态卡 + 订阅管理：添加 / 重复拒绝 / 删除 / 强制刷新）；② 书架 AppBar 加「远程源」入口；③ 新增 widget 测试 **8 用例**；lib **76 → 77**、测试 **30 → 31**、单测 **378 → 386**、整体覆盖 **71.8% → 73.1%**、零触达 **24/77**；E.10b **G-01 继续解除**；新增 **P.26**；文档更名 `VBOX_PLAN_v6.15.md` → `VBOX_PLAN_v6.16.md` |
| **v6.17** | 2026-09-30：**G-01 desktop 形态交付（第 1 轮 UI 第三块）+ 共享视图抽取** —— ① 新增 `lib/presentation/widgets/library_views.dart`（FavoritesView / HistoryView 抽取为三形态共享组件）；② 新增 `lib/presentation/desktop/desktop_home_page.dart`（NavigationRail 宽屏布局，内嵌远程源）；③ `app.dart` desktop 占位解除；④ 新增 widget 测试 **5 用例**；lib **77 → 79**、测试 **31 → 32**、单测 **386 → 391**、整体覆盖 **73.1% → 73.2%**、零触达 **24/79**；E.10b **G-01 继续解除**（仅余 TV）；新增 **P.27**；文档更名 `VBOX_PLAN_v6.16.md` → `VBOX_PLAN_v6.17.md` |
| **v6.18** | 2026-09-30：**G-01 tv 形态交付（第 1 轮 UI 收官）** —— ① 新增 `lib/presentation/tv/tv_home_page.dart`（T.7 焦点规范：FocusTraversalGroup + TabBar autofocus，三 Tab 导航复用共享视图）；② `app.dart` tv 占位解除，**三形态全部交付**；③ 新增 widget 测试 **5 用例**；lib **79 → 80**、测试 **32 → 33**、单测 **391 → 396**、整体覆盖 **73.2% → 73.5%**、零触达 **24/80**；E.10b **G-01 UI 三形态解除**（TV D-pad 归 G-10 人工验收）；新增 **P.28**；文档更名 `VBOX_PLAN_v6.17.md` → `VBOX_PLAN_v6.18.md` |
| **v6.19** | 2026-09-30：**G-03 可行性评估登记（不改码）** —— 5 引擎 × 三端可行性矩阵（Node/NodeLX 桥 + Python 桥纯 Dart 可交付，QuickJS 需 FFI 原生，JSC 三端不可用）；关键判断（ABI 收敛差异、运行时分发为最大风险）；推荐路线 G-03-A（引擎工厂 + 双桥 + ABI conformance）→ G-03-B（QuickJS FFI + 分发方案待决策）；**计数不变**（80 / 33 / 396 / 73.5% / 24/80）；新增 **P.29**；文档更名 `VBOX_PLAN_v6.18.md` → `VBOX_PLAN_v6.19.md` |
| v6.20 | 2026-09-30：**G-02 平台插件层可行性评估登记（含播放器插件）+ 门禁编号纠偏（不改码）** —— 三端插件矩阵（Android Media3+libVLC 纯 Gradle 零 NDK / macOS AVPlayer 零原生依赖 / Windows libmpv 需 dll）；播放器回退路径三端齐备（A21.5）；**编号纠偏**（G-06=iOS 参照已✅、G-07=编译环境已✅，播放器属 G-02；E.10b 余项 = G-02 / G-03 / G-05 / G-09 / G-10）；推荐 G-02-A（Dart PlayerController + Android 接线，CI 可验）→ G-02-B（libmpv 分发待决策）；**计数不变**（80 / 33 / 396 / 73.5% / 24/80）；新增 **P.30**；文档更名 `VBOX_PLAN_v6.19.md` → `VBOX_PLAN_v6.20.md` |
| **v6.21** | 2026-09-30：**G-03-A 桥接协议层交付（G-03 从「未开始」推进到「桥接协议层交付」）** —— ① 交付 `lib/platform/spider/` **6 文件**（ABI 编解码 / Node·NodeLX HTTP 桥 / Python 子进程桥 / 引擎工厂 / Node 客户端 / barrel），引擎差异收敛到适配层，三引擎走 ABI 统一编解码；② 新增 **4 个测试文件 / 27 用例**（ABI 7 / Node 桥 7 / Python 桥 8（真实 python3 子进程）/ 工厂 5）；③ 本机全量校验：analyze 0 issues · 423 用例全通过 · conformance 45/45 · 11 守卫全绿（触达 86.9%、整体 **74.0% 达标**、零触达 25/86）；④ 计数：lib **80 → 86**、测试 **33 → 37**、单测 **396 → 423**、整体 **73.5% → 74.0%**、零触达 **24/80 → 25/86**；⑤ E.10b **G-03 部分解除**（G-03-A 交付，G-03-B 待决策）；新增 **P.31**；文档更名 `VBOX_PLAN_v6.20.md` → `VBOX_PLAN_v6.21.md` |
| **v6.22** | 2026-09-30：**G-02-A 平台插件层首批交付（G-02 从「未开始」推进到「部分解除」）** —— ① 交付 `lib/platform/player/` **4 文件**（通道桥 / 通道播放器 / 统一控制层 PlayerController / barrel），对齐 iOS `PlayerEngine` 协议与契约 §2.5 / A21.5 回退策略；② Android 接线（`PlayerPlugin.kt` Media3 主后端双通道 + `CodecCapability.kt` A21.5 selectBackend + Gradle 依赖 + MainActivity 注册；libVLC 回退实现在 G-02-B/C）；③ 新增 **2 个测试文件 / 15 用例**；④ 修复 `PlayerController` 误标 `@override` 与 `CodecCapability.kt` 缺导入两处缺陷；⑤ 计数：lib **86 → 90**、测试 **37 → 39**、单测 **423 → 438**、零触达 **25/86 → 26/90**（新增 barrel `player.dart` 零触达属预期）；⑥ E.10b **G-02 部分解除**（G-02-A 交付，G-02-B/C 待决策）；新增 **P.32**；文档更名 `VBOX_PLAN_v6.21.md` → `VBOX_PLAN_v6.22.md` |
| **v6.23** | 2026-09-30：**第 1 轮（核心骨架）全面检查报告交付** —— ① 新增 `contract/docs/stage_check_report_stage1.yaml`（E.10b.2 六类扫描逐项：契约 ✅ / 数据 ✅ / 平台差异 ⚠️ / 功能 ⚠️ / 质量 ✅ / 交付 ✅）；② **verdict: blocked**（第 1 轮 70% 进行中，D20 不得标记完成、不得进入第 2 轮；阻断 G-02-B/C / G-03-B / G-05 / G-09 / G-10 / 详情页·播放入口接线）；③ 计数不变（90 / 39 / 438（静态声明））；conformance 45/45 + 守卫 10/10 本地实测；④ 文档更名 `VBOX_PLAN_v6.22.md` → `VBOX_PLAN_v6.23.md`；下一批 = G-02-B |
| **v6.24** | 2026-09-30：**G-02-B / G-03-B 平台插件与 Spider 运行时交付（三端决策 D28/D29 定稿）** —— ① **G-02-B-1 macOS AVPlayer 接线交付**：`macos/Runner/PlayerPlugin.swift`（AVFoundation 主后端，MethodChannel `com.vbox.player/player` + EventChannel `.../player/events`，open/play/pause/seekTo/setVolume/setSpeed/dispose + state/progress/error 事件流，A21.5 复杂封装（MKV/FLV/TS/RMVB/AVI/WMV/M2TS）返回 `E_BACKEND_UNAVAILABLE` 供降级链捕获）+ `MainFlutterWindow.swift` 手动注册 + `project.pbxproj` 纳入 Swift 编译；② **D28 libmpv 原生二进制分发决策**：**原生二进制不入 git 仓库**，由构建脚本从 GitHub Release 资产下载（沿用 iOS `mpvkit-deps-0.0.1` 模式，新增 `libmpv-{os}-{arch}-{ver}` 资产），随 DMG/EXE 侧载产物分发（D11）；CI 仅验证下载 + 链接（smoke），端到端回退真机验收归 G-02-C；③ **G-03-B-1 QuickJS FFI 绑定交付**：`quickjs/wrapper.{h,c}`（纯 C 封装 `vq_create_runtime/vq_create_context/vq_eval/...`，三端可编译）+ `scripts/build_quickjs_wrapper.sh`（产物 `libvbox_quickjs.{so,dylib,dll}`）+ CI 新增 `build-native-quickjs` job（ubuntu gcc 实测编译通过）；④ **G-03-B-2 QuickJS 引擎交付**：`lib/platform/runtime/` **3 文件**（`quickjs_ffi.dart` / `quickjs_bridge_engine.dart` / barrel `runtime.dart`）+ `spider_engine_factory.dart` quickJS 分派接入（javaScriptCore 仍抛 unimplemented，iOS 原生保留）；⑤ **D29 Node/Python 运行时分发决策**：**Python 三端内置 + 桌面系统探测**（Android 用 Chaquopy Gradle 依赖零 NDK / iOS 原生 python-stdlib 3.14 / 桌面探测系统 python3，缺失 → `E_BACKEND_UNAVAILABLE`）；**Node 仅桌面系统探测 + iOS 原生常驻**（Android NodeMobile 嵌入成本高，登记待评估）；**不采用首次下载**（D11 侧载无商店更新通道，运行时网络依赖与校验不可控）；⑥ 测试：新增 `test/platform/runtime/quickjs_bridge_engine_test.dart`（**13 用例**）+ 工厂测试更新（5 → 6 用例）；静态用例 **436 → 450**、测试文件 **39 → 40**、lib 文件 **90 → 93**；⑦ E.10b：**G-02 继续解除**（余 G-02-C 需真机）、**G-03 继续解除**（QuickJS 顶替 JSC 落地）；余项 = **G-02-C / G-05 / G-09 / G-10 / 详情页·播放入口接线**；新增 **P.33（G-02-B 交付复核）/ P.34（G-03-B 交付复核）**；文档更名 `VBOX_PLAN_v6.23.md` → `VBOX_PLAN_v6.24.md`；下一批 = G-02-C（真机前置）或 G-05（零触达收尾） |
| **v6.51（现行）** | 2026-10-08：**文档口径修正 —— 明确「本机不安装 Flutter SDK」** —— Trae 沙箱按会话创建、工作区不跨会话保留，本地安装 Flutter SDK **无法留存**，且会诱导每个新会话重复下载安装数 GB；统一口径：本机**不安装**，Dart 编译 / 静态分析 / 单测 / 构建一律由 CI（`flutter-check.yml`，Flutter 3.47.5）承担；落点 = 本方案 P.7 / A.4 + `README.md` + `docs/后期开发方案_v1.1~v1.4.md` + 第 1 轮检查报告 / WBS / UI 对齐前置；**无代码 / 契约 / 计数改动**；文档更名 `VBOX_PLAN_v6.50.md` → `VBOX_PLAN_v6.51.md` |
| **v6.50** | 2026-10-03：**批次 H 续段 —— H-04 福利三重隔离 + 守卫** —— ① 领域 `lib/domain/entities/welfare/welfare_isolation.dart`（`WelfareIsolationPolicy`：`normalizeScriptPath` + `isAllowedScriptPath`（`contains("sources/welfare-js/") || hasPrefix("welfare-js/")`，对齐 iOS `WelfareSpiderLoader.isAllowedWelfareScriptPath`）+ `isWelfareSpider` / `satisfiesTripleIsolation`（仅 `welfare_spider`）/ `violationFor` / `violationsForAll`）+ 修改 `welfare_platform_config.dart`（`WelfarePlatform` 增 `api` + 三可见字段（缺省 false）+ `copyWith`）；② 表现 `welfare_platform_router.dart`（`welfare_spider` 分支前置隔离校验，违规 → 未支持页）；③ 守卫 `scripts/check_welfare_isolation.py`（6 项：契约 allOf / 领域层一致性 / 模型解析 / 路由接入 / sources 越界扫描 / 普通 Spider 链路引用，`--selftest` 负向自测）；④ 测试 1 新文件 / 17 用例 + 路由 2 用例；⑤ 自检：`flutter analyze` **0 issue** · `flutter test` **1634 全通过**（1607 → 1634）· **14 守卫脚本全绿**（新增福利隔离守卫，文档一致性 0 漂移）；⑥ 文档更名 `VBOX_PLAN_v6.49.md` → `VBOX_PLAN_v6.50.md`（任务级 WBS v1.25 → v1.26、开发方案 v2.20 → v2.21）；⑦ 交付边界：三重隔离策略层 + 运行时拦截 + CI 守卫三层落地，脚本实际加载 / 引擎执行归 H-03 |
| **v6.49** | 2026-10-03：**批次 H 续段 —— H-02 福利平台路由（5 类 serviceType + 基类抽象）** —— ① 领域 `lib/domain/entities/welfare/welfare_service_type.dart`（`WelfareServiceType` 枚举：8 已知 case + `unknown` 兜底，`fromRaw` 未命中回退 `unknown` 不兜底，对齐 iOS `WelfarePlatformConfig.swift` L268-L284）+ 修改 `welfare_platform_config.dart`（`WelfarePlatform` 增 `scriptType` + `service`/`isJavaScriptSpider`/`primaryHost`）+ `lib/domain/services/fuli_base_service.dart`（`FuliContentCategory` + `FuliBaseService` 基类 + `FuliBaseServiceRegistry` 注册表，对齐 iOS `FuliPlatformService.swift`）；② 表现 `lib/presentation/welfare/welfare_platform_router.dart`（`WelfareRoute` 密封类族 + `WelfarePlatformRouter.resolve`：原生专用 × 3 / `aidan_video` / `fuli_base`（查注册表，未注册 → 未支持）/ `remote_cms_v10` / `welfare_spider`（JS / 非 JS 分流）/ `python_spider` / `unknown` → 未支持）+ `lib/presentation/pages/welfare/unsupported_platform_page.dart`（对齐 iOS `UnsupportedPlatformView.swift`）；③ 接线 `welfare_home_page.dart`（平台点击经路由器）+ `vbox_welfare.dart`（`VboxWelfarePlatform` 增可选 `platformKey`）；④ 测试 1 新文件 / 10 用例 + 页面 2 用例；⑤ 自检：`flutter analyze` **0 issue** · `flutter test` **1618 全通过**（1607 → 1618）· 13 守卫脚本全绿 · UI 令牌 / Dart 导入守卫通过；⑥ 文档更名 `VBOX_PLAN_v6.48.md` → `VBOX_PLAN_v6.49.md`（D25，并补记 v6.48 内容；任务级 WBS v1.24 → v1.25、开发方案 v2.19 → v2.20、UI 对齐 v1.9 → v1.10）；⑦ 交付边界：`fuli_base` 路由抽象面（基类 + 注册表 + 路由描述），目标页面与原生平台服务实现随后续批次 |
| **v6.48** | 2026-10-03：**批次 H 首段 —— H-01 平台配置加载 + H-06 三栏目 + 平台网格页**（v6.48 文件名于交付时已重命名、内容于 v6.49 一并补记） —— ① H-01：领域 `lib/domain/entities/welfare/welfare_platform_config.dart`（`WelfarePlatformCategory`（video/live/comic）+ `WelfarePlatform` + `WelfarePlatformCategoryMeta` + `WelfarePlatformConfig` 严格 `tryParse`，对齐契约 `welfare_v1.json`）+ 数据源 `lib/data/datasources/remote/welfare_platform_datasource.dart`（manifest → 平台配置 + 代理降级链）+ 本地缓存 `lib/data/datasources/local/welfare_platform_cache.dart` + 控制器 `lib/presentation/welfare/welfare_platform_controller.dart`；② H-06：页面 `lib/presentation/pages/welfare/welfare_home_page.dart`（三栏目 + 4 列平台网格 + 加载/失败/空态）+ `welfare_gate_page.dart` 门控接线 + `app.dart` 注册；③ 测试 4 文件 / **35 用例** + 金色基线 `welfare_live_portrait`（SSIM 0.819）；④ 自检：`flutter analyze` **0 issue** · `flutter test` **1607 全通过**（1572 → 1607）· 覆盖率 **78.0%** · 11 守卫全绿 · conformance **83/83** · 视觉门禁 exit 0；⑤ 文档更名 `VBOX_PLAN_v6.47.md` → `VBOX_PLAN_v6.48.md`（任务级 WBS v1.23 → v1.24、开发方案 v2.18 → v2.19） |
| **v6.47** | 2026-10-03：**批次 G 首段 —— G-01 音乐（队列 + 迷你播放器）** —— ① 领域 `lib/domain/entities/music/music.dart`（`MusicPlatform` 五平台（网易云 / QQ / 酷狗 / 酷我 / 咪咕）+ `MusicQueueItem`（队列项 + 8 扩展字段 + JSON 容错往返））+ `music_queue.dart`（`MusicQueue` 纯逻辑：`setQueue` / `addToQueue` 去重 / `removeFromQueue`（移除当前项 → stop 语义清空）/ `replaceCurrent` 保留索引与进度 / `next` / `previous`（>3s 回本曲开头）/ `current` / `isEmpty` / `isNotEmpty`，对齐 iOS `AudioPlayerManager`）；② 数据 `lib/data/datasources/local/music_queue_store.dart`（落契约键 `music_queue_items` + `music_queue_index`，非法 JSON / 越界索引容错）；③ 平台 `lib/platform/player/music_player.dart`（`MusicAudioEngine` 抽象 + `UnavailableMusicAudioEngine` + `MusicPlayerController` 队列状态机：自动连播 / 连续失败保护 / 进度回补 / 落盘 / `restore`）；④ 表现 `lib/presentation/widgets/music/mini_player.dart`（`MiniPlayerBar` 320×60 + `MiniPlayerCloseButton`：封面 / 歌名 / 进度 / 播放暂停 / 下一首，左滑关闭 · 右滑折叠胶囊 · 点击展开，`OverflowBox + ClipRect` 防过渡溢出，对齐 iOS `MusicPlayerViews.swift:11`）；⑤ 测试 4 文件 / **54 用例**（领域+存储+播放器 46 · 组件 8）；⑥ 自检：`flutter analyze` 0 issues · `flutter test` **1527 全通过**（1473 → 1527）· 13 守卫脚本全绿 · UI 令牌 / Dart 导入守卫通过；⑦ 交付边界：G-01 首段（队列 + 状态机 + 迷你浮层），音乐页 / 全屏播放器 / 五平台内容服务留待 G-01 续段 |
| **v6.46** | 2026-10-03：**批次 F 收官 —— F-09 PG 自动化 + F-10 批次自检** —— ① 领域 `lib/domain/entities/cloud/pg_auto.dart`（`PgVodQuality`（五档画质：原画 4K `4kz|auto` / 高清 FHD / 高清 HD / 标清 SD / 流畅 LD + `fromFlags` 前缀解析）+ `PgAutoConfig`（9 契约键：`enabled`/`isVip`/`threadLimit`/`threadNight`/`vodFlags`/`transferDir`/`autoCleanup`/`cleanupDelaySeconds`/`proxyPort` + `defaults`/`copyWith`）+ `PgAutoRules`（`resolvedVodFlags` 空串回退 `4kz|auto` · `resolvedTransferDir` 空串回退 `vbox_pg_temp` · `isNightWindow`（19–23 时）· `currentThreadLimit`（非 VIP 收敛 1；VIP 夜间取夜间线程）· `cleanupDelay` · `shouldScheduleCleanup` · `proxyUrl`）+ `PgCredentialMark`（`pg_source=qr_scan`），对齐 iOS `AliyunPgConfig` / `PgPlayConfigSection`）；② 数据 `lib/data/datasources/local/pg_auto_store.dart`（`PgAutoStore`：`load`/`save`/`reset`，落 9 契约键 `pg_ali_*`，缺省按契约补齐）；③ 表现 `lib/presentation/pages/cloud/pg_auto.dart`（`PgAutoPage`：路链开关 + 播放参数（VIP → 线程 Stepper + 画质）+ 转存目录（目录 + 自动清理 + 延迟 + 代理端口）+ **当前生效卡** + 恢复默认 / 保存，对齐 iOS `AliyunPgConfigView`）；④ 测试 3 文件 / **29 用例**；⑤ 自检：`flutter analyze` 0 issues · `flutter test` **1473 全通过** · 13 守卫脚本全绿；⑥ 文档更名 `VBOX_PLAN_v6.45.md` → `VBOX_PLAN_v6.46.md`（任务级 WBS v1.20 → v1.21、开发方案 v2.16 → v2.17）；⑦ 交付边界：PG 自动化配置（领域 + 存储 + 设置 UI）+ 9 契约键接线，阿里 PG 4kz 播放编排（线程池实转 + 代理起服）归真机联调（D28） |
| **v6.45** | 2026-10-03：**批次 F 第七段 —— F-08 网盘播放 pan 模式** —— ① 领域 `lib/domain/entities/cloud/node_pan.dart`（`NodePanPaths`（`/spider/push/4/detail` + `/spider/push/4/play`）+ `NodePanEntry`（base64 播放 ID + 展示名）+ `NodePanShare` / `NodePanPlayData` + `NodePanErrorKind`（三档）+ `NodePanException`（`displayMessage`）+ `NodePanRouting`（10 家 Node 托管盘 `managedProviders` + `isNodeManaged`）+ `NodePanParser`（`vod_play_url` 名`$`id 解析 + base64 JSON 取名），对齐 iOS `NodePanResolver.swift`）+ `lib/domain/entities/cloud/cloud_play_item.dart`（`CloudPlayItem`（统一缓存条目 + `cacheKey`/`hasPlayURL`/`isExpiredAt`/`copyWith`/JSON 往返）+ `CloudPlayItemSummary` + `CloudPlayItemCache`（键 `provider|sourceKey` · 上限 **260** · `invalidate`/`clearExpired`/`clear`/`summary`），对齐 iOS `CloudDriveManager.CloudPlayItem` / `cloudPlayItemCacheKey` / `storeUnifiedCloudPlayItem` / `invalidateUnifiedCloudPlayItem` / `clearExpiredUnifiedCloudPlayItems` / `clearUnifiedCloudPlayItems` / `cloudPlayItemSummary`）；② 数据 `lib/data/datasources/remote/node_pan_client.dart`（`NodePanTransport` 接缝 + `UnavailableNodePanTransport` + `LocalNodePanTransport`（`127.0.0.1:58080`，分享清洗去零宽字符）+ `NodePanClient`：`resolveShare`/`resolvePlay`）+ `lib/data/datasources/local/cloud_play_item_cache_store.dart`（契约键 `cloud_play_item_cache_v1`：`load`/`save`/`store`/`invalidate`/`clearExpired`/`clear`/`summary`）；③ 平台 `lib/platform/player/pan_player.dart`（`PanPlayChannel` 四档路由判定 + `PanPlayer`：分享解析 / 播放地址 / 统一缓存 / **显式 pan 路由**打开 + `_guardChannel` 通道守卫）+ `lib/platform/player/player_controller.dart`（`open` 增可选 `route` 显式路由覆盖）；④ 测试 5 文件 / 51 用例；⑤ 自检：`flutter analyze` 0 issues · `flutter test` **1444 全通过** · 13 守卫脚本全绿 · conformance **83/83**；⑥ 文档更名 `VBOX_PLAN_v6.44.md` → `VBOX_PLAN_v6.45.md`（任务级 WBS v1.19 → v1.20、开发方案 v2.15 → v2.16）；⑦ 交付边界：Node 托管盘 pan 播放全链路，阿里 PG 4kz / 原生盘路链 `_guardChannel` 明确报错留待 F-09 接线（D28） |
| **v6.44** | 2026-10-03：**批次 F 第六段 —— F-07 文件列表 / 转存 / 清理队列** —— ① 领域 `lib/domain/entities/cloud/cloud_drive_files.dart`（`CloudDriveFileEntry`（`isVideo` 扩展名判定 + 文件夹优先 `compareTo` + JSON 兼容 `fileId`/`fsId`/`fid`）+ `CloudDriveCleanupItem`（去重键 `drive|tokenName|fileId`）+ `CloudDriveCleanupQueue`（`enqueue` 去重 / 空 fileId 忽略 / 上限 300 保留最新；`due` / `groupByDrive` / `remove`，对齐 iOS `CloudDriveManager.CleanupQueueItem` 与 `enqueueCleanup` / `flushCleanupQueue`）+ `CloudDriveTransferResult`）；② 数据 `lib/data/datasources/local/cloud_drive_cleanup_queue_store.dart`（契约键 `cloud_drive_cleanup_queue_v1`，`load`/`save`/`enqueue`/`due`/`removeDue`/`count`/`clear`，默认延迟 180s）；③ 表现 `lib/presentation/pages/cloud/files_controller.dart`（`CloudDriveFileLister` 接缝 + 控制器：目录列举 / 排序 / 面包屑 / 转存入队 / 立即清理）+ `lib/presentation/pages/cloud/files.dart`（文件列表页：刷新 + 面包屑 + 文件行 + 清理队列卡）；④ 测试 3 文件 / 29 用例；⑤ 自检：`flutter analyze` 0 issues · `flutter test` **1393 全通过** · 13 守卫脚本全绿；⑥ 文档更名 `VBOX_PLAN_v6.43.md` → `VBOX_PLAN_v6.44.md`（任务级 WBS v1.18 → v1.19、开发方案 v2.14 → v2.15） |
| **v6.43** | 2026-10-03：**批次 F 第五段 —— F-05 B站扫码 + 百度专用代理** —— ① 领域 `lib/domain/entities/cloud/bili_auth.dart`（`BiliAuthStatus` 五态 + `fromWire`（`waiting` + msg「已扫码」合并为 scanned）+ `BiliQrStart` + `BiliAuthPaths` + `BiliAuthException`，对齐 iOS `BiliAuthManager.swift`）+ `lib/domain/entities/cloud/baidu_proxy.dart`（`BaiduProxyEndpoints` + `BaiduProxySigner`（HMAC-SHA256 小写 hex）+ `BaiduProxyPlayData` / `BaiduProxyResponse` + `BaiduProxyException`，对齐 iOS `BaiduProxyClient.swift`）；② 数据 `lib/data/datasources/remote/bili_auth_client.dart`（`BiliAuthTransport` 接缝 + `UnavailableBiliAuthTransport` + `LocalBiliAuthTransport`（`127.0.0.1:58080`，3 次退避）+ `BiliAuthClient`）+ `lib/data/datasources/remote/baidu_proxy_client.dart`（`BaiduProxyTransport` 接缝 + `HttpBaiduProxyTransport` + `BaiduProxyClient` + `BaiduPcsDeviceId` 落契约敏感键 `baidu_local_pcs_device_id`）；③ 表现 `lib/presentation/pages/cloud/node_login_gateway.dart`（`NodeCloudDriveLoginGateway` + `defaultCloudDriveLoginGateway` 工厂，`login_sheet.dart` 三处缺省网关接入）；④ 测试 5 文件 / 51 用例（含 HMAC 固定向量回归锚点 + PCS 设备指纹持久化）；⑤ 文档更名 `VBOX_PLAN_v6.42.md` → `VBOX_PLAN_v6.43.md`（任务级 WBS v1.17 → v1.18、开发方案 v2.13 → v2.14）；⑥ 交付边界：API 契约 + 网关接线交付，端到端扫码真机联调待 Node 就绪（D28） |
| **v6.42** | 2026-10-03：**批次 F 第四段 —— F-04 阿里 extscreen 加密链路** —— ① 领域 `lib/domain/entities/cloud/aliyun_extscreen.dart`（`ExtscreenCrypto`：设备指纹参数字典 · `h()` 字符变换 · MD5 密钥派生 · AES-256-CBC 加解密 · SHA-256 签名 · 请求头 + `ExtscreenException`，逐档对齐 iOS `ExtscreenCrypto.swift`）；② 数据 `lib/data/datasources/remote/aliyun_extscreen_client.dart`（`ExtscreenTransport` 传输接缝 + `CoreExtscreenTransport` + `ExtscreenApiClient`：`getTimestamp` / `getQrcode` / `pollQrcodeStatus` / `getRefreshToken` / `refresh` / `makeCrypto` + `ExtscreenToken`，对齐 iOS `ExtscreenAPIClient.swift`）；③ 测试 2 文件 / 28 用例（加密链路 15 含固定输入密钥与签名回归锚点 + 客户端 13 替身传输驱动）；④ 自检：`flutter analyze` 0 issues · `flutter test` **1313 用例全通过** · 13 守卫脚本全绿；⑤ 文档更名 `VBOX_PLAN_v6.41.md` → `VBOX_PLAN_v6.42.md`（任务级 WBS v1.16 → v1.17、开发方案 v2.12 → v2.13）；⑥ 交付边界：原生扫码接入 UI 的二维码渲染留待 F-05 一并接线 |
| **v6.41** | 2026-10-03：**批次 F 第三段 —— F-02 登录模式收官（网页兜底 + Node 账号）+ F-03 Node 凭据同步** —— ① F-02 余项：`CloudDriveWebLogin`（官方登录页 URL 映射 + `credentialHint`）· `CloudDriveWebLoginSheet`（`url_launcher` 拉起系统浏览器 + 复制链接 + Token/Cookie 粘贴 + 落安全存储）· `CloudDriveAccountLoginSheet`（Node 账号 / 密码）· 控制器 `loginWithAccount` · `auth_center` 登录后刷新；② F-03：`node_credential_sync.dart`（11 家托管盘字段映射 / 7 家拉取映射 / 槽位读写 / 摘要）+ `node_credential_sync_service.dart`（`NodeCredentialApiClient` 接缝 + push/pull/级联删除 + `syncNow`，落 `cloud_drive_credentials_v1`）；③ 测试 2 文件 / 25 用例；④ 自检 analyze 0 · test **1285 全通过** · 13 守卫全绿；⑤ 文档更名 `VBOX_PLAN_v6.40.md` → `VBOX_PLAN_v6.41.md`（任务级 WBS v1.15 → v1.16、开发方案 v2.11 → v2.12） |
| **v6.40** | 2026-10-03：**批次 F 第二段 —— F-02 登录模式首段（登录态机 + 网关接缝 + 扫码 / 短信验证码登录 Sheet）** —— ① 领域层 `cloud_drive_login.dart`（六登录方式 / 八会话阶段 / 六配色档，对齐 iOS `qrLoginState` 与 `NodeGuangyaSMSLoginView`）；② 表现层 `login_gateway.dart`（网关抽象 + 缺省未就绪实现）· `login_controller.dart`（扫码轮询态机 + 短信 60s 冷却 + 取消幂等）· `login_sheet.dart`（扫码 Sheet + 短信验证码 Sheet + 共享子组件）· 授权中心动作接入 `openCloudDriveLoginSheet` · 新增颜色令牌 `VboxColors.pending`；③ 测试 3 文件（领域 / 控制器 / Widget）；④ 文档更名 `VBOX_PLAN_v6.39.md` → `VBOX_PLAN_v6.40.md`（任务级 WBS v1.14 → v1.15、开发方案 v2.10 → v2.11） |
| **v6.39** | 2026-10-03：**批次 D 收口 + 批次 E 全交付（E-01~E-06）+ 批次 F 首段（F-01 / F-06）** —— ① 批次 D 收口（D-04 短剧 / D-05 详情页扩展 / D-07 源发现 / D-08 批次自检）；② 批次 E 全交付直播域（E-01 直播页 / E-02 播放接入 / E-03 EPG / E-04 自定义源导入导出 / E-05 MDTV 子系统 / E-06 批次自检）；③ 批次 F 首段网盘（F-01 授权中心页 + F-06 排序页 + 云盘凭据安全存储 + 底部导航「网盘」入口 + `mdtv_crypto` AES Rcon 越界修复）；④ 文档更名 `VBOX_PLAN_v6.38.md` → `VBOX_PLAN_v6.39.md`（任务级 WBS v1.13 → v1.14、开发方案 v2.9 → v2.10） |
| **v6.38** | 2026-10-02：**批次 C 全交付（C-01~C-12）+ 批次 D 首段（D-01 / D-02 / D-03 / D-06）** —— ① 批次 C 播放器核心链全交付（路由/后端/控制层 UI/弹幕/四菜单/自动连播+PiP+后台+长按倍速/回退可观测/转封装/字幕/投屏·浮窗/Go 代理三端/Windows 插件/URL 探测·后端矩阵）；② 批次 D 首段内容浏览 UI（D-01 首页 / D-02 搜索 / D-03 豆瓣 / D-06 分类网格）；③ 自检：`flutter analyze` 0 · `flutter test` **1061 全通过** · 覆盖率 **80.4% ≥ 70%** · 守卫全绿 · 零触达 2 个（`app.dart` / `main.dart`）；④ 文档更名 `VBOX_PLAN_v6.37.md` → `VBOX_PLAN_v6.38.md`（任务级 WBS v1.8 → v1.9、开发方案 v2.8 → v2.9） |
| **v6.34** | 2026-10-01：**第 2 轮批次 A「设计基座」续交付（A-05 / A-06）** —— ① **形态模型改造**（A-05）：`UiMode{phone,tv,desktop}` 三形态 → `UiForm{portrait,landscape}` 双形态 + `InputModality{touch,remote,mouseKeyboard}`（只加焦点 / 交互反馈层，不改版式）；`UiFormResolver` 四级判定（用户开关 → 平台特征 → 最短边 ≥600dp → 方向）+ `UiFormController.resolveAt` 响应式注入 `MediaQuery` 视口（不在 build 改状态）+ `UiFormPlatform` 可注入隔离平台分支；`app.dart` `_RootRouter` 过渡映射（A-08 前临时载体）；② **契约键**（A-06）：新增 `app_ui_form_override`（`_group_app_settings`，string，`userdefaults`，默认 `auto`；D17 门禁主动扩键，**非 iOS 来源**），契约 **v1.3 → v1.4**、键数 **98 → 99**（`_group_app_settings` 4 → 5），Dart 镜像 + `prefs_manager.uiFormOverride()` + `check_contract_sync` 同步；③ 键数口径 98 → 99 逐处订正（§2.4 / §2.7 / §C.1 / §C.3 / E.10b / P.3 / P.6 / P.8 / P.10 / 目录树 / D17），§2.4「仅为占位」注记订正为 **A-05 已交付**；④ 计数：lib **125** / 测试 **57** / 静态用例 **600 → 614** / 守卫 **12** / conformance **45/45**（A-05 / A-06 均改造，无新增文件）；⑤ 运行时验证（analyze / test）留待 CI 首跑；文档更名 `VBOX_PLAN_v6.33.md` → `VBOX_PLAN_v6.34.md` |
| **v6.33** | 2026-10-01：**第 2 轮批次 A「设计基座」首批交付（A-01 / A-02 / A-03 / A-04 / A-11）** —— ① 设计令牌 `lib/presentation/theme/tokens/` **5 文件**（colors / typography / radii / spacing / shadows；字号 10 档、圆角档位 {4,6,8,10,12,14,16,20}）；② 主题工厂 `vbox_theme.dart`（iOS `preferredColorScheme` 等价口径）+ 皮肤控制器 `vbox_skin_controller.dart`（消费 `app_skin_mode` / `app_skin_follows_system`），`app.dart` 接线 theme / darkTheme / themeMode；③ 统一组件库 `lib/presentation/widgets/vbox/` **11 文件**（Card / Chip / SectionHeader / EpisodeChip / Button / Toast / Nav / Dialog / PosterCard / SourceBadge + barrel）；④ 新增 UI 守卫 `check_ui_tokens.py`（R-2 / R-3 / R-4）→ **校验脚本 11 → 12**；⑤ 测试 **+5 文件 / +47 静态用例**；⑥ 计数（`git ls-files` 实测口径）：lib **125** / 测试 **57** / 静态用例 **600** / 守卫 **12** / conformance 45/45；⑦ 订正 lib / 测试计数旧口径（100 / 46 与实测基线 106 / 52 不符）；⑧ 运行时验证（analyze / test / 覆盖率）留待 CI 首跑；文档更名 `VBOX_PLAN_v6.32.md` → `VBOX_PLAN_v6.33.md` |
| **v6.32** | 2026-10-01：**Spider 引擎口径落定（新增 D31）+ 订正三处残留漂移**（**文档批次**，无代码 / 契约改动，计数不变：100 / 46 / 555 / 73.6% / 11 / 45-45）—— ① 新增 **D31**：**三端（Android / Windows / macOS）均集成 JavaScriptCore** 作为 JS 站点脚本**主引擎**，QuickJS 保留为**降级备份**；依据：iOS `SpiderManager` 实为「**JSC 主 / QuickJS 降级**」，且 JSC 桥在 **GBK·Big5 编码链 / `sslBypass` / `atob`·`btoa` / `console`·`print` / `req` / 对象式 `options`** 共 6 项上强于 QuickJS 桥（该 6 项与引擎选择无关）；代价集中于 **Windows** → 设 **Q-01 门禁**，不通过即降级为「Windows 用 QuickJS」并回老板确认；② 订正顶部**文件名沿革链**（长期停在 v6.30「当前版」，与 v6.31 不符）；③ 订正正文「决策记录追加」表残留的「**D20 第 1 轮不可标记完成**」（与 D30 修订后的 D20 相矛盾）；④ 订正第 1 轮检查报告残留计数 / 进度口径（用例 504 → **555** · 覆盖 76.1% → **73.6%** · 进度 73% → **100%（代码侧）**）并补 **D31** 条目；文档更名 `VBOX_PLAN_v6.31.md` → `VBOX_PLAN_v6.32.md`，检查报告同步更名 `_v6.31.md` → `_v6.32.md` |
| **v6.31** | 2026-10-01：**真机验收排期修订（G-09 / G-10 整体后移至第 2 轮末，新增 D30）** —— ① 依据：第 1 轮代码侧已全部交付，唯一余项 **G-09**（侧载链路 / 自更新 / 播放器回退真机）/ **G-10**（TV 焦点与遥控真机）均为**真机人测**（D8）；第 2 轮功能补全（搜索 / 直播 / 网盘 / Spider / 播放器）后再测更完整；② **修订 D20**：第 1 轮完成判定 = **代码侧交付 + 自动化门禁（E.10b 六类扫描）通过**；新增 **D30**（真机验收整体后移至第 2 轮末）；③ E.7 第 1 轮人测改为「**延后**」、第 2 轮人测改为「**全功能 + TV 遥控 + 老设备 + G-09/G-10 全量真机**」，E.10b.5 检查重点同步；④ `stage_check_report_stage1.yaml` verdict **blocked → pass**（真机类检查项后移登记），检查报告更名 `第1轮核心骨架全面检查报告_v6.30.md` → `_v6.31.md`，`docs/真机验收清单_G09_G10.md` 范围标注改「第 2 轮末」；⑤ 风险登记：地基类问题（安装链路 / 播放器回退 / TV 焦点）**延后暴露**，真机批次优先覆盖地基项；文档更名 `VBOX_PLAN_v6.30.md` → **`VBOX_PLAN_v6.31.md`**（D25）；下一批 = 第 2 轮功能补全（含 UI 令牌层 G1/G2） |
| **v6.30** | 2026-10-01：**CI 反馈修复第二轮（flutter test 2 处失败清零）** —— ① v6.29 重推（`70e231e`）后 Flutter Check（run `36760297112`）**`Analyze` 步骤通过**（10 处提示确认清零），但同 job **`flutter test` 失败 2 处**（553 通过 / 2 失败），本机 Flutter 3.47.5 复现确认为 `backup_page_test.dart` **测试侧缺陷**（生产代码零改动）；② 根因：**①-1 视口过小** —— 导出 Tab 9 类目超出 `testWidgets` 默认 800×600 视口，`ListView` 仅构建可见子项致末尾类目缺席树；**①-2 FakeAsync 死锁** —— 测试 3 在体内 `await svc.writeBackupFile(...)` 触发真实文件 I/O，FakeAsync 时钟下该 `Future` 永不完成 → 挂满 10 分钟超时；③ 修复（仅测试文件）：注入 `_FakeBackupService` 替身（覆盖 `listBackupFiles`）+ 视口放大 **1200×1600**；④ 本机实测 analyze 0 issues · **555 用例全通过** · 覆盖率 **73.6%**（≥70%）· 守卫 10/10 · conformance 45/45；⑤ 环境：沙箱本轮安装 Flutter 3.47.5 复现 CI 全链路（P.7 约束解除）；文档更名 `VBOX_PLAN_v6.29.md` → `VBOX_PLAN_v6.30.md`，检查报告更名 `_v6.29.md` → `_v6.30.md`；下一批 = 重推验证 CI 全绿后进入 G-09/G-10 真机验收 |
| **v6.29** | 2026-10-01：**推送 + CI 反馈修复** —— `main` 推送（commit `738b3b7`）后 Flutter Check run `36759261677` 的 **flutter-analyze 失败**（新增代码 10 处提示）；修复 `backup_service.dart` 冗余插值 + `backup_payload.dart` 非 const 构造（默认 `categories` 由 `const {}` 改可变映射，**顺带修复 `putCategory` 写入不可变映射抛 `UnsupportedError` 的运行期缺陷**）；连带消除 9 处 `prefer_const_constructors`；其余 5 job 全绿；守卫 10/10；文档更名 `VBOX_PLAN_v6.28.md` → `VBOX_PLAN_v6.29.md`；下一批 = 重推验证 CI 全绿后进入 G-09/G-10 真机验收 |
| **v6.28** | 2026-10-01：**A2/A3/B4 接线交付（网络可达性 / 日志落盘 / 备份还原）** —— ① **A2**：平台层 `connectivity_network_info.dart`（`connectivity_plus`，失败开放）+ `HttpClient` 离线短路 + `app.dart` 注入；② **A3**：`AppLog` 契约门控（`app_log_enabled` / `app_log_min_level`）+ 关键模块埋点 + `log_file_sink.dart`（按日文件 / 3 小时保留）+ `log_viewer_page.dart`（三形态）；③ **B4**：`backup_service.dart`（9 类目 dump/restore，merge/overwrite）+ `backup_payload.dart`（Base64 UTF-8 JSON）+ `backup_page.dart`（导出 / 导入双 Tab），扩展名统一 `.vboxbak`；④ **守卫**：`check_backup_contract.py` 新增 **§6**（B4 契约核对），修复 §7 白名单解析误抓 `settingsDefaultKeys`；⑤ 测试：新增 5 个测试文件，更新 logger / network / backup_manager / app_constants 用例；⑥ 校验：守卫 **10/10** + conformance **45/45** 全绿；E.10b 余项 = **G-09 / G-10（真机人测）**；文档更名 `VBOX_PLAN_v6.27.md` → `VBOX_PLAN_v6.28.md`；下一批 = 真机验收 |
| **v6.27** | 2026-09-30：**P2 遗留清理全批次闭环（A4/B2/B3/D1/D2）+ E.10b 代码侧收口（第 1 轮只剩真机验收）** —— ① **A4** 移除 `DbModel` 抽象基类（死代码裁定，保留读写辅助函数）；② **D1** 移除 `pubspec.yaml` 零引用 `dev_dependencies.test`；③ **D2** 归并 `api_push.py`（以 api_push2 为基底，删除 api_push2，引用统一）；④ **B2** `prefs_manager._isSecure` 纳入 `credentialExtra`（PG 凭据 extra 字段改走安全存储）；⑤ **B3** 契约升 **v1.3**：`sensitiveKeys` 5 → **7**（新增 baidu_local_pcs_device_id / saved_drive_tokens），Dart 镜像逐键同步；⑥ 测试：`prefs_manager_test` 安全键口径 **11 键**（7 敏感 + 2 keychain + 2 credential_extra）；⑦ E.10b：第 1 轮**代码侧全部交付**，余项 = **G-09 / G-10（真机人测）**，`stage_check_report_stage1.yaml` verdict 仍 blocked（D20）；新增 **P.37**；文档更名 `VBOX_PLAN_v6.26.md` → `VBOX_PLAN_v6.27.md`；下一批 = 真机验收（人工，清单已就绪） |
| **v6.26** | 2026-09-30：**G-02-C Android 平台补全 + G-05 零触达收尾 + G-09/G-10 真机验收清单交付** —— ① **G-02-C Android 代码**：`SystemPlugin.kt`（UiMode 三重判定通道 `com.vbox.system/system`）/ `MediaPlaybackService.kt`（Media3 前台媒体服务）/ Manifest 双形态声明 + 前台服务 + TV 入口 / `media3-session` 依赖 / Dart 侧 `system_bridge.dart` + `resolveModeWithBridge` 接线 / `fetch_libmpv.sh` + `libmpv_external_dependencies.json`（D28 落地）；② **G-05 零触达收尾**：补测 4 文件 22 用例（system_bridge 7 / network_info 2 / app_constants 6 / ui_mode_resolver 7），零触达 **29 → 27**，修复 `_invoke` 缺 `TypeError` 兜底缺陷，剩余 27 零触达全登记排除（20 barrel + 4 接口 + 2 入口 + 1 纯常量）；静态用例 **482 → 504**、测试文件 **43 → 46**、lib 文件 **98 → 100**、整体覆盖 **76.1%**（≥70%）、触达口径 **84.2%**；③ **G-09/G-10 真机验收清单**：新增 `docs/真机验收清单_G09_G10.md`（G-09 侧载 24 项 + G-10 TV 焦点 17 项，人测职责 D8）；④ E.10b：**G-02-C 代码交付**（真机验收并入 G-09）、**G-05 收尾交付**；余项 = **G-09 / G-10（真机人测）**；新增 **P.36**；文档更名 `VBOX_PLAN_v6.25.md` → `VBOX_PLAN_v6.26.md`；下一批 = G-05 守卫全量验证 + 推送（本批收口） |
| **v6.25** | 2026-09-30：**详情页·播放入口接线交付（第 1 轮 E.10b 余项最后一块 UI / 播放数据链路）** —— ① 交付 **5 个 lib 文件**：`lib/domain/entities/playback/`（`playback_detail.dart`：`PlaybackDetail` / `PlaybackEpisode` / `PlaybackUrlParser`（契约 §3.4 `vod_play_from` / `vod_play_url` 解析 + 直链判定）+ barrel）；`lib/data/datasources/remote/all_sources_datasource.dart`（allSources 代理降级链拉取 + `findSite`）；`lib/domain/usecases/detail_playback_usecases.dart`（站点 → 模式 → CMS V10 / Spider 引擎（QuickJS 顶替 JSC）→ 详情 → `resolvePlayUrl` 三分支）；`lib/presentation/widgets/detail_page.dart`（详情页：线路 ChoiceChip / 剧集 ActionChip / 播放按钮 / 续播钳制 / 失败重试）；② 接线：`library_views.dart` 收藏/历史 onTap → `DetailPage`（siteKey=laiyuan / vodId=detailurl / initialIndex=jishu）；`app.dart` 装配 `AllSourcesDatasource` / `CmsV10Datasource` / `DetailPlaybackUseCases` + Provider；③ 测试：新增 **3 文件 / 32 用例**（playback_detail 9 / detail_playback_usecases 15 / detail_page 8）；静态用例 **450 → 482**、测试文件 **40 → 43**、lib 文件 **93 → 98**；④ E.10b：**详情页·播放入口接线解除**；余项 = **G-02-C / G-05 / G-09 / G-10**；新增 **P.35（交付复核）**；文档更名 `VBOX_PLAN_v6.24.md` → `VBOX_PLAN_v6.25.md`；下一批 = G-02-C（真机前置）或 G-05（零触达收尾） |

<!-- /docs-guard:history -->

> **D12 已定稿（经联网查证）**：TV 最低版本定为 **Android 7.0 (API 24)**。
> 依据：Flutter 官方支持矩阵（3.47）**仅支持 API 24-37，明确标注 `Unsupported: 23 and earlier`**；
> Flutter 引擎源码 `minSdkVersionInt = 24`。原 API 21 方案不受官方支持，现予修正。

---

## 〇、决策记录（Decision Log）

| ID | 决策项 | 结论 | 日期 |
|----|--------|------|------|
| D1 | iOS 迁移策略 | **方案 A4：契约共享**。iOS 现有实现（现位于 `vboxapp/vbox/`）作为**初始基线与契约来源**，Flutter 端遵循同一契约；后续 iOS 改动亦在 vboxapp 进行 | 已确认（微调） |
| D2 | Android TV | **同一 APK 双形态**（手机 + TV 双入口，`required="false"` 双向兼容） | 已确认 |
| D3 | TV 最低版本 | ~~Android 5.0 (API 21)~~ → **已被 D12 覆盖为 API 24** | 已覆盖 |
| D4 | 人力模型 | ~~多人协作（建议 4 人分工）~~ → **AI 全量开发，人力仅做测试** | **已修订** |
| D5 | 首期范围 | **三端全平台并行**：Android 手机 / Android TV / Windows / macOS / iOS 维持 | 已确认 |
| D6 | 播放器策略 | iOS 不迁移；Android 用 Media3 + libVLC 回退；Windows/macOS 用 libmpv + AVPlayer | 已确认 |
| D7 | 数据互通方式 | 契约层（SQLite DDL + Prefs 键名 + JSON Schema + 备份格式 + Spider ABI） | 已确认 |
| **D8** | **开发模式** | **AI 全量编码；人力只负责测试与真机验证** | **已确认** |
| **D9** | **关键路径** | **人测验证**（非 AI 编码）；迭代轮次驱动 | **已确认** |
| **D10** | **验收方式** | **自动化测试 + conformance 自证**（AI 无法依赖人工评审） | **已确认** |
| **D11** | **分发方式** | **全部侧载，不提交任何应用商店**（Android APK / Windows EXE / macOS DMG / iOS TrollStore） | **已确认** |
| **D12** | **TV 最低版本** | ~~Android 5.0 (API 21)~~ → **Android 7.0 (API 24)** —— 经联网查证，Flutter 官方（3.47）仅支持 API 24-37，23 及以下标注 Unsupported | **已确认** |
| **D13** | **阶段质量门禁** | **每阶段完成后必须先做遗漏检查，通过后才可进入下一阶段**（六类扫描 + 报告留档 + 不通过硬阻断） | **已确认** |
| **D14** | **唯一开发仓库** | **`q2787244398/vboxapp` 为项目唯一开发仓库**（含 iOS + Flutter 三端）。原 TVS 逆向代码已清空 | **已确认** |
| **D15** | **推送节奏** | **每完成一个阶段，推送一次到 vboxapp**（阶段验收通过后执行） | **已确认** |
| **D16** | **源仓库归档** | `q2787244398/app` **冻结不动**，仅作历史备份；**iOS 后续改动也直接在 vboxapp 进行，不回流 app** | **已修订** |
| **D17** | **契约键范围** | Prefs 契约覆盖**全模块**（含云盘/福利/直播/音乐/TG/日志/推送），共 **99 键**（iOS 源码实测 98 键 + 第 2 轮 A-06 主动扩 1 键，契约 v1.4）。以 iOS 源码实测为唯一基准 | **已确认**（2026-09-29） |
| **D18** | **目录结构基准** | 采用方案 §2.4 的**五层架构**（contract/core/data/domain/presentation/platform），取代中途生成的 `PROJECT_LAYOUT.md` 简化结构 | **已确认**（2026-09-29） |
| **D19** | **契约键存储方式区分** | 键须标注 `storage`：`userDefaults`（SharedPreferences）/ `keychain`（flutter_secure_storage）/ `credentialExtra`（凭据对象 extra 字典，非独立键） | **已确认**（2026-09-29） |
| **D20** | **阶段完成判定** | 第 1 轮完成判定 = **代码侧交付 + 自动化门禁（E.10b 六类扫描）通过**（E.10b 余项由 9 项收敛为纯真机类）；**G-09 / G-10 真机验收整体后移至第 2 轮末**（见 **D30**），不再阻断第 1 轮 → 第 2 轮推进 | **已修订**（2026-10-01；原「不得标记完成 / 不得进入第 2 轮」结论由 D30 覆盖） |
| **D21** | **Flutter 状态管理** | 采用 **`provider`**（轻量 `ChangeNotifier`），**不引入 Riverpod**。§2.3 原定 Riverpod 系早期选型，现以**已落地实现为准**修订文档 | **已确认**（2026-09-29） |
| **D22** | **Flutter 版本基线** | 以 CI 实测 **3.47.5** 为准，**修订 §2.3 的「3.24.x 锁版」**；与 D12（API 24，依据 3.47 支持矩阵）保持一致 | **已确认**（2026-09-29） |
| **D23** | **本地持久化与模型** | Flutter 侧采用 **`sqflite` 直连 + 手写模型**，**不引入 drift / freezed 代码生成**；契约正确性由 Python 侧 `check_*` 断言，不依赖 Dart 代码生成 | **已确认**（2026-09-29） |
| **D24** | **文档版本号递增** | **每次修改本方案文档必须先递增修订版本号**（v6.x → v6.x+1）**再交付 / 推送**；递增须同步：① 顶部「本版变更」块（旧版去掉「（本版）」标记）、② 版本历史表「（现行）」行、③ 受影响的计数与口径引用 | **已确认**（2026-09-29） |
| **D25** | **文档文件名版本号** | 本方案文档**文件名须携带现行修订版本号**（`docs/VBOX_PLAN_v6.20.md`），且与「（现行）」行、顶部「本版变更」块**三处一致**；递增修订版本号须**同步重命名文件并更新全部引用**（含 README / 源码注释 / CI / 守卫），守卫规则 6 强制 | **已确认**（2026-09-29） |
| **D26** | **守卫结构性漏洞须闭环** | 文档守卫的**块级豁免标记必须成对闭合**；凡「静默豁免 / 静默跳过」类设计必须自带**自检**（如块标记成对性、豁免行数上限告警）。发现「规则静默失效」类结构性漏洞时，须**先补漏洞、再用其复查全量**，并把新规则纳入 CI（本轮即由未闭合的 `docs-guard:history` 块暴露 L104–L3158 长期失守） | **已确认**（2026-09-29） |
| **D27** | **平台壳与包名基线** | Flutter 平台壳**一律以 `flutter create` 官方模板生成**（不手写），且**非侵入落地**（临时目录生成后仅拷贝平台目录 + `.metadata`，不改 `lib/` / `test/` / `pubspec.yaml`）；Android `namespace`/`applicationId` 与 macOS `PRODUCT_BUNDLE_IDENTIFIER` 统一为 **`com.vbox.player`**（iOS 保持 `com.vbox.iosplayer`）；`minSdk` **显式写死 24**（D12），不依赖 `flutter.minSdkVersion` 隐式默认 | **已确认**（2026-09-29） |
| **D28** | **libmpv 原生二进制分发** | **原生二进制不入 git 仓库**：由构建脚本（`scripts/fetch_mpv_dependencies.sh` 扩展）从 GitHub Release **资产**下载（沿用 iOS `mpvkit-deps-0.0.1` 模式，新增 `libmpv-{os}-{arch}-{ver}` 资产），随 DMG / EXE **侧载产物**分发（D11）；CI 仅验证「下载 + 链接（smoke）」，端到端回退验收归 G-02-C（真机）；版本与校验和由资产清单（`mpvkit_external_dependencies.json` 同款）登记 | **已确认**（2026-09-30） |
| **D29** | **Node / Python 运行时分发** | **Python 三端内置 + 桌面系统探测**（Android：Chaquopy Gradle 依赖，纯 Gradle 零 NDK；iOS：原生 python-stdlib 3.14 常驻；桌面：探测系统 `python3`，缺失 → `E_BACKEND_UNAVAILABLE`）；**Node 仅桌面系统探测 + iOS 原生常驻**（Android NodeMobile 嵌入成本高，**登记待评估**）；**一律不采用「首次下载」**（D11 侧载无商店更新通道，运行时网络依赖与校验不可控） | **已确认**（2026-09-30） |
| **D30** | **真机验收排期** | **G-09（侧载链路 / 自更新 / 播放器回退真机）/ G-10（TV 焦点与遥控真机）整体后移至第 2 轮末**：第 1 轮完成判定改为「**代码侧交付 + 自动化门禁（E.10b 六类扫描）通过**」（**修订 D20**）；真机验收并入**第 2 轮 E.10b 门禁**，第 2 轮人测 = **全功能 + TV 遥控 + 老设备 + G-09/G-10 全量真机**（理由：第 2 轮补齐搜索 / 直播 / 网盘 / Spider / 播放器后测试更完整，避免对不全功能重复测试）；**已知风险**：地基类问题（安装链路 / 播放器后端回退 / TV 焦点）**延后暴露**，真机批次须**优先覆盖地基项** | **已确认**（2026-10-01） |
| **D31** | **Spider 引擎在 Flutter 三端的落地口径** | **三端（Android / Windows / macOS）均集成 JavaScriptCore** 作为 **JS 站点脚本主引擎**，**QuickJS 保留为降级备份**；Node / NodeLX / Python 维持既有分流（`nodejs_` / lx / `csp_`）。**依据**：iOS `SpiderManager` 实测为「**JSC 主 → QuickJS 降级**」（`for engineType in [.javaScriptCore, .quickJS]`），且 **JSC 桥能力显著强于 QuickJS 桥**（GBK/Big5 编码链 · `sslBypass` · `atob`/`btoa` · 真实 `console`/`print` · `req` 别名 · 对象式 `options`）—— 此 6 项**与引擎选择无关，无论选谁均须实现**。**风险与预案**：代价集中于 **Windows**（无成熟预编译 JSC，须 MSVC 自建）→ **门禁任务 Q-01（可行性评估）先行**；不通过则触发降级预案（**Windows 改用 QuickJS**，其余两端 JSC）并回老板重新确认；包体与许可（JSC 属 LGPL 系）由 Q-06 核销 | **已确认**（2026-10-01） |

---

## 〇之二、增补结论速览（v2 修订要点）

| # | 修订项 | 初版结论 | v2 修订结论 |
|---|--------|----------|-----------|
| 1 | 跨平台可行性 | 60-70% 可迁移 | **40-55% 可迁移**（初版严重高估） |
| 2 | 工期估算 | 12-18 周 | **单人 20-28 周** → v3 多人 13-16 周 → **v4（AI 开发）8-12 / 11-16 周** |
| 3 | 架构描述 | 三层 | **契约层 + 双客户端 + 原生插件层** |
| 4 | 播放器 | 需原生插件 | **iOS 不迁移**（6 后端 + Metal/VT 深度耦合） |
| 5 | Python 运行时 | 嵌入式 Python | **iOS 现状是 Python 3.14.7 + lxml 自编译，三端不可复用** |
| 6 | Node 运行时 | 独立进程 | **补：5 端口 + 4 握手文件的完整协议** |
| 7 | 音乐模块 | 未展开 | **新增：csp_ 类名 Node 托管 + lx-music 桥接插件架构** |
| 8 | 福利模块 | 「子系统」 | **修正：90 平台、3 分类、~100 脚本、三重隔离** |
| 9 | 数据源 | 未量化 | **量化：12 API 源 + 16 网盘源 + 59 Spider 源 + 90 福利平台** |
| 10 | 迁移策略 | 全量迁移 | **改为：契约共享 + Flutter 新建 + iOS 保留原生** |

---

## 一、项目现状分析

### 1.1 项目定位

vbox 是一个 **iOS 聚合视频播放器**（TVBox 架构的 iOS 移植版），核心能力：

- 多站点视频搜索、详情、播放
- TVBox/MyApp 风格的 Spider 配置与解析
- JavaScript / QuickJS / Python / Node 多运行时脚本引擎
- AVPlayer / MPV / MDK / VLC / IJKPlayer / 阿里云播放器 多播放后端
- 云盘、直播、音乐、短剧、福利平台等扩展业务
- 本地 SQLite 数据库、播放历史、收藏、下载、备份还原
- Go 语言本地 HTTP 代理（HLS/M3U8 重写 + 分片预取）

### 1.2 代码规模

| 类型 | 数量 | 说明 |
|------|------|------|
| Swift | 189 文件 | 主工程全部逻辑 |
| Go | 6 文件 (1156 行) | 本地 HTTP 代理 |
| JavaScript | 35 文件 | Spider 脚本、cheerio、crypto-js、模板 |
| Python | 23 文件 | Spider 运行时、加密库 |
| Objective-C/C | 16 文件 | QuickJS/Node/Python 桥接 |
| Shell/Ruby/Python 脚本 | 20+ | 构建链、依赖注入 |
| Xcode 工程 | 1 (256KB pbxproj) | iOS 单 target |

### 1.3 技术栈

**应用层：**
- Swift 5 / SwiftUI
- iOS 16.0+（README 写 15.0，实际工程 16.0）
- Bundle ID: `com.vbox.iosplayer`
- 版本: 3.1613 (build 1613)

**CocoaPods 依赖：**
- MobileVLCKit 3.7.3 — MKV/HEVC/10-bit/HDR 播放
- swift-mdk 0.38.0 — 复杂封装、帧回调、PiP
- GRDB.swift 6.24.1 — SQLite ORM
- Kanna 6.0.1 — HTML/XML 解析

**系统框架：**
AVFoundation, AVKit, AudioToolbox, CoreMedia, CoreVideo, VideoToolbox, Metal, QuartzCore, IOSurface, Security, UIKit, JavaScriptCore, WebKit, Network

**嵌入式二进制：**
- FFmpeg 组件（Libavdevice, Libavutil, Libswscale, Libcrypto）
- 渲染/字幕（Libplacebo, Libass, Libfreetype, Libfribidi）
- 协议/格式（Libbluray, Libdovi, Libsmbclient, hogweed）
- MPVKit.xcframework + Libmpv
- NodeMobile.xcframework
- Python.framework (3.14.7)
- QuickJS (2024-01-13)
- AliyunPlayer.framework + alivcffmpeg.framework
- IJKMediaFrameworkWithSSL

### 1.4 目录结构

```
vbox/
├── App/                 # SwiftUI 入口、设置、根导航
├── Bridge/              # GoProxyManager（gomobile 桥接）
├── Libraries/           # ObjC/C 桥接（QuickJS/Node/Python/Log/AliPlayer）
├── Models/              # 数据模型（GRDB Codable）
├── PlayerCore/          # 多播放器引擎抽象与实现
├── Services/            # 业务服务（Spider/云盘/音乐/下载/备份/远程源）
├── Views/               # SwiftUI 视图
├── WelfareRemote/       # 福利远程平台子系统
└── Resources/           # JS/Python/Node 运行时资产、字体、配置
```

### 1.5 核心模块详解

#### 1.5.1 Spider 系统（6075 行 SpiderManager）

统一协议 `SpiderEngineProtocol`，支持 5 种引擎：
- **JavaScriptCore** — Apple 原生 JS 引擎
- **QuickJS** — 嵌入式 C JS 引擎
- **Node** — 独立进程，桥接 127.0.0.1:58080
- **NodeLX** — Node 独立端口 58083，lx-music 协议
- **Python** — 嵌入式 Python 3.14

站点模式识别：
- `type=0/1` → API 模式（CMS 接口直调）
- `type=2` → 站源模式（HTML 解析）
- `type=3` → JS/Python/Node 蜘蛛（按 URL 后缀和 key 前缀区分）

远程源配置：
- manifest.json 版本探测 → all_sources.json 全量拉取
- 6 合 1 源文件（apiSources + cloudSources + spiderSources）
- GitHub 代理加速（ghfast.top → gh-proxy.com → 直连）
- JS 蜘蛛文件 + lx-music 插件下载缓存

#### 1.5.2 播放器系统

统一协议 `PlayerEngine`：
```swift
protocol PlayerEngine {
    var type: PlayerEngineType { get }
    var state: PlayerEngineState { get }
    var onEvent: ((PlayerEngineEvent) -> Void)? { get set }
    func attach(to view: UIView)
    func load(route: PlaybackRoute)
    func play/pause/stop/seek/setRate/setVolume/teardown
}
```

实现后端：
- AVPlayerEngine — 系统播放器
- MPVPlayerEngine — libmpv（含 MoltenVK 渲染）
- MDKPlayerEngine — swift-mdk
- IJKPlayerRepresentable — IJKPlayer
- VLC — MobileVLCKit
- AliPlayer — 阿里云播放器

高级能力：
- VideoToolbox 硬解码
- Metal 渲染层
- PiP（画中画）多后端管理
- 流重封装（RemuxProxyServer + StreamRemuxer）
- 帧回调

#### 1.5.3 数据库系统

GRDB.swift SQLite，v1→v4 迁移：
- `zhanyuan` — 站源站点配置
- `apiyuan` — API 站点配置
- `subscription` — 订阅源
- `favorite` — 收藏
- `history` — 观看历史（含进度）
- `download` — 下载记录
- `settings` — 键值设置
- `jiexi` — 解析设置
- `search_history` — 搜索历史

旧数据迁移：UserDefaults → SQLite（subscribed_config_urls）

#### 1.5.4 备份系统

- 9 个类目（历史/收藏/下载/订阅/站点/设置/远程源/搜索/凭据）
- AES 加密 + PBKDF2 密钥派生
- 冲突策略：合并 / 覆盖
- 版本兼容：schemaVersion 检查
- 敏感数据（网盘凭据）默认关闭

#### 1.5.5 Go 代理（go-proxy）

纯 Go 标准库实现，零外部依赖：
- 本地 HTTP 服务（127.0.0.1）
- HLS/M3U8 播放列表重写
- 分片 URL 重写 + Base64 编码
- 三级缓存：预取内存 → 磁盘 → 上游
- 分片预取（当前后 3 个）
- HTTP/2 + TLS 1.2 + 连接池
- gomobile 导出：StartProxy/RegisterStream/StopProxy/ProxyStatus/ClearCache

#### 1.5.6 构建链

10 个 GitHub Actions workflow：
- build-ipa / build-ipa-debug — 主工程构建
- build-quarkproxy — Go 代理 gomobile 编译
- build-quickjs — QuickJS 静态库
- build-mdk-branch — MDK 分支构建
- build-mpv-pip-bridge — MPV PiP 桥接
- build-lxml-test — lxml iOS 编译
- mpvkit-deps-check — MPV 依赖检查
- changelog — 变更日志

### 1.6 平台耦合度评估

| 模块 | 跨平台可行性 | 说明 |
|------|-------------|------|
| UI (SwiftUI) | ❌ 不可直接迁移 | 需重写为 Flutter Widget |
| 数据模型 (Codable) | ✅ 可迁移 | 转 Dart json_serializable |
| Spider 协议层 | ✅ 可迁移 | 纯逻辑，转 Dart |
| Spider 引擎 (JSC/QJS/Node/Python) | ❌ 需原生桥接 | 运行时嵌入式 |
| 播放器 (AVPlayer/MPV/MDK/VLC) | ❌ 需原生桥接 | 平台专用渲染 |
| 数据库 (GRDB) | ✅ 可迁移 | 用 sqflite 替代 |
| 备份系统 | ✅ 可迁移 | 纯逻辑 + 加密 |
| 远程源管理 | ✅ 可迁移 | HTTP + 文件缓存 |
| Go 代理 | ⚠️ 源码可复用 | 需重新绑定 Android/Windows |
| Keychain | ❌ 需平台替代 | Android Keystore / Windows DPAPI |
| 后台音频 | ❌ 需原生实现 | 各平台音频会话 |
| 文件共享/照片 | ❌ 需平台替代 | 各平台文件 API |
| Metal/VideoToolbox | ❌ iOS 专用 | 需替换为平台渲染 |

---

## 一之补：远程源仓库 `vbox-Ai/api` 全景分析（新增章节）

### A.1 仓库定位

`vbox-Ai/api` 是 vbox 客户端的**远程配置数据平面**，与客户端代码完全解耦。客户端只依赖 `manifest.json` 契约，源内容变更无需发版。

**入口地址（双通道）：**
```
https://raw.githubusercontent.com/vbox-Ai/api/main/sources/manifest.json   （主，raw）
https://vbox-ai.github.io/api/sources/manifest.json                        （备，Pages）
```

### A.2 manifest 契约（迁移必须 1:1 复刻）

```json
{
  "schemaVersion": 1,
  "configVersion": "2026.09.29.3",
  "minAppVersion": "1.0.0",
  "updatedAt": "2026-09-29T00:51:43Z",
  "ttlSeconds": 21600,
  "files": {
    "allSources":     ".../all_sources.json",
    "apiSources":     ".../api_sources.json",
    "cloudSources":   ".../cloud_sources.json",
    "spiderSources":  ".../spider_sources.json",
    "domainOverrides":".../domain_overrides.json",
    "parsers":        ".../parsers.json",
    "disabledSources":".../disabled_sources.json",
    "welfarePlatforms":".../welfare_platforms.json",
    "nodeRuntimeBundle": ".../kstore_index.js",
    "nodeRuntimeBundleVer": ".../kstore.version"
  },
  "disabledKeys": [],
  "forceRefresh": true
}
```

**关键机制：**
- `configVersion` 版本号探测（manifest.version，约 38 字节）→ 变更才全量拉取
- `ttlSeconds = 21600`（6 小时）兜�刷新
- `forceRefresh: true` 强制全量
- `minAppVersion` 客户端兼容门控
- 所有 JSON 用 `_meta` 字段自描述（标准 JSON 不支持注释）

### A.3 数据源量化清单（重要补充）

| 文件 | 数据量 | 内容 |
|------|--------|------|
| `api_sources.json` | **12** 站点 | 极速资源/黄河资源/555影视/电影天堂/360资源/DONW/奇迹影视 + 5 个 builtin_fallback |
| `cloud_sources.json` | **16** 网盘站 | cms×11 / binhd / forum / dedecms / spa，含玩偶、木偶、多多、欧歌、至臻、小斑、奕搜、123分享、人人电影、虎斑、4KTOP、LIBVIO、原盘4K、剧透4K、七味4K |
| `spider_sources.json` | **59** 站点 | JS 蜘蛛 14 + Python 蜘蛛 9 + 音乐 csp_ 类名 10 + Node 托管 6 + 其他 |
| `welfare_platforms.json` | **90** 平台 / 3 分类 | video / live / comic |
| `all_sources.json` | 108 KB | 上述 6 合 1 聚合文件 |
| `sources/js/` | 30 脚本 | .js 与 .py 混放（含 323ys.py、Pan_tgs.js 等） |
| `sources/welfare-js/` | **~100 脚本** | 福利专区专用，严格隔离 |
| `sources/lx/` | 2 插件 | da xe.js (17KB) / nianxin.js (26KB) |
| `sources/bundles/kstore_index.js` | **6.4 MB** | Node 运行时 bundle（第三方 kstore.vip 上游） |

### A.4 站点类型编码（迁移必须对齐）

```dart
// type 字段语义
// 0, 1 → API 模式（CMS 接口直调）
// 2    → 站源模式（HTML 解析）
// 3    → 蜘蛛模式（按 api 后缀 / key 前缀细分）

// key 前缀语义（决定引擎选择）
// js_       → JavaScriptCore / QuickJS 引擎
// y_        → Python 引擎
// Music_    → csp_ 类名 → Node 托管（音乐）
// nodejs_   → Node 常驻系统托管
// csp_      → Node 托管（type=3 时）
// 其他      → 按 api 后缀判断
```

`SiteConfig` 扩展字段（P2-00 / P1-A6）：
```dart
playMode      // normal / pan / hybrid
panHosts      // ["quark","ali"] 网盘宿主列表
group         // "video" / "music" / "node" / "cloud" / "api"
engineType    // "lxMusic" / "node" / 空
pluginPath    // "sources/lx/daxe.js" lx 插件路径
version       // 插件版本，用于远程更新比对
md5           // 插件完整性校验
```

### A.5 自动化流水线（5 个 workflow）

| Workflow | 触发 | 作用 |
|----------|------|------|
| `validate-sources.yml` | sources/** push/PR | Python 校验所有 JSON 合法性 |
| `bump-version.yml` | 任意配置变更 | 自动递增 `configVersion`（YYYY.MM.DD.N，同日递增） |
| `check-domains.yml` | 每周一 UTC 18:00 + 配置变更 | 域名存活检测 + 邮件报告 |
| `update-cloud-urls.yml` | 每 3 天 UTC 10:00 | 自动更新云盘域名 + LIBVIO 备用线路 |
| `sync-kstore-bundle.yml` | 每 3 天 UTC 03:00 | 从 `9280.kstore.vip` 拉取最新 Node bundle（MD5 比对） |

**域名监控机制：**
- `extract_domains.py` 提取所有 URL/域名
- `check_domains.py` 并发检测 → `check-results.json` + `check-results.md`
- `domain-monitor/backups/` 保留 19 个历史快照（2026-07-31 起）
- 失败域名可自动写入 `disabled_sources.json`

### A.6 三级隔离约定（Flutter 端必须遵守）

```
spider_sources.json     → 普通全局源（首页 / 全局搜索 / 普通播放）
welfare_platforms.json  → 福利专区（独立入口）
  └─ visibleInNormalSpider: false   ← 强制
  └─ visibleInGlobalSearch: false   ← 强制
  └─ visibleInHome:         false   ← 强制
  └─ 脚本只允许在 sources/welfare-js/
  └─ 禁止加入 spider_sources.json
```

### A.7 客户端与远程源的耦合点（迁移风险表）

| 客户端组件 | 依赖的远程字段 | 迁移影响 |
|-----------|---------------|----------|
| `RemoteSourceConfigManager` | manifest / allSources / spiderJS / lxPlugins / nodeRuntimeBundle | **必须整体重写为 Dart**，含代理降级链 |
| `SpiderManager.resolveSiteMode` | type / key 前缀 / api / group / playMode | **纯逻辑，可直接迁移** |
| `SiteConfig` 模型 | 20+ 字段（含扩展） | 手写模型（D23），字段名必须 1:1 |
| `NodeRuntimeManager` | nodeRuntimeBundle / kstore.version | 需重新实现进程管理 + MD5 校验 |
| `SpiderRepository` | parsers / disabledSources / domainOverrides | 纯逻辑可迁移 |
| 福利加载器 | welfarePlatforms 全字段 | 需完整复刻 schema |
| `BackupManager` | remoteSources 快照（含 lxPlugins） | 备份格式必须兼容 |

### A.8 远程源仓库对迁移方案的影响（结论）

1. **数据契约稳定**：远程源是纯 JSON，Flutter 端实现成本低，但字段必须逐一对齐（20+ 字段）。
2. **代理降级链必需**：GitHub raw 在部分地区不可达，客户端已有 `ghfast.top → gh-proxy.com → 直连` 三级降级，Flutter 必须复刻。
3. **Node bundle 体积风险**：kstore_index.js 单文件 **6.4 MB**，三端打包需考虑按需下载而非内置。
4. **福利模块体量大**：90 平台 + ~100 脚本，是三端迁移中**单点工作量最重**的模块，建议最后迁移或独立排期。
5. **自动化已在服务端**：域名监控、版本递增、bundle 同步均由远程仓库 CI 承担，客户端无需实现，**降低迁移复杂度**。

---

## 二、Flutter 多端重构方案（v3 定稿）

### 2.1 总体架构（契约层 + 双客户端）

```
┌───────────────────────────────────────────────────────────────────┐
│                    契约层 Contract Layer（只读，冻结后不可擅改）    │
│  ┌────────────────┐ ┌────────────────┐ ┌───────────────────────┐ │
│  │ SQLite DDL     │ │ Prefs 键名契约 │ │ JSON Schema           │ │
│  │ schema_v1.sql  │ │ prefs_keys_v1  │ │ site/fuLi/manifest    │ │
│  ├────────────────┤ ├────────────────┤ ├───────────────────────┤ │
│  │ Spider ABI     │ │ 备份格式规范   │ │ 一致性测试样本        │ │
│  │ abi_v1.md      │ │ backup_v1.md   │ │ conformance/fixtures  │ │
│  └────────────────┘ └────────────────┘ └───────────────────────┘ │
└────────────┬──────────────────────────────────────┬───────────────┘
             │                                      │
   ┌─────────▼──────────┐                ┌─────────▼──────────┐
   │  Flutter 客户端     │                │   iOS 原生客户端    │
   │  （全新开发）       │                │   （零改造，仅适配）│
   ├────────────────────┤                ├────────────────────┤
   │ Dart 领域层         │                │ Swift 领域层        │
   │ ├ models           │                │ ├ Models（现有）    │
   │ ├ database         │                │ ├ GRDB（现有）      │
   │ ├ remote_source    │                │ ├ RemoteSource（现有）│
   │ ├ backup           │                │ ├ Backup（现有）    │
   │ └ spider_abi       │                │ └ Spider（现有）    │
   ├────────────────────┤                ├────────────────────┤
   │ 5 形态 UI           │                │ SwiftUI（现有）     │
   │ ├ Android 手机      │                │                    │
   │ ├ Android TV        │                │                    │
   │ ├ Windows           │                │                    │
   │ ├ macOS             │                │                    │
   │ └ (Linux 可选)      │                │                    │
   ├────────────────────┤                ├────────────────────┤
   │ 原生插件层          │                │ 原生实现（现有）    │
   │ ├ Player           │                │ ├ 6 播放器后端      │
   │ ├ QuickJS FFI      │                │ ├ JSC/QuickJS      │
   │ ├ Python           │                │ ├ Python 3.14.7    │
   │ ├ Node             │                │ ├ NodeMobile       │
   │ ├ Go Proxy         │                │ ├ Go Proxy         │
   │ └ System           │                │ └ Keychain 等       │
   └────────────────────┘                └────────────────────┘
```

**D1 落实：iOS 零改造原则**
- iOS 代码一行不改
- 契约层从 iOS 现有实现**逆向提取**（而非设计后要求 iOS 遵守）
- 若 Flutter 实现与 iOS 不符 → **以 iOS 为准修订 Flutter 实现**
- iOS 作为**参照实现（Reference Implementation）**用于一致性测试

**收益**：三端完全解耦，可并行开发，iOS 零风险，测试时 iOS 即现成参照。

**代价**：领域逻辑写两遍（Dart 一遍 + 沿用 Swift 现有）。但 iOS 已写好，Flutter 端本就必做，故无额外成本。

### 2.2 契约优先（Contract-First）工作流

```
① 逆向提取契约（从 iOS 现有代码）
   ├── DatabaseManager.swift   → SQLite DDL（9 表 + v1→v4 迁移）
   ├── Swift Codable 模型       → JSON Schema
   ├── UserDefaults 键名扫描    → Prefs 键名契约（98 键）
   ├── BackupManager.swift     → 备份格式规范
   └── SpiderEngineProtocol    → Spider ABI
                ↓
② 冻结契约（打 tag：contract-v1.0）
                ↓
③ 三端并行开发，各自实现，遵循同一契约
                ↓
④ 一致性测试（Conformance Test）
   ├── 同一 fixtures 喂给 iOS 和 Flutter
   ├── 逐层比对各层输出
   └── 不一致 → 判定 Flutter 实现 bug，不改契约
```

### 2.3 技术选型（minSdk 24 / API 24）

| 层级 | 技术 | 版本 | 备注 |
|------|------|------|------|
| UI 框架 | Flutter | **3.47.5**（CI 实测，D22） | 5 形态复用 |
| 设计系统 | Material 3 | — | 三套主题（phone/tv/desktop） |
| 状态管理 | **provider**（D21） | ^6.1.2 | ✅ 已落地；~~Riverpod~~ 早期选型，按实现修订 |
| 路由 | ~~go_router~~ **未引入** | — | 当前仅 `app.dart` + `ui_mode`，路由待接线 |
| 本地数据库 | **sqflite**（+ `sqflite_common_ffi`，D23） | ^2.3.3 | 复刻 v1→v4 迁移链；~~drift~~ 不引入代码生成 |
| 网络 | **http + dio** | ^1.2.2 / ^5.7.0 | 数据源已用 `http`；`dio` 预留拦截器/取消/重试 |
| JSON | **手写模型**（D23） | — | ~~freezed + json_serializable~~ 不引入代码生成 |
| 文件 | path_provider + path | ^2.1.4 / ^1.9.0 | ⚠️ `file_picker` 尚未引入 |
| 加密 | cryptography + crypto | ^2.7.0 / ^3.0.5 | AES-GCM + PBKDF2 |
| 安全存储 | flutter_secure_storage | ^9.2.2 | 7 个敏感键 + keychain + credential_extra（B2/B3 v6.27 裁定） |
| 权限 | ~~permission_handler~~ **待引入** | — | 平台壳创建后评估 |
| 唤醒锁 | ~~wakelock_plus~~ **待引入** | — | 播放器阶段引入 |
| 脚本运行时 | ffi（QuickJS FFI 绑定） | ^2.1.3 | Phase 2+，先占位（**未实现**） |
| 播放器（移动） | media3 (Android) / video_player | 待定 | + libVLC 回退（**未实现**） |
| 播放器（桌面） | media_kit | 待定 | libmpv 绑定（**未实现**） |
| 渲染 | Impeller（默认） | — | ✅ API 24 支持 Impeller |

### 2.4 目标目录结构

```
vboxapp/
├── lib/
│   ├── main.dart
│   ├── app.dart
│   ├── core/
│   │   ├── constants/  errors/  network/  storage/  utils/
│   ├── contract/                    # ⭐ 契约层镜像（从 vbox-contract 同步）
│   │   ├── schema/                  # SQL DDL 常量
│   │   ├── prefs_keys.dart          # 98 键名常量 / 21 组（v1.2）
│   │   └── abi/                     # Spider ABI 定义
│   ├── data/
│   │   ├── datasources/local/       # SQLite 数据源
│   │   ├── datasources/remote/      # HTTP 数据源
│   │   ├── models/                  # 手写模型（D23，1:1 对齐契约）
│   │   └── repositories/
│   ├── domain/
│   │   ├── entities/  repositories/  usecases/
│   ├── presentation/
│   │   ├── providers/
│   │   ├── ui_mode/ui_mode_resolver.dart   # ⭐ 形态判定
│   │   ├── phone/                   # 手机布局
│   │   ├── tv/                      # ⭐ TV 布局（焦点系统）
│   │   ├── desktop/                 # 桌面布局
│   │   ├── shared/                  # 共享组件
│   │   └── theme/                   # phone / tv / desktop 三套主题
│   └── platform/
│       ├── player/  spider/  runtime/  system/
├── android/app/src/main/kotlin/com/vbox/player/
│   ├── PlayerPlugin.kt              # Media3 + libVLC 回退
│   ├── player/CodecCapability.kt    # ⭐ 编解码能力探测
│   ├── SpiderPlugin.kt
│   ├── QuickJsRuntime.kt
│   ├── PythonRuntime.kt             # Chaquopy
│   ├── NodeRuntime.kt
│   ├── SystemPlugin.kt              # ⭐ UiMode 判定
│   └── MediaPlaybackService.kt      # 前台服务
├── macos/Runner/
│   ├── PlayerPlugin.swift           # AVPlayer + libmpv 回退
│   ├── QuickJsRuntime.swift  PythonRuntime.swift  SystemPlugin.swift
├── windows/runner/
│   ├── player_plugin.cpp            # libmpv
│   ├── quickjs_runtime.cpp  python_runtime.cpp  node_runtime.cpp  system_plugin.cpp
├── plugins/                          # 自研 Flutter 插件
│   ├── vbox_player/  vbox_spider/  vbox_runtime/  vbox_proxy/
├── assets/  js/  python/  node/  fonts/
├── conformance/                      # ⭐ 一致性测试（共享 fixtures）
│   ├── fixtures/                     # SQLite 样本 / 备份样本 / Spider IO 样本
│   └── runner/                       # 各端一致性测试运行器
├── docs/
│   └── android-compat.md            # ⭐ 依赖锁定清单（实际位于 contract/docs/）
└── test/  integration_test/
```

> **⚠️ 形态判定口径统一（v6.2；v6.34 订正）**：`presentation/ui_mode/` 的**权威设计口径为 §T.1**
> （Android 侧经平台通道 `getUiModeType` / `hasLeanbackFeature` / `hasTouchscreen` 三重判定，
> 桌面端为编译期常量）。**v6.34（A-05）已交付**：`ui_mode_resolver.dart` 由三形态占位改造为
> `UiForm{portrait,landscape}` + `InputModality{touch,remote,mouseKeyboard}`，
> `UiFormController.resolveWithBridge` 经 `SystemBridge` 走平台通道，视口由 `_RootRouter` 经
> `MediaQuery` 注入（原「无调用方提供 `screenSize/hasTouch/hasRemote`」的占位缺陷已消除）；
> 注释中提及的 `ui_tv_mode` 键**不在契约 98 键内**（Android TV 经通道判定，不读此键）。
> 接线已于 **v6.26**（G-02-C `SystemPlugin.kt` 三重判定通道）+ **v6.34**（A-05 `SystemBridge` 消费）完成。

### 2.5 平台能力矩阵（v3）

| 能力 | Android 手机 | Android TV | Windows | macOS | iOS（维持） |
|------|-------------|-----------|---------|-------|------------|
| 主播放器 | Media3 | Media3 | libmpv | AVPlayer | 6 后端 |
| 全格式回退 | libVLC | **libVLC（必需）** | FFmpeg/mpv | libmpv | MPV/MDK/VLC |
| JS 引擎 | QuickJS FFI | 同左 | 同左 | 同左 | JSC/QuickJS |
| Python | Chaquopy | 同左 | CPython | 嵌入式 | 3.14.7 自编译 |
| Node | 独立进程 | 同左 | 同左 | 同左 | NodeMobile |
| 后台音频 | ForegroundService | 前台服务+通知 | MTC | AVAudioSession | AVAudioSession |
| 画中画 | 系统 PiP (8.0+) | ≤7.1 小窗降级 | 自定义 overlay | AVPlayer PiP | 4 种 PiP |
| 凭据存储 | EncryptedPrefs | 同左 | DPAPI | Keychain | Keychain |
| 文件选择 | SAF | SAF（遥控受限） | IFileOpenDialog | NSOpenPanel | UIDocumentPicker |
| 最低版本 | **API 24** | **API 24** | Win10 | macOS 12+ | iOS 16 |
| 输入方式 | 触摸 | **D-pad 遥控** | 键鼠 | 键鼠 | 触摸 |

### 2.6 关键接口设计

#### 2.6.1 播放器接口

```dart
abstract class VboxPlayer {
  Future<void> initialize();
  Future<void> load(PlayerSource source);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
  Future<void> setVolume(double volume);
  Future<void> setTrack(PlayerTrack track);
  Future<void> setSubtitle(SubtitleTrack track);
  Future<void> enterPiP();
  Future<void> exitPiP();
  Future<void> dispose();

  Stream<PlayerState> get stateStream;
  Stream<PlayerEvent> get eventStream;
  Widget buildView();
}
```

#### 2.6.2 Spider 引擎接口

```dart
abstract class SpiderEngine {
  Future<void> loadScript(String script);
  Future<void> loadScriptFromUrl(String url);
  Future<void> registerSpider();
  bool get isReady;

  Future<HomeContent> callHomeContent();
  Future<SearchContent> callSearch(String keyword, int page);
  Future<CategoryContent> callCategory(String tid, int page, String extend);
  Future<DetailContent> callDetail(String ids);
  Future<PlayerContent> callPlayer(String vodId, String flag, String url);

  Stream<String> get logStream;
}
```

#### 2.6.3 运行时接口

```dart
abstract class ScriptRuntime {
  Future<void> initialize();
  Future<String> evaluate(String script);
  Future<String> callFunction(String name, Map<String, dynamic> args);
  Future<void> dispose();

  Stream<String> get logStream;
  Stream<String> get errorStream;
}
```

#### 2.6.4 形态判定接口

```dart
enum UiMode { phone, tv, desktop }

abstract class UiModeResolver {
  Future<UiMode> resolve();
}
```

### 2.7 数据迁移策略

1. **SQLite**：严格遵循 `schema_v1.sql`，复刻 v1→v4 迁移链（含 v2 重建表）
2. **JSON**：数据模型字段名与 SQL 列名 1:1
3. **Prefs**：遵循 `prefs_keys_v1.json`，98 键名 + 类型完全一致（v1.5，A-06 扩键后 v1.5 移除误抓键）
4. **备份**：格式与加密参数不变，须通过跨端互通测试
5. **迁移标记**：`vbox_sqlite_migration_done` 必须识别，避免重复迁移
6. **敏感键**：7 个敏感键 + `storage=keychain` + `storage=credential_extra` 键建议迁 secure storage（v1.3，B2/B3 裁定），需兼容读取 UserDefaults

### 2.8 验收标准

1. **功能完整性**：iOS 现有核心功能 100% 覆盖
2. **数据兼容**：旧 SQLite / 备份可读，且 iOS ↔ Flutter **双向互通**
3. **契约一致性**：conformance fixtures 100% 通过
4. **多形态一致**：5 形态功能对齐（TV 遥控交互差异属预期）
5. **性能**：
   - 新设备：启动 < 2s、播放启动 < 1s
   - **Android 7.0 下限设备：启动 < 5s、播放启动 < 3s**
6. **稳定性**：崩溃率 < 0.1%，ANR < 0.01%
7. **包体积**：APK arm64 < 100MB / v7a < 70MB；Windows < 120MB；macOS < 150MB
8. **测试覆盖**：单元测试 > 70%，conformance 100%

---

## 二之补：Android TV 双形态技术方案（新增）

### T.1 形态判定（三重判定，优先级递减）

```dart
// lib/presentation/ui_mode/ui_mode_resolver.dart
Future<UiMode> resolveUiMode() async {
  if (Platform.isAndroid) {
    // ① 系统 UI Mode（官方标准，最可靠）
    final isTelevision = await _ch.invokeMethod<bool>('getUiModeType') ?? false;
    if (isTelevision) return UiMode.tv;

    // ② PackageManager 特性（兜底）
    final hasLeanback  = await _ch.invokeMethod<bool>('hasLeanbackFeature') ?? false;
    final hasTouch     = await _ch.invokeMethod<bool>('hasTouchscreen') ?? true;
    if (hasLeanback && !hasTouch) return UiMode.tv;

    // ③ 屏幕尺寸 + 输入设备（山寨盒子 ROM 兜底）
    final shortestSide = MediaQueryData.fromWindow(
        WidgetsBinding.instance.window).size.shortestSide;
    if (shortestSide >= 720 && !hasTouch) return UiMode.tv;

    return UiMode.phone;
  }
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    return UiMode.desktop;
  }
  return UiMode.phone;
}
```

**Kotlin 侧（三 API 均早于 API 24，无需版本判断）：**
```kotlin
class SystemPlugin : MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getUiModeType" -> {
                val m = (context.getSystemService(Context.UI_MODE_SERVICE) as UiModeManager)
                // UI_MODE_TYPE_TELEVISION = 4，API 21+
                result.success(m.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION)
            }
            "hasLeanbackFeature" -> result.success(
                context.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK))
            "hasTouchscreen" -> result.success(
                context.packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN))
            else -> result.notImplemented()
        }
    }
}
```
✅ `UiModeManager.getCurrentModeType()`、`FEATURE_LEANBACK`、`FEATURE_TOUCHSCREEN` **均为 API 21+**，无需版本判断。

### T.2 AndroidManifest 双入口

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <!-- 关键：双向兼容，手机/TV 都能安装 -->
    <uses-feature android:name="android.hardware.touchscreen"  android:required="false" />
    <uses-feature android:name="android.software.leanback"     android:required="false" />
    <uses-feature android:name="android.hardware.gamepad"      android:required="false" />

    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />

    <application
        android:banner="@drawable/tv_banner"
        android:networkSecurityConfig="@xml/network_security_config"
        android:usesCleartextTraffic="true">

        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:configChanges="orientation|screenSize|keyboardHidden|uiMode"
            android:launchMode="singleTask">
            <!-- 手机入口 -->
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
            <!-- TV 入口（仅 TV Launcher 显示） -->
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LEANBACK_LAUNCHER" />
            </intent-filter>
        </activity>

        <service
            android:name=".player.MediaPlaybackService"
            android:foregroundServiceType="mediaPlayback"
            android:exported="false" />
    </application>
</manifest>
```

⚠️ API 24 下的行为：
- `android:banner` API 21+ ✅ 可用
- `foregroundServiceType` API 29+ 引入（API 24 上忽略，无害）
- `FOREGROUND_SERVICE_MEDIA_PLAYBACK` API 34+（API 24 上忽略）
- `usesCleartextTraffic` API 23+ 生效，API 24 读取该属性
- `FileProvider` **API 24 原生可用**（自更新安装依赖它）

### T.3 network_security_config.xml

```xml
<network-security-config>
    <base-config cleartextTrafficPermitted="true">
        <trust-anchors>
            <certificates src="system" />
            <certificates src="@raw/extra_ca" />  <!-- 老设备根证书陈旧 -->
        </trust-anchors>
    </base-config>
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="false">127.0.0.1</domain>
        <domain includeSubdomains="false">localhost</domain>
    </domain-config>
</network-security-config>
```
⚠️ API 24+ 会读取此文件；显式声明 `cleartextTrafficPermitted="true"` 以兼容大量 http 源站。

### T.4 TV 焦点系统（核心）

```dart
class FocusableCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onSelect;
  final bool autofocus;
}

class _FocusableCardState extends State<FocusableCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      autofocus: widget.autofocus,
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) { widget.onSelect?.call(); return null; }),
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: _focused
              ? Border.all(color: Theme.of(context).colorScheme.primary, width: 3)
              : Border.all(color: Colors.transparent, width: 3),
          boxShadow: _focused
              ? [const BoxShadow(color: Colors.black45, blurRadius: 16, spreadRadius: 2)]
              : null,
        ),
        child: widget.child,
      ),
    );
  }
}
```

**TV 焦点 5 条铁律：**
1. 焦点**必须始终可见**（`autofocus` + `FocusTraversalGroup`）
2. 焦点变化**必须有视觉反馈**（边框 + 缩放 + 阴影）
3. **所有可交互元素可聚焦**（含播放器控制栏）
4. **焦点循环**（行末 → 下一行首，或回到行首）
5. **Back 键拦截**（`PopScope`，播放页先关控制栏再退出）

### T.5 遥控器按键映射

```dart
Shortcuts(
  shortcuts: {
    const SingleActivator(LogicalKeyboardKey.select):          const ActivateIntent(),
    const SingleActivator(LogicalKeyboardKey.enter):           const ActivateIntent(),
    const SingleActivator(LogicalKeyboardKey.gameButtonA):     const ActivateIntent(),
    const SingleActivator(LogicalKeyboardKey.escape):          const DismissIntent(),
    const SingleActivator(LogicalKeyboardKey.goBack):          const DismissIntent(),
    const SingleActivator(LogicalKeyboardKey.mediaPlayPause):  const PlayPauseIntent(),
    const SingleActivator(LogicalKeyboardKey.mediaPlay):       const PlayIntent(),
    const SingleActivator(LogicalKeyboardKey.mediaPause):      const PauseIntent(),
    const SingleActivator(LogicalKeyboardKey.mediaStop):       const StopIntent(),
    const SingleActivator(LogicalKeyboardKey.mediaFastForward):const FastForwardIntent(),
    const SingleActivator(LogicalKeyboardKey.mediaRewind):     const RewindIntent(),
  },
  child: Actions(
    actions: {
      PlayPauseIntent: CallbackAction<PlayPauseIntent>(
        onInvoke: (_) { PlayerController.instance.togglePlay(); return null; }),
    },
    child: FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: child,
    ),
  ),
)
```

**键值异常兜底**：支持用户可配置的 `TvKeyRemap` 映射表（部分山寨盒子返回非标准键值）。

### T.6 十英尺主题

```dart
ThemeData buildTvTheme(ThemeData base) {
  const scale = 1.5;
  return base.copyWith(
    textTheme: base.textTheme.apply(fontSizeFactor: scale, fontSizeDelta: 2),
    cardTheme: base.cardTheme.copyWith(margin: const EdgeInsets.all(16), elevation: 8),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(160, 64),
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
        textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      ),
    ),
    colorScheme: base.colorScheme.copyWith(
      surface: const Color(0xFF121212), onSurface: Colors.white),
  );
}
```

### T.7 TV 布局规范

```
手机布局                     TV 布局
┌─────────────┐             ┌──────────────────────────────────────┐
│ 顶部搜索栏   │             │  侧边导航  │   内容区（横向滚动）      │
├─────────────┤             │  首页     │  ┌───┐┌───┐┌───┐┌───┐   │
│  列表（垂直）│             │  搜索     │  └───┘└───┘└───┘└───┘   │
├─────────────┤             │  我的     │  ┌───┐┌───┐┌───┐┌───┐   │
│ 底部导航栏  │             │  设置     │  └───┘└───┘└───┘└───┘   │
└─────────────┘             └──────────────────────────────────────┘
                            恒横屏，卡片横排，每行 5-6 个
```

| 项 | 手机 | TV |
|----|------|-----|
| 导航 | 底部 TabBar | 左侧边栏 |
| 列表 | 垂直滚动 | 横向行 + 垂直滚动 |
| 每行项数 | 2-3 | 5-6 |
| 卡片尺寸 | 120×160 | 200×280 |
| 字号 | 14-16 | 20-24 |
| 间距 | 8-12 | 16-24 |
| 方向 | 竖屏为主 | 恒横屏 |

### T.8 TV 端特有风险与缓解

| 风险 | 说明 | 缓解 |
|------|------|------|
| 老盒子内存 | Android 7.0 下限，1-2GB | `ListView.builder` 懒加载；图片降采样；bundle 延迟加载 |
| 解码器弱 | RK3128/S905 无 HEVC 硬解 | 播放前能力探测；自动回退软解；画质降级 |
| UiMode 误判 | 山寨盒子定制 ROM | 三重判定 + 按键探测兜底 |
| 按键键值异常 | 部分盒子非标准 | 可配置按键映射表 |
| WebView 缺失 | 老盒子可能无 | 扫码降级为设备码流程 |
| 无触摸 | 完全依赖遥控 | 所有交互必须 D-pad 可达 |
| 输入困难 | 遥控打字痛苦 | 九宫格/首字母/语音/手机同步 |
| TV 商店审核 | 各商店规则不同 | 优先侧载；Play TV 单独适配 |

### T.9 TV 端测试矩阵

| 设备类型 | 型号示例 | Android | 测试重点 |
|---------|---------|---------|---------|
| 低端盒子 | 2016 年盒子 | **7.0/7.1** | 内存、解码、启动速度 |
| 中端盒子 | 小米盒子 4 | 6.0/9.0 | 焦点、遥控、播放 |
| 高端盒子 | 当贝 B3 | 9.0+ | 全功能 |
| 电视自带 | 小米电视 | 8.0+ | 系统集成 |
| 海外 | Fire TV Stick | 7.1 | 无 Google 服务兼容 |
| 模拟器 | Android TV API 24 | 7.0 | 基线兼容 |

**最低要求**：4 台真机，至少 1 台 Android 7.x。

### T.10 TV 端工作量

| 任务 | 周期 |
|------|------|
| 形态判定 + 双入口 | 0.5 周 |
| 焦点系统 + 遥控映射 | 1.5 周 |
| 十英尺主题 + 布局 | 1.5 周 |
| 播放器控制栏焦点化 | 0.5 周 |
| 老设备适配 + 真机测试 | 1-1.5 周 |
| **合计** | **3-5 周** |

---

## 二之补二：Android 5.0 (API 21) 兼容专章（⚠️ 已废弃，保留作降级参考）

> **D12 更新**：TV 最低版本已定为 **Android 7.0 (API 24)**，本章内容**不再需要**。
> 保留此章仅供「未来若需降级支持 API 21 老设备」时参考。
> 依据：Flutter 3.47 官方支持矩阵标注 `Unsupported: 23 and earlier`。

### A21.1 硬约束总览

| 约束 | 说明 | 影响 |
|------|------|------|
| Flutter minSdk | 21 是官方下限 | 不能再低 |
| Impeller | API 21 不支持 | **必须回退 Skia 渲染** |
| 多 Dex | API 21 需手动开启 | `multiDexEnabled true` |
| Java 8+ API | 需脱糖 | `desugar_jdk_libs` |
| 插件升级 | 多数新版要求 minSdk 23 | **必须锁定版本** |
| Media3 | minSdk 21 ✅ | 可用，功能需验证 |
| libVLC Android | 支持 API 21 ✅ | 全格式回退 |

### A21.2 Gradle 配置（必需）

```gradle
android {
    compileSdk 34
    ndkVersion "25.1.8937393"

    defaultConfig {
        applicationId "com.vbox.player"
        minSdk 21              // Android 5.0
        targetSdk 34
        multiDexEnabled true   // ⚠️ API 21 必需
        ndk { abiFilters 'armeabi-v7a', 'arm64-v8a', 'x86_64' }
    }

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
        coreLibraryDesugaringEnabled true   // ⚠️ 必需
    }
    kotlinOptions { jvmTarget = '17' }

    buildTypes {
        release {
            minifyEnabled true
            shrinkResources true
            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
        }
    }

    splits {
        abi {
            enable true
            reset()
            include 'armeabi-v7a', 'arm64-v8a', 'x86_64'
            universalApk true    // 同时产出通用包，方便测试
        }
    }
}

dependencies {
    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.0.4'  // ⚠️ 锁 2.0.4
    implementation 'androidx.multidex:multidex:2.0.1'                 // ⚠️ API 21 必需
    implementation 'androidx.media3:media3-exoplayer:1.3.1'
    implementation 'androidx.media3:media3-exoplayer-hls:1.3.1'
    implementation 'androidx.media3:media3-ui:1.3.1'
    implementation 'org.videolan.android:libvlc-all:3.6.0'            // 全格式回退
}
```

⚠️ `desugar_jdk_libs` **锁定 2.0.4**（最稳），2.1+/3.x 要求更高。

### A21.3 依赖版本锁定清单（关键！）

写入 `contract/docs/android-compat.md`，CI 加守卫。

| 依赖 | 锁定版本 | 上限原因 | 替代方案 |
|------|---------|---------|---------|
| `flutter_secure_storage` | **9.2.4** | v10+ 要求 minSdk 23 | — |
| `permission_handler` | **11.4.0** | v12+ 要求 minSdk 23 | 自研 Channel |
| `wakelock_plus` | **1.2.10** | v2+ 要求更高 | 自研 Channel |
| `media_kit` | 需实测 1.1.x | libmpv Android 需验证 | `video_player` + libVLC |
| `file_picker` | 8.x | 9+ 可能提高要求 | 自研 SAF Channel |
| `path_provider` | 任意 | 无限制 | — |
| `sqflite` | 任意 | 无限制 | — |
| `dio` | 任意 | 无限制 | — |
| `shared_preferences` | 任意 | 无限制 | — |
| `crypto` / `cryptography` | 任意 | 纯 Dart | — |

**CI 守卫脚本：**
```bash
#!/bin/bash
# scripts/check-min-sdk21.sh
LOCKED="flutter_secure_storage:9.2.4 permission_handler:11.4.0 wakelock_plus:1.2.10"
FAIL=0
for pair in $LOCKED; do
  name="${pair%%:*}"; expect="${pair##*:}"
  actual=$(grep -A2 "^  $name:" pubspec.lock | grep 'version:' | awk '{print $2}' | tr -d '"')
  if [ "$actual" != "$expect" ]; then
    echo "❌ $name: 期望 $expect, 实际 $actual（可能破坏 minSdk 21 兼容）"; FAIL=1
  fi
done
[ $FAIL -eq 0 ] && echo "✅ 所有依赖版本符合 minSdk 21 约束" || exit 1
```

### A21.4 渲染引擎配置（必须回退 Skia）

```xml
<meta-data
    android:name="io.flutter.embedding.android.EnableImpeller"
    android:value="false" />
```
⚠️ Flutter 3.29+ 对 Android Impeller 的开关方式可能变化，**第 0 阶段必须实测验证**。

### A21.5 播放器能力探测与回退

```kotlin
// android/app/src/main/kotlin/com/vbox/player/player/CodecCapability.kt
object CodecCapability {

    fun supportsHevcHardware(): Boolean {
        val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        return list.codecInfos.any { info ->
            !info.isEncoder && info.supportedTypes.any { it.equals("video/hevc", true) }
        }
    }

    fun selectBackend(url: String): PlayerBackend {
        val ext = url.substringAfterLast('.', "").lowercase()
        return when {
            ext == "mkv"                                 -> PlayerBackend.LIBVLC  // MKV 保守走 VLC
            isHevc(url) && !supportsHevcHardware()       -> PlayerBackend.LIBVLC  // 无硬解
            else                                         -> PlayerBackend.MEDIA3
        }
    }
    private fun isHevc(url: String) = url.contains("hevc", true) || url.contains("h265", true)
}

enum class PlayerBackend { MEDIA3, LIBVLC }
```

### A21.6 老设备性能优化

| 优化项 | 措施 |
|--------|------|
| 启动速度 | 延迟初始化 Spider 引擎；bundle 异步下载 |
| 内存占用 | 图片降采样（TV 上 720p 足够）；列表懒加载；及时释放 bitmap |
| 网络 | 连接池复用；分片预取限流（老设备降到 1-2 片） |
| 数据库 | 索引优化；分页查询；避免全表扫描 |
| 渲染 | 减少动画；避免阴影/模糊（老 GPU 吃力） |
| 后台 | TV 端避免常驻进程；Node 按需启动 |

### A21.7 Android 5.0 测试清单

| 项 | 验证内容 |
|----|---------|
| 安装 | 双入口 APK 在 API 21 设备可安装 |
| 启动 | 冷启动 < 5s |
| 渲染 | Skia 渲染正常，无画面异常 |
| 播放 | Media3 播放 HLS 正常 |
| 回退 | MKV → libVLC 回退成功 |
| 解码 | 无 HEVC 硬解设备软解可播（可接受卡顿） |
| 形态 | UiMode 判定正确（手机/TV） |
| 焦点 | TV 遥控全流程可操作 |
| 内存 | 峰值 < 500MB（2GB 设备可跑） |
| 网络 | 明文 HTTP 源站可访问 |

### A21.8 minSdk 21 的长期成本

| 成本项 | 说明 |
|--------|------|
| 依赖冻结 | 每次升级依赖都要验证 minSdk 兼容 |
| 功能取舍 | 部分新特性无法使用 |
| 测试负担 | 需长期维护 API 21 测试设备/模拟器 |
| 性能天花板 | 老设备性能上限低，高级功能需降级 |

**建议**：若 TV 设备调研显示 Android 5.0 占比 < 10%，可考虑提到 **API 23 (6.0)**，解锁大量现代依赖。**当前决策维持 API 21。**

---

## 二之补三：第 0 阶段契约层产物（已生成）

### C.1 契约层目录

```
/var/minis/workspace/vbox-contract/
├── schema/
│   ├── schema_v1.sql          ✅ SQLite DDL（9 表 + v1→v4 迁移链）
│   └── prefs_keys_v1.json     ✅ Prefs 键名契约（98 键 + 7 敏感键；v1.5）
├── conformance/fixtures/      ✅ 已交付（SQLite 样本 / 备份样本 / Spider IO，conformance 45/45）
└── docs/                      ✅ 已交付（Spider ABI / 备份格式规范 / android-compat）
```

### C.2 `schema_v1.sql` 要点

- **9 张表**：zhanyuan / apiyuan / subscription / favorite / history / settings / jiexisetting / search_history / download
- **v2 迁移**：重建表（`UNIQUE(name)` → `UNIQUE(name, dyurl)`），必须复刻顺序
- **v3 迁移**：新建 download 表
- **v4 迁移**：`ALTER TABLE download ADD COLUMN` ×4，**均为可空**

### C.3 `prefs_keys_v1.json` 要点

> **v6.2 修订**：本节原为 **v1.0 时期 14 组 / 57 键** 的旧表（含已不存在的 `buffer` 组），
> 与 §C.1 现行键数（**99**）及现行契约矛盾，且该节旧表以「合计」行的表格写法绕过了文档守卫。
> 现按 **契约 v1.2 实况** 重写为 **21 组 / 98 键**（**v1.4 扩为 99 键**，见下表）。

| 组 | 键数 | 说明 |
|----|------|------|
| `_group_subscription` | 3 | 含 skip 项 |
| `_group_spider` | 4 | fallback / dual_mode 等 |
| `_group_remote_source` | 9 | manifest 相关 |
| `_group_player` | 4 | 播放行为 |
| `_group_tmdb` | 3 | 含 1 敏感键 |
| `_group_danmaku` | 2 | 弹幕 |
| `_group_live_tv` | 6 | MDTV 相关 |
| `_group_one_platform` | 5 | 含 **3** 敏感键 |
| `_group_quark_pg` | 10 | 含 1 敏感键 |
| `_group_welfare` | 2 | 福利排序 |
| `_group_debug` | 3 | 调试（v1.5 移除误抓键 `dns_cache_clear`） |
| `_group_legacy_migration` | 1 | **必须迁移**（`vbox_sqlite_migration_done`） |
| `_group_log` | 8 | 日志（v1.2 新增组） |
| `_group_app_settings` | 5 | 应用设置（v1.2 新增组；v1.4 增 `app_ui_form_override`） |
| `_group_welfare_ext` | 6 | 福利扩展（v1.2 新增组） |
| `_group_live_ext` | 2 | 直播扩展（v1.2 新增组） |
| `_group_music` | 2 | 音乐（v1.2 新增组） |
| `_group_tg` | 3 | 电报（v1.2 新增组） |
| `_group_push` | 1 | 推送（v1.2 新增组） |
| `_group_pg_extra` | 2 | 凭据扩展（`credential_extra`，v1.2 新增组） |
| `_group_cloud` | 17 | 云盘（含 2 keychain 键，v1.2 新增组） |
| **合计** | **98** | **21 组** |

**7 个敏感键**（v1.3，B3 裁定）：`app_tmdb_proxy_token`、`one_platform_token`、`one_platform_userkey`、`one_platform_uuid`、`quark_device_id`、`baidu_local_pcs_device_id`、`saved_drive_tokens`

**关键提醒**：`vbox_sqlite_migration_done` 必须迁移，否则 Flutter 首次启动会重复执行 UserDefaults→SQLite 迁移，导致数据重复。

> **结构统一（v6.3 已闭环）**：v6.2 登记的键对象异构（原前 12 组为 `{type, default, desc[, sensitive]}`、
> 后 9 组为 `{type, storage, evidence, desc}`）**已消除** —— 现**全部 98 键**均显式标注 `storage`
> （取值 `userdefaults | keychain | credential_extra`），落实 **D19**。
> `check_contract_sync.py` 新增「**3d. storage 完整性 + Dart↔JSON 逐键比对**」防回归
> （已通过负向测试：人为删去任一键的 `storage` 即硬失败）。

### C.4 待生成的契约产物

| # | 产物 | 路径 | 优先级 |
|---|------|------|--------|
| 1 | Spider ABI 规范 | `vbox-contract/docs/abi_v1.md` | P0 |
| 2 | 备份格式规范 | `vbox-contract/docs/backup_v1.md` | P0 |
| 3 | JSON Schema（SiteConfig） | `vbox-contract/schema/site_v1.json` | P1 |
| 4 | JSON Schema（福利平台） | `vbox-contract/schema/welfare_v1.json` | P1 |
| 5 | JSON Schema（远程源 manifest） | `vbox-contract/schema/manifest_v1.json` | P1 |
| 6 | 一致性 fixtures | `vbox-contract/conformance/fixtures/*` | P1 |
| 7 | `android-compat.md` | `contract/docs/` | P0 |

---

## 二之补四：AI 全量开发执行计划（v4 修订）

> **重大变更（D8/D9/D10）**：本项目**全部代码由 AI 编写**，人力**只做测试**。
> 本节替换原「多人协作执行计划」。

### E.1 执行模型对比

| 维度 | 原假设（人力开发） | **新假设（AI 开发 + 人测）** |
|------|------------------|---------------------------|
| 编码 | 4 人分工，13-16 周 | AI 单次可产出大量代码，**2-4 周可出全量骨架** |
| **关键路径** | 插件层编码（12 周） | **人测验证**（真机不可自动化） |
| **瓶颈** | 人手 | **反馈回路**（AI 无法真机调试） |
| 并行度 | 受人数限制 | 受**上下文窗口**限制 |
| 工期公式 | 人周累加 | **迭代轮次 × 单轮周期** |
| 契约要求 | 人能读懂 | **必须机器可读**（AI 据此生成代码） |
| 验收方式 | 人力评审 | **自动化测试自证** |
| 主要风险 | 进度风险 | **幻觉风险**（代码看似对实则错） |

### E.2 工期重估

```
原模型（4 人，已废弃）：  13-16 周
原模型（单人，已废弃）：  20-28 周

新模型（AI + 人测）：

  真实周期 = max(AI 编码周期, 人测验证周期) × 迭代轮次

  AI 编码：      2-4 周（全量代码 + 单测）
  人测验证：     每轮 1-2 周（真机 + 反馈）
  迭代轮次：     4-6 轮（含修正与回归）

  ├─ 乐观：8-12 周
  └─ 保守：11-16 周（已含 D12 minSdk 24 节省的 3 周）
```

**为什么不是「1 周完成」**：

| 障碍 | 说明 |
|------|------|
| 真机验证不可自动化 | 播放效果、TV 遥控、老设备兼容必须人测 |
| 反馈周期串行 | 「人测 → 结构化报告 → AI 修正 → 复测」是真实串行链 |
| 幻觉累积 | AI 生成的接口/依赖/API 需实测才能确认存在且正确 |
| 环境不可见 | AI 看不到真机日志、崩溃堆栈、画面卡顿 |
| 跨会话记忆限制 | 长周期项目需靠契约+文档维持一致性 |

**结论**：人测是**新的关键路径**，不是 AI。工期不会因 AI 而缩短到周级，但相比纯人力可压缩 **30-50%**。

### E.3 人力真实职责（只做测试）

| 职责 | 具体内容 | 为什么必须人力 |
|------|---------|--------------|
| **真机安装测试** | 各平台安装包在真实设备安装、启动 | AI 无法操作物理设备 |
| **TV 遥控验证** | 焦点流转、按键响应、大屏观感 | 需真实遥控器 + 大屏 |
| **播放效果评估** | 卡顿、音画同步、色彩、字幕 | 主观判断 |
| **Android 7.0 下限设备验证** | API 24 真机运行 | 需真实老硬件 |
| **UI/UX 验收** | 视觉、交互手感、布局 | 主观判断 |
| **跨端数据互通验证** | iOS 导出 → Flutter 导入 | 需两套真实环境 |
| **分发物制作与验证** | 签名、打包、侧载安装验证（**不提交商店**，D11） | 需真实设备与证书管理 |
| **账号相关测试** | 扫码登录、云盘授权 | 需真实账号 |
| **长期稳定性观察** | 挂机、内存泄漏、崩溃 | 需长时间运行 |
| **结构化 Bug 报告** | 现象 → 复现步骤 → 日志 | **这是喂给 AI 的关键输入** |
| **回归验证** | 修复后复测 | 闭环最后一环 |
| **阶段检查报告评审** | 审核 AI 输出的《阶段 N 遗漏检查报告》 | 硬门禁最后一道确认（D13） |

### E.4 关键新增要求：AI 自证能力

AI 开发模式下，**没有自动化测试 = AI 无法自我验证 = 必然积累错误**。

| 要求 | 原因 | 落地方式 |
|------|------|---------|
| **契约机器可读** | AI 据此生成三端代码 | JSON Schema / SQL DDL / ABI 必须结构化（非自然语言） |
| **每模块单测** | AI 自证正确性 | 覆盖率 > 70%，CI 强制门禁 |
| **Conformance 测试** | 三端行为一致 | 同一 fixtures 跑三端，自动比对 |
| **无真机冒烟测试** | 人测前先筛错 | 模拟器 + mock + 单元测试 |
| **结构化反馈模板** | 人测结果喂回 AI | 定义 Bug 报告 schema |
| **代码可追溯** | AI 跨会话无记忆 | 契约 + 文档 + 注释 + commit 规范 |
| **契约变更门禁** | 防止三端漂移 | 契约改动必须同步三端 + 跑 conformance |

### E.5 Bug 反馈闭环（核心流程）

```
┌──────────────────────────────────────────────────────────────┐
│  ① AI 编码（含单测）                                          │
│     └── 产出：代码 + 单测 + 自测报告                          │
├──────────────────────────────────────────────────────────────┤
│  ② AI 自测（无真机）                                          │
│     ├── 单元测试                                              │
│     ├── 模拟器冒烟                                            │
│     ├── conformance 测试（如适用）                            │
│     └── 静态分析 + 编译通过                                    │
│     → 未通过：AI 自行修正，不进入人测                          │
├──────────────────────────────────────────────────────────────┤
│  ③ 产出构建物（APK / EXE / DMG）                              │
├──────────────────────────────────────────────────────────────┤
│  ④ 人测（真机）                                               │
│     ├── 按测试清单执行                                        │
│     ├── 记录现象 + 截图/录屏                                  │
│     └── 填写结构化 Bug 报告 ──────────────┐                   │
├──────────────────────────────────────────┼───────────────────┤
│  ⑤ AI 修复                               │                   │
│     ├── 读 Bug 报告 ◄────────────────────┘                   │
│     ├── 定位代码                                              │
│     ├── 修复 + 补单测                                         │
│     └── 回到 ②                                                │
├──────────────────────────────────────────────────────────────┤
│  ⑥ 人测回归验证 → 通过则关闭 Bug                              │
└──────────────────────────────────────────────────────────────┘
```

**关键**：**步骤 ② 必须拦住大部分错误**，否则人测会成为瓶颈。目标：人测发现的 bug 数 < 单测发现的 bug 数。

### E.6 结构化 Bug 报告模板（人测产出）

```yaml
# bug_report_YYYYMMDD_NNN.yaml
id: BUG-001
title: "TV 端首页焦点在第二行末尾丢失"
platform: android_tv
device: "小米盒子 4 (Android 9)"
build: "v0.1.0+15 (arm64)"
ui_mode: tv

severity: high          # critical | high | medium | low
frequency: always       # always | often | sometimes | once

reproduction:
  - "启动 App 进入 TV 首页"
  - "遥控器向下移动到第二行"
  - "向右移动到最后一个卡片"
  - "再按右键"

expected: "焦点循环到行首 或 跳转到下一行"
actual: "焦点消失，画面无高亮元素"

evidence:
  screenshot: "bug001_focus_lost.png"
  video: "bug001_focus_lost.mp4"
  logcat: "bug001_logcat.txt"

last_working_build: "v0.1.0+14"   # 如已知

notes: "第一行末尾正常，仅第二行复现"
```

**为什么用 YAML**：AI 可直接解析，无需人工二次转述，减少信息损耗。

### E.7 AI 开发阶段编排（迭代驱动）

```
第 0 阶段：契约冻结（AI 主导，1 周）
├── AI 生成 Spider ABI 规范（机器可读）
├── AI 生成备份格式规范
├── AI 生成 JSON Schema ×3
├── AI 生成 conformance fixtures
├── AI 生成 Flutter 项目骨架 + minSdk 24 配置
└── 人工确认：契约完整性评审（1-2 天）

第 1 轮迭代：核心骨架（AI 2 周）  ← 结束后过 E.10b 遗漏检查（代码侧 + 自动化门禁）
├─ AI 产出
│   ├── Dart 领域层（模型/DB/远程源/备份）
│   ├── Android 插件层（Media3 + libVLC + 3 运行时 + Go）
│   ├── Windows/macOS 插件层
│   ├── 手机 UI + 桌面 UI + TV UI
│   └── 全部单测 + conformance 测试
├─ AI 自测（单测 + 模拟器 + 编译）
└─ 人测：延后（真机验收整体并入第 2 轮末批次，见 D30；本轮仅代码侧 + 自动化门禁）

第 2 轮迭代：功能补全（AI 1-2 周 + 人测 1-2 周）
├─ AI 修复上一轮 Bug + 补齐剩余功能（搜索 / 直播 / 网盘 / Spider / 播放器等）
├─ AI 补单测覆盖
└─ 人测：全功能 + TV 遥控 + 老设备（API 24 下限）
   └── 并入 G-09 / G-10 全量真机验收（侧载链路 + 自更新 + 播放器端到端回退 + TV D-pad 焦点，见 D30）

第 3 轮迭代：兼容性与稳定性（AI 1 周 + 人测 1-2 周）
├─ AI 修复真机发现的问题
├─ AI 优化老设备性能
└─ 人测：Android 7.0 下限真机 + TV 矩阵 + 压力测试

第 4 轮迭代：数据互通与边界（AI 1 周 + 人测 1 周）
├─ AI 修复互通问题
└─ 人测：iOS ↔ Flutter 双向数据验证

第 5 轮迭代：发布准备（AI 3-5 天 + 人测 3-5 天）
├─ AI 生成签名配置、构建脚本、自更新器
└─ 人测：安装包验证 + 侧载链路 + 自更新全流程

总计：8-12 周（乐观） / 11-16 周（保守）

⚠️ 每轮迭代结束后，必须执行 E.10b「阶段遗漏检查门禁」通过后才可进入下一轮
```

### E.8 迭代节奏建议

| 迭代周期 | AI 编码 | 人测验证 | 说明 |
|---------|--------|---------|------|
| **1 周节奏** | 5 天 | 2 天 | 快速迭代，适合前期 |
| **2 周节奏** | 7 天 | 7 天 | 稳定节奏，适合中期 |
| **按需** | — | — | Bug 修复可随时插入 |

**建议**：
- 前期（骨架）用 1 周节奏，快速验证方向
- 中期（功能）用 2 周节奏，保证质量
- 后期（兼容）用按需节奏，紧跟真机反馈

### E.9 风险与缓解（AI 开发特有）

| 风险 | 说明 | 缓解 |
|------|------|------|
| **幻觉 API** | AI 编造不存在的库/方法 | 强制编译通过 + 单测覆盖 + 依赖版本锁定 |
| **幻觉依赖** | 引入不存在或版本错误的包 | `pubspec.lock` 锁定 + CI 校验 |
| **契约漂移** | 三端实现偏离契约 | conformance 测试 + 契约变更门禁 |
| **跨会话失忆** | AI 忘记早期决策 | 决策记录（本文档）+ 契约文件 + 代码注释 |
| **过度自信** | AI 声称"已完成"但实际有误 | 强制单测 + 人测兜底 + 明确完成定义 |
| **真机盲区** | AI 看不到真机问题 | 人测 + 结构化反馈 + 日志回传 |
| **返工循环** | 反复修不好同一问题 | 3 次修复失败 → 人工介入分析根因 |
| **人测瓶颈** | 人测排队等 AI | 自动化测试前置，人测只验真机不可自动化部分 |
| **回归遗漏** | 修复引入新问题 | 每次修复补单测 + 定期全量回归 |

### E.10 「完成」的定义（避免 AI 过度自信）

一个模块**只有满足以下全部条件**才算完成：

- [ ] 代码编译通过
- [ ] 单元测试通过，覆盖率 ≥ 70%
- [ ] 静态分析无 error（warning 需说明）
- [ ] conformance 测试通过（如适用）
- [ ] **真机测试通过**（由人力确认）
- [ ] 无已知 blocker 级 Bug
- [ ] 代码有注释说明关键逻辑
- [ ] 契约对齐（如涉及数据）

**AI 不得自称"已完成"除非全部勾选**；人力测试是最后一环，不可省略。

### E.10b 阶段遗漏检查门禁（强制，D13）

> **执行标准（用户明确要求）**：**每开发完成一阶段后，必须先检查有没有遗漏的问题，通过后才能进入下一阶段。**

#### E.10b.1 与 E.10 的关系

| 项 | E.10 | E.10b |
|----|------|-------|
| 粒度 | 单个模块 | **整个阶段** |
| 时机 | 模块交付前 | **阶段交付前** |
| 目的 | 单模块自证 | **阶段级遗漏扫描** |
| 阻断性 | 模块不进人测 | **不通过不进下一阶段** |

嵌套关系：**模块过 E.10 → 阶段过 E.10b**。

#### E.10b.2 六类扫描清单（逐项必过）

**① 契约一致性**
- [ ] 本阶段代码是否全部对齐 `vbox-contract/`（DDL / 键名 / Schema / ABI）
- [ ] 是否新增契约未定义的字段或行为（有 → 删除或补进契约）
- [ ] 契约本身是否需修订（需 → 走变更门禁，同步三端）
- [ ] conformance 测试是否 100% 通过

**② 数据与状态**
- [ ] SQLite 迁移链 v1→v4 完整复刻
- [ ] 旧数据可读写（fixtures 实测）
- [ ] 备份文件可双向互通
- [ ] Prefs 键名 98 个全覆盖，无遗漏无拼错
- [ ] 敏感键按约定处理

**③ 平台差异**
- [ ] 三端（Android 手机 / TV / 桌面）功能对齐
- [ ] TV 焦点全程可见、遥控全流程可达
- [ ] iOS 参照实现未被破坏（零改造原则）
- [ ] minSdk 24 下依赖全部可用
- [ ] 侧载链路验证（安装 + 自更新）

**④ 功能完整性**
- [ ] 本阶段承诺功能全部交付（对照阶段目标）
- [ ] 无「临时绕过 / TODO / 写死值」遗留（必须登记或清除）
- [ ] 5 个 Spider 引擎均能跑通
- [ ] 播放器后端均有回退路径
- [ ] 福利 / 音乐模块隔离生效

**⑤ 质量基线**
- [ ] 单测覆盖率 ≥ 70%
- [ ] 静态分析无 error
- [ ] 无已知 blocker / critical Bug
- [ ] 三端编译全部通过
- [ ] 本阶段所有 Bug 已闭环（修复或登记）

**⑥ 交付物与文档**
- [ ] 本阶段应产出文件齐全
- [ ] 决策记录是否需追加（D13+）
- [ ] 风险清单是否需更新
- [ ] 新增「已知限制」是否已记录
- [ ] 下一阶段输入是否就绪

#### E.10b.3 执行流程

```
阶段 N 开发完成
      ↓
AI 自检（跑 6 类清单）→ 输出《阶段 N 遗漏检查报告》
      ↓
      ├─ 发现问题 → AI 修复 → 重跑自检
      │
      └─ 全部通过 → 人工确认（评审报告）
                        ↓
                        ├─ 人工发现遗漏 → 补充 → 重跑
                        │
                        └─ 确认通过 → 解锁阶段 N+1
```

**关键规则**：
1. AI 必须**主动输出检查报告**，不能只说「已完成」
2. 报告必须**逐项列出**，不能只写「全部通过」
3. 人工**有权否决**，并可要求补充检查项
4. **不通过不得进入下一阶段**（硬门禁）
5. 报告留档，作为阶段验收凭据

#### E.10b.4 报告格式（机器可读，便于 AI 复用）

```yaml
# stage_check_report_stage2.yaml
stage: 2
stage_name: "功能补全"
timestamp: "2026-XX-XX"
completed_at_iteration: "第 2 轮迭代"

checks:
  contract_alignment:
    status: pass
    details: "全部对齐 contract-v1.0"
  data_migration:
    status: pass
    details: "v1→v4 迁移链实测通过，fixtures 32/32"
  platform_parity:
    status: partial
    details: "TV 焦点第 3 行末尾丢失 1 处（已登记 BUG-018）"
  feature_complete:
    status: pass
    details: "本阶段 24 项功能全部交付"
  quality_gate:
    status: fail
    details: "单测覆盖率 68%（目标 70%）"
  deliverables:
    status: pass
    details: "文档与构建物齐全"

blockers:
  - id: BUG-018
    desc: "TV 焦点在第三行末尾丢失"
    severity: medium
    plan: "下阶段修复"

verdict: blocked        # pass | blocked
block_reason: "单测覆盖率未达标（68% < 70%）"
next_action: "补测至 70% 后重跑本检查"
```

#### E.10b.5 各阶段检查重点

| 阶段 | 检查重点 |
|------|---------|
| 第 0 阶段（契约冻结） | 契约完整性、机器可读性、minSdk 24 环境验证 |
| 第 1 轮（核心骨架） | 三端可编译可启动、契约对齐、单测基线（**真机验收后移至第 2 轮末**，见 D30，本轮不含真机项） |
| 第 2 轮（功能补全） | 功能齐备、Spider 5 引擎、播放器回退 + **G-09 / G-10 全量真机验收**（侧载链路 / 自更新 / 播放器端到端回退 / TV 焦点与遥控） |
| 第 3 轮（兼容稳定） | API 24 下限真机、TV 矩阵、压力测试 |
| 第 4 轮（数据互通） | iOS ↔ Flutter 双向、备份一致性 |
| 第 5 轮（发布准备） | 签名、安装、自更新全链路 |

### E.11 工具链要求（AI 开发必需）

| 工具 | 用途 | 必要性 |
|------|------|--------|
| **Flutter 分析器** | `flutter analyze` 静态检查 | 必需 |
| **单测框架** | `flutter_test` + `mockito` | 必需 |
| **conformance runner** | 三端一致性比对 | 必需 |
| **CI（多平台）** | 自动构建三端 | 必需 |
| **契约校验器** | 校验代码是否对齐契约 | 必需 |
| **Bug 报告模板** | 结构化人测反馈 | 必需 |
| **日志收集** | 真机日志回传 | 必需 |
| **崩溃上报** | 真机崩溃收集 | 建议 |
| **截图/录屏工具** | 人测取证 | 建议 |

### E.12 成功指标

| 指标 | 目标 | 说明 |
|------|------|------|
| 单测覆盖率 | ≥ 70% | AI 自证基础 |
| 人测发现 bug 占比 | < 50% | 大部分应由单测拦住 |
| 单轮迭代 Bug 修复率 | ≥ 80% | 反馈闭环效率 |
| conformance 通过率 | 100% | 三端一致性 |
| 同问题返工次数 | ≤ 2 | 超过则人工分析根因 |
| 真机崩溃率 | < 0.1% | 稳定性 |
| 总迭代轮次 | ≤ 6 | 控制返工 |

---

## 二之补五：Android TV 版本分布与 minSdk 定稿（v4 新增）

> 依据 D12 决策。本节数据来源于**联网查证的官方权威来源**，非估算。

### V.1 决定性证据：Flutter 官方支持矩阵

**来源**：`https://docs.flutter.dev/reference/supported-platforms`（Flutter 3.47，页面更新 2026-09-22）

| 平台 | 架构 | Supported | CI tested | Unsupported |
|------|------|-----------|-----------|-------------|
| **Android** | x64 / Arm32 / Arm64 | **24 → 37** | **24 → 36** | **23 and earlier** |
| iOS | Arm64 | 15 → 27 | 18, 26 | 14 and earlier |
| Windows | x64 / Arm64 | 10, 11 | 10 | 8 and earlier |
| macOS | x64 / Arm64 | Monterey(12) → Golden Gate(27) | Sequoia(15) | Big Sur(11) and earlier |

**引擎源码实证**（`packages/flutter_tools/lib/src/android/gradle_utils.dart`）：
```dart
const minSdkVersionInt = 24;
const minSdkVersion = '$minSdkVersionInt';
```

**Gradle 插件默认值**（`FlutterExtension.kt`）：
```kotlin
val compileSdkVersion: Int = 36
val minSdkVersion: Int = 24      // Flutter 项目默认
val targetSdkVersion: Int = 36
```

**源码中的过旧检查**（把 16-23 判为过旧）：
```dart
final tooOldMinSdkVersionEqualsMatch = RegExp(
  r'(?<=^\s*)minSdk(Version)?\s*=\s*(1[6789]|2[0123])(?=\s*(?://|$))',
);
```

**结论**：**Flutter 官方最低支持 API 24**。API 21 属于「可配置但官方不支持、不测试、无保障」的状态。

### V.2 原 API 21 方案的问题（修正依据）

| 问题 | 说明 |
|------|------|
| 官方不支持 | Flutter 标注 `Unsupported: 23 and earlier`，不测试、不修 bug |
| 需多 Dex | `multiDexEnabled true` + `androidx.multidex` |
| 需 Java 8 脱糖 | `coreLibraryDesugaringEnabled` + `desugar_jdk_libs:2.0.4` |
| 需回退 Skia | API 21 不支持 Impeller，需显式关闭 |
| 依赖被迫锁版 | `flutter_secure_storage` 9.2.4、`permission_handler` 11.4.0、`wakelock_plus` 1.2.10 |
| CI 不覆盖 | 官方 CI 从 24 起测，21 上出问题无参照 |
| 测试负担 | 需长期维护 API 21 真机/模拟器 |
| **额外工期** | **+2-3 周**（锁版调试 + 老设备适配 + 兼容测试） |

### V.3 全球 Android 版本分布（已查证，精确数据）

**来源 A**：`https://gs.statcounter.com/android-version-market-share/mobile/worldwide`（Mobile, Worldwide, Aug 2026）

| 版本 | 全球份额 |
|------|---------|
| Android 16 | 23.29% |
| Android 15 | 14.82% |
| Android 13 | 14.78% |
| Android 14 | 14.21% |
| Android 12 | 10.55% |
| Android 11 | 8.54% |
| Android 10 | 4.58% |
| Android 9 (Pie) | 2.25% |
| Android 5.0 (Lollipop) | 1.72% |
| 其他 | 5.25% |

**来源 B**：`https://apilevels.com/`（累积使用率，更新于 2026-05-28，基于 2026-04 StatCounter 数据）

| API | 版本 | **累积使用率**（≤该版本合计） |
|-----|------|------------------------|
| **21** | Android 5.0 | **99.8%** |
| 22 | Android 5.1 | 98.2% |
| **23** | Android 6.0 | **98.0%** |
| **24** | **Android 7.0** | **96.6%** |
| 25 | Android 7.1 | 96.4% |
| 26 | Android 8.0 | 96.1% |
| 28 | Android 9 | 93.5% |
| 30 | Android 11 | 86.9% |
| 34 | Android 14 | 54.5% |
| 36 | Android 16 | 22.3% |

**结论（精确）**：

| 对比 | 覆盖率差异 |
|------|-----------|
| API 21 vs API 24 | 99.8% - 96.6% = **仅差 3.2%** |
| API 23 vs API 24 | 98.0% - 96.6% = **仅差 1.4%** |

即：**选择 API 24 只放弃 3.4% 的设备**，而非此前粗略估计的 12-18%。

### V.3b 现代依赖对 minSdk 的硬性要求（关键发现）

**来源**：`apilevels.com`（经官方变更记录核对）

| 依赖/组件 | 最低 minSdk | 生效时间 |
|----------|------------|---------|
| **Jetpack / AndroidX 全系列** | **23** | 2025-06 起 |
| Google Play Services | 23 | 2024-07 起（v24.28+） |
| Jetpack Compose | 21 | — |
| AndroidX（旧） | 19 | 2023-10 起 |
| AndroidX（更早） | 21 | 2024-04 起 |

**关键推论**：即使强行配置 `minSdk 21`，**现代 AndroidX 依赖已不再支持**——必须降级到旧版 AndroidX，进而牵连整个依赖树。这从工程上进一步印证 **API 24 是正确选择**。

### V.4 Android TV 生态现状（含查证限制说明）

**已确认事实：**

| 事实 | 来源 | 影响 |
|------|------|------|
| Fire TV 2026 新品改用 **Vega OS**（非 Android） | developer.amazon.com 设备规格页 | Fire TV 不再构成 Android 7.0 以下的主要考量 |
| 历史 Fire TV 从 Android 5.1 起步，已停产迭代 | 同上 | 存量占比持续下降 |
| 国内盒子多为 AOSP 定制（小米/当贝/天猫魔盒） | 设备实测（`ro.build.version.sdk` 可知） | `UiModeManager` 判定可能不准，需三重判定 |
| 运营商盒子系统锁死 | 设备实测 | 难侧载，不纳入支持范围 |
| 标准 Android TV 国内几乎不存在 | 无 Google 服务 | Google Play TV 适配可跳过 |

**⚠️ 查证限制说明（TV 专项数据无法从公开渠道获得）：**

经实际联网尝试，**未能获得权威的 Android TV 专项版本分布数据**。原因：

| 尝试的来源 | 结果 |
|-----------|------|
| `developer.android.com/about/dashboards` | 连接失败（该面板 Google 自 2018 年起已停止更新） |
| StatCounter | 仅区分 Desktop / Mobile / Tablet，**不区分 TV** |
| Counterpoint / IDC 中国智能电视报告 | 公开页面无版本细分，需付费 |
| Wikipedia / DuckDuckGo API | 当前网络环境不可达 |

**因此 TV 专项覆盖率采用「基于 Android 版本年份 + TV 设备生命周期」的合理外推（非实测数据）：**

| TV 区间 | 外推依据 | 推断覆盖 |
|---------|---------|---------|
| API 24 (Android 7.0, 2016) | TV 换代慢于手机；2016 年后盒子为主流 | **约 93-96%** |
| API 21 (Android 5.0, 2014) | 含 2014-2015 老盒子 | 约 97-99% |

**说明**：TV 设备比手机更保守，API 24 实际覆盖率可能略低于手机的 96.6%，但保守估计不低于 90%。**此项为外推估算，建议在真机测试阶段实测确认**（通过 `ro.build.version.sdk` 统计）。

### V.5 D12 定稿：minSdk 24

| 项 | 值 |
|----|----|
| **minSdk** | **24（Android 7.0）** |
| compileSdk | 36 |
| targetSdk | 36 |
| 覆盖率 | **96.6%**（apilevels 累积数据，2026-04）；放弃设备仅 **3.4%** |
| 官方支持 | ✅ Supported 24-37, CI tested 24-36 |
| 放弃设备 | Android 5.0/5.1/6.0（合计 **3.4%**，且持续下降） |

### V.6 minSdk 24 下的配置简化

**移除以下内容**（原 API 21 方案需要，现不需要）：

| 项 | 状态 |
|----|------|
| `multiDexEnabled true` | ❌ 移除 |
| `androidx.multidex` 依赖 | ❌ 移除 |
| `coreLibraryDesugaringEnabled` | ❌ 移除 |
| `desugar_jdk_libs` 依赖 | ❌ 移除 |
| `EnableImpeller = false` | ❌ 移除（可正常用 Impeller） |
| `check-min-sdk21.sh` CI 守卫 | ❌ 移除 |
| 依赖锁版（3 项） | ❌ 解除 |

**最终 Gradle 配置**：
```gradle
android {
    compileSdk 36
    ndkVersion "25.1.8937393"

    defaultConfig {
        applicationId "com.vbox.player"
        minSdk 24              // Android 7.0
        targetSdk 36
        ndk { abiFilters 'armeabi-v7a', 'arm64-v8a', 'x86_64' }
    }

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = '17' }

    buildTypes {
        release {
            minifyEnabled true
            shrinkResources true
            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
        }
    }

    splits {
        abi {
            enable true
            reset()
            include 'armeabi-v7a', 'arm64-v8a', 'x86_64'
            universalApk true
        }
    }
}

dependencies {
    implementation 'androidx.media3:media3-exoplayer:1.3.1'
    implementation 'androidx.media3:media3-exoplayer-hls:1.3.1'
    implementation 'androidx.media3:media3-ui:1.3.1'
    implementation 'org.videolan.android:libvlc-all:3.6.0'
}
```

**依赖版本（不再受限）**：

| 依赖 | 原锁定 | minSdk 24 后 |
|------|--------|-------------|
| `flutter_secure_storage` | 9.2.4 | 最新稳定版 |
| `permission_handler` | 11.4.0 | 最新稳定版 |
| `wakelock_plus` | 1.2.10 | 最新稳定版 |
| `media_kit` | 需实测 1.1.x | 最新稳定版 |
| `file_picker` | 8.x | 最新稳定版 |

### V.7 API 24 的播放器能力（对比 API 21）

| 能力 | API 21 | **API 24** |
|------|--------|-----------|
| Media3 | ✅ | ✅ |
| libVLC | ✅ | ✅ |
| 系统 PiP | ❌（需 8.0） | ❌（仍需 8.0，可降级小窗） |
| HEVC 硬解 | 依赖设备 | 依赖设备（同） |
| 前台服务 | ✅ | ✅ |
| FileProvider | ✅（API 24 引入） | ✅ **原生** |
| 通知渠道 | ❌（需 26） | ❌（需 26） |
| 明文流量默认 | 允许 | 允许（API 28 才默认禁） |

**关键收益**：`FileProvider` 是 API 24 引入的 —— 自更新安装恰好需要它。

### V.8 Android 6.0 及以下设备（放弃）

| 版本 | 全球份额 | 处理 |
|------|---------|------|
| Android 6.0 (API 23) | ~1.8% | 放弃 |
| Android 5.1 (API 22) | ~1.6% | 放弃 |
| Android 5.0 (API 21) | 1.72% | 放弃 |
| **合计** | **约 3.4%** | 放弃 |

**若确有老设备需求**：可后续单独发一个 `vbox-legacy.apk`（minSdk 21），但不纳入首期范围。

### V.9 测试矩阵更新（minSdk 24）

| 设备类型 | 型号示例 | Android | 测试重点 |
|---------|---------|---------|---------|
| 老设备下限 | 2016 年盒子 | **7.0/7.1** | 启动、内存、解码 |
| 中端盒子 | 小米盒子 4 | 8.1/9.0 | 焦点、遥控、播放 |
| 高端盒子 | 当贝 B3 | 9.0+ | 全功能 |
| 电视自带 | 小米电视 | 8.0+ | 系统集成 |
| 模拟器 | Android API 24 | 7.0 | 基线兼容 |

**最低要求**：4 台真机，其中至少 1 台 Android 7.x。

### V.10 工期影响

| 项 | 影响 |
|----|------|
| 移除多 Dex / 脱糖 / Skia 回退 / 锁版 | **-1.5 周** |
| 移除老设备（API 21）专项适配 | **-1 周** |
| 移除 CI 守卫脚本 | **-0.5 周** |
| **合计节省** | **约 -3 周**（相对 API 21 方案） |

**补充**：API 24 实际覆盖率 96.6%（仅放弃 3.4% 设备），而 API 21 方案的额外成本（多 Dex、脱糖、Skia 回退、依赖降级）实际上是为 3.2% 的用户付出 3 周工期 —— **性价比极低**。

**修订工期**：8-12 周（乐观）/ **11-16 周**（保守，原 12-18 周）。

## 二之补六：侧载分发方案（v4 新增，D11）

> **D11 决策**：全部产出侧载分发，**不提交任何应用商店**。

### S.1 侧载对方案的简化

**不需要做的事（省约 2-3 周工作量）：**

| 原计划 | 侧载后 |
|--------|--------|
| Google Play 政策适配 | ✅ 省 |
| Google Play TV 审核 | ✅ 省 |
| Microsoft Store 打包 | ✅ 省 |
| macOS App Store 公证 | ✅ 省（可选做公证减警告） |
| 各 TV 商店适配 | ✅ 省 |
| 商店素材（截图/描述/隐私政策） | ✅ 省 |
| 商店隐私合规审核 | ✅ 省 |
| 应用内购/订阅适配 | ✅ 省 |

**但需加强的事：**

| 项 | 原因 |
|----|------|
| 自动更新机制 | 无商店分发，需自建 |
| 签名管理 | 自管证书，更新必须同签名 |
| 安装引导（App 内 + 文档） | 用户需知道怎么装 |
| 局域网安装服务（TV） | TV 无浏览器，需辅助安装 |
| 版本兼容提示 | 无商店自动过滤，需 App 内提示 |

### S.2 各平台侧载方式

| 平台 | 侧载方式 | 难度 | 关键点 |
|------|---------|------|--------|
| **Android 手机** | 直接安装 APK | ⭐ | 允许"未知来源" |
| **Android TV** | ADB / U 盘 / 局域网 / 电视助手 | ⭐⭐ | 部分盒子限制第三方 |
| **Windows** | 直接运行 EXE | ⭐ | SmartScreen 警告可绕过 |
| **macOS** | 右键打开 / 移除隔离属性 | ⭐⭐ | Gatekeeper 拦截 |
| **iOS** | TrollStore | ⭐⭐⭐ | 已有方案 |

**macOS 移除隔离属性（用户操作）：**
```bash
# 用户侧载后若被 Gatekeeper 拦截
xattr -dr com.apple.quarantine /Applications/vbox.app
```

### S.3 自动更新设计（核心）

参考 iOS 现有 `UpdateManager.swift` 的实现，抽象为跨平台 Dart 服务：

```
┌─────────────────────────────────────────────────────┐
│  统一更新服务（Dart）                                │
│  ├── 检查：GET GitHub releases/latest               │
│  ├── 比对：当前版本 vs 远程版本（cleanVersion 逻辑）  │
│  ├── 下载：三级代理降级链                            │
│  │    ghfast.top → gh-proxy.com → 直连              │
│  └── 安装：分平台分派                                │
│      ├── Android: FileProvider + Intent             │
│      ├── Windows: 下载 EXE + 启动安装器              │
│      └── macOS: 下载 DMG + open                      │
└─────────────────────────────────────────────────────┘
```

**Dart 接口设计：**
```dart
abstract class UpdateService {
  Future<UpdateInfo?> checkForUpdate();
  Future<void> downloadAndInstall(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
  });
  Stream<UpdateState> get stateStream;
}

class UpdateInfo {
  final String version;
  final String build;
  final String downloadUrl;
  final String releaseNotes;
  final String releasePageUrl;
}
```

### S.4 Android 自更新（侧载核心）

```xml
<!-- AndroidManifest.xml -->
<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"
    android:maxSdkVersion="28" />

<provider
    android:name="androidx.core.content.FileProvider"
    android:authorities="${applicationId}.fileprovider"
    android:exported="false"
    android:grantUriPermissions="true">
    <meta-data
        android:name="android.support.FILE_PROVIDER_PATHS"
        android:resource="@xml/file_paths" />
</provider>
```

```xml
<!-- res/xml/file_paths.xml -->
<paths>
    <external-files-path name="downloads" path="Download/" />
    <files-path name="internal" path="updates/" />
</paths>
```

```kotlin
// Kotlin 侧安装逻辑
fun installApk(context: Context, apkFile: File) {
    val uri = FileProvider.getUriForFile(
        context, "${context.packageName}.fileprovider", apkFile)

    val intent = Intent(Intent.ACTION_VIEW).apply {
        setDataAndType(uri, "application/vnd.android.package-archive")
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        // Android 8.0+ 需用户授权"安装未知应用"
        if (!context.packageManager.canRequestPackageInstalls()) {
            // 引导到设置页
            val settings = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                .setData(Uri.parse("package:${context.packageName}"))
            context.startActivity(settings)
            return
        }
    }
    context.startActivity(intent)
}
```

⚠️ **版本适配要点**：
| Android 版本 | 行为 |
|-------------|------|
| 5.0-7.1 | 直接 `ACTION_VIEW` 安装，无需权限 |
| 8.0+ | 需 `REQUEST_INSTALL_PACKAGES` 权限 + 用户手动授权 |
| 10+ | 建议下载到 `getExternalFilesDir()`（免存储权限） |

### S.5 Android TV 侧载难点与方案

| 难点 | 说明 | 方案 |
|------|------|------|
| 无浏览器 | 大部分 TV 无浏览器 | ADB / U 盘 / 局域网服务 |
| 无文件管理器 | 需第三方 | **内置局域网安装服务** |
| ADB 未开启 | 用户不知怎么开 | 提供图文引导 |
| 盒子锁第三方安装 | 运营商盒子 | 不支持，明确放弃 |
| 遥控器输入难 | 输 URL 痛苦 | 二维码 / 短码 / 手机同步 |

**首次安装方案（鸡生蛋问题）：**

```
TV 上还没有 App 时，只能：
  ① ADB：adb connect <TV_IP>:5555 && adb install vbox-tv.apk
  ② U 盘：拷贝 APK → TV 文件管理器安装
  ③ 电视助手 App：小米电视助手 / 当贝助手等
  ④ 部分盒子：内置"U 盘安装"入口

首次安装后，后续更新走 App 内自更新
```

**局域网安装服务（可选，增强体验）：**
```
┌──────────┐   局域网 HTTP     ┌──────────────┐
│  PC/手机  │ ───────────────→ │  Android TV  │
│  浏览器   │  http://TV:8888  │  vbox 安装助手│
└──────────┘                  └──────────────┘
  上传 APK  →  TV 端保存并触发安装
```

**注意**：此功能需**先安装 vbox**，所以仅用于**后续更新**和**传递 APK 给其他设备**。

### S.6 签名管理（关键）

| 平台 | 签名要求 | 风险 |
|------|---------|------|
| **Android** | **自签名即可，但更新必须同签名** | ⚠️ **密钥丢失 = 无法发布更新** |
| Windows | 可选代码签名 | 不签 SmartScreen 警告（侧载可接受） |
| macOS | 可选签名 + 公证 | 不签需右键打开 |
| iOS | TrollStore 无需签名 | 现有方案 |

**Android 签名密钥管理：**
```bash
# 生成密钥（一次性）
keytool -genkeypair -v \
  -keystore vbox-release.jks \
  -alias vbox \
  -keyalg RSA -keysize 2048 \
  -validity 10000

# 签名
apksigner sign --ks vbox-release.jks --out vbox-signed.apk vbox-unsigned.apk
```

⚠️ **密钥必须离线备份**（至少 2 处），并记录口令。丢失后用户**必须卸载重装**（无法覆盖更新）。

### S.7 版本分发渠道

**推荐：GitHub Releases（复用现有 iOS 方案）**

```
https://github.com/q2787244398/app/releases/latest/download/vbox.ipa    (iOS)
https://github.com/q2787244398/app/releases/latest/download/vbox-arm64.apk    (Android)
https://github.com/q2787244398/app/releases/latest/download/vbox-v7a.apk      (Android 老设备)
https://github.com/q2787244398/app/releases/latest/download/vbox-setup.exe    (Windows)
https://github.com/q2787244398/app/releases/latest/download/vbox.dmg          (macOS)
```

**代理降级链（必须复刻 iOS 现有实现）：**
```
1. https://ghfast.top/<原始URL>
2. https://gh-proxy.com/<原始URL>
3. 直连 <原始URL>
```

### S.8 App 内安装引导（首启体验）

```
首启时检测：
├── Android 手机：提示"允许未知来源"引导
├── Android TV：提示 ADB / U 盘安装方式（若首装）
├── Windows：提示 SmartScreen 绕过方法
└── macOS：提示 Gatekeeper 绕过方法
```

**建议**：在设置页提供"如何安装/更新"的图文说明。

### S.9 侧载对工期的影响

| 项 | 影响 |
|----|------|
| 商店适配 | **-1 周** |
| 商店素材准备 | **-0.5 周** |
| 自动更新机制 | **+1 周**（三端） |
| 局域网安装服务 | **+0.5 周**（TV，可选） |
| 安装引导 UI | **+0.5 周** |
| **净影响** | **约 ±0 周**（省与增抵消） |

**但风险显著降低**：无商店审核，不会被拒；无政策合规风险。

### S.10 侧载分发的风险

| 风险 | 说明 | 缓解 |
|------|------|------|
| 用户安装困难 | 不懂侧载 | 图文引导 + 局域网安装 |
| 安全软件拦截 | 杀软误报 | 代码签名（Windows） |
| 更新失败 | 签名不一致 | **密钥安全备份** |
| 老版本残留 | 用户不更新 | App 内强提示 |
| 分发渠道不稳定 | GitHub 被墙 | 三级代理 + 备用渠道 |
| iOS 依赖 TrollStore | 需越狱环境 | 现有方案，用户已知 |

---

## 二之补七：仓库布局与推送流程（v4 新增，D14-D16）

### R.1 仓库布局

| 仓库 | 用途 | 状态 |
|------|------|------|
| **`q2787244398/vboxapp`** | **项目唯一开发仓库**（iOS 现有代码 + Flutter 三端 + 契约层） | ✅ 已就位 |
| `q2787244398/app` | **冻结归档**（仅历史备份，改动不回流） | ✅ 未改动 |
| `vbox-Ai/api` | 远程源配置（外部依赖，非本项目仓库） | ✅ 只读 |

**原则**：
- **vboxapp 是唯一真相源（single source of truth）**
- 所有开发（含 iOS 侧修改）都在 vboxapp 进行
- `app` 仓库冻结，仅在需要查阅历史时访问

### R.2 迁移记录（2026-09-29）

| 项 | 值 |
|----|----|
| 操作 | vboxapp 清空 → 迁入 app 全部代码 |
| 清空前 | 236 文件（TVS 逆向重建项目） |
| 迁入后 | **481 项**（全仓，含 `vbox/` 274 项） |
| Commit | `bef4e9e` feat: migrate vbox iOS project |
| 校验 | 文件列表 diff 一致 + 抽样 MD5 匹配 |
| 源仓库影响 | **无**（app 保持原样） |

**vboxapp 当前结构**（v6.2 复核后计数）：
```
vboxapp/
├── vbox/                        274 项  Swift 主工程（189 .swift）
├── quickjs/                      67 项  QuickJS 引擎
├── .uploads/                     65 项  素材（不推送）
├── scripts/                      34 项  构建/校验脚本（含 legacy/ 与 Crypto/）
├── remote-source-repo-template/  13 项  远程源模板
├── .github/                      11 项  CI workflow
├── go-proxy/                      7 项  Go 代理
├── lib/ test/ contract/ docs/          Flutter 多端代码与契约（v6 起）
├── Podfile / Podfile.lock
├── vbox.xcodeproj
└── README.md / CHANGELOG.md / docs/archive/修复说明.md
```

> 计数口径：`VBOX_PLAN_v6.47.md` 为唯一主文档；`修复说明.md` 已于 v6.1 归档至 `docs/archive/`。

### R.3 每阶段推送流程（D15）

**触发时机**：阶段开发完成 → **E.10b 遗漏检查通过** → 人工确认 → 推送

```
阶段 N 开发完成
      ↓
AI 自检（E.10b 六类扫描）→ 输出检查报告
      ↓
      ├─ 不通过 → 修复 → 重跑
      └─ 通过 → 人工确认
                  ↓
            ① 更新版本号
            ② 提交（规范 commit message）
            ③ 推送到 vboxapp/main
            ④ 打 tag（stage-N）
            ⑤ 远程校验
```

**推送检查清单**：
- [ ] E.10b 报告 verdict = pass
- [ ] 人工已确认
- [ ] 三端编译通过
- [ ] 无未提交的临时文件
- [ ] commit message 规范（feat/fix/chore + 阶段标识）
- [ ] 推送后校验远程 blob 数

**Commit message 规范**：
```
<type>(stage-N): <描述>

- 本阶段交付内容
- 已知限制（如有）
- Stage check: pass (E.10b)
```

**Tag 规范**：`stage-0` / `stage-1` / ... / `stage-5`

### R.4 推送通道

| 项 | 值 |
|----|----|
| 直连 HTTPS | ❌ 当前环境超时 |
| 代理通路 | ✅ `ghfast.top` / `gh-proxy.com` 可用 |
| 推送命令 | `git push origin main`（remote 已含 token） |

**注意**：Claude/AI 执行推送需要 `GITHUB_TOKEN`（已配置，权限 `admin: true`）。

### R.5 与 D1（契约共享）的协同

| 决策 | 落实 |
|------|------|
| D1 契约共享 | iOS 现有实现（`vboxapp/vbox/`）作为**初始基线与契约来源** |
| D14 唯一仓库 | **所有开发（iOS + Flutter）均在 vboxapp 进行** |
| D15 推送节奏 | 每阶段推 vboxapp |
| D16 源仓库归档 | `app` 冻结，不再回流 |

**契约优先流程（最终）**：

```
从 vboxapp/vbox/（iOS Swift 实现）提取契约
        ↓
冻结契约（contract-v1.0）
        ↓
三端并行开发（全部在 vboxapp）
        ↓
每阶段完成 → E.10b 遗漏检查 → 推送 vboxapp
```

**已消除的风险**：
- ✅ ~~双份 Swift 代码不同步~~（不再有双份，vboxapp 唯一）
- ✅ ~~iOS 改动需跨仓库同步~~（都在 vboxapp）

**目录规划（vboxapp 内）**：
```
vboxapp/
├── vbox/                 iOS 现有代码（Swift，契约来源 + 后续 iOS 改动）
├── lib/                  Flutter 三端（新建）
├── android/              Flutter Android 壳（新建）
├── macos/                Flutter macOS 壳（新建）
├── windows/              Flutter Windows 壳（新建）
├── contract/             契约层（SQLite DDL / Prefs / Schema / ABI）
├── conformance/          一致性测试
├── go-proxy/             Go 代理（复用现有）
├── quickjs/              QuickJS（复用现有）
└── .github/              CI（改造为多端流水线）
```

⚠️ **注意**：现有 `vbox.xcodeproj` 与 `Podfile` 是 iOS 工程配置，Flutter 端需**新建独立工程结构**，避免相互干扰。

## 三、结论（v4 定稿）

vbox 是一个功能丰富的 iOS 聚合视频播放器，代码质量较高，架构清晰。**经远程源仓库 `vbox-Ai/api` 交叉验证 + 十项决策确认后，最终结论如下：**

### 3.1 可行性修订

| 层次 | 初版结论 | v3 最终结论 | 依据 |
|------|---------|-----------|------|
| UI 层 | 100% 可迁移 | **Android/TV/Windows/macOS 新建；iOS 保留 SwiftUI** | SwiftUI 189 文件，约 40 视图 |
| 业务逻辑 | 60-70% | **40-55%**（Dart 需重写；Swift 沿用现有） | SpiderManager 6075 行单体；5 引擎差异 |
| 数据层 | 100% | **100%**（靠契约保证互通） | 9 表 + 4 次迁移，纯 SQLite |
| 播放器 | 需原生插件 | **iOS 不迁移**；其余平台独立实现 | 6 后端 + Metal/VT 深度耦合 |
| 脚本运行时 | 需 FFI/进程桥接 | **正确，但成本被低估** | Python 3.14.7 + lxml 自编译 |
| Go 代理 | 源码可复用 | **正确** | 1156 行纯标准库，零依赖 |

### 3.2 最终架构（D1 决策：方案 A4 契约共享）

```
┌──────────────────────────────────────────────────┐
│   契约层（SQLite DDL / Prefs 键名 / JSON Schema  │
│          Spider ABI / 备份格式 / conformance）    │
└────────────┬────────────────────────┬────────────┘
             │                        │
   ┌─────────▼─────────┐    ┌────────▼─────────┐
   │  Flutter 客户端    │    │  iOS 原生客户端   │
   │  （全新开发）      │    │  （零改造，参照） │
   ├───────────────────┤    ├──────────────────┤
   │ Dart 领域层        │    │ Swift 领域层      │
   │ ├ models          │    │ （现有实现）      │
   │ ├ database        │    │                  │
   │ ├ remote_source   │    │                  │
   │ ├ backup          │    │                  │
   │ └ spider_abi      │    │                  │
   ├───────────────────┤    ├──────────────────┤
   │ 5 形态 UI          │    │ SwiftUI（现有）   │
   │ ├ Android 手机     │    │                  │
   │ ├ Android TV       │    │                  │
   │ ├ Windows          │    │                  │
   │ ├ macOS            │    │                  │
   │ └ (Linux 可选)     │    │                  │
   ├───────────────────┤    ├──────────────────┤
   │ 原生插件层         │    │ 原生实现（现有）  │
   │ ├ Player          │    │ ├ 6 播放器后端    │
   │ ├ QuickJS FFI     │    │ ├ JSC/QuickJS    │
   │ ├ Python          │    │ ├ Python 3.14.7  │
   │ ├ Node            │    │ ├ NodeMobile     │
   │ ├ Go Proxy        │    │ ├ Go Proxy       │
   │ └ System          │    │ └ Keychain 等     │
   └───────────────────┘    └──────────────────┘
```

**已否决的方案**：
- ❌ **A1 Flutter 嵌入 iOS**：引擎 +50MB，启动慢，iOS 需改造
- ❌ **A2 flutter_rust_bridge**：需重写领域层为 Rust，成本过高
- ❌ **A3 独立 Dart 服务进程**：进程管理复杂
- ❌ **方案 B 纯 Flutter 三端**：iOS 播放器功能降级，风险高，+6-8 周

**A4 的核心优势**：iOS 零风险、三端完全解耦可并行、iOS 即现成参照实现、数据靠契约互通。

### 3.3 决策落实清单

| 决策 | 落实方式 | 状态 |
|------|---------|------|
| D1 iOS 零改造 | 契约从 iOS 逆向提取；iOS 作为参照实现 | ✅ |
| D2 双形态 APK | 三重 UiMode 判定 + 双 intent-filter + `required="false"` | ✅ 方案已出（第 T 章） |
| D3 ~~Android 5.0~~ | 已被 D12 覆盖（第 A21 章保留作降级参考） | ⚪ 已废弃 |
| **D12 Android 7.0** | **minSdk 24 + 现代依赖 + Impeller + libVLC 回退** | ✅ 方案已出（第 V 章） |
| **D13 阶段遗漏检查** | **六类扫描 + 报告留档 + 不通过硬阻断** | ✅ 方案已出（E.10b） |
| **D14 唯一开发仓库** | **`q2787244398/vboxapp`**（含 iOS + Flutter） | ✅ 已执行 |
| **D15 推送节奏** | **每阶段完成后推送 vboxapp** | ✅ 方案已出（R.3） |
| **D16 源仓库归档** | **`app` 冻结，纯历史备份** | ✅ 未改动 |
| **D4 AI 全量开发** | **全部代码 AI 编写；人力只做测试** | ✅ 方案已出（第 E 章） |
| D5 三端并行 | 契约先行 + AI 批量产出 | ✅ |
| D6 播放器策略 | iOS 不迁移；Android Media3+libVLC；桌面 libmpv | ✅ |
| D7 数据互通 | 契约层（已生成 DDL + Prefs 契约） | 🟡 部分完成 |
| **D8 开发模式** | **AI 编码 + 人测验证闭环** | ✅ |
| **D9 关键路径** | **人测验证（非 AI 编码）** | ✅ |
| **D10 验收方式** | **自动化测试 + conformance 自证** | ✅ |
| **D11 侧载分发** | **不提交商店，GitHub Releases 分发 + App 内自更新** | ✅ 方案已出（第 S 章） |
| **D12 TV 最低版本** | **Android 7.0 (API 24)**（Flutter 官方仅支持 24-37） | ✅ 已定稿（第 V 章） |

### 3.4 关键风险（v4 最终）

| 风险 | 等级 | 缓解 |
|------|------|------|
| **AI 幻觉（不存在的 API/依赖）** | **高** | 强制编译通过 + 单测覆盖 + 依赖锁版 |
| **人测成为瓶颈** | **高** | 自动化测试前置，人测只验不可自动化部分 |
| ~~minSdk 21 依赖冻结~~ | ~~高~~ | ✅ 已解除（D12 定为 API 24） |
| SpiderManager 6075 行拆分 | **高** | 先冻结接口，再拆实现 |
| Python 三端不一致 | **高** | 抽象 ScriptRuntime；长期考虑 JS 重写 |
| **契约漂移** | **高** | conformance 测试 + 契约变更门禁 |
| 福利模块 90 平台 | 中高 | 独立排期，最后迁移 |
| 备份加密跨端一致性 | 中 | conformance 双向验证 |
| TV 老盒子解码能力 | 中 | 能力探测 + libVLC 回退 |
| Node bundle 6.4MB | 中 | 按需下载 + MD5 校验 |
| **跨会话记忆限制** | 中 | 决策记录 + 契约文件 + 代码注释 |

### 3.5 工期最终结论（v4：AI 开发模式）

| 模型 | 工期 | 说明 |
|------|------|------|
| **AI 全量开发 + 人测（推荐）** | **8-12 周（乐观）/ 11-16 周（保守）** | 迭代轮次驱动；含 minSdk 24 节省的 3 周 |
| 原 4 人协作模型 | 13-16 周 | 已废弃 |
| 原单人模型 | 20-28 周 | 已废弃 |
| ~~原 minSdk 21 方案~~ | ~~12-18 周~~ | 已废弃（minSdk 24 省 3 周） |

**工期公式**：
```
真实周期 = max(AI 编码周期, 人测验证周期) × 迭代轮次
         = max(2-4 周, 每轮 1-2 周) × 4-6 轮
```

**关键路径**：**人测验证**（真机不可自动化），非 AI 编码。

**为何不能压缩到周级**：真机验证、TV 遥控、老设备（API 24 下限）、播放效果评估均需人力，且「人测 → 反馈 → AI 修正 → 复测」是真实串行链。

### 3.6 交付物清单

| 交付物 | 路径 | 状态 |
|--------|------|------|
| 本方案（v4 定稿） | `minis://workspace/vbox_flutter_migration_plan.md` | ✅ |
| SQLite DDL 契约 | `minis://workspace/vbox-contract/schema/schema_v1.sql` | ✅ |
| Prefs 键名契约 | `minis://workspace/vbox-contract/schema/prefs_keys_v1.json` | ✅ |
| 远程源仓库快照 | `/var/minis/workspace/vbox-api/` | ✅ |
| 主仓库快照 | `/var/minis/workspace/app-repo/` | ✅ |
| **唯一开发仓库 vboxapp** | `https://github.com/q2787244398/vboxapp` @ `bef4e9e` | ✅ 已迁移（迁入时全仓 481 项） |
| Spider ABI 规范 | `contract/docs/abi_v1.md` | ✅ |
| 备份格式规范 | `contract/docs/backup_v1.md` | ✅ |
| JSON Schema | `contract/schema/{site,welfare,manifest}_v1.json` | ✅ |
| conformance fixtures | `conformance/fixtures/` | ✅（3 类样本） |
| **Bug 报告模板** | `contract/docs/bug_report_template.yaml` | ✅ |
| **android-min-sdk21-compat.md** | `contract/docs/android-compat.md` | ✅（命名与计划不符） |

### 3.7 下一步行动（AI 主导，可立即执行）

**第 0 阶段（AI 1 周 + 人工评审 1-2 天）**

| 序号 | 任务 | 执行方 |
|------|------|--------|
| 1 | 生成 Spider ABI 规范（机器可读） | AI |
| 2 | 生成备份格式规范 | AI |
| 3 | 生成 JSON Schema ×3（SiteConfig / 福利 / manifest） | AI |
| 4 | 生成 conformance fixtures | AI |
| 5 | 生成 Bug 报告模板（YAML） | AI |
| 6 | 生成 Flutter 项目骨架 + minSdk 24 配置 | AI |
| 7 | 输出 `android-min-sdk21-compat.md` | AI |
| 8 | 搭建 CI 骨架（三端构建 + minSdk 守卫 + conformance） | AI |
| 9 | **minSdk 24 环境验证**（编译 + 模拟器冒烟） | AI |
| 10 | 契约完整性评审 | **人工（1-2 天）** |
| 11 | 契约打 tag `contract-v1.0` | AI |

**第 0 阶段验收（AI 自测 + 人工确认）**：
- [ ] 所有契约文件生成完毕
- [ ] minSdk 24 下 Flutter 空项目**编译通过 + 模拟器可跑**
- [ ] Media3 与 libVLC 在 API 24 模拟器**可播放**
- [ ] Impeller 渲染正常（API 24 原生支持）
- [ ] conformance fixtures 就绪
- [ ] CI 能产出 Android/Windows/macOS 空包
- [ ] Bug 报告模板可用

### 3.8 需要持续关注的不确定性

1. ~~Android 5.0 实际占比~~ → ✅ 已查证：Flutter 官方仅支持 API 24+，已定稿 minSdk 24
2. **Chaquopy 授权**：商业项目需确认许可范围；否则改自研 CPython 交叉编译
3. **media_kit Android 在 API 24 的表现**：必须实测，否则需改用 libVLC 直绑
4. **Flutter Impeller 开关方式**：3.29+ 变更，必须实测
5. **TV 商店政策**：若目标是 Google Play TV，需额外适配周期
6. **AI 幻觉率**：若单测拦截率低于预期，需加强契约约束与测试密度
7. **人测人力投入**：迭代期间需稳定的人力测试窗口，否则关键路径阻塞
8. **跨会话一致性**：长周期项目需持续维护契约与决策记录，防止 AI 偏离

---

## 四、细节修正与深度调整建议（新增）

### 4.1 初版方案的错误修正

| 编号 | 初版错误 | 修正 | 影响 |
|------|---------|------|------|
| E1 | 「Play 层 60-70% 可迁移」 | 实际 **40-55%**。SpiderManager 单文件 6075 行、311 KB，且深度依赖 5 种运行时 | 工期翻倍 |
| E2 | 「Python 嵌入式运行时」一句话带过 | iOS 是 **Python 3.14.7 + 自编译 lxml（静态链接 + iphoneos SDK）**，见 `build_lxml_ios.sh`（16.6 KB）。Android/Windows 需完全重做 | 新增 2-3 周 |
| E3 | 「Node 独立进程」未提协议 | 实际有 **5 个端口 + 3 个握手文件**协议 | 需补协议文档 |
| E4 | 未提 `csp_` 类名机制 | 音乐模块 10 个源依赖 `csp_*Guard` 类名 → Node 托管 | 音乐模块需重设计 |
| E5 | 「福利子系统」 | 实际 **90 平台 / 3 分类 / ~100 脚本** | 单模块独立排期 |
| E6 | 未提 6.4 MB Node bundle | 打包体积风险 | 改用按需下载 |
| E7 | 「Java/Kotlin 桥接」泛泛 | Android 无现成 QuickJS/Python/Node 等价物，需自研 | 新增 3-4 周 |

### 4.2 Node 运行时端口与握手协议（必须复刻）

```
端口分配：
  58080  mainPort      kstore bundle 主端口（网盘系统默认）
  2333   catpawPort    catpaw bundle（可选启用）
  58082  healthPort    健康探测端口（崩溃检测）
  58083  lxPort        lx-music 桥接服务端口
  58084  lxHealthPort  lx-music 桥接健康端口

握手文件（Documents/noderuntime/）：
  .startup.ack     启动确认（Node 写完 → 客户端认为就绪）
  .relisten        iOS 挂起恢复请求
  .relisten.ack    恢复确认
  .lx.ack          lx 桥接就绪确认

目录结构：
  Documents/noderuntime/
    ├── main.js               主入口
    ├── node-intl-polyfill.js 国际化补丁
    ├── bundles/kstore_index.js  bundle（3.9MB 内置 / 6.4MB 远程）
    ├── plugins/lx/           lx 插件目录（daxe.js / nianxin.js）
    ├── db.json               配置
    └── wexfnwconfig.json     微信风控配置

崩溃恢复：
  - 周期 HTTP 心跳探测 healthPort
  - 连续失败 → 判定崩溃 → 自动重启
  - 内存告警 → 降级（卸载非必要 bundle）
  - bundle MD5 校验失败 → 回退 App Bundle 内置资源
```

**Flutter 侧对应设计：**
```dart
abstract class NodeRuntimeService {
  Future<void> start();
  Future<void> stop();
  Future<void> restart();
  bool get isReady;
  int get activePort;
  Stream<NodeRuntimeStatus> get statusStream;
  Stream<String> get crashStream;
  Future<void> installBundle(Uint8List data);  // MD5 校验
  Future<void> installLxPlugin(String name, Uint8List data);
}
```

### 4.3 Python 运行时现状（重大成本项）

**iOS 现状（不可直接移植）：**
- Python **3.14.7** 预编译为 `Python.framework`（arm64）
- `lxml` 5.4.0 + libxml2 2.13.5 + libxslt 1.1.42 **静态编译**（`build_lxml_ios.sh`，固定 iphoneos SDK）
- `scripts/Crypto/` 提供 AES/ARC4/RSA/PKCS1 兼容层
- `python-stdlib/base/spider.py` 为 Spider 基类

**Android 方案对比：**

| 方案 | 可行性 | 成本 | 风险 |
|------|--------|------|------|
| Chaquopy（嵌入式 CPython） | 高 | 低 | 商业授权（免费额度有限） |
| BeeWare / CPython 交叉编译 | 中 | 高 | NDK 工具链复杂，lxml 需重编译 |
| Kivy python-for-android | 中 | 中 | 体积大，与 Flutter 集成差 |
| Termux 派生物 | 低 | 中 | 无 Play 商店兼容 |
| **改用 JS 重写 Python 蜘蛛** | 中 | 中 | 需重写 ~100 脚本 |

**Windows 方案：**
- 直接嵌入 CPython 官方 Windows 发行版（最简单）
- lxml 使用官方 wheel（预编译，无需自编译）

**结论**：Python 运行时是三端最大不一致点。建议 **抽象 `ScriptRuntime` 接口 + 各平台独立实现**，并用**统一的 Spider ABI**（输入 JSON / 输出 JSON / 超时 / 取消 / 日志）屏蔽差异。

### 4.4 播放器层调整建议（重要）

初版建议「三端统一播放器插件」。**修正为分层策略：**

| 平台 | 主播放器 | 备选 | 理由 |
|------|---------|------|------|
| **Android** | Media3/ExoPlayer | libVLC Android | Media3 原生支持 HLS、软解回退 |
| **Windows** | libmpv (mpv.dll) | FFmpeg 直调 | libmpv 完整支持 MKV/HEVC/10bit/HDR |
| **macOS** | AVPlayer | libmpv | AVPlayer 够用，特殊格式回退 libmpv |
| **iOS** | **保持现状，不迁移** | — | 6 个后端 + Metal + VideoToolbox 深度耦合 |

**iOS 不迁移的理由（关键决策）：**
1. 6 个播放后端（AVPlayer/MPV/MDK/VLC/IJK/Ali）已稳定运行
2. Metal 渲染层 + VideoToolbox 硬解 + IOSurface 零拷贝，Flutter Texture 无法等价
3. 3 种 PiP 管理器（MPV/VT/MDK/ViewCapture）依赖平台 API
4. 流重封装（RemuxProxyServer + StreamRemuxer + Go 代理）是 iOS 特化实现
5. 迁移收益 < 迁移成本，且风险极高

**推荐架构（修正）：**
```
Android 新客户端 ──┐
Windows 新客户端 ──┼── 共享 Dart 业务层（models/spider协议/data/backup）
iOS 原客户端 ─────┘    （iOS 通过 FFI/Channel 复用同一份 Dart 逻辑）
```

即：**Flutter 只做 Android + Windows 两端的 UI，iOS 保留 SwiftUI，三端共享一份 Dart 领域逻辑（通过 `flutter_rust_bridge` 或独立 Dart VM 服务化）。**

若确认要全量 Flutter 三端，则 iOS 播放器必须保留原生插件，且接受**功能降级**（放弃部分 MPV 特性和自定义渲染）。

### 4.5 Spider 统一 ABI 设计（新增，关键）

初版只有接口签名，缺少**跨语言 ABI 契约**。补充：

```
┌─────────────────────────────────────────────────┐
│              Spider ABI (JSON over stdio/FFI)    │
├─────────────────────────────────────────────────┤
│ 输入（客户端 → 引擎）：                           │
│ {                                                │
│   "op": "home|search|category|detail|player",    │
│   "params": {...},                               │
│   "ctx": {                                       │
│     "baseUrl": "...",        // 相对 api 解析基准 │
│     "headers": {...},        // 默认请求头        │
│     "timeoutMs": 15000,                          │
│     "requestId": "uuid"                          │
│   }                                              │
│ }                                                │
│                                                  │
│ 输出（引擎 → 客户端）：                           │
│ {                                                │
│   "ok": true,                                    │
│   "data": {...},                                 │
│   "logs": [...],                                 │
│   "elapsedMs": 1234                              │
│ }                                                │
│ 或                                                │
│ { "ok": false, "error": {"code":"...","msg":"..."} }│
├─────────────────────────────────────────────────┤
│ HTTP 回调（引擎 → 宿主，用于 JS fetch 重定向）：   │
│ {"cb":"http","id":"...","method":"GET","url":"..."}│
│   → 宿主执行 → 回传 {"id":"...","status":200,...}  │
├─────────────────────────────────────────────────┤
│ 错误码：                                          │
│  E_SCRIPT_LOAD  脚本加载失败                      │
│  E_REGISTER     蜘蛛未注册（__JS_SPIDER__ 缺失）  │
│  E_TIMEOUT      超时                              │
│  E_CANCELLED    取消                              │
│  E_RUNTIME      运行时崩溃                        │
│  E_PROTOCOL     返回格式非法                      │
└─────────────────────────────────────────────────┘
```

**为什么必须统一 ABI**：
- 5 种引擎（JSC/QuickJS/Node/NodeLX/Python）行为差异大
- 初版风险表提到「行为不一致」，但没给解决方案
- ABI 是唯一能把差异收敛到适配层的手段

### 4.6 数据模型兼容性清单（新增，逐表核对）

| Swift 模型 | 表名 | 字段数 | Flutter 对应 | 兼容要求 |
|-----------|------|--------|-------------|----------|
| `ZhanyuanSite` | zhanyuan | 17 | `ZhanyuanSite` | 唯一键 (name, dyurl) |
| `ApiYuanSite` | apiyuan | 8 | `ApiYuanSite` | 唯一键 (name, dyurl) |
| `SubscriptionRecord` | subscription | 5 | `SubscriptionRecord` | dyurl 唯一 |
| `FavoriteRecord` | favorite | 9 | `FavoriteRecord` | 含 xianlu/jishu |
| `HistoryRecord` | history | 10 | `HistoryRecord` | 含 progress |
| `DownloadRecord` | download | 18 | `DownloadRecord` | v4 新增 4 个可空字段 |
| `JiexiSetting` | jiexisetting | 3 | `JiexiSetting` | bianma 主键 |
| settings | settings | 3 | 键值表 | key 主键 |
| search_history | search_history | 3 | 搜索历史 | — |

**关键约束：**
- `DownloadRecord` v4 字段（sourceType/engineKey/vodId/headers）**必须可空**
- 所有模型用 `decodeIfPresent` 语义（Dart: 可空字段 + 默认值）
- SQLite 迁移 v1→v4 逻辑需 1:1 复刻（含 `zhanyuan_v2`/`apiyuan_v2` 重建表）
- UserDefaults 键名映射表：
  ```
  subscribed_config_urls   → SharedPreferences（同键名）
  active_subscription_index→ SharedPreferences（同键名）
  cached_subscribe_config  → 建议不迁移（缓存）
  fallback_enabled         → SharedPreferences
  enable_dual_mode         → SharedPreferences
  remote_default_*         → SharedPreferences
  vbox_sqlite_migration_done → 迁移后置 true
  ```

### 4.7 备份格式兼容性（新增）

**备份文件结构（必须 1:1 兼容）：**
```json
{
  "schemaVersion": 1,
  "meta": { "appName", "appVersion", "createdAt", "account", "username", "device" },
  "encrypted": true,
  "cipher": "AES-GCM",
  "kdf": "PBKDF2",
  "salt": "...", "iv": "...", "authTag": "...",
  "payload": "base64..."
}
```

**9 个类目：**
```
watchHistory / favorites / downloads / subscriptions
siteConfigs / personalSettings / remoteSources
searchHistory / cloudCredentials（敏感，默认关闭）
```

**加密实现：** AES-GCM + PBKDF2（`CommonCrypto` + `CryptoKit`）
- Flutter 对应：`cryptography` 包的 `AesGcm` + `Pbkdf2`
- **必须验证跨平台加解密一致性**（salt/iv 长度、迭代次数、authTag 位置）

**RemoteSourcesSnapshot 特殊要求：**
- `lxPlugins` 字段必须可选（旧备份无此字段 → 空字典）
- 自定义 `init(from:)`/`encode(to:)` 需在 Dart 手写模型中按 `includeIfNull: false` 语义复刻（D23：不引入 freezed 代码生成）

### 4.8 安全配置迁移（新增）

**iOS 现状的 ATS 配置：**
```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsArbitraryLoads</key><true/>
  <key>NSAllowsLocalNetworking</key><true/>
</dict>
```

**三端对应：**
| 平台 | 配置 | 说明 |
|------|------|------|
| Android | `network_security_config.xml` + `usesCleartextTraffic` | 允许明文 HTTP（大量源站为 http） |
| Windows | 无系统限制 | 但需处理 TLS 证书校验 |
| macOS | 需关闭沙盒网络限制或申请 entitlement | 沙盒下 localhost 监听需 `com.apple.security.network.server` |

**本地代理端口安全（Go 代理）：**
- 仅绑定 `127.0.0.1`（已正确）
- 无鉴权 → 同机其他 App 可访问
- **建议**：增加随机端口 + 一次性 token 校验

### 4.9 包体积优化方案（新增）

**现状估算（iOS）：**
```
Swift 代码           ~8 MB
MPVKit + FFmpeg      ~60 MB
MobileVLCKit         ~45 MB
Python + lxml        ~35 MB
NodeMobile           ~25 MB
Node bundle (内置)    ~4 MB
QuickJS              ~2 MB
AliyunPlayer + IJK   ~30 MB
─────────────────────────────
总计                 ~200+ MB
```

**三端目标：**
| 平台 | 目标体积 | 策略 |
|------|---------|------|
| Android | < 100 MB | 按 ABI 拆分 APK；运行时按需下载 Node bundle |
| Windows | < 120 MB | 安装包内置 libmpv + FFmpeg |
| macOS | < 150 MB | 首次启动按需下载（可选） |

**按需下载清单：**
- Node bundle（6.4 MB）→ 首次启动下载
- Python stdlib（如采用）→ 首次使用 Spider 时下载
- 福利脚本（~2 MB）→ 进入福利专区时下载
- lx 插件（~44 KB）→ 启用音乐时下载

### 4.10 工期估算（已对齐 v4 AI 开发模型）

> ⚠️ 本节原为「人力开发」模型（Phase 1-5、20-28 周），已废弃。
> 当前有效模型见 **E.7 AI 开发阶段编排** 与 **3.5 工期最终结论**。

| 模型 | 工期 | 状态 |
|------|------|------|
| **AI 全量开发 + 人测（当前）** | **8-12 周（乐观）/ 11-16 周（保守）** | ✅ 有效 |
| 原 4 人人力协作 | 13-16 周 | ❌ 已废弃（D4 修订） |
| 原单人全职 | 20-28 周 | ❌ 已废弃 |
| 原 minSdk 21 方案 | 12-18 周 | ❌ 已废弃（D12 定 API 24，省 3 周） |

**当前模型的阶段划分**：见 E.7（第 0 阶段契约冻结 + 第 1-5 轮迭代）

**关键路径**：人测验证（非 AI 编码）

### 4.11 风险清单更新

| 风险 | 等级 | 初版 | 修订后 | 缓解 |
|------|------|------|--------|------|
| SpiderManager 单体过大 | **高** | 未识别 | 6075 行 / 311 KB 单文件 | 先做接口冻结 + 模块拆分 |
| Python 三端不一致 | **高** | 低估 | lxml 自编译不可复用 | 抽象 ScriptRuntime + 考虑 JS 重写 |
| Node bundle 6.4 MB | 中 | 未识别 | 打包体积 | 按需下载 + MD5 校验 |
| 福利模块 90 平台 | **高** | 未识别 | 单点最重模块 | 独立排期，最后迁移 |
| iOS 播放器 6 后端 | **高** | 低估 | Metal/VT 深度耦合 | **不迁移，保留原生** |
| ABI 不一致 | **高** | 提及未解决 | 5 引擎行为差异 | 统一 Spider ABI |
| 备份加密跨平台 | 中 | 未识别 | 必须字节级一致 | 交叉验证测试 |
| 明文 HTTP 政策 | 中 | 提及 | 各平台配置不同 | 平台配置文件 |
| 远程源代理降级 | 中 | 未识别 | GitHub 可达性 | 三级代理链复刻 |
| 工期低估 | **高** | 12-18 周 | 20-28 周 | 分阶段交付 |

### 4.12 迁移顺序（已对齐 v4 AI 迭代模型）

> ⚠️ 本节原为「人力分阶段交付」模型（Android MVP → Windows → 福利 → iOS），已废弃。
> 当前有效模型见 **E.7 AI 开发阶段编排**。

**当前模型（简版，详见 E.7）**：

```
第 0 阶段  契约冻结（AI 主导，1 周）+ 人工评审 1-2 天
   └─ 产出：Spider ABI / 备份规范 / JSON Schema / fixtures / Flutter 骨架
   └─ ⚠️ 结束后过 E.10b 遗漏检查

第 1 轮    核心骨架（AI 2 周 + 人测 1 周）
   └─ Dart 领域层 + 三端插件层 + 手机/桌面/TV UI + 单测
   └─ ⚠️ 结束后过 E.10b

第 2 轮    功能补全（AI 1-2 周 + 人测 1-2 周）
   └─ 修 Bug + 补功能 + TV 遥控 + API 24 下限设备
   └─ ⚠️ 结束后过 E.10b

第 3 轮    兼容性与稳定性（AI 1 周 + 人测 1-2 周）
   └─ 真机问题修复 + 老设备性能 + TV 矩阵
   └─ ⚠️ 结束后过 E.10b

第 4 轮    数据互通与边界（AI 1 周 + 人测 1 周）
   └─ iOS ↔ Flutter 双向数据验证
   └─ ⚠️ 结束后过 E.10b

第 5 轮    发布准备（AI 3-5 天 + 人测 3-5 天）
   └─ 签名 / 构建脚本 / 自更新器 / 侧载链路验证
   └─ ⚠️ 结束后过 E.10b

总计：8-12 周（乐观）/ 11-16 周（保守）
```

**核心差异（对比旧模型）**：三端并行推进（非串行），AI 主导编码，人测作为阶段门禁。

---

---

## 五、附录：远程源字段完整映射表

### 5.1 SiteConfig 字段映射（客户端 ↔ 远程源）

| 字段 | 类型 | 远程源示例 | Dart 类型 | 必填 |
|------|------|-----------|----------|------|
| key | String | `"js_剧迷"` | `String` | ✅ |
| name | String | `"剧迷[js]"` | `String` | ✅ |
| type | Int | `3` | `int` | ✅ |
| api | String? | `"./js/jumi.js"` | `String?` | ✅ |
| searchable | Int? | `1` | `int?` | — |
| quickSearch | Int? | `0` | `int?` | — |
| filterable | Int? | `0` | `int?` | — |
| ext | String? | — | `String?` | — |
| playerType | Int? | — | `int?` | — |
| jar | String? | — | `String?` | — |
| changeable | Int? | — | `int?` | — |
| playStrategy | String? | — | `String?` | — |
| playMode | String? | `"pan"` | `String?` | — |
| panHosts | [String]? | `["quark","ali"]` | `List<String>?` | — |
| group | String? | `"video"` | `String?` | — |
| engineType | String? | `"lxMusic"` | `String?` | — |
| pluginPath | String? | `"sources/lx/daxe.js"` | `String?` | — |
| version | String? | — | `String?` | — |
| md5 | String? | — | `String?` | — |
| enabled | bool? | `true` | `bool?` | — |
| priority | int? | `1001` | `int?` | — |

### 5.2 福利平台字段映射

| 字段 | 类型 | 说明 | Dart |
|------|------|------|------|
| platformKey | String | 平台唯一键 | `String` |
| name | String | 平台名 | `String` |
| category | String | video/live/comic | `String` |
| icon | String | SF Symbol 名 | `String` |
| desc | String | 描述 | `String` |
| serviceType | String | `"welfare_spider"` | `String` |
| defaultHosts | [String] | 默认域名列表 | `List<String>` |
| sortOrder | Int | 排序 | `int` |
| defaultProxy | bool | 是否默认走代理 | `bool` |
| notes | String | 备注 | `String` |
| api | String | 脚本路径 | `String` |
| scriptType | String | `"python"`/`"javascript"` | `String` |
| engine | String | `"python"`/`"spider"` | `String` |
| visibleInNormalSpider | bool | **必须 false** | `bool` |
| visibleInGlobalSearch | bool | **必须 false** | `bool` |
| visibleInHome | bool | **必须 false** | `bool` |

### 5.3 远程源文件与客户端组件依赖矩阵

| 文件 | RemoteSourceConfigManager | SpiderManager | NodeRuntimeManager | BackupManager |
|------|:------------------------:|:-------------:|:------------------:|:-------------:|
| manifest.json | ✅ 主入口 | — | ✅ bundle 地址 | ✅ 快照 |
| all_sources.json | ✅ 聚合加载 | ✅ 站点来源 | — | ✅ 快照 |
| api_sources.json | ✅ | ✅ type 0/1 | — | ✅ |
| cloud_sources.json | ✅ | ✅ 网盘 | — | ✅ |
| spider_sources.json | ✅ | ✅ type 3 | — | ✅ |
| domain_overrides.json | ✅ | ✅ 域名替换 | — | ✅ |
| parsers.json | ✅ | ✅ 解析器 | — | — |
| disabled_sources.json | ✅ | ✅ 过滤 | — | — |
| welfare_platforms.json | ✅ | — | — | — |
| kstore_index.js | ✅ | — | ✅ 主 bundle | — |
| kstore.version | ✅ | — | ✅ 版本比对 | — |
| lx/*.js | ✅ 下载 | ✅ LXBridge | ✅ 插件目录 | ✅ 备份 |

---

**文档版本**：v4（定稿版 · AI 全量开发）
**最后更新**：基于 commit `1f95d10`（客户端）+ `vbox-Ai/api@main`（远程源）
**决策记录**：见第〇章 Decision Log（D1-D10 全部确认）

### v4 相对 v3 的变更

| 项 | v3 | v4 |
|----|----|----|
| 开发模式 | 4 人人力协作 | **AI 全量编码，人力只做测试** |
| 关键路径 | 插件层编码（12 周） | **人测验证（迭代驱动）** |
| 工期 | 13-16 周 | **8-12 周（乐观）/ 11-16 周（保守）** |
| 验收方式 | 人力评审 | **自动化测试 + conformance 自证** |
| 新增章节 | — | 第 E 章「AI 全量开发执行计划」 |
| 新增风险 | — | AI 幻觉、契约漂移、人测瓶颈 |
| 新增要求 | — | 单测覆盖率 ≥70%、结构化 Bug 报告、AI 自证 |
| 分发方式 | 未明确 | **全部侧载，不提交商店**（D11） |
| TV minSdk | Android 5.0 (API 21) | **Android 7.0 (API 24)**（D12，经 Flutter 官方查证） |
| 新增章节 | — | 第 V 章 TV 版本调研（已定稿）、第 S 章 侧载分发方案 |
| 质量门禁 | 模块级（E.10） | **新增阶段级（E.10b，D13）** |
| 开发仓库 | `q2787244398/app` | **`q2787244398/vboxapp` 唯一开发仓库**（D14） |
| 推送节奏 | 未明确 | **每阶段推送一次**（D15） |
| 源仓库 | 未明确 | **冻结归档，改动不回流**（D16 修订） |
| 新增章节 | — | 第 R 章 仓库布局与推送流程 |
| 工期 | 12-18 周（保守） | **11-16 周**（保守，minSdk 24 省 3 周） |

---

## 六、变更记录（v3 → v4）

### 6.1 相对 v2 的新增章节

| 章节 | 内容 |
|------|------|
| 〇 决策记录 | D1-D7 七项决策固化 |
| 二之补 | Android TV 双形态技术方案（T.1-T.10） |
| 二之补二 | Android 5.0 (API 21) 兼容专章（A21.1-A21.8）⚠️ 已废弃，保留作降级参考 |
| 二之补五 | Android TV 版本分布与 minSdk 定稿（V.1-V.10） |
| 二之补六 | 侧载分发方案（S.1-S.10） |
| 二之补三 | 第 0 阶段契约层产物（C.1-C.4） |
| 二之补四 | 多人协作执行计划（E.1-E.5） |
| 3.3 | 决策落实清单 |
| 3.7 | 下一步行动（W1-W2 可立即执行） |
| 3.8 | 需要持续关注的不确定性 |

### 6.2 相对 v2 的修订章节

| 章节 | 修订内容 |
|------|---------|
| 2.1 总体架构 | 改为「契约层 + 双客户端」结构 |
| 2.3 技术选型 | 更新为 minSdk 24（解除依赖锁定） |
| 2.4 目录结构 | 增加 contract/、ui_mode/、tv/、conformance/ |
| 2.5 能力矩阵 | 增加 Android TV 列 |
| 3.2 最终架构 | 明确方案 A4，列出已否决的 A1/A2/A3/B |
| 3.5 工期 | 单人 20-28 周 → 多人 13-16 周 → **AI 开发 8-12 / 11-16 周** |

### 6.3 已生成的契约产物

| 文件 | 大小 | 状态 |
|------|------|------|
| `contract/schema/schema_v1.sql` | 5.9 KB | ✅ |
| `contract/schema/prefs_keys_v1.json` | v1.2，**98 键 / 21 组** | ✅ |
| `contract/docs/abi_v1.md` | 14.7 KB | ✅ |
| `contract/docs/backup_v1.md` | 13.1 KB | ✅ |
| `contract/schema/site_v1.json` | — | ✅ |
| `contract/schema/welfare_v1.json` | — | ✅ |
| `contract/schema/manifest_v1.json` | — | ✅ |
| `contract/conformance/fixtures/*` | 3 类样本 | ✅ |
| `contract/docs/android-compat.md` | 7.4 KB | ✅（命名与 C.4 计划不符） |
| `contract/docs/prefs_keys_revision_v1.1.md` | 4.4 KB | ✅（契约修订留档） |

### 6.4 待生成的契约产物

| 文件 | 优先级 | 状态 |
|------|--------|------|
| ~~`contract/docs/abi_v1.md`（Spider ABI）~~ | P0 | ✅ 已生成 |
| ~~`contract/docs/backup_v1.md`（备份格式）~~ | P0 | ✅ 已生成 |
| ~~`contract/schema/site_v1.json`~~ | P1 | ✅ 已生成 |
| ~~`contract/schema/welfare_v1.json`~~ | P1 | ✅ 已生成 |
| ~~`contract/schema/manifest_v1.json`~~ | P1 | ✅ 已生成 |
| ~~`contract/conformance/fixtures/*`~~ | P1 | ✅ 已生成 |
| ~~`docs/android-min-sdk21-compat.md`~~ | P0 | ✅ 已生成（`contract/docs/android-compat.md`） |

## 6.5 v4 → v5 变更（本版）

| 项 | 内容 |
|----|------|
| **文档合并** | 原 `PROGRESS.md`/`PROJECT_LAYOUT.md`/`KNOWN_GAPS.md` **全部并入本方案**（附录 A / B / C）——全项目**仅此一份文档** |
| **进度追踪** | 新增 **P.1–P.11** 实际开发进度、缺口清单、E.10b 门禁核查与文档一致性核查 |
| **契约修订** | `prefs_keys_v1.json` 由 53 键 → **98 键 / 21 组（v1.2）**；新增双向完整性校验（见 P.5 问题 1） |
| **新增交付** | `conformance/runner/run_conformance.py`（**45/45**，含否定测试）· `scripts/check_docs_consistency.py`（文档漂移守护） |
| **门禁** | E.10b 不达标项 **12 → 9**；第 1 轮仍**不可**标记完成（D20） |
| **环境** | Flutter SDK 在 aarch64 无法运行（官方 Linux 包仅 x86-64）→ 所有 Dart 代码**未经编译验证**（见 P.7） |

> **待办（已闭环）**：~~`contract/schema/prefs_keys_v1.json` 需补齐 44 个遗漏键~~ ✅ 已补齐至 98 键（v1.2，见 P.5 问题 1）

---

## 6.6 v5 → v6 变更（本版）

| # | 变更 | 说明 |
|---|------|------|
| 1 | **新增 P.13 全量体检与问题清单** | 21 项（6 已修 / 15 待处理）+ 6 项待办 + 门禁复核视角 |
| 2 | **交付核心层** | `lib/core/` 5 模块 21 文件（常量 / 错误 / 网络 / 存储 / 工具），零插件依赖 |
| 3 | **交付用例层与远程数据源** | `domain/entities/library` 3 实体 + 4 仓储契约 + 4 用例组；`data/datasources/remote`（CMS V10 + 清单） |
| 4 | **单测体系** | 12 文件 / **143 用例**（core + 用例层 + 数据源），CI 由空跑转为真实执行 |
| 5 | **新增校验脚本**（v6 第 10 个） | `check_dart_imports.py`（相对路径断链秒级检测，开发中即捕获 22 处）；v6.6 再加第 11 个 `check_coverage.py`（覆盖率门槛） |
| 6 | **高危缺陷修复** | `.version` 纳入 `CI_MANAGED`，杜绝 CI 版本号被本地旧值回推 |
| 7 | **数字口径全面刷新** | 用例数 78 → 143 · 脚本 9 → 10 · 错误码 11 → 14 · lib 文件 51 → 69 · 进度 65% → 70% |
| 8 | **文档更名** | `docs/VBOX_PLAN_v5.md` → **`docs/VBOX_PLAN_v6.md`**（脚本与代码注释同步更新）；v6.9 起再随修订版本更名为 **`docs/VBOX_PLAN_v6.9.md`**（D25） |

> **注意**：本文件为**唯一现行文档**（**v5 文档合并结论**：附录 A/B/C 已全部并入；开发仓库唯一性另见 D14）。历史版本 v5 不再保留副本，
> 变更内容全部体现在本文件的 §6.6 与 P.13。

---

## 二之补八：实际开发进度追踪（2026-09-29 更新）

> **本章由开发过程实时核验生成。**
> 仓库：https://github.com/q2787244398/vboxapp · **623 文件**（v6.13 复核计数，`git ls-files --cached --others --exclude-standard`）
> **⚠️ 本机（aarch64）无 Flutter SDK**（见 P.7）；Dart 代码的编译 / 静态 / 单测验证
> 已由 GitHub Actions `flutter-check.yml` 承接（`analyze` 0 issues · 371 用例 + 覆盖率门槛，v6.13）。

### P.1 总体进度

| 阶段 | 目标 | 进度 | 状态 |
|------|------|------|------|
| 第 0 阶段 | 契约冻结 | 100% | ✅ 已过 D13 门禁 |
| 第 1 轮 | 核心骨架 | **约 56%** | 🔄 进行中 |
| 第 2 轮 | 功能补全 | 0% | ⬜ |
| 第 3 轮 | 兼容性与稳定性 | 0% | ⬜ |
| 第 4 轮 | 数据互通与边界 | 0% | ⬜ |
| 第 5 轮 | 发布准备 | 0% | ⬜ |

### P.2 第 0 阶段交付核验（承诺 7 项）

| # | 承诺产物 | 实际 | 状态 |
|---|---------|------|------|
| 1 | `contract/docs/abi_v1.md` | ✅ 14.7 KB | 完备 |
| 2 | `contract/docs/backup_v1.md` | ✅ 13.1 KB | 完备 |
| 3 | `contract/schema/site_v1.json` | ✅ | 19 字段与 iOS 源码完全一致 |
| 4 | `contract/schema/welfare_v1.json` | ✅ | 结构 = API 实际一致 |
| 5 | `contract/schema/manifest_v1.json` | ✅ | 已交付 |
| 6 | `conformance/fixtures/*` | ✅ | 3 类样本 |
| 7 | `docs/android-min-sdk21-compat.md` | ⚠️ | 实际为 `contract/docs/android-compat.md`（命名差异） |

### P.3 第 1 轮交付核验

**✅ 已完成（75 个 Dart 文件 + 29 个测试文件 / 371 用例，v6.13）**

| 模块 | 产物 |
|------|------|
| 契约层 | `contract/prefs_keys.dart`（**98 键/21 组**）· `contract/schema/schema.dart`（9 表+迁移链） |
| 数据层 | `data/models/`（9 模型）· `data/datasources/local/`（database/prefs/backup manager） |
| 领域层 | `domain/entities/spider/`（6 文件）· `remote_source/`（3）· `player/`（1） |
| 表现层 | `presentation/ui_mode/ui_mode_resolver.dart`（⭐ 三重判定） |
| 入口 | `main.dart` · `app.dart` |
| **核心层**（P.12） | `core/{constants,errors,network,storage,utils}`（21 文件） |
| **用例层与远程数据源**（P.13） | `domain/entities/library` + `domain/{repositories,usecases}` · `data/datasources/remote`（CMS V10 + 清单） |
| **数据层仓储实现**（v6.7） | `data/repositories/`——`favorite` / `history` / `subscription` / `remote_source` **四个实现 + barrel**，经 `app.dart` 组装并注入用例层（P.19） |

**❌ 未完成**

| 方案要求 | 状态 |
|---------|------|
| `presentation/{phone,tv,desktop,shared,theme}` 布局 | ⬜ 未创建（仅 `ui_mode/` 已交付） |
| `platform/{player,spider,runtime,system}` 插件层 | ⬜ 未创建 |
| 平台壳 | ✅ **v6.11 已交付**：`android/` / `macos/` / `windows/`（`flutter create` 官方模板，66 文件，包名 `com.vbox.player`）；CI 三端 build job **v6.12 首跑全绿**（Flutter Check `f59d04e`，见 P.22） |
| **单元测试**（目标 >70%） | ✅ **29 文件 / 371 用例通过**（本机 + CI 双复现）；覆盖率**已测量**：触达口径 **86.5%**，全 lib 整体口径 **71.1%**（保守下界，**达标**），零触达文件 **24/75**（见 P.18 / P.19 / P.23） |
| conformance runner | ✅ 已交付（45/45，见 P.8b） |
| `lib/domain/{repositories,usecases}` · `lib/data/{datasources/remote,repositories}` | ✅ 已交付（接口 + **四个仓储实现**，v6.7） |

### P.4 自动化校验体系（**15 脚本 + 1 runner，全部通过**）

| 脚本 | 验证内容 | 结果 |
|------|---------|------|
| `check_contract_sync.py` | 键名98/敏感键5/分组21/类型98/防回归/表9/fixture | ✅ |
| `check_contract_completeness.py` | **双向：契约↔iOS 源码完整性** | ✅ |
| `check_migration_chain.py` | onCreate↔onUpgrade/契约/v4可空列/UNIQUE/数据保留 | ✅ |
| `check_models_roundtrip.py` | 建库+往返+UNIQUE+NULL容忍 | ✅ |
| `check_prefs_manager.py` | 键名在契约内/jsonListKeys/敏感键分派 | ✅ |
| `check_backup_contract.py` | PBKDF2实测/AES-GCM往返/错口令/静态检查 | ✅ |
| `check_spider_domain.py` | 引擎rawValue/15模式用例/容错解码/回填/错误检测 | ✅ |
| `check_domain_remote_player.py` | 代理链/同步判定/后端降级链/封装回退 | ✅ |
| `check_docs_consistency.py` | **文档漂移检测**：陈旧键数/组数、失效路径（P.11 新增）、源码注释失效引用（v6.2）、**文件名/版本三处一致 + D 编号唯一性与引用无悬空**（v6.9） | ✅ |
| `check_dart_imports.py` | **Dart 导入路径可达性**（v6 新增）：相对路径/`package:vbox` 断链；本地秒级兜住「相对路径写错一次连带 20+ analyze 报错」 | ✅ |
| `check_coverage.py` | **单测覆盖率门槛**（v6.6 新增）：按**全 lib 行数口径**重算（零触达文件按非空非注释行估行 → 保守下界），硬门槛 70%，堵住「lcov 只算触达文件」的口径陷阱 | ✅ |
| `check_ui_tokens.py` | **UI 令牌守卫**（v6.33 新增）：**R-2** 圆角必须取档位 `{4,6,8,10,12,14,16,20}` · **R-3** 字号必须取档位 `{10,11,12,13,14,15,16,18,24,28}` · **R-4** 十六进制主色仅限令牌文件 | ✅ |
| `check_engine_bundle.py` | **双引擎体积/许可核销**（Q-06 新增）：QuickJS MIT 许可 · JSC BSD-2 声明 · 产物体积区间登记 | ✅ |
| `check_welfare_isolation.py` | **福利三重隔离守卫**（H-04 新增）：契约 allOf 约束 / 领域层实现一致性 / 模型三字段解析 / 路由接入 / sources 越界扫描 / 普通 Spider 链路引用（`--selftest` 负向自测） | ✅ |
| `check_platform_wiring.py` | **平台层组件接线守卫**（S-07-a 新增）：登记 9 项平台能力（网盘编排/字幕解析/长按倍速/自动连播/转封装/Go 代理/直链校验/后台播放/画中画），逐项核对「类存在 + 消费域非零引用」；计数前剥离注释与字符串，防「注释提一句」误判为接线。存量未接线项走 `EXEMPT` 登记（点名不失败），拦截**新增**「组件建完零接线」回归 | ✅ |
| **`conformance/runner/run_conformance.py`** | **fixture 消费：Spider ABI 20 + SQLite 6 + 备份 19 = 45 项** | ✅ **45/45** |

> 另有 `check_mpv_installed_dependencies.py`（iOS CI 依赖检查，不属契约校验套件）。

### P.5 核查发现的问题与修复状态

#### ✅ 问题 1（v6.1 已修复）：Prefs 契约曾遗漏 44 个真实键

<!-- docs-guard:history -->

| 项 | 修复前 | 修复后 |
|----|--------|--------|
| 契约键数 | 53 | **98** |
| 分组数 | 12 | **21** |
| 契约遗漏 | **44 键** | **0** |
| 契约冗余 | 0 | 0 |

**修复方式**：
1. `scripts/extract_all_keys.py`（3 种写法穷举 + 变量追踪 + `Self.` 前缀）
2. 新增**区分 3 种存储方式**：`userDefaults`(94) / `keychain`(2) / `credentialExtra`(2)
3. 新增 `scripts/check_contract_completeness.py` **双向校验**（防再漏根因）
   - 上线即抓出 2 个漏网键（`saved_drive_tokens` 等），证明其有效

**根因**：原提取脚本只匹配 `forKey:"k"` 一种写法，漏掉 `let xKey="k"` 与 `enum XXXKeys` 两种；
且原校验只验「实现↔契约」，不验「契约↔源码」，导致漏 44 键仍全绿。

<!-- /docs-guard:history -->

#### ✅ 问题 2（已修复）：目录结构对齐方案 §2.4

已重构为五层架构：
```
lib/
├── main.dart, app.dart
├── contract/{prefs_keys.dart, schema/, abi/}
├── core/{constants,errors,network,storage,utils}
├── data/{datasources/{local,remote}, models/, repositories/}
├── domain/{entities/{spider,remote_source,player}, repositories/, usecases/}
├── presentation/{providers,ui_mode,phone,tv,desktop,shared,theme}
└── platform/{player,spider,runtime,system}
```
（`presentation/` 仅 `ui_mode/` 已交付、`platform/` 尚未创建；`core/` 已交付 21 文件）

#### ✅ 问题 3（已修复）：新增双向完整性校验

见 P.4 `check_contract_completeness.py`。

#### ✅ 问题 4（部分修复）：缺失入口文件

| 文件 | 状态 |
|------|------|
| `lib/main.dart` | ✅ 已补 |
| `lib/app.dart` | ✅ 已补 |
| `lib/presentation/ui_mode/ui_mode_resolver.dart` | ✅ 已补 |
| 单元测试 | ❌ **仍为 0**（需 Flutter SDK 的 `flutter test`） |
| conformance runner | ❌ 未实现 |
| 平台插件层 / UI 三形态 | ❌ 未实现 |

### P.6 键数口径澄清（原 4 处矛盾）

<!-- docs-guard:history -->
| 出处 | 键数 | 说明 |
|------|------|------|
| 方案文档 | 57 | ❌ 初版估计值 |
| 阶段 0 报告 | 63 | ❌ 含 10 个误抓键 |
| 契约 v1.1 | 53 | ❌ 移除误抓键后，但漏 45 个 |
| **契约 v1.2（现行）** | **98** | ✅ 经双向校验，与 iOS 源码一致 |
| iOS 源码实测 | 98 | ✅ 权威基准 |
<!-- /docs-guard:history -->

> **结论**：以 **iOS 源码实测 98 键** 为唯一基准（第 2 轮 A-06 在此基础上扩 1 键 → 现行契约 **99 键**）。

### P.7 ⚠️ 环境约束：Flutter SDK 无法运行

| 项 | 结果 |
|----|------|
| Flutter Linux 发行版 | **仅提供 x86-64**（`dart_sdk_arch: x64`） |
| 本机架构 | **aarch64**（iSH / Alpine） |
| 实测结果 | `Exec format error` —— **无法运行** |
| 官方 arm64 Linux 包 | **不存在**（404 验证） |

**影响**：
- 所有 Flutter/Dart 代码**仅通过静态检查**，**未经编译验证**
- 单测（`flutter test`）、`flutter analyze`、`flutter build` **均无法执行**
- 第 1 轮剩余部分（UI/插件/单测）**无法在此环境验证**

**可选出路**：
1. 在有 x86-64 Linux / macOS 的机器上跑（推荐）
2. 用 GitHub Actions（已有 macos-15-arm64 runner）跑 Dart 构建与测试
3. 购买/挂载 arm64 Linux 环境

> **⚠️ 现行口径（v6.51 起，强制）**：本机**不安装** Flutter SDK。
> Trae 沙箱为**按会话创建**的 Kata 微虚拟机，工作区**不跨会话保留** —— 本地安装的
> Flutter SDK **无法留存到下一个会话**，且会在每个新会话诱导**重复下载安装数 GB**。
> Dart 侧的**编译 / 静态分析 / 单测 / 构建一律由 CI**（`flutter-check.yml`，Flutter **3.47.5**）承担；
> 本机**仅跑纯 Python 守卫（`scripts/check_*.py`）与 conformance runner**，不执行任何 `flutter` 命令。
> 历史正文中「本沙箱已安装 Flutter 3.47.5」「SDK 位于 `/workspace/.flutter-sdk/flutter`（持久目录）」
> 等表述**均已作废**，仅供历史追溯，不得据此在本地重装 SDK。

### P.8 E.10b 六类扫描门禁核查结果（**未通过：9 项不达标**）

> 按 D13 强制门禁，逐项执行六类扫描。以下为**实测结果**。

#### ① 契约一致性（**4/4 通过** ✅ 本轮补强）

| 检查项 | 结果 |
|--------|------|
| 契约同步校验 | ✅ |
| 契约完整性（双向） | ✅ |
| Dart 无契约外键 | ✅ 98 键全部在契约内 |
| conformance 100% 通过 | ✅ **runner 已交付，45/45 通过**（原 ❌ → 见 P.8b） |

#### ② 数据与状态（5/5 通过）

| 检查项 | 结果 |
|--------|------|
| SQLite 迁移链 v1→v4 | ✅ |
| 旧数据可读写（fixtures） | ✅ |
| 备份格式契约对齐 | ✅ |
| Prefs 键全覆盖 | ✅ **98 键** |
| 敏感键按约定处理 | ✅ 5 个 |

#### ③ 平台差异（2/5 通过）

| 检查项 | 结果 |
|--------|------|
| 三端功能对齐 | ❌ UI/插件层未实现 |
| TV 焦点全程可见 | ❌ TV UI 未实现 |
| iOS 参照未被破坏 | ✅ `vbox/` 目录完好 |
| minSdk 24 依赖可用 | ✅ 已查证 |
| 侧载链路验证 | ❌ 需真机验证 |

#### ④ 功能完整性（**3/5 通过**）

| 检查项 | 结果 |
|--------|------|
| 本阶段承诺功能交付 | ❌ UI/插件/单测未交付 |
| 无 TODO 遗留 | ✅ **已登记至 `附录 C`**（G-01，原 ❌ → 见 P.8b） |
| 5 个 Spider 引擎跑通 | ❌ 仅抽象层，引擎实现未开始 |
| 播放器后端均有回退 | ✅ 降级链已定义 |
| 福利/音乐隔离生效 | ✅ 契约含隔离约束 |

#### ⑤ 质量基线（2/5 通过）

| 检查项 | 结果 |
|--------|------|
| 单测覆盖率 ≥ 70% | ❌ **0 个测试文件** |
| 静态分析无 error | ❌ `flutter analyze` 无法运行（环境，见 P.7） |
| 无 blocker Bug | ✅ |
| 三端编译通过 | ❌ Flutter SDK 无法运行 |
| Bug 已闭环 | ✅ |

#### ⑥ 交付物与文档（**4/5 通过**）

| 检查项 | 结果 |
|--------|------|
| 应产出文件齐全 | ✅ 6 项（main/app/ui_mode/PROGRESS/LAYOUT/KNOWN_GAPS） |
| 决策记录需追加 | ✅ **已追加 D17–D20**（原 ❌ → 见 P.8b） |
| 风险清单更新 | ✅ v1.1 修订留档 |
| 已知限制已记录 | ✅ P.7 记录环境限制 |
| 下阶段输入就绪 | ❌ UI/插件未实现 |

#### 门禁结论

```
E.10b 结果：❌ 未通过（12 → 9 项不达标）
阻断：第 1 轮迭代不得标记完成，不得进入第 2 轮
```

> **v6 更新**：⑤「静态分析无 error」已随 CI 通道解除（`flutter analyze` 0 issues，每次推送执行）。
> **后续闭环**（见 P.13 §6 / P.22）：⑤「单测覆盖率 ≥70%」✅ **v6.6 达标**；③/⑤「三端编译」✅ **v6.11 交付平台壳 + CI build job，v6.12 首跑全绿（已通过）**。
> 当前口径：**9 项 → 6 项**（余：UI 三形态 / 插件层 / 5 引擎 / 4 播放器 / 三端功能对齐 / 侧载链路），需重跑门禁正式确认。

**不达标项归类（12 → 9 → 6）**：

| 类型 | 数量 | 说明 |
|------|------|------|
| ~~**环境阻塞**~~ | ~~3~~ | ✅ **全部解除**：单测覆盖率（v6.6）/ 静态分析（v6）/ 三端编译通道（v6.11，见 P.22） |
| **功能未实现** | 5 | UI 三形态、插件层、引擎实现、三端功能对齐、侧载链路 |
| **需真机** | 1 | TV 焦点与遥控（与「侧载链路」重叠计入功能类） |
| ~~流程缺失~~ | ~~2~~ | ✅ **已消除**（TODO 登记 + 决策记录，见 P.8b） |

### P.8b 本轮补强记录（2026-09-29）

#### ① conformance runner 交付 ✅

| 项 | 内容 |
|----|------|
| 交付物 | `conformance/runner/run_conformance.py` |
| 覆盖 | **45 项检查** — Spider ABI 20 · SQLite v4 6 · 备份格式 19 |
| 结果 | **45/45 通过**，退出码 0；落盘 `conformance/runner/results.json` |
| 参考实现 | Python 镜像 Dart 侧容错规则（`spider_models.dart`）；三端须产出同构输出 |

**有效性验证（否定测试）**：为避免 runner 沦为「必然通过」的空壳，向临时副本注入 3 处故障：

| 注入故障 | runner 反应 |
|---------|------------|
| 篡改容错期望值 `urls: ["WRONG"]` | ✅ 捕获（期望 'WRONG' 实为 'https://x.com/a.m3u8'） |
| 删除 `download.headers` 列 | ✅ 捕获（3 项检查同时失败） |
| 重建表丢失约束 | ✅ 捕获 |

> 首次否定测试**本身无效**：误在仓库路径运行 runner（`ROOT` 由 `__file__` 推导，
> 读到的是原始 fixture）。已重做，确认 runner 有效。

#### ② runner 自身 3 处缺陷修复（记录存档）

首次运行报 3 项失败，经查**全部为 runner bug，fixture 与契约均正确**：

| # | 误报 | 真实原因 | 修复 |
|---|------|---------|------|
| 1 | `download` 字段不一致 | 契约用 `ALTER TABLE ADD COLUMN` 加 v4 列，解析器只读 `CREATE TABLE` | 补 ALTER 解析 |
| 2 | 「NOT NULL 计数为 0」失败 | 断言写反（变量名 `nullable` 却在收集可空列） | 改为「4 列须存在且可空 + 基线列仍 NOT NULL」 |
| 3 | `UNIQUE(name,dyurl)` 未找到 | 内联 UNIQUE 生成**隐式索引**（`sqlite_master.sql` 为 NULL） | 改用 `PRAGMA index_list` + `index_info` |

> **教训**：① 查索引结构不能依赖 `sqlite_master.sql`；
> ② 契约 DDL 分散在 `CREATE TABLE` 与 `ALTER TABLE` 两处，须合并解析。

#### ③ TODO 登记 ✅

`lib/app.dart` 的 TODO 改为可追踪格式 `TODO(G-01/stage-1)`，并在 `附录 C`
登记为 **G-01**（含影响、阻塞原因、解除条件）。

#### ④ 决策记录追加 ✅

| 编号 | 决策 |
|------|------|
| D17 | 契约键范围 = 全模块（98 键，v1.5），以 iOS 源码实测为唯一基准 |
| D18 | 目录结构基准 = 方案 §2.4 五层架构 |
| D19 | 契约键须标注 `storage`（userDefaults/keychain/credentialExtra） |
| D20 | 第 1 轮完成判定 = **代码侧交付 + 自动化门禁（E.10b 六类扫描）通过**（**已修订**，见 D30：G-09 / G-10 真机项整体后移至第 2 轮末） |

#### ⑤ 文档自查发现并更正的错误

| # | 错误 | 更正 |
|---|------|------|
| 1 | P.8 ① 标注「2/4 通过」，实际 3 项 ✅ | 已更正为 3/4 →（本轮）4/4 |
| 2 | 附录 C 汇总表 G-09 重复计入两类且未说明 | 已加重叠说明 |

### P.9 该补但未补的项（诚实清单）

**✅ 本轮已补齐（原清单 1–3 项）**

| # | 原缺失项 | 交付 |
|---|---------|------|
| 1 | conformance runner | ✅ `conformance/runner/run_conformance.py`（45/45） |
| 2 | TODO 登记 | ✅ `附录 C` G-01 |
| 3 | 决策记录 D17+ | ✅ D17–D20 |

**⏳ 仍未补齐（7 项；其中第 4–6 项已于 2026-09-29 补齐，见 P.12/P.13）**

| # | 缺失项 | 严重度 | 可否在当前环境完成 |
|---|--------|--------|------------------|
| 4 | ~~`lib/core/*` 实现~~ | 中 | ✅ **已补齐**（5 模块 20 文件，见 P.12） |
| 5 | ~~`lib/data/datasources/remote` HTTP 数据源~~ | 中 | ✅ **已补齐**（CMS V10 + 清单，见 P.13） |
| 6 | ~~`lib/domain/usecases` 用例层~~ | 中 | ✅ **已补齐**（4 契约 + 4 用例组，见 P.13） |
| 7 | UI 三形态（phone/tv/desktop） | 高 | ⚠️ 未开始；**现已可编译验证**（CI 通道已通，不再是阻碍） |
| 8 | 平台插件层（Android/桌面） | 高 | ⚠️ **G-02-A 部分交付**（Dart 控制层 + Android Media3 接线，v6.22，见 P.32）；G-02-B/C 余项仍需原生工具链 / libmpv 分发决策 |
| 9 | 单元测试 | 高 | ✅ **39 文件 / 436 用例（静态声明，v6.22）**；覆盖率口径与 CI 复核见 P.32（v6.21 实测触达 86.9%、全 lib 整体 74.0% 达标、零触达 25/86） |
| 10 | 5 个 Spider 引擎实现 | 高 | ⚠️ **G-03-A 桥接协议层已交付**（Node/NodeLX/Python 纯 Dart 桥，v6.21，见 P.31）；QuickJS FFI / 运行时分发（G-03-B）待决策 |

> **风险提示（v6 更新）**：编译验证通道已通（`flutter-check.yml`），
> 第 7 项不再有「不可编译验证」的阻碍；但 **UI 三形态 / 平台插件层 / Spider 引擎**仍是
> 体量与风险最大的三项，且 E.10b 门禁未通过，**第 1 轮不得结项**。
> 建议优先解决 P.7 的编译环境问题（GitHub Actions macOS runner）。

### P.10 未决事项

| # | 事项 | 状态 |
|---|------|------|
| 1 | ~~契约键范围~~ | ✅ 已定：全模块（98 键，v1.5） |
| 2 | ~~目录结构~~ | ✅ 已定：方案 §2.4 五层 |
| 3 | ~~键数口径~~ | ✅ 已定：以 iOS 源码 98 键为基准（第 2 轮 A-06 扩 1 键 → 99 键） |
| 4 | ~~conformance runner~~ | ✅ **已交付**（45/45 + 否定测试通过） |
| 5 | ~~Flutter 编译环境~~ | ✅ **已解决**（`flutter-check.yml`，见 P.12）—— 解除 G-07/G-08，解锁 G-05 |
| 6 | **第 1 轮可否标记完成** | ❌ **不可**（E.10b 原 9 项 → 静态分析 1 项已可解除，余 **8 项**；需重跑门禁后结项） |
| 7 | ~~文档漂移~~ | ✅ **已修复**（16 处 → 0），新增 `check_docs_consistency.py` 守护（见 P.11） |
| 8 | **下一步优先级** | ~~P.7 编译环境~~ ✅ · ~~P.9 #4–#6~~ ✅ → **`data/repositories` 实现与接线** > CI 覆盖率门槛 > 平台壳与构建 > UI 三形态 > 平台插件层 > Spider 引擎（详见 **P.13 §5**） |

---

### P.11 文档一致性核查（本轮新发现）

除代码核查外，本轮对**全部 12 个文档**做了交叉核对，发现 3 类文档漂移 + 1 项事实遗漏：

| # | 问题 | 具体表现 | 处置 |
|---|------|---------|------|
| 1 | 原 `PROGRESS.md` 严重过期（已并入附录 A） | ① 仍写「53 键 / 12 组」（现行 98 / 21）② 仍列 6 个校验脚本（现行 10）③ 引用**重构后已删除的路径**（`lib/contract/schema.dart`、`lib/domain/spider/`、`lib/domain/remote_source/`）④ 进度 50% 未经门禁校验 | **整篇重写**为对齐真相源的状态快照 |
| 2 | 原 `PROJECT_LAYOUT.md` 与 D18 冲突（已并入附录 B） | 描述的是中途生成的简化结构，与方案 §2.4 五层架构（D18 定案）不一致 | **重写**为 §2.4 落地快照，并标注空目录现状 |
| 3 | `contract/docs/prefs_keys_revision_v1.1.md` 缺历史范围声明 | 文中「53 键 / 12 组」未声明是 v1.1 时期状态，易被误读为现行值 | 加**历史范围声明**（指向现行 98 键与 P.6） |
| 4 | 原进度文档遗漏 `pubspec.yaml` | 此前 P.3 记「平台壳未创建」，但 `pubspec.yaml` **已被 git 跟踪**且依赖已对齐契约 | 更正为「工程清单 ✅ 已交付；`android/`/`macos/`/`windows/` 目录 ⬜ 未创建」 |

#### 根因与防再犯

**根因**：文档与代码各自演进，**没有自动校对**——与「契约漏 44 键」同类：
校验只覆盖「实现↔契约」，未覆盖「文档↔事实」。

**处置**：新增 `scripts/check_docs_consistency.py`（v6 体系共 **10 个**校验脚本），把文档漂移转为可检测：

| 规则 | 说明 |
|------|------|
| 键数 | 出现已知陈旧口径（44/53/57/63 键）即失败 |
| 组数 | 陈旧口径（12/13 组）即失败（须与「键/分组」共现，避免误伤） |
| 失效路径 | 引用重构后已删路径即失败 |
| 关键文档 | 主方案文档（本文件）必须存在 |
| 脚本数 | **须与 `scripts/check_*.py` 目录实际数量一致**（v6.1 由「仅告警」改为**硬失败**） |
| 历史豁免 | 仅两种显式方式：行内强标记（v1.x / 修订 / 历史 / → 等）或块级标记 `<!-- docs-guard:history --> … <!-- /docs-guard:history -->` |

**上线效果**：首次运行抓出 **16 处漂移**；修正后 **0 处**。
期间还修掉检测器自身 3 处误报（白名单「14 键」、iOS 依赖脚本计数、`sources/js` 的「30 脚本文件」）。

> **v6.1 补丁（漏洞修复）**：v6 的 `HISTORY_MARKS` 含「初版 / 估计 / 见 P.6」等弱标记，
> 使主方案 §2.2/§2.4/§2.8/C.1 的 **4 处陈旧「57 键」**仅凭一句「（初版估计值，见 P.6）」
> 即被整行豁免——**守卫对自身最该守的文档实际失效**。v6.1 移除这三个弱标记、引入块级历史标记，
> 并令脚本数检查硬失败；收紧后立刻抓出 **4 处**残留漂移（3 处陈旧键数 + 1 处脚本数）并修正。

> **教训**：文档漂移与契约遗漏是同一类问题——**只靠人工核对必然复发**，
> 必须把「事实基准」写成可执行断言。

---

### P.12 核心层交付与 CI 验证通道（2026-09-29 增补）

**增补 commit**：`fc9e8bcc`（核心层 + 单测）· `ef06b193`（指令顺序修复）

#### 1. Flutter CI 验证通道（解除 G-07 / G-08）

| job | runner | 内容 | 结果 |
|-----|--------|------|------|
| `contract-checks` | ubuntu-latest | 9 个契约校验脚本 + conformance runner（45 项） | ✅ |
| `flutter-analyze` | ubuntu-latest（x86-64；与 golden 基线生成环境一致，防跨平台伪 diff） | Flutter 3.47.5 → `pub get` → `flutter analyze` → `flutter test` | ✅ |

- **首跑即抓到 28 errors + 8 warnings**（相对路径写错、record 返回类型不符、`kIsWeb` 未导入、未使用导入、`assets/` 缺目录），全部修复后 **analyze 0 issues**——证明此前「未编译验证」的代码确实藏有缺陷。
- `flutter test` 由空跑转为真实执行：**78 用例全部通过**（G-05 起步；v6 已扩展至 **143 用例**）。
- 意义：本机 aarch64 无法运行 Flutter（G-07）→ 由 GitHub Actions macOS runner 绕过，**编译 / 静态 / 单测验证闭环成立**，后续所有纯 Dart 工作可直接交付验证。

#### 2. 核心层 `lib/core/`（P.9 第 4 项，21 文件）

| 模块 | 文件 | 职责 |
|------|------|------|
| `constants/` | `app_constants.dart` | 应用 / DB / 网络 / 目录 / 日志常量（对齐契约与 iOS） |
| `errors/` | `exceptions.dart` `failures.dart` | **14 个错误码** + 7 类 `VBoxException` + `sealed Failure`（9 类，含可重试判定）+ 归一映射 |
| `network/` | `http_body_decoder.dart` `http_client.dart` `network_info.dart` | 契约 §4.2 探测链**权威实现**；HTTP 客户端（UA / 超时 / 指数退避重试 / 解码 / 异常归一）；可达性抽象 |
| `storage/` | `storage_paths.dart` `file_store.dart` `secure_store.dart` | 目录布局（根目录注入）· 原子写文件 · 敏感键存储抽象 |
| `utils/` | `charset.dart` `json_utils.dart` `logger.dart` `result.dart` `string_utils.dart` `time_utils.dart` | 字符集原语 + 码表注册 · JSON 宽容取值 · 环形缓冲日志 · `Result<T>` · 字符串 / 时间工具 |

**分层约束落实**：核心层**零插件依赖**（纯 Dart、可单测）；插件能力（路径 / 安全存储 / 连通性）以接口形式下沉 `platform/`。

#### 3. 消重：契约逻辑双份漂移

`domain/entities/spider/http_bridge.dart` 原本自带一份编码探测链 → 上移核心层后该文件 **204 行 → 75 行**，仅 **re-export**；
`scripts/check_spider_domain.py` 同步改为「校验核心层实现 + 校验委托关系」，防止回退成双份。

#### 4. 单测（G-05 起步，7 文件 78 用例；v6 后为 12 文件 143 用例，见 P.13）

| 文件 | 覆盖 |
|------|------|
| `charset_test.dart` | 归一映射（GBK 8 变体）· meta 探测 · 非法 utf-8 → null · 未注册码表不产乱码 |
| `json_utils_test.dart` | 宽容转换（`"12"`/`12.9`/`true`）· 空容器兜底 · 编解码往返 |
| `string_time_test.dart` | SHA-256 / MD5 标准向量 · HTML 清洗 · URL 解析 · Unix 秒往返 · 相对时间分级 |
| `result_failure_test.dart` | `fold` / `map` · 8 类异常 → Failure 归一 · 可重试判定 |
| `logger_test.dart` | 环形淘汰（容量 500）· 级别过滤 · 广播流订阅 |
| `network_test.dart` | 探测链 ①②③④ + 兜底链顺序 · MockClient 覆盖 5xx 重试 / 4xx 不重试 / 网络异常归一 / POST 编码 |
| `storage_test.dart` | 未配置抛错 · 目录布局 · 幂等建目录 · 原子写 / JSON / 删除 / 列举 · 内存安全存储 |

#### 5. 本轮暴露并修复的实现缺陷

| 缺陷 | 根因 | 修复 |
|------|------|------|
| 21 个 `Favorite` undefined | `database_manager.dart` 相对路径写成 `models/models.dart` | 改为 `../../models/models.dart` |
| 6 个返回类型错误 | `decodeResponseBody` 声明 `(List<String>,bool)` 实为 `(String,bool)` | 修正声明 |
| `kIsWeb` 未定义 | Flutter 3.47 的 `material.dart` 不再透传 foundation | 显式导入 `foundation.dart` |
| 2 个 directive 顺序错误 | `export` 写在类声明之后 | 前移至 import 之后 |
| 7 个未使用导入 + `assets/` 缺失 | 模型文件冗余导入；`pubspec.yaml` 声明目录不存在 | 清理 + 建 `assets/.gitkeep` |

#### 6. 待确认（契约语义）

契约 §4.2 ④ 末位 `ISO-8859-1` 属**全域映射**（任意字节均可解码成功），
故 ⑤「全部失败 → base64」在纯 Dart 语义下**不可达**。
已在 `http_body_decoder.dart` 标注并保留防御性分支，待契约方明确「④ 失败」的判定标准（如乱码率阈值）。

#### 7. 顺带修复：CI 管理文件被回退

`api_push2.py` 曾把本地旧版本推回远程，回退 CI 自动 bump 的版本号（3.1615 → 3.1614）。
已新增 `CI_MANAGED` 排除集（`vbox/Info.plist` / `vbox.xcodeproj/project.pbxproj` / `CHANGELOG.md`），**永不参与推送与删除**。

---

### P.13 全量体检与问题清单（2026-09-29，v6 新增）

> **触发**：第 1 轮增量交付（核心层 / 用例层 / 远程数据源 / 单测）后的**全量复查**。
> **方法**：各层文件清点 → 引用关系（接线）扫描 → 文档口径比对 → 工程配置缺口检查 →
> 远程仓库清单核对。**合计发现 21 项：6 项已修、15 项待处理。**

#### 1. 各层实测（文件数，`lib/` 69 + `test/` 12）

| 层 | 目录 | Dart 文件 | 状态 |
|----|------|----------|------|
| 契约层 | `lib/contract` | 2 | ✅ 已交付（`abi/` 仍为空，见 §4-12） |
| 核心层 | `lib/core` | 21 | ✅ 已交付（5 模块） |
| 数据层 | `lib/data` | 18 | 🔶 local 有实现；`repositories/` 空（见 §4-1） |
| 领域层 | `lib/domain` | 24 | ✅ entities / repositories / usecases 齐备 |
| 表现层 | `lib/presentation` | 2 | 🔶 仅 `ui_mode` |
| 平台层 | `lib/platform` | **0** | ⬜ 全空（4 个子目录） |
| 测试 | `test` | 12（**143 用例**） | ✅ 全绿 |

**CI 实测（历史快照，v6 全量体检时）**：`flutter analyze` 0 issues · **143 单测通过** · **11 个校验脚本**全绿 ·
conformance **45/45** · iOS IPA 构建链路成功。

#### 2. 高危缺陷（✅ 本次体检当场修复）

| # | 问题 | 证据 | 处置 |
|---|------|------|------|
| 1 | **`.version` 未纳入 `api_push2` 的 `CI_MANAGED`** | 远程 `BASE_BUILD=1619` vs 本地 `1614`；`build-ipa.yml` 的 bump 任务会 `git add … .version`，`changelog.yml` 以其为触发源 | ✅ commit `529180a3`，**已验证推送后远程仍为 1619** |

> **教训（必须固化）**：CI 自管文件为 **4 个** —— `vbox/Info.plist`、
> `vbox.xcodeproj/project.pbxproj`、`CHANGELOG.md`、`.version`。
> 上一次只排除了前 3 个，导致版本号被本地旧值回推（3.1615 → 3.1614）。
> **规则：凡 CI bump / changelog 任务会写入的文件，一律排除出 API 推送集。**

#### 3. 本轮交付过程中由 CI 抓出并修复的编译级缺陷（5 类 / 6 处提交）

| 缺陷 | 根因 | commit |
|------|------|--------|
| `analyze` 28 errors + 8 warnings | 相对路径写错（连带 21 个 undefined）、record 返回类型不符、`kIsWeb` 未导入、7 个未使用导入、`assets/` 目录缺失 | `eda3abf6` |
| directive 顺序错误 ×2 | `export` 写在类声明之后（`directive_after_declaration`） | `ef06b193` |
| `const` 内使用字符串插值 ×6 | `const ValidationFailure('…$id')` 非法常量 | `6b339fca` |
| 测试名 `$` 未转义 | `'…名称$地址…'` → `$中文` 被当作标识符插值 | `6b339fca` |
| MockClient 响应缺 charset | `package:http` 的 `Response(String …)` 在无 charset 时按 **latin1** 编码，含中文即抛错（被数据源捕获成 `ParseFailure`，造成 2 个用例假失败） | `24c15bd9` |

#### 4. 待处理问题清单（15 项，按严重度）

| # | severity | 问题 | 影响 / 证据 |
|---|----------|------|------------|
| 1 | 🔴 高 | ~~`lib/data/repositories/` 为空 —— 用例层无实现、**lib 内 0 处引用**~~ | ✅ **v6.7 已闭环**：四个仓储实现 + `app.dart` 组装注入（见 P.19）；门禁 ④ 待 UI / 平台层补齐后整体复核 |
| 2 | 🔴 高 | ~~平台壳 `android/` `macos/` `windows/` 全缺，CI 无 build job~~ | ✅ **v6.11 已闭环**：三端平台壳交付（`com.vbox.player`）+ CI `build-android`/`build-macos`/`build-windows` job；门禁 ③/⑤ 由「无能力」转为「已具备编译通道」（v6.12 CI 首跑全绿 → **已通过**，见 P.22） |
| 3 | 🔴 高 | CI 未测量覆盖率（无 `flutter test --coverage`） | 344 用例通过 ≠ 覆盖率 ≥70%；✅ **v6.6 已闭环**：CI 增 `flutter test --coverage` + `check_coverage.py`（全 lib 口径 70% 硬门槛），本机整体 **71.1%**（见 P.18 / P.19） |
| 4 | 🟡 中 | ~~DB 路径双真相源：`StoragePaths.databaseFile`（核心层）vs `database_manager.dart` 用 sqflite `getDatabasesPath()`~~ | ✅ **v6.13 已闭环**：`database_manager` 统一取 `StoragePaths.databaseFile`（见 P.23） |
| 5 | 🟡 中 | ~~`prefs_manager.dart` 直连 `flutter_secure_storage`，未走核心层 `SecureStore` 抽象~~ | ✅ **v6.13 已闭环**：新增 `secure_store_adapter.dart`，`PrefsManager` 依赖 `SecureStore` 抽象（见 P.23） |
| 6 | 🟡 中 | ~~`analysis_options.yaml` 缺失~~ | ✅ **v6.13 已闭环**：启用 `flutter_lints`，`flutter analyze` 0 issues（见 P.23） |
| 7 | 🟡 中 | `修复说明.md`（74 行 iOS 旧修复记录）仍在根目录 | 与 **v5 文档合并结论**「全项目仅一份文档」冲突（附录 B 布局已加注）；✅ **v6.1 已归档至 `docs/archive/`** |
| 8 | 🟡 中 | P.8 ⑥「应产出文件齐全」仍列 `PROGRESS.md` / `PROJECT_LAYOUT.md` / `KNOWN_GAPS.md` | 三者已在 v5 并入本方案并删除 → 引用失效 |
| 9 | 🟢 低 | 根目录 6 个 `.o` 编译产物（`cutils.o` `quickjs.o` `quickjs-libc.o` `libbf.o` `libregexp.o` `libunicode.o`） | 无任何引用（`build-quickjs.yml` 用的是 `.obj/` 路径）→ 构建垃圾；✅ **v6.1 已删除** |
| 10 | 🟢 低 | `.gitignore` 未忽略 `*.o` / `build/` | 与第 9 项同源；✅ **v6.1 已补 `*.o` / `build/` / `.dart_tool/`** |
| 11 | 🟢 低 | `pre-commit.sh` 引用的 `check_braces.py` 仓库中不存在 | 钩子实际失效；✅ **v6.1 已删除**（游离脚本一并归入 `scripts/legacy/`） |
| 12 | 🟢 低 | `lib/contract/abi/` 为空 | Spider ABI 在 Dart 侧无镜像（仅 Python runner 校验） |
| 13 | 🟢 低 | ~~`network_info.dart` / `logger.dart` 在 `lib` 内 **0 引用**~~ ✅ **本轮已接线**（A2 `ConnectivityNetworkInfo` + `HttpClient` 离线短路；A3 契约门控 + 埋点 + `LogFileSink` 落盘 + 查看页，见检查报告 §4-A2/A3）；`core.dart` 为顶层 barrel（聚合导出性质）；`CmsV10Datasource` ✅ v6.25 详情页接线已消费 | 预置能力接线闭环，漂移风险解除 |
| 14 | 🟢 低 | `LICENSE` 缺失 | 自用项目，影响低 |
| 15 | 🟢 低 | `assets/.gitkeep` 会被打进包 | 无害 |

#### 5. 待办（按优先级，供下一轮执行）

| 序 | 任务 | 直接收益 |
|----|------|---------|
| 1 | ~~补 `lib/data/repositories/` 四个实现（绑定 database / prefs manager）+ 在 `main.dart`/`app.dart` 注入~~ ✅ **v6.7 已完成** | 让已交付用例真正可用；推进门禁 ④ |
| 2 | ~~CI 增 `flutter test --coverage` + 覆盖率门槛（≥70%，**按全 lib 行数口径**）~~ ✅ **v6.6 已完成**（`check_coverage.py` + CI 步骤） | 门禁 ⑤ 已**可验证**且**达标**（本机整体 71.1%） |
| 3 | ~~创建平台壳（`flutter create --platforms=android,macos,windows .`）+ CI build job（`flutter build apk --debug` 等）~~ ✅ **v6.11 已完成**（D27：官方模板 + 非侵入落地 + `com.vbox.player` + minSdk 24） | 解锁门禁 ③/⑤「三端编译」 |
| 4 | ~~加 `analysis_options.yaml`；DB 路径统一到 `StoragePaths`~~ ✅ **v6.13 已完成**（另含 `SecureStore` 抽象接入 + 敏感键回退读取） | 消除问题 4 / 5 / 6（双真相源 + 抽象未接入 + lint 空白） |
| 5 | ~~根级清理：`.o` ×6、`修复说明.md` 归档、`.gitignore` 补 `*.o`、修 `pre-commit.sh`~~ ✅ **v6.1 已完成** | 仓库卫生（问题 7–11） |
| 6 | 补 `lib/contract/abi/` Dart 镜像 | ABI 校验可在 Dart 侧自证（问题 12） |

#### 6. 门禁状态（E.10b 复核视角）

| 门禁项 | 状态 | 依据 |
|--------|------|------|
| ⑤ 静态分析无 error | ✅ **已可判通过** | `flutter analyze` 0 issues，每次推送执行 |
| ⑤ 单测覆盖率 ≥70% | ✅ **达标** | v6.13 本机实测：触达 86.5%，全 lib 整体 **71.1%**（保守下界），零触达仍有 **24/75**（P.18 / P.19 / P.23） |
| ③/⑤ 三端编译通过 | ✅ **已通过** | v6.11 交付三端平台壳 + 三个 build job（D27）；v6.12 Flutter Check（`f59d04e`）`build-android`/`build-macos`/`build-windows` 首跑全绿 |
| ④ 本阶段承诺功能交付 | ⚠️ **部分解除** | 用例层已有实现（v6.7），仍缺 UI 三形态 / 平台插件层 |

> **结论**：E.10b 原 9 项不达标 → **静态分析（v6）· 覆盖率（v6.6）· 三端编译通道（v6.11）三项已解除，余 6 项**；
> **第 1 轮仍不得标记完成**（余：UI 三形态 / 平台插件层 / 5 引擎 / 4 播放器 / 三端功能对齐 / 侧载链路），需完成 §5 余项后重跑门禁。

---

### P.14 二轮独立复核清单（v6.1 新增，22 项）

> **触发**：对 v6 的 P.13（15 项）做**独立复核**——逐条比对「方案文档 ↔ 仓库实况」，
> 在 P.13 之外又发现 **22 项遗漏**（P.13 完全未覆盖）。分级：🔴 高 / 🟡 中 / 🟢 低。

#### 1. 文档治理（4 项）

| # | severity | 问题 | 处置 |
|---|----------|------|------|
| 1 | 🔴 高 | 主方案 §2.2/§2.4/§2.8/C.1 残留 4 处陈旧「57 键」，且被守护脚本弱标记整行豁免 | ✅ v6.1 已修正（见 P.11 补丁） |
| 2 | 🟡 中 | `check_docs_consistency.py` 文档串写「脚本数须为 8 或 9」，实为 10；且该项检查仅告警不失败 | ✅ v6.1 已改（硬失败 + 动态口径） |
| 3 | 🟡 中 | §6.3 交付物清单仍写 `prefs_keys_v1.json ⚠️ v1.1，53 键（存疑）` | ✅ v6.2 已改为「v1.2，98 键 / 21 组」 |
| 4 | 🟢 低 | `scripts/merge_docs_v5.py` 仍以 v5 命名/引用，文档更名未清干净 | ✅ v6.2 已归档至 `scripts/legacy/`（一次性破坏性脚本，避免误跑改写主文档） |

#### 2. 方案 ↔ 实现偏离（未协调，4 项）

| # | severity | 问题 | 处置 |
|---|----------|------|------|
| 5 | 🔴 高 | 技术选型冲突：§2.3 定 Riverpod / go_router / drift / freezed，实际 provider / sqflite / 手写模型 | ✅ v6.1 D21/D23 + 修订 §2.3 |
| 6 | 🟡 中 | Flutter 版本冲突：§2.3 写 3.24.x，CI 实为 3.47.5 | ✅ v6.1 D22 + 修订 §2.3 |
| 7 | 🟡 中 | §2.4 目标结构含 `plugins/`、`integration_test/`、`assets/{js,python,node,fonts}`，全部缺失 | 待第 2 阶段 |
| 8 | 🟡 中 | 版本体系割裂：`pubspec` 1.0.0+1 vs iOS `.version 3.1620`；Flutter 无签名/自更新流程 | ✅ v6.1 版本已对齐；签名仍缺 |

#### 3. 工程与构建（6 项）

| # | severity | 问题 |
|---|----------|------|
| 9 | 🔴 高 | **无 `pubspec.lock`** → 依赖未锁定、构建不可复现（与 §A21.3「依赖锁版」原则冲突） |
| 10 | 🟡 中 | 无 `integration_test/` → 人测是关键路径，却无自动化 E2E 入口 |
| 11 | 🟢 低 | 无 `.github/ISSUE_TEMPLATE` / PR 模板 / CODEOWNERS；`bug_report_template.yaml` 未接入 Issue 流程 |
| 12 | 🟢 低 | 根目录另有 `check_project.py` / `fix_pbxproj.py` / `fix_pbxproj2.py` 游离脚本（P.13 只列了 `.o` 等） |
| 13 | 🟢 低 | `contract/schema/` 混入脚本中间产物 `_clean_keys.json` / `_extracted_keys.json` / `_unknown_resolved.json` |
| 14 | 🟢 低 | 无 `.editorconfig` / `.gitattributes`（跨端换行与编码一致性） |

#### 4. 安全 / 供应链 / 合规（5 项，P.13 完全空白）

| # | severity | 问题 |
|---|----------|------|
| 15 | 🔴 高 | **第三方框架许可证合规未评估**：MobileVLCKit / swift-mdk / IJKMediaFrameworkWithSSL / MPVKit 含 GPL/LGPL；§S 却断言「无政策合规风险」，风险清单 §3.4 无法律项 |
| 16 | 🟡 中 | **供应链**：`MobileVLCKit` 取自个人 fork `hf805864818/MobileVLCKit` 的 release 二进制（`Podfile`），无校验和 / 来源评估 |
| 17 | 🟡 中 | `scripts/Crypto/` 为 PyCryptodome vendored 副本（AES/ARC4/RSA/PKCS1_v1_5），无许可证 / 来源声明 |
| 18 | 🟡 中 | 内容合规：福利专区聚合成人 / 盗版站点，文档把「侧载」当规避手段而非风险 |
| 19 | 🟢 低 | 敏感数据脱敏仅覆盖 prefs 5 键；网盘 token / `saved_drive_tokens` 在备份导出与日志路径的脱敏无校验 |

#### 5. 功能与架构（3 项，P.13 仅以「平台壳缺失」一笔带过）

| # | severity | 问题 |
|---|----------|------|
| 20 | 🔴 高 | **5 个 Spider 引擎（JSC/QuickJS/Node/NodeLX/Python）Dart 侧零实现**；go-proxy gomobile 绑定、QuickJS FFI 绑定均无 Dart 入口 —— 迁移最大工作量 |
| 21 | 🔴 高 | 4 端播放器后端（Media3/libVLC/media_kit）零实现；`player.dart` 仅有枚举与降级链注释，「可播放」无验证 |
| 22 | 🟡 中 | iOS 遗留 3 处 native 修复（MDK 黑屏 / MPV 闪退 / 切集倒序）仍「需真机验证」；文档仅当文档垃圾待清理，未作功能风险跟踪 |

#### 6. 本轮（v6.1）实际处置与进度

| 类别 | 处置 | 状态 |
|------|------|------|
| 文档守护漏洞 | 移除弱标记 + 块级历史标记 + 脚本数改硬失败 | ✅ 已提交 |
| 残留漂移 | 3 处陈旧键数 + 1 处脚本数 | ✅ 已修正，守卫 **0 漂移** |
| 决策缺口 | D21（provider）/ D22（3.47.5）/ D23（sqflite） | ✅ 已入库 |
| 仓库卫生 | `.o` ×6 删除；游离脚本 → `scripts/legacy/`；游离 md → `docs/archive/`；`.gitignore` 补 `*.o` / `build/` / `.dart_tool/` | ✅ 已完成 |
| 版本 | `pubspec.yaml` → `3.1621.0+1621`（对齐 iOS 方案位） | ✅ 已完成 |
| 未做（环境限制） | `pubspec.lock` 需 Flutter SDK 解析依赖（本地 aarch64 无 Flutter/Dart）→ 留待 CI 首次 `pub get` 后回填 | ✅ **v6.6 已入库**（见 P.18 #6；v6.12 更正此处旧状态） |

> **复核结论**：P.13 的 15 项 + P.14 的 22 项 = **共 37 项**。本轮（v6.1）关闭 **11 项**，
> 余 **26 项**中 5 项 🔴 直接卡 E.10b 门禁（repositories / 平台壳 / 覆盖率 / 5 引擎 / 4 播放器），
> 4 项属安全合规（须专项评估）。**第 1 轮仍不得标记完成。**

---

### P.15 三轮独立复核（v6.2 新增）

> **触发**：对 v6.1「守卫 0 漂移」结论的再次独立验证。
> **方法**：逐层实测（`git ls-files` 点算 / 全脚本实跑 / 逐节比对方案与实况）。
> **结果**：**又发现 12 项**（P.13+P.14 完全未覆盖），本轮全部处置或登记。

#### 1. 文档守卫「格式逃逸」（v6.1 声称已清零，实为未清）

| # | severity | 问题 | 证据 | 处置 |
|---|----------|------|------|------|
| 1 | 🔴 高 | **§C.3 整节仍是 v1.0 口径 14 组 / 57 键**（含已不存在的 `buffer` 组），与同页 §C.1「98 键」矛盾 | `VBOX_PLAN_v6.md` §C.3 原表；守卫因合计写成 `\| **合计** \| **57** \|`（数字后无「键」字）而漏检 | ✅ 已按契约实况重写为 21 组 / 98 键 |
| 2 | 🔴 高 | 守卫的键数规则要求数字**紧邻「键」字**，表格 / 加粗 / 合计写法可逃逸 | `check_docs_consistency.py` 原 `(\d+)\s*键` | ✅ 新增「表格单元格 / 加粗 / 合计」三种包裹形式检测（`INLINE_COUNT_PATTERNS`） |
| 3 | 🟡 中 | 文件数口径漂移：`vbox/` 被 2 处写 **481 文件**（实为 **274**）；仓库总数写 **465**（实为 **530**）；§R.2 `scripts 26→34`、`.github 10→11` | `git ls-files` 实测 | ✅ 已逐处对齐 |
| 4 | 🟡 中 | §3.6 交付物清单仍标 ABI / 备份 / JSON Schema / fixtures / bug_report 「⏳ 待生成」，实则全部已交付 | `contract/` 实况 | ✅ 已改为 ✅ |
| 5 | 🟡 中 | 源码注释引用已删除文档：`app.dart:8` 写「唯一真相源：`docs/PROJECT_LAYOUT.md`」（v5 已删） | 源码扫描 | ✅ 已修正；守卫新增 **Dart 源码扫描** |
| 6 | 🟢 低 | `P.7` 之后多处仍称「Flutter 代码未经编译验证」，与 `flutter-check.yml` 已生效矛盾 | P 章头 | ✅ 已更正 |

#### 2. 方案 ↔ 实现（v6.1 D21–D23 未清干净）

| # | severity | 问题 | 证据 | 处置 |
|---|----------|------|------|------|
| 7 | 🔴 高 | **形态判定三处口径互不一致**：§2.4 / §T.1（平台通道）/ 实现（参数化 + 常量）各不相同；实现 `resolve()` 参数**无调用方**、注释提及的 `ui_tv_mode` **不在契约 98 键内** → 真机 Android TV 判为 `phone` | `ui_mode_resolver.dart` · `app.dart:71` | ✅ 已统一口径（§2.4 加注 + 实现注释改为「占位」） |
| 8 | 🟡 中 | `freezed` 残留 3 处（§A.7 表 / §2.4 目录树 / §4.7）未随 D23 清除 | 全文扫描 | ✅ 已改为「手写模型」 |
| 9 | 🟡 中 | `TODO(D21/stage-1)` 决策号语义碰撞 —— v6.1 把 **D21 占用为「provider」**，该 TODO 实指 **G-01** | `app.dart:84` | ✅ 改为 `TODO(G-01/stage-1)` |

#### 3. 质量基线

| # | severity | 问题 | 证据 | 处置 |
|---|----------|------|------|------|
| 10 | 🟡 中 | **高风险层 Dart 侧零单测**：`lib/contract/*`（98 键镜像 / 9 表 DDL）、`lib/data/datasources/local/*`（db / prefs / **backup**）、`lib/data/models/*`（9 模型）、`lib/presentation/ui_mode` 均无任何 Dart 测试 | `test/` 清点（143 用例全部集中在 core/utils + remote + usecases） | ✅ **v6.4 闭环**：新增 7 文件 / 103 用例（contract / models / local datasources / ui_mode），单测 143 → 246；**覆盖率仍需 CI 补 `--coverage` 方可判**（见 P.16 #5） |

#### 4. 契约真相源（P.13/P.14 完全空白）

| # | severity | 问题 | 证据 | 处置 |
|---|----------|------|------|------|
| 11 | 🟡 中 | **契约 v1.2 键对象异构**：前 12 组为 `{type, default, desc[, sensitive]}`，后 9 组为 `{type, storage, evidence, desc}` —— **D19「键须标注 storage」仅落实 9/21 组** | `prefs_keys_v1.json` 逐组解析 | ✅ **v6.3 已闭环**：98/98 键补齐 `storage`（见 §C.3 结构统一注）+ `check_contract_sync` 规则 3d 防回归 |

#### 5. 工程卫生

| # | severity | 问题 | 处置 |
|---|----------|------|------|
| 12 | 🟢 低 | `README.md` 仍为「iOS 聚合视频播放器」，未反映 D14 多端唯一仓库；CI `flutter-check.yml` 注释过期（9 脚本 / 30 文件 / test 为空） | ✅ README 补多端说明；CI 注释对齐（10 脚本 / 69 文件 / 143 用例） |

#### 6. 本轮（v6.2）处置小结

| 类别 | 处置 | 状态 |
|------|------|------|
| 守卫加固 | 新增表格/加粗/合计数值检测 + Dart 源码失效引用扫描 + 「取代」历史词 | ✅ |
| 文档修正 | §C.3 重写 / §6.3 / §3.6 / 文件数 / freezed 残留 / P.6 加块级历史标记 | ✅ |
| 口径统一 | §2.4↔T.1↔实现（形态判定）；TODO 改指 G-01 | ✅ |
| 工程卫生 | README / CI 注释；`merge_docs_v5.py` → `scripts/legacy/` | ✅ |
| 登记待办 | 高风险层零单测（#10） | ✅ **v6.4 已闭环**（7 文件 / 103 用例） |
| 待办闭环（v6.3） | 契约 storage 异构（#11）→ 98/98 键标注 `storage` + `check_contract_sync` 规则 3d + 负向测试 | ✅ |
| 深度复核（v6.4） | P.16 新增 **7 项**遗漏（1 🔴 / 4 🟡 / 2 🟢），见下节 | ⬜ 登记跟踪 |
| 五轮复核（v6.5） | P.17 本机实测复现 v6.4 声明 + 覆盖率**首测**，新增 **8 项**（2 🔴 / 5 🟡 / 1 🟢），见下节 | ⬜ 登记跟踪（#5 已修） |
| 六轮复核（v6.6） | P.18 收口批次（Spider 单测 + 覆盖率门禁），新增 **3 项**（🟡 ×2 / 🟢 ×1），见下节 | ⬜ 登记跟踪（#3 无需处理） |
| 七轮复核（v6.7） | P.19 仓储实现批次 + 契约漂移修复，新增 **3 项**（🟡 ×2 / 🟢 ×1），见下节 | ⬜ 登记跟踪（#1 / #3 已修） |
| 八轮复核（v6.9） | P.20 文档文件名版本化 + 守卫加固，新增 **2 项**（🟡 ×2），见下节 | ✅ 本轮 2 项**全部已修** |
| 九轮复核（v6.10） | P.21 清账批次（文档漂移归零 + 守卫加固 + 代码小修），新增 **5 项**（2 🔴 / 2 🟡 / 1 🟢），见下节 | ✅ 本轮 5 项**全部已修** |
| 十轮复核（v6.11） | P.22 平台壳批次（三端编译门禁解锁），新增 **3 项**（🟡 ×1 / 🟢 ×2），见下节 | ✅ CI 首跑验证（v6.12） |
| 十一轮复核（v6.13） | P.23 P0 清障批次（静态分析 + DB 路径 + 安全存储抽象 + 敏感键回退），新增 **2 项**（🟡 ×2），见下节 | ✅ 本轮 2 项**全部已闭环** |

> **结论**：v6.1 的「守卫 0 漂移」并不成立 —— §C.3 以格式化写法长期逃逸。
> v6.2 已堵住该向量并修正全部可离线处置项；**第 1 轮仍不得标记完成**（门禁项未变）。

> **教训（二次）**：守卫一旦以「字面邻接」判数值，就会被**格式化**绕过。
> 断言须覆盖同一事实的多种书写形式（表格 / 加粗 / 合计 / 单位后缀）。

---

### P.16 深度遗漏复核（v6.4 新增）

> **触发**：#10 高风险层单测补齐后，对「已完成阶段」的第**四次**独立复核（前三次见 P.13/P.14/P.15）。
> **方法**：以新增的高风险层单测为**探测器**逐层实测 —— 测试本身即证据。
> **结果**：又发现 **7 项**（1 🔴 / 4 🟡 / 2 🟢），均为 P.13–P.15 未覆盖。

#### 1. 契约与数据层（本轮单测直接暴露）

| # | severity | 问题 | 证据 | 处置 |
|---|----------|------|------|------|
| 1 | 🔴 高 | **敏感键缺 UserDefaults 回退读取**：契约与实现 docstring 均声明「iOS 曾写入 UserDefaults，Flutter 端读取需兼容」，但实现只读 secure storage、**不回退 SharedPreferences** → 自 iOS 迁移后首读 5 个敏感键将拿**默认值（丢值）** | `PrefsManager.get` 安全分支；`prefs_keys.dart` 顶部注 | ⬜ 登记（须首启一次性把 UserDefaults 里的敏感键搬入 secure storage，再标记迁移完成） |
| 2 | 🟡 中 | **读取类型不符 → `TypeError` 抛出（非静默回退）**：`SharedPreferences.getInt` 对 String 值 `as int?` 直接抛；契约 `type` 与历史存储类型不一致时**读取即崩** | 实测：`test/data/datasources/local/prefs_manager_test.dart` | ⬜ 登记（建议 `get` 包 try/catch → 回退契约默认值） |
| 3 | 🟡 中 | **`credential_extra` 键被当普通键写明文**：`pg_source` / `qr_scan` 契约语义为「存于凭据对象 extra，非独立键」，但 `_isSecure = sensitive ∪ keychain` **不含 `credentialExtra`** → 走 SharedPreferences | `prefs_manager.dart:_isSecure`；契约 `storage` 字段 | ⬜ 登记（要么排除，要么按语义并入凭据对象） |
| 4 | 🟡 中 | **同类字段敏感标注不一致**：`quark_device_id` 标敏感，而**同类**的 `baidu_local_pcs_device_id`（设备 ID）与 `saved_drive_tokens`（网盘 token 存储键）**未标敏感** → 明文落盘 | 契约逐键；`prefs_keys.dart` cloud / pg 组 | ⬜ 登记（需人工对照 iOS 语义裁定，勿擅改以免破坏迁移读取） |

#### 2. 工程与流程

| # | severity | 问题 | 证据 | 处置 |
|---|----------|------|------|------|
| 5 | 🟡 中 | **文档守卫不覆盖「用例数 / 文件数」类事实**：v6.2 声称文件数已逐处对齐，但守卫仅硬校验 键 / 组 / 脚本 三类、无自动断言 → 本轮 `143 → 246` 若不同步即再漂移 | `check_docs_consistency.py` 规则 1–2 | ⬜ 登记（可增「测试文件数 / 用例数」断言，或文档不写死数值） |
| 6 | 🟡 中 | **备份仅「导」不「还原」**：`BackupManager` 只有加解密 + 信封编解码，**无 DB dump / restore 落地**；#10 仅覆盖加解密层，「可还原」仍无实现与验证 | `backup_manager.dart` 全文 | ⬜ 登记（既有功能缺口，随「数据互通」轮补） |
| 7 | 🟢 低 | **`DbModel` 抽象基类成死代码**：9 个模型均未 `extends DbModel`，其 `fromMap` 为 `UnimplementedError`、`table` 恒 null | `data/models/db_model.dart`（全仓唯一引用点） | ⬜ 登记（接线或删除，二选一） |

#### 3. 结论与门禁

> 本轮补齐单测**只提高可测性，不改变门禁结论**。P.16 的 4 项 🔴/🟡 属**功能性 / 安全性缺口**，
> 须在后续轮次实修；叠加 P.13–P.15 累计未闭环的 🔴 项（`repositories` 曾未接线 / 平台壳 /
> 覆盖率不可判 / 5 引擎 / 4 播放器 / 供应链），**第 1 轮仍不得标记完成**。

> **教训（三次）**：单测不只是「证明代码对」，更是**发现遗漏的探测器**——
> 本轮 7 项中有 4 项是写测试时才暴露的（读取兼容 / 类型崩溃 / 存储分派 / 死代码）。
> 高风险层长期零单测，等于**放弃了这层探测能力**。

---

### P.17 五轮复核：本地实测 + 覆盖率首次测量（v6.5 新增）

> **触发**：v6.4 声称「`flutter analyze` 0 issues / 246 用例通过」此前**仅来自 CI 声明**、未在本机复现；
> 本轮在本机（`/opt/flutter`，Flutter **3.47.5**）独立实跑，并首次执行 `flutter test --coverage`。
> **结果**：v6.4 的全部声明**逐一复现为真**；覆盖率**首次可测**，又暴露 **8 项**此前无从发现的问题（2 🔴 / 5 🟡 / 1 🟢）。

#### 1. 实测复核（v6.4 声明 → 本机结论）

| 声明（v6.4） | 本机实测 | 结论 |
|---|---|---|
| `flutter analyze` 0 issues | `No issues found!`（7.6s） | ✅ 复现 |
| 246 用例通过 | `00:30 +246: All tests passed!` | ✅ 复现 |
| 守卫 10 脚本 + conformance 45/45 | 10/10 rc=0；`合计 45 项：通过 45 · 失败 0` | ✅ 复现 |

> 注：`check_mpv_installed_dependencies.py` 退出码 1 —— 它是 **iOS 侧 MPVKit 依赖**检查，不属契约守卫套件，
> 也不在 `flutter-check.yml` 的 10 个脚本内；本机无 MPVKit 资产故失败，**非本轮引入**。

#### 2. 覆盖率首次测量（`flutter test --coverage`）

| 指标 | 数值 | 说明 |
|------|------|------|
| 触达文件口径 | **83.4%** | 1240 / 1487 行，**41** 个文件 |
| lib 文件总数 | **69** | `find lib -name '*.dart'` |
| **零触达文件** | **28** | 未被任何测试 import → 实际 0% |
| Spider 实体层零触达 | **789 行** | `lib/domain/entities/spider/`（5 文件） |

> **口径警告**：lcov 的 83.4% **只统计被触达的文件**；28 个零触达文件按 lcov 口径**不进分母**。
> 若据此宣称「覆盖率 83.4% ≥ 70%」是**错的** —— 按「全 lib 行数」整体口径必然 **< 70%**，**门禁 ⑤ 不达标**。

#### 3. 本轮新发现（8 项）

| # | severity | 问题 | 证据 | 处置 |
|---|----------|------|------|------|
| 1 | 🔴 高 | **覆盖率口径陷阱**：lcov 只算触达文件，零触达文件被排除在分母外 → 极易被误读为「已达标」 | 仅 41/69 文件进 lcov | ✅ **v6.6 已闭环**：新增 `check_coverage.py`，按**全 lib 行数口径**重算 + 70% 硬门槛 |
| 2 | 🔴 高 | **最高风险层（Spider 实体层）零单测**：#10 覆盖了 contract / models / local / ui_mode，**独漏 spider** —— 5 文件 789 行全 0%，而 Spider 是本项目最大风险（E1：6075 行单体 / 5 引擎） | `lib/domain/entities/spider/` 未被任何测试触达 | ✅ **v6.6 已闭环**：新增 `test/domain/entities/spider/` **5 文件 / 98 用例**，该层 **0% → 5/5 文件触达** |
| 3 | 🟡 中 | **`lib/core/network/network_info.dart` 零触达**（连通性判定，24 行） | 不在 lcov | 🟡 **仍零触达**（已由 `check_coverage.py` 每次打印零触达清单持续跟踪） |
| 4 | 🟡 中 | **CI 仍无覆盖率步骤/门槛**：本机虽已测量，但 CI 不跑 → **不可防回归**，门禁 ⑤ 对 CI 仍不可判 | `flutter-check.yml` | ✅ **v6.6 已闭环**：CI 增 `flutter test --coverage` + `check_coverage.py` 门槛步骤 |
| 5 | 🟡 中 | **`.gitignore` 缺 `coverage/`**：本地跑 `--coverage` 即产生 `coverage/lcov.info`，当前会被误入库 | `.gitignore` | ✅ **v6.5 已补 `coverage/`** |
| 6 | 🟡 中 | **`pubspec.lock` 未入库且未被忽略**：应用工程应提交 lockfile 以保证可复现构建，现为「游离未跟踪」 | `git status` | ✅ **v6.6 已入库** |
| 7 | 🟡 中 | **`lib/app.dart` 零触达 + 仍含 `TODO(G-01)`**：形态接线未完成，与 G-01 同源 | 不在 lcov；`app.dart:124` | ⬜ 登记（随 G-01） |
| 8 | 🟢 低 | **14 个 barrel 文件（纯 re-export）无逻辑**，会干扰「按文件数」的覆盖率口径 | `core.dart` / `models.dart` 等 | ⬜ 登记（覆盖率按行口径，不按文件数） |

#### 4. 结论与门禁

> 本轮**证明 v6.4 声明为真**（246 用例 / 0 issues 本机复现），并把门禁 ⑤ 从「不可判」
> 推进为 **「可测但明确不达标」**：整体 < 70%、**28/69 文件零触达**、最高风险层（spider）未测。
> 叠加 P.13–P.16 累计未闭环项，**第 1 轮仍不得标记完成**。
>
> **后续（v6.6）**：#1 / #2 / #4 / #6 已在本轮收口批次闭环（详见 P.18），门禁 ⑤ 转为**达标（临界）**。

> **教训（四次）**：「CI 声明为真」不等于「本机可复现」，而「覆盖率未测量」会长期掩盖
> **最高风险层（spider）零单测**这一结构性缺口。测量本身即发现遗漏的手段。

---

### P.18 六轮（收口）复核：Spider 单测补齐 + 覆盖率门禁做实（v6.6 新增）

> **触发**：v6.5 把门禁 ⑤ 判为「明确不达标」后，本轮执行**收口批次**——补最高风险层单测、
> 把覆盖率从「本机一次性测量」升级为**CI 可验证的门槛**。全部为本机（Flutter 3.47.5）实测。

#### 1. 实测复核（本机）

| 项 | 结果 | 结论 |
|---|---|---|
| `flutter analyze` | `No issues found!`（10.1s） | ✅ |
| `flutter test` | `00:46 +344: All tests passed!` | ✅ 246 → **344**（+98） |
| 新增 Spider 单测 | `test/domain/entities/spider/` 5 文件 / 98 用例 | ✅ 全部通过 |
| `check_coverage.py` | 整体 **70.6%** ≥ 70% | ✅ 门槛通过 |

#### 2. 覆盖率复测（口径对比）

| 指标 | v6.5 | v6.6 | 变化 |
|------|------|------|------|
| 触达文件口径 | 83.4%（1240/1487） | **85.6%**（1479/1727） | +2.2pp |
| 触达文件数 | 41 / 69 | **46 / 69** | +5 |
| **零触达文件** | 28 | **23** | −5（Spider 层 5 文件全部触达） |
| **全 lib 整体口径** | < 70% | **≈70.6%（保守下界）** | 门禁 ⑤：不达标 → **达标（临界）** |

> **口径说明**：整体口径分母 = 已触达文件 LF + 零触达文件「非空非注释行」估计；
> 后者把 class/字段/括号等**非插桩行**也算入分母 → 整体覆盖率为**保守下界**，真实值更高。
> 该口径由 `check_coverage.py` 固化为**硬门槛 70%**，且每次打印零触达清单。

#### 3. 本轮新发现（3 项）

| # | severity | 问题 | 证据 | 处置 |
|---|----------|------|------|------|
| 1 | 🟡 中 | **整体口径达标但仅临临界**（≈70.6%）：`check_coverage.py` 门槛无缓冲，后续任意新增未测代码即可能击穿 70% | 保守下界 vs 70% | ⬜ 登记（随仓储/平台壳交付补测抬升） |
| 2 | 🟡 中 | **23 个零触达文件中含 6 个纯 barrel**（`core.dart` / `models.dart` / `errors.dart` 等，仅 re-export）：按「文件数」看很刺眼，按「行数」看影响极小 | `check_coverage.py` 清单 | ⬜ 登记（覆盖率按行口径，不按文件数，勿被文件数误导） |
| 3 | 🟢 低 | **`.version` / `pubspec.yaml` 版本号与文档 v6.6 不同步**：本方案文档版本（v6.6）为**文档自身的修订版本**，与 App 版本号（`3.1621.0+1621`）**语义不同**，无需联动 | `pubspec.yaml` | ✅ 无需处理（文档修订版本 ≠ App 版本号） |

#### 4. 结论

> 收口批次把 v6.5 的**唯一 🔴 风险项（Spider 零单测）**闭环，并把门禁 ⑤ 从
> **「明确不达标」**推进为**「达标（临界）」**——但 23 个零触达文件仍在，**收口 ≠ 第 1 轮完成**。
> 第 1 轮真正剩余的功能缺口是 **`lib/data/repositories/` 四个实现 + 接线**（P.13 §5-1）。
>
> **后续（v6.7）**：该缺口已在**仓储实现批次**闭环（详见 P.19）。

---

### P.19 七轮复核：仓储实现批次 + 契约漂移修复（v6.7 新增）

> **触发**：P.13 §4-1 / §5-1 指认 `lib/data/repositories/` 为空是第 1 轮最后的功能缺口；P.18 收口后执行
> **仓储实现批次**：交付四个仓储实现 + 接线，并对其做独立复核。全部为本机（Flutter 3.47.5）实测。

#### 1. 实测复核（本机）

| 项 | 结果 | 结论 |
|---|---|---|
| `flutter analyze` | `No issues found!` | ✅ |
| `flutter test` | `+365: All tests passed!` | ✅ 344 → **365** |
| 新增仓储单测 | `test/data/repositories/` 4 文件（favorite / history / subscription / remote_source） | ✅ 全通过 |
| `check_coverage.py` | 整体 **71.1%** ≥ 70% | ✅ 门槛通过 |
| 11 守卫脚本 + conformance | 全绿（`check_mpv_installed_dependencies.py` 不属契约套件） | ✅ |

#### 2. 交付清单

| 层 | 文件 | 说明 |
|---|---|---|
| 数据层 | `data/repositories/{favorite,history,subscription,remote_source}_repository_impl.dart` | 实现 `domain/repositories/*` 四契约，绑定 `DatabaseManager` / `PrefsManager`，内层异常经 `Failure.from` 归一为 `Result` |
| 数据层 | `data/repositories/repositories.dart` | barrel（纯 re-export，无逻辑 → 零触达） |
| 入口 | `app.dart` | 组装仓储 → 注入用例层（`MultiProvider`）；`DatabaseManager.instance.database` 触发建库 / 迁移 |
| 测试 | `test/data/repositories/*_test.dart` ×4 | 真库（`sqflite_common_ffi`）CRUD + DDL 约束 + 缓存 / TTL（`MockClient`） |

#### 3. 覆盖率复测

| 指标 | v6.6 | v6.7 | 变化 |
|---|---|---|---|
| 触达文件口径 | 85.6%（1479/1727） | **86.4%**（1618/1873） | +0.8pp |
| **全 lib 整体口径** | ≈70.6% | **71.1%**（1618/2277） | +0.5pp（P.18 #1「门槛无缓冲」略有缓解，仍偏紧） |
| lib 文件 | 69 | **74** | +5（4 实现 + 1 barrel） |
| **零触达文件** | 23 | **24** | +1（新增 barrel `repositories.dart` 未被触达） |

#### 4. 本轮新发现（3 项）

| # | severity | 问题 | 证据 | 处置 |
|---|----------|------|------|------|
| 1 | 🟡 中 | **契约漂移（功能缺陷）**：订阅「友好判重键」被写成 `(dyname, dyurl)`，而 DDL 唯一约束为 **`dyurl UNIQUE`**（地址全局唯一）→ **同址异名**会绕过前置判重、直接撞 DB 唯一约束，向 UI 暴露底层 SQLite 错误而非「已存在」提示；且 `subscription_repository.dart` / `subscription_usecases.dart` docstring 与 DDL 冲突 | `schema_v1.sql:48`；`usecases_test.dart`（原「唯一键为 名称+地址」）与 `subscription_repository_test.dart`（同址异名第二次插入失败）**自相矛盾** | ✅ **已修**：接口 / 实现 / 用例 / 测试 fake 统一为 `findByUrl(dyurl)`；docstring 更正为 `dyurl UNIQUE`；用例层补「同址不同名拒绝」回归用例 |
| 2 | 🟡 中 | **`app.dart` 仍零触达**：DI 组装（仓储 ↔ 用例）无单测；新增 barrel 使零触达 23 → 24 | `check_coverage.py` 清单 | ⬜ 登记（与 G-01「UI 三形态」同源，随 presentation 装配覆盖） |
| 3 | 🟢 低 | `favorite_repository.dart` docstring 称实现「第 2 轮落地」，与实际（v6.7 第 1 轮）不符 | 契约注释 | ✅ **已修**：改为指向具体实现文件 |

#### 5. 结论与门禁

> 仓储实现批次把 **P.13 §4-1（🔴）与 §5-1 第 1 项**闭环——用例层从「可测但不可用」变为**已接线可用**；
> 门禁 ④ 转**部分解除**（仍缺 UI 三形态 / 平台插件层），门禁 ⑤ 覆盖率**达标（71.1%）**。
> 但零触达 24/74（含 `app.dart`）仍在，**第 1 轮仍不得标记完成**。
>
> **教训（七次）**：写实现最容易漏掉的不是 CRUD，而是**「唯一键语义」**——DDL 与业务判重口径不一致时，
> 单测会**各自为真**（仓储测 DDL 唯一约束、用例测业务口径），**只有交叉核对契约**才能发现漂移。
> 本轮 11 个守卫脚本全绿，唯独**领域层注释与用例判重口径未被守卫覆盖**。
>
> **新增建议（登记）**：为「仓储契约唯一键」加一条守卫——比对 `domain/repositories/*` 声明的判重键
> 与 `contract/schema/schema_v1.sql` 的 `UNIQUE` 事实，防止同类漂移复发。

---

### P.20 八轮复核：文档文件名版本化 + 守卫加固（v6.9 新增）

> **触发**：D24（文档版本递增）落地后复核，发现**决策号误引**与**文件名版本不受治理**两个遗留；
> 同时把「文件名须携带版本号」升级为强制规则（D25）。**本机实测**：11 守卫脚本 + conformance 45/45 全绿（本版无代码 / 契约改动）。

#### 1. 本轮新发现（2 项）

| # | severity | 问题 | 证据 | 处置 |
|---|----------|------|------|------|
| 1 | 🟡 中 | **决策号误引**：末章称本文件为「**唯一现行文档**（D17–D20）」，但现行 D17–D20 是「契约键范围 / 目录结构 / storage / 阶段完成判定」，与「仅一份文档」**毫无关系** → 疑为 v5 旧编号与新 D 编号**碰撞**的残留（同类引用另有 1 处，见 P.13 §4 #7） | 全文 `D17–D20` 引用 ×2 | ✅ **已改注**为「**v5 文档合并结论**」（不为历史叙述补造决策号） |
| 2 | 🟡 中 | **文档文件名不受治理**：修订版本只活在正文（「（现行）」行 / 「本版变更」块），文件名恒为 `VBOX_PLAN_v6.md` → 从文件系统侧无法判断现行版本，易误读为「v6 大版本 = 最新」 | `docs/` 目录 | ✅ **已修（D25）**：重命名为 `VBOX_PLAN_v6.9.md`，守卫**规则 6** 强制三处一致；旧文件名入 `DEAD_DOCS` 防回流 |

#### 2. 守卫加固（`check_docs_consistency.py`）

| 规则 | 内容 | 覆盖的失效模式 |
|---|---|---|
| **6（v6.9 新增）** | 文件名版本 ↔ 版本历史「（现行）」行 ↔ 顶部「本版变更」块，**三处必须相等**；文件名须为 `vX.Y` 形式 | 改名不同步、忘记升版本、多处版本并存 |
| **7（v6.9 新增）** | 决策表 `**Dn**` 编号**唯一性** + 全文 `D<编号>` 引用**无悬空**（引用的编号必须存在于决策表） | 编号重复、引用已删除 / 不存在的编号 |
| 3（扩展） | `DEAD_DOCS` 增列 `VBOX_PLAN_v6.md` / `VBOX_PLAN_v5.md` → **文档与源码注释**中的旧文件名引用即刻失败 | 改名后残留旧引用（本轮据此确认 8 处引用全部更新） |

> **教训（八次）**：文档的「版本」若只活在正文里，文件系统与人的直觉就会**分叉** ——
> 文件名必须与文内版本**同源同增**；而**引用型事实**（决策号、旧文件名）必须由守卫**扫全仓**，不能靠人肉 grep。
> 本轮扩展 `DEAD_DOCS` 后一次跑出全部残留，证明该模式有效。

---

### P.21 九轮复核：清账批次（文档漂移归零 + 守卫加固 + 代码小修）（v6.10 新增）

> **触发**：进入下一阶段前的全量复检。**本机实测**：Flutter 3.47.5 · `flutter analyze` 0 issues ·
> `flutter test` 365 用例全通过 · 11 守卫脚本 + conformance 45/45 全绿。

#### 1. 复核结论（Git 状态虚警）

| 项 | 现象 | 判定 |
|----|------|------|
| 本地 `main` 与 `origin/main` 显示「分叉」（本轮观测 8 / 17） | 上一轮以 **GitHub API**（`scripts/api_push2.py`）推送，重建提交 SHA 与 CI 自动 bump 提交交错（远端每推一次 `ci: auto bump version`） | ✅ **虚警**：`git diff main origin/main` 仅 `.version` / `Info.plist` / `project.pbxproj` 三个 **CI 托管文件**有别，v6.1–v6.9 内容**全部已在远端**，无丢失 |

#### 2. 本轮最有价值的发现：守卫「块级豁免」结构性失效 🔴

| # | severity | 问题 | 证据 | 处置 |
|---|----------|------|------|------|
| 1 | 🔴 高 | **`docs-guard:history` 块缺闭合标记**：版本历史块开标后**无对应闭合标记**，致其后 **L104–L3158 整段**（§C.3 / §2.x / E.10b / P.1–P.9）被判为历史区 → **键数 / 组数 / 失效路径规则整体静默失效**（此前「守卫 0 漂移」结论因此**部分失真**） | 全文档仅 2 处闭合标记，均在 P.15 区 | ✅ **已补闭合**；闭合后立即抓出 **2 处陈旧键数 + 1 处旧文件名引用**并修正 |
| 2 | 🔴 高 | **`AppInfo` 版本与 `pubspec.yaml` 不一致**：`version='1.0.0'` / `buildNumber=1`，而 pubspec 为 `3.1621.0+1621`（注释却称「与 pubspec 一致」） | `lib/core/constants/app_constants.dart` | ✅ **已对齐** `3.1621.0` / `1621`；并新增守卫**规则 8** 强制 |
| 3 | 🟡 中 | **过泛历史标记成豁免后门**：过泛的「遗漏 / 冗余」使现行清单行凭「无遗漏」自我豁免 | 本轮实测 | ✅ 移除该两标记，并新增「NN 个」写法检测 |
| 4 | 🟡 中 | **目录现状陈述漂移**：`data/repositories` 已于 v6.7 交付（5 文件）却仍标「未实现」；`platform/*`、`presentation/{phone,tv,desktop,…}` **实际未创建**却标为已预建 | 附录 A §三 / P.3 未完成表 | ✅ **已改**为「未创建 / 已交付」；新增守卫**规则 9** 禁不可验证的目录声明 |
| 5 | 🟢 低 | **失效路径残留**：`android-min-sdk21-compat.md`（实为 `contract/docs/android-compat.md`）、`vbox_flutter/`、`flutter/`、`KNOWN_GAPS` 引用、`app.dart:84` 行号 | 附录 A/B / §2.4 / A21 | ✅ 逐处修正 |

#### 3. 守卫加固（`check_docs_consistency.py`）

| 规则 | 内容 | 覆盖的失效模式 |
|---|---|---|
| **8（v6.10 新增）** | `pubspec.yaml` 的 `version`(`X.Y.Z+N`) ↔ `AppInfo.version` / `buildNumber` **必须一致** | 版本号双源漂移（本轮 #2） |
| **9（v6.10 新增）** | 现行文档**不得出现不可验证的目录声明**（`git` 不跟踪无文件的目录） | 目录现状虚标（本轮 #4） |
| 1（扩展） | 数值检测补「`NN 个`」写法（此前可绕过 `NN 键` 规则） | 格式化 / 措辞逃逸 |
| 历史豁免（收窄） | 移除过泛标记「遗漏 / 冗余」 | 自我豁免后门（本轮 #3） |
| 3（扩展） | `DEAD_DOCS` 增列旧文件名 `VBOX_PLAN_v6.9.md` | 改名后残留旧引用 |

> **教训（九次）**：守卫「**不报错**」≠「**没问题**」——**豁免机制本身**也会失效（一个漏写的闭合标记，
> 就让三千行脱离监管）。凡「静默豁免」类设计，必须有**自检**（如：块标记必须成对出现、豁免行数上限告警）。

#### 4. 代码与依赖小修

| 项 | 变更 |
|----|------|
| `lib/core/constants/app_constants.dart` | `AppInfo.version` `1.0.0`→`3.1621.0`；`buildNumber` `1`→`1621`（对齐 pubspec） |
| `pubspec.yaml` | 移除**零引用**依赖 `dio`、`collection`（`flutter pub get` 后 lock 同步） |
| 源码注释引用 | `app_constants.dart` / `storage_paths.dart` / `charset.dart` / `app.dart` 的文档名 → `VBOX_PLAN_v6.10.md` |

> **登记项（下轮守卫候选）**：① 块级标记**成对性**自检（本轮漏洞的根治，见 D26）；
> ② `check_docs_consistency.py` 目前只扫 `*.md`，`.github/workflows/*.yml` 的文档引用不在监管内（本轮手工同步）。

---

### P.22 十轮复核：平台壳批次（三端编译门禁解锁）（v6.11 新增）

> **触发**：清账批次后进入「动工」，执行 P.13 §5 第 3 项（平台壳 + CI build job）。
> **本机实测**：`flutter pub get` · `flutter analyze` **0 issues** · `flutter test` **365 用例全通过** ·
> 守卫 **11 脚本** + conformance **45/45** 全绿。三端编译由 **CI 首跑验证 → 已通过**
> （Flutter Check run `36600564607`，`f59d04e`，5 job 全绿；本机无 Android SDK / JDK 17 / Xcode）。

#### 1. 交付内容

| 项 | 内容 |
|----|------|
| 平台壳 | `android/` / `macos/` / `windows/`（`flutter create --org com.vbox --project-name vbox --platforms=android,macos,windows`，共 **66 文件**：`android/` 20 · `macos/` 28 · `windows/` 18）+ `.metadata` |
| 落地方式 | **非侵入**：临时目录生成后**仅拷贝平台目录 + `.metadata`**，**不改动** `lib/` / `test/` / `pubspec.yaml`（D27） |
| 包名 | Android `namespace` / `applicationId` = macOS `PRODUCT_BUNDLE_IDENTIFIER` = **`com.vbox.player`**（对齐 §A21.3；`MainActivity.kt` 迁至 `com/vbox/player/`） |
| minSdk | **显式锁 24**（D12；`flutter.minSdkVersion` 在 3.47.5 亦为 24，显式化以防隐式漂移） |
| CI | `flutter-check.yml` 新增 **build-android**（ubuntu + JDK 17，`flutter build apk --debug`）/ **build-macos**（macos-15）/ **build-windows**（windows-latest）三个 job；触发路径补 `android/**` `macos/**` `windows/**` |

#### 2. 门禁影响（E.10b）

| 门禁项 | 变更前 | 变更后 |
|--------|--------|--------|
| ③/⑤ 三端编译 | ❌ 无平台壳、无 build job | ✅ **已通过**（v6.12：CI `f59d04e` 首跑 `build-android`/`build-macos`/`build-windows` 全绿） |

> 余项不变：UI 三形态 / 平台插件层（`lib/platform/*`）/ 5 引擎 / 4 播放器 / 三端功能对齐 / 侧载链路。
> **第 1 轮仍不得标记完成**（D20）。

#### 3. 待确认 / 风险

| # | 项 | 说明 |
|---|----|------|
| 1 | 🟢 CI 首跑已验证 | ✅ **v6.12 闭环**：Flutter Check（`f59d04e`）5 job 全绿，`build-android` / `build-macos` / `build-windows` 均 success → 门禁 ③/⑤ 判定「三端编译通过」 |
| 2 | 🟡 模板版本较新 | 模板生成 AGP **9.1.0** / Kotlin **2.4.0** / Gradle **9.3.1**（Flutter 3.47.5 默认）；若与 runner JDK 不匹配，需在 CI 侧调整 |
| 3 | 🟢 ~~`analysis_options.yaml` 仍缺~~ | ✅ **v6.13 已闭环**：`flutter_lints` 生效，`analyze` 0 issues（P.13 §4 #6） |

#### 4. 收尾核对（文件名版本化 + 一致性复检）

| # | 项 | 处置 |
|---|----|------|
| 1 | 文档文件名版本化 | `VBOX_PLAN_v6.10.md` → `VBOX_PLAN_v6.11.md`（D25），同步 README / 4 处 Dart 注释 / 守卫 `DEAD_DOCS`（v6.10 入防回流） |
| 2 | 平台壳文件数口径 | 首稿误记「68 文件」→ 实测 `git ls-files --others` 为 **66 文件**（`android/` 20 · `macos/` 28 · `windows/` 18）+ `.metadata`，全文 4 处已更正 |
| 3 | README 平台壳状态漂移 | README 仍写「平台壳尚未创建」→ 更正为「v6.11 已交付」，并在顶层目录表补 `android/` · `macos/` · `windows/` 行 |
| 4 | CI 注释脚本数 | 头注「10 个 Python 校验脚本」易被读作套件总数（实为 11）→ 澄清为「10 个纯 Python（不含需 lcov 的 `check_coverage`）」 |

> 注：以上均为文档一致性修正，**不改动 `lib/` / 契约 / 测试**，各项事实计数不变（74 lib 文件 / 28 测试文件 / 365 用例 / 11 脚本）。

---

### P.23 十一轮复核：P0 清障批次（静态分析 + DB 路径 + 安全存储抽象）（v6.13 新增）

> **触发**：v6.12 CI 首跑验证后，执行 P.13 §5 第 4 项（清障批次）。**本机实测**（Flutter 3.47.5）：
> `flutter pub get` · `flutter analyze` **0 issues** · `flutter test` **371 用例全通过** ·
> 守卫 **11 脚本** + conformance **45/45** 全绿 · `check_coverage.py` 整体 **71.1%**（≥70%）。

#### 1. 交付内容

| 项 | 内容 |
|----|------|
| 静态分析 | 新增 `analysis_options.yaml`（`include: package:flutter_lints/flutter.yaml`，排除平台壳与 `build/`）；`dart fix --apply` 清 **79 条** + 手工 **1 条** `unrelated_type_equality_checks` → `flutter analyze` **0 issues** |
| DB 路径单一真相源 | `database_manager.dart` 移除 sqflite `getDatabasesPath()`，统一取核心层 `StoragePaths.databaseFile`；`DatabaseManager.dbFileName` 改为引用 `DbConstants.fileName`（去第二真相源） |
| 安全存储抽象 | 新增 `lib/data/datasources/local/secure_store_adapter.dart`（核心层 `SecureStore` 的 `flutter_secure_storage` 实现）；`PrefsManager` 依赖 `SecureStore` 抽象、**不再直连插件** |
| 敏感键回退读取 | `PrefsManager.get` 安全分支为空时**回退读 SharedPreferences**，命中即迁移入安全存储并清明文（修复 iOS 迁移后 5 敏感键首读丢值） |
| 守卫升级 | `check_prefs_manager.py` 规则 3 → 「须经 `SecureStore` 抽象且不得 `import package:flutter_secure_storage`」 |

#### 2. 事实计数（v6.13）

| 指标 | v6.12 | v6.13 |
|------|-------|-------|
| lib 文件 | 74 | **75**（+`secure_store_adapter.dart`） |
| 测试文件 | 28 | **29**（+`secure_store_adapter_test.dart`） |
| 单测用例 | 365 | **371** |
| 触达口径 | 86.4% | **86.5%** |
| 全 lib 整体覆盖 | 71.1% | **71.1%**（达标） |
| 零触达文件 | 24/74 | **24/75** |

#### 3. 门禁影响（E.10b）

| 门禁项 | 变更 |
|--------|------|
| ⑤ 静态分析无 error | ✅ 由「已可判通过」→ **`analysis_options.yaml` 落地，`flutter_lints` 真正生效**（0 issues） |

> 余项不变（覆盖率 v6.6 达标 / 三端编译 v6.11–v6.12 通过）；**第 1 轮仍不得标记完成**（D20）。

#### 4. 遗留 / 下批待办

| # | severity | 项 | 说明 |
|---|----------|----|------|
| 1 | 🟡 中 | `dev_dependencies.test` 零引用未移除 | `flutter test` 由 SDK 提供，显式 dev 依赖 `test` 冗余；留待后续批次（对照 v6.10 移除 `dio` / `collection`） |
| 2 | 🟡 中 | ~~三端 product name 未统一~~ | ✅ **v6.14 已闭环**：裁定**维持小写 `vbox`**（三端平台壳 Android label / macOS `PRODUCT_NAME` / Windows 标题实测已一致），`app.dart` `title` / `AppBar` 由大写 `VBox` 对齐小写（见 P.24） |
| 3 | 🟢 低 | `scripts/api_push.py` 与 `api_push2.py` 功能重复 | 与「合并重复脚本」批次一并归并 |

#### 5. 收尾核对（文件名版本化 + 引用同步）

| # | 项 | 处置 |
|---|----|------|
| 1 | 文档文件名版本化 | `VBOX_PLAN_v6.12.md` → `VBOX_PLAN_v6.13.md`（D25），同步 README / 4 处 Dart 注释 / CI 头注 / 守卫 `DEAD_DOCS`（v6.12 入防回流） |
| 2 | 版本历史与变更块 | 补 v6.13「（现行）」行，撤销 v6.12 的「（现行）」标记；版本三处一致由 `check_docs_consistency.py` 规则 6 强制 |
| 3 | 计数口径全文同步 | 现行状态处 lib / 测试 / 用例 / 覆盖率口径统一为 75 / 29 / 371 / 86.5% / 24-75 |

> 注：以上收尾为文档一致性修正，事实以本机实测为准。

---

### P.24 十二轮复核：前置收口批次（B1 类型回退 + 应用名裁定 + 登记）（v6.14 新增）

> 复核方法：本机重装 Flutter **3.47.5** 实测 `flutter analyze` / `flutter test` + **11 守卫** + conformance **45/45**；文档↔代码逐项核对（含跨文件 grep 引用实证）。

#### 1. 交付内容

| 项 | 内容 |
|----|------|
| B1 普通分支读取防崩溃（**P.16 #2 闭环**） | `PrefsManager.get` 普通键分支 `try { switch } on TypeError` → **静默回退契约默认值**（此前历史类型不符首读即崩）；单测「读取时类型不符 → TypeError」改写为「→ 回退默认值，不崩溃」 |
| 应用名大小写裁定（**P.23 §4 #2 闭环**） | 三端平台壳（Android `android:label` / macOS `PRODUCT_NAME` / Windows 窗口标题）实测已统一为小写 `vbox`；**裁定维持小写**，`app.dart` `title` / `AppBar` 由大写 `VBox` 对齐小写 |
| CmsV10Datasource 裁定登记 | 「**实现但未接线**」：接入作回退源 or 删除，**待 UI 批次**决定（本轮不动代码）；文档 P.13 §4 #13 表述同步 |
| 云盘凭据敏感标注登记（P.16 #3 / #4） | `pg_source` / `qr_scan`（`credential_extra`）、`baidu_local_pcs_device_id` / `saved_drive_tokens`（未标敏感）**维持现状（明文）**，登记待 UI 批次对照 iOS 源复核后裁定 |
| 修正过期登记（P.13 §4 #13） | `file_store.dart` 经 grep 实证**已被接线**（`remote_source_repository_impl` 清单缓存：`FileStore.join` / `readJsonMap` / `writeJson`），移出「0 引用」清单 |

#### 2. 事实计数（v6.14）

| 指标 | v6.13 | v6.14 |
|------|-------|-------|
| lib 文件 | 75 | **75**（不变） |
| 测试文件 | 29 | **29**（不变） |
| 单测用例 | 371 | **371**（不变；B1 测试改写断言、不加用例） |
| 触达口径 | 86.5% | **86.5%** |
| 全 lib 整体覆盖 | 71.1% | **71.1%**（达标） |
| 零触达文件 | 24/75 | **24/75** |

#### 3. 门禁影响（E.10b）

**无变化**：本轮为收口与裁定，不触碰 G-01 / G-02 / G-03；**第 1 轮仍不得标记完成**（D20）。

#### 4. 遗留 / 下批待办（更新）

| # | severity | 项 | 说明 |
|---|----------|----|------|
| 1 | 🟡 中 | `dev_dependencies.test` 零引用未移除 | `flutter test` 由 SDK 提供，显式 dev 依赖 `test` 冗余；留待后续批次 |
| 2 | 🟡 中 | **CmsV10Datasource 去留** | 已裁定「暂不动」：接入作回退源 or 删除，待 UI 批次（接线远程源链路时）决定 |
| 3 | 🟡 中 | **云盘凭据敏感标注** | P.16 #3 / #4 维持现状（明文），待 UI 批次对照 iOS 源复核后裁定 |
| 4 | 🟢 低 | `scripts/api_push.py` 与 `api_push2.py` 功能重复 | 与「合并重复脚本」批次一并归并 |
| 5 | 🟢 低 | 零触达 24/75 中有逻辑文件（`network_info.dart` 等）无测试 | 待接线或删除（随 G-01 / 第 2 轮） |

---

### P.25 十三轮复核：phone 形态书架交付（G-01 首块）（v6.15 新增）

> 复核方法：本机 Flutter **3.47.5** 实测 `flutter analyze`（0 issues）/ `flutter test --coverage`（**378 用例**）+
> **11 守卫** + conformance **45/45**；widget 测试注入内存仓储 fakes 走**真用例链路**（非 mock 页面）。

#### 1. 交付内容

| 项 | 内容 |
|----|------|
| G-01 phone 形态书架 | 新增 `lib/presentation/phone/home_shelf_page.dart`：收藏 / 历史双 Tab；**直连 UseCase**（D21 轻量路线，`initState` 缓存用例引用规避 async-gap context lint）；覆盖空态引导 / 错误重试 / 单条移除 / 清空确认框；条目展示来源 · 相对时间（`TimeUtils.relative`）· 集数 · 进度条（`LinearProgressIndicator`） |
| 形态路由接线 | `app.dart` `_RootRouter` 按 `UiMode` 分发：`phone → HomeShelfPage`，`desktop / tv` 保留占位（渐进交付）；原 `TODO(G-01/stage-1)` 移除，改为分形态注释 |
| widget 测试 | `test/presentation/phone/home_shelf_page_test.dart` **7 用例**：收藏空态 / 列表展示 / 移除→空态 / 清空确认 / 历史空态 / 历史进度展示 / 历史清空 |

#### 2. 事实计数（v6.15）

| 指标 | v6.14 | v6.15 |
|------|-------|-------|
| lib 文件 | 75 | **76**（+home_shelf_page.dart） |
| 测试文件 | 29 | **30**（+home_shelf_page_test.dart） |
| 单测用例 | 371 | **378**（+7） |
| 触达口径 | 86.5% | **86.3%** |
| 全 lib 整体覆盖 | 71.1% | **71.8%**（达标） |
| 零触达文件 | 24/75 | **24/76**（新增文件有触达） |

#### 3. 门禁影响（E.10b）

**G-01（UI 三形态）部分解除**：phone 书架块交付；仍待 —— TV 形态、desktop 形态、详情页 / 播放链路（依赖 G-02/G-03）。
E.10b 余项由 **6 → 5 + G-01 部分解除**；**第 1 轮仍不得标记完成**（D20）。

#### 4. 遗留 / 下批待办（更新）

| # | severity | 项 | 说明 |
|---|----------|----|------|
| 1 | 🟡 中 | phone 形态下一块：**远程源列表**（订阅 / 清单） | 远程源用例已接线，UI 待书架验收后开工 |
| 2 | 🟡 中 | desktop / tv 形态（G-01 余项） | 待 phone 形态齐整后依次开工 |
| 3 | 🟡 中 | 详情页 / 播放入口（书架条目 onTap 现为 SnackBar 占位） | 依赖 G-02（播放器插件层） |
| 4 | 🟢 低 | `dev_dependencies.test` 零引用 / api_push 脚本重复 | 沿用登记，随工程批次 |

---

### P.26 十四轮复核：phone 远程源列表交付（G-01 第二块）（v6.16 新增）

> 复核方法：本机 Flutter **3.47.5** 实测 `flutter analyze`（0 issues）/ `flutter test --coverage`（**386 用例**）+
> **11 守卫** + conformance **45/45**；widget 测试注入内存仓储 fakes 走**真用例链路**。

#### 1. 交付内容

| 项 | 内容 |
|----|------|
| G-01 phone 远程源 | 新增 `lib/presentation/phone/remote_source_page.dart`：**清单状态卡**（对齐 iOS `LoadState`：idle / loadedCache / loadedRemote / failed，`displayText` 直用领域层；强制刷新按钮）+ **订阅列表**（添加对话框 / 重复地址拒绝（复用用例 `add` 校验）/ 单条删除 / 空态 / 错误重试） |
| 入口接线 | `home_shelf_page.dart` AppBar 新增「远程源」IconButton → `Navigator.push(RemoteSourcePage)`（共享 app.dart 注入的 UseCase） |
| widget 测试 | `test/presentation/phone/remote_source_page_test.dart` **8 用例**：空态+idle / 列表展示 / 删除 / 添加对话框 / 重复地址 SnackBar / 强制刷新（fetchCount 断言）/ 刷新失败 / 相对同步时间 |

#### 2. 事实计数（v6.16）

| 指标 | v6.15 | v6.16 |
|------|-------|-------|
| lib 文件 | 76 | **77**（+remote_source_page.dart） |
| 测试文件 | 30 | **31**（+remote_source_page_test.dart） |
| 单测用例 | 378 | **386**（+8） |
| 触达口径 | 86.3% | **87.0%** |
| 全 lib 整体覆盖 | 71.8% | **73.1%**（达标） |
| 零触达文件 | 24/76 | **24/77**（新增文件有触达） |

#### 3. 门禁影响（E.10b）

**G-01（UI 三形态）继续解除**：phone 书架 + 远程源列表已交付；仍待 —— desktop 形态、TV 形态、详情页 / 播放链路（依赖 G-02/G-03）。
E.10b 余项仍为 **5 + G-01 部分解除**；**第 1 轮仍不得标记完成**（D20）。

#### 4. 遗留 / 下批待办（更新）

| # | severity | 项 | 说明 |
|---|----------|----|------|
| 1 | 🟡 中 | phone 形态下一块：**详情页（收藏 / 历史条目 onTap）** | 需先定义详情页数据通路（依赖远程源内容拉取，G-03 引擎） |
| 2 | 🟡 中 | desktop / tv 形态（G-01 余项） | phone 形态齐整后依次开工 |
| 3 | 🟢 低 | 订阅内容拉取（条目 onTap 现为 SnackBar 占位） | 依赖 G-03 Spider 引擎接线 |

---

### P.27 十五轮复核：desktop 形态交付（G-01 第三块）（v6.17 新增）

> 复核方法：本机 Flutter **3.47.5** 实测 `flutter analyze`（0 issues）/ `flutter test --coverage`（**391 用例**）+
> **11 守卫** + conformance **45/45**；widget 测试注入内存仓储 fakes 走**真用例链路**。

#### 1. 交付内容

| 项 | 内容 |
|----|------|
| G-01 desktop 形态 | 新增 `lib/presentation/desktop/desktop_home_page.dart`：**NavigationRail 宽屏布局**（书架 / 远程源切换，`labelType.all` + `groupAlignment`），右侧内容区切换共享视图；远程源直接内嵌 `RemoteSourcePage`（复用，无返回键冲突） |
| 共享视图抽取 | 新增 `lib/presentation/widgets/library_views.dart`：`FavoritesView` / `HistoryView` 从书架页抽取为**三形态共享组件**（直连 UseCase，空态 / 重试 / 移除 / 清空确认），phone 壳（`HomeShelfPage`）与 desktop 复用同一套逻辑 |
| 形态路由 | `app.dart` `UiMode.desktop → DesktopHomePage`（占位解除）；tv 保持占位 |
| widget 测试 | `test/presentation/desktop/desktop_home_page_test.dart` **5 用例**：默认书架 / 书架展示 / 切远程源（rail label + AppBar title 双出现断言）/ 远程源添加订阅 / 切回书架 |

#### 2. 事实计数（v6.17）

| 指标 | v6.16 | v6.17 |
|------|-------|-------|
| lib 文件 | 77 | **79**（+library_views / +desktop_home_page） |
| 测试文件 | 31 | **32**（+desktop_home_page_test） |
| 单测用例 | 386 | **391**（+5） |
| 触达口径 | 87.0% | **87.1%** |
| 全 lib 整体覆盖 | 73.1% | **73.2%**（达标） |
| 零触达文件 | 24/77 | **24/79**（新增文件有触达） |

#### 3. 门禁影响（E.10b）

**G-01（UI 三形态）继续解除**：phone（书架 + 远程源）+ desktop 已交付；仅余 —— **TV 形态**（焦点规范 T.7）与详情页 / 播放链路（依赖 G-02/G-03）。
E.10b 余项：**G-01 仅余 TV 子项**；**第 1 轮仍不得标记完成**（D20）。

#### 4. 遗留 / 下批待办（更新）

| # | severity | 项 | 说明 |
|---|----------|----|------|
| 1 | 🟡 中 | **TV 形态**（G-01 最后子项） | 需按 T.7 焦点规范（FocusTraversalGroup / D-pad 支持），Android TV 壳已就绪 |
| 2 | 🟡 中 | 详情页 / 播放入口（书架·历史条目 onTap 现为 SnackBar 占位） | 依赖 G-03 Spider 引擎与 G-02 播放器接线 |
| 3 | 🟢 低 | TV 真机焦点验收（G-10） | 需真机，登记待 TV 批次后人工测 |

---

### P.28 十六轮复核：tv 形态交付（G-01 收官）（v6.18 新增）

> 复核方法：本机 Flutter **3.47.5** 实测 `flutter analyze`（0 issues）/ `flutter test --coverage`（**396 用例**）+
> **11 守卫** + conformance **45/45**；widget 测试注入内存仓储 fakes 走**真用例链路**。

#### 1. 交付内容

| 项 | 内容 |
|----|------|
| G-01 tv 形态 | 新增 `lib/presentation/tv/tv_home_page.dart`：**T.7 焦点规范**（`FocusTraversalGroup` + TabBar autofocus）+ 顶部三 Tab（收藏 / 历史 / 远程源）导航，复用三形态共享视图（`library_views` / `RemoteSourcePage`） |
| 形态路由 | `app.dart` `UiMode.tv → TvHomePage`（占位解除）—— **三形态占位全部解除**（phone v6.15 / desktop v6.17 / tv v6.18） |
| widget 测试 | `test/presentation/tv/tv_home_page_test.dart` **5 用例**：默认收藏空态 / 书架展示 / 历史 Tab 切换 / 远程源 Tab（rail label + AppBar title 双出现断言）/ T.7 焦点结构断言（FocusTraversalGroup + 主焦点存在） |

> ⚠️ 测试环境说明：TabBar 的 **D-pad 方向键切换在 widget 测试环境不可靠**（与真机焦点行为有差异），
> 故测试采用「结构断言 + tap 切换」，真机 D-pad 行为归 **G-10**（需 Android TV 真机人工验收）。

#### 2. 事实计数（v6.18）

| 指标 | v6.17 | v6.18 |
|------|-------|-------|
| lib 文件 | 79 | **80**（+tv_home_page） |
| 测试文件 | 32 | **33**（+tv_home_page_test） |
| 单测用例 | 391 | **396**（+5） |
| 触达口径 | 87.1% | **87.2%** |
| 全 lib 整体覆盖 | 73.2% | **73.5%**（达标） |
| 零触达文件 | 24/79 | **24/80**（新增文件有触达） |

#### 3. 门禁影响（E.10b）

**G-01（UI 三形态）解除**：phone（书架 + 远程源）+ desktop + tv 均已交付。
E.10b 余项（最新，v6.20 编号纠偏）：**G-02 平台插件层（含播放器插件 PlayerPlugin.kt/.swift/.cpp）/ G-03 五引擎 / G-05（零触达收尾）/ G-09 侧载链路 / G-10 TV 真机焦点验收**。
**第 1 轮仍不得标记完成**（D20）。

#### 4. 遗留 / 下批待办（更新）

| # | severity | 项 | 说明 |
|---|----------|----|------|
| 1 | 🟡 中 | 详情页 / 播放入口（书架·历史条目 onTap 现为 SnackBar 占位） | 依赖 G-03 Spider 引擎与 G-02 播放器接线 |
| 2 | 🟡 中 | G-01 之后第 1 轮门禁主体：**G-03 五引擎**（Spider） | 需 QuickJS / JS 运行时，`lib/domain/entities/spider/` 已交付可编译 |
| 3 | 🟢 低 | TV 真机焦点验收（G-10） | 需真机，登记待 TV 批次后人工测 |

---

### P.29 十七轮复核：G-03 可行性评估登记（不改码）（v6.19 新增）

> 方法：全量阅读 `contract/docs/abi_v1.md`（引擎表 / 选择规则 / ABI §7）+ `lib/domain/entities/spider/`
> （6 文件，接口层）+ 方案 §4.5（Spider 统一 ABI）+ §1.5.1（iOS SpiderManager 6075 行）+ pubspec（当前无 JS 运行时依赖）。
> 本轮**纯登记，不改码**。

#### 1. 现状盘点

| 层 | 状态 |
|----|------|
| 抽象层 `lib/domain/entities/spider/`（SpiderEngine 接口 / 5 引擎类型 / 站点模式 / 错误码 / 模型） | ✅ 100%（98 单测，可编译） |
| ABI 契约 `contract/docs/abi_v1.md`（JSON over stdio/FFI + HTTP 回调 + 错误码 E_*） | ✅ 已冻结 |
| 引擎实现（`lib/platform/spider/`） | ❌ **目录不存在**，实现 0% |
| conformance Spider IO fixtures | ✅ 已交付 |

#### 2. 5 引擎 × Flutter 三端可行性矩阵

| 引擎 | iOS 实现 | Flutter 三端路径 | 纯 Dart 可测 | 原生 / 分发成本 |
|------|---------|------------------|:---:|------|
| JavaScripCore | 系统框架 | ❌ 三端不可用 → **QuickJS 顶替**（iOS 走原生，不进 Flutter） | — | — |
| QuickJS | QuickJSBridge (C) | FFI 绑原生库（.so/.dll/.dylib） | 部分（FFI mock） | **高**：编译 + 三端打包 + CI 原生 job |
| Node (58080) | 独立进程 | **HTTP 桥**（纯 Dart 请求本地端口） | ✅ 注入假客户端 | 中：需 Node 二进制分发 |
| NodeLX (58083) | lx-music 桥 | **HTTP 桥**（同构，换端口/协议） | ✅ 同 | 中 |
| Python | 嵌入式 3.14 | **子进程 stdio ABI**（`Process.start` + JSON 编解码） | ✅ 本机 / CI 有 python3 | **高**：运行时分发 |

#### 3. 三个关键判断

1. **ABI（§4.5）已把 5 引擎差异收敛到适配层**：引擎 = 协议适配器；Node 桥 / Python 桥 / 引擎工厂是**纯 Dart**，当前环境（本机 + CI 均有 python3、http 可 mock）即可全量验证。
2. **QuickJS 是原生硬骨头**：FFI 绑 C 库需要先决策「原生库来源（自编译 / 第三方预编译）+ 打包进三端侧载包 + CI 原生编译 job」，建议后置，用 Node / Python 桥先把 ABI 链路验证透。
3. **运行时分发是最大隐性风险**：Node / Python 运行时带进 Android TV / Windows / macOS 侧载包的体积与兼容性，是第 1 轮最大不确定性（对应 **E1** 工期翻倍风险）；iOS 侧是嵌入式 Python 3.14。

#### 4. 推荐路线（登记待执行）

| 批次 | 内容 | 环境可验 | 状态 |
|------|------|:---:|------|
| **G-03-A** | 引擎工厂（按站点模式解析 → 引擎选择）+ NodeBridgeEngine（HTTP 桥，ABI 请求/响应 + 错误码映射 + HTTP 回调回传）+ PythonBridgeEngine（子进程 stdio，ABI 编解码）+ ABI 往返 conformance（对齐 fixtures Spider IO） | ✅ 纯 Dart | ✅ **已交付（v6.21，见 P.31）** |
| **G-03-B** | QuickJS FFI 绑定（原生库来源决策）+ Node / Python 运行时分发方案（内置 / 首次下载 / 仅桌面，参考 §4.5 结论与 iOS Python 3.14 实现） | ❌ 需决策 + 原生工具链 | 待决策 |

#### 5. 门禁影响

G-03（5 引擎实现）**G-03-A 部分解除（v6.21）**：桥接协议层（Node/NodeLX/Python 三引擎 + 引擎工厂 + ABI conformance）已交付；
G-03-B（QuickJS FFI + 运行时分发）待决策，G-03 整体**未完全解除**。
E.10b 余项（v6.21）：**G-02 / G-03（G-03-B 余项）/ G-05（零触达收尾）/ G-09 / G-10**。**第 1 轮仍不得标记完成**（D20）。

---

### P.30 十八轮复核：G-02 平台插件层可行性评估登记（含播放器插件）（v6.20 新增）

> 方法：全量阅读 §2.4（平台插件层目录规划）+ §2.5（平台能力矩阵）+ A21.5（播放器能力探测与回退）+
> 三端平台壳实况（`android/app/build.gradle.kts` / `macos/Runner/` Swift / `windows/runner/CMakeLists.txt`）+
> 契约 `abi_v1.md` 播放器 ABI 约束。本轮**纯登记，不改码**。

#### 1. 现状盘点

| 层 | 状态 |
|----|------|
| 平台壳（三端） | ✅ v6.11 交付（Kotlin Gradle DSL / Swift Xcode / C++ CMake，包名 `com.vbox.player`，CI 三端 build job 全绿） |
| 插件实现（`lib/platform/{player,spider,runtime,system}/`） | ❌ 未创建 |
| 播放器 Dart 抽象（映射 iOS `PlayerEngine` 协议） | ❌ 未创建 |
| 播放器回退策略 | ✅ 设计已冻结（A21.5 `selectBackend`：Android Media3→libVLC；macOS AVPlayer→libmpv；Windows libmpv） |

#### 2. 三端播放器插件可行性矩阵

| 端 | 目标（§2.5） | 实现路径 | 原生依赖 | CI 可编译验证 | 分发成本 |
|----|-------------|---------|:---:|:---:|------|
| Android | Media3 主 + libVLC 回退 | Gradle 依赖：`androidx.media3:media3-exoplayer(-hls,-ui)` + `org.videolan.android:libvlc-all`（**aar 自带原生库**） | ❌ **零 NDK**（JVM + aar） | ✅ build-android | 低（依赖进 APK） |
| macOS | AVPlayer 主 + libmpv 回退 | Swift：AVFoundation（**系统框架**）；libmpv 需 dylib 嵌入 + Xcode 链接 | AVPlayer 零依赖；libmpv 需 .dylib | ✅ build-macos（Swift 编译） | 中（libmpv dylib 分发） |
| Windows | libmpv | C++：CMake 链接 mpv（需 `mpv-2.dll`），消息/纹理渲染 | 需 dll | ✅ build-windows | **高**（mpv dll + 依赖链） |

> 另有非播放器插件同属 G-02：`SpiderPlugin` / `QuickJsRuntime` / `PythonRuntime`（Chaquopy，**Gradle 依赖零 NDK**）/ `NodeRuntime` / `SystemPlugin`（UiMode 判定，**v6.2 已登记真机判定接线缺口**）/ `MediaPlaybackService`。

#### 3. 关键判断

1. **Android 播放器插件是 G-02 里最可行的入口**：Media3（JVM）+ libVLC（预编译 aar）均为纯 Gradle 依赖，**无需 NDK**；minSdk 24 满足（A21.4 已核对）；CI build-android 已验证 Gradle 通道 → **G-02-A 可在当前环境完整编译验证**。
2. **macOS AVPlayer 零原生依赖**可先行交付；libmpv 回退与 Windows libmpv 共同受制于**原生二进制分发**（.dylib / mpv-2.dll 需入库或下载策略）→ G-02-B 需决策。
3. **Dart 桥接层先行**：播放器统一走 Dart `PlayerController` 抽象（映射 iOS `PlayerEngine` 协议：type/state/event）+ 平台通道（MethodChannel/FFI）适配，**纯 Dart 可测**（注入假通道），三端插件只是通道实现。
4. **播放能力真机验收不可省略**（E.10b ④「播放器后端均有回退路径」需实测）：Media3→libVLC 回退、AVPlayer→libmpv 回退最终须真机/真机矩阵验证（G-09 关联）。

#### 4. 推荐路线（登记待执行）

| 批次 | 内容 | 环境可验 | 状态 |
|------|------|:---:|------|
| **G-02-A** | Dart `PlayerController` 抽象 + 平台通道桥 + 回退策略枚举 + Android Gradle 接线（media3 + libvlc）+ CI build-android 编译验证 + Dart 单测 | ✅ | ✅ **v6.22 已交付**（详见 P.32） |
| **G-02-B** | macOS AVPlayer 接线（Swift，CI 编译可验）+ Windows/macOS libmpv **原生二进制分发决策**（入库 / 下载策略） | ⚠️ AVPlayer 部分 ✅；libmpv 需决策 | 待决策 |
| **G-02-C** | `SystemPlugin`（UiMode 真机判定，v6.2 缺口）+ `MediaPlaybackService` + 播放真机验收（G-09 关联） | ❌ 需真机 | 待真机 |

#### 5. 门禁影响

G-02（平台插件层）**状态更新（v6.22）**：**G-02-A 已交付**（`lib/platform/player/` 4 文件 + Android 接线 + 15 单测），
G-02 由「未开始」推进到 **部分解除**；G-02-B / G-02-C 仍待决策与真机。
E.10b 余项（**v6.22 最新**）：**G-02（G-02-B/C 余项）/ G-03（G-03-B 余项）/ G-05（零触达收尾）/ G-09 / G-10**。**第 1 轮仍不得标记完成**（D20）。

---

### P.31 十九轮复核：G-03-A 桥接协议层交付（G-03 部分解除）（v6.21 新增）

> 复核方法：本机 Flutter **3.47.5** 实测 `flutter analyze`（0 issues）/ `flutter test --coverage`（**423 用例**）+
> **11 守卫脚本** + conformance **45/45**；Python 桥用例以**真实 python3 子进程**（`conformance/fixtures/python_echo_spider.py`）
> 验证 stdio ABI 往返；Node 桥用例注入 fake HTTP 客户端，无真实端口依赖。

#### 1. 交付内容（`lib/platform/spider/` 6 文件）

| 文件 | 职责 | 对齐来源 |
|------|------|---------|
| `spider_abi.dart` | ABI 请求组装（op / params / ctx）/ 响应解码（ok/data/error/logs/elapsedMs）/ 错误码映射（E_* → SpiderErrorCode，契约 §5.1） | 契约 §7 + §5.1 |
| `node_bridge_engine.dart` | Node（58080）/ NodeLX（58083）HTTP 桥：脚本驻留远端进程，宿主经 `/spider/` ABI 调用；load* 为 no-op，register 即 ready；超时 / SocketException → 结构化错误 | iOS 常驻 Node 进程 + lx-music 桥 |
| `node_http_client.dart` | `NodeHttpClient` 抽象（注入点）+ `LocalNodeHttpClient` 本机实现（15s 超时） | iOS 127.0.0.1:58080 |
| `python_bridge_engine.dart` | Python 子进程 stdio ABI：`loadScript` 写临时 .py、`python3 -u` 常驻、等 READY 行；stdin 写请求行 / stdout 读响应行；超时 / 首行非 READY / 语法错误 → scriptLoad | iOS `PythonSpiderEngine` 脚本语义 |
| `spider_engine_factory.dart` | 按 `SpiderEngineType` 分派：node / nodeLX → NodeBridgeEngine；python → PythonBridgeEngine；quickJS / javaScriptCore → unimplemented（G-03-B 待决策） | 契约 §1 + §1.1 |
| `spider.dart` | barrel（平台层 Spider 导出） | — |

> 设计要点：**引擎差异收敛到适配层**（契约 §4.5 结论落地）—— 三引擎共用 `SpiderAbiCodec`，ABI 请求/响应格式三端一致；
> Node/Python 桥的 `loadScript / loadLibrary / loadScriptFromURL` 语义差异由各引擎自行声明（Node 桥 no-op、Python 桥真实加载）。

#### 2. 测试（新增 4 文件 / 27 用例，全部通过）

| 测试文件 | 用例数 | 覆盖 |
|---------|:---:|------|
| `spider_abi_test.dart` | 7 | encodeRequest 组装 / 成功响应解析（searchContent、homeContent、playerContent fixtures）/ 错误映射 / 非 JSON → E_PROTOCOL / E_* 全映射 |
| `node_bridge_engine_test.dart` | 7 | ABI 请求构造（op/params/ctx）+ 响应解析 / 请求路径 `/spider/` / urls 回填 / E_RUNTIME 映射 / 非 JSON → protocol / 超时 → timeout / 引擎类型断言 |
| `python_bridge_engine_test.dart` | 8 | 真实子进程：READY + homeContent 往返 / keyword 透传 / 剩余 3 op 全链路 / 未加载调用 → register / 首行非 READY → scriptLoad / 语法错误超时 → scriptLoad / URL 加载不支持 / engineType 恒为 python（环境无 python3 时整组 skip） |
| `spider_engine_factory_test.dart` | 5 | node / nodeLX → NodeBridgeEngine、python → PythonBridgeEngine、quickJS / javaScriptCore → unimplemented、注入 fake 客户端走 ABI 调用 |

#### 3. 事实计数（v6.21）

| 指标 | v6.20 | v6.21 |
|------|-------|-------|
| lib 文件 | 80 | **86**（+platform/spider 6） |
| 测试文件 | 33 | **37**（+4） |
| 单测用例 | 396 | **423**（+27） |
| 触达口径 | 87.2%（v6.18 口径） | **86.9%**（2048/2357） |
| 全 lib 整体覆盖 | 73.5% | **74.0%**（达标，2048/2766） |
| 零触达文件 | 24/80 | **25/86**（新增 barrel `spider.dart` 未触达，其余新文件均有测试触达） |

> 注：`lib/platform/spider/spider.dart`（barrel）零触达为**预期**（纯导出无执行逻辑），与既有 barrel 文件（`lib/domain/entities/spider/spider.dart` 等 24 个）同类，不计入门禁问题。

#### 4. 门禁影响（E.10b）

**G-03 部分解除（G-03-A 交付）**：桥接协议层（Node/NodeLX/Python 三引擎 + 引擎工厂 + ABI conformance）已交付，
纯 Dart 可验证路径全部通过；**G-03-B（QuickJS FFI + Node/Python 运行时分发方案）待决策**，G-03 整体未完全解除。
E.10b 余项（v6.21 记；v6.22 已更新）：**G-02 / G-03（G-03-B 余项）/ G-05（零触达收尾）/ G-09 / G-10**。**第 1 轮仍不得标记完成**（D20）。

#### 5. 遗留 / 下批待办（更新）

| # | severity | 项 | 说明 |
|---|----------|----|------|
| 1 | 🟡 中 | **G-03-B**：QuickJS FFI 绑定（原生库来源决策）+ Node / Python 运行时分发方案 | 需决策 + 原生工具链，参考 P.29 §4 |
| 2 | 🟡 中 | **G-02-B**：macOS AVPlayer 接线 + Windows/macOS libmpv **原生二进制分发决策** | 见 P.30 §4；libmpv dylib/dll 分发需决策（G-02-A 已交付） |
| 3 | 🟡 中 | **G-02-C**：`SystemPlugin`（UiMode 真机判定）+ `MediaPlaybackService` + 播放真机验收 | 见 P.30 §4；需真机（G-09 关联） |
| 4 | 🟢 低 | 详情页 / 播放入口接线（Spider 内容 → 播放链路） | 依赖 G-03 引擎接线与 G-02 播放器 |

---

### P.32 二十轮复核：G-02-A 平台插件层首批交付（G-02 部分解除）（v6.22 新增）

> 复核方法：本沙箱无 Flutter SDK（与 P.7 环境约束一致），Dart 验证由 CI `flutter-check.yml`（analyze + test + build-android）
> 复核；本轮在本地完成：源码审读 + 静态用例计数 + Android Kotlin 代码审读（`MediaCodecList` 导入等编译正确性逐项核对）
> + Python 守卫脚本（`check_docs_consistency.py` 等）本地实测。

#### 1. 交付内容（`lib/platform/player/` 4 文件）

| 文件 | 职责 | 对齐来源 |
|------|------|---------|
| `player_channel_bridge.dart` | `PlayerChannelBridge` 抽象（invoke / events / dispose）+ `MethodChannelPlayerBridge` 实现（MethodChannel `com.vbox.player/player` + EventChannel `.../player/events`）+ `backendWireValue`（media3 / libVLC / libmpv / nativeiOS） | 契约 §2.5 + 原生 `PlayerPlugin.kt` wire 值 |
| `channel_player.dart` | 实现 `Player`：open（含 `source.toJson()` + backend wire）/ play / pause / seekTo / setVolume / setSpeed / dispose；事件流解析（state / progress / error → 回调）；`PlatformException` → `PlayerOpenException`（code 透传） | iOS `AVPlayerEngine` 宿主侧语义 |
| `player_controller.dart` | 统一控制层：后端降级链 `_orderedChain`（初始选择 + 链上其余）+ `open` 失败逐级回退 + 状态 / 进度 / 错误转发 + `togglePlay` + `PlayerBackendSelector` 接线（`chainFor` 按平台、`needsFallback` 复杂封装） | iOS `PlayerEngineController` + A21.5 |
| `player.dart` | barrel（平台层播放器导出） | — |

> 设计要点：**通道桥抽象注入**（测试注入 fake 桥，纯 Dart 可测）；**降级链在 Dart 侧统一管理**
> （对齐契约 §2.5 + A21.5：复杂封装 / HEVC 无硬解 → libVLC 回退）；原生失败以 `E_BACKEND_UNAVAILABLE`
> 报回 Dart 侧由 `PlayerController` 捕获并继续回退（libVLC 原生实现在 G-02-B/C 交付）。

#### 2. Android 接线（G-02-A）

| 文件 | 职责 | 编译要点 |
|------|------|---------|
| `android/app/src/main/kotlin/com/vbox/player/PlayerPlugin.kt` | MethodChannel + EventChannel 双通道；`open/play/pause/seekTo/setVolume/setSpeed/dispose`；Media3（ExoPlayer）主后端；state / progress（500ms tick）/ error 事件流；A21.5 判定需 libVLC 时返回 `E_BACKEND_UNAVAILABLE` | Media3 API（`ExoPlayer.Builder` + `DefaultMediaSourceFactory` + `DefaultHttpDataSource.Factory`）；`Player.Listener` 状态映射 |
| `.../player/CodecCapability.kt` | `supportsHevcHardware`（MediaCodecList 探测）+ `selectBackend`（MKV / HEVC 无硬解 → LIBVLC） | 需 `android.media.MediaCodecList` / `MediaCodecInfo` 导入（本批已补，否则编译失败） |
| `android/app/build.gradle.kts` | 依赖：`media3-exoplayer` / `media3-exoplayer-hls` / `libvlc-all`（纯 Gradle 零 NDK） | 仓库 google() + mavenCentral() 已配 |
| `android/app/src/main/kotlin/com/vbox/player/MainActivity.kt` | `configureFlutterEngine` 注册 `PlayerPlugin`（非插件工程手动注册） | `PlayerPlugin.registerWith(flutterEngine)` |

> 说明：`libVLC` 回退原生实现在 **G-02-B/C**（依赖已接线，本批 open 遇需回退媒体返回 `E_BACKEND_UNAVAILABLE`，
> 由 Dart `PlayerController` 降级链捕获 —— 回退路径已在 A21.5 设计 + 单测验证，原生端到端留待真机验收）。

#### 3. 测试（新增 2 文件 / 15 用例）

| 测试文件 | 用例数 | 覆盖 |
|---------|:---:|------|
| `channel_player_test.dart` | 7 | open 参数组装（含 backend wire）/ 原生 PlatformException → PlayerOpenException（code 透传）/ play·pause·seekTo·setVolume·setSpeed·dispose 依次转发 / 参数类型（毫秒 int / 音量·倍速 double）/ state 事件映射（5 态）/ progress 事件（含 isLive）/ error 事件（fatal 透传） |
| `player_controller_test.dart` | 8 | 初始后端失败 → 链上下一个接管 / 全败 → E_NO_BACKEND / .mkv 复杂封装直选 libVLC / open 后 state=opening + 事件流状态转发 / togglePlay（非播放→play、playing→pause）/ 未 open 时控制方法空操作 / 回退时逐级上报 onError / error 事件 fatal 透传 |

> 静态用例计数：`test( 411 + testWidgets( 25 = 436`（含本轮 +15；v6.21 记录口径 423 为
> `flutter test` 运行时计数，与静态声明计数存在循环生成差异，CI 复核为准）。

#### 4. 事实计数（v6.22）

| 指标 | v6.21 | v6.22 |
|------|-------|-------|
| lib 文件 | 86 | **90**（+platform/player 4） |
| 测试文件 | 37 | **39**（+2） |
| 单测用例（静态声明） | 421 | **436**（+15） |
| 触达口径 | 86.9%（v6.21 实测） | 待 CI 复核（新增 4 文件：3 个有测试触达，barrel `player.dart` 零触达属预期） |
| 全 lib 整体覆盖 | 74.0%（达标） | 待 CI 复核 |
| 零触达文件 | 25/86 | **26/90**（新增 barrel `player.dart` 未触达，与既有 barrel 同类，不计入门禁问题） |

> 注：v6.22 变更块中的「423 → 438」按 v6.21 运行时口径外推（423 + 15）；本节表格以**静态声明计数**（436）为准，
> 最终以 CI `flutter test` 运行时报告为准。`lib/platform/player/player.dart`（barrel）零触达为**预期**
> （纯导出无执行逻辑），与既有 25 个 barrel 文件同类。

> **本轮本地实测（v6.22 收尾）**：Python 守卫脚本 **10/10 通过**（`check_docs_consistency` 含防回流：v6.21
> 已入 `DEAD_DOCS`，README / 3 处 Dart 源码注释 / CI 注释同步升版 v6.22）；conformance runner **45/45 通过**；
> Kotlin 审读通过（`MediaCodecList` / `MediaCodecInfo` 导入已补）。Dart analyze / test / build-android 因本机无
> Flutter SDK 留待 GitHub Actions CI 复核（`flutter-check.yml` 已含 G-02-A 新增路径 `android/**`）。

#### 5. 门禁影响（E.10b）

**G-02 部分解除（G-02-A 交付）**：Dart `PlayerController` 抽象 + 平台通道桥 + Android Gradle 接线（Media3 主后端 +
A21.5 回退判定 + 15 单测）已交付；**G-02-B（macOS AVPlayer 接线 + libmpv 分发决策）/ G-02-C（SystemPlugin +
MediaPlaybackService + 真机验收）待决策**，G-02 整体未完全解除。
E.10b 余项（v6.22）：**G-02（G-02-B/C 余项）/ G-03（G-03-B 余项）/ G-05（零触达收尾）/ G-09 / G-10**。**第 1 轮仍不得标记完成**（D20）。

#### 6. 遗留 / 下批待办（更新）

| # | severity | 项 | 说明 |
|---|----------|----|------|
| 1 | 🟡 中 | **G-02-C**：`SystemPlugin`（UiMode 真机判定）+ `MediaPlaybackService` + libmpv 端到端回退真机验收 | 需真机（G-09 关联） |
| 2 | 🟡 中 | **G-05**：零触达文件收尾（覆盖率口径待 CI 复核） | 见 P.33 / P.34 §4 |
| 3 | 🟢 低 | 详情页 / 播放入口接线（Spider 内容 → 播放链路） | 依赖 G-03 引擎接线与 G-02 播放器 |

> v6.24：G-02-B（macOS AVPlayer + libmpv 分发 D28）与 G-03-B（QuickJS FFI + 运行时 D29）已交付，
> 原清单 #1 / #2 关闭，转由 **P.33 / P.34** 复核记录。
> v6.25：详情页 / 播放入口接线（Spider 内容 → 播放链路）已交付，原清单 #3 关闭，转由 **P.35** 复核记录。

---

### P.33 二十一轮复核：G-02-B macOS 播放器接线 + libmpv 分发决策（D28 定稿）（v6.24 新增）

> 复核方法：Swift 源码审读（`macos/Runner/PlayerPlugin.swift`）+ Xcode 工程文件（`project.pbxproj`）PBX
> 结构合法性检查（Python 脚本）+ `MainFlutterWindow.swift` 注册路径核对 + 与 Dart `ChannelPlayer._onEvent`
> 事件解析面逐字段比对（契约 §2.5 wire 协议）+ CI `build-macos` job 复核。

#### 1. 交付内容（macOS 播放器原生）

| 文件 | 职责 | 编译要点 |
|------|------|---------|
| `macos/Runner/PlayerPlugin.swift` | AVFoundation 主后端：MethodChannel `com.vbox.player/player`（open / play / pause / seekTo / setVolume / setSpeed / dispose）+ EventChannel `com.vbox.player/player/events`（state / progress / error）；`timeControlStatus` 观察（buffering / playing / paused）、`currentItem.status` 观察（readyToPlay / failed）、周期 500ms 进度 + 播完 `ended` | import AVFoundation + FlutterMacOS；`FlutterPlugin` / `FlutterStreamHandler` 协议；`NSKeyValueObservation` 管理 |
| `macos/Runner/MainFlutterWindow.swift` | `RegisterGeneratedPlugins` 后手动注册 `PlayerPlugin`（非插件工程模式，对齐 Android `MainActivity.configureFlutterEngine`） | `flutterViewController.registrar(forPlugin:)` + `PlayerPlugin.register(with:)` |
| `macos/Runner.xcodeproj/project.pbxproj` | `PlayerPlugin.swift` 纳入 PBXSourcesBuildPhase / PBXFileReference / Runner group | ID 唯一性 + 引用一致性（脚本检查通过） |

#### 2. A21.5 复杂封装判定（wire 对齐）

- `needsFallback` 清单与 Dart `PlayerBackendSelector.needsFallback` **逐扩展名一致**：`.mkv / .flv / .ts / .rmvb / .avi / .wmv / .m2ts`；
- 命中 → 返回 `FlutterError(E_BACKEND_UNAVAILABLE)`，由 Dart `PlayerController` 降级链捕获继续回退（对齐 G-02-A 已验路径）；
- 事件键名/类型与 `ChannelPlayer._onEvent` 严格对齐：state `{type: state, value}` / progress
  `{type: progress, positionMs, durationMs, bufferedMs, isLive}` / error `{type: error, message, fatal}`。

#### 3. D28 libmpv 原生二进制分发决策（定稿）

| 决策点 | 结论 | 依据 |
|--------|------|------|
| 二进制入不入 git | **不入仓库**：GitHub Release 资产下载（`fetch_mpv_dependencies.sh` 扩展） | 仓库体积 / 侧载产物随包分发（D11）；沿用 iOS `mpvkit-deps-0.0.1` 成熟模式 |
| 资产命名 | `libmpv-{os}-{arch}-{ver}`（dylib / dll）+ 校验和登记 | 与 `mpvkit_external_dependencies.json` 同款资产清单 |
| CI 验证边界 | 仅「下载 + 链接 smoke」；**端到端回退真机验收归 G-02-C** | 桌面真机不可得（本沙箱），避免 CI 假绿 |
| 交付时机 | G-02-C 接入 libmpv 回退实现时落地下载脚本 | 本批不引入原生二进制 |

> **v6.27 修订（D28 资产形态）**：macOS 资产改为**动态库集合** —— 公开源（MPVKit / karelrooted）仅提供静态 `libmpv.a`
> 无法作 dylib 分发，而自包含单文件动态 `libmpv.dylib`（含 FFmpeg）公开源不可得；故采用 media_kit
> `libmpv-darwin-build` 的 macOS 动态库集合（`libmpv.dylib` + `@rpath/libav*.dylib` 等 **18 个 dylib**），
> 资产名 `libmpv-macos-{arch}-0.0.1.tar.gz`，`fetch_libmpv.sh` 下载校验后解包，整组随 App `Contents/Frameworks`
> 分发（依赖由主二进制 `@executable_path/../Frameworks` rpath 解析），并在打包后 ad-hoc 重签。Windows 仍为
> 单一自包含 `libmpv-windows-x86_64-0.0.1.dll`。两资产已发布于公开仓库 `q2787244398/vbox-deps`
> （Release `libmpv-deps-0.0.1`），SHA256 登记于 `scripts/libmpv_external_dependencies.json`。

#### 4. 事实计数（v6.24）

| 指标 | 值 |
|------|------|
| macOS 新增 Swift 文件 | 1（`PlayerPlugin.swift`；`MainFlutterWindow.swift` / `project.pbxproj` 为修改） |
| 复杂封装清单一致性 | 7/7 扩展名与 Dart 侧一致（grep 实证） |
| PBX 结构 | 合法（Python 脚本检查：PBXBuildFile / PBXFileReference / Sources 引用一致，ID 无重复） |
| CI | `build-macos` job 将编译 `PlayerPlugin.swift`（G-07 已解除，CI 复核） |

#### 5. 门禁影响（E.10b）

**G-02 继续解除（G-02-B 交付）**：macOS AVPlayer 主后端 + 双通道 wire 对齐 + libmpv 分发决策（D28）定稿；
**余 G-02-C**（SystemPlugin / MediaPlaybackService / libmpv 端到端回退）需真机验收。E.10b 余项（v6.24）：
**G-02-C / G-05 / G-09 / G-10 / 详情页·播放入口接线**。

---

### P.34 二十二轮复核：G-03-B QuickJS FFI 绑定 + Node/Python 运行时分发（D29 定稿）（v6.24 新增）

> 复核方法：C wrapper 源码审读 + **本地 gcc 实测编译**（`scripts/build_quickjs_wrapper.sh`，产物
> `libvbox_quickjs.so`）+ Dart FFI 抽象 / 引擎源码审读 + 单测静态计数（FFI mock 注入）+ 引擎工厂分派
> 路径核对 + 与 iOS `QJSSpiderEngine` 语义逐条比对（loadScript / registerSpider / init 恰一次 / 5 操作）。

#### 1. 交付内容（QuickJS FFI 绑定）

| 文件 | 职责 | 验证 |
|------|------|------|
| `quickjs/wrapper.h` | C 接口契约：`vq_create_runtime / vq_create_context / vq_eval / vq_free_runtime / vq_free_context / vq_free_string`，`VQ_EXPORT` 跨平台导出（dll / visibility） | — |
| `quickjs/wrapper.c` | 纯 C 封装：`vq_register_console`（console.log / print no-op 防脚本报错）、`vq_eval`（`JS_Eval` 全局求值，异常 → Error 前缀消息） | **gcc 本地实测编译通过**（ubuntu 11.4.0），产物 892KB `.so` |
| `scripts/build_quickjs_wrapper.sh` | 三端编译脚本（.so / .dylib / .dll），含 `CONFIG_VERSION` 宏 + `-lm` 链接 | 本地跑通；CI `build-native-quickjs` job 同款命令 |
| `lib/platform/runtime/quickjs_ffi.dart` | `QuickJsNativeBridge` 抽象 + `DartFfiQuickJsBridge`（`dart:ffi` 加载 + 指针生命周期）+ `UnavailableQuickJsBridge`（安全降级） | FFI mock 注入单测 |
| `lib/platform/runtime/quickjs_bridge_engine.dart` | 实现 `SpiderEngine`：loadScript / loadLibrary / loadScriptFromURL（HttpClient 15s 超时）/ registerSpider（spider → `__JS_SPIDER__` 兜底 + `typeof` 检测）/ 5 操作（homeContent / searchContent / categoryContent / detailContent / playerContent，init 恰一次 + 双返回路径 JSON 包装） | 13 用例 |
| `lib/platform/runtime/runtime.dart` | barrel | — |
| `lib/platform/spider/spider_engine_factory.dart` | quickJS → `QuickJSBridgeEngine`；javaScriptCore → 抛 unimplemented（iOS 原生保留，Flutter 以 QuickJS 顶替） | 工厂测试更新 |

#### 2. 对齐 iOS `QJSSpiderEngine` 语义（逐条核对）

| iOS 语义 | QuickJS 桥实现 | 一致 |
|----------|----------------|:---:|
| `loadScript` → JS 异常转 `E_SCRIPT_LOAD` | `_checkScriptResult`：Error/TypeError/ReferenceError/SyntaxError 前缀 → `SpiderException(scriptLoad)` | ✅ |
| `registerSpider` → 检测 `__JS_SPIDER__` | 注册脚本（`__jsEvalReturn` / `default` / 直赋 + `is_cat=true`）→ 单独 `typeof` 检测（修复注册脚本末表达式布尔污染） | ✅ |
| init 恰一次 | `_inited` 标志：首次 API 调用前 `init(config)`，后续不再重复 | ✅ |
| 返回值字符串（已是 JSON）不双重编码 | `{__type: 'string', __value}` / `{__type: 'object', __value}` 包装 + `JSON.stringify` | ✅ |
| 引擎创建即释放顺序（ctx → rt） | `dispose`：先 `freeContext` 后 `freeRuntime` | ✅ |

#### 3. D29 Node / Python 运行时分发决策（定稿）

| 运行时 | 分发策略 | 依据 |
|--------|----------|------|
| Python | **三端内置 + 桌面系统探测**：Android Chaquopy Gradle 依赖（纯 Gradle 零 NDK）/ iOS 原生 python-stdlib 3.14 常驻 / 桌面探测系统 `python3`，缺失 → `E_BACKEND_UNAVAILABLE` | 对齐 iOS 已落地实现；桌面零打包体积 |
| Node | **仅桌面系统探测 + iOS 原生常驻**；**Android NodeMobile 嵌入成本高 → 登记待评估** | Android 侧 Node 场景少，先不背嵌入成本 |
| 通用 | **不采用「首次下载」运行时** | D11 侧载无商店更新通道，网络依赖与校验不可控 |

#### 4. 事实计数（v6.24）

| 指标 | 值 |
|------|------|
| lib 文件 | **90 → 93**（+`platform/runtime/` 3） |
| 测试文件 | **39 → 40**（+`test/platform/runtime/quickjs_bridge_engine_test.dart`） |
| 单测用例（静态声明） | **436 → 450**（+13 QuickJS 引擎 +1 工厂分派） |
| C wrapper | 本地 gcc 实测编译通过；CI `build-native-quickjs` 复核 |
| 决策 | **D28 / D29 定稿**（决策表 + P.33 §3 / P.34 §3） |

#### 5. 门禁影响（E.10b）

**G-03 继续解除（G-03-B 交付）**：QuickJS FFI 绑定（三端可编译）+ `QuickJSBridgeEngine`（对齐 iOS
语义，13 单测）+ 引擎工厂分派接入；**JavaScriptCore 以 QuickJS 顶替落地**（JSC 仅 iOS 原生保留）。
E.10b 余项（v6.24）：**G-02-C / G-05 / G-09 / G-10 / 详情页·播放入口接线**。

---

### P.35 二十三轮复核：详情页·播放入口接线交付（v6.25 新增）

> 复核方法：源码审读（4 个新 lib 文件 + barrel）+ 单测静态计数（9 / 15 / 8）+ 接线路径核对
> （`library_views.dart` 收藏/历史 onTap + `app.dart` Provider 装配）+ 与契约逐条比对
> （§1.1 引擎选择规则 / §3.4 `vod_play_from`·`vod_play_url` 解析 / §3.5 `playerContent` 二次解析）。

#### 1. 交付内容（详情页·播放入口）

| 文件 | 职责 | 验证 |
|------|------|------|
| `lib/domain/entities/playback/playback_detail.dart` + barrel `playback.dart` | `PlaybackDetail` / `PlaybackEpisode` / `ParsedPlayUrl` / `PlaybackUrlParser`：契约 §3.4 `vod_play_from`（`$$$` 线路，兼容 `$$` 残余）· `vod_play_url`（`#` 剧集 / `$` 名址，地址含 `$` 取首个 `$` 后剩余拼接）解析；空地址/非法段过滤；`from` 缺失按线路序号回填；直链媒体判定（http/https + 20 种扩展名：`.m3u8/.mp4/.mkv/.flv/.ts/.mpd/.mp3/...`）；`initialIndex` 钳制到合法区间 | **9 单测**（双线路多剧集 / 名址含 `$` / 直链判定 / 空值容错） |
| `lib/data/datasources/remote/all_sources_datasource.dart` | 清单 `files.allSources` → **代理降级链**（ghfast → gh-proxy → 直连，对齐 iOS `proxyHosts`）拉取；校验链 HTTP 2xx → JSON 对象 → `AllSourcesContainer.fromJson`；URL 合法性校验（http/https 绝对地址）；`findSite` 按 key 查找站点 | usecases 单测覆盖（容器构造 + 站点查找 + 失败透传） |
| `lib/domain/usecases/detail_playback_usecases.dart` | 链路：站点 key → 模式判定 → **CMS V10**（apiEndpoint/zhanyuan，`?ac=detail&ids=`）或 **Spider 引擎**（node 免脚本 / jsSpider 由 QuickJS 顶替（G-03-B 决策）/ pythonSpider 加载脚本）→ 详情 → `resolvePlayUrl` **三分支**（直链媒体原地址 / API 站点地址即直链 / 脚本引擎 `playerContent` 二次解析）；`_prepareEngine` 脚本 URL 校验（仅 http(s)）+ 注册失败检测（`__JS_SPIDER__`）；CMS 详情 → `VodItem` 归一复用 `PlaybackDetail.fromVod` | **15 单测**（参数校验 / 站点解析 / CMS 路径 / 蜘蛛路径 / resolvePlayUrl 三分支） |
| `lib/presentation/widgets/detail_page.dart` | 详情页：封面（`Image.network` + 占位）+ 影片信息 + 线路 ChoiceChip（>1 线路才显示）+ 剧集 ActionChip（选中高亮 + 点击即播）+ 播放按钮（`PlayerController.open` + `play`，标题 `影片名 - 剧集名`）；续播 `initialIndex` → 线路 + 线路内剧集**双映射**（flat → from/url 反查）；失败重试；加载中 / 播放中状态 | **8 widget 单测**（加载中 / 失败重试 / 线路切换 / 续播高亮 / 播放驱动 / 解析失败提示 / 无剧集禁用） |

#### 2. 接线核对（收藏/历史 → 详情 → 播放）

- `lib/presentation/widgets/library_views.dart`：收藏 / 历史列表项 onTap → `DetailPage`（`siteKey=item.laiyuan` / `vodId=item.detailurl` / `initialIndex=item.jishu` / `title=item.name`），2 处接线一致；
- `lib/app.dart`：装配 `AllSourcesDatasource`（`HttpClient` 注入）+ `CmsV10Datasource` + `DetailPlaybackUseCases`（`loadAllSources` 走清单 → allSources URL → 代理降级链），Provider 注册，详情页经 `context.read` 取用；
- 契约对齐：`$$$` / `#` / `$` 分隔符与 §3.4 示例逐字比对；`playerContent(ids, flag, url)` 参数序（vodId / 线路 from / 剧集地址）对齐 §3.5；引擎选择规则对齐 §1.1（jsSpider → QuickJS 顶替落地）。

#### 3. 事实计数（v6.25）

| 指标 | 值 |
|------|------|
| lib 文件 | **93 → 98**（+`entities/playback/` 2（实体 + barrel）+ `all_sources_datasource.dart` + `detail_playback_usecases.dart` + `detail_page.dart`） |
| 测试文件 | **40 → 43**（+`playback_detail_test.dart` / `detail_playback_usecases_test.dart` / `detail_page_test.dart`） |
| 单测用例（静态声明） | **450 → 482**（+9 +15 +8，磁盘实测一致） |
| 接线 | 收藏/历史 onTap → DetailPage（2 处）+ app.dart Provider（1 处）+ barrel 导出（`remote.dart` / `usecases.dart` / `playback.dart`） |

#### 4. 门禁影响（E.10b）

**详情页·播放入口接线解除**：第 1 轮 UI / 播放数据链路闭环 —— G-01 三形态 + 书架 / 远程源 +
**详情页均交付**，收藏/历史 → 详情 → 播放全链路接通（`siteKey/vodId/initialIndex` → `PlaybackDetail` →
`resolvePlayUrl` → `PlayerController.open/play`）。
E.10b 余项（v6.25）：**G-02-C / G-05 / G-09 / G-10**。

---

### P.36 二十四轮复核：G-02-C Android 平台补全 + G-05 零触达收尾 + G-09/G-10 真机验收清单（v6.26 新增）

> 复核方法：源码审读（G-02-C Android 原生 3 文件 + Dart 桥 2 文件 + 下载脚本）+ 本机实测
> （`flutter analyze` 0 issues · `flutter test --coverage` **504 用例全通过** · `check_coverage.py` 整体 **76.1%** 达标）+
> 零触达逐文件分类 + 真机清单与方案 §S / §T.4 / §A21.5 逐条对照。

#### 1. 交付内容（G-02-C Android 平台补全）

| 文件 | 职责 | 验证 |
|------|------|------|
| `android/.../SystemPlugin.kt` | UiMode 三重判定通道 `com.vbox.system/system`：`getUiModeType`（`UiModeManager.currentModeType`）/ `hasLeanbackFeature` / `hasTouchscreen`；插件未附着 → `E_STATE` | Dart 侧 `MethodChannelSystemBridge` 单测 mock 通道（7 用例） |
| `android/.../player/MediaPlaybackService.kt` | Media3 `MediaSessionService` 前台媒体服务：ExoPlayer + MediaSession 构建，`onGetSession` 返回会话，`onDestroy` 释放 | Manifest 注册 `foregroundServiceType="mediaPlayback"`（编译面验证，真机行为归 G-09） |
| `AndroidManifest.xml` | 双形态兼容：touchscreen / leanback `required=false`；`FOREGROUND_SERVICE(_MEDIA_PLAYBACK)` 权限；TV `LEANBACK_LAUNCHER` 入口 | CI build-android 编译验证 |
| `lib/platform/system/system_bridge.dart` | `SystemBridge` 抽象 + `MethodChannelSystemBridge`（异常安全回退 false 不抛） | **修复缺陷**：`_invoke` 补 `TypeError` 兜底（`invokeMethod<bool>` 遇非布尔回传先抛类型转换错，由补测暴露） |
| `lib/presentation/ui_mode/ui_mode_resolver.dart` + `lib/app.dart` | `resolveModeWithBridge` / `resolveAndroidMode` 纯逻辑 + Android 启动注入桥 | ui_mode_resolver 单测覆盖三重判定 + 接线 |
| `scripts/fetch_libmpv.sh` + `libmpv_external_dependencies.json` | D28 落地：macOS/Windows libmpv 资产 GitHub Release 下载 + SHA256 校验 | 脚本参数化（`LIBMPV_DEPS_*` 环境变量），CI smoke 可验 |

#### 2. 交付内容（G-05 零触达收尾）

| 项 | 值 |
|----|-----|
| 补测 | `test/platform/system/system_bridge_test.dart` **7 用例** / `test/core/network/network_info_test.dart` **2 用例** / `test/core/constants/app_constants_test.dart` **6 用例** / `test/presentation/ui_mode/ui_mode_resolver_test.dart` **7 用例** |
| 零触达 | **29 → 27**（`system_bridge.dart` / `network_info.dart` 转触达；`app_constants.dart` 仍零触达但登记排除） |
| 排除登记（27 个） | **20 barrel**（纯导出，A5 属预期）+ **4 领域仓储接口**（纯抽象，无运行代码）+ **2 入口**（`main.dart` / `app.dart`，根组件由集成冒烟覆盖）+ **1 纯常量**（`app_constants.dart`，编译期内联 lcov 无法记录命中，已有单测验证值） |
| 计数 | lib **98 → 100**、测试文件 **43 → 46**、静态用例 **482 → 504**、整体覆盖 **76.1%**（≥70%）、触达口径 **84.2%** |

#### 3. 交付内容（G-09/G-10 真机验收清单）

- 新增 `docs/真机验收清单_G09_G10.md`：**G-09 侧载链路 24 项**（安装链路 9-1~9-7 / 自更新 9-8~9-14 / 播放器端到端回退 9-15~9-24）+ **G-10 TV 焦点与遥控 17 项**（焦点 5 铁律 10-1~10-6 / 按键映射 10-7~10-12 / D-pad 全流程 10-13~10-17）；
- 前置物料 P1~P8（真机 4 台 + 签名 APK + GitHub Release 资产 + 片源）与执行记录表齐备；
- 解除条件对照：G-09 = 真机安装 + 自更新 + 播放器回退实测；G-10 = TV 真机 D-pad 验证；**G-02-C 端到端回退真机验收并入 G-09**（人测职责 D8）。

#### 4. 门禁影响（E.10b）

**G-02-C 代码交付**（真机端到端回退并入 G-09 清单）；**G-05 收尾交付**（零触达 27/100 全分类排除，
整体覆盖 76.1% ≥ 70%）。E.10b 余项（v6.26）= **G-09 / G-10（真机人测）**。
第 1 轮仍受 D20 约束：**不得标记完成，不得进入第 2 轮**（待真机验收通过后刷新检查报告 verdict）。

---

### P.37 二十五轮复核：P2 遗留清理全批次闭环（A4/B2/B3/D1/D2）（v6.27 新增）

> 复核方法：逐项对照 v6.20 报告 §4 遗留问题清单（A1/A2/A3/A4/B1/B2/B3/C1/C3/D1/D2）grep 复核 + 契约/Dart 镜像双侧比对 + 守卫脚本实测。

#### 1. 交付内容（P2 遗留清理五子项）

| 项 | 处置 | 验证 |
|------|------|------|
| **A4** | 移除 `lib/data/models/db_model.dart` 零继承零使用的 `DbModel` 抽象基类，保留 SQLite 读写辅助函数（`insert` / `update` / `queryAll` / `delete` / `deleteById`），文件注释更新为辅助函数定位 | 无任何 `DbModel` 残留引用（grep 实证）；`check_docs_consistency.py` 引用计数同步；单测 0 破坏（db_model 辅助函数仍被各模型测试经 database_manager 覆盖） |
| **D1** | 移除 `pubspec.yaml` 零引用 `dev_dependencies.test: ^1.25.8`（`package:test` 从未被任何测试文件 import，测试均走 `flutter_test`）；`pubspec.lock` 同步 | `grep package:test test/` 0 命中；`flutter pub get` 通过 |
| **D2** | 以 `api_push2.py` 为基底归并进 `scripts/api_push.py`（保留 API 通道 + diff 模式 + `.version` 自适应），删除 `scripts/api_push2.py` | 唯一推送脚本；全文引用统一为 `api_push.py`（P.13 风险表 / README / CI 注释）；`python3 scripts/api_push.py --help` 可运行 |
| **B2** | `prefs_manager.dart` `_isSecure` 分派新增 `meta.storage == PrefsStorage.credentialExtra` —— PG 凭据 extra 字段（`pg_source` / `qr_scan`）由明文 SharedPreferences 改经核心层 `SecureStore` 抽象走安全存储（与 keychain 键同级）；`check_prefs_manager.py` 静态检查同步 | 守卫 `check_prefs_manager.py` 3 项全过（存在 `_isSecure` / 覆盖 sensitive ∪ keychain ∪ credential_extra / 经 SecureStore 抽象且不直依赖 flutter_secure_storage）；单测安全键集合口径 **11 键** |
| **B3** | 契约 `contract/schema/prefs_keys_v1.json` 升 **v1.3**：`sensitiveKeys` 5 → **7**（新增 `baidu_local_pcs_device_id` 百度 PCS 本地设备指纹（与 quark_device_id 同类）、`saved_drive_tokens` 网盘 token 存储键（UserDefaults 遗留，Keychain 迁移后清除））；Dart 镜像 `lib/contract/prefs_keys.dart` 逐键 `sensitive: true` + `kSensitiveKeys` 同步 | `check_contract_sync.py` 通过（98 键逐键比对 + storage 完整性）；`kSensitiveKeys.length == 7` 单测断言 |

#### 2. 门禁影响（E.10b）

- P2 遗留清理（A4/B2/B3/D1/D2）**全批次闭环**；连同历史已闭环的 A1/B1/C1/C3，v6.20 报告 §4 遗留问题**全部处置**；
- 剩余登记项 A2/A3（预置能力：`NetworkInfo` / `Logger` 仍零引用，设计为后续批次消费）按登记留待后续批次，不计入本轮门禁；
- **E.10b 余项 = G-09 / G-10（真机人测）**：第 1 轮（核心骨架）**代码侧已全部交付**；
- `stage_check_report_stage1.yaml` verdict 仍 **blocked**（D20：真机验收通过前不得标记完成、不得进入第 2 轮）。

---

# 附录部分

---

# 附录 A：项目状态快照（2026-09-29）

> 本附录合并原 `PROGRESS.md`。**详细进度、核查结果与门禁结论见 P.1–P.11**，
> 本附录仅保留总览与 CI 状态，避免与正文重复。

## A.1 阶段总览

```
第 0 阶段  契约冻结        ████████████████████ 100%  ✅ 已过 D13 门禁
第 1 轮    核心骨架        ████████████████████ 100%  ✅ 代码侧已过 D13 门禁（真机验收后移至第 2 轮末，见 D30）
第 2 轮    功能补全        █████░░░░░░░░░░░░░░░░  25%  ⬜ 进行中（批次 A/B/Q 全交付，批次 C–P 未开始；含 G-09/G-10 全量真机验收）
第 3 轮    兼容性与稳定性   ░░░░░░░░░░░░░░░░░░░░   0%  ⬜ 未开始
第 4 轮    数据互通与边界   ░░░░░░░░░░░░░░░░░░░░   0%  ⬜ 未开始
第 5 轮    发布准备        ░░░░░░░░░░░░░░░░░░░░   0%  ⬜ 未开始
```

**第 1 轮 100% 的依据（代码侧）**：9 个交付块完成 **5 个**，另 **3 项计划外交付**，单测达成，平台层与 Spider 引擎代码链路齐备——
✅ 契约层镜像 · ✅ 数据层 · ✅ 领域层实体 · ✅ 入口与形态判定 · ✅ conformance runner
· ✅ 核心层（`lib/core/` 21 文件，计划外，见 P.12）
· ✅ 用例层 + 远程数据源（计划外，见 P.13）
· ✅ Spider 引擎桥接协议层（G-03-A，计划外，见 P.31）
· ✅ UI 三形态（G-01 收官，见 P.28）
· ✅ 单元测试（43 文件 / 482 用例静态声明，v6.25；覆盖率口径与 CI 复核详见 P.32）；
· ✅ 详情页·播放入口接线（收藏/历史 → 详情 → 播放全链路，v6.25，见 P.35）；
· ✅ 平台插件层（**G-02-A/B/C 代码交付**：Dart 控制层 + Android Media3 接线 + macOS AVPlayer + SystemPlugin / MediaPlaybackService + libmpv 分发决策 D28，见 P.32/P.33）
· ✅ Spider 引擎（**G-03-A/B 交付**：桥接协议层 + QuickJS FFI + 运行时 D29，见 P.31/P.34）

> 口径说明（v6.31 修订，D30）：本轮**代码侧已全部交付**，E.10b 门禁的**真机类检查项整体后移至第 2 轮末**
> （G-09 / G-10，含侧载链路 / 自更新 / 播放器端到端回退 / TV 焦点遥控），故第 1 轮按「**代码侧交付 + 自动化门禁**」判定为 **100% 通过**；
> 原 **73%（v6.25 口径）** 为「含真机项未完成」的旧算法（历史值，见版本历史 v6.25/v6.26）。

**第 2 轮 25% 的依据（v6.35，代码侧）**：第 2 轮 WBS 共 **128 个任务条目**（批次 A 13 + B 13 + Q 6 + C 12 + D 8 + E 6 + F 10 + G 10 + H 8 + I 6 + J 5 + K 6 + L 5 + M 6 + N 4 + O 5 + P 5）；本轮已交付 **批次 A（设计基座，13）· 批次 B（远程源与 Spider，13，含 B-05a）· 批次 Q（JSC 三端集成 D6，6）** 共 **32 项**（32/128 ≈ **25%**）——
· ✅ 批次 A：自适应框架 / 页面树收敛 / 输入适配 / 图片组件 / UI 守卫 / 视觉回归基线（35 图归档）/ 品牌资源（658 用例 · 覆盖 75.6%，见 WBS §1）
· ✅ 批次 B：远程源配置 / 站点模式 / JS 全局桥 / QuickJS / 引擎映射定稿 / HTTP 桥 / url 数组对齐 / 站源搜索+腾讯 Spider / conformance 收口 **83/83**（见 WBS §2）
· ✅ 批次 Q：Windows 可行性门禁 / Android·Windows·macOS 三端 JSC / 引擎统一封装 + D6 降级链 / 双引擎体积·许可核销（见 WBS §16）
剩余 **批次 C–P（96 项）** 未启动；第 2 轮完成仍受 **D20/E.10b** 约束（待批次 C–P 与 **G-09/G-10 全量真机验收**，第 2 轮末）。

## A.2 第 0 阶段交付产物（15 文件）

| 类别 | 文件 | 状态 |
|------|------|------|
| SQLite DDL | `contract/schema/schema_v1.sql` | ✅ 9 表 + v1→v4 迁移链 |
| Prefs 契约 | `contract/schema/prefs_keys_v1.json` | ⚠️ 初版 53 键 → **第 1 轮修订为 98 键** |
| JSON Schema | `manifest_v1.json` / `site_v1.json` / `welfare_v1.json` | ✅ |
| Spider ABI | `contract/docs/abi_v1.md` | ✅ 引擎/操作/回调/错误全规范 |
| 备份格式 | `contract/docs/backup_v1.md` | ✅ AES-GCM + PBKDF2 字节级规范 |
| Android 兼容 | `contract/docs/android-compat.md` | ✅ minSdk 24 依据 |
| 检查模板 | `stage_check_template.yaml` / `bug_report_template.yaml` | ✅ |
| 阶段 0 报告 | `stage_check_report_stage0.yaml` | ✅ verdict: pass |
| 一致性样本 | `conformance/fixtures/`（3 类） | ✅ |

## A.3 iOS CI 构建状态

| 项 | 状态 |
|----|------|
| MPVKit 依赖资产缺失 | ✅ 已修复（资产迁入 vboxapp release `mpvkit-deps-0.0.1`，sha256 校验通过） |
| `scripts/*.sh` 缺执行位 | ✅ 已修复（100644 → 100755） |
| 最新构建 | ✅ run `36540984193` = success（IPA 链路跑通） |
| 版本自动 bump | ✅ 已到 `3.1614`（本地旧值曾回退为 3.1614，已加 `CI_MANAGED` 排除防复发） |
| **Flutter 校验通道** | ✅ `flutter-check.yml` 双 job 全绿：`analyze` 0 issues + **371 单测** + **11 脚本** + conformance 45/45（**历史快照**：v6.6 增覆盖率门槛步骤） |

## A.4 环境约束摘要

| 问题 | 影响 | 应对 |
|------|------|------|
| 本机**不安装** Flutter SDK（现行口径，v6.51 起） | 本机不执行 Dart 编译 / 静态分析 / 单测 / 构建 | Trae 沙箱按会话创建、工作区不跨会话保留，本地安装**无法留存**且诱导重复下载数 GB；Dart 侧一律由 **CI**（`flutter-check.yml`，Flutter 3.47.5）承担，本机仅跑纯 Python 守卫 + conformance runner |
| `github.com:443` 不可达 | `git push/fetch` 失败 | 推送走 `scripts/api_push.py`（API 通道，自动 diff，D2 归并后唯一脚本） |
| 本地 git 历史与远程不一致 | 无法直接比对 | 网络恢复后 `git fetch && git reset --hard origin/main` |

> ⚠️ Dart 代码由 `flutter-check.yml` 做**编译 + 静态 + 单测 + 覆盖率门槛**四重验证（analyze 0 issues / 371 用例 / 整体 71.1%）；
> **本机不安装 Flutter SDK，不跑任何 `flutter` 命令**（详见 P.7 现行口径）。
> 但**功能层（UI 三形态 / 平台插件 / Spider 引擎）尚未落地**，仍是当前最大风险。

---

# 附录 B：目录结构（方案 §2.4 落地快照）

> 本附录合并原 `PROJECT_LAYOUT.md`。

> **状态**：本文档已对齐 **D18**（目录结构基准 = 方案 §2.4 五层架构）
> **唯一真相源**：本文档 §2.4 —— 本附录为其落地快照
> **更新时间**：2026-09-29

`vboxapp` 仓库**同时容纳 iOS 现有代码与 Flutter 三端代码**（D14：唯一开发仓库）。

---

## 一、仓库顶层

```
vboxapp/
├── vbox/                       iOS 现有代码（Swift / SwiftUI，274 文件 / 189 .swift）
│                               └─ 契约来源；后续 iOS 改动亦在此进行（D16）
├── lib/                        Flutter 三端共享 Dart 代码
├── pubspec.yaml                Flutter 工程清单（依赖已对齐契约）
├── contract/                   契约层（唯一真相源，跨端共享）
├── conformance/                一致性样本与 runner
├── scripts/                    校验与运维脚本
├── docs/                       开发文档
├── quickjs/                   脚本运行时源码（Spider 引擎依赖）
├── go-proxy/                   iOS 侧 Go 代理
├── remote-source-repo-template/ 远程源仓库模板
├── android/ · macos/ · windows/ Flutter 平台壳（v6.11 交付，包名 `com.vbox.player`，D27）
└── vbox.xcodeproj/             iOS 工程
```

> ✅ `android/` / `macos/` / `windows/` 平台壳已于 **v6.11 交付**（`flutter create` 官方模板；`lib/platform/` 插件层仍未创建，见附录 C G-02）。

---

## 二、`lib/` 五层架构（方案 §2.4）

```
lib/
├── main.dart                        应用入口
├── app.dart                         根组件（依赖初始化 + Provider 注入 + 形态路由）
│
├── contract/                        ── 第 1 层：契约镜像（与 contract/ 一一对应）
│   ├── prefs_keys.dart              98 键 / 21 组 / 3 种存储方式
│   ├── schema/schema.dart            9 表 DDL + v1→v4 迁移链
│   └── abi/                          Spider ABI 镜像
│
├── core/                            ── 第 2 层：通用能力
│   ├── constants/  errors/  network/  storage/  utils/
│
├── data/                            ── 第 3 层：数据
│   ├── datasources/
│   │   ├── local/                   database_manager / prefs_manager / backup_manager
│   │   └── remote/                  HTTP 数据源
│   ├── models/                      9 张表模型 + 基类 + barrel
│   └── repositories/
│
├── domain/                          ── 第 4 层：领域
│   ├── entities/
│   │   ├── spider/                  引擎类型 / 站点配置 / 结果模型 / 引擎接口 / HTTP 桥
│   │   ├── remote_source/           远程源配置与同步
│   │   └── player/                  播放器抽象 + 后端降级链
│   ├── repositories/
│   └── usecases/
│
├── presentation/                    ── 第 5 层：表现
│   ├── ui_mode/                     ⭐ 形态判定（偏好 → 设备特征 → 编译期常量）
│   ├── providers/                  状态管理
│   ├── phone/  tv/  desktop/        三套形态布局
│   ├── shared/                      跨形态复用组件
│   └── theme/
│
└── platform/                        平台插件层（各端原生实现）
    ├── player/                      Android Media3+VLC / 桌面 libmpv / iOS AVPlayer
    ├── spider/                      QuickJS / Node / NodeLX / Python / JSC 运行时绑定
    ├── runtime/
    └── system/                      文件 / 权限 / 设备能力
```

---

## 三、当前落地状态（如实标注）

| 层级 | 目录 | 状态 |
|------|------|------|
| 入口 | `main.dart` `app.dart` | ✅ 已交付（未编译验证） |
| 契约层 | `contract/` | ✅ 已交付并校验 |
| 核心层 | `core/*` | ✅ 已交付（5 子目录 **21 文件**，见 P.12） |
| 数据层 | `data/{models,datasources/local}` | ✅ 已交付 |
| 数据层 | `data/datasources/remote` | ✅ 已交付（CMS V10 + 清单数据源，见 P.13） |
| 数据层 | `data/repositories` | ✅ 已交付（4 实现 + barrel，v6.7，见 P.19） |
| 领域层 | `domain/entities/*` | ✅ 已交付 |
| 领域层 | `domain/{repositories,usecases}` | ✅ 已交付（4 契约 + 4 用例组 + 3 实体，见 P.13） |
| 表现层 | `presentation/ui_mode` | ✅ 已交付 |
| 表现层 | `presentation/{phone,tv,desktop,providers,shared,theme}` | ⬜ 未创建（仅 `ui_mode` 已交付） |
| 平台层 | `platform/*` | ⬜ 未创建 |
| 平台壳 | `android/` `macos/` `windows/` | ✅ 已交付（v6.11，`flutter create` 官方模板，包名 `com.vbox.player`；CI 三端 build job v6.12 首跑全绿） |
| 测试 | `test/` | ✅ 29 文件 / **371 用例**（本机实测）；覆盖率触达 86.5%，全 lib 整体 **71.1%**（保守下界，达标），零触达 24/75（见 P.18 / P.19 / P.23） |

> `presentation/` 的子目录与 `platform/` 尚未创建（`git` 不跟踪无文件的目录，故远端亦不可见）；已交付部分以上表为准。

---

## 四、约束

1. **不改 iOS 运行逻辑**（D1）：`vbox/` 仅作契约来源与参照实现
2. **契约唯一真相源**：`contract/` 与 `lib/contract/` 必须逐位对齐，
   由 `scripts/check_contract_sync.py` 守护
3. **形态判定集中于** `presentation/ui_mode/`，不得散落各布局文件
4. **平台差异隔离在** `platform/`，业务层不得直接调用原生 API

---

# 附录 C：缺口登记表（Known Gaps）

> 本附录合并原 `KNOWN_GAPS.md`。按 E.10b ④「无 TODO 遗留（必须登记或清除）」要求，所有未完成项必须登记于此。

> **用途**：按方案 E.10b ④「无 TODO 遗留（必须登记或清除）」要求，
> 所有未完成项必须在此登记，不得以裸 TODO 形式散落代码中。
>
> **更新**：2026-09-29 · 对应 E.10b 门禁未通过项

---

## G-01 UI 三形态未实现 ⛔ 高（**v6.18 已解除**）

| 项 | 内容 |
|----|------|
| 代码位置 | `lib/app.dart`（形态路由按 `UiMode` 分发）+ `lib/presentation/{phone,desktop,tv}/` |
| 影响 | ~~三形态无实际界面~~（✅ 已解除） |
| 解除记录 | phone 书架 ✅（v6.15）→ phone 远程源 ✅（v6.16）→ desktop ✅（v6.17）→ **tv ✅（v6.18，T.7 焦点规范：FocusTraversalGroup + TabBar autofocus）** |
| 残余 | TV D-pad 真机行为归 **G-10**（人工验收）；详情 / 播放入口依赖 G-02/G-03 |
| 关联 | 方案 §2.4、T.7（TV 布局规范） |

## G-02 平台插件层部分解除（**G-02-A 已交付 v6.22，见 P.32**；G-02-B/C 待决策）⛔ 高

| 项 | 内容 |
|----|------|
| 位置 | `lib/platform/{player,spider,runtime,system}/`（**player 已创建 4 文件（G-02-A）**；spider 6 文件（G-03-A）；runtime/system **未创建**） |
| 平台壳 | ✅ **v6.11 已交付** `android/` / `macos/` / `windows/`（`flutter create` 官方模板，包名 `com.vbox.player`，CI 三端 build job，见 P.22 / D27） |
| 影响 | 播放器 Dart 控制层 + 通道桥已就绪（G-02-A）；libVLC 回退原生实现（G-02-B/C）、桌面 libmpv 分发、SystemPlugin / 前台服务未交付 |
| 阻塞原因 | ~~需 Android NDK + 桌面工具链~~ → **v6.20 已评估**：Android 播放器插件（Media3 + libVLC）为**纯 Gradle 依赖（零 NDK）**；macOS AVPlayer 零原生依赖；libmpv（macOS 回退 / Windows 主）受制于原生二进制分发 |
| 解除条件 | **G-02-A ✅**（`lib/platform/player/` 4 文件 + Android 接线 + 15 单测，v6.22 交付，见 **P.32**）；余 **G-02-B**（PlayerPlugin.swift AVPlayer + libmpv 分发决策）/ **G-02-C**（SystemPlugin / MediaPlaybackService / 真机验收）；含 SpiderPlugin / QuickJsRuntime / PythonRuntime（Chaquopy）/ NodeRuntime |
| 推荐路线 | **G-02-A**（✅ v6.22 交付）→ **G-02-B**（macOS AVPlayer + libmpv 分发决策）→ **G-02-C**（SystemPlugin / 前台服务 / 真机验收） |
| 关联 | 方案 §2.4、D6、D27、**P.30 评估登记**、**P.32 交付复核** |

## G-03 5 个 Spider 引擎实现部分解除（**G-03-A 已交付 v6.21**；G-03-B 待决策）⛔ 高

| 项 | 内容 |
|----|------|
| 现状 | 抽象层 ✅（`lib/domain/entities/spider/` 6 文件，98 单测）；**桥接协议层 ✅（G-03-A v6.21 交付）**：`lib/platform/spider/` 6 文件（ABI 编解码 / Node·NodeLX HTTP 桥 / Python 子进程桥 / 引擎工厂），Node/NodeLX/Python 三引擎已可走 ABI 调用（见 **P.31**） |
| 影响 | 所有 Spider 源不可用（Node/NodeLX/Python 桥已就绪，QuickJS/JSC 仍未实现） |
| 阻塞原因 | ~~需 QuickJS/Node/Python 运行时绑定~~ → **v6.19 已评估**：Node/NodeLX 桥 + Python 桥为**纯 Dart 可交付**（G-03-A）；QuickJS FFI 与运行时分发需先行决策（G-03-B） |
| 解除条件 | G-03-A ✅（桥接协议层 + conformance）；**G-03-B**（QuickJS FFI 绑定 + Node/Python 运行时分发方案）待决策；JSC 三端以 QuickJS 顶替（iOS 走原生） |
| 关联 | 契约 `abi_v1.md`、方案 E.7 / §4.5、**P.29 评估登记**、**P.31 交付复核** |

## G-04 conformance runner ✅ 已解决（2026-09-29）

| 项 | 内容 |
|----|------|
| 交付物 | `conformance/runner/run_conformance.py`（Python 参考实现） |
| 覆盖 | **45 项检查**：Spider ABI（20）· SQLite v4（6）· 备份格式（19） |
| 结果 | **45/45 通过**，退出码 0；结果落盘 `conformance/runner/results.json` |
| 有效性验证 | **否定测试**：注入 3 处故障（篡改容错期望值 / 删 `download.headers` 列 / 破坏表结构），runner 全部捕获并报 4 项失败 |
| 说明 | 三端（Dart/Kotlin/Swift）实现须产出与本 fixture 一致的输出；Python 版为参考实现 |

## G-04b runner 自身缺陷（已修复，记录存档）

首次运行报 3 项失败，经查**全部为 runner 自身 bug，fixture 与契约均正确**：

| # | 误报 | 真实原因 | 修复 |
|---|------|---------|------|
| 1 | `download` 字段不一致 | 契约用 `ALTER TABLE ADD COLUMN` 加 v4 列，解析器只读 `CREATE TABLE` | 补 ALTER 解析 |
| 2 | 「NOT NULL 计数为 0」断言失败 | 断言写反（变量名 `nullable` 却在收集可空列） | 改为「4 列须存在且可空」 |
| 3 | `UNIQUE(name,dyurl)` 未找到 | 内联 UNIQUE 生成**隐式索引**（`sqlite_master.sql` 为 NULL） | 改用 `PRAGMA index_list` + `index_info` |

> **教训**：查索引结构不能依赖 `sqlite_master.sql`（内联约束无 DDL 文本）；
> 契约 DDL 可能分散在 `CREATE TABLE` 与 `ALTER TABLE` 两处，须合并解析。

## G-05 单元测试（⚠️ 中，已部分解除）

| 项 | 内容 |
|----|------|
| 现状 | ✅ 29 文件 **371 用例全部通过**（本机 Flutter 3.47.5 独立复现）；覆盖率**已测量**（触达口径 86.5%，全 lib 整体 71.1%） |
| 影响 | E.10b ⑤「单测覆盖率 ≥ 70%」**达标**（整体口径 71.1%，零触达仍有 24/75，见 P.18 / P.19 / P.23） |
| 阻塞原因 | ~~需 `flutter test`~~ → 通道已通（G-07 解除） |
| 解除条件 | 功能层（Spider 实体层等零触达文件）补测，**整体**覆盖率 ≥ 70% |

## G-06 iOS 参照实现完整性

| 项 | 内容 |
|----|------|
| 现状 | ✅ `vbox/` 目录 **274 文件**（189 .swift）完好，未被破坏 |
| 说明 | 零改造原则（D1）已遵守 |

## G-07 Flutter SDK 无法在本机运行 ✅ 已解决（2026-09-29）

| 项 | 内容 |
|----|------|
| 现象 | `Exec format error` |
| 原因 | Flutter 官方 Linux 发行版**仅 x86-64**；本机为 **aarch64**（iSH/Alpine） |
| 处置 | ✅ 采用出路①：新增 `.github/workflows/flutter-check.yml`（macos-15 runner，Flutter 3.47.5） |
| 结果 | 编译 / 静态 / 单测三重验证闭环成立（见 P.12），G-08 同步解除、G-05 解锁 |

## G-08 静态分析 ✅ 已解决（2026-09-29）

| 项 | 内容 |
|----|------|
| 现状 | ✅ `flutter analyze` 随 CI 每次推送执行，当前 **0 issues** |
| 首跑价值 | 抓到 28 errors + 8 warnings（全部修复，见 P.12 §5） |
| 影响 | E.10b ⑤「静态分析无 error」现已可验证 |

## G-09 侧载链路未验证

| 项 | 内容 |
|----|------|
| 现状 | 未验证 |
| 原因 | 需真机（人测职责，D8） |
| 关联 | 方案 §S（侧载分发）、D11 |

## G-10 TV 焦点与遥控未验证

| 项 | 内容 |
|----|------|
| 现状 | 未验证（TV UI 未实现，见 G-01） |
| 原因 | 需真机 + TV 模拟器 |
| 关联 | 方案 T.4（TV 焦点系统） |

---

## 汇总

| 类别 | 数量 | 编号 |
|------|------|------|
| ✅ 已解决 | 3 | G-04（conformance runner）, G-07（编译环境）, G-08（静态分析） |
| 部分解除 | 1 | G-05（371 用例已过，本机复现；覆盖率已测量，全 lib 整体 71.1% 达标） |
| 功能未实现 | 4 | G-01, G-02, G-03, G-09 |
| 需真机验证 | 2 | G-09, G-10 |
| 已满足 | 1 | G-06 |

> 注：G-09 同时属「功能未实现」与「需真机验证」，故分类计数有重叠。

**E.10b 门禁状态**：❌ 未通过（不达标项 **12 → 9**，见方案文档 P.8）

---

**文档结束**
