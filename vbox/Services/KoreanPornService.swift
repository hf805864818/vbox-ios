import Foundation

// MARK: - 韩国色情电影 数据模型

struct KoreanPornCategory: Identifiable {
    var id: String { cid }
    let cid: String
    let name: String
}

struct KoreanPornVideo: Identifiable {
    var id: String { vodId }
    let vodId: String
    let title: String
    let cover: String
    let pageUrl: String
    let remarks: String
}

// MARK: - 韩国色情电影 服务

@MainActor
final class KoreanPornService: ObservableObject {
    static let shared = KoreanPornService()

    private let defaultDomains = ["https://koreanpornmovie.com", "https://koreanpornmovie.net", "https://koreanpornmovie.org", "https://www.koreanpornmovie.com"]

    private var activeBaseURL: String {
        let customs = WelfareDomainStore.shared.domains(for: "韩国色情电影")
        if let first = customs.first { return first }
        return defaultDomains.first ?? "https://koreanpornmovie.com"
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.httpShouldSetCookies = true
        c.httpCookieAcceptPolicy = .always
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        ]
        return URLSession(configuration: c)
    }()

    private let fallbackCategories: [KoreanPornCategory] = [
        KoreanPornCategory(cid: "latest", name: "最新视频"),
        KoreanPornCategory(cid: "longest", name: "最长的视频"),
        KoreanPornCategory(cid: "random", name: "随机视频"),
    ]

    private var cachedCategories: [KoreanPornCategory]?

    // MARK: - 辅助正则方法

    private func firstMatch(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        var groups: [String] = []
        for i in 0..<match.numberOfRanges {
            if let r = Range(match.range(at: i), in: text) {
                groups.append(String(text[r]))
            }
        }
        return groups
    }

    private func allMatches(pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        return matches.map { match in
            var groups: [String] = []
            for i in 0..<match.numberOfRanges {
                if let r = Range(match.range(at: i), in: text) {
                    groups.append(String(text[r]))
                }
            }
            return groups
        }
    }

    // MARK: - 自适应分类获取

    func fetchCategories() async -> [KoreanPornCategory] {
        if let cached = cachedCategories { return cached }

        // 尝试多个默认域名
        let bases = WelfareDomainStore.shared.domains(for: "韩国色情电影").isEmpty ? defaultDomains : [activeBaseURL]
        for base in bases {
            guard let html = await fetchHTML(base, referer: base) else { continue }
            let parsed = parseCategories(from: html)
            if !parsed.isEmpty {
                if WelfareDomainStore.shared.domains(for: "韩国色情电影").isEmpty {
                    WelfareDomainStore.shared.setDomains([base], for: "韩国色情电影")
                }
                cachedCategories = parsed
                return parsed
            }
        }

        return fallbackCategories
    }

    func resetDomain() {
        cachedCategories = nil
        WelfareDomainStore.shared.clearDomains(for: "韩国色情电影")
    }

    func reprobe() {
        cachedCategories = nil
    }

    // MARK: - 分类视频列表

    func fetchVideos(cid: String, page: Int) async -> (videos: [KoreanPornVideo], pageCount: Int) {
        let base = activeBaseURL
        let url: String
        switch cid {
        case "longest":
            url = page > 1 ? "\(base)/?filter=longest&page/\(page)/" : "\(base)/?filter=longest"
        case "random":
            url = page > 1 ? "\(base)/?filter=random&page/\(page)/" : "\(base)/?filter=random"
        default:
            url = page > 1 ? "\(base)/page/\(page)/" : "\(base)/"
        }

        guard let html = await fetchHTML(url, referer: base) else {
            return ([], 1)
        }

        let videos = parseVideoList(from: html, base: base)
        print("[KoreanPorn] 分类 cid=\(cid) page=\(page): \(videos.count)条")
        return (videos, 9999)
    }

    // MARK: - 视频详情（获取播放地址）

    func fetchPlayURL(pageUrl: String) async -> String? {
        let base = activeBaseURL
        let url = pageUrl.hasPrefix("http") ? pageUrl : "\(base)/\(pageUrl)"
        guard let html = await fetchHTML(url, referer: base) else { return nil }

        if let playURL = extractPlayURL(from: html) {
            print("[KoreanPorn] 播放地址: \(playURL.prefix(100))...")
            return playURL
        }
        return url
    }

    // MARK: - 搜索

    func search(keyword: String, page: Int) async -> [KoreanPornVideo] {
        let base = activeBaseURL
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "\(base)/?s=\(encoded)"
        guard let html = await fetchHTML(url, referer: base) else { return [] }
        return parseVideoList(from: html, base: base)
    }

    // MARK: - 网络请求

    private func fetchHTML(_ urlString: String, referer: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.timeoutInterval = 20

        do {
            let (data, resp) = try await session.data(for: req)
            guard let httpResp = resp as? HTTPURLResponse,
                  (200...299).contains(httpResp.statusCode) else { return nil }
            let raw = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii)
                ?? String(data: data, encoding: .isoLatin1)
            return raw
        } catch {
            print("[KoreanPorn] fetchHTML error: \(error)")
            return nil
        }
    }

    // MARK: - HTML 解析：分类（自适应）

    private func parseCategories(from html: String) -> [KoreanPornCategory] {
        var categories: [KoreanPornCategory] = []
        let navPattern = "<nav[^>]*>(.*?)</nav>"
        guard let navGroups = firstMatch(pattern: navPattern, in: html), navGroups.count >= 2 else {
            return categories
        }
        let navHTML = navGroups[1]

        let linkPattern = "<a[^>]*href=\"([^\"]+)\"[^>]*>([^<]+)</a>"
        let matches = allMatches(pattern: linkPattern, in: navHTML)
        var seen: Set<String> = []

        for groups in matches {
            guard groups.count >= 3 else { continue }
            let name = groups[2].trimmingCharacters(in: .whitespaces)
            let href = groups[1]
            let cid: String
            if href.contains("filter=longest") {
                cid = "longest"
            } else if href.contains("filter=random") {
                cid = "random"
            } else if href == "/" || href == basePath {
                cid = "latest"
            } else {
                continue
            }
            if !seen.contains(cid) {
                seen.insert(cid)
                categories.append(KoreanPornCategory(cid: cid, name: name))
            }
        }
        return categories
    }

    private var basePath: String {
        URL(string: activeBaseURL)?.path ?? "/"
    }

    // MARK: - HTML 解析：视频列表

    private func parseVideoList(from html: String, base: String) -> [KoreanPornVideo] {
        var videos: [KoreanPornVideo] = []

        let articlePattern = "<article[^>]*class=\"[^\"]*thumb-block[^\"]*\"[^>]*>(.*?)</article>"
        let articleMatches = allMatches(pattern: articlePattern, in: html)

        for groups in articleMatches {
            guard groups.count >= 2 else { continue }
            if let vod = parseVideoItem(groups[1], base: base) {
                videos.append(vod)
            }
        }

        return videos
    }

    private func parseVideoItem(_ item: String, base: String) -> KoreanPornVideo? {
        guard let linkGroups = firstMatch(pattern: "<a[^>]*href=\"([^\"]+)\"[^>]*>", in: item),
              linkGroups.count >= 2 else { return nil }

        let link = linkGroups[1]
        let components = link.components(separatedBy: "/").filter { !$0.isEmpty }
        guard let vodId = components.last else { return nil }

        let pageUrl: String
        if link.hasPrefix("http") {
            pageUrl = link
        } else if link.hasPrefix("/") {
            pageUrl = "\(base)\(link)"
        } else {
            pageUrl = "\(base)/\(link)"
        }

        let cover: String
        if let imgGroups = firstMatch(pattern: "<img[^>]*class=\"[^\"]*video-main-thumb[^\"]*\"[^>]*src=\"([^\"]+)\"[^>]*>", in: item),
           imgGroups.count >= 2 {
            cover = normalizeImageURL(imgGroups[1], base: base)
        } else if let imgGroups = firstMatch(pattern: "<img[^>]*src=\"([^\"]+)\"[^>]*>", in: item),
                  imgGroups.count >= 2 {
            cover = normalizeImageURL(imgGroups[1], base: base)
        } else {
            cover = ""
        }

        let title: String
        if let titleGroups = firstMatch(pattern: "<header[^>]*class=\"[^\"]*entry-header[^\"]*\"[^>]*>\\s*<span[^>]*>([^<]+)</span>", in: item),
           titleGroups.count >= 2 {
            title = titleGroups[1].trimmingCharacters(in: .whitespaces)
        } else if let titleGroups = firstMatch(pattern: "<span[^>]*>([^<]+)</span>", in: item),
                  titleGroups.count >= 2 {
            title = titleGroups[1].trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }

        var remarks = ""
        if let durGroups = firstMatch(pattern: "<span[^>]*class=\"[^\"]*duration[^\"]*\"[^>]*>([^<]+)</span>", in: item),
           durGroups.count >= 2 {
            remarks = durGroups[1].trimmingCharacters(in: .whitespaces)
        }

        return KoreanPornVideo(vodId: vodId, title: title, cover: cover, pageUrl: pageUrl, remarks: remarks)
    }

    private func normalizeImageURL(_ url: String, base: String) -> String {
        if url.hasPrefix("http") { return url }
        if url.hasPrefix("//") { return "https:\(url)" }
        if url.hasPrefix("/") { return "\(base)\(url)" }
        return "\(base)/\(url)"
    }

    // MARK: - HTML 解析：播放地址（4 级回退）

    private func extractPlayURL(from html: String) -> String? {
        // 级别 1: meta[itemprop="contentURL"]
        if let groups = firstMatch(pattern: "<meta[^>]*itemprop=\"contentURL\"[^>]*content=\"([^\"]+)\"[^>]*>", in: html),
           groups.count >= 2 {
            return groups[1]
        }

        // 级别 2: iframe base64 解码 → 提取 mp4
        if let groups = firstMatch(pattern: "<iframe[^>]*src=\"[^\"]*\\?q=([^\"]+)\"[^>]*>", in: html),
           groups.count >= 2 {
            let base64Str = groups[1]
            if let data = Data(base64Encoded: base64Str),
               let decoded = String(data: data, encoding: .utf8) {
                if let mp4Groups = firstMatch(pattern: "src=\"([^\"]+\\.mp4)\"", in: decoded),
                   mp4Groups.count >= 2 {
                    return mp4Groups[1]
                }
            }
        }

        // 级别 3: 直接搜索 mp4 链接（优先 koreanporn.stream）
        let mp4Pattern = "https?://[^\\s\"']+\\.mp4"
        let matches = allMatches(pattern: mp4Pattern, in: html)
        if !matches.isEmpty {
            for match in matches {
                if match.count >= 1, match[0].contains("koreanporn.stream") {
                    return match[0]
                }
            }
            if matches.first?.count ?? 0 >= 1 {
                return matches.first![0]
            }
        }

        // 级别 4: JS 变量
        let jsPatterns = [
            "file\\s*:\\s*[\"']([^\"']+\\.mp4)[\"']",
            "src\\s*:\\s*[\"']([^\"']+\\.mp4)[\"']",
            "videoSrc\\s*:\\s*[\"']([^\"']+\\.mp4)[\"']",
        ]
        for pattern in jsPatterns {
            if let groups = firstMatch(pattern: pattern, in: html),
               groups.count >= 2 {
                var url = groups[1]
                if url.hasPrefix("//") { url = "https:\(url)" }
                return url
            }
        }

        return nil
    }
}
