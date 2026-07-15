import Foundation

// MARK: - 萝莉AV 数据模型

struct LuoliAVCategory: Identifiable {
    var id: String { cid }
    let cid: String
    let name: String
}

struct LuoliAVVideo: Identifiable {
    var id: String { vodId }
    let vodId: String
    let title: String
    let cover: String
    let pageUrl: String
}

// MARK: - 萝莉AV 服务

@MainActor
final class LuoliAVService: ObservableObject {
    static let shared = LuoliAVService()

    private let defaultDomain = "https://212602.luoliav.cc"

    private var activeBaseURL: String {
        let customs = WelfareDomainStore.shared.domains(for: "萝莉AV")
        if let first = customs.first { return first }
        return defaultDomain
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        ]
        return URLSession(configuration: c)
    }()

    private let fallbackCategories: [LuoliAVCategory] = [
        LuoliAVCategory(cid: "1", name: "国产精选"),
        LuoliAVCategory(cid: "2", name: "日韩AV"),
        LuoliAVCategory(cid: "3", name: "蓝光超清"),
        LuoliAVCategory(cid: "4", name: "欧美精品"),
        LuoliAVCategory(cid: "5", name: "异族风情"),
        LuoliAVCategory(cid: "6", name: "动漫专区"),
    ]

    private var cachedCategories: [LuoliAVCategory]?

    // MARK: - 自适应分类获取

    func fetchCategories() async -> [LuoliAVCategory] {
        if let cached = cachedCategories { return cached }

        let base = activeBaseURL
        guard let html = await fetchHTML("\(base)/index.html", referer: base) else {
            return fallbackCategories
        }

        let parsed = parseCategories(from: html)
        if parsed.isEmpty {
            return fallbackCategories
        }

        cachedCategories = parsed
        return parsed
    }

    func resetDomain() {
        cachedCategories = nil
        WelfareDomainStore.shared.clearDomains(for: "萝莉AV")
    }

    func reprobe() {
        cachedCategories = nil
    }

    // MARK: - 分类视频列表

    func fetchVideos(cid: String, page: Int) async -> (videos: [LuoliAVVideo], pageCount: Int) {
        let base = activeBaseURL
        let url = "\(base)/list.php?cid=\(cid)&page=\(page)"
        guard let html = await fetchHTML(url, referer: base) else {
            return ([], 1)
        }

        let videos = parseVideoList(from: html, base: base)
        let pageCount = parsePageCount(from: html, cid: cid, currentPage: page)

        print("[LuoliAV] 分类 cid=\(cid) page=\(page): \(videos.count)条, 共\(pageCount)页")
        return (videos, pageCount)
    }

    // MARK: - 视频详情（获取播放地址）

    func fetchPlayURL(vodId: String, pageUrl: String) async -> String? {
        let base = activeBaseURL
        let url = pageUrl.hasPrefix("http") ? pageUrl : "\(base)/\(pageUrl)"
        guard let html = await fetchHTML(url, referer: base) else { return nil }

        if let m3u8 = extractPlayURL(from: html) {
            print("[LuoliAV] 播放地址: \(m3u8.prefix(100))...")
            return m3u8
        }
        return url
    }

    // MARK: - 搜索

    func search(keyword: String, page: Int) async -> [LuoliAVVideo] {
        let base = activeBaseURL
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "\(base)/search.php?keyword=\(encoded)&page=\(page)"
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
            print("[LuoliAV] fetchHTML error: \(error)")
            return nil
        }
    }

    // MARK: - HTML 解析：分类

    private func parseCategories(from html: String) -> [LuoliAVCategory] {
        var categories: [LuoliAVCategory] = []
        let pattern = #/<a[^>]*href="[^"]*list\.php\?cid=(\d+)[^"]*"[^>]*>([^<]+)</a>/#
        let matches = html.matches(of: pattern)
        var seen: Set<String> = []
        for match in matches {
            let cid = String(match.1)
            let name = String(match.2).trimmingCharacters(in: .whitespaces)
            if !seen.contains(cid) {
                seen.insert(cid)
                categories.append(LuoliAVCategory(cid: cid, name: name))
            }
        }
        return categories
    }

    // MARK: - HTML 解析：视频列表

    private func parseVideoList(from html: String, base: String) -> [LuoliAVVideo] {
        var videos: [LuoliAVVideo] = []

        let itemPattern = #/<div[^>]*class="[^"]*group[^"]*item[^"]*"[^>]*>(.*?)</div>\s*</div>\s*</div>/#
        let itemMatches = html.matches(of: itemPattern.anchorsMatchLineEndings())

        for itemMatch in itemMatches {
            let item = String(itemMatch.1)
            guard let vod = parseVideoItem(item, base: base) else { continue }
            videos.append(vod)
        }

        if videos.isEmpty {
            videos = parseVideoListAlt(from: html, base: base)
        }

        return videos
    }

    private func parseVideoItem(_ item: String, base: String) -> LuoliAVVideo? {
        guard let hrefMatch = item.firstMatch(of: #/<a[^>]*href="([^"]+)"[^>]*>/#/) else { return nil }
        var vodId = String(hrefMatch.1)
        vodId = vodId.replacingOccurrences(of: #/\?.*$/#, with: "", options: .regularExpression)

        let pageUrl: String
        if vodId.hasPrefix("http") {
            pageUrl = vodId
        } else if vodId.hasPrefix("/") {
            pageUrl = "\(base)\(vodId)"
        } else {
            pageUrl = "\(base)/\(vodId)"
        }

        guard let imgMatch = item.firstMatch(of: #/<img[^>]*data-original="([^"]+)"[^>]*>/#/) else { return nil }
        let pic = normalizeImageURL(String(imgMatch.1), base: base)

        let title: String
        if let titleMatch = item.firstMatch(of: #/<a[^>]*class="[^"]*font-bold[^"]*"[^>]*>([^<]+)</a>#/) {
            title = String(titleMatch.1).trimmingCharacters(in: .whitespaces)
        } else if let titleMatch = item.firstMatch(of: #/<a[^>]*>([^<]+)</a>\s*</div>\s*$/#/) {
            title = String(titleMatch.1).trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }

        return LuoliAVVideo(vodId: vodId, title: title, cover: pic, pageUrl: pageUrl)
    }

    private func parseVideoListAlt(from html: String, base: String) -> [LuoliAVVideo] {
        var videos: [LuoliAVVideo] = []
        let pattern = #/<div class="group[^"]*item[^>]*>.*?<a[^>]*href="([^"]+)"[^>]*>.*?<img[^>]*data-original="([^"]+)"[^>]*>.*?<a[^>]*class="[^"]*font-bold[^"]*"[^>]*>([^<]+)</a>/#
        let matches = html.matches(of: pattern.anchorsMatchLineEndings())

        for match in matches {
            var vodId = String(match.1)
            vodId = vodId.replacingOccurrences(of: #/\?.*$/#, with: "", options: .regularExpression)

            let pageUrl: String
            if vodId.hasPrefix("http") { pageUrl = vodId }
            else if vodId.hasPrefix("/") { pageUrl = "\(base)\(vodId)" }
            else { pageUrl = "\(base)/\(vodId)" }

            let pic = normalizeImageURL(String(match.2), base: base)
            let title = String(match.3).trimmingCharacters(in: .whitespaces)
            videos.append(LuoliAVVideo(vodId: vodId, title: title, cover: pic, pageUrl: pageUrl))
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

    private func parsePageCount(from html: String, cid: String, currentPage: Int) -> Int {
        let pattern = try? NSRegularExpression(pattern: #"list\.php\?cid=\#(cid)&amp;page=(\d+)"#)
        let range = NSRange(html.startIndex..., in: html)
        let matches = pattern?.matches(in: html, range: range) ?? []
        let pages = matches.compactMap { match -> Int? in
            guard let r = Range(match.range(at: 2), in: html) else { return nil }
            return Int(html[r])
        }
        return pages.max() ?? (currentPage + 2)
    }

    // MARK: - HTML 解析：播放地址

    private func extractPlayURL(from html: String) -> String? {
        if let match = html.firstMatch(of: #/(https?://[^"'\s]+\.m3u8[^"'\s]*)/#/) {
            return String(match.1)
        }
        if let match = html.firstMatch(of: #/(https?://[^"'\s]+\.mp4[^"'\s]*)/#/) {
            return String(match.1)
        }
        if let match = html.firstMatch(of: #/var[^;]*video[^=]*=\s*["']([^"']+\.m3u8[^"']*)["']/#/) {
            return String(match.1)
        }
        return nil
    }
}
