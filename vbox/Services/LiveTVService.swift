import Foundation
import SwiftUI
import JavaScriptCore

// MARK: - 直播源类型
enum LiveSourceType: Identifiable, Equatable, Codable {
    case defaultIPTV      // iptv807.com
    case cctvLive         // 央视直播 (tv.cctv.com)
    case subscribe(name: String, url: String)  // 订阅配置中的源
    case custom(name: String, url: String)     // 用户自定义源

    var id: String {
        switch self {
        case .defaultIPTV:
            return "default_iptv"
        case .cctvLive:
            return "default_cctv"
        case .subscribe(let name, let url):
            return "subscribe_\(name)_\(url)"
        case .custom(let name, let url):
            return "custom_\(name)_\(url)"
        }
    }

    var displayName: String {
        switch self {
        case .defaultIPTV:
            return "默认源 (iptv807.com)"
        case .cctvLive:
            return "央视直播 (CCTV)"
        case .subscribe(let name, _):
            return name
        case .custom(let name, _):
            return name
        }
    }

    var sourceURL: String? {
        switch self {
        case .defaultIPTV, .cctvLive:
            return nil
        case .subscribe(_, let url):
            return url
        case .custom(_, let url):
            return url
        }
    }

    var isDefault: Bool {
        switch self {
        case .defaultIPTV, .cctvLive:
            return true
        case .subscribe, .custom:
            return false
        }
    }

    // MARK: - Codable
    enum CodingKeys: String, CodingKey {
        case type, name, url
    }

    enum SourceKind: String, Codable {
        case defaultIPTV, cctvLive, subscribe, custom
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .defaultIPTV:
            try container.encode(SourceKind.defaultIPTV, forKey: .type)
        case .cctvLive:
            try container.encode(SourceKind.cctvLive, forKey: .type)
        case .subscribe(let name, let url):
            try container.encode(SourceKind.subscribe, forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(url, forKey: .url)
        case .custom(let name, let url):
            try container.encode(SourceKind.custom, forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(url, forKey: .url)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(SourceKind.self, forKey: .type)
        switch kind {
        case .defaultIPTV:
            self = .defaultIPTV
        case .cctvLive:
            self = .cctvLive
        case .subscribe:
            let name = try container.decode(String.self, forKey: .name)
            let url = try container.decode(String.self, forKey: .url)
            self = .subscribe(name: name, url: url)
        case .custom:
            let name = try container.decode(String.self, forKey: .name)
            let url = try container.decode(String.self, forKey: .url)
            self = .custom(name: name, url: url)
        }
    }

    init?(dictionary: [String: String]) {
        guard let type = dictionary["type"] else { return nil }
        switch type {
        case "defaultIPTV":
            self = .defaultIPTV
        case "cctvLive":
            self = .cctvLive
        case "subscribe":
            guard let name = dictionary["name"], let url = dictionary["url"] else { return nil }
            self = .subscribe(name: name, url: url)
        case "custom":
            guard let name = dictionary["name"], let url = dictionary["url"] else { return nil }
            self = .custom(name: name, url: url)
        default:
            return nil
        }
    }

    func toDictionary() -> [String: String] {
        switch self {
        case .defaultIPTV:
            return ["type": "defaultIPTV"]
        case .cctvLive:
            return ["type": "cctvLive"]
        case .subscribe(let name, let url):
            return ["type": "subscribe", "name": name, "url": url]
        case .custom(let name, let url):
            return ["type": "custom", "name": name, "url": url]
        }
    }
}

// MARK: - 订阅源频道模型
struct SubscribeChannel: Identifiable {
    let id = UUID()
    let name: String
    let url: String
    let group: String?   // 分组名（如"央视","卫视"）
    let logo: String?    // 台标URL
}

// MARK: - 直播频道模型
struct LiveChannel: Identifiable, Codable {
    let id: String
    let name: String
    let tid: String
    let channelId: String
    let token: String
    let logo: String?
    /// 多线路播放地址列表（解析后填充）
    var sources: [String]

    /// 构建播放页面URL
    var playURL: String {
        return "http://m.iptv807.com/?act=play&token=\(token)&tid=\(tid)&id=\(channelId)"
    }

    /// 构建M3U8直链（通过解析播放页获取）
    var m3u8URL: String? {
        return LiveTVService.shared.m3u8Cache[id]
    }

    /// 线路数量
    var routeCount: Int {
        return max(1, sources.count)
    }

    /// 获取指定线路的播放地址
    func routeURL(index: Int) -> String? {
        if !sources.isEmpty {
            let idx = min(index, sources.count - 1)
            return sources[idx]
        }
        return m3u8URL
    }
}

// MARK: - 直播分类
struct LiveCategory: Identifiable {
    let id: String
    let name: String
    let tid: String
    let icon: String

    var tintColor: Color {
        switch id {
        case "itv": return Color.blue
        case "ty": return Color.green
        case "ys": return Color.red
        case "ws": return Color.orange
        case "gt": return Color.purple
        case "movie": return Color.pink
        case "migu": return Color.cyan
        case "fjitv", "hlitv": return Color.teal
        case "ipv6": return Color.indigo
        default: return Color.gray
        }
    }

    var backgroundColor: Color { tintColor }
}

// MARK: - 直播服务
class LiveTVService: ObservableObject {
    static let shared = LiveTVService()

    private let baseURL = "http://m.iptv807.com"
    private let session: URLSession

    /// M3U8缓存 [channelId: m3u8URL]
    var m3u8Cache: [String: String] = [:]

    /// 当前直播源
    @Published var currentSource: LiveSourceType = .defaultIPTV {
        didSet {
            // 切换源时清空缓存
            clearCache()
            // 保存当前源到 UserDefaults
            saveCurrentSource()
        }
    }

    /// 订阅源频道列表（当前订阅源的频道）
    @Published var subscribeChannels: [SubscribeChannel] = []

    /// 用户自定义源列表（从 UserDefaults 读取）
    @Published var customSources: [LiveSourceType] = []

    /// 本地导入的频道缓存 [源名称: 频道列表]
    @Published var localChannelsMap: [String: [SubscribeChannel]] = [:]

    /// 所有可用源列表
    var availableSources: [LiveSourceType] {
        var sources: [LiveSourceType] = [.defaultIPTV, .cctvLive]
        // 可以从配置文件读取的订阅源
        sources.append(contentsOf: configSubscribeSources)
        // 用户自定义源
        sources.append(contentsOf: customSources)
        return sources
    }

    /// 配置文件中预定义的订阅源
    private var configSubscribeSources: [LiveSourceType] = []

    /// 分类列表（仅默认源使用）
    let categories: [LiveCategory] = [
        LiveCategory(id: "itv", name: "综合", tid: "itv", icon: "tv"),
        LiveCategory(id: "ty", name: "体育", tid: "ty", icon: "sportscourt"),
        LiveCategory(id: "ys", name: "央视", tid: "ys", icon: "antenna.radiowaves.left.and.right"),
        LiveCategory(id: "ws", name: "卫视", tid: "ws", icon: "tv.inset.filled"),
        LiveCategory(id: "gt", name: "港澳台", tid: "gt", icon: "globe.asia.australia"),
        LiveCategory(id: "other", name: "其他", tid: "other", icon: "ellipsis.circle"),
        LiveCategory(id: "movie", name: "电影", tid: "movie", icon: "film"),
        LiveCategory(id: "migu", name: "咪咕", tid: "migu", icon: "play.circle"),
        LiveCategory(id: "fjitv", name: "福建IPTV", tid: "fjitv", icon: "network"),
        LiveCategory(id: "hlitv", name: "黑龙江IPTV", tid: "hlitv", icon: "network"),
        LiveCategory(id: "ipv6", name: "IPv6", tid: "ipv6", icon: "wifi")
    ]

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9"
        ]
        self.session = URLSession(configuration: config)

        // 从 UserDefaults 加载自定义源和当前源
        loadCustomSources()
        loadCurrentSource()
        loadLocalChannels()
    }

    // MARK: - UserDefaults 持久化

    private let customSourcesKey = "live_tv_custom_sources"
    private let currentSourceKey = "live_tv_current_source"

    private func loadCustomSources() {
        guard let data = UserDefaults.standard.data(forKey: customSourcesKey),
              let dicts = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            customSources = []
            return
        }
        customSources = dicts.compactMap { LiveSourceType(dictionary: $0) }
    }

    private func saveCustomSources() {
        let dicts = customSources.map { $0.toDictionary() }
        if let data = try? JSONSerialization.data(withJSONObject: dicts) {
            UserDefaults.standard.set(data, forKey: customSourcesKey)
        }
    }

    private func loadCurrentSource() {
        guard let data = UserDefaults.standard.data(forKey: currentSourceKey) else { return }
        if let source = try? JSONDecoder().decode(LiveSourceType.self, from: data) {
            currentSource = source
        }
    }

    private func saveCurrentSource() {
        if let data = try? JSONEncoder().encode(currentSource) {
            UserDefaults.standard.set(data, forKey: currentSourceKey)
        }
    }

    // MARK: - 源管理

    /// 切换直播源
    func switchSource(to source: LiveSourceType) {
        currentSource = source
        if case .subscribe(_, let url) = source {
            // 如果是本地导入的源，从缓存加载
            if url.hasPrefix("local://") {
                let localName = String(url.dropFirst(8))
                subscribeChannels = localChannelsMap[localName] ?? []
            } else {
                Task {
                    await fetchSubscribeChannels(url: url)
                }
            }
        } else if case .custom(_, let url) = source {
            // 自定义源也可能是本地导入的
            if url.hasPrefix("local://") {
                let localName = String(url.dropFirst(8))
                subscribeChannels = localChannelsMap[localName] ?? []
            } else {
                Task {
                    await fetchSubscribeChannels(url: url)
                }
            }
        }
        // defaultIPTV 和 cctvLive 不需要额外加载
    }

    /// 添加自定义源
    func addCustomSource(name: String, url: String) {
        let source = LiveSourceType.custom(name: name, url: url)
        customSources.append(source)
        saveCustomSources()
    }

    /// 删除自定义源
    func removeCustomSource(at index: Int) {
        guard index >= 0 && index < customSources.count else { return }
        let removed = customSources.remove(at: index)
        saveCustomSources()
        // 如果删除的是当前正在使用的源，切回默认源
        if removed.id == currentSource.id {
            currentSource = .defaultIPTV
        }
    }

    /// 删除自定义源（按标识）
    func removeCustomSource(id: String) {
        if let index = customSources.firstIndex(where: { $0.id == id }) {
            removeCustomSource(at: index)
        }
    }

    // MARK: - 本地文件导入频道管理

    /// 添加本地导入的频道
    func addLocalChannels(name: String, channels: [SubscribeChannel]) {
        localChannelsMap[name] = channels
        // 持久化到 UserDefaults
        saveLocalChannels()
        // 同时添加为自定义源（如果不存在）
        let localURL = "local://\(name)"
        if !customSources.contains(where: { $0.id == "custom_\(name)_\(localURL)" }) {
            let source = LiveSourceType.custom(name: name, url: localURL)
            customSources.append(source)
            saveCustomSources()
        }
    }

    /// 保存本地频道到 UserDefaults
    private func saveLocalChannels() {
        var dict: [String: [[String: Any]]] = [:]
        for (key, channels) in localChannelsMap {
            dict[key] = channels.map { channel in
                var d: [String: Any] = ["name": channel.name, "url": channel.url]
                if let group = channel.group { d["group"] = group }
                if let logo = channel.logo { d["logo"] = logo }
                return d
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            UserDefaults.standard.set(data, forKey: "live_tv_local_channels")
        }
    }

    /// 从 UserDefaults 加载本地频道
    private func loadLocalChannels() {
        guard let data = UserDefaults.standard.data(forKey: "live_tv_local_channels"),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]] else {
            return
        }
        for (key, channelDicts) in dict {
            localChannelsMap[key] = channelDicts.compactMap { d in
                guard let name = d["name"] as? String, let url = d["url"] as? String else {
                    return nil
                }
                return SubscribeChannel(
                    name: name,
                    url: url,
                    group: d["group"] as? String,
                    logo: d["logo"] as? String
                )
            }
        }
    }

    // MARK: - 获取分类频道列表
    func fetchChannels(tid: String) async -> [LiveChannel] {
        switch currentSource {
        case .defaultIPTV:
            return await fetchDefaultChannels(tid: tid)
        case .cctvLive:
            return await fetchCCTVChannels(tid: tid)
        case .subscribe, .custom:
            return await fetchSubscribeChannelsForTid(tid: tid)
        }
    }

    // MARK: - 默认源频道获取（iptv807.com）
    private func fetchDefaultChannels(tid: String) async -> [LiveChannel] {
        guard let url = URL(string: "\(baseURL)/?tid=\(tid)") else {
            print("[LiveTV] 默认源 URL 构建失败: tid=\(tid)")
            return []
        }

        do {
            let (data, response) = try await session.data(from: url)

            // 检查 HTTP 状态码
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode != 200 {
                print("[LiveTV] 默认源 HTTP 错误: \(httpResponse.statusCode)")
                return []
            }

            guard let html = String(data: data, encoding: .utf8) else {
                print("[LiveTV] 默认源内容编码错误")
                return []
            }

            print("[LiveTV] 默认源获取成功，HTML 长度: \(html.count), tid=\(tid)")

            // 尝试多种解析方式
            var channels = parseChannels(from: html, tid: tid)

            // 如果第一种方式没有结果，尝试更宽松的HTML匹配
            if channels.isEmpty {
                channels = parseChannelsFallback(from: html, tid: tid)
            }

            // 如果HTML匹配都没有结果，尝试Markdown格式解析
            if channels.isEmpty {
                channels = parseChannelsMarkdown(from: html, tid: tid)
            }

            print("[LiveTV] 解析到 \(channels.count) 个频道, tid=\(tid)")
            return channels
        } catch {
            print("[LiveTV] 获取频道失败: \(error)")
            return []
        }
    }

    // MARK: - 央视直播频道获取
    private func fetchCCTVChannels(tid: String) async -> [LiveChannel] {
        // 央视频道数据（内置）
        let cctvChannels: [(id: String, name: String, streamId: String, logo: String)] = [
            ("cctv_1", "CCTV-1 综合", "cctv1", "CCTV1"),
            ("cctv_2", "CCTV-2 财经", "cctv2", "CCTV2"),
            ("cctv_3", "CCTV-3 综艺", "cctv3", "CCTV3"),
            ("cctv_4", "CCTV-4 中文国际", "cctv4", "CCTV4"),
            ("cctv_5", "CCTV-5 体育", "cctv5", "CCTV5"),
            ("cctv_5p", "CCTV-5+ 体育赛事", "cctv5plus", "CCTV5PLUS"),
            ("cctv_6", "CCTV-6 电影", "cctv6", "CCTV6"),
            ("cctv_7", "CCTV-7 国防军事", "cctv7", "CCTV7"),
            ("cctv_8", "CCTV-8 电视剧", "cctv8", "CCTV8"),
            ("cctv_9", "CCTV-9 纪录", "cctv9", "CCTV9"),
            ("cctv_10", "CCTV-10 科教", "cctv10", "CCTV10"),
            ("cctv_11", "CCTV-11 戏曲", "cctv11", "CCTV11"),
            ("cctv_12", "CCTV-12 社会与法", "cctv12", "CCTV12"),
            ("cctv_13", "CCTV-13 新闻", "cctv13", "CCTV13"),
            ("cctv_14", "CCTV-14 少儿", "cctv14", "CCTV14"),
            ("cctv_15", "CCTV-15 音乐", "cctv15", "CCTV15"),
            ("cctv_16", "CCTV-16 奥林匹克", "cctv16", "CCTV16"),
            ("cctv_17", "CCTV-17 农业农村", "cctv17", "CCTV17"),
            ("cctv_news", "CCTV-新闻", "cctvnews", "CCTVNEWS"),
            ("cgtn", "CGTN 英语", "cgtn", "CGTN"),
            ("cgtn_doc", "CGTN 纪录", "cgtn Documentary", "CGTNDOC"),
            ("cgtn_fr", "CGTN 法语", "cgtn-f", "CGTNFR"),
            ("cgtn_es", "CGTN 西班牙语", "cgtn-e", "CGTNES"),
            ("cgtn_ar", "CGTN 阿拉伯语", "cgtn-a", "CGTNAR"),
            ("cgtn_ru", "CGTN 俄语", "cgtn-r", "CGTNRU"),
        ]

        // 央视分类映射
        let cctvCategoryMap: [String: [(String, String, String, String)]] = {
            var map: [String: [(String, String, String, String)]] = [:]
            for ch in cctvChannels {
                let category: String
                if ch.streamId.hasPrefix("cgtn") {
                    category = "gt"  // 港澳台/国际
                } else {
                    category = "ys"  // 央视
                }
                map[category, default: []].append((ch.id, ch.name, ch.streamId, ch.logo))
            }
            return map
        }()

        guard let channels = cctvCategoryMap[tid] else { return [] }

        return channels.map { ch in
            LiveChannel(
                id: ch.0,
                name: ch.1,
                tid: tid,
                channelId: ch.2,
                token: "",
                logo: nil,
                sources: []  // 播放时动态解析
            )
        }
    }

    // MARK: - 央视直播流地址解析（多线路备用）
    func resolveCCTVStream(channelId: String) async -> [String] {
        // 多线路备用：每条频道提供多个源，增加可用性
        let streamMap: [String: [String]] = [
            "cctv1": [
                "http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226016/index.m3u8",
                "http://39.134.24.162/dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221225804/index.m3u8",
            ],
            "cctv2": [
                "http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221225588/index.m3u8",
                "http://39.134.24.162/dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226195/index.m3u8",
            ],
            "cctv3": [
                "http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226021/index.m3u8",
            ],
            "cctv4": [
                "http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226428/index.m3u8",
                "http://39.134.24.162/dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226191/index.m3u8",
            ],
            "cctv5": [
                "http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226019/index.m3u8",
                "http://39.134.24.162/dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226395/index.m3u8",
            ],
            "cctv5plus": [
                "http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221225603/index.m3u8",
            ],
            "cctv6": [
                "http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226010/index.m3u8",
            ],
            "cctv7": [
                "http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221225733/index.m3u8",
            ],
            "cctv8": [
                "http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226008/index.m3u8",
            ],
            "cctv9": [
                "http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221225734/index.m3u8",
            ],
            "cctv10": [
                "http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221225730/index.m3u8",
            ],
            "cctv11": [
                "http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221225597/index.m3u8",
            ],
            "cctv12": [
                "http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221225731/index.m3u8",
            ],
            "cctv13": [
                "http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226011/index.m3u8",
                "http://39.134.24.162/dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226233/index.m3u8",
            ],
            "cctv14": [
                "http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221225732/index.m3u8",
            ],
            "cctv15": [
                "http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221225601/index.m3u8",
            ],
            "cctv16": [
                "http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226100/index.m3u8",
            ],
            "cctv17": [
                "http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221225765/index.m3u8",
            ],
            "cctvnews": [
                "http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226580/index.m3u8",
            ],
        ]

        if let urls = streamMap[channelId], !urls.isEmpty {
            return urls
        }

        // CGTN 等国际频道使用备用源
        if channelId.hasPrefix("cgtn") {
            return ["https://news.cgtn.com/resource/live/english/cgtn-news.m3u8"]
        }

        return []
    }

    // MARK: - 订阅源频道获取（按分类过滤）
    private func fetchSubscribeChannelsForTid(tid: String) async -> [LiveChannel] {
        // 如果 subscribeChannels 为空，先尝试获取
        if subscribeChannels.isEmpty, let url = currentSource.sourceURL {
            await fetchSubscribeChannels(url: url)
        }

        // 根据 tid 过滤频道
        let filtered: [SubscribeChannel]
        switch tid {
        case "ys":
            filtered = subscribeChannels.filter { ch in
                guard let group = ch.group else { return false }
                return group.contains("央视") || group.contains("CCTV") || group.contains("中央")
            }
        case "ws":
            filtered = subscribeChannels.filter { ch in
                guard let group = ch.group else { return false }
                return group.contains("卫视") || group.contains("地方")
            }
        case "gt":
            filtered = subscribeChannels.filter { ch in
                guard let group = ch.group else { return false }
                return group.contains("港澳") || group.contains("台湾") || group.contains("港澳台")
            }
        case "ty":
            filtered = subscribeChannels.filter { ch in
                guard let group = ch.group else { return false }
                return group.contains("体育") || group.contains("Sport")
            }
        case "movie":
            filtered = subscribeChannels.filter { ch in
                guard let group = ch.group else { return false }
                return group.contains("电影") || group.contains("Movie")
            }
        case "itv":
            // 综合：未分组或无法识别的分组
            filtered = subscribeChannels.filter { ch in
                guard let group = ch.group else { return true }
                let knownGroups = ["央视", "CCTV", "中央", "卫视", "地方", "港澳", "台湾", "港澳台", "体育", "Sport", "电影", "Movie"]
                return !knownGroups.contains(where: { group.contains($0) })
            }
        default:
            // 其他分类：尝试按分组名精确匹配
            filtered = subscribeChannels.filter { ch in
                guard let group = ch.group else { return false }
                return group.contains(tid) || tid.contains(group)
            }
        }

        return filtered.map { ch in
            LiveChannel(
                id: "sub_\(ch.name)_\(ch.url)",
                name: ch.name,
                tid: tid,
                channelId: ch.url,
                token: "",
                logo: ch.logo,
                sources: [ch.url]
            )
        }
    }

    // MARK: - 解析频道列表（从HTML中提取）
    private func parseChannels(from html: String, tid: String) -> [LiveChannel] {
        var channels: [LiveChannel] = []

        // 匹配模式: <a href="https://m.iptv807.com/?act=play&token=xxx&tid=ys&id=1">CCTV1综合</a>
        let pattern = #"<a\s+href="https?://m\.iptv807\.com/\?act=play&token=([^"]+)&tid=([^"]+)&id=([^"]+)"[^>]*>([^<]+)</a>"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let matches = regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))

        for match in matches {
            guard match.numberOfRanges >= 5 else { continue }

            let token = String(html[Range(match.range(at: 1), in: html)!])
            let matchTid = String(html[Range(match.range(at: 2), in: html)!])
            let channelId = String(html[Range(match.range(at: 3), in: html)!])
            let name = String(html[Range(match.range(at: 4), in: html)!])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // 只取当前分类的频道
            guard matchTid == tid else { continue }

            let channel = LiveChannel(
                id: "\(tid)_\(channelId)",
                name: name,
                tid: tid,
                channelId: channelId,
                token: token,
                logo: nil,
                sources: []
            )
            channels.append(channel)
        }

        return channels
    }

    // MARK: - 备用解析方式（更宽松的匹配）
    private func parseChannelsFallback(from html: String, tid: String) -> [LiveChannel] {
        var channels: [LiveChannel] = []

        // 方式1: 匹配任意包含 act=play 的链接
        let pattern1 = #"<a\s[^>]*href=["']([^"']*act=play[^"']*)["'][^>]*>([^<]+)</a>"#
        if let regex = try? NSRegularExpression(pattern: pattern1, options: [.caseInsensitive]) {
            let matches = regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
            for match in matches {
                guard match.numberOfRanges >= 3 else { continue }
                let href = String(html[Range(match.range(at: 1), in: html)!])
                let name = String(html[Range(match.range(at: 2), in: html)!])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                // 从 href 中提取参数
                let params = extractParams(from: href)
                let matchTid = params["tid"] ?? ""
                let token = params["token"] ?? ""
                let channelId = params["id"] ?? ""

                guard matchTid == tid && !channelId.isEmpty else { continue }

                let channel = LiveChannel(
                    id: "\(tid)_\(channelId)",
                    name: name,
                    tid: tid,
                    channelId: channelId,
                    token: token,
                    logo: nil,
                    sources: []
                )
                channels.append(channel)
            }
        }

        // 方式2: 匹配列表项中的链接
        if channels.isEmpty {
            let pattern2 = #"<li[^>]*>.*?<a\s[^>]*href=["']([^"']*tid=\(tid)[^"']*)["'][^>]*>([^<]+)</a>.*?</li>"#
            if let regex = try? NSRegularExpression(pattern: pattern2, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                let matches = regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
                for match in matches {
                    guard match.numberOfRanges >= 3 else { continue }
                    let href = String(html[Range(match.range(at: 1), in: html)!])
                    let name = String(html[Range(match.range(at: 2), in: html)!])
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    let params = extractParams(from: href)
                    let token = params["token"] ?? ""
                    let channelId = params["id"] ?? ""

                    guard !channelId.isEmpty else { continue }

                    let channel = LiveChannel(
                        id: "\(tid)_\(channelId)",
                        name: name,
                        tid: tid,
                        channelId: channelId,
                        token: token,
                        logo: nil,
                        sources: []
                    )
                    channels.append(channel)
                }
            }
        }

        return channels
    }

    // MARK: - Markdown 格式解析（itv等分类返回Markdown而非HTML）
    private func parseChannelsMarkdown(from content: String, tid: String) -> [LiveChannel] {
        var channels: [LiveChannel] = []

        // 匹配 Markdown 链接: [频道名](URL)
        // 格式: - [CCTV1综合](https://m.iptv807.com/?act=play&token=xxx&tid=itv&id=1)
        let pattern = #"\[([^\]]+)\]\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let matches = regex.matches(in: content, options: [], range: NSRange(content.startIndex..., in: content))

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let name = String(content[Range(match.range(at: 1), in: content)!])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let href = String(content[Range(match.range(at: 2), in: content)!])
                .trimmingCharacters(in: .whitespaces)

            // 从 href 中提取参数
            let params = extractParams(from: href)
            let matchTid = params["tid"] ?? ""
            let token = params["token"] ?? ""
            let channelId = params["id"] ?? ""

            guard matchTid == tid && !channelId.isEmpty else { continue }

            let channel = LiveChannel(
                id: "\(tid)_\(channelId)",
                name: name,
                tid: tid,
                channelId: channelId,
                token: token,
                logo: nil,
                sources: []
            )
            channels.append(channel)
        }

        return channels
    }

    // MARK: - 从 URL 字符串中提取查询参数
    private func extractParams(from urlString: String) -> [String: String] {
        var params: [String: String] = [:]
        guard let components = URLComponents(string: urlString) else {
            // 尝试手动解析
            let parts = urlString.components(separatedBy: "?")
            guard parts.count > 1 else { return params }
            let query = parts[1].components(separatedBy: "&")
            for q in query {
                let kv = q.components(separatedBy: "=")
                if kv.count == 2 {
                    params[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
                }
            }
            return params
        }
        for item in components.queryItems ?? [] {
            params[item.name] = item.value
        }
        return params
    }

    // MARK: - 解析M3U8播放地址
    func resolveM3U8(channel: LiveChannel) async -> String? {
        // 先查缓存
        if let cached = m3u8Cache[channel.id] { return cached }

        // 如果是订阅源，直接返回已有 source
        if !channel.sources.isEmpty {
            m3u8Cache[channel.id] = channel.sources.first
            return channel.sources.first
        }

        guard let url = URL(string: channel.playURL) else { return nil }

        do {
            let (data, _) = try await session.data(from: url)
            guard let html = String(data: data, encoding: .utf8) else { return nil }

            // 提取所有匹配的URL作为多线路
            var allSources: [String] = []
            let patterns = [
                #"src\s*=\s*["']([^"']+\.m3u8[^"']*)["']"#,
                #"url\s*[:=]\s*["']([^"']+\.m3u8[^"']*)["']"#,
                #"(https?://[^\s"'<>]+\.m3u8[^\s"'<>]*)"#,
                #"var\s+url\s*=\s*["']([^"']+)["']"#,
                #"player\s*\(\s*["']([^"']+)["']"#
            ]

            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    let matches = regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
                    for match in matches {
                        guard match.numberOfRanges >= 2,
                              let range = Range(match.range(at: 1), in: html) else { continue }
                        var m3u8 = String(html[range])
                        // 处理相对路径
                        if m3u8.hasPrefix("//") { m3u8 = "https:" + m3u8 }
                        else if m3u8.hasPrefix("/") { m3u8 = baseURL + m3u8 }
                        else if !m3u8.hasPrefix("http") { m3u8 = baseURL + "/" + m3u8 }
                        if m3u8.contains(".m3u8") && !allSources.contains(m3u8) {
                            allSources.append(m3u8)
                        }
                    }
                }
            }

            // 如果都没找到，尝试iframe
            let iframePattern = #"<iframe[^>]+src=["']([^"']+)["']"#
            if let regex = try? NSRegularExpression(pattern: iframePattern, options: []),
               let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
               match.numberOfRanges >= 2,
               let range = Range(match.range(at: 1), in: html) {
                let iframeSrc = String(html[range])
                if iframeSrc.contains(".m3u8") && !allSources.contains(iframeSrc) {
                    allSources.append(iframeSrc)
                }
            }

            // 缓存第一个线路
            if let first = allSources.first {
                m3u8Cache[channel.id] = first
                return first
            }
            return nil
        } catch {
            print("[LiveTV] 解析M3U8失败: \(error)")
            return nil
        }
    }

    // MARK: - 解析频道所有可用线路
    func resolveAllSources(channel: LiveChannel) async -> [String] {
        // 先查缓存
        if let cached = m3u8Cache[channel.id], !cached.isEmpty {
            return [cached]
        }

        // 如果是订阅源，直接返回已有 sources
        if !channel.sources.isEmpty {
            return channel.sources
        }

        // 如果是央视源，使用央视专用解析
        if case .cctvLive = currentSource {
            let streams = await resolveCCTVStream(channelId: channel.channelId)
            if let first = streams.first {
                m3u8Cache[channel.id] = first
            }
            return streams
        }

        // 默认源：使用内置公开 IPTV 源映射
        let sources = resolveDefaultStream(channelId: channel.channelId, tid: channel.tid)
        if let first = sources.first {
            m3u8Cache[channel.id] = first
        }
        return sources
    }

    // MARK: - 默认源内置公开 IPTV 流地址
    private func resolveDefaultStream(channelId: String, tid: String) -> [String] {
        // 内置公开 IPTV 源映射表（央视 + 卫视 + 地方台）
        let streamMap: [String: [String]] = [
            // 央视
            "cctv1": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226016/index.m3u8"],
            "cctv2": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221225588/index.m3u8"],
            "cctv3": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226021/index.m3u8"],
            "cctv4": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226428/index.m3u8"],
            "cctv5": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226019/index.m3u8"],
            "cctv6": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226010/index.m3u8"],
            "cctv7": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221225733/index.m3u8"],
            "cctv8": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226008/index.m3u8"],
            "cctv9": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221225734/index.m3u8"],
            "cctv10": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221225730/index.m3u8"],
            "cctv11": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221225597/index.m3u8"],
            "cctv12": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221225731/index.m3u8"],
            "cctv13": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226011/index.m3u8"],
            "cctv14": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221225732/index.m3u8"],
            "cctv15": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221225601/index.m3u8"],
            "cctv16": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226100/index.m3u8"],
            "cctv17": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221225765/index.m3u8"],
            "cctv5plus": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221225603/index.m3u8"],
            // 卫视
            "hunan": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226307/index.m3u8"],
            "zhejiang": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226333/index.m3u8"],
            "jiangsu": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226310/index.m3u8"],
            "dongfang": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226345/index.m3u8"],
            "beijing": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226224/index.m3u8"],
            "shenzhen": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226313/index.m3u8"],
            "guangdong": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226180/index.m3u8"],
            "anhui": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226391/index.m3u8"],
            "dongnan": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226341/index.m3u8"],
            "tianjin": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226386/index.m3u8"],
            "shandong": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226456/index.m3u8"],
            "sichuan": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226335/index.m3u8"],
            "chongqing": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226400/index.m3u8"],
            "heilongjiang": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226327/index.m3u8"],
            "liaoning": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226261/index.m3u8"],
            "hubei": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226477/index.m3u8"],
            "jiangxi": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226344/index.m3u8"],
            "guizhou": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226397/index.m3u8"],
            "gansu": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226240/index.m3u8"],
            "henan": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226480/index.m3u8"],
            "hebei": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226401/index.m3u8"],
            "shanxi": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226392/index.m3u8"],
            "guangxi": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226388/index.m3u8"],
            "jilin": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226393/index.m3u8"],
            "yunnan": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226444/index.m3u8"],
            "sanxia": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226485/index.m3u8"],
            "neimenggu": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226389/index.m3u8"],
            "qinghai": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226367/index.m3u8"],
            "xinjiang": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226466/index.m3u8"],
            "xizang": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226465/index.m3u8"],
            "ningxia": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226462/index.m3u8"],
            "bingtuan": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226463/index.m3u8"],
            "yanbian": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226350/index.m3u8"],
            "kangba": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226464/index.m3u8"],
            "shanxi2": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226486/index.m3u8"],
            "hainan": ["http://ottrrs.hl.chinamobile.com/PLTV/88888888/224/3221226461/index.m3u8"],
        ]

        if let urls = streamMap[channelId], !urls.isEmpty {
            print("[LiveTV] 默认源内置映射: \(channelId) -> \(urls)")
            return urls
        }

        print("[LiveTV] 默认源无内置映射: \(channelId)")
        return []
    }

    // MARK: - 获取回看节目单
    func fetchEPG(channel: LiveChannel, day: String) async -> [(time: String, title: String)] {
        guard let url = URL(string: "\(baseURL)/?act=play&playtype=lookback&day=\(day)&token=\(channel.token)&tid=\(channel.tid)&id=\(channel.channelId)") else { return [] }

        do {
            let (data, _) = try await session.data(from: url)
            guard let html = String(data: data, encoding: .utf8) else { return [] }
            return parseEPG(from: html)
        } catch {
            return []
        }
    }

    private func parseEPG(from html: String) -> [(time: String, title: String)] {
        var programs: [(time: String, title: String)] = []

        // 匹配节目单: [00:17 今日说法回看]
        let pattern = #"\[(\d{2}:\d{2})\s+([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let matches = regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let time = String(html[Range(match.range(at: 1), in: html)!])
            let title = String(html[Range(match.range(at: 2), in: html)!])
                .replacingOccurrences(of: "回看", with: "")
                .trimmingCharacters(in: .whitespaces)
            programs.append((time: time, title: title))
        }

        return programs
    }

    // MARK: - 清空缓存
    func clearCache() {
        m3u8Cache.removeAll()
    }

    // MARK: - M3U 格式解析
    /// 解析 M3U 格式直播源内容
    func parseM3U(content: String) -> [SubscribeChannel] {
        var channels: [SubscribeChannel] = []
        let lines = content.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                // 解析 #EXTINF 行
                var name = ""
                var group: String? = nil
                var logo: String? = nil

                // 提取 group-title
                if let groupRange = line.range(of: #"group-title="([^"]*)""#, options: .regularExpression) {
                    let groupStr = String(line[groupRange])
                    if let valRange = groupStr.range(of: #""([^"]*)""#, options: .regularExpression) {
                        group = String(groupStr[valRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    }
                }

                // 提取 tvg-logo
                if let logoRange = line.range(of: #"tvg-logo="([^"]*)""#, options: .regularExpression) {
                    let logoStr = String(line[logoRange])
                    if let valRange = logoStr.range(of: #""([^"]*)""#, options: .regularExpression) {
                        logo = String(logoStr[valRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    }
                }

                // 提取频道名（最后一个逗号之后）
                if let commaIndex = line.lastIndex(of: ",") {
                    let nameStart = line.index(after: commaIndex)
                    name = String(line[nameStart...]).trimmingCharacters(in: .whitespaces)
                }

                // 下一行是 URL
                i += 1
                if i < lines.count {
                    let urlLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if !urlLine.isEmpty && !urlLine.hasPrefix("#") {
                        let channel = SubscribeChannel(
                            name: name.isEmpty ? "未知频道" : name,
                            url: urlLine,
                            group: group,
                            logo: logo
                        )
                        channels.append(channel)
                    }
                }
            }
            i += 1
        }
        return channels
    }

    // MARK: - TXT 格式解析
    /// 解析 TXT 格式直播源内容
    /// 格式A: 频道名,http://xxx.m3u8
    /// 格式B: 分组名,频道名,http://xxx.m3u8
    func parseTXT(content: String) -> [SubscribeChannel] {
        var channels: [SubscribeChannel] = []
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty && !trimmed.hasPrefix("#") else { continue }

            let parts = trimmed.components(separatedBy: ",")
            if parts.count == 2 {
                // 格式A: 频道名,URL
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                let url = parts[1].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty && !url.isEmpty {
                    channels.append(SubscribeChannel(
                        name: name,
                        url: url,
                        group: nil,
                        logo: nil
                    ))
                }
            } else if parts.count >= 3 {
                // 格式B: 分组名,频道名,URL
                let group = parts[0].trimmingCharacters(in: .whitespaces)
                let name = parts[1].trimmingCharacters(in: .whitespaces)
                let url = parts[2].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty && !url.isEmpty {
                    channels.append(SubscribeChannel(
                        name: name,
                        url: url,
                        group: group.isEmpty ? nil : group,
                        logo: nil
                    ))
                }
            }
        }
        return channels
    }

    // MARK: - 从 URL 获取并解析订阅源
    func fetchSubscribeChannels(url: String) async {
        guard let requestURL = URL(string: url) else {
            print("[LiveTV] 订阅源 URL 无效: \(url)")
            return
        }

        do {
            let (data, response) = try await session.data(from: requestURL)
            guard let content = String(data: data, encoding: .utf8) else {
                print("[LiveTV] 订阅源内容编码错误")
                return
            }

            // 根据内容判断格式
            let parsed: [SubscribeChannel]
            if content.trimmingCharacters(in: .whitespaces).hasPrefix("#EXTM3U") {
                parsed = parseM3U(content: content)
            } else {
                parsed = parseTXT(content: content)
            }

            await MainActor.run {
                self.subscribeChannels = parsed
            }
            print("[LiveTV] 订阅源解析成功: \(parsed.count) 个频道")
        } catch {
            print("[LiveTV] 获取订阅源失败: \(error)")
        }
    }
}

// MARK: - Array JSON 编码扩展
extension Array where Element == String {
    func toJSONEncodedString() -> String {
        let parts = self.map { s -> String in
            // 转义双引号和反斜杠
            let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
            return "\"\(escaped)\""
        }
        return "[\(parts.joined(separator: ","))]"
    }
}
