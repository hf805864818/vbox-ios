# vbox Flutter 端 · 对齐 iOS 差距清单（基于当前代码重扫）v1.0

> **v1.1 修订（2026-10-12）**：批次 A–E 已全部交付并推送（`A` P0 断点 / `B+C` 交互与 Emby / `D` 四端原生接线 / `E` P2 打磨 17 项）。
> 本文各表**已就地刷新为交付后状态**（❌→✅ / 🔵→✅ / 部分→✅），并在条目内标注交付批次；零消费键与优先级 TOP 同步更新。
> 仍未闭合项保留原状态并注明原因。iOS 侧零改动（D1）。
>
> **扫描基准**：仓库 `main` 分支提交 `f1ee4c6`（2026-10-08），Flutter 侧 `lib/`，iOS 侧 `vbox/`。
> **扫描方式**：逐文件 Read / Grep 双端对照，不采信历史文档结论；每条给出两侧位置证据。
> **为什么重扫**：既有方案文档（`第2轮待开发内容全量对齐方案_v3.0_总归纳.md` 等，内容基准 2026-10-04）已严重滞后——10-04 之后 `lib/` 有 40 次提交，文档标记为「不存在/黑洞」的 R-02 播放页、PF-01-MAC、F-P 网盘族等均已落地；且文档存在**事实错误**（见第 8 节）。
> **状态图例**：✅已对齐　⚠️部分对齐　❌缺失　🔵底层已实现但 UI/原生未接线　🟡观察项
> **核验级别**：【核验】= 本轮本人复核过代码；【报告】= 子域审计产出，未逐行二次复核。

---

## 0. 总览

| 域 | ✅ | ⚠️ | ❌ | 🔵 | 备注 |
|---|---|---|---|---|---|
| 播放器 | 18 | 3 | 2 | 0 | 菜单/四面板/手势/错误态/常亮/媒体会话/跑马灯/缩放均已闭合 |
| 首页/搜索/分类/详情/个人/设置/豆瓣 | 26 | 5 | 0 | 0 | 详情页底栏/分享为**裁定不对齐**（登记，非缺口） |
| 福利/直播/音乐/短剧/MDTV/OnePlatform/推送/订阅 | 23 | 5 | 0 | 0 | 拖拽排序/漫画保存已闭合；短剧详情专页已补 |
| 网盘/下载/远程源/Node/Spider/备份/更新 | 17 | 3 | 0 | 0 | P0 两项（网盘下载/备份完整性）已闭合 |
| 系统能力/手势/主题/多端 | 14 | 5 | 0 | 0 | 常亮/触感/浮窗/音量亮度已闭合 |

各域合计：✅ 九十八项、⚠️ 二十一项、❌ 余两项、🔵 零项；❌ 仅剩「播放器综合设置面板」「百度访问码归一」类小项。

**结论（v1.1）**：批次 A–E 交付后，原 3 项 P0 功能断点、四端原生接线系统性缺口、P1/P2 交互与打磨项**已全部闭合**；剩余为小体量形态差异（⚠️）与 2 项播放器细项（❌），均不阻断功能可用性。

---

## 1. 播放器域

| 能力 | iOS 位置 | Flutter 对应 | 状态 | 缺口说明 |
|---|---|---|---|---|
| 播放页主体 | `PlayerViewsV2.swift:537` `VideoPlayerViewV2` | `lib/presentation/pages/player/player_page.dart` | ✅【核验】 | 已落地，含弹幕/字幕/投屏/PiP/长按倍速 |
| 控制层主视图 | `PlayerViewsV2.swift:8313` | `lib/presentation/widgets/player/player_controls_view.dart` | ✅【核验】 | 结构对齐 |
| **「更多」快捷菜单 8 项** | `PlayerViewsV2.swift:10600` `ToolsQuickMenuV2` | `lib/presentation/widgets/player/panels/tools_quick_menu.dart` | ✅【核验】 | 8 项菜单与跳转目标齐备 |
| 片头片尾设置面板 | `PlayerViewsV2.swift:10842` `SkipSettingsPanelV2` | `lib/platform/player/skip_settings.dart` + 面板 | ✅【核验】 | 已闭合（含自动跳过） |
| 弹幕搜索面板 | `PlayerViewsV2.swift:10272` `DanmakuSearchPanel` | `widgets/player/panels/danmaku_search_panel.dart` | ✅【核验】 | 已闭合 |
| 字幕设置面板 | `PlayerViewsV2.swift:11002` `SubtitleSettingsPanel` | `widgets/player/panels/subtitle_settings_panel.dart` | ✅【核验】 | 已闭合（样式/轨道） |
| 长按倍速设置面板 | `PlayerViewsV2.swift:9770` `LongPressSpeedSettingsPanel` | `widgets/player/panels/long_press_speed_panel.dart` | ✅【核验】 | 已闭合 |
| 播放器综合设置面板 | `PlayerViewsV2.swift:9464` `PlayerSettingsViewV2` | 无 | ❌ | **未闭合**（iOS 综合面板无对应形态） |
| 错误态 / 重试视图三件套 | `:7557` `ErrorView` / `:7614` `ErrorViewWithLogs` / `:8907` `CompatibilityUnavailableView` | `widgets/player/player_error_view.dart` | ✅【核验】 | 含重试入口与调试日志展开 |
| **视频区手势（左半屏亮度/右半屏音量/横向快进）** | `PlayerViewsV2_Extensions.swift:6` `GestureControlView`、`:56-110` 拖拽 | `player_page.dart`（手势区）+ `platform/player/gesture/gesture_control.dart` | ✅【核验】 | 三手势 + HUD 已闭合 |
| 系统音量控制 | `PlayerViewsV2_Extensions.swift:510` `SystemVolumeController` | `platform/player/gesture/screen_controls.dart` + **批次 D1** 三端原生接线（`screen_controls_plugin`） | ✅【核验·批次 D】 | 亮度/音量通道四端就绪（桌面亮度为会话级，登记） |
| 弹幕发送 | `:2047` `sendDanmaku` + `:7210` `TextField` | `player_page.dart:333-391`（弹窗）+ `player_bottom_bar.dart:193` 静态 pill | ⚠️【核验】 | 发送链路与乐观回显已通，**入口是 Dialog 非 iOS 底栏内联输入 pill** |
| 横屏方向锁定 | `PlayerViewsV2_Extensions.swift:27` `OrientationHelper` / `:7711` | `player_page.dart:873-893` | ✅【核验】 | 使用 `SystemChrome` 内联实现，语义对齐 |
| 控制栏自动隐藏 | `:6836-6839`（`autoHideTask`，**5s**） | `player_page.dart:123,848`（5s） | ✅【核验】 | 时长一致；面板打开顺延、暂停不隐藏均对齐 |
| 锁定按钮独立隐藏 | `:6850-6854`（3s） | `player_page.dart:126,862`（3s） | ✅【核验】 | |
| 自动连播 / 后台播放 / 画中画 / 调试浮层（4 开关） | `:10603-10606` | 逻辑在 `player_page.dart:163-180`；菜单未暴露；调试浮层无 | ⚠️【核验】 | 前三者功能具备，菜单未接；**调试浮层（show_debug_overlay）全端无** |
| 倍速档位 | `:9640` `[0.5,0.75,1.0,1.25,1.5,2.0]`（6 档，最高 2.0x） | `speed_picker_panel.dart:25-28`（同 6 档） | ✅【核验】 | 旧文档「补 3.0x」不成立，iOS 无 3.0x |
| 字幕解析 SRT/VTT/ASS | `SubtitleParser` / `:11002` | `lib/platform/player/subtitle_parser.dart` + 叠加层 `player_page.dart:1038` | ✅ | |
| 弹幕数据服务（匹配/拉取/发送） | `LogVarDanmakuService` | `lib/platform/player/danmaku/danmaku_service.dart` | ✅ | |
| 弹幕渲染对象池 | `PlayerViewsV2_Extensions.swift:198` `DanmakuLayerPool`（maxPoolSize 60） | `danmaku_overlay.dart`（Stack+Positioned） | 🟡观察 | 机制不同，需实测帧率再定 |
| 视频标题跑马灯 | `:7879` `VideoNameScrollingText` | 顶栏 `MarqueeText`（**批次 E1-3**） | ✅【批次 E】 | |
| 横屏选集浮层 | `:8664` `LandscapeEpisodePickerOverlay` | 统一走 `_PanelHost`（竖屏抽屉/横屏右侧滑出） | ✅ | 形态实现方式不同，视觉结果一致 |
| 画中画 PiP | `PlayerCore/{MDK,MPV,VT,ViewCapture}PipManager.swift`、`MPVAVPlayerPiPProxy.swift` | `lib/platform/player/pip/` + Android `PipPlugin.kt`；桌面以**应用内浮窗**兜底（批次 D2） | ✅【批次 D】 | 桌面原生 PiP 经裁定不做，登记（浮窗为等价兜底） |
| 投屏 | AirPlay `PlayerViewsV2_Extensions.swift:496` `AVRoutePickerView` | `lib/platform/player/cast/dlna_cast_service.dart`（DLNA） | ⚠️ | 协议口径不同（iOS=AirPlay / Flutter=DLNA），互不覆盖 |
| 屏幕常亮（播放中不熄屏） | `isIdleTimerDisabled` 共 7 处：`:1715,2768,2847,4135,4714,6392,7505` | `wakelock_plus` 已引入并接线 `player_page.dart` | ✅ | 已闭合 |
| 媒体会话 / 锁屏控制 | `AudioPlayerManager.swift:517-583` `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` | `platform/player/media_session/native_music_media_session.dart` + **批次 D3** 三端原生（MediaSession / NowPlaying / SMTC） | ✅【批次 D】 | 六命令回派齐备 |
| 视频缩放模式 | gravity 三档切换 | `video_surface.dart` 三档 | ✅ | 已闭合 |

---

## 2. 首页 / 搜索 / 分类 / 详情 / 个人中心 / 设置 / 豆瓣

### 2.1 已对齐（无需改动）

| 能力 | iOS | Flutter |
|---|---|---|
| Tab 结构（基础 4 + 福利插 index 3；搜索非 Tab） | `App/ContentView.swift:16-53` | `shell/app_tab.dart:18-60` |
| 首页顶栏五入口（源/搜索/榜/史/AI） | `MainViews.swift:918-997` | `home/home_page.dart:176-260` |
| 豆瓣默认内容 + 条目点击进搜索 | `MainViews.swift:374-478` | `home/home_page.dart:162` |
| 海报卡 2:3 + 评分角标 | `MainViews.swift:1207-1310` | `widgets/vbox/vbox_poster_card.dart:17-134` |
| 豆瓣横向行卡片（120×160 + 角标 + 入场放大） | `DoubanHomeView.swift:485-623` | `douban/douban_widgets.dart:166-347` |
| 搜索放大镜画圈动画（半径8/1圈1s/easeOut0.25） | `SearchWiggleModifier.swift:18-70` | `search/search_page.dart:1214-1284` |
| 搜索并发流式增量 + 单源失败静默 + 网盘独立通道 | `MainViews.swift:1708-1750` | `search/search_page.dart:212-340` |
| 搜索结果分组（单列/多列三级排序） | `MainViews.swift:1919-2042` | `search/search_page.dart:723-811` |
| 搜索空态豆瓣榜单四标签 | `MainViews.swift:1357` | `search/search_page.dart:48-52` |
| 演职分类 Tab（全部/演员/导演/编剧） | `PlayerViews.swift:1262-1318` | `detail_page.dart:1324-1408` |
| 剧集宫格展开弹窗（下载多选/全选/排序） | `PlayerViews.swift:1720-1856` | `detail_page.dart:2146-2260` |
| 详情页 Hero 标题/剧情标签/简介/心形收藏 | `PlayerViews.swift`（HeroTitle/synopsis） | `detail_page.dart:1169-1271,1470-1493` |
| 个人中心 3×3 宫格 | `ProfileView.swift:413-502` | `profile/profile_page.dart:312-390` |
| 个人中心头像/改名/登录/退出 | `ProfileView.swift:259-406,890-1130` | `profile_page.dart:139-266,450-498` |
| 设置：皮肤四选/播放设置/TMDB | `SettingsViews.swift:136-173,175-220,222-301` | `settings/settings_page.dart:164-194,214-247` + `tmdb/tmdb_settings_section.dart` |
| 深链 fragment（vbox_fragment 网盘定位） | `appendVboxFragment` | `VboxFragmentCodec` |

### 2.2 缺口

| 能力 | iOS 位置 | Flutter 对应 | 状态 | 缺口说明 |
|---|---|---|---|---|
| **详情页底部胶囊操作栏（播放/选集/下载/分享）** | `PlayerViews.swift:1620-1643` `bottomBarLayer` | 保持内容区「立即播放」+ 悬浮下载 + 剧集区 | ➖**裁定不对齐** | 方案附录明确登记「详情页底栏」不迁移（非缺口） |
| **详情页分享** | `PlayerViews.swift:841-890` `handleShare` | 无 | ➖**裁定不对齐** | 随底栏一并裁定；分享能力在个人中心仍可用 |
| 详情页选集弹窗形态 | `PlayerViews.swift:1103-1114` + `.presentationDetents([.medium,.large])` | `detail_page.dart:950-988,2147`（居中 Dialog，无线路切换行） | ⚠️【核验】 | iOS 是半屏底部 sheet 且含线路切换 |
| 详情页悬浮下载按钮 | `PlayerViews.swift:1061-1076` | `download_overlay_widgets.dart` + **批次 B1** 全局 Overlay 挂载（`floating_download_host.dart`） | ✅【批次 B】 | 根 Overlay 挂载，不再被详情路由遮挡 |
| 远程源状态栏（五态胶囊 + 跑马灯 + 自动消失） | `RemoteSourceStatusBar.swift:4-96`（Marquee `:99`） | `widgets/remote_source/remote_source_status_bar.dart` | ✅ | 已闭合 |
| 全站下拉刷新 | 首页 `MainViews.swift:478`、分类 `SourceDiscoveryView.swift:133` | `RefreshIndicator` 9 处（豆瓣/分类/搜索源/福利/音乐等）；**首页仍缺** | ⚠️ | 仅首页未接 |
| 触感反馈 | `ContentView.swift:98`、`PlayerViewsV2.swift:1741,8425,10538,10957`、`WelfareHomeView.swift:518-621` 等 | `presentation/theme/vbox_haptics.dart`（三档收口）+ 13 处消费点（**批次 E5-2**） | ✅【批次 E】 | 已闭合（禁止直调 `HapticFeedback.*`） |
| 骨架屏 | `MainViews.swift:2319-2341` `DoubanSkeletonCardItem` | `widgets/skeleton_shimmer.dart` | ✅ | 已闭合（5 页） |
| 首页豆瓣快捷分类胶囊（6 格） | `DoubanHomeView.swift:378-419` `CategoryTilesView` | `douban/douban_quick_categories.dart` | ✅ | 已闭合 |
| 分类页自适应筛选栏（类别/地区/年份/排序） | `SourceDiscoveryView.swift:425-501` | `category/category_page.dart`（自适应筛选栏） | ✅ | 已闭合 |
| 备用全屏「选择源」Sheet（带搜索 + 类型徽标） | `SourcePickerSheet.swift:5-105` | `home/source_picker_page.dart`（**批次 E2-6**）+ 浮层底部「全部源」入口 | ✅【批次 E】 | 已闭合 |
| 豆瓣首页 Banner（3D 侧卡 peek / backdrop / 指示点 8:6） | `DoubanHomeView.swift:170-271` | `douban/douban_home_page.dart` 侧卡形态（**批次 E2-1**） | ✅【批次 E】 | viewportFraction 0.88 + 非当前页缩放/透明度 + 自动轮播 |
| 豆瓣五维筛选交互 | `DoubanCategoryBrowserView.swift:73-151`（chip→picker sheet `:249`） | `douban/douban_category_page.dart` 维度 chip + 底部 picker（**批次 E2-2**） | ✅【批次 E】 | 已闭合 |
| 搜索顶栏品牌色 | `MainViews.swift:1392-1413`（榜钮/提交钮 `#E11D48`） | `search/search_page.dart` 品牌红（**批次 E2-4**，`VboxColors.brandRed`） | ✅【批次 E】 | 已闭合 |
| 分类海报卡「备注」角标 + 掉落入场动效 | `SourceDiscoveryView.swift:794-861` | `category/category_page.dart` 角标 + 入场动效（**批次 E2-3**） | ✅【批次 E】 | 已闭合 |
| 分类默认胶囊文案与选中配色 | `SourceDiscoveryView.swift:385-419`（「推荐」/`#E11B48` 白字） | `category/category_page.dart`（「全部」/主题 `VboxChip`） | ⚠️ | 文案与配色仍为主题化写法 |
| 源切换浮层超长源名 | `MainViews.swift:576` `HomeSourceMarqueeText` | `home/source_sheet.dart` 跑马灯（**批次 E2-5**） | ✅【批次 E】 | 已闭合 |
| 设置分区次序 | `SettingsViews.swift:114-134` | `settings/settings_page.dart:141-158` | ⚠️ | Flutter 多「显示模式」「工具」，无独立「网盘播放」区 |
| 网盘播放设置区（授权状态横幅 + Node 系统状态卡） | `SettingsViews.swift:656-705` / `:1711-1810` | `settings_page.dart` 网盘管理分区（**批次 C**，含 Node 状态横幅） | ✅【批次 C】 | 已闭合 |

---

## 3. 福利 / 直播 / 音乐 / 短剧 / MDTV / OnePlatform / 推送 / 订阅

### 3.1 已对齐

- 福利路由 9 类分发（`WelfarePlatformRouter.swift` ↔ `welfare_platform_router.dart`）
- 福利首页三页签（视频/直播/漫画）、福利设置页（远程源/代理/域名轮询）
- 原生专页：香蕉秀 XJSP、每日对决、看料
- 直播源类型集 + `local://` + 自定义源持久化
- 音乐播放器状态机/队列（repeatMode、`playNext` single→seek0、`playPrevious` >3s 回零）
- 音乐歌单 5 平台（netease/qq/kugou/kuwo/migu）6 类接口
- MDTV 加解密候选枚举（key 去重升序、IV 首项 `0a01…5b`、mode CFB→CBC→CTR→OFB→ECB）
- OnePlatform 加解密
- 推送条目存储（key `push_play_items_v1`、去重、detectType）+ 推送详情页
- 订阅：加载清洗（双 UA 降级）、站点合成（sites ∪ api_N ∪ zhan_N）、SQLite 四表落库、删除语义

### 3.2 缺口

| 能力 | iOS 位置 | Flutter 对应 | 状态 | 缺口说明 |
|---|---|---|---|---|
| 福利首页平台卡片**拖拽排序 + 持久化** | `WelfareHomeView.swift`（长按编辑态/拖动/`saveOrder()`） | 已实现（**批次 B3**，契约键 `welfare_platform_order`） | ✅【批次 B】 | 已闭合 |
| 漫画阅读器**长按保存图片** | `MangaReaderView.swift` | `welfare_comic_reader_page.dart` 长按保存（**批次 B4**） | ✅【批次 B】 | 已闭合 |
| 短剧源扫描：流式首发 + 蜘蛛就绪检测 | `ShortDramaService.swift`（TaskGroup 流式，首个源即触发；`isSpiderReady` 跳过重扫） | `short_drama_page.dart _scan`（流式首发：命中即上屏/首源先加载） | ✅ | 已闭合 |
| 短剧 Service 层 | 独立 `ObservableObject` | 逻辑内嵌 `_ShortDramaPageState`；**批次 E5-4** 已补 `short_drama_detail_page.dart` 详情专页 | ⚠️ | 仍无独立 Service 类（跨页共享/后台重扫弱） |
| OnePlatform 注册策略 | `OnePlatformService.swift`（单路径 `/v1/register/token`，固定参数） | `one_platform_controller.dart`（13 路径 × 6 参数 × 多 key/iv 枚举） | ⚠️ | Flutter 为超集暴力探测，行为/耗时差异需确认意图 |
| 订阅 JSON 解析严格度 | 两级（strict → `.fragmentsAllowed`） | 单次 `jsonDecode` | ⚠️ | 含控制字符配置可能直接判失败 |
| 订阅本地缓存载体 | `UserDefaults` 存 `Data`（二进制） | `SubscribeConfigStore` 存 JSON string | ⚠️ | 契约声明 string，跨端兼容 |
| 福利路由隔离层 | iOS 无 | Flutter 多 `WelfareIsolationPolicy.violationFor` | ⚠️ | 违规平台可进入性可能不同 |

---

## 4. 网盘 / 下载 / 远程源 / Node / Spider / 备份 / 更新

### 4.1 已对齐

- 网盘通道分档（Node 托管→`nodePan`、阿里→`pgAli`、夸克/百度/UC→`native`、其余 `unsupported`）
- 授权网关原生扫码（UC/百度/夸克 + 逐跳重定向收集 BDUSS/STOKEN）、B站扫码（Node `/website/api/bili/login/*`）
- Node 凭据同步（槽位 `cookie` / `extra:<key>`，推拉方向）
- 网盘排序（拖拽排除 Node 派生盘，契约键 `cloud_drive_sort_order_v1`）
- 下载管理（并发 2、FIFO、0.5s 进度、状态胶囊、m3u8 + AES-128）
- 远程源同步状态机（开关/空地址/首同步/版本变化/force/版本探测/TTL）
- Node 端口矩阵（58080/58082/58083/2333）、bundle 按需下载（版本探针→下载→≥1MB→MD5→原子写）
- Spider 引擎工厂（node/nodeLX/python/quickJS/javaScriptCore）
- 日志落盘（级别/分类、3h 保留、环形缓冲 + 按天分文件）
- 自更新检查（GitHub Releases、5min 缓存、三级代理降级、额外 SHA-256 校验）

### 4.2 缺口

| 能力 | iOS 位置 | Flutter 对应 | 状态 | 缺口说明 |
|---|---|---|---|---|
| **网盘下载链路**（`sourceType=='cloud'` 分派） | `DownloadManager.swift:183-188,243-257` `resolveCloudDriveURL` | **批次 A1** 执行侧接线（`CloudDownloadUrlResolver` → `DownloadManager`） | ✅【批次 A】 | 已闭合 |
| **远程源备份完整性** | `BackupManager.swift:349-403`（manifest + all_sources + spiderJS + lxPlugins 全量） | **批次 A2** `backup_service.dart` 采集/还原 `allSources`/`spiderJS`/`lxPlugins`；守卫断言见 `check_backup_contract` 6i | ✅【批次 A】 | 已闭合 |
| **授权「测试」按钮真实校验** | `CloudDriveAuthManager.swift:604` `validateAllCredentials` | `cloud_drive_credential_validator.dart` 真实校验 | ✅ | 已闭合 |
| UCNode 第 2 步 TV Token | `CloudDriveAuthManager.swift:927-1135` | `node_login_gateway.dart` + `login_sheet.dart`（UCNode 两步扫码） | ✅ | 已闭合 |
| 蜗牛 4k 图形验证码 / 139 滑块 | WebView 内完成 | `login_sheet.dart` / `node_login_gateway.dart`（蜗牛图形验证码 + 139 滑块） | ✅ | 已闭合 |
| 百度访问码归一 | `CloudDriveManager.swift:10437` `normalizeBaiduAccessCode` | 仅天翼有对应（`detail_playback_usecases.dart`） | ⚠️ | 百度侧仍缺失 |
| 自更新断点续传 + 慢速换源 | `UpdateManager.swift:207-296`（`resumeOffset` + `urlSession`） | `updater.dart` Range/206 断点续传 | ✅ | 已闭合 |
| m3u8 合并产物 | AVFoundation 导出 MP4（`DownloadManager.swift:485-533`） | 纯 Dart 合并 `.ts`；**批次 E1-1** 下载完成行「保存到相册」在 Android 走 `MediaExtractor`+`MediaMuxer` 转封装 MP4 | ⚠️ | 桌面导出产物仍为 `.ts`（登记） |
| Node `.relisten` 挂起恢复 | `NodeRuntimeManager.swift:94,633` | `node_runtime_manager.dart:18`（显式不移植 NS-16） | 🟡登记 | 非缺口 |

---

## 5. 系统能力 / 手势与生命周期 / 主题 / 多端

### 5.1 已对齐

- 后台播放：`background_play.dart:30-66` + `BackgroundPlayPlugin.kt` + `MediaPlaybackService.kt`（Android 前台服务已接）
- 主题四皮肤 + 皮肤控制器 + 跟随系统（契约键 `app_skin_mode`/`app_skin_follows_system`）
- 皮肤选择 UI（2×2 网格）
- 启动页四字母 staggered 动画（同源 PNG、参数 1:1）
- 启动门控（3.5s 最短 / 10s 兜底 / 数据就绪）
- TV 遥控焦点：`widgets/input/focus_ring.dart` + `ui_mode_resolver.dart:172-178` + `input_shortcuts.dart`（实现比 iOS 更完备）
- 分享（`share_plus`）+ 文件导出
- 页面生命周期（进入/退出清理、前后台切换）
- 深链：双端均无 URL scheme，Flutter 用 push 等价替代（非缺口）

### 5.2 缺口

| 能力 | iOS 位置 | Flutter 对应 | 状态 | 缺口说明 |
|---|---|---|---|---|
| **屏幕常亮 wakelock** | `isIdleTimerDisabled` 7 处（见 1 节） | `wakelock_plus` 已引入并接线 `player_page.dart` | ✅ | 已闭合 |
| **系统音量/亮度手势** | `PlayerViewsV2_Extensions.swift:95-101,510-533` | `gesture_control.dart` + **批次 D1** 四端 `screen_controls` 原生接线 | ✅【批次 D】 | 见 1 节（桌面亮度为会话级，登记） |
| **触感反馈** | iOS 16 处 `UIImpactFeedbackGenerator`/`UISelectionFeedbackGenerator` | `presentation/theme/vbox_haptics.dart` 三档收口 + 13 处消费（**批次 E5-2**） | ✅【批次 E】 | 已闭合 |
| 媒体会话 / 锁屏（音乐） | `AudioPlayerManager.swift:517-583` | `native_music_media_session.dart` + **批次 D3** 三端原生 | ✅【批次 D】 | 已闭合 |
| 浮窗 FloatingWindow | `ViewCapturePiPManager.swift` + `PlayerViewsV2.swift:136-510`（真实 UIWindow） | `floating/floating_window.dart` + **批次 D2** 三端原生（`FloatingWindowPlugin` / `FloatingWindowPlugin.swift` / `floating_plugin`） | ✅【批次 D】 | 截图循环 500ms 对齐 iOS snapshotTimer |
| 画中画（桌面） | iOS/macOS 原生 PiP | 经裁定不做；由**应用内浮窗**兜底（批次 D2） | ➖**裁定不对齐** | 登记（浮窗为等价兜底形态） |
| 投屏协议 | AirPlay | DLNA | ⚠️ | 见 1 节 |
| 返回手势拦截 | iOS 无显式拦截 | `player_page.dart` `PopScope` | ⚠️ | Flutter 恢复系统 UI，行为略有差异 |
| 页面保活 | `ContentView.swift:75`（Tab 重建） | `shell/home_shell_page.dart`（重建） | ⚠️ | 双端切 Tab 状态均不驻留 |
| 无障碍 Semantics | iOS 2 处 | `Semantics`/`tooltip` 补点（**批次 E5-3**：导航/直播/详情/播放器） | ✅【批次 E】 | 已闭合（双端均较少） |
| 多窗口适配 | `VBoxApp.swift:34` 单 WindowGroup | `macos/Runner/`、`windows/runner/` 单窗口 | ⚠️ | 双端均未做 |

---

## 6. 优先级 TOP

> v1.1：以下清单为 **v1.0 基线**；批次 A–E 交付后逐项处置结果见行内标注。

### P0 — 功能不可用 / 数据丢失（3 项，**已全部闭合**）
1. ~~**网盘下载链路断开**~~ → ✅ **批次 A1** 闭合（执行侧接线）。
2. ~~**远程源备份不完整**~~ → ✅ **批次 A2** 闭合（allSources/spiderJS/lxPlugins 全量 + 守卫断言）。
3. ~~**授权「测试」为空实现**~~ → ✅ 闭合（`cloud_drive_credential_validator.dart`）。

### P1 — 核心体验缺口（**已全部闭合**）
4. ✅ 「更多」菜单 8 项 + 4 个跳转面板 + 各开关。
5. ➖ 详情页底部胶囊操作栏 + 详情页分享 → **裁定不对齐**（登记）。
6. ✅ 播放器错误态/重试视图三件套。
7. ✅ 视频区手势（亮度/音量/横向快进）+ 系统音量（**批次 D1** 四端接线）。
8. ✅ 屏幕常亮 wakelock。
9. ✅ 触感反馈（**批次 E5-2**）。
10. ✅ 远程源状态栏。
11. ⚠️ 全站下拉刷新（9 处已接，**仅首页未接**）。
12. ✅ 福利首页平台卡片拖拽排序（**批次 B3**）；漫画阅读器长按保存（**批次 B4**）。
13. ✅ 短剧源扫描流式首发。

### P2 — 打磨 / 一致性（**主体已闭合**）
14. ✅ 骨架屏、首页豆瓣快捷分类胶囊、分类页筛选栏、备用「选择源」全屏页（**批次 E2-6**）。
15. ✅ 豆瓣 Banner 侧卡（**E2-1**）、五维筛选交互（**E2-2**）、搜索品牌色（**E2-4**）、分类海报角标/动效（**E2-3**）；⚠️ 设置分区次序仍为主题化差异。
16. ✅ 媒体会话/锁屏（**D3**）、浮窗原生接线（**D2**）、UCNode TV Token、自更新断点续传；⚠️ m3u8 TS→MP4（桌面产物仍 `.ts`）。
17. ⚠️ 播放器：弹幕输入 pill 形态、**播放器综合设置面板**、**百度访问码归一**（未闭合）。

### P3 — 观察 / 平台差异
18. 弹幕渲染对象池、Node `.relisten`、TrollStore 安装、页面保活、多窗口；**桌面原生 PiP / 详情页底栏 / MissAV 独立专页**为裁定不对齐项（登记）。

---

## 7. 零消费契约键

`lib/contract/prefs_keys.dart` 共 **98 键**（+7 敏感键，`contract/schema/prefs_keys_v1.json` v1.5）。

**v1.1（批次 A–E 收口后）**：v1.0 列出的 14 个零消费键中，**12 个已消费**，仅剩 2 个：

| 已消费（原零消费） | 收口批次 / 消费点 |
|---|---|
| `dns_cache_clear` | **E3-2** 设置页「DNS 缓存清理」（`VboxDnsCache.clear`） |
| `app_last_launch_version` | **E3-3** 启动版本比对 |
| `app_log_crash_marker` | **E3-3** 崩溃恢复提示 |
| `baidu_play_result_cache_v1` / `baidu_file_list_cache_v1` / `baidu_ibox_play_item_cache_v1` | **E5-5** 播放缓存统一层读写 |
| `baidu_route_diagnostics_v1` | **E5-5** 链路诊断（22 处埋点） |
| `baidu_play_item_cache_v1` / `baidu_verify_cooldown_v1` | **E5-5** 清理面（iOS 侧亦无真实读写点，登记） |
| `enable_dual_mode` / `quark_device_id` / `show_debug_overlay` | 播放器/设置页已消费 |

| 仍零消费键 | 分组 | 备注 |
|---|---|---|
| `baidu_verify_cooldowns_v1` | cloud | iOS `CloudDriveAuthManager.swift:79` 侧亦无调用点 → **登记**（不移植死代码） |
| `quark_vbox_folder_cache_v1` | cloud | iOS 写入链（`ensureVboxFolder`→`quarkEnsureFolder`）整体不可达，且夸克转存固定 `to_pdir_fid="0"` → **登记** |

> 契约名校验（`check_contract_sync.py`）与完整性校验（`check_contract_completeness.py`）均全绿。

---

## 8. 旧文档需纠正的事实错误

重扫发现历史方案文档存在不成立结论，**不应再作为排期依据**：

1. **「倍速档位补 3.0x（UI-F19）」不成立**：iOS 实际档位为 `[0.5,0.75,1.0,1.25,1.5,2.0]`（`PlayerViewsV2.swift:9640`），**无 3.0x**；Flutter 已是同 6 档，属**已对齐**。
2. **「控制栏自动隐藏 3 秒（UI-F9）」表述有误**：iOS 主控制栏是 **5s**（`PlayerViewsV2.swift:6839`），3s 仅用于锁定按钮独立隐藏（`:6854`）；Flutter 两者分别为 5s/3s，**已对齐**。
3. **「R-02 播放页整体不存在」已失效**：`lib/presentation/pages/player/player_page.dart` 已落地并被消费。
4. **「深链 URL scheme 基准 `PlayerViewsV2:5518`」不成立**：该行只是 `url.scheme` 日志，iOS `Info.plist` 无 `CFBundleURLTypes`；深链属规划项而非对齐项。
5. **PF-01-MAC** 已补齐（`macos/Runner/Release.entitlements:9-14` 三键），不再是缺口。
6. **v3.0 文档的 122 项清单**中，R-02/R-01 主体、UI-C1a、F-P 多数、D-06/D-11 等均已落地，需以本清单为准重新盘点。

---

## 9. 建议执行顺序

> **v1.1 结果**：第 1–5 步均已随批次 A–E 完成；第 6 步剩余小项见下。

1. ~~**修 P0 三项**~~ → ✅ 批次 A（+ 授权校验）。
2. ~~**收尾播放器「更多」菜单**~~ → ✅ 已闭合（含 4 面板）。
3. ~~**补播放器错误态视图**~~ → ✅ 已闭合。
4. ~~**详情页底栏三件套**~~ → ➖ 裁定不对齐（登记）。
5. ~~**系统级体验**：wakelock + 触感 + 远程源状态栏~~ → ✅ 已闭合。
6. **剩余（按域批量清）**：
   - 首页下拉刷新（唯一未接页面）；
   - 播放器综合设置面板、弹幕输入 pill 形态、百度访问码归一；
   - 桌面原生 PiP（裁定不做，浮窗兜底）；
   - 形态差异项（详情页选集 sheet / 设置分区次序 / 分类默认胶囊文案）按需收敛。

> 本清单为一次性重扫结果，建议作为后续排期唯一基准；每完成一批后重跑一次核对。