# 桌面端内置 CPython 落地方案 v1.0

> 目标：让 **Windows / macOS 桌面端的 `.py`（Python 蜘蛛）源可用**，且**严格对齐 iOS 端**的语义与行为。
> 范围：Flutter 桌面端（Windows / macOS）；不改 iOS / Android 现有实现（仅做「抽取共用」级别的对齐）。
> 本方案取代 D29「桌面探测系统 python3」的旧口径（[VBOX_PLAN_v6.51.md §5116](file:///workspace/vboxapp/docs/VBOX_PLAN_v6.51.md#L5116)）。

---

## 0. 结论摘要（TL;DR）

桌面端 py 源「暂无数据」**不是单一原因，而是三层缺口叠加**。只做「内置解释器」无法修复，必须三件一起做：

| 缺口 | 现象 | 对齐 iOS 的动作 | 优先级 |
|---|---|---|---|
| **G1 无解释器** | 桌面不携带 Python，探测系统 `python3`，缺失即不可用 | 随包内置 CPython **3.14.x** | P0 |
| **G2 无对象调用桥**（最致命） | 桌面走 **stdio ABI v1**，把**原始 Spider 类脚本**当 ABI 脚本跑 → 永远等不到 `READY` | 移植 iOS `PythonBridge.m` 的**对象调用**模型（复用 Android 已落地的 `vbox_python_bridge.py`） | **P0（决定性）** |
| **G3 无依赖随包** | 无 `base.spider`、无 `lxml`/requests 栈 | 内置 `python-stdlib/base` + 依赖（`lxml` 官方 wheel） | P1 |

> **关键认知**：即便用户手动装了 Python，桌面端 py 源**仍然会失败** —— 因为 G2。这是本方案与「方案 B（只补探测+缓存）」的本质区别。

---

## 1. 现状与差距分析（以 iOS 为基准）

### 1.1 三端 Python 运行时对照

| 维度 | iOS（基准 ✅） | Android（已对齐 ✅） | Windows / macOS（本方案要修 ❌） |
|---|---|---|---|
| 解释器 | 内置 **CPython 3.14.7**（`Python.framework` arm64，beeware/Python-Apple-support） | 内置 Chaquopy CPython 3.11（随 APK） | **无**，探测系统 `python3`/`python`/`py -3` |
| 调用模型 | **对象调用**（`PythonBridge.m` `callSpider:`） | **对象调用**（`vbox_python_bridge.py` v2） | **stdio ABI v1**（`python3 -u <script>`） |
| Spider 基类 | 内置 `Resources/python-stdlib/base/spider.py` | 内置（Chaquopy `src/main/python`） | **无** |
| 第三方依赖 | `lxml 5.4.0`（+libxml2 2.13.5/libxslt 1.1.42，**静态编译**） | requests 栈 + pyaes/Crypto（**无 lxml**） | **无** |
| 体积 | ~35 MB | （随 APK） | 0 |

来源：`pack_python_artifacts.sh`（3.14.7）、`build_lxml_ios.sh`（lxml 5.4.0）、`vbox_python_bridge.py` 头注释、[python_runtime.dart](file:///workspace/vboxapp/lib/platform/spider/python_runtime.dart#L31-L84)。

### 1.2 桌面端三个致命缺口（逐条定位）

**G1 — 无内置解释器**
[PythonRuntime.forCurrentPlatform](file:///workspace/vboxapp/lib/platform/spider/python_runtime.dart#L64-L84) 中，非 Android 一律走 [StdioPythonRuntime](file:///workspace/vboxapp/lib/platform/spider/python_runtime.dart#L103-L169)；Windows 仅做 [`_probeWindowsPythonCommand`](file:///workspace/vboxapp/lib/platform/spider/python_runtime.dart#L31-L57) 的 **PATH 名探测**（`python3 → python → py -3`），**没有 `<exeDir>/...` 随包探测档**，也没有 `probed` 候选清单。`windows/`、`macos/` 工程 grep `python` **零命中**；发布流程只打包 Node/JSC/QuickJS/libmpv，**无 Python 步骤**。

**G2 — 无对象调用桥（决定性）**
[_prepareEngine](file:///workspace/vboxapp/lib/domain/usecases/content_browse_usecases.dart#L666-L673) 把**原始脚本**直接交给 `engine.loadScript(...)`，桌面端**没有任何桥接包装**。[StdioPythonRuntime.launch](file:///workspace/vboxapp/lib/platform/spider/python_runtime.dart#L132-L169) 将其写到临时 `.py` 后 `python3 -u <tmp.py>`，等待脚本自行 `print('READY')`。
而真实 TVBox py 源（真不错4K 等）是**标准 `Spider` 类定义脚本，没有 ABI 循环** → 宿主永远等不到 `READY` → 超时 → 「暂无数据」。
> 这正是 [vbox_python_bridge.py](file:///workspace/vboxapp/android/app/src/main/python/vbox_python_bridge.py) 头注释记载的历史：v1 stdio ABI 因真实源不兼容而被 v2 对象调用取代；**该修复只落在 Android，桌面端至今停在 v1**。

**G3 — 无依赖随包**
桌面端既无 `base/spider.py`（真实源普遍 `from base.spider import Spider`），也无 requests 栈 / lxml。即便 G1/G2 修好，脚本也会 `ImportError`。

### 1.3 对齐基准（锁定版本）

| 项 | iOS 基准值 | 桌面取值 |
|---|---|---|
| CPython | 3.14.7 | **3.14.x（尽量 3.14.7）** |
| lxml | 5.4.0 | 5.4.0（官方 wheel） |
| base.spider | `Resources/python-stdlib/base/spider.py` | **同一份文件**（平台无关） |
| 调用模型 | 对象调用 | 对象调用（复用 Android 桥） |

> 注：Android 是 3.11，iOS/桌面为 3.14 —— 跨端 ABI 不一致由 **Spider ABI（JSON 行）屏蔽**，脚本层不感知（与既有设计一致）。

---

## 2. 方案总览

```
┌─────────────────────────── Flutter 域层（跨端共用，不改语义）───────────────────────────┐
│  content_browse / detail_playback  →  PythonBridgeEngine  →  PythonRuntime              │
│                                                              │ forCurrentPlatform        │
│                        ┌─────────────────────────────────────┴───────────────────────┐   │
│                        │ Android: ChannelPythonRuntime(进程内 Chaquopy)   ← 已对齐 iOS │   │
│                        │ 桌面:    StdioPythonRuntime(子进程)  ← 本方案改造              │   │
│                        └───────────────────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────────────────────────────────────────┘
桌面 StdioPythonRuntime 改造后：
  <内置 python3>  -u  <bridge_shim.py>  <用户脚本路径>
         │                  │
         │                  └─ 复用 Android vbox_python_bridge.run(script, io)  ← 对象调用，对齐 iOS
         │
         └─ <exeDir>/pyruntime/  (随包内置 CPython 3.14.x + lxml)
             + PYTHONPATH → assets/python-stdlib  (base/ + requests 栈)   ← 对齐 iOS Resources/python-stdlib
```

**四件改动**：① 随包内置解释器；② 桌面桥接层对齐（对象调用）；③ 依赖随包；④ 探测链镜像 Node 的「内置优先→系统回退」。

---

## 3. 详细设计

### 3.1 运行时发行源与版本

| 平台 | 发行源（推荐） | 说明 |
|---|---|---|
| Windows | **python-build-standalone**（astral-sh）x86_64 | 可重定位、自带 pip、目录自包含；**优于** python.org embeddable（后者无 pip、`._pth` 配置别扭） |
| macOS | **python-build-standalone** universal2（或 arm64+x86_64 双架构） | 可重定位、可直接 ad-hoc 签名；版本族与 iOS 一致 |

- 版本锚定 **3.14.x**（对齐 iOS 3.14.7；以 python-build-standalone 可用的最接近补丁版为准）。
- 采用**预编译二进制**，无需桌面端自编译（区别于 iOS 的 lxml 自编译）——**lxml 用官方 wheel**，对齐方案 §4.3 口径。
- 可选：对发行包做**裁剪**（移除 `tkinter`/`idlelib`/`test`/`ensurepip`/`__pycache__`/`*.pdb`），减小体积。

### 3.2 目录布局

| 用途 | Windows | macOS | 读写 |
|---|---|---|---|
| 内置解释器 | `<exeDir>/pyruntime/`（`python.exe` + `Lib/` + `DLLs/`） | `<App>/Contents/Resources/pyruntime/`（`bin/python3` + `lib/`） | 只读，随包 |
| 依赖（纯 py） | 随 `assets/python-stdlib/`，运行时经 `PYTHONPATH` 注入 | 同左 | 只读，随包 |
| 原生 lxml | 内置到 `pyruntime/.../site-packages/` | 同左 | 只读，随包 |
| 桥接脚本 | 随 `assets/pythonbridge/` | 同左 | 只读，随包 |

> 与 Node 的「两套 noderuntime」语义一致：**只读随包**放二进制（Node 用 `<exeDir>/noderuntime`，Python 用 `<exeDir>/pyruntime`）；脚本/依赖以 `assets/` 分发。目录名与 Node 区分，避免混淆。

### 3.3 探测链改造（镜像 [ProcessNodeHost.locate](file:///workspace/vboxapp/lib/platform/node/node_host.dart#L148-L163)）

新增 `PythonExecutableLocation { resolved, probed }` 与 `locatePython()`，**逐字照搬 Node 四段式**：

1. **随包候选**（新增档，当前完全没有）
   - Windows：`<exeDir>/pyruntime/python.exe`
   - macOS：`<App>/Contents/Resources/pyruntime/bin/python3`（**必须放 Resources 数据区**：
     codesign 视 `Contents/MacOS` 下整棵子树为代码，`python-stdlib/**/*.py` 会被判为
     「未签名的嵌套代码」而令 App 重签失败；Node 仅单个 Mach-O 故放 MacOS 无碍）
2. **平台安装位置**（补全现有 PATH 名探测）
   - Windows：`%LOCALAPPDATA%\Programs\Python\Python314\python.exe`、`%ProgramFiles%\Python314\python.exe`、`py -3`
   - macOS：`/opt/homebrew/bin/python3`、`/usr/local/bin/python3`、`/usr/bin/python3`
3. **PATH 兜底**（沿用现有 `_fromPath` 思路）
4. **裸名兜底** `python3`

改造点：[PythonRuntime.forCurrentPlatform](file:///workspace/vboxapp/lib/platform/spider/python_runtime.dart#L64-L84) 先调 `locatePython()`，命中随包/系统绝对路径则注入 `StdioPythonRuntime(pythonExecutable: resolved)`；`extraArgs` 保留 `py -3` 场景。`probed` 清单用于**可读失败文案**（对齐 Node 的 [`_failureMessage`](file:///workspace/vboxapp/lib/platform/node/node_host.dart#L237-L256)），替换现有「Python 桥启动超时」这类底层提示。

### 3.4 桥接层对齐（决定性，对齐 iOS 对象调用）

**目标**：桌面不再直接跑原始脚本，而是**运行桥接层**，由桥接层 `exec` 用户脚本、以**对象调用**提供 `categoryContent/homeContent/searchContent/...`，与 iOS `PythonBridge.m`、Android `vbox_python_bridge.py` 语义一致。

**做法（推荐）**：
1. 将 Android 的 [vbox_python_bridge.py](file:///workspace/vboxapp/android/app/src/main/python/vbox_python_bridge.py) 的**核心 `run(script, io)` 抽取为平台无关模块**（它就是纯 Python，天然可复用）。
2. 新增桌面 `__main__` 垫片 `vbox_python_bridge_desktop.py`：把 `sys.stdin/stdout` 适配成 `io`（`emit`/读请求），从 `argv[1]` 读用户脚本内容，调用 `run(script, io)`。
3. 改造 [StdioPythonRuntime.launch](file:///workspace/vboxapp/lib/platform/spider/python_runtime.dart#L132-L169)：写用户脚本到临时文件 → `Process.start(python, [...extraArgs, '-u', <bridge_shim>, <scriptPath>])`。
4. **Dart 侧 ABI 边界不变**（仍是 JSON 行 over stdin/stdout），故 [PythonBridgeEngine](file:///workspace/vboxapp/lib/platform/spider/python_bridge_engine.dart) 与域层**零改动**。

**备选（不推荐）**：把桥接代码**拼接**进临时 `.py`。改动更小，但污染脚本、难维护，且不利于三端共用。

> 收益：桌面与 Android 共用**同一份桥接源码** → 三端对象调用语义真正统一；也顺带修掉「ext 顶替主脚本」等 ABI 级隐患。

### 3.5 依赖清单（对齐 iOS）

| 类别 | 内容 | 分发方式 |
|---|---|---|
| Spider 基类 | `python-stdlib/base/spider.py`（+`__init__.py`） | `assets/python-stdlib/` → `PYTHONPATH` |
| HTTP 栈 | `requests`、`urllib3`、`idna`、`certifi`、`charset_normalizer` | 同上（纯 py，复用 Android 已 vendor 集合） |
| 加密 | `Crypto`（pycryptodome）/ `pyaes` | 同上 |
| XML/HTML | **`lxml 5.4.0`**（官方 wheel，win/mac 均免编译） | 内置到解释器 `site-packages` |

> **待决**：iOS 带 lxml、Android 不带。既然「对齐 iOS」，**默认带 lxml**；最终依赖集合以 Android 真机日志（脚本 traceback 点名的 import）为准做增删。

### 3.6 打包脚本（镜像 `bundle-node-*.ps1/.sh`）

| 新增脚本 | 落点 | 职责 |
|---|---|---|
| `scripts/bundle-python-windows.ps1` | `build/windows/x64/runner/Release/pyruntime/` | 下载 pbs → 解压 → pip 装 lxml → 拷 `assets/python-stdlib`、`assets/pythonbridge` → 裁剪 |
| `scripts/bundle-python-macos.sh` | `<App>/Contents/Resources/pyruntime/` | 同上（universal2） |

参照 [bundle-node-windows.ps1](file:///workspace/vboxapp/scripts/bundle-node-windows.ps1#L52-L64)、[bundle-node-macos.sh](file:///workspace/vboxapp/scripts/bundle-node-macos.sh#L70-L77)。

### 3.7 CI 集成（[build-release-assets.yml](file:///workspace/vboxapp/.github/workflows/build-release-assets.yml)）

- Windows：在 Node 步骤（[L206](file:///workspace/vboxapp/.github/workflows/build-release-assets.yml#L206-L211)）附近新增 `bundle-python-windows.ps1` 调用；
- macOS：在 Node 步骤（[L342](file:///workspace/vboxapp/.github/workflows/build-release-assets.yml#L342-L345)）附近新增 `bundle-python-macos.sh`；
- **必须在统一 re-sign 之前**（与 Node/QuickJS 同约束）。

### 3.8 签名 / 公证 / 安装器

- **macOS**：现有 re-sign 只签 `Contents/Frameworks/*.dylib` + App 本体（[L353-L359](file:///workspace/vboxapp/.github/workflows/build-release-assets.yml#L353-L359)）。`Contents/Resources/pyruntime/**` 内含大量 Mach-O（`python3`、`*.dylib`、`*.so`），**需在 App 本体签名前递归 ad-hoc 签名**（否则嵌套二进制未签，可能被系统拦截）。运行时**必须落在 `Contents/Resources`**：codesign 视 `Contents/MacOS` 下整棵子树为代码，纯 py 的 `python-stdlib/**/*.py` 会被判为「未签名的嵌套代码」而令 App 重签失败（`code object is not signed at all / In subcomponent: ...python-stdlib/.../__init__.py`）；Resources 为数据区，仅按哈希封存，不含此约束。仍维持「未公证（S.6 侧载）」现状。
- **Windows**：`installer.iss` 已递归打包 `Release\*`（`noderuntime` 即由此携带），**`pyruntime/` 会自动包含**；但升级安装需把 `python.exe` 加入「安装前 kill 列表」（与 `node.exe` 同处理），避免子进程占用导致覆盖失败。
- **体积**：预计 **+35~45 MB / 平台**（解释器 20~30 MB + lxml 10~15 MB，裁剪后）。

### 3.9 运行期环境变量（对齐 Android/避免污染）

- `PYTHONPATH=<assets/python-stdlib>`（注入 base + 纯 py 依赖）
- `PYTHONNOUSERSITE=1`（不读用户 site-packages）
- `PYTHONDONTWRITEBYTECODE=1`（只读目录不写 pyc）

---

## 4. 分步实施计划（WBS）

| 步 | 内容 | 产出 | 依赖 |
|---|---|---|---|
| **S1** | 抽取平台无关桥接模块 + 桌面垫片 | `assets/pythonbridge/*.py` | 复用 Android 桥 |
| **S2** | 新增 `PythonExecutableLocation` + `locatePython()`；改造 `forCurrentPlatform` | python_runtime.dart | 对齐 Node |
| **S3** | 改造 `StdioPythonRuntime.launch` 跑桥接层 + 注入环境变量 | python_runtime.dart | S1/S2 |
| **S4** | 新增两个打包脚本 + 裁剪逻辑 | bundle-python-*.* | — |
| **S5** | CI 接入（win/mac，re-sign 之前） | build-release-assets.yml | S4 |
| **S6** | macOS 递归签名 + Windows kill 列表 | workflow / installer.iss | S5 |
| **S7** | 桌面一致性测试（真实 Spider 类脚本 → 分类/首页有数据） | test/ + 冒烟 | S3/S5 |

---

## 5. 验收标准

1. **无系统 Python** 的干净 Windows/macOS 上，py 源（如「真不错4K[py]」）能出**分类胶囊 + 列表数据**；
2. 日志显示 `引擎已就绪：python`、解释器路径指向 **`<exeDir>/pyruntime/...`**（而非系统 python）；
3. 卸载/未装系统 Python 不报「缺少订阅源基址 / 启动超时」；
4. iOS / Android 行为**无回归**；
5. 安装包体积增量在预期区间（±45 MB）。

---

## 6. 风险与待决

| # | 风险 / 待决 | 影响 | 处置 |
|---|---|---|---|
| R1 | 桥接层对齐改动触及运行核心路径 | 可能影响现有桌面 py 一致性测试 | S1~S3 与一致性测试同 PR 交付 |
| R2 | python-build-standalone 是否有 3.14.7 精确补丁版 | 版本与 iOS 差一个补丁号 | 取最接近版本；ABI 由 Spider ABI 屏蔽 |
| R3 | macOS 递归签名遗漏嵌套 Mach-O | 签名校验失败/启动被拦 | S6 专门校验 `codesign --verify --deep` |
| R4 | lxml 依赖集合是否与真实源一致 | 个别源 `ImportError` | **以 Android 真机日志 traceback 为准**再定稿依赖 |
| R5 | 裁剪过度移除必需 stdlib 模块 | 运行期 `ImportError` | 保留完整 `Lib`，仅删 tkinter/test/idlelib 等明显无关项 |
| R6 | 与 D29 决策冲突 | 文档口径不一 | 本方案显式取代 D29 桌面口径，回写 PLAN |

---

## 7. 影响面 / 回归清单

- **不改**：域层 usecase 语义、`PythonBridgeEngine`、Dart↔桥 ABI、iOS/Android 现有实现。
- **改**：`python_runtime.dart`（探测链 + launch）、新增 `assets/pythonbridge`、新增 `assets/python-stdlib`（若未内置）、两个打包脚本、CI workflow、`installer.iss`。
- **回归重点**：Android py 源、桌面 Node/JS 源（不应受影响）、桌面一致性测试全套。

---

## 8. 与既有「方案 B」的关系

| | 方案 B（已实施：缓存 + `.py` 解析 + 日志） | 本方案（真·内置，对齐 iOS） |
|---|---|---|
| 解决 | 缓存/解析/可观测性 | 解释器 + 对象调用桥 + 依赖 |
| 桌面 py 源能否跑通 | **不能**（G1/G2/G3 未解） | **能** |
| 体积 | 0 | +35~45 MB/平台 |
| 依赖真机日志 | 是（先拿到 traceback） | 是（定稿依赖集合） |

> 两者互补：B 先上线拿证据，本方案据证据定稿依赖并根治。
