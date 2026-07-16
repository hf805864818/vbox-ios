import Foundation

// MARK: - 久久網 数据模型

struct JiujiuCategory: Identifiable {
    var id: String { cid }
    let cid: String
    let name: String
}

struct JiujiuVideo: Identifiable {
    var id: String { vodId }
    let vodId: String
    let title: String
    let cover: String
    let pageUrl: String
    let remarks: String
}

// MARK: - 久久網 服务

@MainActor
final class JiujiuService: ObservableObject {
    static let shared = JiujiuService()

    private let defaultDomains = ["https://ww.jiujiu.one", "https://jiujiu.one", "https://www.jiujiu.one"]

    private var activeBaseURL: String {
        let customs = WelfareDomainStore.shared.domains(for: "久久網")
        if let first = customs.first { return first }
        return defaultDomains.first ?? "https://ww.jiujiu.one"
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

    private let fallbackCategories: [JiujiuCategory] = [
        JiujiuCategory(cid: "68", name: "亞洲無碼"),
        JiujiuCategory(cid: "67", name: "日本女優"),
        JiujiuCategory(cid: "23", name: "日本無碼"),
        JiujiuCategory(cid: "9", name: "中文字幕"),
        JiujiuCategory(cid: "24", name: "日本有碼"),
        JiujiuCategory(cid: "82", name: "日韓無碼"),
        JiujiuCategory(cid: "113", name: "無碼專區"),
        JiujiuCategory(cid: "78", name: "AV明星"),
        JiujiuCategory(cid: "269", name: "倫理影片"),
        JiujiuCategory(cid: "90", name: "日本片商"),
        JiujiuCategory(cid: "80", name: "國產自拍"),
        JiujiuCategory(cid: "231", name: "傳媒原創"),
        JiujiuCategory(cid: "63", name: "國產精品"),
        JiujiuCategory(cid: "77", name: "國產情色"),
        JiujiuCategory(cid: "105", name: "美女主播"),
        JiujiuCategory(cid: "33", name: "強姦亂倫"),
        JiujiuCategory(cid: "36", name: "國產主播"),
        JiujiuCategory(cid: "66", name: "亞洲有碼"),
        JiujiuCategory(cid: "3", name: "偷拍自拍"),
        JiujiuCategory(cid: "91", name: "抖陰視頻"),
        JiujiuCategory(cid: "31", name: "制服誘惑"),
        JiujiuCategory(cid: "10", name: "黑料不打烊"),
        JiujiuCategory(cid: "25", name: "歐美精品"),
    ]

    private var cachedCategories: [JiujiuCategory]?

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

    func fetchCategories() async -> [JiujiuCategory] {
        if let cached = cachedCategories { return cached }

        // 尝试多个默认域名
        let bases = WelfareDomainStore.shared.domains(for: "久久網").isEmpty ? defaultDomains : [activeBaseURL]
        for base in bases {
            guard let html = await fetchHTML(base, referer: base) else { continue }
            let parsed = parseCategories(from: html)
            if !parsed.isEmpty {
                if WelfareDomainStore.shared.domains(for: "久久網").isEmpty {
                    WelfareDomainStore.shared.setDomains([base], for: "久久網")
                }
                cachedCategories = parsed
                return parsed
            }
        }

        return fallbackCategories
    }

    func resetDomain() {
        cachedCategories = nil
        WelfareDomainStore.shared.clearDomains(for: "久久網")
    }

    func reprobe() {
        cachedCategories = nil
    }

    // MARK: - 分类视频列表

    func fetchVideos(cid: String, page: Int) async -> (videos: [JiujiuVideo], pageCount: Int) {
        let base = activeBaseURL
        let url: String
        if page == 1 {
            url = "\(base)/c/\(cid)"
        } else {
            url = "\(base)/c/\(cid)?page=\(page)"
        }
        guard let html = await fetchHTML(url, referer: base) else {
            return ([], 1)
        }

        let videos = parseVideoList(from: html, base: base)
        let pageCount = parsePageCount(from: html, currentPage: page)

        print("[Jiujiu] 分类 cid=\(cid) page=\(page): \(videos.count)条, 共\(pageCount)页")
        return (videos, pageCount)
    }

    // MARK: - 视频详情（获取播放地址）

    func fetchPlayURL(pageUrl: String) async -> String? {
        let base = activeBaseURL
        let url = pageUrl.hasPrefix("http") ? pageUrl : "\(base)\(pageUrl)"
        guard let html = await fetchHTML(url, referer: base) else { return nil }

        if let playURL = extractPlayURL(from: html) {
            print("[Jiujiu] 播放地址: \(playURL.prefix(100))...")
            return playURL
        }
        return url
    }

    // MARK: - 搜索

    func search(keyword: String, page: Int) async -> [JiujiuVideo] {
        let base = activeBaseURL
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "\(base)/node/search?q=\(encoded)"
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
            print("[Jiujiu] fetchHTML error: \(error)")
            return nil
        }
    }

    // MARK: - HTML 解析：分类（自适应）

    private func parseCategories(from html: String) -> [JiujiuCategory] {
        var categories: [JiujiuCategory] = []
        let pattern = "<a[^>]*href=\"[^\"]*/c/(\\d+)[^\"]*\"[^>]*>([^<]+)</a>"
        let matches = allMatches(pattern: pattern, in: html)
        var seen: Set<String> = []
        for groups in matches {
            guard groups.count >= 3 else { continue }
            let cid = groups[1]
            let name = groups[2].trimmingCharacters(in: .whitespaces)
            if !seen.contains(cid) {
                seen.insert(cid)
                categories.append(JiujiuCategory(cid: cid, name: name))
            }
        }
        return categories
    }

    // MARK: - HTML 解析：视频列表

    private func parseVideoList(from html: String, base: String) -> [JiujiuVideo] {
        var videos: [JiujiuVideo] = []

        let itemPattern = "<div[^>]*class=\"[^\"]*item[^\"]*\"[^>]*>(.*?)</div>\\s*</div>\\s*</div>"
        let itemMatches = allMatches(pattern: itemPattern, in: html)

        for groups in itemMatches {
            guard groups.count >= 2 else { continue }
            if let vod = parseVideoItem(groups[1], base: base) {
                videos.append(vod)
            }
        }

        return videos
    }

    private func parseVideoItem(_ item: String, base: String) -> JiujiuVideo? {
        let linkPattern = "<a[^>]*href=\"([^\"]+)\"[^>]*>([^<]+)</a>"
        let linkMatches = allMatches(pattern: linkPattern, in: item)

        guard linkMatches.count >= 2 else { return nil }
        let href = linkMatches[1][1]
        let title = linkMatches[1][2].trimmingCharacters(in: .whitespaces)

        guard !href.isEmpty else { return nil }

        let pageUrl: String
        if href.hasPrefix("http") {
            pageUrl = href
        } else if href.hasPrefix("/") {
            pageUrl = "\(base)\(href)"
        } else {
            pageUrl = "\(base)/\(href)"
        }

        let vodId: String
        if href.hasPrefix("http") {
            vodId = href
        } else if href.hasPrefix("/") {
            vodId = href
        } else {
            vodId = "/\(href)"
        }

        var cover = ""
        if let imgGroups = firstMatch(pattern: "<img[^>]*(?:src|data-src)=\"([^\"]+)\"[^>]*>", in: item),
           imgGroups.count >= 2 {
            cover = normalizeImageURL(imgGroups[1], base: base)
        }

        var remarks = ""
        if let badgeGroups = firstMatch(pattern: "<span[^>]*class=\"[^\"]*badge[^\"]*\"[^>]*>([^<]+)</span>", in: item),
           badgeGroups.count >= 2 {
            remarks = badgeGroups[1].trimmingCharacters(in: .whitespaces)
        }

        return JiujiuVideo(vodId: vodId, title: title, cover: cover, pageUrl: pageUrl, remarks: remarks)
    }

    private func normalizeImageURL(_ url: String, base: String) -> String {
        if url.hasPrefix("http") { return url }
        if url.hasPrefix("//") { return "https:\(url)" }
        if url.hasPrefix("/") { return "\(base)\(url)" }
        return "\(base)/\(url)"
    }

    // MARK: - HTML 解析：分页

    private func parsePageCount(from html: String, currentPage: Int) -> Int {
        let pattern = "<ul[^>]*class=\"[^\"]*pagination[^\"]*\"[^>]*>(.*?)</ul>"
        guard let ulGroups = firstMatch(pattern: pattern, in: html), ulGroups.count >= 2 else {
            return 1
        }
        let paginationHTML = ulGroups[1]

        let pageLinkPattern = "<a[^>]*>(\\d+)</a>"
        let matches = allMatches(pattern: pageLinkPattern, in: paginationHTML)
        let pages = matches.compactMap { groups -> Int? in
            guard groups.count >= 2 else { return nil }
            return Int(groups[1])
        }
        return pages.max() ?? (currentPage + 2)
    }

    // MARK: - HTML 解析：播放地址

    private func extractPlayURL(from html: String) -> String? {
        if let groups = firstMatch(pattern: "<video[^>]*>(.*?)</video>", in: html),
           groups.count >= 2 {
            let videoHTML = groups[1]
            if let srcGroups = firstMatch(pattern: "<source[^>]*src=\"([^\"]+)\"[^>]*>", in: videoHTML),
               srcGroups.count >= 2 {
                return srcGroups[1]
            }
        }

        if let groups = firstMatch(pattern: "(https?://[^\"'\\s]+\\.m3u8[^\"'\\s]*)", in: html),
           groups.count >= 2 {
            return groups[1]
        }
        if let groups = firstMatch(pattern: "(https?://[^\"'\\s]+\\.mp4[^\"'\\s]*)", in: html),
           groups.count >= 2 {
            return groups[1]
        }

        if let groups = firstMatch(pattern: "<iframe[^>]*src=\"([^\"]+)\"[^>]*>", in: html),
           groups.count >= 2 {
            return groups[1]
        }

        return nil
    }
}
