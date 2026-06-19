import Foundation
import SwiftUI

// MARK: - 直播源类型
enum LiveSourceType: Identifiable, Equatable, Codable {
    case defaultIPTV      // 默认源一 (APTV)
    case defaultIPTV2     // 默认源二 (YueChan)
    case subscribe(name: String, url: String)  // 订阅配置中的源
    case custom(name: String, url: String)     // 用户自定义源

    var id: String {
        switch self {
        case .defaultIPTV:
            return "default_iptv_1"
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
        case .defaultIPTV:
            return "默认源一 (IPv4多线路)"
        case .defaultIPTV2:
            return "默认源二 (YueChan)"
        case .subscribe(let name, _):
            return name
        case .custom(let name, _):
            return name
        }
    }

    var sourceURL: String? {
        switch self {
        case .defaultIPTV:
            return "https://raw.githubusercontent.com/bjzhou/iptv-collector/output/iptv.m3u"
        case .defaultIPTV2:
            return "https://raw.githubusercontent.com/YueChan/Live/refs/heads/main/APTV.m3u"
        case .subscribe(_, let url):
            return url
        case .custom(_, let url):
            return url
        }
    }

    var isDefault: Bool {
        switch self {
        case .defaultIPTV, .defaultIPTV2:
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
        case defaultIPTV, defaultIPTV2, subscribe, custom
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .defaultIPTV:
            try container.encode(SourceKind.defaultIPTV.rawValue, forKey: .type)
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
        case .defaultIPTV:
            self = .defaultIPTV
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
        case "defaultIPTV":
            self = .defaultIPTV
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
        case .defaultIPTV:
            return ["type": "defaultIPTV"]
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

    /// 动态分类列表（从 group-title 生成）
    @Published var dynamicCategories: [LiveCategory] = []

    /// 用户自定义源列表（从 UserDefaults 读取）
    @Published var customSources: [LiveSourceType] = []

    /// 本地导入的频道缓存 [源名称: 频道列表]
    @Published var localChannelsMap: [String: [SubscribeChannel]] = [:]

    /// 所有可用源列表
    var availableSources: [LiveSourceType] {
        var sources: [LiveSourceType] = [.defaultIPTV, .defaultIPTV2]
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

        if let url = source.sourceURL {
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
        // 回看功能需要源支持，当前M3U订阅源不支持回看
        return []
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
}
