//
//  WelfareJSSpiderService.swift
//  vbox
//
//  通用福利 JS Spider 服务 — 通过远程 JavaScript 脚本驱动福利平台。
//
//  设计目标：
//  - 新增福利平台只需在远程源 welfare_platforms.json 中配置 + 上传 JS 脚本
//  - 无需修改 vbox 项目代码
//  - 复用 FuliPlatformMainView 自适应框架
//  - 不影响普通蜘蛛资源、网盘播放和其他福利平台
//
//  JS 脚本需实现以下方法（兼容 JavaScriptCore 引擎）：
//  - init(config)           → 初始化（可选）
//  - homeContent(filter)     → { class: [...], list: [...] }
//  - homeVideoContent()      → { list: [...] }（可选）
//  - categoryContent(tid, pg, filter, extend) → { list, page, pagecount, limit }
//  - detailContent(ids)      → { list: [{ vod_id, vod_name, vod_pic, vod_content, vod_play_from, vod_play_url }] }
//  - searchContent(key, quick, pg) → { list, page, pagecount }
//  - playerContent(flag, id, vipFlags) → { parse, url, header }（可选）
//
//  播放处理：
//  - m3u8 URL 自动通过本地 HTTP 代理（SSL 绕过 + Brotli 解压 + key/TS 重写）
//  - 非 m3u8 URL 直接返回
//

import Foundation

final class WelfareJSSpiderService: FuliBaseService {

    // MARK: - 实例缓存

    private static let cache = NSCache<NSString, WelfareJSSpiderService>()

    static func service(for platform: WelfarePlatform) -> WelfareJSSpiderService {
        let key = platform.platformKey as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let svc = WelfareJSSpiderService(platform: platform)
        cache.setObject(svc, forKey: key)
        return svc
    }

    // MARK: - 属性

    private let platform: WelfarePlatform
    private var engine: JSSpiderEngine?
    private var initError: String?
    private let initLock = NSLock()

    /// 是否需要 SSL 绕过
    private var sslBypass: Bool {
        platform.sslBypass ?? false
    }

    // MARK: - Init

    init(platform: WelfarePlatform) {
        self.platform = platform
        super.init(
            platformName: platform.name,
            defaultHosts: platform.defaultHosts
        )
    }

    // MARK: - 引擎初始化

    private func ensureEngine() async {
        initLock.lock()
        if engine != nil || initError != nil {
            initLock.unlock()
            return
        }
        initLock.unlock()

        do {
            let script = try await WelfareSpiderLoader.shared.loadScript(for: platform)
            let eng = JSSpiderEngine(sslBypass: sslBypass)
            let platformKey = platform.platformKey
            eng.onLog = { msg in print("[WelfareJS:\(platformKey)] \(msg)") }
            try eng.loadScript(script.content)
            try eng.registerSpider()

            // 调用 init
            let config: [String: Any] = [
                "platformKey": platform.platformKey,
                "hosts": platform.defaultHosts,
            ]
            _ = eng.callInit(config: config)

            initLock.lock()
            self.engine = eng
            self.initError = nil
            initLock.unlock()
            print("[WelfareJS:\(platform.platformKey)] ✅ 引擎初始化成功")
        } catch {
            initLock.lock()
            self.initError = error.localizedDescription
            initLock.unlock()
            print("[WelfareJS:\(platform.platformKey)] ❌ 引擎初始化失败: \(error.localizedDescription)")
        }
    }

    // MARK: - FuliPlatformService 实现

    override func fetchHomeContent() async -> FuliHomeResult {
        await ensureEngine()
        guard let engine = engine else {
            return .empty
        }

        do {
            let result = try engine.callHomeContent()

            // 分类
            let categories = (result.class ?? []).map {
                FuliCategory(typeId: $0.typeId, typeName: $0.typeName)
            }

            // 首页推荐视频
            var videos = (result.list ?? []).compactMap { convertVideo($0) }

            // 如果 homeContent 没有返回 list，尝试调用 homeVideoContent
            if videos.isEmpty {
                // 检查是否实现了 homeVideoContent
                if let checkResult = engine.callRawFunction(
                    "typeof globalThis.__JS_SPIDER__.homeVideoContent === 'function' ? 'yes' : 'no'"
                ), checkResult.toString() == "yes" {
                    // 调用 homeVideoContent 并存储结果
                    _ = engine.callRawFunction("globalThis.__tmpHVC = globalThis.__JS_SPIDER__.homeVideoContent()")
                    if let jsonStr = engine.callRawFunction("JSON.stringify(globalThis.__tmpHVC)")?.toString(),
                       let data = jsonStr.data(using: .utf8),
                       let homeVideo = try? JSONDecoder().decode(HomeContentResult.self, from: data) {
                        videos = (homeVideo.list ?? []).compactMap { convertVideo($0) }
                    }
                    _ = engine.callRawFunction("delete globalThis.__tmpHVC")
                }
            }

            return FuliHomeResult(categories: categories, videos: videos)
        } catch {
            print("[WelfareJS:\(platform.platformKey)] ❌ fetchHomeContent: \(error.localizedDescription)")
            return .empty
        }
    }

    override func fetchCategoryContent(
        category: FuliCategory,
        subCategory: FuliCategory?,
        page: Int
    ) async -> FuliCategoryResult {
        await ensureEngine()
        guard let engine = engine else {
            return FuliCategoryResult(videos: [], page: page, hasMore: false)
        }

        let tid = subCategory?.typeId ?? category.typeId

        do {
            let result = try engine.callCategoryContent(tid: tid, pg: page)
            let videos = (result.list ?? []).compactMap { convertVideo($0) }
            let pageCount = result.pagecount ?? 1
            let hasMore = page < pageCount

            return FuliCategoryResult(videos: videos, page: page, hasMore: hasMore)
        } catch {
            print("[WelfareJS:\(platform.platformKey)] ❌ fetchCategoryContent: \(error.localizedDescription)")
            return FuliCategoryResult(videos: [], page: page, hasMore: false)
        }
    }

    override func fetchDetail(vodId: String) async -> FuliDetail {
        await ensureEngine()
        guard let engine = engine else {
            return FuliDetail(
                vodId: vodId, vodName: "", vodPic: "",
                vodContent: nil, playFrom: platformName, episodes: []
            )
        }

        do {
            let result = try engine.callDetailContent(ids: vodId)
            guard let item = result.list?.first else {
                return FuliDetail(
                    vodId: vodId, vodName: "", vodPic: "",
                    vodContent: nil, playFrom: platformName, episodes: []
                )
            }

            let episodes = parseEpisodes(
                playFrom: item.vodPlayFrom ?? platformName,
                playUrl: item.vodPlayUrl ?? ""
            )

            return FuliDetail(
                vodId: item.vodId,
                vodName: item.vodName,
                vodPic: item.vodPic,
                vodContent: item.vodContent,
                playFrom: item.vodPlayFrom ?? platformName,
                episodes: episodes
            )
        } catch {
            print("[WelfareJS:\(platform.platformKey)] ❌ fetchDetail: \(error.localizedDescription)")
            return FuliDetail(
                vodId: vodId, vodName: "", vodPic: "",
                vodContent: nil, playFrom: platformName, episodes: []
            )
        }
    }

    override func fetchSearch(keyword: String, page: Int) async -> FuliSearchResult {
        await ensureEngine()
        guard let engine = engine else {
            return FuliSearchResult(videos: [], page: page, hasMore: false)
        }

        do {
            let result = try engine.callSearchContent(keyword: keyword, pg: page)
            let videos = (result.list ?? []).compactMap { convertVideo($0) }
            let pageCount = result.pagecount ?? 1
            let hasMore = page < pageCount

            return FuliSearchResult(videos: videos, page: page, hasMore: hasMore)
        } catch {
            print("[WelfareJS:\(platform.platformKey)] ❌ fetchSearch: \(error.localizedDescription)")
            return FuliSearchResult(videos: [], page: page, hasMore: false)
        }
    }

    override func fetchPlayerURL(episode: FuliEpisode) async -> FuliPlayerResult {
        await ensureEngine()

        var url = episode.url
        var playerHeaders: [String: String] = [:]
        var parseFlag = 0

        // 如果 JS 蜘蛛实现了 playerContent，调用它获取最终播放地址
        if let engine = engine, engine.isSpiderReady {
            if let checkResult = engine.callRawFunction(
                "typeof globalThis.__JS_SPIDER__.playerContent === 'function' ? 'yes' : 'no'"
            ), checkResult.toString() == "yes" {
                // 调用 playerContent(flag, id, vipFlags) 并存储结果到临时变量
                let escapedUrl = url.replacingOccurrences(of: "'", with: "\\'")
                let escapedFlag = platformName.replacingOccurrences(of: "'", with: "\\'")
                _ = engine.callRawFunction(
                    "globalThis.__tmpPC = globalThis.__JS_SPIDER__.playerContent('\(escapedFlag)', '\(escapedUrl)', [])"
                )

                // 将结果转为 JSON 字符串
                if let jsonStr = engine.callRawFunction("JSON.stringify(globalThis.__tmpPC)")?.toString(),
                   let data = jsonStr.data(using: .utf8),
                   let pc = try? JSONDecoder().decode(PlayerContentResult.self, from: data) {
                    if let pcUrl = pc.url, !pcUrl.isEmpty {
                        url = pcUrl
                    }
                    playerHeaders = pc.header ?? [:]
                    parseFlag = pc.parse ?? 0
                }

                // 清理临时变量
                _ = engine.callRawFunction("delete globalThis.__tmpPC")
            }
        }

        return processPlayerURL(url: url, headers: playerHeaders, parse: parseFlag)
    }

    // MARK: - 播放地址处理

    /// 处理播放地址：m3u8 走本地代理（SSL 绕过 + Brotli 解压），其他直接返回
    private func processPlayerURL(url: String, headers: [String: String], parse: Int) -> FuliPlayerResult {
        // 合并默认 headers
        var finalHeaders = headers
        if finalHeaders["User-Agent"] == nil {
            finalHeaders["User-Agent"] = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36"
        }

        // m3u8 走本地代理（SSL 绕过 + Brotli 解压 + key/TS 重写）
        if url.contains(".m3u8") {
            DoubanImageProxyServer.shared.start()
            if let proxyURL = DoubanImageProxyServer.shared.proxiedWelfareJSM3U8URL(
                for: url,
                headers: finalHeaders
            ) {
                return FuliPlayerResult(url: proxyURL.absoluteString, headers: finalHeaders, parse: 0)
            }
        }

        return FuliPlayerResult(url: url, headers: finalHeaders, parse: parse)
    }

    // MARK: - 数据转换

    /// VodItem → FuliVideo
    private func convertVideo(_ item: VodItem) -> FuliVideo? {
        guard !item.vodId.isEmpty else { return nil }
        return FuliVideo(
            vodId: item.vodId,
            vodName: item.vodName,
            vodPic: item.vodPic,
            vodRemarks: item.vodRemarks
        )
    }

    /// 解析标准 spider 的 vod_play_from + vod_play_url 为 FuliEpisode 数组
    /// 格式：
    ///   vod_play_from: "线路1$$$线路2"  （多线路用 $$$ 分隔）
    ///   vod_play_url:  "第1集$url1#第2集$url2$$$第1集$url1#第2集$url2"
    private func parseEpisodes(playFrom: String, playUrl: String) -> [FuliEpisode] {
        guard !playUrl.isEmpty else { return [] }

        let lines = playFrom.components(separatedBy: "$$$")
        let urlGroups = playUrl.components(separatedBy: "$$$")

        var episodes: [FuliEpisode] = []
        let hasMultipleLines = lines.count > 1

        for (i, group) in urlGroups.enumerated() {
            let lineName = i < lines.count ? lines[i] : "线路\(i + 1)"
            let items = group.components(separatedBy: "#")

            for item in items {
                let parts = item.components(separatedBy: "$")
                guard parts.count >= 2 else { continue }
                let epName = parts[0]
                let epUrl = parts[1]

                let displayName = hasMultipleLines ? "[\(lineName)] \(epName)" : epName
                episodes.append(FuliEpisode(name: displayName, url: epUrl))
            }
        }

        return episodes
    }
}
