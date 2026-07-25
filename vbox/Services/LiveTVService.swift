import Foundation
import SwiftUI

// MARK: - 直播源类型
enum LiveSourceType: Identifiable, Equatable, Codable {
    case yangshipin       // 央视频（内置直播源，替换默认源1）
    case defaultIPTV2     // 默认源2 (运营商IPTV)
    case subscribe(name: String, url: String)  // 订阅配置中的源
    case custom(name: String, url: String)     // 用户自定义源

    var id: String {
        switch self {
        case .yangshipin:
            return "yangshipin"
        case .defaultIPTV2:
            return "default_iptv_2"
        case .subscribe(let name, let url):
            return "subscribe_\(name)_\(url)"
        case .custom(let name, let url):
            return "custom_\(name)_\(url)"
        }
    }

    var displayName: String {
        switch self {
        case .yangshipin:
            return "默认源1 (央视频)"
        case .defaultIPTV2:
            return "默认源2 (运营商IPTV)"
        case .subscribe(let name, _):
            return name
        case .custom(let name, _):
            return name
        }
    }

    var sourceURL: String? {
        switch self {
        case .yangshipin:
            return nil  // 央视频使用内置频道数据，无需 URL
        case .defaultIPTV2:
            return "http://mg.earxo.com/itv_ANGEHPV3YLVD/m3u"
        case .subscribe(_, let url):
            return url
        case .custom(_, let url):
            return url
        }
    }

    var isDefault: Bool {
        switch self {
        case .yangshipin, .defaultIPTV2:
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
        case yangshipin, defaultIPTV2, subscribe, custom
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .yangshipin:
            try container.encode(SourceKind.yangshipin.rawValue, forKey: .type)
        case .defaultIPTV2:
            try container.encode(SourceKind.defaultIPTV2.rawValue, forKey: .type)
        case .subscribe(let name, let url):
            try container.encode(SourceKind.subscribe.rawValue, forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(url, forKey: .url)
        case .custom(let name, let url):
            try container.encode(SourceKind.custom.rawValue, forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(url, forKey: .url)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(SourceKind.self, forKey: .type)
        switch type {
        case .yangshipin:
            self = .yangshipin
        case .defaultIPTV2:
            self = .defaultIPTV2
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
}

// MARK: - LiveSourceType 字典初始化扩展
extension LiveSourceType {
    init?(dictionary: [String: String]) {
        guard let type = dictionary["type"] else { return nil }
        switch type {
        case "yangshipin":
            self = .yangshipin
        case "defaultIPTV2":
            self = .defaultIPTV2
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
        case .yangshipin:
            return ["type": "yangshipin"]
        case .defaultIPTV2:
            return ["type": "defaultIPTV2"]
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

    /// 播放地址：优先返回 sources[0]，否则返回空字符串
    var playURL: String {
        if let first = sources.first, !first.isEmpty {
            return first
        }
        return ""
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
struct LiveCategory: Identifiable, Equatable {
    let id: String
    let name: String
    let tid: String
    let icon: String
    let logo: String?

    /// 根据 index 循环分配颜色
    static let palette: [Color] = [
        .blue, .green, .red, .orange, .purple,
        .pink, .cyan, .teal, .indigo, .yellow,
        .mint, .brown
    ]

    var tintColor: Color {
        guard let idx = Int(id.components(separatedBy: "_").last ?? "0"),
              idx >= 0 else {
            return Color.gray
        }
        return LiveCategory.palette[idx % LiveCategory.palette.count]
    }

    var backgroundColor: Color { tintColor }
}

// MARK: - 直播服务
class LiveTVService: ObservableObject {
    static let shared = LiveTVService()
    private let session: URLSession

    /// M3U8缓存 [channelId: m3u8URL]
    var m3u8Cache: [String: String] = [:]

    /// 当前直播源
    @Published var currentSource: LiveSourceType = .yangshipin {
        didSet {
            // 切换源时清空缓存
            clearCache()
            // 保存当前源到 UserDefaults
            saveCurrentSource()
        }
    }

    /// 订阅源频道列表（当前订阅源的频道）
    @Published var subscribeChannels: [SubscribeChannel] = []

    /// 动态分类列表（从 group-title 生成）
    @Published var dynamicCategories: [LiveCategory] = []

    /// 用户自定义源列表（从 UserDefaults 读取）
    @Published var customSources: [LiveSourceType] = []

    /// 本地导入的频道缓存 [源名称: 频道列表]
    @Published var localChannelsMap: [String: [SubscribeChannel]] = [:]

    /// 所有可用源列表
    var availableSources: [LiveSourceType] {
        var sources: [LiveSourceType] = [.yangshipin, .defaultIPTV2]
        // 可以从配置文件读取的订阅源
        sources.append(contentsOf: configSubscribeSources)
        // 用户自定义源
        sources.append(contentsOf: customSources)
        return sources
    }

    /// 配置文件中预定义的订阅源
    private var configSubscribeSources: [LiveSourceType] = []

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
        subscribeChannels = [] // 清空缓存，强制重新加载
        dynamicCategories = []

        if case .yangshipin = source {
            // 央视频使用内置频道数据
            loadYangshipinChannels()
            buildYangshipinCategories()
        } else if let url = source.sourceURL {
            // 如果是本地导入的源，从缓存加载
            if url.hasPrefix("local://") {
                let localName = String(url.dropFirst(8))
                subscribeChannels = localChannelsMap[localName] ?? []
                buildDynamicCategories()
            } else {
                Task {
                    await fetchSubscribeChannels(url: url)
                }
            }
        }
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
            currentSource = .yangshipin
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
        var dict: [String: [[String: String?]]] = [:]
        for (key, channels) in localChannelsMap {
            dict[key] = channels.map { [
                "name": $0.name,
                "url": $0.url,
                "group": $0.group,
                "logo": $0.logo
            ]}
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            UserDefaults.standard.set(data, forKey: "live_tv_local_channels")
        }
    }

    /// 从 UserDefaults 加载本地频道
    private func loadLocalChannels() {
        guard let data = UserDefaults.standard.data(forKey: "live_tv_local_channels"),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: String?]]] else {
            return
        }
        for (key, channelDicts) in dict {
            localChannelsMap[key] = channelDicts.compactMap { d in
                let nameVal = (d["name"] ?? nil) ?? "未知"
                let urlVal = (d["url"] ?? nil) ?? ""
                return SubscribeChannel(
                    name: nameVal,
                    url: urlVal,
                    group: d["group"] ?? nil,
                    logo: d["logo"] ?? nil
                )
            }
        }
    }

    // MARK: - 动态分类构建

    /// 从 subscribeChannels 的 group-title 提取唯一分组，生成动态分类
    func buildDynamicCategories() {
        var groupMap: [String: (channels: [SubscribeChannel], firstLogo: String?)] = [:]
        var insertionOrder: [String] = []

        for ch in subscribeChannels {
            let groupName = ch.group ?? "其他"
            if groupMap[groupName] == nil {
                insertionOrder.append(groupName)
                groupMap[groupName] = (channels: [], firstLogo: nil)
            }
            groupMap[groupName]!.channels.append(ch)
            // logo 取该分组中第一个有 logo 的频道
            if groupMap[groupName]!.firstLogo == nil, let logo = ch.logo, !logo.isEmpty {
                groupMap[groupName]!.firstLogo = logo
            }
        }

        var categories: [LiveCategory] = []
        for (index, groupName) in insertionOrder.enumerated() {
            guard let info = groupMap[groupName] else { continue }
            let cat = LiveCategory(
                id: "cat_\(index)",
                name: groupName,
                tid: groupName,
                icon: "tv",
                logo: info.firstLogo
            )
            categories.append(cat)
        }

        dynamicCategories = categories
    }

    // MARK: - 获取分类频道列表
    func fetchChannels(tid: String) async -> [LiveChannel] {
        // 央视频分类
        if tid.hasPrefix("ysp_") {
            return fetchYangshipinChannels(forTid: tid)
        }

        // 统一使用 dynamicCategories
        if dynamicCategories.isEmpty {
            if let url = currentSource.sourceURL {
                if subscribeChannels.isEmpty {
                    // 本地源已从 localChannelsMap 同步加载，无需网络请求
                    if url.hasPrefix("local://") {
                        let localName = String(url.dropFirst(8))
                        subscribeChannels = localChannelsMap[localName] ?? []
                        buildDynamicCategories()
                    } else {
                        await fetchSubscribeChannels(url: url)
                    }
                }
            }
        }
        return await fetchChannelsForGroup(groupName: tid)
    }

    // MARK: - 按分组名精确匹配过滤频道
    private func fetchSubscribeChannelsForTid(tid: String) async -> [LiveChannel] {
        // 如果 subscribeChannels 为空，先尝试获取
        if subscribeChannels.isEmpty, let url = currentSource.sourceURL {
            await fetchSubscribeChannels(url: url)
        }

        // 按 group-title 精确匹配过滤频道
        let filtered = subscribeChannels.filter { ch in
            guard let group = ch.group else { return tid == "其他" }
            return group == tid
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

    // MARK: - 按分组名过滤频道，同名频道自动合并多线路
    func fetchChannelsForGroup(groupName: String) async -> [LiveChannel] {
        // 如果 subscribeChannels 为空，先尝试获取
        if subscribeChannels.isEmpty, let url = currentSource.sourceURL {
            await fetchSubscribeChannels(url: url)
        }

        // 按 group-title 精确匹配过滤频道
        let filtered = subscribeChannels.filter { ch in
            guard let group = ch.group else { return groupName == "其他" }
            return group == groupName
        }

        // 按 channel name 分组，同名频道合并多线路
        var mergedMap: [String: (sources: [String], logo: String?, firstURL: String)] = [:]
        var insertionOrder: [String] = []

        for ch in filtered {
            if mergedMap[ch.name] == nil {
                insertionOrder.append(ch.name)
                mergedMap[ch.name] = (sources: [], logo: nil, firstURL: ch.url)
            }
            mergedMap[ch.name]!.sources.append(ch.url)
            // logo 取第一个有 logo 的
            if mergedMap[ch.name]!.logo == nil, let logo = ch.logo, !logo.isEmpty {
                mergedMap[ch.name]!.logo = logo
            }
        }

        var channels: [LiveChannel] = []
        for name in insertionOrder {
            guard let info = mergedMap[name] else { continue }
            let channel = LiveChannel(
                id: "sub_\(name)_\(info.firstURL)",
                name: name,
                tid: groupName,
                channelId: info.firstURL,
                token: "",
                logo: info.logo,
                sources: info.sources
            )
            channels.append(channel)
        }

        return channels
    }

    // MARK: - 解析频道所有可用线路
    func resolveAllSources(channel: LiveChannel) async -> [String] {
        // 央视频频道：动态获取播放地址
        if channel.id.hasPrefix("ysp_") {
            if let yspChannel = yangshipinChannels.first(where: { $0.key == channel.id.replacingOccurrences(of: "ysp_", with: "") }) {
                if let playURL = await fetchYangshipinPlayURL(for: yspChannel) {
                    return [playURL]
                }
            }
            return []
        }

        // 直接返回频道已有的 sources（M3U订阅源中已包含播放地址）
        if !channel.sources.isEmpty {
            return channel.sources
        }

        // 如果频道有 playURL，尝试直接返回
        if !channel.playURL.isEmpty, channel.playURL.hasPrefix("http") {
            return [channel.playURL]
        }

        return []
    }

    // MARK: - 获取回看节目单
    func fetchEPG(channel: LiveChannel, day: String) async -> [(time: String, title: String)] {
        // EPG接口已失效，直接返回空
        return []
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
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

                // fallback: 从 tvg-name 提取
                if name.isEmpty {
                    if let nameRange = line.range(of: #"tvg-name="([^"]*)""#, options: .regularExpression) {
                        let nameStr = String(line[nameRange])
                        if let valRange = nameStr.range(of: #""([^"]*)""#, options: .regularExpression) {
                            name = String(nameStr[valRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        }
                    }
                }

                // 跳过分组标记（以 ** 开头的名称，如 **NOTÍCIAS**）
                if name.hasPrefix("**") {
                    i += 1
                    continue
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
                self.buildDynamicCategories()
            }
            print("[LiveTV] 订阅源解析成功: \(parsed.count) 个频道")
        } catch {
            print("[LiveTV] 获取订阅源失败: \(error)")
        }
    }

    // MARK: - 央视频频道数据

    /// 央视频频道模型
    struct YangshipinChannel {
        let key: String
        let cnlid: String
        let livepid: String
        let defn: String
        let displayName: String
        let logo: String
    }

    /// 央视频分类模型
    struct YangshipinCategory {
        let name: String
        let ids: [String]
    }

    /// 央视频频道台标
    private static let yangshipinLogos: [String: String] = [
        "cctv1": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTV1.png",
        "cctv2": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTV2.png",
        "cctv3": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTV3.png",
        "cctv4": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTV4.png",
        "cctv5": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTV5.png",
        "cctv5p": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTV5plus.png",
        "cctv6": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTV6.png",
        "cctv7": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTV7.png",
        "cctv8": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTV8.png",
        "cctv9": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTV9.png",
        "cctv10": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTV10.png",
        "cctv11": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTV11.png",
        "cctv12": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTV12.png",
        "cctv13": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTV13.png",
        "cctv14": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTV14.png",
        "cctv15": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTV15.png",
        "cctv16": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTV16.png",
        "cctv164k": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTV16.png",
        "cctv17": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTV17.png",
        "cctv4k": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTV4K.png",
        "cctv8k": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTV8K.png",
        "cgtn": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CGTN.png",
        "cgtnfy": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CGTNfy.png",
        "cgtney": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CGTNey.png",
        "cgtnalby": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CGTNalby.png",
        "cgtnxby": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CGTNxbyy.png",
        "cgtnwyjl": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CGTNjilu.png",
        "cctvfyjc": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTVfyjc.png",
        "cctvdyjc": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTVdyjc.png",
        "cctvhjjc": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTVhjjc.png",
        "cctvsjdl": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTVsjdl.png",
        "cctvfyyy": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTVfyyy.png",
        "cctvbqkj": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTVbqkj.png",
        "cctvfyzq": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTVfyzq.png",
        "cctvgeqwq": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTVgefwq.png",
        "cctvnxss": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTVnxss.png",
        "cctvyswhjp": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTVyswhjp.png",
        "cctvystq": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTVystq.png",
        "cctvdszn": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTVdszn.png",
        "cctvwsjk": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CCTVwsjk.png",
        "bjws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Beijing.png",
        "jsws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Jiangsu.png",
        "dfws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Dongfang.png",
        "zjws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Zhejiang.png",
        "hnws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Hunan.png",
        "hbws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Hubei.png",
        "gdws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Guangdong.png",
        "gxws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Guangxi.png",
        "hljws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Heilongjiang.png",
        "hnws2": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Hainan.png",
        "cqws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Chongqing.png",
        "szws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Shenzhen.png",
        "scws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Sichuan.png",
        "henanws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Henan.png",
        "fjdnhz": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Dongnan.png",
        "gzhws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Guizhou.png",
        "jxws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Jiangxi.png",
        "lnws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Liaoning.png",
        "ahws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Anhui.png",
        "hbws2": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Hebei.png",
        "sdws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Shandong.png",
        "tjws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Tianjin.png",
        "jlws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Jilin.png",
        "shanxiws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Shanxi.png",
        "nxws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Ningxia.png",
        "nmgws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Neimeng.png",
        "ynws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Yunnan.png",
        "shanxiws2": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Shanxi_.png",
        "qhws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Qinghai.png",
        "xzws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Xizang.png",
        "xjws": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/Xinjiang.png",
        "cetv1": "https://cdn.jsdelivr.net/gh/wanglindl/TVlogo@main/img/CETV1.png",
        "gxpd": ""
    ]

    /// 央视频频道原始数据 [key: [cnlid, livepid, defn, displayName]]
    private static let yangshipinRawData: [String: [String]] = [
        "cctv1":     ["2024078201", "600001859", "fhd", "CCTV-1"],
        "cctv2":     ["2024075401", "600001800", "fhd", "CCTV-2"],
        "cctv3":     ["2024068501", "600001801", "fhd", "CCTV-3"],
        "cctv4":     ["2029797101", "600001814", "fhd", "CCTV-4"],
        "cctv5":     ["2024078401", "600001818", "fhd", "CCTV-5"],
        "cctv5p":    ["2024078001", "600001817", "fhd", "CCTV-5+"],
        "cctv6":     ["2013693901", "600108442", "fhd", "CCTV-6"],
        "cctv7":     ["2024072001", "600004092", "fhd", "CCTV-7"],
        "cctv8":     ["2029793001", "600001803", "fhd", "CCTV-8"],
        "cctv9":     ["2024078601", "600004078", "fhd", "CCTV-9"],
        "cctv10":    ["2024078701", "600001805", "fhd", "CCTV-10"],
        "cctv11":    ["2027248701", "600001806", "fhd", "CCTV-11"],
        "cctv12":    ["2027248801", "600001807", "fhd", "CCTV-12"],
        "cctv13":    ["2029797201", "600001811", "fhd", "CCTV-13"],
        "cctv14":    ["2027248901", "600001809", "fhd", "CCTV-14"],
        "cctv15":    ["2027249001", "600001815", "fhd", "CCTV-15"],
        "cctv16":    ["2027249101", "600098637", "fhd", "CCTV-16"],
        "cctv164k":  ["2027249301", "600099502", "fhd", "CCTV-16(4K)"],
        "cctv17":    ["2027249401", "600001810", "fhd", "CCTV-17"],
        "cctv4k":    ["2029810301", "600002264", "fhd", "CCTV-4K"],
        "cctv8k":    ["2026774101", "600156816", "fhd", "CCTV-8K"],
        "cgtn":      ["2024181701", "600014550", "fhd", "CGTN"],
        "cgtnfy":    ["2024181801", "600084704", "fhd", "CGTN法语"],
        "cgtney":    ["2024181901", "600084758", "fhd", "CGTN俄语"],
        "cgtnalby":  ["2024182001", "600084782", "fhd", "CGTN阿拉伯语"],
        "cgtnxby":   ["2024182101", "600084744", "fhd", "CGTN西班牙语"],
        "cgtnwyjl":  ["2024182301", "600084781", "fhd", "CGTN外语纪录"],
        "cctvfyjc":  ["2025637103", "600099658", "shd", "风云剧场"],
        "cctvdyjc":  ["2026874203", "600099655", "shd", "第一剧场"],
        "cctvhjjc":  ["2026874303", "600099620", "shd", "怀旧剧场"],
        "cctvsjdl":  ["2026874403", "600099637", "shd", "世界地理"],
        "cctvfyyy":  ["2026874503", "600099660", "shd", "风云音乐"],
        "cctvbqkj":  ["2026874603", "600099649", "shd", "兵器科技"],
        "cctvfyzq":  ["2026966203", "600099636", "shd", "风云足球"],
        "cctvgeqwq": ["2026874703", "600099659", "shd", "高尔夫·网球"],
        "cctvnxss":  ["2026874803", "600099650", "shd", "女性时尚"],
        "cctvyswhjp":["2026874903", "600099653", "shd", "央视文化精品"],
        "cctvystq":  ["2026875003", "600099652", "shd", "央视台球"],
        "cctvdszn":  ["2026875103", "600099656", "shd", "电视指南"],
        "cctvwsjk":  ["2025637003", "600099651", "shd", "卫生健康"],
        "bjws":      ["2024052703", "600002309", "fhd", "北京卫视"],
        "jsws":      ["2024171103", "600002521", "fhd", "江苏卫视"],
        "dfws":      ["2024054503", "600002483", "fhd", "东方卫视"],
        "zjws":      ["2024054703", "600002520", "fhd", "浙江卫视"],
        "hnws":      ["2024054803", "600002475", "fhd", "湖南卫视"],
        "hbws":      ["2024171203", "600002508", "fhd", "湖北卫视"],
        "gdws":      ["2024060903", "600002485", "fhd", "广东卫视"],
        "gxws":      ["2024060703", "600002509", "fhd", "广西卫视"],
        "hljws":     ["2029797003", "600002498", "fhd", "黑龙江卫视"],
        "hnws2":     ["2024055603", "600002506", "fhd", "海南卫视"],
        "cqws":      ["2024061103", "600002531", "fhd", "重庆卫视"],
        "szws":      ["2024061303", "600002481", "fhd", "深圳卫视"],
        "scws":      ["2024061403", "600002516", "fhd", "四川卫视"],
        "henanws":   ["2029797303", "600002525", "fhd", "河南卫视"],
        "fjdnhz":    ["2024061503", "600002484", "fhd", "福建东南卫视"],
        "gzhws":     ["2024061603", "600002490", "fhd", "贵州卫视"],
        "jxws":      ["2024061703", "600002503", "fhd", "江西卫视"],
        "lnws":      ["2024171303", "600002505", "fhd", "辽宁卫视"],
        "ahws":      ["2024171403", "600002532", "fhd", "安徽卫视"],
        "hbws2":     ["2024171503", "600002493", "fhd", "河北卫视"],
        "sdws":      ["2029787903", "600002513", "fhd", "山东卫视"],
        "tjws":      ["2019927003", "600152137", "fhd", "天津卫视"],
        "jlws":      ["2025561503", "600190405", "fhd", "吉林卫视"],
        "shanxiws":  ["2029795103", "600190400", "fhd", "陕西卫视"],
        "nxws":      ["2025608503", "600190737", "fhd", "宁夏卫视"],
        "nmgws":     ["2025561203", "600190401", "fhd", "内蒙古卫视"],
        "ynws":      ["2025561303", "600190402", "fhd", "云南卫视"],
        "shanxiws2": ["2025560803", "600190407", "fhd", "山西卫视"],
        "qhws":      ["2025559103", "600190406", "fhd", "青海卫视"],
        "xzws":      ["2025558003", "600190403", "fhd", "西藏卫视"],
        "xjws":      ["2019927403", "600152138", "fhd", "新疆卫视"],
        "cetv1":     ["2022823801", "600171827", "fhd", "中国教育电视台"],
        "gxpd":      ["2029360403", "600213139", "fhd", "国学频道"]
    ]

    /// 央视频分类定义
    private static let yangshipinCats: [YangshipinCategory] = [
        YangshipinCategory(name: "央视", ids: [
            "cctv1", "cctv2", "cctv3", "cctv4", "cctv5", "cctv5p",
            "cctv6", "cctv7", "cctv8", "cctv9", "cctv10", "cctv11",
            "cctv12", "cctv13", "cctv14", "cctv15", "cctv16", "cctv164k",
            "cctv17", "cctv4k", "cctv8k"
        ]),
        YangshipinCategory(name: "CGTN", ids: [
            "cgtn", "cgtnfy", "cgtney", "cgtnalby", "cgtnxby", "cgtnwyjl"
        ]),
        YangshipinCategory(name: "央视付费", ids: [
            "cctvfyjc", "cctvdyjc", "cctvhjjc", "cctvsjdl", "cctvfyyy",
            "cctvbqkj", "cctvfyzq", "cctvgeqwq", "cctvnxss", "cctvyswhjp",
            "cctvystq", "cctvdszn", "cctvwsjk"
        ]),
        YangshipinCategory(name: "卫视", ids: [
            "bjws", "jsws", "dfws", "zjws", "hnws", "hbws", "gdws",
            "gxws", "hljws", "hnws2", "cqws", "szws", "scws", "henanws",
            "fjdnhz", "gzhws", "jxws", "lnws", "ahws", "hbws2", "sdws",
            "tjws", "jlws", "shanxiws", "nxws", "nmgws", "ynws",
            "shanxiws2", "qhws", "xzws", "xjws"
        ]),
        YangshipinCategory(name: "其他", ids: [
            "cetv1", "gxpd"
        ])
    ]

    /// 已解析的央视频频道列表
    @Published var yangshipinChannels: [YangshipinChannel] = []

    /// 央视频分类列表
    @Published var yangshipinCategories: [LiveCategory] = []

    // MARK: - 央视频频道加载

    /// 加载央视频内置频道数据
    func loadYangshipinChannels() {
        var channels: [YangshipinChannel] = []
        for (key, data) in Self.yangshipinRawData {
            guard data.count >= 4 else { continue }
            let logo = Self.yangshipinLogos[key] ?? ""
            channels.append(YangshipinChannel(
                key: key,
                cnlid: data[0],
                livepid: data[1],
                defn: data[2],
                displayName: data[3],
                logo: logo
            ))
        }
        yangshipinChannels = channels
    }

    /// 构建央视频分类列表
    func buildYangshipinCategories() {
        var cats: [LiveCategory] = []
        for (idx, cat) in Self.yangshipinCats.enumerated() {
            // 取第一个频道台标作为分类图标
            let firstLogo = cat.ids.first.flatMap { Self.yangshipinLogos[$0] }
            cats.append(LiveCategory(
                id: "ysp_cat_\(idx)",
                name: cat.name,
                tid: "ysp_\(idx)",
                icon: "tv",
                logo: firstLogo
            ))
        }
        yangshipinCategories = cats
    }

    // MARK: - 央视频播放地址获取

    /// 获取央视频频道的播放地址
    /// - Parameter channel: 央视频频道
    /// - Returns: 播放 URL，失败返回 nil
    func fetchYangshipinPlayURL(for channel: YangshipinChannel) async -> String? {
        let guid = YangshipinCrypto.genGUID()
        let (ckey, timestamp) = YangshipinCrypto.genCKey(cnlid: channel.cnlid, guid: guid)
        let flowid = YangshipinCrypto.genFlowID()

        var urlComponents = URLComponents(string: "https://bkliveinfo.ysp.cctv.cn")!
        urlComponents.queryItems = [
            URLQueryItem(name: "atime", value: "120"),
            URLQueryItem(name: "livepid", value: channel.livepid),
            URLQueryItem(name: "cnlid", value: channel.cnlid),
            URLQueryItem(name: "appVer", value: "V8.22.1035.3031"),
            URLQueryItem(name: "app_version", value: "300090"),
            URLQueryItem(name: "caplv", value: "1"),
            URLQueryItem(name: "cmd", value: "2"),
            URLQueryItem(name: "defn", value: channel.defn),
            URLQueryItem(name: "device", value: "iPhone"),
            URLQueryItem(name: "encryptVer", value: "4.2"),
            URLQueryItem(name: "getpreviewinfo", value: "0"),
            URLQueryItem(name: "hevclv", value: "33"),
            URLQueryItem(name: "lang", value: "zh-Hans_JP"),
            URLQueryItem(name: "livequeue", value: "0"),
            URLQueryItem(name: "logintype", value: "1"),
            URLQueryItem(name: "nettype", value: "1"),
            URLQueryItem(name: "newnettype", value: "1"),
            URLQueryItem(name: "newplatform", value: "4330403"),
            URLQueryItem(name: "platform", value: "4330403"),
            URLQueryItem(name: "sdtfrom", value: "v3021"),
            URLQueryItem(name: "spacode", value: "23"),
            URLQueryItem(name: "spaudio", value: "1"),
            URLQueryItem(name: "spdemuxer", value: "6"),
            URLQueryItem(name: "spdrm", value: "2"),
            URLQueryItem(name: "spdynamicrange", value: "7"),
            URLQueryItem(name: "spflv", value: "1"),
            URLQueryItem(name: "spflvaudio", value: "1"),
            URLQueryItem(name: "sphdrfps", value: "60"),
            URLQueryItem(name: "sphttps", value: "0"),
            URLQueryItem(name: "spvcode", value: "MSgzMDoyMTYwLDYwOjIxNjB8MzA6MjE2MCw2MDoyMTYwKTsyKDMwOjIxNjAsNjA6MjE2MHwzMDoyMTYwLDYwOjIxNjAp"),
            URLQueryItem(name: "spvideo", value: "4"),
            URLQueryItem(name: "stream", value: "1"),
            URLQueryItem(name: "system", value: "1"),
            URLQueryItem(name: "sysver", value: "ios18.2.1"),
            URLQueryItem(name: "uhd_flag", value: "4"),
            URLQueryItem(name: "cKey", value: ckey),
            URLQueryItem(name: "guid", value: guid),
            URLQueryItem(name: "fntick", value: "\(timestamp)"),
            URLQueryItem(name: "flowid", value: flowid),
            URLQueryItem(name: "playbacktime", value: "0")
        ]

        guard let url = urlComponents.url else {
            print("[LiveTV] 央视频播放地址 URL 构建失败")
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("qqlive", forHTTPHeaderField: "User-Agent")
            request.setValue("Keep-Alive", forHTTPHeaderField: "Connection")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15

            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let iretcode = json["iretcode"] as? Int, iretcode == 0,
               let playurl = json["playurl"] as? String {
                print("[LiveTV] 央视频播放地址获取成功: \(channel.displayName)")
                return playurl
            } else {
                print("[LiveTV] 央视频播放地址获取失败: \(channel.displayName)")
                return nil
            }
        } catch {
            print("[LiveTV] 央视频播放地址请求异常: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 央视频频道按分类获取

    /// 按分类获取央视频频道列表
    func fetchYangshipinChannels(forTid tid: String) -> [LiveChannel] {
        guard tid.hasPrefix("ysp_"),
              let catIdx = Int(tid.replacingOccurrences(of: "ysp_", with: "")),
              catIdx >= 0, catIdx < Self.yangshipinCats.count else {
            return []
        }

        let cat = Self.yangshipinCats[catIdx]
        return cat.ids.compactMap { key -> LiveChannel? in
            guard let data = Self.yangshipinRawData[key], data.count >= 4,
                  let channel = yangshipinChannels.first(where: { $0.key == key }) else {
                return nil
            }
            return LiveChannel(
                id: "ysp_\(key)",
                name: channel.displayName,
                tid: tid,
                channelId: channel.cnlid,
                token: channel.livepid,
                logo: channel.logo,
                sources: []
            )
        }
    }
}
