# VBox 更新日志

> 自动生成于每次 CI 构建，记录所有功能变更和修复。

---

## 2026-07-10

### 修复
- **神秘电影**: 修复 `MysteryMovieMainView` 缺少 `import AVKit` 导致编译失败
- **神秘电影**: 修复播放 404 — m3u8 URL 从硬编码改为从详情页 HTML 动态抓取，支持 4 种提取策略
- **神秘电影**: 修复分类只显示一页 — 分页 URL 改为尝试 3 种格式（`-` / `/` / `?page=`），`hasMore` 阈值从 20 降到 10
- **神秘电影**: 修复 `svc.baseURL` → `svc.host` 编译错误
- **四虎视频 + 香肠派对**: 修复播放失败 — `DoubanImageProxyServer.isAllowedStreamURL` 白名单拒绝四虎/香肠的 CDN 域名，新增 `sihu`/`xcp`/`mystery` provider 跳过白名单
- **神秘电影**: 修复闪退 — `MysteryMoviePlayerView` 重写为 AVPlayer 直接播放，移除 `VodItem` → `VideoDetailView` → `SpiderManager` 崩溃链路
- **XCPService**: `title`/`remarks` 从 `let` 改为 `var`（允许多次赋值）
- **XCPService**: `stringByReplacingMatches` 参数类型修复（`NSString` → `String`）
- **XCPService**: `NSString` 隐式转换修复
- **SihuVideoService**: `currentBaseURL` 从 `private` → `internal`，修复视图层访问
- **XCPService**: `currentHost` 从 `private` → `internal`，修复视图层访问
- **SihuVideo**: 添加 `Equatable` 协议
- **SihuVideoView**: `playEpisode()` 变量名遮蔽修复

### 新增
- **香肠派对**: 完整对接（`XCPService.swift` + `XCPView.swift`），4 分类 + 分页 + AVPlayer 播放
- **四虎视频**: 完整对接（`SihuVideoService.swift` + `SihuVideoView.swift`），54 分类 + 分页 + AVPlayer 播放
- **DoubanImageProxyServer**: 新增 `sihu-stream` / `xcp-stream` / `mystery-stream` 路由

---

## 2026-07-09

### 修复
- **SB聚合**: flv.js 双 CDN 容灾（bootcdn → unpkg）
- **每日大赛**: probeHost JS 跳转页跟进失败后 fallthrough 修复
- **每日大赛**: probeHost 导航页检测（`isNavigationPage()`）+ Case 3 fallthrough 修复
- **每日大赛**: nzmknoycm.cc 302 重定向域名稳定性修复

### 新增
- **福利专区**: 域名设置功能（`WelfareSettingsView` + `WelfareDomainStore`），支持自定义替换失效域名
- **色播聚合**: 新增平台（`SBAggregationService` + `SBAggregationView`），直播聚合分类显示和播放
- **神秘电影**: 平台集成（`MysteryMovieService` + `MysteryMovieMainView`）

---

## 2026-07-08

### 修复
- 每日大乱斗/大赛/神秘电影封面图不显示（`@UA@Referer` 头注入）
- 去除平台顶部分类导航和小分类按钮的背景框
- 每日大赛分类数据不显示（四个问题修复）
- 香蕉秀/DailyBattle UI 去背景 + 短视频滑动修复
- 福利首页 Tab 导航上移 + 浅色模式修复
- 域名设置保存按钮 + 每日大赛导航页线路自动发现

### 新增
- 每日大乱斗平台集成（`DailyBattleService` + `DailyBattleMainView`）
- 每日大赛平台对接（复用 DailyBattleService 多站点架构）
- 观看历史和收藏弹窗支持左滑删除

---

## 2026-07-07

### 重构
- 福利页 UI 重设计 + 24 个 Python 爬虫平台对接
- 福利页移除非核心平台代码，保留 MissAV / 香蕉秀
- 长按排序功能恢复
- 直播播放走代理

### 新增
- 福利设置页增加直播代理地址配置
- 22 平台路由 + 皮肤适配

---

> 📝 此日志由 CI 自动维护，每次构建时从 git commit 历史生成。
> 最后更新: 2026-07-10
