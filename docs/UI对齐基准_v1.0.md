# vbox · UI 对齐基准（iOS → Flutter 三端）

> **版本**：v1.0（首版）· 2026-10-01
> **定位**：**表现层（UI）对齐基准**，与数据层契约 `contract/` 平行存在、互不覆盖。
> **不变式**：本文件**不修改**任何既有决策 —— D1（契约共享）/ D5（三端形态）/ D20（第 1 轮门禁）全部保持原样；仅**新增**表现层基准，**第 2 轮（功能补全）起按批次落地**。
> **关联**：主方案 [VBOX_PLAN_v6.47.md](computer:///workspace/vboxapp/docs/VBOX_PLAN_v6.47.md) · [第1轮核心骨架全面检查报告_v6.32.md](computer:///workspace/vboxapp/docs/第1轮核心骨架全面检查报告_v6.32.md) · [真机验收清单_G09_G10.md](computer:///workspace/vboxapp/docs/真机验收清单_G09_G10.md)

---

## 0. 为什么需要这份文件

数据层已经有硬基准：**D17** 规定 Prefs 契约「以 iOS 源码实测为唯一基准」，并有 `check_contract_sync.py` 逐键守护。

**但表现层此前没有任何对齐基准。** 后果是「Flutter 的 UI 有没有达到 iOS 的水平」这句话**无法判定** —— 没有基准就没有「达标」的定义。本文件把表现层基准补齐到**可核对**的程度。

### 0.1 目标与边界

| 端 | 目标 | 说明 |
|---|---|---|
| **Android 手机** | **贴近 iOS** | 逐页对齐 §4 映射表；信息架构与 iOS 一致 |
| **PC（Windows / macOS）** | **贴近 iOS** | 布局按桌面适配（NavigationRail 取代底部 Tab），信息架构与手机同源 |
| **Android TV** | **尽量接近** | 受十英尺 + D-pad 约束，**允许形态差异**；但视觉语言（色 / 字 / 圆角）必须对齐 |

### 0.2 三条原则

1. **基准 = iOS 源码实测**，不是「设计稿」也不是「印象」。凡本文件给出的值都有证据位置。
2. **视觉语言必须对齐，交互形态允许适配**。色 / 字号 / 圆角 / 组件质感 → 对齐；导航结构 → 按端适配。
3. **不追溯改造 iOS**。`vbox/` 保持零改动（D1），本基准只约束 `lib/` 侧。

---

## 1. 基准来源与提取方法

### 1.1 一条必须先说清的事实

**iOS 侧没有集中式设计令牌文件。** 实测结论：

- 唯一的集中式颜色资产是 `Assets.xcassets/AccentColor.colorset`（sRGB `0.098 / 0.098 / 0.098` → `#191919`）；
- 其余颜色以「**各视图内的私有计算属性** + 散落的 `Color(hex:)` 字面量」存在，例如 `textNormal` / `textSecondary` / `cardBackground` 都是**视图私有**变量；
- `Color(hex:)` 初始化器本身也定义在业务模型文件里：[SpiderModels.swift](file:///workspace/vboxapp/vbox/Models/SpiderModels.swift#L403-L423)。

> **因此本基准不是「抄一份令牌表」，而是「从 iOS 源码采样 + 归纳」。** 这一点很重要：它意味着「对齐」是可执行的工程动作（采样 → 归纳 → 固化到 Flutter 令牌层），而不是一句口号。

### 1.2 提取方法

| 手段 | 目标 |
|---|---|
| 全仓检索 `Color(hex: "` | 枚举所有写死的色值字面量 |
| 全仓检索 `cornerRadius(` | 归纳圆角档位集合 |
| 全仓检索 `.font(.system(size:` | 归纳字号档位集合 |
| 检索 `Color(uiColor: .xxx)` | 识别 iOS 系统语义色引用 |
| 关键视图逐行阅读 | 确认皮肤分支、组件参数、页面结构 |

### 1.3 值的三类来源（全文逐条标注）

| 标记 | 含义 |
|---|---|
| **【实测】** | iOS 源码中显式写死的值，可直接引用 |
| **【系统】** | 源码以 `Color(uiColor: .xxx)` 引用 iOS 系统语义色 → 取 Apple HIG 标准值 |
| **【推导】** | 由实测值归纳出的档位/规则（如圆角档位集合） |

---

## 2. 设计令牌（Design Tokens）

### 2.1 皮肤系统 —— 本基准最高优先级的一条

iOS 有 **四套皮肤**，由 pref 键 `app_skin_mode` 控制（**契约内的既有键**，见 [prefs_keys_v1.json](file:///workspace/vboxapp/contract/schema/prefs_keys_v1.json#L357-L368)），默认 `light`。

| 枚举 | 中文名 | 主色 | 配色模式 | 证据 |
|---|---|---|---|---|
| `light` | 浅色模式 | `#E11D48` 玫瑰红 | 强制 Light | [AppSettings.swift](file:///workspace/vboxapp/vbox/App/AppSettings.swift#L39-L45) |
| `dark` | 黑暗模式 | `#E11D48` 玫瑰红 | 强制 Dark | 同上 |
| `frosted` | 磨砂模式 | `#7C3AED` 紫 | **跟随系统**（返回 nil） | [AppSettings.swift](file:///workspace/vboxapp/vbox/App/AppSettings.swift#L203-L204) |
| `liquid` | 液态模式 | `#38BDF8` 天蓝 | 强制 Dark | [AppSettings.swift](file:///workspace/vboxapp/vbox/App/AppSettings.swift#L199-L200) |

配套键：`app_skin_follows_system`（bool，契约内既有键）。

**主色分支在源码中同构出现 5 处**，判定依据是 `usesLiquidSkin` / `usesFrostedSkin` 两个布尔计算属性：

- [ProfileView.swift](file:///workspace/vboxapp/vbox/Views/ProfileView.swift#L92-L94)（及同文件 L1218、L1398 两处重复）
- [ShortDramaView.swift](file:///workspace/vboxapp/vbox/Views/ShortDramaView.swift#L314-L316)
- [ContentView.swift](file:///workspace/vboxapp/vbox/App/ContentView.swift#L258)

> **落地要求**：Flutter 必须建立等价令牌层，至少覆盖「枚举 × 主色 × 配色模式」三元组。
> 注意 `dark` 与 `light` **共用同一主色** `#E11D48`，差异只在 `ColorScheme`（Light/Dark）—— 不要误认为 `dark` 有独立品牌色。

### 2.2 颜色令牌

| 令牌 | 值 | 来源 | 用途 | 证据 |
|---|---|---|---|---|
| 皮肤主色 · 浅色/黑暗 | `#E11D48` | 【实测】 | 主按钮、选中态、强调 | ProfileView L94 |
| 皮肤主色 · 磨砂 | `#7C3AED` | 【实测】 | 磨砂皮肤主色 | ProfileView L93 |
| 皮肤主色 · 液态 | `#38BDF8` | 【实测】 | 液态皮肤主色 | ProfileView L92 |
| AccentColor 资产 | `#191919` | 【实测】 | 资产目录中的强调色 | [AccentColor.colorset](file:///workspace/vboxapp/vbox/Resources/Assets.xcassets/AccentColor.colorset/Contents.json) |
| 选中 / 激活 | `#2196F3` | 【实测】 | 播放器剧集当前项、面板选中 | [PlayerViewsV2_Extensions.swift](file:///workspace/vboxapp/vbox/Views/PlayerViewsV2_Extensions.swift#L462-L476) |
| 选中胶囊 | `#34C759` | 【实测】 | 榜单胶囊选中填充/描边 | [DoubanHomeView.swift](file:///workspace/vboxapp/vbox/Views/DoubanHomeView.swift#L439-L442) |
| 播放器深底 | `#0F0F23` | 【实测】 | 播放器空/错态背景 | [PlayerSubViews.swift](file:///workspace/vboxapp/vbox/Views/PlayerSubViews.swift#L44) |
| 品牌蓝渐变 | `#3B82F6` → `#2563EB` → `#1D4ED8` | 【实测】 | 「我的」页头部渐变 | [ProfileView.swift](file:///workspace/vboxapp/vbox/Views/ProfileView.swift#L902) |
| 系统底 · 浅 | `#FFFFFF` | 【系统】 | `.systemBackground` | Apple HIG |
| 系统分组底 · 浅 | `#F2F2F7` | 【系统】 | `.secondarySystemBackground` | Apple HIG |
| 系统分组底 · 深 | `#1C1C1E` | 【系统】 | `.secondarySystemBackground`（Dark） | Apple HIG |
| 次级文字 · 浅 | `#3C3C43` @ 60% | 【系统】 | `.secondaryLabel` | Apple HIG |
| 分类色板（10 色） | `#6B7280` `#8B5CF6` `#EF4444` `#3B82F6` `#10B981` `#F59E0B` `#6366F1` `#EC4899` `#F97316` `#14B8A6` | 【实测】 | 日志分类 / 站点标签 | [LogViewerView.swift](file:///workspace/vboxapp/vbox/Views/LogViewerView.swift#L374-L384) |

> 分类色板是**有语义的固定映射**（app / spider / player / cloud / proxy / network / db / download / welfare / node），不是装饰色 —— 落地时应作为枚举 → 颜色的映射表，而非自由取色。

### 2.3 字体

- iOS **全部使用系统字体** `.font(.system(size:))`（即 SF Pro / 苹方），Assets 中**没有注册任何自定义字体文件**（资产目录只有 1 个颜色集 + AppIcon + 若干 splash 字母图）。
- **字号实测集合**：`10 / 11 / 12 / 13 / 14 / 15 / 16 / 18 / 24 / 28`。
- **归纳档位**【推导】：

| 档位 | 用途 |
|---|---|
| 10 – 11 | 角标、辅助说明、Tab 文字 |
| 12 – 13 | 次级正文、列表副标题、标签 |
| 14 – 15 | 正文、列表主标题 |
| 16 | 区块标题（semibold） |
| 18 | 弹窗标题、大号按钮 |
| 24 – 28 | 页面主标题、空态标题 |

> **落地口径**：**字号对齐，字体族不强制**。Android 用思源黑体 / 桌面用系统字体即可 —— 逐字形的字体差异不计入「不达标」。

### 2.4 圆角

- **实测档位集合**【推导】：`{ 4, 6, 8, 10, 12, 14, 16, 20 }`
- 一律使用 **`.continuous`**（连续曲率）风格，非普通圆角。
- **用途映射**【推导】：

| 圆角 | 用途 | 证据示例 |
|---|---|---|
| 4 | 小标签 / 角标 | [SiteDiagnosticsView.swift](file:///workspace/vboxapp/vbox/Views/SiteDiagnosticsView.swift#L217-L220) |
| 6 – 8 | 按钮、列表项内小块 | [LogViewerView.swift](file:///workspace/vboxapp/vbox/Views/LogViewerView.swift#L131-L167) |
| 10 – 12 | 分组卡片、sheet | [BackupRestoreSheet.swift](file:///workspace/vboxapp/vbox/Views/BackupRestoreSheet.swift#L118-L144) |
| 14 – 16 | 筛选 chip、中号卡 | [SiteDiagnosticsView.swift](file:///workspace/vboxapp/vbox/Views/SiteDiagnosticsView.swift#L51-L54) |
| 20 | 大卡片 / 面板（主角） | [MainViews.swift](file:///workspace/vboxapp/vbox/Views/MainViews.swift#L2424-L2441) |

### 2.5 关键组件规格

| 组件 | 规格 | 证据 |
|---|---|---|
| **大卡片 / 面板** | 圆角 20（continuous）+ **1px 线性渐变描边**（`systemBackground` 10% → 0%，左上→右下） | [MainViews.swift](file:///workspace/vboxapp/vbox/Views/MainViews.swift#L2424-L2441) |
| **Toast** | 背景黑 85% + 圆角 12 + 白字 | [RemoteWelfareSettingsView.swift](file:///workspace/vboxapp/vbox/WelfareRemote/RemoteWelfareSettingsView.swift#L76-L83) |
| **选中胶囊** | 填充 `#34C759` + 同色描边 70% | [DoubanHomeView.swift](file:///workspace/vboxapp/vbox/Views/DoubanHomeView.swift#L439-L442) |
| **播放器剧集项** | 当前项文字 `#2196F3`、底色 `#2196F3` @20%、带边框；非当前项跟随正文色 | [PlayerViewsV2_Extensions.swift](file:///workspace/vboxapp/vbox/Views/PlayerViewsV2_Extensions.swift#L460-L476) |
| **阴影** | 主色阴影 `opacity 0.35 – 0.40`、`radius 10 – 16`、`y 4 – 6` | [ProfileView.swift](file:///workspace/vboxapp/vbox/Views/ProfileView.swift#L933) / [L1026](file:///workspace/vboxapp/vbox/Views/ProfileView.swift#L1026) |
| **危险操作** | 文字红 + 背景红 @10% + 圆角 8 | [RemoteWelfareSettingsView.swift](file:///workspace/vboxapp/vbox/WelfareRemote/RemoteWelfareSettingsView.swift#L230-L237) |

### 2.6 图标

- iOS 以 **SF Symbols**（`Image(systemName:)`）为主。
- **落地口径**：Flutter 侧用 Material Icons，**只要求语义等价，不要求形状逐一对齐**。

---

## 3. UI 样式图

> 以下 8 张样式图由本基准的定义值直接渲染生成（真实中文字形 + Material 图标），用于**视觉核对**，不替代 §2 的文字规格。

| # | 样式图 | 内容 |
|---|---|---|
| 01 | [设计令牌总览](computer:///workspace/vboxapp/docs/ui_baseline/01_tokens.png) | 皮肤主色 / 语义色 / 品牌渐变 / 分类色板 / 字阶 / 圆角档位 / 卡片 / Toast |
| 02 | [手机 · 首页](computer:///workspace/vboxapp/docs/ui_baseline/02_phone_home.png) | 源选择 + 搜索栏 + 轮播 + 分类胶囊 + 横向列表 + MiniPlayer + 悬浮 TabBar |
| 03 | [手机 · 搜索](computer:///workspace/vboxapp/docs/ui_baseline/03_phone_search.png) | 搜索框 + 排行榜入口 + 搜索历史胶囊 + 结果网格 |
| 04 | [手机 · 详情页](computer:///workspace/vboxapp/docs/ui_baseline/04_phone_detail.png) | 头图 + 评分标签 + 简介 + 选集网格 + 播放源 + 底部操作条 |
| 05 | [手机 · 播放器](computer:///workspace/vboxapp/docs/ui_baseline/05_phone_player.png) | 播放区 + 控制条 + 功能按钮行 + 选集抽屉（当前项高亮） |
| 06 | [手机 · 我的](computer:///workspace/vboxapp/docs/ui_baseline/06_phone_profile.png) | 渐变头部卡 + 分组设置 + 皮肤选择器 |
| 07 | [桌面 · 首页](computer:///workspace/vboxapp/docs/ui_baseline/07_desktop_home.png) | NavigationRail + 顶栏搜索/源选择 + 海报墙 |
| 08 | [TV · 首页](computer:///workspace/vboxapp/docs/ui_baseline/08_tv_home.png) | 顶栏 Tab + 横向大卡 + **焦点态**（主色描边 + 放大 + 阴影）+ 遥控提示 |

---

## 4. 页面清单与三端映射

### 4.1 iOS 页面清单（基准侧）

导航骨架：底部 Tab **首页 / 搜索 / 短剧 / 直播 / 福利 / 我的**（福利 Tab 条件可见），见 [ContentView.swift](file:///workspace/vboxapp/vbox/App/ContentView.swift#L17-L57)。

| iOS 页面 | 职责 | 证据 |
|---|---|---|
| 首页 `HomeView` | 搜索栏 + 轮播 + 分类 + 横向影视列表 + 源下拉 | [MainViews.swift](file:///workspace/vboxapp/vbox/Views/MainViews.swift#L301-L501) |
| 搜索 `SearchView` | 搜索框 + 排行榜入口 + 历史 + 结果 | [MainViews.swift](file:///workspace/vboxapp/vbox/Views/MainViews.swift#L1334-L1417) |
| 短剧 `ShortDramaView` | 短剧频道 | [ShortDramaView.swift](file:///workspace/vboxapp/vbox/Views/ShortDramaView.swift) |
| 直播 `LiveTVView` | 分类 + 频道列表 + 源选择 + EPG | [LiveTVView.swift](file:///workspace/vboxapp/vbox/Views/LiveTVView.swift#L225-L342) |
| 福利 `WelfareTabGateView` | 条件可见 + 三重隔离约束 | [ContentView.swift](file:///workspace/vboxapp/vbox/App/ContentView.swift#L59-L82) |
| 我的 `ProfileView` | 个人信息 + 分组设置 + 皮肤选择 | [ProfileView.swift](file:///workspace/vboxapp/vbox/Views/ProfileView.swift) |
| 详情页 | 剧集列表 + 播放源选择 | [SourcePickerSheet.swift](file:///workspace/vboxapp/vbox/Views/SourcePickerSheet.swift#L30-L104) |
| 播放器 `VideoPlayerViewV2` | 多后端播放 + 控制层 + 画中画 | [PlayerViewsV2.swift](file:///workspace/vboxapp/vbox/Views/PlayerViewsV2.swift#L537-L636) |
| 备份 / 日志 / 站点诊断 | 工具页 | [BackupRestoreSheet.swift](file:///workspace/vboxapp/vbox/Views/BackupRestoreSheet.swift) · [LogViewerView.swift](file:///workspace/vboxapp/vbox/Views/LogViewerView.swift) · [SiteDiagnosticsView.swift](file:///workspace/vboxapp/vbox/Views/SiteDiagnosticsView.swift) |

### 4.2 Flutter 侧现状（`lib/presentation/`，10 文件）

| 文件 | 对应 iOS 页面 | 状态 |
|---|---|---|
| [home_shelf_page.dart](file:///workspace/vboxapp/lib/presentation/phone/home_shelf_page.dart) | 首页（骨架级书架） | 已交付（第 1 轮） |
| [remote_source_page.dart](file:///workspace/vboxapp/lib/presentation/phone/remote_source_page.dart) | 源管理 | 已交付 |
| [detail_page.dart](file:///workspace/vboxapp/lib/presentation/widgets/detail_page.dart) | 详情页 + 播放入口 | 已交付 |
| [library_views.dart](file:///workspace/vboxapp/lib/presentation/widgets/library_views.dart) | 收藏 / 历史 | 已交付 |
| [desktop_home_page.dart](file:///workspace/vboxapp/lib/presentation/desktop/desktop_home_page.dart) | 桌面形态 | 已交付 |
| [tv_home_page.dart](file:///workspace/vboxapp/lib/presentation/tv/tv_home_page.dart) | TV 形态 | 已交付 |
| [backup_page.dart](file:///workspace/vboxapp/lib/presentation/widgets/backup_page.dart) | 备份 / 恢复 | 已交付 |
| [log_viewer_page.dart](file:///workspace/vboxapp/lib/presentation/widgets/log_viewer_page.dart) | 日志查看 | 已交付 |
| [ui_mode.dart](file:///workspace/vboxapp/lib/presentation/ui_mode/ui_mode.dart) · [ui_mode_resolver.dart](file:///workspace/vboxapp/lib/presentation/ui_mode/ui_mode_resolver.dart) | 形态判定 | 已交付 |

### 4.3 映射与批次（**待对齐清单**）

| iOS 页面 | phone | desktop | TV | 批次 |
|---|---|---|---|---|
| 首页（完整版：轮播 + 分类 + 横向列表） | 对齐 §3-02 | 对齐 §3-07 | 对齐 §3-08 | 第 2 轮 |
| 搜索 | 对齐 §3-03 | 同源适配 | 同源适配 | 第 2 轮 |
| 详情页 | 对齐 §3-04 | 同源适配 | 同源适配 | 第 2 轮 |
| 播放器 | 对齐 §3-05 | 同源适配 | 同源适配 | 第 2 轮 |
| 我的 | 对齐 §3-06 | 同源适配 | 同源适配 | 第 2 轮 |
| 短剧 / 直播 / 福利 | 形态对齐 | 同源适配 | 优先 TV 形态 | 第 2 轮起 |
| 站点诊断 | 对齐 | 同源适配 | — | 第 2 轮起 |

> **批次口径**：上表「第 2 轮」为**功能补全轮的统称**，具体子批次以主方案为准 —— 本文件只定义「做到什么样算对齐」，不定义排期。

---

## 5. 验收口径（可核对）

| 编号 | 规则 | 核对方式 |
|---|---|---|
| **R-1** | 皮肤令牌一致：四枚举的主色与 §2.1 表一致 | 人工 + 令牌文件比对 |
| **R-2** | 圆角受控：新增代码的圆角值取自档位集合 | 检索 `BorderRadius.circular` |
| **R-3** | 字号受控：新增代码的字号取自档位集合 | 检索 `fontSize:` |
| **R-4** | 主色不散落：除令牌文件外，禁止出现十六进制颜色字面量 | 检索 `Color(0x` |
| **R-5** | 页面登记：新增页面必须在 §4 映射表中登记 | 人工核对 |

> **建议（第 2 轮实施）**：为 R-2 / R-3 / R-4 增加守卫脚本，把上述口径转为可自动检测的失败，与数据层的 `check_contract_sync.py` 形成对称。**本文件不预置脚本数量口径**，避免与既有校验套件计数冲突。

---

## 6. 现状差距（Gap）

| # | 差距 | 证据 | 严重度 |
|---|---|---|---|
| G1 | **Flutter 无令牌层**：当前主题是 `ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true)` —— 主色为 Material 默认蓝，与四套皮肤**无任何映射关系** | [app.dart](file:///workspace/vboxapp/lib/app.dart#L209-L217) | 🔴 高 |
| G2 | **无皮肤切换能力**：`app_skin_mode` / `app_skin_follows_system` 两个契约键在 Flutter 侧未被消费 | 同上 | 🔴 高 |
| G3 | **表现层体量差距**：`lib/presentation` 10 文件 vs iOS 80+ SwiftUI 视图 | §4.2 | 🟡 中（第 2 轮补齐） |
| G4 | **形态差异**：TV 端导航为顶栏 Tab、桌面为 NavigationRail，与 iOS 底部 Tab 不同 | 设计使然（D5） | 🟢 低（不计不达标） |

**建议的第 2 轮起手动作**：先做 G1 + G2（令牌层 + 皮肤切换），因为它是一次性基础设施，做完之后所有页面都能「天然对齐」；若先做页面，会导致颜色散落、后续返工。

---

## 附录 A：令牌速查

```
皮肤主色      light/dark #E11D48   frosted #7C3AED   liquid #38BDF8
语义色        #2196F3 选中 · #34C759 胶囊 · #0F0F23 播放器底
品牌渐变      #3B82F6 → #2563EB → #1D4ED8
系统色        #FFFFFF / #F2F2F7 / #1C1C1E / #3C3C43@60%
分类色板      #6B7280 #8B5CF6 #EF4444 #3B82F6 #10B981
              #F59E0B #6366F1 #EC4899 #F97316 #14B8A6
字号          10 11 12 13 14 15 16 18 24 28
圆角          4 6 8 10 12 14 16 20   （.continuous）
阴影          主色 opacity .35–.40 / radius 10–16 / y 4–6
```

## 附录 B：证据索引（iOS 侧）

| 主题 | 文件 |
|---|---|
| 皮肤枚举与配色模式 | [AppSettings.swift](file:///workspace/vboxapp/vbox/App/AppSettings.swift#L4-L46) |
| 皮肤主色分支 | [ProfileView.swift](file:///workspace/vboxapp/vbox/Views/ProfileView.swift#L92-L94) · [ShortDramaView.swift](file:///workspace/vboxapp/vbox/Views/ShortDramaView.swift#L314-L316) · [ContentView.swift](file:///workspace/vboxapp/vbox/App/ContentView.swift#L258) |
| `Color(hex:)` 定义 | [SpiderModels.swift](file:///workspace/vboxapp/vbox/Models/SpiderModels.swift#L403-L423) |
| 大卡片 + 渐变描边 | [MainViews.swift](file:///workspace/vboxapp/vbox/Views/MainViews.swift#L2424-L2441) |
| 分类色板 | [LogViewerView.swift](file:///workspace/vboxapp/vbox/Views/LogViewerView.swift#L374-L384) |
| 品牌蓝渐变 + 阴影 | [ProfileView.swift](file:///workspace/vboxapp/vbox/Views/ProfileView.swift#L902-L933) |
| 导航骨架（六 Tab） | [ContentView.swift](file:///workspace/vboxapp/vbox/App/ContentView.swift#L17-L82) |
| 播放器控制与剧集项 | [PlayerViewsV2.swift](file:///workspace/vboxapp/vbox/Views/PlayerViewsV2.swift#L537-L636) · [PlayerViewsV2_Extensions.swift](file:///workspace/vboxapp/vbox/Views/PlayerViewsV2_Extensions.swift#L460-L476) |

---

> **维护口径**：本文件与主方案**版本独立**（主方案用 v6.x 修订号，本文件用 v1.x）。本文件任何变更须在下方登记。
>
> | 版本 | 日期 | 变更 |
> |---|---|---|
> | v1.0 | 2026-10-01 | 首版：皮肤系统 / 颜色 / 字体 / 圆角 / 组件令牌 + 8 张样式图 + 页面映射表 + 验收口径 R-1~R-5 + 现状差距 G1~G4 |