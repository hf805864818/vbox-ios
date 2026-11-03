# vbox 第 2 轮开发方案 · iOS 全量复核与遗漏补全 · v1.3

> **性质**：对 [第2轮开发计划_功能补全_v2.6.md](computer:///workspace/vboxapp/docs/第2轮开发计划_功能补全_v2.6.md) 的**独立复核补遗**，不替代该方案；结论已回流至该方案 **v2.2 / v2.3 / v2.4 / v2.5**。
> **复核对象**：iOS 参照实现 `/workspace/vboxapp/vbox/`，共 **189 个 Swift 文件**（Views 55 · Services 73 · PlayerCore 34 · WelfareRemote 17 · Models 6 · App 3 · Bridge 1）+ `Libraries/` 原生库 + `Resources/` 资源。
> **复核方法**：全目录盘点 → 逐文件归类 → 导航入口回溯（谁打开了这个页面）→ 与 v2.1 批次 A–K 逐条比对。
> **结论**：v2.1 遗漏 **41 项**，需新增 **5 个批次（L–P）**，并显著扩充 4 个既有批次（B/C/F/G/H）。

---

## 0. 复核摘要

| 项 | 结论 |
|----|------|
| iOS 文件规模 | **189 Swift**（初版仅按 UI 图 + 粗清单估算，覆盖面不足） |
| v2.1 批次 | A–K（11 个） |
| **补齐后批次** | **A–P（16 个）** |
| 完全遗漏（用户可见） | **17 项**（P0） |
| 严重低估（已提及但范围不足） | **13 项**（P1） |
| 资源/种子数据遗漏 | **7 类**（P2） |
| 口径需澄清 | **1 项**（P3：福利漫画 vs 独立漫画阅读器） |

---

## 1. 复核基线：iOS 全量盘点

### 1.1 目录构成（已核实）

| 目录 | 文件数 | 说明 |
|------|--------|------|
| `vbox/Views/` | 55 | 全部页面与通用视图 |
| `vbox/Services/` | 73 | 服务层（含 11 个网盘/授权服务、12 个内容源服务、福利服务、运行时服务） |
| `vbox/PlayerCore/` | 34 | 播放内核（引擎矩阵、PiP、Remux、硬解） |
| `vbox/WelfareRemote/` | 17 | 福利远程子系统（路由/加载器/门控/映射） |
| `vbox/Models/` | 6 | 数据模型 |
| `vbox/App/` | 3 | VBoxApp / ContentView / AppSettings |
| `vbox/Bridge/` | 1 | GoProxyManager |
| `vbox/Libraries/` | — | QuickJS / Python / NodeMobile / MPVKit / IJK / AliyunPlayer / AliyunMediaDownloader / alivcffmpeg + AppLogBridge |
| `vbox/Resources/` | — | js 脚本库 / noderuntime / python-stdlib / m3u / json / 字体 / 启动页图片 |

### 1.2 导航骨架（`ContentView.swift` 实证）

- 6 个底部 Tab：首页 / 搜索 / 短剧 / 直播 / **福利（条件可见）** / 我的。
- **福利 Tab 条件可见**：`settings.welfareUnlocked && settings.welfareEnabled` 才插入（L51-57）。
- **动态启动页覆盖层（zIndex 30，最高层）**：`VboxSplashView`（L229-235）。
- 全局浮层：**音乐 MiniPlayer**（L141-143）· 更新弹窗/最小化气泡（L191-208）· 下载管理弹窗（L210-216）· 悬浮下载按钮（L218-227）· **远程源状态条**（L90）· 下载胶囊通知（L91）。
- 启动序列（L149-186）：恢复音乐队列 → Spider 初始化 → 检查更新 → 启动页最短 3.5s + 数据就绪 + **10s 兜底**。
- 底栏可隐藏（`settings.isTabBarHidden`）、悬浮胶囊底栏样式。

---

## 2. 遗漏清单

### 2.1 P0 · 完全遗漏且用户可见（必须补）

| # | 遗漏项 | iOS 证据 | 说明 |
|---|--------|---------|------|
| 1 | **启动闪屏与数据门控** | `Views/VboxSplashView.swift`、`Services/SplashGateMonitor.swift`、`App/ContentView.swift:11-15,229-254` | 动画 Logo（V/b/o/x + swoosh 图片）、最短 3.5s、数据就绪淡出、10s 兜底 |
| 2 | **账号体系** | `Views/ProfileView.swift:890`（LoginSheetView）、`L1130`（EditNicknameSheet） | 登录 / 注册 / **上级用户推荐码** / 编辑昵称 / 退出登录 |
| 3 | **观看记录页** | `Views/ProfileView.swift:1210`（WatchHistoryView） | 列表 + 删除 + 清空 + 点开续播 |
| 4 | **我的收藏页** | `Views/ProfileView.swift:1390`（FavoriteView） | 同上；v2.1 只提到「观看记录」，漏了收藏 |
| 5 | **分享 vbox** | Profile 3×3 宫格项 | 应用分享 |
| 6 | **备份与还原** | `Views/BackupRestoreSheet.swift`、`Services/BackupManager.swift` | **9 类目**；**PBKDF2 + AES-256-GCM 口令加密**；账号校验；远程源版本检测；还原后重建站点列表 + 网盘凭据同步 |
| 7 | **音乐 MiniPlayer 全局浮层** | `App/ContentView.swift:141-143` | 可拖动；左滑关闭 / 右滑折叠 / 上下移动；启动恢复播放队列 |
| 8 | **下载胶囊通知 + 悬浮下载按钮** | `Views/DownloadOverlayViews.swift`、`ContentView.swift:91,218-227` | 胶囊通知条 + 悬浮按钮（可手动隐藏）+ 下载管理弹窗 |
| 9 | **远程源状态通知条** | `Views/RemoteSourceStatusBar.swift`、`ContentView.swift:90` | 全局显示远程源加载/版本状态 |
| 10 | **源发现页** | `Views/SourceDiscoveryView.swift`、`Views/MainViews.swift:301-328` | 从首页进入的**单源分类浏览**（配套 `SpiderManager.getCategoryContent`） |
| 11 | **兜底切片资源** | `Views/SettingsViews.swift:399-464` | 启用兜底切片资源开关 |
| 12 | **自定义切片源管理** | `Views/SettingsViews.swift:3127-3298` | 内置兜底源（兼容模式）+ 自定义兜底源 + 添加/删除 |
| 13 | **自定义解析器管理** | `Views/SettingsViews.swift:3341-3396` | `spiderManager.customParsers` 增删 |
| 14 | **站源管理** | `Views/SettingsViews.swift:467-493` | 启用 / 禁用站源 |
| 15 | **日志系统** | `Views/LogViewerView.swift`、`Services/AppLogStore.swift`（11 类分类）、`Services/NetworkLogger.swift`（URLProtocol 拦截） | 日志查看页 + 分类日志 + 网络拦截 |
| 16 | **开发调试页 + 存储管理** | `Views/SettingsViews.swift:806,844-931` | 存储管理；开发调试（MPV Header 测试、切片播放测试、网盘直链测试） |
| 17 | **「关于」页** | `Views/SettingsViews.swift:931` | 版本/许可等 |

### 2.2 P1 · 已提及但**严重低估**（范围须扩充）

| # | 域 | v2.1 口径 | **实际范围** | 证据 |
|---|----|----------|-------------|------|
| 1 | **网盘/授权** | 夸克 / 阿里 / 百度 共 3 家 | **11+ 家**：UC · 115 · 123 · 139 · 189 · 迅雷 · 光鸭 · 蜗牛 · **B站** · 夸克 · 百度；每家支持 **原生扫码 / Node 扫码 / 网页兜底 / 复制粘贴 Token** 多模式 | `SettingsViews.swift:1616,1971-2058` |
| 2 | **B 站扫码登录** | 未提 | 独立授权链路（Node `/website/api/bili/login/*`）| `Services/BiliAuthManager.swift`、`Views/BiliQrLoginView.swift` |
| 3 | **阿里 extscreen 授权加密链** | 未提 | 设备指纹 + 时间戳 + SHA256 签名 + 二维码/轮询/token 刷新 | `Services/ExtscreenAPIClient.swift`、`ExtscreenCrypto.swift`、`AliyunPgAuthManager/Config/PlayManager.swift`、`Views/AliyunPgQrLoginView.swift` |
| 4 | **Node 凭据同步** | 未提 | **12+ provider 字段映射**（115/123/139/189/迅雷/光鸭/蜗牛/B站/夸克/UC/百度）| `Services/NodeCredentialSyncService.swift` |
| 5 | **福利平台路由** | "90 平台 ×3 分类" | 需 **5 类 `serviceType` 路由**：`aidanVideo` / `fuliBase` / `remoteCmsV10` / `welfareSpider` / `pythonSpider` + **`FuliBaseService` 基类** + `CMSV10Helper` / `RemoteCMSV10Service` | `WelfareRemote/WelfarePlatformRouter.swift`、`Services/FuliPlatformService.swift`、`CMSV10Helper.swift`、`RemoteCMSV10Service.swift` |
| 6 | **福利原生平台服务** | 视为配置驱动 | 存在**独立原生实现**：每日大乱斗/每日大赛（`DailyBattleService`）、今日看料（`KanliaoService`）、三更平台（`SangeModels` + 分类/列表页）、FullHD（`FullHDService`）、空虚视频 H5（`KXSPAPIService`）、Aidan/Banana/Duck/FourH/Panda/Waibi/MissAV/Lusushequ 等 | `Services/*.swift`、`Views/SangeCategoryView.swift`、`SangeListView.swift`、`KanliaoHomeView.swift`、`DailyBattleMainView.swift` |
| 7 | **福利脚本安全加载器** | 未提 | 只允许 `welfare_spider` 类型、仅 `python`/`javascript`、**路径必须来自 `sources/welfare-js/`** | `WelfareRemote/WelfareSpiderLoader.swift:109-164` |
| 8 | **弹幕后端服务** | 仅 UI | 番剧搜索 → 按集匹配 → 缓存 → 失败回退按剧名搜索；**自定义弹幕源设置** | `Services/LogVarDanmakuService.swift` |
| 9 | **字幕解析** | 仅"加载字幕"菜单项 | 独立解析服务 | `Services/SubtitleParser.swift` |
| 10 | **站源原生搜索** | 未提 | Kanna HTML/XPath **并发搜索全部启用站源** + 内存回退 | `Services/ZhanyuanSearchService.swift` |
| 11 | **腾讯视频原生 Spider** | 未提 | 替代失效 drpy JS 蜘蛛（`siteKey = drpy_js_腾云驾雾`）| `Services/TencentVideoNativeSpider.swift` |
| 12 | **WKWebView 解析器** | 未提 | JS / WASM parser 经 WebView 执行 + 超时清理 | `Services/WKWebViewParser.swift` |
| 13 | **播放器内核深度** | 基础回退 | **PiP 5 策略**（MDK/MPV/VT/ViewCapture/AVPlayer 代理）+ **本地 Remux 代理**（`RemuxProxyServer`/`StreamRemuxer`）+ **硬解会话**（`VTDecoderSession`）+ **MPV 后端矩阵**（MPVKit / libmpv / MoltenVK / 不可用降级 / 运行时清单校验）| `PlayerCore/*`（34 文件） |

### 2.3 P2 · 资源与种子数据遗漏

| # | 资源 | 用途 | 处置 |
|---|------|------|------|
| 1 | `Resources/js/`（`cheerio.min.js`、`net.js`、`similarity.js`、`utils.js`、`zhanyuan_spider.js`、`模板.js`、`native_bridge/测试蜘蛛.js`） | JS 蜘蛛运行时与示例 | 需内置/按需下载 |
| 2 | `Resources/noderuntime/`（`main.js`、`lx/lx-bridge.js`、`bundles/kstore_index.js`、`db.json`、`wexfnwconfig.json`、`node-intl-polyfill.js`） | Node 运行时主入口与 lx 插件 | 按需下载（6.4MB，不入包） |
| 3 | `Resources/python-stdlib/base/spider.py` | Python 蜘蛛基类（代理桥接 / SSL bypass / 请求拦截） | 需内置 |
| 4 | `Resources/default_subscribe.json`、`ibox_sources.json`、`tetui_spider.js`、`video_sources.json` | 内置订阅/源种子数据 | 需内置 |
| 5 | `Resources/live_default.m3u`、`default_live.m3u` | 默认直播源 | 需内置 |
| 6 | `Resources/Fonts/MaShanZheng-Regular.ttf` | 品牌书法字体（启动页/标题） | **需内置**（v2.1 曾将"字体族差异"排除在还原度外，但品牌字体本身须内置） |
| 7 | `Assets.xcassets`：`splash_letter_V/b/o/x`、`splash_swoosh`、`AccentColor` | 启动页字母动画素材 | 需内置 |

### 2.4 P3 · 口径需澄清

| 冲突 | 说明 | 建议 |
|------|------|------|
| **D2「漫画/小说延后」** vs **福利三栏目含"漫画"** | 福利专区三栏目为 视频 / 直播 / **漫画**，福利·漫画栏目属 H 批次范围；而独立的 `MangaReaderView` / `ComicDetailBridgeView`（阅读器）体量大 | **边界写明**：福利·漫画**栏目**保留（H）；**独立漫画/小说阅读器增强延后**（跨轮待办） |

---

## 3. 补全方案：新增批次 L–P

> 批次字母续用 A–P，不重排既有 A–K；新增批次依赖均为 A（基座），可与 D–H 并行。

| 批次 | 名称 | 体量 | 依赖 | 要点 |
|------|------|------|------|------|
| **L** | **启动与全局外壳** | 中 | A | 启动闪屏（动画 Logo + 数据门控 + 3.5s 最短 + 10s 兜底）；远程源状态条；下载胶囊通知 + 悬浮下载按钮；音乐 MiniPlayer（拖动/滑动/队列恢复）；底栏隐藏与四皮肤背景（liquid/frosted） |
| **M** | **账号与个人数据** | 大 | A、B | 登录/注册（含推荐码）；编辑昵称；退出登录；**观看记录页**；**我的收藏页**；分享 vbox |
| **N** | **备份与还原** | 中 | A、F | 9 类目采集；PBKDF2 + AES-256-GCM 口令加密；账号校验；远程源版本检测；还原后重建站点列表 + 网盘凭据同步 |
| **O** | **兜底与源治理** | 大 | A、B、C | 兜底切片资源开关；自定义切片源（内置兼容模式 + 自定义）；自定义解析器管理；站源启用/禁用；**源发现页** |
| **P** | **日志与诊断** | 中 | A | AppLogStore（11 分类）；NetworkLogger（URLProtocol 拦截）；日志查看页；开发调试页（MPV Header / 切片播放 / 网盘直链测试）；存储管理；关于页 |

---

## 4. 既有批次范围修订

| 批次 | 修订内容 |
|------|---------|
| **B 远程源 + Spider** | **新增**：站源原生搜索（Kanna 并发）· 腾讯视频原生 Spider · WKWebView 解析器（JS/WASM） |
| **C 播放器** | **新增**：PiP 5 策略（MDK/MPV/VT/ViewCapture/AVPlayer 代理）· 本地 Remux 代理（`RemuxProxyServer`/`StreamRemuxer`，与 Go 代理并列）· 硬解会话（`VTDecoderSession`）· MPV 后端矩阵与运行时清单校验 · 弹幕后端服务 · 字幕解析 |
| **F 网盘** | **扩为 11+ 家** + 多登录模式（原生扫码 / Node 扫码 / 网页兜底 / Token 粘贴）+ 阿里 extscreen 加密链 + Node 凭据同步 + B 站扫码登录 |
| **G 扩展域** | **新增**：音乐 MiniPlayer 归属 L；观看记录/收藏/昵称/分享归属 M |
| **H 福利** | **新增**：5 类 `serviceType` 路由 + `FuliBaseService` 基类 + `CMSV10Helper`/`RemoteCMSV10Service` + 福利脚本安全加载器 + **原生平台服务清单**（每日大乱斗 / 今日看料 / 三更 / FullHD / 空虚 H5 / Aidan / Banana / Duck / FourH / Panda / Waibi / MissAV / Lusushequ…） |
| **A 设计基座** | **新增**：品牌字体 `MaShanZheng-Regular` 内置 + liquid/frosted 皮肤背景组件 + 底栏隐藏能力 |
| **I 我的/设置** | 设置页分组按实证对齐为 **12 个设置分区**：皮肤 / 播放设置 / TMDB / TG搜索 / 切片资源 / 站源管理 / 订阅配置 / 网盘播放 / 存储管理 / 站点诊断 / 开发调试 / 关于 |

---

## 5. 修订后批次全景（A–P）

| 批次 | 名称 | 体量 | 依赖 |
|------|------|------|------|
| A | 设计基座（令牌+组件库+形态解析+自适应+守卫+视觉回归+品牌字体） | 特大 | — |
| B | 远程源 + Spider（5 引擎 + 站源原生搜索 + 腾讯原生 + WebView 解析） | 大 | A |
| C | 播放器（横竖双态 + 回退 + PiP 5 策略 + Remux + 硬解 + 弹幕/字幕 + Go 代理） | 特大 | B、A |
| D | 内容浏览 | 大 | A、B、C |
| E | 直播 | 大 | A、C |
| F | 网盘与授权（11+ 家 + 多登录模式 + extscreen + B站） | 特大 | A、B、C |
| G | 扩展域（音乐/下载/推送/TG/单平台/TMDB/订阅/诊断/Bug反馈） | 大 | A、B、C |
| H | 福利专区（5 类路由 + 基类 + 原生平台清单 + 三重隔离） | 特大 | A、B、C |
| I | 我的/设置（12 组 + 显示模式开关）+ 更新 UI | 大 | A + 各域 |
| **L** | **启动与全局外壳** | 中 | A |
| **M** | **账号与个人数据** | 大 | A、B |
| **N** | **备份与还原** | 中 | A、F |
| **O** | **兜底与源治理** | 大 | A、B、C |
| **P** | **日志与诊断** | 中 | A |
| K | 打包 / 签名 / 自更新链路（D1 提前） | 中 | A（可早启动） |
| J | 全量真机验收（G-09/G-10）+ E.10b 门禁 + UI 还原度终检 | 大 | A–I、K–P |

---

## 6. 对完成判定（E.10b）的影响

| 门禁项 | 追加要求 |
|--------|---------|
| ③ 平台差异 | 启动闪屏在四端均正常；底栏隐藏/胶囊底栏四端一致 |
| ④ 功能完整性 | **账号体系 + 观看记录/收藏 + 备份还原 + 兜底切片/自定义解析器 + 站源管理 + 源发现 + 日志系统**全部交付；**网盘 11+ 家**授权与播放可用；**福利 5 类 serviceType 路由**可用 |
| ⑥ 交付物与文档 | 品牌字体与启动素材已内置；内置种子数据（订阅/源/m3u）已内置 |

---

## 7. 复核局限（诚实声明）

- 本次复核基于**全目录盘点 + 关键模块精读 + 导航入口回溯**；`Services/` 73 个文件未逐一逐行精读，按职责归类。
- 若某服务为**死代码/历史遗留**（iOS 侧未从任何入口可达），实际可减配；建议在执行对应批次时以「入口可达性」二次确认后再决定是否移植。
- 已知入口未定位项：`SangeCategoryView`（三更）在 iOS 侧未见顶层入口，疑经福利平台路由进入，需在 H 批次确认。

---

## 附录：遗漏项 → 批次映射

| 遗漏项 | 归属批次 |
|--------|---------|
| 启动闪屏 / 状态条 / 下载胶囊 / MiniPlayer / 底栏隐藏 | **L** |
| 账号 / 昵称 / 观看记录 / 收藏 / 分享 | **M** |
| 备份与还原 | **N** |
| 兜底切片源 / 自定义切片源 / 自定义解析器 / 站源管理 / 源发现 | **O** |
| 日志 / 网络日志 / 开发调试 / 存储管理 / 关于 | **P** |
| 网盘 11+ 家 / extscreen / B站 / Node 凭据同步 | **F** |
| 福利 5 类路由 + 原生平台 + 安全加载器 | **H** |
| PiP 5 策略 / Remux / 硬解 / MPV 矩阵 / 弹幕后端 / 字幕 | **C** |
| 站源原生搜索 / 腾讯原生 Spider / WKWebView 解析 | **B** |
| 品牌字体 / 皮肤背景 / 内置种子数据 | **A** |

---

## 8. 二轮复核补遗（v1.1 新增 12 项）

> 二轮复核方式：逐文件核验**入口可达性**（grep 全仓引用）+ 仓库顶层全量盘点 + 设置页逐条扒取。以下为 v1.0 之后**新发现**的遗漏项。

| # | 新增遗漏项 | 证据 | 归属批次 |
|---|-----------|------|---------|
| 1 | **本地图片/转码代理服务器 `DoubanImageProxyServer`（2900+ 行，启动即启）** —— 豆瓣图片代理 + **夸克 m3u8 转码代理** + **lusushequ m3u8 代理**；被 `JSHTTPBridge` / `TMDBService` / `DoubanService` / `CloudDriveManager` / `LusushequService` 复用 | `Services/DoubanImageProxyServer.swift`、`App/VBoxApp.swift:12-31`、`Services/JSHTTPBridge.swift:255` | **C**（与 Go 代理并列的**第二个**本地代理） |
| 2 | **投屏 / AirPlay**（播放器投屏入口） | `Views/PlayerViewsV2_Extensions.swift:385-499`（`AirPlayViewV2`） | **C** |
| 3 | **非 AVPlayer 内核的浮动小窗播放**（VLC/MPV 内核浮窗：截图更新 / 拖拽 / 双击恢复全屏 / 单击播放暂停） | `Views/PlayerViewsV2.swift:327-510` | **C** |
| 4 | **网盘精确为 12 家**（在 11 家基础上补 **天翼**） | `Services/CloudDriveManager.swift:63-119` | **F** |
| 5 | **MDTV / 麻豆平台子系统**（顶部动态 Tab + 配置/分类自动加载 + 详情 + 播放链路），**非仅「MDTV 键」** | `Views/MDTVViews.swift:23-108,603-755`、`Services/MDTVService.swift` | **E** |
| 6 | **直播源本地文件导入 / 导出 / 分享**（M3U / TXT 解析、添加本地源、导出自定义源、临时文件 share） | `Views/LiveTVView.swift:434-583` | **E** |
| 7 | **`bundleSourcesEnabled`（内置 JSON 兜底源开关）** | `App/AppSettings.swift:141-143` | **O** |
| 8 | **`defaultManifestURL`（自定义 manifest 地址）** | `App/AppSettings.swift:148-150` | **B / I** |
| 9 | **自定义弹幕源设置**（开关 + 弹幕 API 地址输入） | `Views/SettingsViews.swift:175-220` | **C / I** |
| 10 | **搜索调试面板开关** | `Views/SettingsViews.swift:175-220` | **I**（开发调试） |
| 11 | **仓库内已存在可复用资产（应复用而非重写）**：`go-proxy/`（Go 代理源码：m3u8/cache/client/export/debug）· `quickjs/`（QuickJS 源码 + `wrapper.c/h`）· `remote-source-repo-template/`（远程源仓库模板：manifest + 全部源 JSON + `domain-monitor` 脚本 + `.github/workflows`）· `conformance/`（fixtures + runner） | 仓库顶层 | **B / C** |
| 12 | **启动序列包含 3 个本地服务**：AliyunPlayer 加载 → **图片代理** → **转封装代理** → **Go HTTP/2 代理** → Node runtime → DB 初始化 | `App/VBoxApp.swift:12-31` | **L / C** |

### 8.1 二轮复核的事实修正

| 项 | v1.0 说法 | **v1.1 修正（实证）** |
|----|----------|---------------------|
| 网盘家数 | 11+ 家 | **12 家**（阿里云盘 / 夸克 / 百度 / 115 / UC / 123 / 139 / **天翼** / 迅雷 / 光鸭 / 蜗牛 / B站） |
| 设置页「播放设置」 | 预期含内核/硬解/连播/PiP 等 | **实测仅 3 项**：自定义弹幕源开关 · 弹幕 API 地址 · 搜索调试面板 → 播放器配置主要在**播放器内菜单**，非设置页 |
| Flutter 工程现状 | 未提及 | 已有 `android/` `macos/` `windows/` `go-proxy/` `quickjs/` `conformance/` `contract/` `lib/` `test/`；**无 `ios/`**（符合 A4 零改造）；`assets/` **为空需填充** |

### 8.2 仍未闭环的问题

| 问题 | 状态 |
|------|------|
| `SangeCategoryView`（三更）顶层入口 | **二轮仍未定位**（仅见内部 `NavigationLink` 到 `SangeListView`，未见任何外部入口）；疑经福利平台路由或为历史遗留 → 执行 H 批次时按「入口可达性」定夺 |
| `Services/` 其余文件是否死代码 | 部分平台服务（Waibi / Duck / YYBox 等）未见直接外部引用，可能经 JSON 配置的 `platformKey` 动态路由 → 需在 H 批次确认 |

---

## 9. 三轮复核补遗（v1.2 新增 15 项）

> 三轮复核方式：**确定性文件级枚举**（不依赖抽样）+ iOS 平台能力/配置审计 + Flutter 侧现状对照。**已达成文件级全覆盖：185 个文件（Views 55 · Services 73 · PlayerCore 34 · WelfareRemote 17 · Models 6）全部枚举出主类型，无未分类文件**。

### 9.1 最关键发现：Flutter 侧既有架构与「四端同 UI」冲突

| 项 | 实证 | 影响 |
|----|------|------|
| **既有三形态 UI 架构** | `lib/presentation/ui_mode/ui_mode_resolver.dart` 已定义 `UiMode { phone, tv, desktop }` + `UiModeController`（同步 `resolve()` / 异步 `resolveWithBridge()`）；`lib/platform/system/system_bridge.dart` 提供 `getUiModeType/hasLeanbackFeature/hasTouchscreen`；`lib/app.dart:198-218` 按 mode 路由到 **三套独立页面** `HomeShelfPage` / `DesktopHomePage` / `TvHomePage` | **与 D3「多端保留统一 UI，仅横竖屏变化」直接冲突** —— 现状是「**每形态一套 UI**」，目标是「**一套 UI + 横竖屏**」 |
| 结论 | 批次 A 不是「新建形态解析器」，而是「**改造既有三形态为横竖双形态 + 收敛为单一页面树**」 | 批次 A 工作量与风险**上调**；须先做架构改造决策，避免边写边返工 |

### 9.2 新增遗漏项（15）

| # | 新增遗漏项 | 证据 | 归属批次 |
|---|-----------|------|---------|
| 1 | **平台能力与配置类工作**（此前完全未覆盖）：iOS `Info.plist` 声明 —— **后台音频**（`UIBackgroundModes: audio`）· **ATS 任意加载 + 本地网络** · **文件共享/文档就地打开**（`UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace`，备份导入导出依赖）· **相册权限** · `LSApplicationQueriesSchemes`（外部 App 探测）· **方向声明 portrait + landscape（含 iPad）** | `vbox/Info.plist:23-76` | **新增 §14 平台配置** |
| 2 | **MPV 多渲染管线**：`MPVKitMetalLayer`(CAMetalLayer) · `MPVKitRenderView`(UIView) · `MPVKitRenderedPlayerCore` · `MPVRenderContextPlayerCore` · `LibmpvMoltenVKPlayerCore` · `MDKRenderView`(MTKView) | `vbox/PlayerCore/*` | **C** |
| 3 | **3 个播放器 UIKit 桥接视图**：`AliPlayerRepresentable` · `IJKPlayerRepresentable` · `MDKPlayerRepresentable` | `vbox/Views/*Representable.swift` | **C** |
| 4 | **3 个 MPV 调试视图**：`MPVKitDebugPlayerView` · `MPVRenderContextDebugView` · `LibmpvMoltenVKDebugView` | `vbox/Views/*Debug*.swift` | **P**（开发调试） |
| 5 | **转封装代理端口固定 `127.0.0.1:18081`**，与主代理隔离；MKV/FLV → fMP4 **只换容器不重编码**；MP4/未知透传 | `PlayerCore/RemuxProxyServer.swift:5-31,224-315`、`StreamRemuxer.swift:29-48` | **C**（含端口规划） |
| 6 | **`VTDecoderSession` 专服务 PiP 硬解**（H.264/H.265 → CVPixelBuffer，VideoToolbox） | `PlayerCore/VTDecoderSession.swift:5-10` | **C** |
| 7 | **MPV 后端用户可见选项**：自动 / MPV / **自由度（libmpv）** | `PlayerCore/MPVBackendType.swift:3-22`、`MPVBackendFactory.swift` | **C / I** |
| 8 | **网盘登录模式细化**：`TokenWebView`（Token 获取 WebView）· `NodeLoginViews`（光鸭/蜗牛 **短信验证码**登录）· `BiliQrLoginView`（B站扫码）· `AliyunPgQrLoginView`（阿里 PG 扫码） | `vbox/Views/*.swift` | **F** |
| 9 | **百度网盘专用代理链路**：`BaiduProxyClient` + `BaiduWebViewBridge` | `vbox/Services/Baidu*.swift` | **F** |
| 10 | **`MediaURLChecker`（媒体 URL 可用性探测，播放前校验）** | `vbox/Models/MediaURLChecker.swift` | **C** |
| 11 | **图片加载组件与模式**：`PlatformImageLoader`(`PlatformImageMode`) + `PlatformAsyncImage`（含"神秘电影 / 每日大乱斗 / 源封面"分支） | `vbox/Models/`、`vbox/Views/PlatformAsyncImage.swift` | **A** |
| 12 | **福利额外视图**：`XJSPWelfareMainView` · `WelfareSpiderHomeView` · `RemoteWelfareGateView` · `WelfareTabGateView` · `UnsupportedPlatformView` · `FuliVideoBridgeView` · `ComicDetailBridgeView<Service: FuliPlatformService>`（**泛型绑定福利平台**）· `FuliPlatformMainView`(含 `CategoryTabStateCache`) | `vbox/Views/`、`vbox/WelfareRemote/` | **H** |
| 13 | **豆瓣并发服务**：`DoubanChartService`（`actor` 并发）+ `DoubanHomeView` / `DoubanRankingView` / `DoubanCategoryBrowserView` | `vbox/Services/DoubanChartService.swift` | **D** |
| 14 | **音乐视图与服务细化**：`MusicView`(`MusicTab`) · `MusicPlayerViews`(`MiniPlayerBar`) · `MusicPlaylistService`(`MusicPlatformType`) | `vbox/Views/Music*.swift` | **G / L** |
| 15 | **福利域名/代理存储服务**：`WelfareDomainStore` · `WelfareProxyStore` | `vbox/Services/Welfare*Store.swift` | **H** |

### 9.3 三轮复核完成度声明

| 层 | 状态 |
|----|------|
| 文件级覆盖 | **185/185 枚举完成**（主类型全部确认），无未分类文件 |
| 平台能力/配置 | **本轮新覆盖**（Info.plist 全键 + 3 端所需配置） |
| Flutter 侧现状 | **本轮新覆盖**（lib/ 106 dart · test/ 53 · android/windows/macos 原生目录） |
| 仍为抽样 | `Services/` 73 文件的**实现细节**按职责归类，未逐行精读；跨端**真机行为**未验（须真机） |

---

## 10. 四轮复核补遗（v1.3：契约与数据层）

> 四轮复核方式：契约层真值提取 + iOS 数据层精读 + 资源/原生目录盘点 + Flutter 侧现状对照。**本轮补齐「写代码时手边要有的事实」：键 / 表 / 端点 / 资源 / 端口。**

### 10.1 事实基线（实测）

| 维度 | 实测结果 | 来源 |
|------|---------|------|
| Prefs 契约 | **21 组 / 98 键**，`schemaVersion 1.5`；敏感键 **7 个**（`app_tmdb_proxy_token`、`one_platform_token`、`one_platform_userkey`、`one_platform_uuid`、`quark_device_id`、`baidu_local_pcs_device_id`、`saved_drive_tokens`） | `contract/schema/prefs_keys_v1.json` |
| 分组错位 | 皮肤键 `app_skin_mode` / `app_skin_follows_system` 落在 `_group_log` 组内（语义应属界面/皮肤） | 同上 |
| 契约无「显示模式」键 | 确认 `app_ui_form_override` 为**新增键** → 走 **D17** 契约变更 | 同上 |
| SQLite | `vbox.sqlite3`，**9 张业务表**：`zhanyuan` `apiyuan` `subscription` `favorite` `history` `settings` `jiexisetting` `search_history` `download`；迁移链 **v1 建表 → v2/v3/v4 扩列**；`download` v4 新增 `sourceType` / `engineKey` / `vodId` / `headers` | `vbox/Services/DatabaseManager.swift` |
| Keychain | `SecureCredentialStore` 两套 `service/account`：`credentialService` 与 `tokenService` | `vbox/Services/SecureCredentialStore.swift` |
| Node 凭据端点 | `PUT` / `DELETE /website/api/credential/:provider/:field`；`GET /website/api/credentials`（12 网盘 + B站 provider 字段映射） | `vbox/Services/NodeCredentialSyncService.swift` |
| 本地端口 | 图片/转码代理（`DoubanImageProxyServer`）· **转封装 `127.0.0.1:18081`** · Go HTTP/2 代理 | `PlayerCore/RemuxProxyServer.swift` 等 |
| 契约配套产物 | `manifest_v1.json` · `site_v1.json` · `welfare_v1.json` · `schema_v1.sql` · `android-compat.md` · `bug_report_template.yaml` | `contract/` |

### 10.2 D6（第 2 轮决策 · Spider 引擎口径）—— **已定：三端均集成 JavaScriptCore**

> **编号说明**：本节为**第 2 轮范围决策 D6**。登记进主方案时**须使用主方案的下一个空闲编号 `D31`** —— 主方案 **D6 已被「播放器策略」占用**（`VBOX_PLAN_v6.35.md:469`），沿用会造成决策号语义碰撞（同 P.13 曾出现的 `TODO(D21)` 问题）。**✅ 已随主方案 v6.32 登记为 `D31`（2026-10-01）。**
> **决策日期**：2026-10-01（老板选定方案 ③）。

**实测事实（修正 v1.3 初稿口径）**：

| 项 | 实测 |
|----|------|
| `SpiderEngineType` 枚举 | **只有 4 类**：`javaScriptCore` / `quickJS` / `node` / `nodeLX`（`vbox/Services/SpiderEngineProtocol.swift:39-55`） |
| 第 5 个引擎实现 | `PythonSpiderEngine: SpiderEngineProtocol`（`vbox/Services/PythonSpiderEngine.swift:44`）**不在枚举内**，故「5 引擎」= 枚举 4 类 + Python 实现 |
| **JSC 的实际地位** | **主引擎**，非可选：`SpiderManager` 按 `for engineType in [.javaScriptCore, .quickJS]` **先 JSC、失败再 QuickJS**（`vbox/Services/SpiderManager.swift:1078,1649`） |
| JSC 接入方式 | `import JavaScriptCore`（Apple 系统框架）+ `JSContext` 执行本地 `.js` 站点脚本（`vbox/Services/JSSpiderEngine.swift:2`） |
| **平台可用性** | JavaScriptCore **仅 Apple 平台**：**macOS 有**（系统框架，可直接用）、**iOS 有**；**Android / Windows 没有** |

**决策依据：两引擎能力并不对等（实测对比）**

| 能力 | JSC 桥（`JSSpiderEngine.swift` + `JSHTTPBridge.swift`） | QuickJS 桥（`QuickJSBridge.m` + `QJSSpiderEngine.swift`） |
|---|---|---|
| HTTP 编码链 | **GBK / GB2312 / GB18030 / Big5 + 回退循环** | **仅 UTF-8 → ASCII** |
| `sslBypass` | ✅ 专用 URLSession + SSL 绕过 | ❌ 无 |
| `atob` / `btoa` | ✅ | ❌ **未注册** |
| `console.log` / `print` | ✅ 真实转发日志 | ⚠️ **空函数占位**（日志全丢） |
| `req` 别名 | ✅ | ❌ |
| `http` 第二参 | 接收**对象** | 只认**字符串**（`JS_IsString`；传对象则 headers/method/data/timeout **静默丢弃**） |
| `crypto.*` | ✅ AES/RSA/MD5/SHA256/HMAC/base64/hex/uuid | ✅ 同集合（C 实现） |

→ **结论**：QuickJS 在 iOS 中是一条**功能不完整的降级路径**；JSC 才是能力完整的主引擎。因此「三端统一用 JSC」有**实质收益**（脚本零改写、与 iOS 主路径行为一致、且无需把 QuickJS 桥补齐到同等能力）。

**决策（D6 · 2026-10-01）**

> **三端（Android / Windows / macOS）均集成 JavaScriptCore，作为 JS 站点脚本主引擎；QuickJS 保留为降级备份。**

**成本矩阵**

| 端 | JSC 落地成本 | 说明 |
|----|-------------|------|
| **macOS** | **零** | 系统自带 `JavaScriptCore.framework`，直接调用 |
| **Android** | **低** | 有社区预编译产物（`.so` + 头文件），接入 JNI/CMake 即可 |
| **Windows** | **高 —— 唯一硬骨头** | 无成熟预编译 JSC；须 MSVC 自建 WebKit JSC（或改用已 EOL 的 ChakraCore / 另引 V8）→ **设门禁任务 Q-01 先评估** |

其他影响：**包体**（JSC 单 ABI `.so` 为 MB 量级，QuickJS 为亚 MB~1MB 量级，以实测为准）· **许可**（JSC 长期属 LGPL 系，闭源侧载分发须核对合规，动态链接 + 可替换性）· **构建链**（Android NDK/JNI + Windows MSVC/CMake 两套长期维护）· **测试**（conformance 须覆盖 2 个 JS 引擎）。

**风险与降级预案**

| # | 风险 | 预案 |
|---|------|------|
| 1 | **Windows 自建 JSC 不可行** | Q-01 门禁不通过 → 触发降级：**Windows 用 QuickJS，Android/macOS 用 JSC**（与另两端行为有差异，**须回老板重新确认**） |
| 2 | 包体增大超预期 | Q-06 登记体积；必要时按 ABI 拆分或改用动态下载（注意 D11 侧载约束） |
| 3 | LGPL 合规 | Q-06 出合规结论；必要时改为动态链接 + 声明可替换 |
| 4 | 双引擎行为差异 | B-12 conformance **双引擎双跑**，主/降级结果须一致 |

**必须配套的 6 项桥接能力（与引擎选择无关，无论选谁都须实现）**

`console`/`print` 真实输出 · `atob`/`btoa` · `req` 别名 · **对象式 `options` 归一** · GBK/Big5 编码链 · `sslBypass`（仅福利）
→ 落为任务 **B-05a**（JS 全局 API 桥）与 **B-09**（HTTP 桥）；JSC 侧已有现成实现，**直接移植**即可。

### 10.3 Flutter 侧现状（决定「新建 / 改造 / 复用」）

| 已有基建 | 文件 | 对计划的影响 |
|---------|------|-------------|
| QuickJS 引擎 + FFI | `lib/platform/runtime/quickjs_bridge_engine.dart`、`quickjs_ffi.dart` | 批次 B **复用** |
| Node 桥 + HTTP 客户端 | `lib/platform/spider/node_bridge_engine.dart`、`node_http_client.dart` | 批次 B **复用** |
| Python 桥 | `lib/platform/spider/python_bridge_engine.dart` | 批次 B **复用** |
| 引擎工厂 + ABI | `lib/platform/spider/spider_engine_factory.dart`、`spider_abi.dart` | 批次 B **扩 ABI** |
| 播放器通道桥 | `lib/platform/player/channel_player.dart`、`player_channel_bridge.dart`、`player_controller.dart` | 批次 C **改造** |
| UI 形态判定 | `lib/presentation/ui_mode/ui_mode.dart`、`ui_mode_resolver.dart` | 批次 A **改造**（三形态 → 双形态） |
| 已有页面 | `phone/home_shelf_page.dart`、`phone/remote_source_page.dart`、`desktop/desktop_home_page.dart`、`tv/tv_home_page.dart`、`widgets/backup_page.dart`、`widgets/detail_page.dart`、`widgets/library_views.dart`、`widgets/log_viewer_page.dart` | 批次 A/D/N/P **改造** |
| macOS 播放器插件 | `macos/Runner/PlayerPlugin.swift` | 批次 C **复用** |
| **Windows 播放器插件缺失** | `windows/runner/` 仅默认文件 | 批次 C **新建**（C++ 插件） |
| **`assets/` 为空**（仅 `.gitkeep`） | `assets/.gitkeep` | 批次 A **补资源** |
| 已有 UI 基准图 | `docs/ui_baseline/` 8 张（tokens / phone 首页·搜索·详情·播放器·我的 / desktop / tv） | 批次 A 视觉回归 **可用起点** |

### 10.4 资源清单（需内置项）

- **JS 脚本**：`js/lib/` 下 `cheerio.min.js` `net.js` `similarity.js` `utils.js` `zhanyuan_spider.js` `模板.js`，另 `js/lib/native_bridge/测试蜘蛛.js` 与 `js/tetui_spider.js`
- **JSON**：`js/default_subscribe.json` · `js/ibox_sources.json`（**与 `Resources/ibox_sources.json` 重复两份**）· `video_sources.json`
- **Node 运行时**：`noderuntime/` 下 `main.js`、`lx/lx-bridge.js`、`bundles/kstore_index.js`、`db.json`、`default.db.json`、`node-intl-polyfill.js`、`wexfnwconfig.json`
- **Python 标准库**：`python-stdlib/base/spider.py`、`__init__.py`
- **直播源**：`default_live.m3u` · `live_default.m3u`（**两份 m3u**）
- **品牌资源**：`Fonts/MaShanZheng-Regular.ttf` · `Assets.xcassets` 下 `splash_letter_V/b/o/x.png` · `splash_swoosh.png` · `AccentColor`

### 10.5 四轮复核完成度

| 层 | 状态 |
|----|------|
| 契约 / 数据层 | **本轮新覆盖**（98 键 / 9 表 / Keychain / 端点 / 端口） |
| Flutter 现状 | **本轮新覆盖**（已有基建盘点 → 新建 / 改造 / 复用三分） |
| 仍为抽样 | `Services/` 各服务的**逐行实现细节**与**跨端真机行为**（须真机） |

---

> **版本历史**
>
> | 版本 | 日期 | 变更 |
> |---|---|---|
> | v1.0 | 2026-10-01 | 首版：iOS 全量复核（189 Swift 文件）→ 遗漏 41 项 → 新增批次 L–P + 既有批次 B/C/F/G/H/A/I 范围修订 + E.10b 追加要求 |
> | v1.1 | 2026-10-01 | 二轮复核补遗：逐文件核验入口可达性 + 仓库顶层盘点 → **新增 12 项遗漏**（图片/转码代理服务器、投屏 AirPlay、浮窗播放、网盘 12 家、MDTV 子系统、直播源导入导出、bundleSourcesEnabled、defaultManifestURL、弹幕自定义源、搜索调试面板、可复用资产 go-proxy/quickjs/remote-source-repo-template、启动三代理）；修正网盘家数为 12、播放设置实测条目、Flutter 工程现状 |
> | v1.2 | 2026-10-01 | 三轮复核补遗：**确定性文件级枚举达成 185/185 全覆盖**；**新增 15 项**（平台能力与配置类工作、MPV 多渲染管线、3 播放器桥接视图、3 MPV 调试视图、转封装端口 18081、PiP 硬解、MPV 后端"自由度"选项、网盘登录模式细化、百度专用代理、MediaURLChecker、图片加载组件、福利额外视图、豆瓣并发服务、音乐视图、福利域名/代理存储）；**关键发现：Flutter 既有 `UiMode{phone,tv,desktop}` 三形态架构与 D3「四端同 UI」冲突，批次 A 应为"改造"而非"新建"** |
> | v1.3 | 2026-10-01 | **四轮复核（契约与数据层）**：提取契约真值（**21 组 / 98 键**、敏感键 7、无「显示模式」键）、iOS 数据层（**`vbox.sqlite3` 9 表 + 迁移链 v1→v4**、Keychain 两服务、Node 凭据端点、转封装端口 18081）、资源清单（JS/Node/Python/直播源/品牌字体）与 **Flutter 侧现状三分（新建/改造/复用）**；**关键发现：D4「5 引擎含 JavaScriptCore」在 Flutter 侧不可落地 → 新增决策 D6（改为 5 类站点模式 × 4 类 Flutter 运行时）**；确认 `assets/` 为空、Windows 播放器插件缺失、macOS `PlayerPlugin.swift` 已有 |