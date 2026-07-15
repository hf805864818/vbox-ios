import Foundation
import Combine

// MARK: - 通用福利平台服务协议
protocol FuliPlatformService: ObservableObject {
    /// 平台唯一名称（与 WelfareSettingsView 中配置一致）
    var platformName: String { get }
    /// 默认域名列表
    var defaultHosts: [String] { get }
    /// 当前选中的可用域名
    var currentHost: String { get set }
    /// 域名是否已就绪
    var isHostReady: Bool { get set }

    /// 通用 HTTP headers
    func defaultHeaders(host: String) -> [String: String]

    /// 解析首页分类 + 推荐视频
    func fetchHomeContent() async -> FuliHomeResult
    /// 解析分类/子分类视频列表
    func fetchCategoryContent(category: FuliCategory, subCategory: FuliCategory?, page: Int) async -> FuliCategoryResult
    /// 解析视频详情（含剧集）
    func fetchDetail(vodId: String) async -> FuliDetail
    /// 搜索
    func fetchSearch(keyword: String, page: Int) async -> FuliSearchResult
    /// 获取播放地址（默认直接返回剧集 URL）
    func fetchPlayerURL(episode: FuliEpisode) async -> FuliPlayerResult

    /// 域名管理
    func reprobe()
    func resetDomain()
}

// MARK: - 默认实现（域名探测 + HTTP 工具）
extension FuliPlatformService {

    var allHosts: [String] {
        let customs = WelfareDomainStore.shared.domains(for: platformName)
        return customs + defaultHosts
    }

    func defaultHeaders(host: String) -> [String: String] {
        [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Connection": "keep-alive",
            "Cache-Control": "no-cache",
            "Origin": host,
            "Referer": "\(host)/"
        ]
    }

    var session: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }

    func reprobe() {
        guard let obj = self as? FuliBaseService else { return }
        obj.currentHost = ""
        obj.isHostReady = false
        Task { _ = await probeHost() }
    }

    func resetDomain() {
        WelfareDomainStore.shared.clearDomains(for: platformName)
        reprobe()
    }

    @discardableResult
    func probeHost() async -> String {
        let hosts = allHosts
        for host in hosts {
            guard let url = URL(string: host) else { continue }
            var req = URLRequest(url: url)
            defaultHeaders(host: host).forEach { req.setValue($1, forHTTPHeaderField: $0) }
            do {
                let (_, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else { continue }
                if let obj = self as? FuliBaseService {
                    await MainActor.run {
                        obj.currentHost = host
                        obj.isHostReady = true
                    }
                }
                print("[\(platformName)] 选用站点: \(host)")
                return host
            } catch {
                print("[\(platformName)] 探测失败 \(host): \(error.localizedDescription)")
                continue
            }
        }
        let fallback = hosts.first ?? defaultHosts.first ?? ""
        if let obj = self as? FuliBaseService {
            await MainActor.run {
                obj.currentHost = fallback
                obj.isHostReady = true
            }
        }
        return fallback
    }

    func fetchHTML(_ path: String) async throws -> String {
        let urlStr: String
        if path.hasPrefix("http") {
            urlStr = path
        } else {
            urlStr = currentHost + (path.hasPrefix("/") ? path : "/\(path)")
        }
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        defaultHeaders(host: currentHost).forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        return html
    }

    func fetchData(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        defaultHeaders(host: currentHost).forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    func fetchPlayerURL(episode: FuliEpisode) async -> FuliPlayerResult {
        let direct = episode.url.contains(".m3u8") || episode.url.contains(".mp4") || episode.url.contains(".ts")
        return FuliPlayerResult(url: episode.url, headers: defaultHeaders(host: currentHost), parse: direct ? 0 : 1)
    }
}

// MARK: - 基类（用于 @Published 状态管理）
class FuliBaseService: ObservableObject, FuliPlatformService {
    let platformName: String
    let defaultHosts: [String]

    @Published var currentHost: String = ""
    @Published var isHostReady: Bool = false

    init(platformName: String, defaultHosts: [String]) {
        self.platformName = platformName
        self.defaultHosts = defaultHosts
    }

    func fetchHomeContent() async -> FuliHomeResult { .empty }
    func fetchCategoryContent(category: FuliCategory, subCategory: FuliCategory?, page: Int) async -> FuliCategoryResult {
        FuliCategoryResult(videos: [], page: page, hasMore: false)
    }
    func fetchDetail(vodId: String) async -> FuliDetail {
        FuliDetail(vodId: vodId, vodName: "", vodPic: "", vodContent: nil, playFrom: platformName, episodes: [])
    }
    func fetchSearch(keyword: String, page: Int) async -> FuliSearchResult {
        FuliSearchResult(videos: [], page: page, hasMore: false)
    }
}
