# 评估：Windows 自建/集成 JavaScriptCore 可行性（Q-01 · 门禁）

> **任务**：WBS v1.2 §16 Q-01（批次 Q 门禁）——Windows 平台 JSC 的可用构建方案 + 体积/许可结论；**不通过 → 触发 D6 降级预案（Windows 改用 QuickJS，回老板确认）**。
> **结论先行**：✅ **可行（通过）· Q-03 已落地交付**。Q-01 原推荐 **方案 A（WinCairo 官方端口自建）**；实施前核查发现 **Apple WinCairo buildbot 已于 2024-09 停更**（最后 Windows 包即当时版本），故 Q-03 改用 **Playwright WebKit Win64 持续构建预编译 DLL**（当前唯一在维护的 Windows JSC 二进制来源）：`JavaScriptCore.dll`（~32 MB，导出完整 JSC C API）+ ICU + MSVC 运行时，仅用 MSVC 编译自有 `vbox_jsc.dll` wrapper。**不触发降级预案**，QuickJS 保留为运行时降级兜底（B-05 映射不变）。
> **日期**：2026-10-01 · **评估人**：开发（第 2 轮批次 B 并行）

---

## 1. 背景（为什么是门禁）

D6（主方案登记号 **D31**）已定：三端（Android / Windows / macOS）均集成 **JavaScriptCore 为 JS 站点脚本主引擎、QuickJS 为降级备份**。其中：

- **macOS**：系统自带 `JavaScriptCore.framework`，零构建成本（Q-04）；
- **Android**：JSC 预编译 `.so` 是 React Native 生态的成熟产物（四 ABI），风险低（Q-02）；
- **Windows**：Apple 已于 2012 年停止 Safari for Windows，**无官方二进制**，须自建或借第三方产物——**唯一硬骨头，故设门禁**。

## 2. 候选方案盘点

| 方案 | 路径 | 产物 | 体积（x64） | 维护方 | 可行性 |
|------|------|------|------------|--------|--------|
| **P · Playwright WebKit JSC（Q-03 实际采用）** | Playwright WebKit win64.zip 预编译 DLL + MSVC 编译自有 wrapper | `vbox_jsc.dll`（wrapper，仅导出 `vj_*` 六符号）+ `JavaScriptCore.dll` + ICU + MSVC 运行时 | `JavaScriptCore.dll` ~32 MB（+`icu*77.dll`） | Playwright（微软持续重建） | ✅ **已落地**（2026-10-02） |
| ~~A · WinCairo 官方端口自建~~（Q-01 原推荐） | WebKit `--jsc-only` + MSVC/CMake + WinCairoRequirements 预编译依赖 | `vbox_jsc.dll`（含 C API 导出） | ~10–18 MB | 我们（锁定 WebKit tag） | ❌ buildbot 已停（最后 Windows 包 2024-09），实施受阻改方案 P |
| **B · NativeScript 预编译 DLL** | `@nativescript/windows-jsc`（npm，Apache-2.0 封装，自带 JSC 运行时 DLL） | 提取其 `JavaScriptCore.dll` | ~10–15 MB | NativeScript 社区 | ⚠️ 未采用（版本跟进受制第三方） |
| **C · MSYS2 WebKitGTK** | `javascriptcoregtk` mingw 包 | GTK 绑定式 JSC DLL + GTK 运行时 | ~25 MB+（带 GTK 依赖） | MSYS2 | ⚠️ 与 GTK 耦合过重，弃 |
| **D · 降级预案（不采用）** | Windows 仅用 QuickJS（`libvbox_quickjs` 已有 MSVC 编译管线） | 已有 | ~1 MB | 我们 | 保留为 **B-05 运行时兜底**，不作主引擎 |

**关键佐证（方案 P 实际采用）**：Apple 官方 WinCairo buildbot 已停（最后 Windows 包 2024-09），WebKit 当前唯一在维护的 Windows JSC 二进制来源是 **Playwright 的 WebKit Win64 持续构建**（`webkit-win64.zip` 内含 `JavaScriptCore.dll`，导出完整 JSC C API，稳定 C API 语义同 iOS / macOS `JavaScriptCore.framework`）。Q-03 用该预编译 DLL 作运行时，仅用 MSVC 编译自有 `vbox_jsc.dll` wrapper（`windows/runner/jsc/JavaScriptCore.def` 重建导入库，无需从源码编 WebKit）；版本跟进受 Playwright 构建节奏约束（锁定 revision，`scripts/fetch-jsc-windows.ps1` 幂等拉取）。

## 3. 评估维度逐项结论

### 3.1 构建可行性 ✅

- 改走 **Playwright 预编译运行时**（无需从源码编 WebKit）：Q-03 仅用 MSVC 编译自有 `vbox_jsc.dll` wrapper——`windows/runner/jsc/JavaScriptCore.def` 重建 `JavaScriptCore.lib` 导入库（lib.exe），`cl.exe` 编译 `jsc/wrapper.c` 导出 `vj_*` 六符号（`vj_create_runtime` / `vj_create_context` / `vj_free_runtime` / `vj_free_context` / `vj_eval` / `vj_free_string`）。64 位限定与产品目标一致（Windows 桌面端均为 x64）。
- 现有 `quickjs/wrapper.c` 已验证「纯 C wrapper + `dart:ffi` 动态加载」三端管线（`libvbox_quickjs`）；JSC 侧复制同一模式：`vj_*` 六符号与 `vq_*` 同 ABI 形状，Dart 侧 `jsc_ffi.dart` 镜像 `QuickJsNativeBridge` 抽象——**三端同一 ABI**（Q-05 验收口径）。
- 构建复杂度远低于自建 WebKit：`fetch-jsc-windows.ps1`（幂等拉取 Playwright DLL）→ `build-jsc-windows.ps1`（MSVC 编译 + `vj_*` 符号/语义冒烟）→ `bundle-jsc-windows.ps1`（拷入 runner 目录随包分发）；CI 由 `build-jsc.yml` `build-windows` job 固化。

### 3.2 体积 ✅（可接受，Q-03 实测校准）

| 项 | 值 | 说明 |
|----|----|------|
| `JavaScriptCore.dll`（Playwright WebKit x64） | **~32 MB**（契约区间 25–45 MB） | Q-03 实际采用；NSIS/LZMA 压缩后安装包增量约 10–12 MB |
| ICU 运行时 + 数据（`icuin*`/`icuuc*`/`icudt*`） | 随包分发 | `JavaScriptCore.dll` 的运行时依赖（`icu*77.dll`） |
| MSVC 运行时（`msvcp*`/`vcruntime*`） | 随包分发 | Playwright 产物编译链依赖，随包分发 |
| 仅 x64 | 无 arm64 产物 | Playwright WebKit 仅 x64；Windows arm64 设备占比可忽略，走 QuickJS 兜底 |
| 对照：`vbox_quickjs.dll` | ~1 MB | 已随包分发（降级备份），不因此移除 |

> **口径修正（Q-03）**：Q-01 评估时按自建 MinSizeRel 预估 ~10–18 MB；实施改用 Playwright 预编译运行时后，`JavaScriptCore.dll` 单文件 ~32 MB，另加 ICU + MSVC 运行时。桌面安装包总量级（数十 MB 级）下仍可接受。体积契约已登记 `scripts/check_engine_bundle.py`（jsc-windows：25–45 MB 区间）+ `scripts/engine_bundle_registry.json`。

### 3.3 许可 ✅（合规路径明确）

- JavaScriptCore 源码：**LGPL-2.1 + BSD-2-Clause**（WebKit 双许可）。
- 合规要点：**动态链接（`JavaScriptCore.dll` 独立随安装包分发；`vbox_jsc.dll` 为自有 wrapper）** + 关于页（P-05）提供 WebKit 源码获取链接 + 保留版权声明。**无需开源宿主 App**。
- 对照：QuickJS 为 MIT（更宽松），方案 D 在许可上无优势差异。
- Playwright WebKit JSC-only 运行时与 NativeScript 方案 B 的封装（Apache-2.0）同源——其 DLL 本身仍是 **LGPL-2.1 + BSD-2-Clause** 产物，动态链接分发合规口径同上。

### 3.4 行为一致性 ✅

- Windows JSC（Playwright WebKit 预编译）与 macOS 系统 JSC 同源（同为 WebKit JavaScriptCore），`conformance` 双引擎双跑（B-12 / Q-06）交叉验证语义一致性。
- 与 QuickJS 的行为差集已由 **B-05a `SpiderJsGlobals` prelude**（console/print/atob/btoa/req/options）抹平——6 项能力「与引擎无关」，JSC 注入同一 prelude（Q-05 接入 `JSCBridgeEngine` 时复用）。

## 4. 对后续任务的直接影响

| 任务 | 结论 |
|------|------|
| **Q-02（Android JSC）** | 门禁通过，可启动（与 Q-03/Q-04 并行） |
| **Q-03（Windows JSC 集成）** | ✅ **已交付**：按方案 P（Playwright 预编译 DLL）落地——`windows/runner/jsc/JavaScriptCore.def` + `scripts/{fetch,build,bundle}-jsc-windows.ps1` + `windows/runner/main.cpp` `LoadLibraryW` 预加载，`vbox_jsc.dll` + 运行时 DLL 随 runner 打包 |
| **Q-04（macOS JSC）** | 不受影响（系统框架零构建） |
| **Q-05（JSC 引擎封装）** | `jsc_bridge_engine.dart` 复用 `QuickJsNativeBridge` 式抽象 + `SpiderJsGlobals` prelude 注入；降级开关与可观测保留 |
| **B-05（引擎映射定稿）** | **不触发降级预案**：JSC 主 / QuickJS 降级维持 D6 原案；Windows arm64（如有）自动落 QuickJS |
| **Q-06（体积/许可核销）** | 依本评估 §3.2/§3.3 登记：jsc-windows `JavaScriptCore.dll` 25–45 MB 区间（实测 ~32 MB，x64）· LGPL-2.1 动态链接合规 |

## 5. 风险与缓解

| # | 风险 | 缓解 |
|---|------|------|
| 1 | Playwright WebKit 构建产物非官方发布渠道（社区持续构建，version/revision 不可控） | 锁定 revision（`scripts/fetch-jsc-windows.ps1` 幂等拉取）；wrapper + 运行时 DLL 经 CI 缓存，不追 latest |
| 2 | 仅 64 位 | Windows x64 覆盖主流桌面；arm64 运行时自动降级 QuickJS（B-05 映射已含降级可观测） |
| 3 | JSC 运行时 DLL ~32 MB + ICU + MSVC | 安装包 LZMA 压缩（`JavaScriptCore.dll` 增量 ~10 MB）；桌面端可接受；体积契约 25–45 MB 越界告警（Q-06） |
| 4 | LGPL 合规遗漏 | 关于页（P-05）加 WebKit 源码链接；Q-06 已出正式核销结论 |
| 5 | 双引擎行为差异 | B-12 conformance 双跑 + B-05a prelude 已抹平能力差集 |

## 6. 参考资料

- **Playwright WebKit Win64 持续构建产物（Q-03 实际来源）**：<https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/webkit/>（`webkit-win64.zip` 内含 `JavaScriptCore.dll` + ICU）
- WebKit 官方 Windows port 文档（方案 A 背景，buildbot 已停）：<https://docs.webkit.org/Ports/WindowsPort.html>（MSVC / 仅 64 位 / cairo+curl）
- WebKit Building on Windows（方案 A 的 JSC 工程与构建入口）：<https://trac.webkit.org/wiki/BuildingOnWindows>
- NativeScript Windows JSC 预编译运行时（方案 B 佐证）：<https://www.npmjs.com/package/@nativescript/windows-jsc>
- WebKitGTK JSC built products（JSC-only 独立构建产物先例）：<https://webkitgtk.org/jsc-built-products/x86_64/release/>
