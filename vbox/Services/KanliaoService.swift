import Foundation

// MARK: - 今日看料 数据模型

struct KanliaoCategory: Identifiable {
    var id: String { cid }
    let cid: String
    let name: String
}

struct KanliaoVideo: Identifiable {
    var id: String { vodId }
    let vodId: String
    let title: String
    let cover: String
    let pageUrl: String
    let remarks: String
}

// MARK: - 今日看料 服务

@MainActor
final class KanliaoService: ObservableObject {
    static let shared = KanliaoService()

    private let candidateDomains = [
        "https://kanliao2.one",
        "https://kanliao7.org",
        "https://kanliao7.net",
        "https://kanliao14.com",
    ]

    private var _activeBaseURL: String?
    private var activeBaseURL: String {
        if let cached = _activeBaseURL { return cached }
        let customs = WelfareDomainStore.shared.domains(for: "今日看料")
        if let first = customs.first { return first }
        return candidateDomains[0]
    }

    private let _delegate = _KanliaoSessionDelegate()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.httpShouldSetCookies = true
        c.httpCookieAcceptPolicy = .always
        c.tlsMinimumSupportedProtocolVersion = .TLSv10
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9",
        ]
        return URLSession(configuration: c, delegate: _delegate, delegateQueue: nil)
    }()

    private let fallbackCategories: [KanliaoCategory] = [
        KanliaoCategory(cid: "/category/rdgz/", name: "热点关注"),
        KanliaoCategory(cid: "/category/dy/", name: "抖音"),
        KanliaoCategory(cid: "/category/ks/", name: "快手"),
        KanliaoCategory(cid: "/category/douyu/", name: "斗鱼"),
        KanliaoCategory(cid: "/category/hy/", name: "虎牙"),
        KanliaoCategory(cid: "/category/hj/", name: "花椒"),
        KanliaoCategory(cid: "/category/tt/", name: "推特"),
        KanliaoCategory(cid: "/category/wh/", name: "网红"),
        KanliaoCategory(cid: "/category/asmr/", name: "ASMR"),
        KanliaoCategory(cid: "/category/xb/", name: "X播"),
        KanliaoCategory(cid: "/category/xsp/", name: "小视频"),
    ]

    private var cachedCategories: [KanliaoCategory]?

    // MARK: - 辅助正则方法

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

    // MARK: - 动态域名探测

    @discardableResult
    func probeDomain() async -> Bool {
        for domain in candidateDomains {
            guard let url = URL(string: domain) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            do {
                let (data, resp) = try await session.data(for: req)
                guard let httpResp = resp as? HTTPURLResponse,
                      httpResp.statusCode == 200 else { continue }
                let html = String(data: data, encoding: .utf8) ?? ""
                if html.contains("<article") || html.contains("article") {
                    _activeBaseURL = domain
                    WelfareDomainStore.shared.addDomain(for: "今日看料", domain)
                    print("[Kanliao] 探测到可用域名: \(domain)")
                    return true
                }
            } catch {
                continue
            }
        }
        _activeBaseURL = candidateDomains[0]
        print("[Kanliao] 未找到可用域名，回退: \(candidateDomains[0])")
        return false
    }

    // MARK: - 自适应分类获取

    func fetchCategories() async -> [KanliaoCategory] {
        if let cached = cachedCategories { return cached }

        await probeDomain()
        let base = activeBaseURL
        guard let html = await fetchHTML(base, referer: base) else {
            return fallbackCategories
        }

        let parsed = parseCategories(from: html, base: base)
        if parsed.isEmpty {
            return fallbackCategories
        }

        cachedCategories = parsed
        return parsed
    }

    func resetDomain() {
        cachedCategories = nil
        WelfareDomainStore.shared.clearDomains(for: "今日看料")
        _activeBaseURL = nil
    }

    func reprobe() {
        cachedCategories = nil
        _activeBaseURL = nil
    }

    // MARK: - 分类视频列表

    func fetchVideos(cid: String, page: Int) async -> (videos: [KanliaoVideo], pageCount: Int) {
        let base = activeBaseURL
        let cleanCid = cid.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url: String
        if page > 1 {
            url = "\(base)/\(cleanCid)/\(page)/"
        } else {
            url = "\(base)/\(cleanCid)/"
        }

        guard let html = await fetchHTML(url, referer: base) else {
            return ([], 1)
        }

        let videos = parseVideoList(from: html, base: base)
        let pageCount = parsePageCount(from: html)
        print("[Kanliao] 分类 cid=\(cid) page=\(page): \(videos.count)条, 共\(pageCount)页")
        return (videos, pageCount)
    }

    // MARK: - 视频详情（获取播放地址）

    func fetchPlayURL(pageUrl: String) async -> String? {
        let base = activeBaseURL
        let url = pageUrl.hasPrefix("http") ? pageUrl : "\(base)\(pageUrl)"
        guard let html = await fetchHTML(url, referer: base) else { return nil }

        if let playURL = extractPlayURL(from: html) {
            print("[Kanliao] 播放地址: \(playURL.prefix(100))...")
            return playURL
        }
        return url
    }

    // MARK: - 搜索

    func search(keyword: String, page: Int) async -> [KanliaoVideo] {
        let base = activeBaseURL
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let tagURL = "\(base)/tag/\(encoded)/"
        if let html = await fetchHTML(tagURL, referer: base) {
            let videos = parseVideoList(from: html, base: base)
            if !videos.isEmpty { return videos }
        }

        let searchURL = "\(base)/search/\(encoded)/"
        guard let html = await fetchHTML(searchURL, referer: base) else { return [] }
        return parseVideoList(from: html, base: base)
    }

    // MARK: - 网络请求

    private func fetchHTML(_ urlString: String, referer: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue(referer, forHTTPHeaderField: "Origin")
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
            print("[Kanliao] fetchHTML error: \(error)")
            return nil
        }
    }

    // MARK: - HTML 解析：分类（自适应从导航栏）

    private func parseCategories(from html: String, base: String) -> [KanliaoCategory] {
        var categories: [KanliaoCategory] = []

        let navSelectors = [
            "#navbarCollapse .navbar-nav .nav-item .nav-link",
            ".navbar-nav .nav-item .nav-link",
            ".menu .menu-item a",
        ]

        let navBlockPatterns = [
            "<nav[^>]*class=\"[^\"]*navbar[^\"]*\"[^>]*>(.*?)</nav>",
            "<ul[^>]*class=\"[^\"]*(?:navbar-nav|nav-menu|menu)[^\"]*\"[^>]*>(.*?)</ul>",
        ]

        var navHTML = ""
        for pat in navBlockPatterns {
            if let groups = firstMatch(pattern: pat, in: html), groups.count >= 2 {
                navHTML = groups[1]
                break
            }
        }
        if navHTML.isEmpty { navHTML = html }

        let linkPattern = "<a[^>]*href=\"([^\"]+)\"[^>]*>([^<]+)</a>"
        let matches = allMatches(pattern: linkPattern, in: navHTML)
        var seen: Set<String> = []

        let knownPaths = ["/category/", "/dy/", "/ks/", "/douyu/", "/hy/", "/hj/", "/tt/", "/wh/", "/asmr/", "/xb/", "/xsp/", "/rdgz/"]

        for groups in matches {
            guard groups.count >= 3 else { continue }
            let href = groups[1]
            let name = groups[2].trimmingCharacters(in: .whitespaces)

            if href == "#" || href == "/" || href.hasPrefix("http") { continue }
            let skipWords = ["about", "contact", "tags", "top", "start", "time"]
            if skipWords.contains(where: { href.lowercased().contains($0) }) { continue }
            if name.isEmpty { continue }

            let isCat = knownPaths.contains(where: { href.contains($0) })

            if isCat {
                let cid = href.hasPrefix("/") ? href : "/\(href)"
                if !seen.contains(cid) {
                    seen.insert(cid)
                    categories.append(KanliaoCategory(cid: cid, name: name))
                }
            }
        }

        return categories
    }

    // MARK: - HTML 解析：视频列表

    private func parseVideoList(from html: String, base: String) -> [KanliaoVideo] {
        var videos: [KanliaoVideo] = []
        let articlePattern = "<article[^>]*>(.*?)</article>"
        let articleMatches = allMatches(pattern: articlePattern, in: html)

        for groups in articleMatches {
            guard groups.count >= 2 else { continue }
            let articleHTML = groups[1]
            if isAdvertisement(articleHTML) { continue }
            if let vod = parseVideoItem(articleHTML, base: base) {
                videos.append(vod)
            }
        }

        return videos
    }

    private func parseVideoItem(_ item: String, base: String) -> KanliaoVideo? {
        guard let linkGroups = firstMatch(pattern: "<a[^>]*href=\"([^\"]+)\"[^>]*>", in: item),
              linkGroups.count >= 2 else { return nil }

        let href = linkGroups[1]
        let vodId: String
        if href.hasPrefix("http") {
            vodId = href
        } else if href.hasPrefix("/") {
            vodId = href
        } else {
            vodId = "/\(href)"
        }

        let pageUrl: String
        if href.hasPrefix("http") {
            pageUrl = href
        } else if href.hasPrefix("/") {
            pageUrl = "\(base)\(href)"
        } else {
            pageUrl = "\(base)/\(href)"
        }

        let title: String
        if let h2Groups = firstMatch(pattern: "<h2[^>]*>([^<]+)</h2>", in: item), h2Groups.count >= 2 {
            title = h2Groups[1].replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        } else if let titleGroups = firstMatch(pattern: "(?:post-card-title|entry-title)[^>]*>([^<]+)<", in: item), titleGroups.count >= 2 {
            title = titleGroups[1].replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }

        let cover = extractImage(from: item, base: base)

        var remarks = ""
        if let dateGroups = firstMatch(pattern: "<time[^>]*datetime=\"([^\"]+)\"[^>]*>", in: item), dateGroups.count >= 2 {
            remarks = dateGroups[1]
        } else if let metaGroups = firstMatch(pattern: "(?:post-meta|entry-meta|post-card-info)[^>]*>([^<]+)<", in: item), metaGroups.count >= 2 {
            remarks = metaGroups[1].trimmingCharacters(in: .whitespaces)
        }

        return KanliaoVideo(vodId: vodId, title: title, cover: cover, pageUrl: pageUrl, remarks: remarks)
    }

    private func extractImage(from html: String, base: String) -> String {
        if let bgGroups = firstMatch(pattern: "background-image:\\s*url\\([\"']?([^\"')]+)[\"']?\\)", in: html),
           bgGroups.count >= 2 {
            let url = bgGroups[1]
            if !url.hasPrefix("data:") {
                return normalizeImageURL(url, base: base)
            }
        }

        if let imgGroups = firstMatch(pattern: "<img[^>]*data-src=\"([^\"]+)\"[^>]*>", in: html),
           imgGroups.count >= 2 {
            return normalizeImageURL(imgGroups[1], base: base)
        }

        if let imgGroups = firstMatch(pattern: "<img[^>]*src=\"([^\"]+)\"[^>]*>", in: html),
           imgGroups.count >= 2 {
            return normalizeImageURL(imgGroups[1], base: base)
        }

        return ""
    }

    private func normalizeImageURL(_ url: String, base: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("http") { return trimmed }
        if trimmed.hasPrefix("//") { return "https:\(trimmed)" }
        if trimmed.hasPrefix("/") { return "\(base)\(trimmed)" }
        return "\(base)/\(trimmed)"
    }

    // MARK: - 广告过滤

    private func isAdvertisement(_ html: String) -> Bool {
        let adKeywords = ["热搜HOT", "手机链接", "DNS设置", "修改DNS", "WIFI设置"]
        for keyword in adKeywords {
            if html.contains(keyword) { return true }
        }
        return false
    }

    // MARK: - 分页解析

    private func parsePageCount(from html: String) -> Int {
        var pageNumbers: [Int] = []
        let pagePattern = "/(\\d+)/?\""
        let matches = allMatches(pattern: pagePattern, in: html)
        for groups in matches {
            guard groups.count >= 2, let num = Int(groups[1]) else { continue }
            pageNumbers.append(num)
        }

        if let pagesPattern = firstMatch(pattern: "page-numbers[^>]*>(.*?)</div>", in: html),
           pagesPattern.count >= 2 {
            let digitPattern = ">(\\d+)<"
            for groups in allMatches(pattern: digitPattern, in: pagesPattern[1]) {
                guard groups.count >= 2, let num = Int(groups[1]) else { continue }
                pageNumbers.append(num)
            }
        }

        if let maxPage = pageNumbers.max() { return maxPage }
        if html.contains("next") || html.contains("下一页") { return 9999 }
        return 1
    }

    // MARK: - 播放地址提取

    private func extractPlayURL(from html: String) -> String? {
        // 1. DPlayer data-config
        let dplayerPattern = "<div[^>]*class=\"[^\"]*dplayer[^\"]*\"[^>]*data-config=\"([^\"]+)\"[^>]*>"
        if let groups = firstMatch(pattern: dplayerPattern, in: html), groups.count >= 2 {
            let configStr = groups[1]
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#34;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&#38;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&#60;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&#62;", with: ">")
            if let urlGroups = firstMatch(pattern: "\"url\"\\s*:\\s*\"([^\"]+)\"", in: configStr),
               urlGroups.count >= 2 {
                return urlGroups[1].replacingOccurrences(of: "\\/", with: "/")
            }
        }

        // 2. 通用视频配置 JSON（video, playerConfig 等）
        let configPatterns = [
            "var\\s+video\\s*=\\s*\\{([^}]+)\\}",
            "playerConfig\\s*=\\s*\\{([^}]+)\\}",
            "\"video\"\\s*:\\s*\\{([^}]+)\\}",
        ]
        for pat in configPatterns {
            if let groups = firstMatch(pattern: pat, in: html), groups.count >= 2 {
                if let urlGroups = firstMatch(pattern: "\"url\"\\s*:\\s*\"([^\"]+)\"", in: groups[1]),
                   urlGroups.count >= 2 {
                    return urlGroups[1].replacingOccurrences(of: "\\/", with: "/")
                }
                if let urlGroups = firstMatch(pattern: "\"src\"\\s*:\\s*\"([^\"]+)\"", in: groups[1]),
                   urlGroups.count >= 2 {
                    return urlGroups[1].replacingOccurrences(of: "\\/", with: "/")
                }
            }
        }

        // 3. 直接 m3u8/mp4 URL
        if let groups = firstMatch(pattern: "(https?://[^\"'\\s]+\\.m3u8[^\"'\\s]*)", in: html),
           groups.count >= 2 {
            return groups[1]
        }
        if let groups = firstMatch(pattern: "(https?://[^\"'\\s]+\\.mp4[^\"'\\s]*)", in: html),
           groups.count >= 2 {
            return groups[1]
        }

        // 4. video 标签
        if let groups = firstMatch(pattern: "<video[^>]*src=\"([^\"]+)\"[^>]*>", in: html),
           groups.count >= 2 {
            return groups[1]
        }
        if let groups = firstMatch(pattern: "<video[^>]*data-src=\"([^\"]+)\"[^>]*>", in: html),
           groups.count >= 2 {
            return groups[1]
        }

        // 5. source 标签
        if let groups = firstMatch(pattern: "<source[^>]*src=\"([^\"]+)\"[^>]*>", in: html),
           groups.count >= 2 {
            return groups[1]
        }

        // 6. iframe 内嵌播放器
        if let groups = firstMatch(pattern: "<iframe[^>]*src=\"([^\"]+)\"[^>]*>", in: html),
           groups.count >= 2 {
            let iframeSrc = groups[1]
            if iframeSrc.contains("player") || iframeSrc.contains("play") || iframeSrc.contains(".m3u8") || iframeSrc.contains(".mp4") {
                return iframeSrc.hasPrefix("http") ? iframeSrc : nil
            }
        }

        return nil
    }
}

// MARK: - URLSession Delegate（允许自签名证书）

class _KanliaoSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            if let serverTrust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
