import Foundation

// MARK: - GBK 编码扩展
extension String.Encoding {
    static let gbk: String.Encoding = {
        let cfEnc = CFStringEncodings.GB_18030_2000
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEnc.rawValue))
        return String.Encoding(rawValue: nsEnc)
    }()
    static let big5: String.Encoding = {
        let cfEnc = CFStringEncodings.big5
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEnc.rawValue))
        return String.Encoding(rawValue: nsEnc)
    }()
    static let gb2312: String.Encoding = {
        let cfEnc = CFStringEncodings.GB_2312_80
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEnc.rawValue))
        return String.Encoding(rawValue: nsEnc)
    }()
}

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

    private let platformName = "麻豆免费"

    // 默认域名列表（按优先级排列，12个以上）
    private let defaultDomains = [
        "https://c-you.hair",
        "https://www.yamdck.com",
        "https://yamdck.com",
        "https://madoufree.com",
        "https://www.madoufree.com",
        "https://madou.tv",
        "https://www.madou.tv",
        "https://mdvideo.xyz",
        "https://www.mdvideo.xyz",
        "https://madoufree.xyz",
        "https://madoufree.me",
        "https://mdav.me",
        "https://www.mdav.me",
        "https://madou.app",
        "https://mdvideo.app",
    ]

    private var _activeBaseURL: String?
    private var activeBaseURL: String {
        if let cached = _activeBaseURL { return cached }
        let customs = WelfareDomainStore.shared.domains(for: platformName)
        if let first = customs.first {
            _activeBaseURL = first
            return first
        }
        let first = defaultDomains.first ?? "https://c-you.hair"
        _activeBaseURL = first
        return first
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 25
        c.httpShouldSetCookies = true
        c.httpCookieAcceptPolicy = .always
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            "Accept-Encoding": "gzip, deflate",
            "Connection": "keep-alive",
            "Cache-Control": "max-age=0",
        ]
        return URLSession(configuration: c)
    }()

    private var cachedCategories: [MadouFreeCategory]?

    private let fallbackCategories: [MadouFreeCategory] = [
        MadouFreeCategory(cid: "6", name: "国产精品"),
        MadouFreeCategory(cid: "7", name: "中文字幕"),
        MadouFreeCategory(cid: "8", name: "伦理影片"),
        MadouFreeCategory(cid: "9", name: "自拍偷拍"),
        MadouFreeCategory(cid: "10", name: "口交视频"),
        MadouFreeCategory(cid: "11", name: "日韩无码"),
        MadouFreeCategory(cid: "12", name: "制服诱惑"),
        MadouFreeCategory(cid: "13", name: "国产色情"),
        MadouFreeCategory(cid: "14", name: "麻豆传媒"),
        MadouFreeCategory(cid: "15", name: "天美传媒"),
        MadouFreeCategory(cid: "16", name: "果冻传媒"),
        MadouFreeCategory(cid: "17", name: "蜜桃传媒"),
        MadouFreeCategory(cid: "18", name: "91制片厂"),
        MadouFreeCategory(cid: "19", name: "精东影业"),
        MadouFreeCategory(cid: "20", name: "无码专区"),
        MadouFreeCategory(cid: "21", name: "三级片"),
        MadouFreeCategory(cid: "22", name: "动漫卡通"),
        MadouFreeCategory(cid: "23", name: "主播福利"),
        MadouFreeCategory(cid: "24", name: "明星换脸"),
        MadouFreeCategory(cid: "25", name: "强奸乱伦"),
    ]

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

    // MARK: - HTML 实体解码

    private func decodeHTMLEntities(_ string: String) -> String {
        var result = string
        let namedEntities: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
            "&apos;": "'", "&nbsp;": " ", "&copy;": "©", "&reg;": "®",
            "&ldquo;": "\"", "&rdquo;": "\"", "&lsquo;": "'", "&rsquo;": "'",
            "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
        ]
        for (entity, char) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);", options: []) {
            let matches = regex.matches(in: result, options: [], range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let numRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range(at: 0), in: result),
                      let num = Int(result[numRange]),
                      let scalar = UnicodeScalar(num) else { continue }
                result.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }
        return result
    }

    // MARK: - 域名探测

    @discardableResult
    private func probeAvailableDomain() async -> String? {
        let bases = defaultDomains
        for base in bases {
            print("[MadouFree] 探测域名: \(base)")
            guard let html = await fetchHTML(base + "/", referer: base), !html.isEmpty else { continue }
            if html.count > 500 && (html.contains("<a") || html.contains("video") || html.contains("麻豆")) {
                _activeBaseURL = base
                WelfareDomainStore.shared.setDomains([base], for: platformName)
                print("[MadouFree] 探测到可用域名: \(base)")
                return base
            }
        }
        print("[MadouFree] 未探测到可用域名")
        return nil
    }

    // MARK: - 自适应分类

    func fetchCategories() async -> [MadouFreeCategory] {
        if let cached = cachedCategories { return cached }

        let customDomains = WelfareDomainStore.shared.domains(for: platformName)
        let bases = customDomains.isEmpty ? defaultDomains : customDomains

        for base in bases {
            print("[MadouFree] 尝试获取分类: \(base)")
            guard let html = await fetchHTML(base + "/", referer: base) else {
                print("[MadouFree] 获取首页 HTML 失败: \(base)")
                continue
            }

            guard html.count > 200 else {
                print("[MadouFree] 页面内容过短，跳过: \(base) (\(html.count) 字节)")
                continue
            }

            let parsed = parseCategories(from: html)
            if !parsed.isEmpty {
                if customDomains.isEmpty {
                    WelfareDomainStore.shared.setDomains([base], for: platformName)
                }
                _activeBaseURL = base
                cachedCategories = parsed
                print("[MadouFree] 成功解析 \(parsed.count) 个分类，使用域名: \(base)")
                return parsed
            } else {
                print("[MadouFree] 分类解析为空，页面长度: \(html.count)")
            }
        }

        print("[MadouFree] 所有域名均失败，使用 fallback 分类")
        return fallbackCategories
    }

    func resetDomain() {
        cachedCategories = nil
        WelfareDomainStore.shared.clearDomains(for: platformName)
        _activeBaseURL = nil
    }

    func reprobe() {
        cachedCategories = nil
        _activeBaseURL = nil
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

        guard let html = await fetchHTMLWithRetry(url, referer: base) else {
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
        guard let html = await fetchHTMLWithRetry(url, referer: base) else { return nil }

        // 第一层：直接提取
        if let m3u8 = extractPlayURL(from: html) {
            print("[MadouFree] 第一层提取到播放地址: \(m3u8.prefix(80))...")
            return normalizePlayURL(m3u8, base: base)
        }

        // 第二层：iframe 解析
        if let iframeURL = extractIframeURL(from: html, base: base) {
            print("[MadouFree] 发现 iframe，尝试第二层解析: \(iframeURL.prefix(60))...")
            if let iframeHTML = await fetchHTMLWithRetry(iframeURL, referer: url) {
                if let playURL = extractPlayURL(from: iframeHTML) {
                    print("[MadouFree] iframe 层提取到播放地址: \(playURL.prefix(80))...")
                    return normalizePlayURL(playURL, base: base)
                }
                // 第三层：iframe 内嵌 iframe
                if let iframeURL2 = extractIframeURL(from: iframeHTML, base: iframeURL) {
                    print("[MadouFree] 发现第二层 iframe，继续解析")
                    if let iframeHTML2 = await fetchHTMLWithRetry(iframeURL2, referer: iframeURL) {
                        if let playURL = extractPlayURL(from: iframeHTML2) {
                            print("[MadouFree] 第三层提取到播放地址")
                            return normalizePlayURL(playURL, base: base)
                        }
                    }
                }
            }
        }

        print("[MadouFree] 未能提取到播放地址，返回原始 URL")
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
        guard let html = await fetchHTMLWithRetry(url, referer: base) else { return [] }
        return parseVideoList(from: html, base: base)
    }

    // MARK: - 网络请求（含代理支持 + 重试机制 + 多编码）

    private func fetchHTMLWithRetry(_ urlString: String, referer: String) async -> String? {
        let result = await fetchHTML(urlString, referer: referer)
        if result != nil { return result }

        print("[MadouFree] 第1次重试请求: \(urlString.prefix(60))...")
        try? await Task.sleep(nanoseconds: 300_000_000)
        if let result2 = await fetchHTML(urlString, referer: referer) { return result2 }

        print("[MadouFree] 第2次重试请求: \(urlString.prefix(60))...")
        try? await Task.sleep(nanoseconds: 500_000_000)
        return await fetchHTML(urlString, referer: referer)
    }

    private func fetchHTML(_ urlString: String, referer: String) async -> String? {
        let proxyEnabled = WelfareProxyStore.shared.isProxyEnabled(for: platformName)
        let finalURL: String
        let finalReferer: String

        if proxyEnabled {
            guard let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            finalURL = WelfareProxyStore.shared.proxyURL + encoded
            finalReferer = WelfareProxyStore.shared.proxyURL
            print("[MadouFree] 使用代理请求: \(urlString.prefix(60))...")
        } else {
            finalURL = urlString
            finalReferer = referer
        }

        guard let url = URL(string: finalURL) else {
            print("[MadouFree] fetchHTML: URL 无效 - \(finalURL.prefix(80))")
            return nil
        }

        var req = URLRequest(url: url)
        req.setValue(finalReferer, forHTTPHeaderField: "Referer")
        if proxyEnabled {
            req.setValue(finalReferer, forHTTPHeaderField: "Origin")
        } else {
            if let host = URL(string: referer)?.host {
                req.setValue(host, forHTTPHeaderField: "Host")
            }
        }
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        req.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("max-age=0", forHTTPHeaderField: "Cache-Control")
        req.setValue("?1", forHTTPHeaderField: "Sec-Fetch-Dest")
        req.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        req.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        req.setValue("?1", forHTTPHeaderField: "Sec-Fetch-User")
        req.setValue("\"Google Chrome\";v=\"135\", \"Chromium\";v=\"135\", \"Not-A.Brand\";v=\"24\"", forHTTPHeaderField: "sec-ch-ua")
        req.timeoutInterval = 25

        do {
            let (data, resp) = try await session.data(for: req)
            guard let httpResp = resp as? HTTPURLResponse,
                  (200...299).contains(httpResp.statusCode) else {
                let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? -1
                print("[MadouFree] HTTP 状态码异常: \(statusCode) for \(urlString.prefix(60))")
                return nil
            }

            // 尝试多种编码解码：UTF-8 → GBK → GB2312 → Big5 → ASCII → ISO Latin-1
            var raw: String?
            let encodings: [String.Encoding] = [.utf8, .gbk, .gb2312, .big5, .ascii, .isoLatin1]
            for enc in encodings {
                if let decoded = String(data: data, encoding: enc), !decoded.isEmpty {
                    raw = decoded
                    break
                }
            }

            guard let html = raw, !html.isEmpty else {
                print("[MadouFree] 页面内容解码失败或为空")
                return nil
            }

            if html.count < 100 {
                print("[MadouFree] 页面内容过短 (\(html.count) 字节)")
                return nil
            }

            return html
        } catch {
            print("[MadouFree] fetchHTML error: \(error.localizedDescription) for \(urlString.prefix(60))")
            return nil
        }
    }

    // MARK: - HTML 解析：分类（4种策略）

    private func parseCategories(from html: String) -> [MadouFreeCategory] {
        var categories: [MadouFreeCategory] = []
        var seen: Set<String> = []

        let skipWords = ["about", "contact", "tags", "tag", "top", "start", "time",
                         "首页", "home", "search", "搜索", "关于", "联系",
                         "register", "login", "注册", "登录", "vip", "会员",
                         "下载", "公告", "帮助", "feedback", "隐私", "协议"]

        // 策略一：特定格式（vodtype/{cid}.html）
        let specificPattern = "<a[^>]*href=\"[^\"]*vodtype/(\\d+)\\.html\"[^>]*>([^<]+)</a>"
        let specificMatches = allMatches(pattern: specificPattern, in: html)
        for groups in specificMatches {
            guard groups.count >= 3 else { continue }
            let cid = groups[1]
            let name = groups[2].trimmingCharacters(in: .whitespacesAndNewlines)
            if let cat = makeMadouCategory(cid: cid, name: name, skipWords: skipWords, seen: &seen) {
                categories.append(cat)
            }
        }
        if categories.count >= 5 {
            print("[MadouFree] 策略一(特定格式)匹配到 \(categories.count) 个分类")
            return categories
        }

        // 策略二：导航栏解析
        if categories.count < 5 {
            let navPatterns = [
                "<nav[^>]*>(.*?)</nav>",
                "<div[^>]*class=\"[^\"]*(?:header|top-bar|nav-wrap|menu-wrap|navbar|nav)[^\"]*\"[^>]*>(.*?)</div>",
                "<ul[^>]*class=\"[^\"]*(?:menu|nav|navbar|top-menu)[^\"]*\"[^>]*>(.*?)</ul>",
            ]
            var navHTML = ""
            for pat in navPatterns {
                if let groups = firstMatch(pattern: pat, in: html), groups.count >= 2 {
                    navHTML = groups[1]
                    break
                }
            }
            if !navHTML.isEmpty {
                let linkPattern = "<a[^>]*href=\"([^\"]+)\"[^>]*>([^<]+)</a>"
                let matches = allMatches(pattern: linkPattern, in: navHTML)
                for groups in matches {
                    guard groups.count >= 3 else { continue }
                    let href = groups[1].trimmingCharacters(in: .whitespaces)
                    let name = groups[2].trimmingCharacters(in: .whitespacesAndNewlines)
                    if let cid = extractCid(from: href),
                       let cat = makeMadouCategory(cid: cid, name: name, skipWords: skipWords, seen: &seen) {
                        categories.append(cat)
                    }
                }
            }
        }

        // 策略三：侧边栏解析
        if categories.count < 5 {
            let sidebarPatterns = [
                "<aside[^>]*>(.*?)</aside>",
                "<div[^>]*class=\"[^\"]*(?:sidebar|side|widget|category|cat-list|sidenav)[^\"]*\"[^>]*>(.*?)</div>",
                "<ul[^>]*class=\"[^\"]*(?:cat|category|side-list)[^\"]*\"[^>]*>(.*?)</ul>",
            ]
            for pat in sidebarPatterns {
                for groups in allMatches(pattern: pat, in: html) {
                    guard groups.count >= 2 else { continue }
                    let sidebarHTML = groups[1]
                    let linkPattern = "<a[^>]*href=\"([^\"]+)\"[^>]*>([^<]+)</a>"
                    let matches = allMatches(pattern: linkPattern, in: sidebarHTML)
                    for sm in matches {
                        guard sm.count >= 3 else { continue }
                        let href = sm[1].trimmingCharacters(in: .whitespaces)
                        let name = sm[2].trimmingCharacters(in: .whitespacesAndNewlines)
                        if let cid = extractCid(from: href),
                           let cat = makeMadouCategory(cid: cid, name: name, skipWords: skipWords, seen: &seen) {
                            categories.append(cat)
                        }
                    }
                }
                if categories.count >= 8 { break }
            }
        }

        // 策略四：通用链接匹配
        if categories.count < 3 {
            print("[MadouFree] 使用通用链接策略解析分类")
            let linkPattern = "<a[^>]*href=\"([^\"]+)\"[^>]*>([^<]+)</a>"
            let allLinkMatches = allMatches(pattern: linkPattern, in: html)
            for groups in allLinkMatches {
                guard groups.count >= 3 else { continue }
                let href = groups[1].trimmingCharacters(in: .whitespaces)
                let name = groups[2].trimmingCharacters(in: .whitespacesAndNewlines)
                guard name.count >= 2 && name.count <= 8 else { continue }
                guard !name.contains(" ") else { continue }
                if let cid = extractCid(from: href),
                   let cat = makeMadouCategory(cid: cid, name: name, skipWords: skipWords, seen: &seen) {
                    categories.append(cat)
                }
            }
        }

        print("[MadouFree] 共解析到 \(categories.count) 个分类")
        return categories
    }

    private func extractCid(from href: String) -> String? {
        // 从 URL 中提取分类 ID
        if let groups = firstMatch(pattern: "vodtype/(\\d+)", in: href), groups.count >= 2 {
            return groups[1]
        }
        if let groups = firstMatch(pattern: "cid=(\\d+)", in: href), groups.count >= 2 {
            return groups[1]
        }
        if let groups = firstMatch(pattern: "/(\\d+).html", in: href), groups.count >= 2 {
            return groups[1]
        }
        let clean = href.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = clean.split(separator: "/").filter { !$0.isEmpty }
        guard let last = components.last, let cid = Int(String(last)) else { return nil }
        return String(cid)
    }

    private func makeMadouCategory(cid: String, name: String, skipWords: [String], seen: inout Set<String>) -> MadouFreeCategory? {
        guard !cid.isEmpty && !name.isEmpty else { return nil }
        guard name.count >= 2 && name.count <= 10 else { return nil }
        guard !seen.contains(cid) else { return nil }

        let lowerName = name.lowercased()
        for skip in skipWords {
            if lowerName.contains(skip.lowercased()) { return nil }
        }

        seen.insert(cid)
        return MadouFreeCategory(cid: cid, name: name)
    }

    // MARK: - HTML 解析：视频列表（4种策略）

    private func parseVideoList(from html: String, base: String) -> [MadouFreeVideo] {
        var videos: [MadouFreeVideo] = []
        var seenIDs: Set<String> = []

        // 策略一：原有结构（resent-grid recommended-grid）
        let cardPattern = "<div[^>]*class=\"[^\"]*resent-grid[^\"]*recommended-grid[^\"]*\"[^>]*>(.*?)</div>\\s*</div>\\s*</div>\\s*</div>"
        let cards = allMatches(pattern: cardPattern, in: html)
        for groups in cards {
            guard groups.count >= 2 else { continue }
            let card = groups[1]
            if let vod = parseVideoCard(card, base: base), !seenIDs.contains(vod.vodId) {
                seenIDs.insert(vod.vodId)
                videos.append(vod)
            }
        }
        if videos.count >= 5 {
            print("[MadouFree] 策略一(原有结构)匹配到 \(videos.count) 条视频")
            return videos
        }

        // 策略二：多种卡片结构
        if videos.count < 5 {
            let cardSelectors = [
                "video-item", "video-card", "item-box", "list-item",
                "post-item", "content-item", "vod-item", "movie-item",
                "grid-item", "card-item", "stui-vodlist__box",
            ]
            for sel in cardSelectors {
                let pattern = "<[^>]*class=\"[^\"]*\(sel)[^\"]*\"[^>]*>(.*?)(?:</div>\\s*</div>|</li>|</div>)"
                let matches = allMatches(pattern: pattern, in: html)
                for groups in matches {
                    guard groups.count >= 2 else { continue }
                    let itemHTML = groups[1]
                    guard !isAdvertisement(itemHTML) else { continue }
                    guard let vod = parseVideoCard(itemHTML, base: base) else { continue }
                    if seenIDs.contains(vod.vodId) { continue }
                    seenIDs.insert(vod.vodId)
                    videos.append(vod)
                }
                if videos.count >= 10 { break }
            }
            if videos.count >= 5 {
                print("[MadouFree] 策略二(卡片结构)匹配到 \(videos.count) 条视频")
                return videos
            }
        }

        // 策略三：单条正则（img + title + link）
        if videos.isEmpty {
            let singlePatterns = [
                "<a[^>]*href=\"([^\"]+)\"[^>]*>[\\s\\S]*?<img[^>]*data-original=\"([^\"]+)\"[^>]*>[\\s\\S]*?class=\"title\"[^>]*>([^<]+)</a>",
                "<a[^>]*href=\"([^\"]+)\"[^>]*>[\\s\\S]*?<img[^>]*src=\"([^\"]+)\"[^>]*>[\\s\\S]*?<h[0-9][^>]*>([^<]+)</h[0-9]>",
                "<div[^>]*>[\\s\\S]*?<a[^>]*href=\"([^\"]+)\"[^>]*>[\\s\\S]*?<img[^>]*data-src=\"([^\"]+)\"[^>]*>[\\s\\S]*?class=\"[^\"]*title[^\"]*\"[^>]*>([^<]+)<",
            ]
            for pattern in singlePatterns {
                let matches = allMatches(pattern: pattern, in: html)
                for groups in matches {
                    guard groups.count >= 4 else { continue }
                    let href = groups[1]
                    let img = groups[2]
                    let title = groups[3].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty && title.count >= 2 else { continue }

                    let vodId = href
                    let playPath = href
                    let cover = normalizeImageURL(img, base: base)

                    var remarks = ""
                    if let viewsGroups = firstMatch(pattern: "views-info[^>]*>.*?<span[^>]*>([^<]+)</span>", in: groups[0] ?? ""),
                       viewsGroups.count >= 2 {
                        remarks = viewsGroups[1].trimmingCharacters(in: .whitespaces) + "观看"
                    }

                    guard !seenIDs.contains(vodId) else { continue }
                    seenIDs.insert(vodId)
                    videos.append(MadouFreeVideo(
                        vodId: vodId, title: title, cover: cover,
                        playPath: playPath, remarks: remarks
                    ))
                }
                if videos.count >= 5 { break }
            }
            if videos.count >= 3 {
                print("[MadouFree] 策略三(单条正则)匹配到 \(videos.count) 条视频")
                return videos
            }
            videos.removeAll()
            seenIDs.removeAll()
        }

        // 策略四：兜底模式（通用 a + img 组合）
        if videos.isEmpty {
            print("[MadouFree] 使用策略四(兜底模式)")
            let genericPattern = "<a[^>]*href=\"([^\"]+)\"[^>]*>[\\s\\S]*?<img[^>]*>[\\s\\S]*?</a>"
            let matches = allMatches(pattern: genericPattern, in: html)
            for groups in matches {
                guard groups.count >= 1 else { continue }
                let itemHTML = groups[0]
                guard !isAdvertisement(itemHTML) else { continue }
                guard let vod = parseVideoCard(itemHTML, base: base) else { continue }
                guard !vod.title.isEmpty && !vod.cover.isEmpty else { continue }
                if seenIDs.contains(vod.vodId) { continue }
                seenIDs.insert(vod.vodId)
                videos.append(vod)
            }
            print("[MadouFree] 策略四匹配到 \(videos.count) 条视频")
        }

        if videos.isEmpty {
            print("[MadouFree] ===== 视频列表解析失败调试信息 =====")
            print("[MadouFree] HTML 长度: \(html.count)")
            print("[MadouFree] 包含 img 标签: \(html.contains("<img"))")
            print("[MadouFree] 包含 data-original: \(html.contains("data-original"))")
            print("[MadouFree] 包含 title 类: \(html.contains("title"))")
            print("[MadouFree] ====================================")
        }

        return videos
    }

    private func parseVideoCard(_ card: String, base: String) -> MadouFreeVideo? {
        // 链接提取
        guard let hrefGroups = firstMatch(pattern: "<a[^>]*href=\"([^\"]+)\"[^>]*>", in: card),
              hrefGroups.count >= 2 else { return nil }
        let vodId = hrefGroups[1]
        guard !vodId.isEmpty else { return nil }

        // 标题提取（多种方式）
        var title = ""
        let titlePatterns = [
            "class=\"title\"[^>]*>([^<]+)</a>",
            "class=\"[^\"]*video-title[^\"]*\"[^>]*>([^<]+)<",
            "<h[0-9][^>]*>([^<]+)</h[0-9]>",
            "class=\"[^\"]*title[^\"]*\"[^>]*>([^<]+)<",
            "title=\"([^\"]+)\"",
            "alt=\"([^\"]+)\"",
        ]
        for pat in titlePatterns {
            if let groups = firstMatch(pattern: pat, in: card), groups.count >= 2 {
                let t = groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && t.count >= 2 {
                    title = t
                    break
                }
            }
        }
        guard !title.isEmpty else { return nil }
        title = decodeHTMLEntities(title)

        // 封面图提取（8种属性）
        let cover = extractCover(from: card, base: base)

        // 备注/观看次数提取
        var remarks = ""
        let remarkPatterns = [
            "views-info[^>]*>.*?<span[^>]*>([^<]+)</span>",
            "class=\"[^\"]*views[^\"]*\"[^>]*>([^<]+)<",
            "class=\"[^\"]*hits[^\"]*\"[^>]*>([^<]+)<",
            "class=\"[^\"]*duration[^\"]*\"[^>]*>([^<]+)<",
            "class=\"[^\"]*time[^\"]*\"[^>]*>([^<]+)<",
            "class=\"[^\"]*remarks[^\"]*\"[^>]*>([^<]+)<",
            "<span[^>]*>([0-9:,次观看部集]+)</span>",
        ]
        for pat in remarkPatterns {
            if let groups = firstMatch(pattern: pat, in: card), groups.count >= 2 {
                let r = groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !r.isEmpty {
                    remarks = r
                    break
                }
            }
        }

        return MadouFreeVideo(
            vodId: vodId, title: title, cover: cover,
            playPath: vodId, remarks: remarks
        )
    }

    // MARK: - 封面图提取（8种属性）

    private func extractCover(from html: String, base: String) -> String {
        let attrs = [
            "data-original", "data-src", "data-lazy-src", "data-cover",
            "data-url", "data-image", "src",
        ]
        for attr in attrs {
            if let groups = firstMatch(pattern: "<img[^>]*\(attr)=\"([^\"]+)\"[^>]*>", in: html),
               groups.count >= 2 {
                let url = groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty && !url.hasPrefix("data:") else { continue }
                return normalizeImageURL(url, base: base)
            }
        }

        // background-image
        if let bgGroups = firstMatch(pattern: "background-image:\\s*url\\([\"']?([^\"')]+)[\"']?\\)", in: html),
           bgGroups.count >= 2 {
            let url = bgGroups[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty && !url.hasPrefix("data:") {
                return normalizeImageURL(url, base: base)
            }
        }

        // srcset
        if let srcsetGroups = firstMatch(pattern: "<img[^>]*srcset=\"([^\"]+)\"[^>]*>", in: html),
           srcsetGroups.count >= 2 {
            if let firstURL = srcsetGroups[1].components(separatedBy: ",").first?
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: " ")
                .first?
                .trimmingCharacters(in: .whitespaces),
               !firstURL.isEmpty && !firstURL.hasPrefix("data:") {
                return normalizeImageURL(firstURL, base: base)
            }
        }

        return ""
    }

    private func normalizeImageURL(_ url: String, base: String) -> String {
        var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        trimmed = decodeHTMLEntities(trimmed)
        trimmed = trimmed.replacingOccurrences(of: "\\/", with: "/")

        if trimmed.hasPrefix("http") { return trimmed }
        if trimmed.hasPrefix("//") { return "https:\(trimmed)" }
        if trimmed.hasPrefix("/") {
            let cleanBase = base.hasSuffix("/") ? String(base.dropLast()) : base
            return "\(cleanBase)\(trimmed)"
        }
        let cleanBase = base.hasSuffix("/") ? base : "\(base)/"
        return "\(cleanBase)\(trimmed)"
    }

    // MARK: - 广告过滤

    private func isAdvertisement(_ html: String) -> Bool {
        let adKeywords = [
            "广告", "推广", "ad-", "ad_", "advertisement", "sponsor",
            "广告位", "赞助商", "telegram", "电报群",
            "adsbygoogle", "google_ad", "googlesyndication",
        ]
        let lower = html.lowercased()
        for keyword in adKeywords {
            if lower.contains(keyword.lowercased()) { return true }
        }
        return false
    }

    // MARK: - HTML 解析：分页

    private func parsePageCount(from html: String, currentPage: Int) -> Int {
        // 查找 "当前页/总页数" 格式
        if let groups = firstMatch(pattern: "class=\"active\"[^>]*>.*?(\\d+)\\s*/\\s*(\\d+)", in: html),
           groups.count >= 3, let total = Int(groups[2]) {
            return total
        }

        // 查找分页链接
        let pageLinks = allMatches(pattern: "<a[^>]*href=\"[^\"]*vodtype/[^\"]*-(\\d+)\\.html\"", in: html)
        let pages = pageLinks.compactMap { groups -> Int? in
            guard groups.count >= 2 else { return nil }
            return Int(groups[1])
        }
        if let maxPage = pages.max(), maxPage > currentPage {
            return maxPage
        }

        // 备用：page 参数
        let altPattern = "page=(\\d+)"
        let altMatches = allMatches(pattern: altPattern, in: html)
        let altPages = altMatches.compactMap { groups -> Int? in
            guard groups.count >= 2 else { return nil }
            return Int(groups[1])
        }
        return altPages.max() ?? (currentPage + 2)
    }

    // MARK: - HTML 解析：播放地址（6+策略）

    private func extractPlayURL(from html: String) -> String? {
        // 策略1: player_data JSON
        if let groups = firstMatch(pattern: "var\\s+player_data\\s*=\\s*(\\{[^;]+\\})", in: html),
           groups.count >= 2 {
            let jsonStr = groups[1]
            if let url = extractURLFromJSONContent(jsonStr) {
                print("[MadouFree] 策略1(player_data JSON)提取到播放地址")
                return url
            }
        }

        // 策略2: m3u8直链
        if let groups = firstMatch(pattern: "(https?://[^\"'\\s<>]+\\.m3u8[^\"'\\s<>]*)", in: html),
           groups.count >= 2 {
            let url = decodeHTMLEntities(groups[1]).replacingOccurrences(of: "\\/", with: "/")
            print("[MadouFree] 策略2(m3u8直链)提取到播放地址")
            return url
        }

        // 策略3: mp4直链
        if let groups = firstMatch(pattern: "(https?://[^\"'\\s<>]+\\.mp4[^\"'\\s<>]*)", in: html),
           groups.count >= 2 {
            let url = decodeHTMLEntities(groups[1]).replacingOccurrences(of: "\\/", with: "/")
            print("[MadouFree] 策略3(mp4直链)提取到播放地址")
            return url
        }

        // 策略4: video / source 标签
        let videoPatterns = [
            "<video[^>]*src=\"([^\"]+)\"[^>]*>",
            "<video[^>]*data-src=\"([^\"]+)\"[^>]*>",
            "<source[^>]*src=\"([^\"]+)\"[^>]*>",
        ]
        for pat in videoPatterns {
            if let groups = firstMatch(pattern: pat, in: html), groups.count >= 2 {
                let url = decodeHTMLEntities(groups[1]).replacingOccurrences(of: "\\/", with: "/")
                if !url.isEmpty {
                    print("[MadouFree] 策略4(video/source标签)提取到播放地址")
                    return url
                }
            }
        }

        // 策略5: JS变量
        let jsVarPatterns = [
            "video_url\\s*=\\s*[\"']([^\"']+)[\"']",
            "videoUrl\\s*=\\s*[\"']([^\"']+)[\"']",
            "play_url\\s*=\\s*[\"']([^\"']+)[\"']",
            "m3u8_url\\s*=\\s*[\"']([^\"']+)[\"']",
            "mp4_url\\s*=\\s*[\"']([^\"']+)[\"']",
            "src\\s*[=:]\\s*[\"']([^\"']+\\.(?:m3u8|mp4)[^\"']*)[\"']",
            "url\\s*[=:]\\s*[\"']([^\"']+\\.(?:m3u8|mp4)[^\"']*)[\"']",
        ]
        for pat in jsVarPatterns {
            if let groups = firstMatch(pattern: pat, in: html), groups.count >= 2 {
                let url = decodeHTMLEntities(groups[1]).replacingOccurrences(of: "\\/", with: "/")
                if !url.isEmpty && (url.contains(".m3u8") || url.contains(".mp4") || url.hasPrefix("http")) {
                    print("[MadouFree] 策略5(JS变量)提取到播放地址")
                    return url
                }
            }
        }

        // 策略6: iframe
        if let groups = firstMatch(pattern: "<iframe[^>]+src=\"([^\"]+)\"", in: html),
           groups.count >= 2 {
            let url = groups[1].trimmingCharacters(in: .whitespaces)
            let skipPatterns = ["google", "facebook", "baidu", "cnzz", "51.la", "tongji",
                                "ads", "advert", "googletag", "doubleclick", "analytics"]
            let lower = url.lowercased()
            var isAd = false
            for skip in skipPatterns {
                if lower.contains(skip) { isAd = true; break }
            }
            if !isAd && !url.isEmpty {
                print("[MadouFree] 策略6(iframe)提取到播放地址")
                return url
            }
        }

        // 策略7: DPlayer / CKPlayer / 其他播放器配置
        let playerPatterns = [
            "<div[^>]*class=\"[^\"]*dplayer[^\"]*\"[^>]*data-config=\"([^\"]+)\"[^>]*>",
            "playerConfig\\s*=\\s*(\\{[\\s\\S]{0,2000}?\\})",
            "window\\.playerData\\s*=\\s*(\\{[\\s\\S]{0,2000}?\\})",
            "new\\s+[A-Z]\\w*Player[\\s\\S]{0,500}?[\"'](https?://[^\"']+\\.(?:m3u8|mp4)[^\"']*)[\"']",
            "ckplayer[\\s\\S]{0,500}?[\"']video[\"']\\s*[=:]\\s*[\"']([^\"']+)[\"']",
        ]
        for pat in playerPatterns {
            if let groups = firstMatch(pattern: pat, in: html), groups.count >= 2 {
                let content = groups[1]
                if content.hasPrefix("{") || content.hasPrefix("[") {
                    if let url = extractURLFromJSONContent(content) {
                        print("[MadouFree] 策略7(播放器配置JSON)提取到播放地址")
                        return url
                    }
                } else {
                    let url = decodeHTMLEntities(content).replacingOccurrences(of: "\\/", with: "/")
                    if !url.isEmpty {
                        print("[MadouFree] 策略7(播放器配置)提取到播放地址")
                        return url
                    }
                }
            }
        }

        return nil
    }

    // MARK: - 从 JSON 内容中提取视频 URL

    private func extractURLFromJSONContent(_ jsonString: String) -> String? {
        let decoded = decodeHTMLEntities(jsonString)
        let urlKeys = ["url", "src", "video_url", "videoUrl", "play_url", "playUrl",
                       "m3u8_url", "mp4_url", "video", "movie", "source", "videoSrc"]
        for key in urlKeys {
            let pattern = "\"\(key)\"\\s*:\\s*\"([^\"]+)\""
            if let groups = firstMatch(pattern: pattern, in: decoded), groups.count >= 2 {
                var url = groups[1].replacingOccurrences(of: "\\/", with: "/")
                url = url.trimmingCharacters(in: .whitespaces)
                if !url.isEmpty && (url.contains(".m3u8") || url.contains(".mp4") || url.hasPrefix("http")) {
                    return url
                }
            }
        }
        return nil
    }

    // MARK: - 提取 iframe URL

    private func extractIframeURL(from html: String, base: String) -> String? {
        let iframePattern = "<iframe[^>]*src=\"([^\"]+)\"[^>]*>"
        guard let groups = firstMatch(pattern: iframePattern, in: html),
              groups.count >= 2 else { return nil }

        var iframeSrc = groups[1].trimmingCharacters(in: .whitespaces)
        guard !iframeSrc.isEmpty else { return nil }

        let skipPatterns = ["google", "facebook", "baidu", "cnzz", "51.la", "tongji",
                            "ads", "advert", "googletag", "doubleclick", "analytics"]
        let lower = iframeSrc.lowercased()
        for skip in skipPatterns {
            if lower.contains(skip) { return nil }
        }

        if iframeSrc.hasPrefix("//") {
            iframeSrc = "https:" + iframeSrc
        } else if iframeSrc.hasPrefix("/") {
            iframeSrc = base + iframeSrc
        } else if !iframeSrc.hasPrefix("http") {
            iframeSrc = base + "/" + iframeSrc
        }

        return iframeSrc
    }

    // MARK: - 播放地址规范化

    private func normalizePlayURL(_ url: String, base: String) -> String {
        var result = url.trimmingCharacters(in: .whitespacesAndNewlines)
        result = decodeHTMLEntities(result)
        result = result.replacingOccurrences(of: "\\/", with: "/")

        if result.hasPrefix("http") { return result }
        if result.hasPrefix("//") { return "https:\(result)" }
        if result.hasPrefix("/") {
            let cleanBase = base.hasSuffix("/") ? String(base.dropLast()) : base
            return "\(cleanBase)\(result)"
        }
        let cleanBase = base.hasSuffix("/") ? base : "\(base)/"
        return "\(cleanBase)\(result)"
    }
}
