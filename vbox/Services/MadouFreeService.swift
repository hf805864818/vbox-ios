import Foundation

// MARK: - 麻豆免费 数据模型

struct MadouFreeCategory: Identifiable {
    var id: String { cid }
    let cid: String
    let name: String
}

struct MadouFreeVideo: Identifiable {
    var id: String { vodId }
    let vodId: String
    let title: String
    let cover: String
    let playPath: String
    let remarks: String
}

// MARK: - 麻豆免费 服务

@MainActor
final class MadouFreeService: ObservableObject {
    static let shared = MadouFreeService()

    private let defaultDomains = ["https://c-you.hair", "https://www.yamdck.com", "https://yamdck.com"]

    private var activeBaseURL: String {
        let customs = WelfareDomainStore.shared.domains(for: "麻豆免费")
        if let first = customs.first { return first }
        return defaultDomains.first ?? "https://c-you.hair"
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

    private var cachedCategories: [MadouFreeCategory]?

    // MARK: - 正则辅助

    private func firstMatch(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
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
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
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

    // MARK: - 自适应分类

    func fetchCategories() async -> [MadouFreeCategory] {
        if let cached = cachedCategories { return cached }

        // 尝试多个默认域名
        let bases = WelfareDomainStore.shared.domains(for: "麻豆免费").isEmpty ? defaultDomains : [activeBaseURL]
        for base in bases {
            guard let html = await fetchHTML(base + "/", referer: base) else { continue }
            let parsed = parseCategories(from: html)
            if !parsed.isEmpty {
                if WelfareDomainStore.shared.domains(for: "麻豆免费").isEmpty {
                    WelfareDomainStore.shared.setDomains([base], for: "麻豆免费")
                }
                cachedCategories = parsed
                return parsed
            }
        }

        return fallbackCategories
    }

    private var fallbackCategories: [MadouFreeCategory] {
        [
            MadouFreeCategory(cid: "6", name: "国产精品"),
            MadouFreeCategory(cid: "7", name: "中文字幕"),
            MadouFreeCategory(cid: "8", name: "伦理影片"),
            MadouFreeCategory(cid: "9", name: "自拍偷拍"),
            MadouFreeCategory(cid: "10", name: "口交视频"),
            MadouFreeCategory(cid: "11", name: "日韩无码"),
            MadouFreeCategory(cid: "12", name: "制服诱惑"),
            MadouFreeCategory(cid: "13", name: "国产色情"),
        ]
    }

    func resetDomain() {
        cachedCategories = nil
        WelfareDomainStore.shared.clearDomains(for: "麻豆免费")
    }

    func reprobe() {
        cachedCategories = nil
    }

    // MARK: - 分类视频列表

    func fetchVideos(cid: String, page: Int) async -> (videos: [MadouFreeVideo], pageCount: Int) {
        let base = activeBaseURL
        let url: String
        if page <= 1 {
            url = "\(base)/vodtype/\(cid).html"
        } else {
            url = "\(base)/vodtype/\(cid)-\(page).html"
        }

        guard let html = await fetchHTML(url, referer: base) else {
            return ([], 1)
        }

        let videos = parseVideoList(from: html, base: base)
        let pageCount = parsePageCount(from: html, currentPage: page)

        print("[MadouFree] 分类 cid=\(cid) page=\(page): \(videos.count)条, 共\(pageCount)页")
        return (videos, pageCount)
    }

    // MARK: - 视频详情 + 播放地址

    func fetchPlayURL(playPath: String) async -> String? {
        let base = activeBaseURL
        let url = playPath.hasPrefix("http") ? playPath : "\(base)\(playPath)"
        guard let html = await fetchHTML(url, referer: base) else { return nil }

        if let m3u8 = extractPlayURL(from: html) {
            print("[MadouFree] 播放地址: \(m3u8.prefix(100))...")
            return m3u8
        }
        return url
    }

    // MARK: - 搜索

    func search(keyword: String, page: Int) async -> [MadouFreeVideo] {
        let base = activeBaseURL
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url: String
        if page <= 1 {
            url = "\(base)/vodsearch/\(encoded)-------------.html"
        } else {
            url = "\(base)/vodsearch/\(encoded)-------------\(page)---.html"
        }
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
                  (200...299).contains(httpResp.statusCode) else {
                if let httpResp = resp as? HTTPURLResponse {
                    print("[MadouFree] HTTP status: \(httpResp.statusCode) for \(urlString)")
                }
                return nil
            }
            let raw = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii)
                ?? String(data: data, encoding: .isoLatin1)
            return raw
        } catch {
            print("[MadouFree] fetchHTML error: \(error)")
            return nil
        }
    }

    // MARK: - HTML 解析：分类（从导航栏）

    private func parseCategories(from html: String) -> [MadouFreeCategory] {
        var categories: [MadouFreeCategory] = []
        let pattern = "<a[^>]*href=\"[^\"]*vodtype/(\\d+)\\.html\"[^>]*>([^<]+)</a>"
        let matches = allMatches(pattern: pattern, in: html)
        var seen: Set<String> = []
        for groups in matches {
            guard groups.count >= 3 else { continue }
            let cid = groups[1]
            let name = groups[2].trimmingCharacters(in: .whitespaces)
            if !seen.contains(cid) {
                seen.insert(cid)
                categories.append(MadouFreeCategory(cid: cid, name: name))
            }
        }
        return categories
    }

    // MARK: - HTML 解析：视频列表（CSS选择器模拟）

    private func parseVideoList(from html: String, base: String) -> [MadouFreeVideo] {
        var videos: [MadouFreeVideo] = []

        let cardPattern = "<div[^>]*class=\"[^\"]*resent-grid[^\"]*recommended-grid[^\"]*\"[^>]*>(.*?)</div>\\s*</div>\\s*</div>\\s*</div>"
        let cards = allMatches(pattern: cardPattern, in: html)

        for groups in cards {
            guard groups.count >= 2 else { continue }
            let card = groups[1]

            guard let hrefGroups = firstMatch(pattern: "<a[^>]*href=\"([^\"]+)\"[^>]*>", in: card),
                  hrefGroups.count >= 2 else { continue }
            let vodId = hrefGroups[1]

            var title = ""
            if let titleGroups = firstMatch(pattern: "class=\"title\"[^>]*>([^<]+)</a>", in: card),
               titleGroups.count >= 2 {
                title = titleGroups[1].trimmingCharacters(in: .whitespaces)
            }

            var cover = ""
            if let imgGroups = firstMatch(pattern: "data-original=\"([^\"]+)\"", in: card),
               imgGroups.count >= 2 {
                cover = normalizeImageURL(imgGroups[1], base: base)
            }

            var remarks = ""
            if let viewsGroups = firstMatch(pattern: "views-info[^>]*>.*?<span[^>]*>([^<]+)</span>", in: card),
               viewsGroups.count >= 2 {
                remarks = viewsGroups[1].trimmingCharacters(in: .whitespaces) + "观看"
            }

            if !vodId.isEmpty && !title.isEmpty {
                videos.append(MadouFreeVideo(
                    vodId: vodId, title: title, cover: cover,
                    playPath: vodId, remarks: remarks
                ))
            }
        }
        return videos
    }

    private func normalizeImageURL(_ url: String, base: String) -> String {
        if url.hasPrefix("http") { return url }
        if url.hasPrefix("//") { return "https:\(url)" }
        if url.hasPrefix("/") { return "\(base)\(url)" }
        return "\(base)/\(url)"
    }

    // MARK: - HTML 解析：分页

    private func parsePageCount(from html: String, currentPage: Int) -> Int {
        if let groups = firstMatch(pattern: "class=\"active\"[^>]*>.*?(\\d+)\\s*/\\s*(\\d+)", in: html),
           groups.count >= 3, let total = Int(groups[2]) {
            return total
        }
        let pageLinks = allMatches(pattern: "<a[^>]*href=\"[^\"]*vodtype/[^\"]*-(\\d+)\\.html\"", in: html)
        let pages = pageLinks.compactMap { groups -> Int? in
            guard groups.count >= 2 else { return nil }
            return Int(groups[1])
        }
        return pages.max() ?? (currentPage + 2)
    }

    // MARK: - HTML 解析：播放地址（5级回退）

    private func extractPlayURL(from html: String) -> String? {
        // 1. player_data JSON
        if let groups = firstMatch(pattern: "var\\s+player_data\\s*=\\s*(\\{[^;]+\\})", in: html),
           groups.count >= 2 {
            let jsonStr = groups[1]
            if let data = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let url = json["url"] as? String, !url.isEmpty {
                return url
            }
        }

        // 2. iframe src
        if let groups = firstMatch(pattern: "<iframe[^>]+src=\"([^\"]+)\"", in: html),
           groups.count >= 2 {
            return groups[1]
        }

        // 3. video src
        if let groups = firstMatch(pattern: "<video[^>]+src=\"([^\"]+)\"", in: html),
           groups.count >= 2 {
            return groups[1]
        }

        // 4. source src
        if let groups = firstMatch(pattern: "<source[^>]+src=\"([^\"]+)\"", in: html),
           groups.count >= 2 {
            return groups[1]
        }

        // 5. direct m3u8/mp4
        if let groups = firstMatch(pattern: "(https?://[^\"'\\s]+\\.m3u8[^\"'\\s]*)", in: html),
           groups.count >= 2 {
            return groups[1]
        }
        if let groups = firstMatch(pattern: "(https?://[^\"'\\s]+\\.mp4[^\"'\\s]*)", in: html),
           groups.count >= 2 {
            return groups[1]
        }

        return nil
    }
}
