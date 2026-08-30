//
//  WelfarePythonSpiderService.swift
//  vbox
//
//  通用福利 Python Spider 服务 — 通过远程 Python 脚本驱动福利平台。
//
//  设计目标：
//  - 新增 Python 福利平台只需在远程源 welfare_platforms.json 中配置 + 上传 .py 脚本
//  - 无需修改 vbox 项目代码（首次对接后，后续纯配置驱动）
//  - 复用 FuliPlatformMainView 自适应框架
//  - 不影响普通蜘蛛资源、网盘播放和其他福利平台
//  - 自动享用福利专区自定义域名和代理设置（通过 injectDict 注入 base.spider）
//
//  Python 脚本需实现以下方法（继承 base.spider.Spider）：
//  - init(extend)            → 初始化（可选）
//  - homeContent(filter)     → { class: [...], list: [...] }
//  - homeVideoContent()      → { list: [...] }（可选）
//  - categoryContent(tid, pg, filter, extend) → { list, page, pagecount, limit }
//  - detailContent(ids)      → { list: [{ vod_id, vod_name, vod_pic, vod_content, vod_play_from, vod_play_url }] }
//  - searchContent(key, quick, pg) → { list, page, pagecount }
//  - playerContent(flag, id, vipFlags) → { parse, url, header }（可选）
//
//  福利基础设施自适应：
//  - 自定义域名：从 WelfareDomainStore 读取，注入 _vbox_effective_hosts → base.spider 自动应用
//  - 代理设置：从 WelfareProxyStore 读取，注入 _vbox_proxy_enabled / _vbox_proxy_url → base.spider 自动应用
//  - 新增 Python 福利平台时，自动出现在设置页的代理开关和自定义域名列表中
//

import Foundation
import Combine

final class WelfarePythonSpiderService: FuliBaseService {

    // MARK: - 日志辅助

    /// 统一日志：同时输出到 print() 和 AppLogStore（welfare 分类）
    private func pyLog(_ msg: String) {
        let entry = "[WelfarePy:\(platform.platformKey)] \(msg)"
        print(entry)
        AppLogStore.shared.info(.welfare, entry)
    }

    // MARK: - 实例缓存

    private static let cache = NSCache<NSString, WelfarePythonSpiderService>()

    static func service(for platform: WelfarePlatform) -> WelfarePythonSpiderService {
        let key = platform.platformKey as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let svc = WelfarePythonSpiderService(platform: platform)
        cache.setObject(svc, forKey: key)
        return svc
    }

    // MARK: - 本地代理入口（供 DoubanImageProxyServer 调用）

    /// 根据 platformKey 查找已注册的服务，调用其 localProxy
    /// 返回 (statusCode, contentType, data)，失败返回 nil
    static func callLocalProxy(platformKey: String, params: [String: String]) -> (status: Int, contentType: String, data: Data)? {
        // 从缓存中查找已初始化的服务
        let svc = cache.object(forKey: platformKey as NSString)
        guard let svc = svc, let engine = svc.engine else {
            return nil
        }

        // 构造 JSON 参数
        guard let jsonData = try? JSONSerialization.data(withJSONObject: params),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            return nil
        }

        return engine.callLocalProxy(args: jsonStr)
    }

    /// 获取已注册的平台 key 列表（调试用）
    static var registeredKeys: [String] {
        // NSCache 没有直接遍历方法，返回空数组占位
        // 实际使用时通过 platformKey 直接查找
        return []
    }

    // MARK: - 属性

    private let platform: WelfarePlatform
    private var engine: PythonSpiderEngine?
    private var initError: String?
    private let initLock = NSLock()
    private let mapper = WelfareResultMapper()
    /// 最近一次详情页返回的 vod_play_from，用于 playerContent 的 flag 参数
    private var lastPlayFrom: String = ""

    // MARK: - Init

    init(platform: WelfarePlatform) {
        self.platform = platform
        super.init(
            platformName: platform.name,
            defaultHosts: platform.defaultHosts,
            platformKey: platform.platformKey
        )
    }

    // MARK: - FuliPlatformService 附加属性

    /// 内容类型：从平台配置读取（contentType 优先，其次用 category），默认视频
    override var contentCategory: FuliContentCategory {
        let type = (platform.contentType ?? platform.category).lowercased()
        switch type {
        case "comic": return .comic
        // 直播目前也走视频播放链路（AVPlayer 支持 m3u8 直播流）
        case "live": return .video
        default: return .video
        }
    }

    /// 图片 SSL 绕过：从平台配置的 imageSSLBypass 字段读取
    override var imageSSLBypass: Bool { platform.imageSSLBypass ?? false }

    /// 图片 Referer：从平台配置读取（如果有）
    override var imageReferer: String? { platform.imageReferer }

    // MARK: - 域名管理（重写协议扩展，适配 Python 蜘蛛）

    /// 重新探测域名。
    /// Python 蜘蛛通过发起一次 homeContent 调用来验证域名是否可用，
    /// 而不是协议扩展的 URLSession 探测（两者网络栈不同）。
    func reprobe() {
        Task {
            isHostReady = false
            await ensureEngine()
            guard engine != nil else {
                isHostReady = false
                return
            }
            // 调用一次首页接口验证域名是否可达
            let result = await fetchHomeContent()
            let ok = !result.videos.isEmpty || !result.categories.isEmpty
            await MainActor.run {
                self.isHostReady = ok
            }
        }
    }

    /// 重置域名：清除用户自定义域名，回退到 defaultHosts。
    func resetDomain() {
        WelfareDomainStore.shared.clearDomains(for: platformName)
        // 下次请求时 injectDict 会重新构建，自动使用 defaultHosts
        reprobe()
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
            // 下载脚本
            let script = try await WelfareSpiderLoader.shared.loadScript(for: platform)

            // 创建引擎
            let eng = PythonSpiderEngine(scriptPath: script.localURL.path, key: platform.platformKey)
            eng.onLog = { [weak self] msg in
                self?.pyLog(msg)
            }

            // 注入福利上下文（自定义域名 + 代理设置）
            eng.injectDict = buildInjectDict()

            // 等待初始化完成（init 方法执行成功）
            try await eng.registerSpiderAsync()

            initLock.lock()
            self.engine = eng
            self.initError = nil
            initLock.unlock()
            pyLog("✅ 引擎初始化成功")
        } catch {
            initLock.lock()
            self.initError = error.localizedDescription
            initLock.unlock()
            pyLog("❌ 引擎初始化失败: \(error.localizedDescription)")
        }
    }

    /// 构建注入到 Python globals 的上下文字典
    ///
    /// 包含：
    /// - _vbox_effective_hosts: [String] — 用户自定义域名 + defaultHosts
    /// - _vbox_proxy_enabled: Bool — 当前平台是否启用代理
    /// - _vbox_proxy_url: String — 全局代理 URL（如果设置了）
    /// - _vbox_platform_key: String — 平台唯一标识
    private func buildInjectDict() -> [String: Any] {
        let customHosts = WelfareDomainStore.shared.domains(for: platformName)
        let effectiveHosts = customHosts + defaultHosts

        let proxyEnabled = WelfareProxyStore.shared.isProxyEnabled(for: platformName)
        let proxyURL = WelfareProxyStore.shared.proxyURL

        var dict: [String: Any] = [
            "_vbox_effective_hosts": effectiveHosts,
            "_vbox_proxy_enabled": proxyEnabled,
            "_vbox_proxy_url": proxyURL,
            "_vbox_platform_key": platform.platformKey
        ]

        // 可选：平台级其他配置
        if let sslBypass = platform.sslBypass {
            dict["_vbox_ssl_bypass"] = sslBypass
        }

        return dict
    }

    // MARK: - FuliPlatformService 实现

    override func fetchHomeContent() async -> FuliHomeResult {
        await ensureEngine()
        guard let engine = engine else {
            return .empty
        }

        do {
            let inject = buildInjectDict()
            let result = try await engine.callHomeContentAsync(injectDict: inject)
            let mapped = mapper.mapHome(result)

            // 如果 homeContent 没有返回 list，尝试调用 homeVideoContent
            // 部分脚本（如 fuli74p.py）不实现 homeVideoContent，需容错处理
            if mapped.videos.isEmpty {
                do {
                    let videoResult = try await engine.callHomeVideoContentAsync(injectDict: inject)
                    if let list = videoResult.list, !list.isEmpty {
                        let videos = list.compactMap { mapVideo($0) }
                        return FuliHomeResult(categories: mapped.categories, videos: videos)
                    }
                } catch {
                    // homeVideoContent 不存在或执行失败时，仍然返回已获取的分类
                    // 避免因 homeVideoContent 缺失导致整个首页"未能解析到分类"
                    pyLog("⚠️ homeVideoContent 不可用，仅返回分类: \(error.localizedDescription)")
                }
            }

            return mapped
        } catch {
            pyLog("❌ fetchHomeContent: \(error.localizedDescription)")
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
        let extend = "{}"

        do {
            let inject = buildInjectDict()
            let result = try await engine.callCategoryContentAsync(tid: tid, pg: page, extend: extend, injectDict: inject)
            return mapper.mapCategory(result)
        } catch {
            pyLog("❌ fetchCategoryContent: \(error.localizedDescription)")
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
            let inject = buildInjectDict()
            let result = try await engine.callDetailContentAsync(ids: vodId, injectDict: inject)
            let detail = mapper.mapDetail(result)
            // 记录 playFrom，供 playerContent 的 flag 参数使用
            lastPlayFrom = detail.playFrom

            // 漫画类型：调用 playerContent 获取 manga:// 图片列表
            if contentCategory == .comic {
                let episodesWithImages = await loadComicImages(for: detail.episodes, inject: inject)
                return FuliDetail(
                    vodId: detail.vodId,
                    vodName: detail.vodName,
                    vodPic: detail.vodPic,
                    vodContent: detail.vodContent,
                    playFrom: detail.playFrom,
                    episodes: episodesWithImages
                )
            }

            return detail
        } catch {
            pyLog("❌ fetchDetail: \(error.localizedDescription)")
            return FuliDetail(
                vodId: vodId, vodName: "", vodPic: "",
                vodContent: nil, playFrom: platformName, episodes: []
            )
        }
    }

    /// 加载漫画图片列表
    /// 优化：如果 episode URL 已经是 manga:// 或 pics:// 协议，直接解析，不再调用 playerContent
    private func loadComicImages(for episodes: [FuliEpisode], inject: [String: Any]) async -> [FuliEpisode] {
        guard let engine = engine else { return episodes }

        return await withTaskGroup(of: (Int, FuliEpisode).self) { group in
            for (index, ep) in episodes.enumerated() {
                group.addTask { [weak self] in
                    guard let self = self else { return (index, ep) }

                    // 快速路径：URL 已经是 manga:// 或 pics:// 协议，直接解析
                    if self.mapper.isMangaProtocol(ep.url) {
                        let images = self.mapper.parseMangaURL(ep.url)
                        if !images.isEmpty {
                            var newEp = ep
                            newEp.images = images
                            return (index, newEp)
                        }
                        return (index, ep)
                    }

                    // 慢速路径：调用 playerContent 获取 manga:// 协议 URL
                    do {
                        let playerResult = try await engine.callPlayerContentAsync(
                            vodId: "",
                            flag: self.playFromFromEpisode(ep),
                            url: ep.url,
                            injectDict: inject
                        )
                        let playerURL = (playerResult.playUrl?.isEmpty == false ? playerResult.playUrl : nil)
                            ?? playerResult.url
                            ?? ""
                        // 解析 manga:// 或 pics:// 协议
                        let images = self.mapper.parseMangaURL(playerURL)
                        if !images.isEmpty {
                            var newEp = ep
                            newEp.images = images
                            return (index, newEp)
                        }
                    } catch {
                        self.pyLog("❌ loadComicImages[\(ep.name)]: \(error.localizedDescription)")
                    }
                    return (index, ep)
                }
            }

            var result: [(Int, FuliEpisode)] = []
            for await item in group {
                result.append(item)
            }
            return result.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    override func fetchSearch(keyword: String, page: Int) async -> FuliSearchResult {
        await ensureEngine()
        guard let engine = engine else {
            return FuliSearchResult(videos: [], page: page, hasMore: false)
        }

        do {
            let inject = buildInjectDict()
            let result = try await engine.callSearchContentAsync(keyword: keyword, pg: page, injectDict: inject)
            return mapper.mapSearch(result)
        } catch {
            pyLog("❌ fetchSearch: \(error.localizedDescription)")
            return FuliSearchResult(videos: [], page: page, hasMore: false)
        }
    }

    override func fetchPlayerURL(episode: FuliEpisode) async -> FuliPlayerResult {
        await ensureEngine()

        // 如果 Python 蜘蛛就绪，优先调用 playerContent 获取最终播放地址
        if let engine = engine, engine.isSpiderReady {
            do {
                let inject = buildInjectDict()
                let result = try await engine.callPlayerContentAsync(
                    vodId: "",
                    flag: playFromFromEpisode(episode),
                    url: episode.url,
                    injectDict: inject
                )
                let mapped = mapper.mapPlayer(result)
                if !mapped.url.isEmpty {
                    // 合并默认 headers
                    var playerHeaders = mapped.headers
                    if playerHeaders["User-Agent"] == nil {
                        playerHeaders["User-Agent"] = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36"
                    }
                    // playerRefererMode = "keep" 时注入标记头，告知播放器保留脚本返回的 Referer
                    // （默认行为是域名不匹配时用 CDN 自身 Referer 替换，但直播源往往需要主站 Referer 才能通过防盗链）
                    if (platform.playerRefererMode ?? "").lowercased() == "keep" {
                        playerHeaders["X-VBox-Player-Referer-Mode"] = "keep"
                    }
                    return FuliPlayerResult(url: mapped.url, headers: playerHeaders, parse: mapped.parse)
                }
            } catch {
                pyLog("❌ fetchPlayerURL: \(error.localizedDescription)")
            }
        }

        // 兜底：使用基类默认实现（按 URL 后缀判断 parse，用默认 headers）
        return await super.fetchPlayerURL(episode: episode)
    }

    // MARK: - Private Helpers

    private func mapVideo(_ item: VodItem) -> FuliVideo? {
        guard !item.vodId.isEmpty else { return nil }
        return FuliVideo(
            vodId: item.vodId,
            vodName: item.vodName,
            vodPic: item.vodPic,
            vodRemarks: item.vodRemarks
        )
    }

    private func playFromFromEpisode(_ episode: FuliEpisode) -> String {
        // 从剧集名称中提取线路名（如果有 [线路名] 前缀，多线路场景）
        let name = episode.name
        if name.hasPrefix("["), let endIndex = name.firstIndex(of: "]") {
            let lineName = name[name.index(after: name.startIndex)..<endIndex]
            return String(lineName)
        }
        // 单线路场景：从 lastPlayFrom 取（详情页返回的 vod_play_from 第一个值）
        // lastPlayFrom 可能是 "$$$" 分隔的多线路名，取第一个
        if !lastPlayFrom.isEmpty {
            let firstLine = lastPlayFrom.components(separatedBy: "$$$").first ?? ""
            if !firstLine.isEmpty {
                return firstLine
            }
        }
        return platformName
    }
}
