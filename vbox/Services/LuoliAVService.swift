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
    let remarks: String
}

// MARK: - 萝莉AV 服务

@MainActor
final class LuoliAVService: ObservableObject {
    static let shared = LuoliAVService()

    private let platformName = "萝莉AV"

    // 默认域名列表（按优先级排列，12个以上）
    private let defaultDomains = [
        "https://212602.luoliav.cc",
        "https://www.luoliav.cc",
        "https://luoliav.cc",
        "https://luoliav.com",
        "https://www.luoliav.com",
        "https://m.luoliav.cc",
        "https://llav.tv",
        "https://www.llav.tv",
        "https://luoli.tv",
        "https://www.luoli.tv",
        "https://llvideo.com",
        "https://luoliav.xyz",
        "https://luoliav.me",
        "https://luoliav.app",
        "https://llav.app",
    ]

    private var _activeBaseURL: String?
    private var activeBaseURL: String {
        if let cached = _activeBaseURL { return cached }
        let customs = WelfareDomainStore.shared.domains(for: platformName)
        if let first = customs.first {
            _activeBaseURL = first
            return first
        }
        let first = defaultDomains.first ?? "https://212602.luoliav.cc"
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

    private let fallbackCategories: [LuoliAVCategory] = [
        LuoliAVCategory(cid: "1", name: "国产精选"),
        LuoliAVCategory(cid: "2", name: "日韩AV"),
        LuoliAVCategory(cid: "3", name: "蓝光超清"),
        LuoliAVCategory(cid: "4", name: "欧美精品"),
        LuoliAVCategory(cid: "5", name: "异族风情"),
        LuoliAVCategory(cid: "6", name: "动漫专区"),
        LuoliAVCategory(cid: "7", name: "无码专区"),
        LuoliAVCategory(cid: "8", name: "有码专区"),
        LuoliAVCategory(cid: "9", name: "中文字幕"),
        LuoliAVCategory(cid: "10", name: "丝袜美腿"),
        LuoliAVCategory(cid: "11", name: "制服诱惑"),
        LuoliAVCategory(cid: "12", name: "人妻熟女"),
        LuoliAVCategory(cid: "13", name: "清纯少女"),
        LuoliAVCategory(cid: "14", name: "强奸乱伦"),
        LuoliAVCategory(cid: "15", name: "三级片"),
        LuoliAVCategory(cid: "16", name: "明星换脸"),
        LuoliAVCategory(cid: "17", name: "主播福利"),
        LuoliAVCategory(cid: "18", name: "偷拍自拍"),
    ]

    private var cachedCategories: [LuoliAVCategory]?

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
        // 数字实体 &#ddd;
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
            print("[LuoliAV] 探测域名: \(base)")
            guard let html = await fetchHTML(base + "/", referer: base), !html.isEmpty else { continue }
            if html.count > 500 && (html.contains("<a") || html.contains("video") || html.contains("萝莉")) {
                _activeBaseURL = base
                WelfareDomainStore.shared.setDomains([base], for: platformName)
                print("[LuoliAV] 探测到可用域名: \(base)")
                return base
            }
        }
        print("[LuoliAV] 未探测到可用域名")
        return nil
    }

    // MARK: - 自适应分类获取

    func fetchCategories() async -> [LuoliAVCategory] {
        if let cached = cachedCategories { return cached }

        // 优先使用自定义域名
        let customDomains = WelfareDomainStore.shared.domains(for: platformName)
        let bases = customDomains.isEmpty ? defaultDomains : customDomains

        for base in bases {
            print("[LuoliAV] 尝试获取分类: \(base)")
            guard let html = await fetchHTML("\(base)/index.html", referer: base) else {
                print("[LuoliAV] 获取首页 HTML 失败: \(base)")
                continue
            }

            guard html.count > 200 else {
                print("[LuoliAV] 页面内容过短，跳过: \(base) (\(html.count) 字节)")
                continue
            }

            let parsed = parseCategories(from: html)
            if !parsed.isEmpty {
                if customDomains.isEmpty {
                    WelfareDomainStore.shared.setDomains([base], for: platformName)
                }
                _activeBaseURL = base
                cachedCategories = parsed
                print("[LuoliAV] 成功解析 \(parsed.count) 个分类，使用域名: \(base)")
                return parsed
            } else {
                print("[LuoliAV] 分类解析为空，页面长度: \(html.count)")
            }
        }

        print("[LuoliAV] 所有域名均失败，使用 fallback 分类")
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

    func fetchVideos(cid: String, page: Int) async -> (videos: [LuoliAVVideo], pageCount: Int) {
        let base = activeBaseURL
        let url = "\(base)/list.php?cid=\(cid)&page=\(page)"
        guard let html = await fetchHTMLWithRetry(url, referer: base) else {
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
        guard let html = await fetchHTMLWithRetry(url, referer: base) else { return nil }

        // 第一层：直接提取
        if let playURL = extractPlayURL(from: html) {
            print("[LuoliAV] 第一层提取到播放地址: \(playURL.prefix(80))...")
            return normalizePlayURL(playURL, base: base)
        }

        // 第二层：iframe 解析
        if let iframeURL = extractIframeURL(from: html, base: base) {
            print("[LuoliAV] 发现 iframe，尝试第二层解析: \(iframeURL.prefix(60))...")
            if let iframeHTML = await fetchHTMLWithRetry(iframeURL, referer: url) {
                if let playURL = extractPlayURL(from: iframeHTML) {
                    print("[LuoliAV] iframe 层提取到播放地址: \(playURL.prefix(80))...")
                    return normalizePlayURL(playURL, base: base)
                }
                // 第三层：iframe 内嵌 iframe
                if let iframeURL2 = extractIframeURL(from: iframeHTML, base: iframeURL) {
                    print("[LuoliAV] 发现第二层 iframe，继续解析")
                    if let iframeHTML2 = await fetchHTMLWithRetry(iframeURL2, referer: iframeURL) {
                        if let playURL = extractPlayURL(from: iframeHTML2) {
                            print("[LuoliAV] 第三层提取到播放地址")
                            return normalizePlayURL(playURL, base: base)
                        }
                    }
                }
            }
        }

        print("[LuoliAV] 未能提取到播放地址，返回原始 URL")
        return url
    }

    // MARK: - 搜索

    func search(keyword: String, page: Int) async -> [LuoliAVVideo] {
        let base = activeBaseURL
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "\(base)/search.php?keyword=\(encoded)&page=\(page)"
        guard let html = await fetchHTMLWithRetry(url, referer: base) else { return [] }
        return parseVideoList(from: html, base: base)
    }

    // MARK: - 网络请求（含代理支持 + 重试机制 + 多编码）

    private func fetchHTMLWithRetry(_ urlString: String, referer: String) async -> String? {
        let result = await fetchHTML(urlString, referer: referer)
        if result != nil { return result }

        // 第一次重试
        print("[LuoliAV] 第1次重试请求: \(urlString.prefix(60))...")
        try? await Task.sleep(nanoseconds: 300_000_000)
        if let result2 = await fetchHTML(urlString, referer: referer) { return result2 }

        // 第二次重试
        print("[LuoliAV] 第2次重试请求: \(urlString.prefix(60))...")
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
            print("[LuoliAV] 使用代理请求: \(urlString.prefix(60))...")
        } else {
            finalURL = urlString
            finalReferer = referer
        }

        guard let url = URL(string: finalURL) else {
            print("[LuoliAV] fetchHTML: URL 无效 - \(finalURL.prefix(80))")
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
                print("[LuoliAV] HTTP 状态码异常: \(statusCode) for \(urlString.prefix(60))")
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
                print("[LuoliAV] 页面内容解码失败或为空")
                return nil
            }

            if html.count < 100 {
                print("[LuoliAV] 页面内容过短 (\(html.count) 字节)")
                return nil
            }

            return html
        } catch {
            print("[LuoliAV] fetchHTML error: \(error.localizedDescription) for \(urlString.prefix(60))")
            return nil
        }
    }

    // MARK: - HTML 解析：分类（4种策略）

    private func parseCategories(from html: String) -> [LuoliAVCategory] {
        var categories: [LuoliAVCategory] = []
        var seen: Set<String> = []

        let skipWords = ["about", "contact", "tags", "tag", "top", "start", "time",
                         "首页", "home", "search", "搜索", "关于", "联系",
                         "register", "login", "注册", "登录", "vip", "会员",
                         "下载", "公告", "帮助", "feedback", "隐私", "协议"]

        // 策略一：特定格式（list.php?cid=）
        let specificPattern = "<a[^>]*href=\"[^\"]*list\\.php\\?cid=(\\d+)[^\"]*\"[^>]*>([^<]+)</a>"
        let specificMatches = allMatches(pattern: specificPattern, in: html)
        for groups in specificMatches {
            guard groups.count >= 3 else { continue }
            let cid = groups[1]
            let name = groups[2].trimmingCharacters(in: .whitespacesAndNewlines)
            if let cat = makeLuoliCategory(cid: cid, name: name, skipWords: skipWords, seen: &seen) {
                categories.append(cat)
            }
        }
        if categories.count >= 5 {
            print("[LuoliAV] 策略一(特定格式)匹配到 \(categories.count) 个分类")
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
                       let cat = makeLuoliCategory(cid: cid, name: name, skipWords: skipWords, seen: &seen) {
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
                           let cat = makeLuoliCategory(cid: cid, name: name, skipWords: skipWords, seen: &seen) {
                            categories.append(cat)
                        }
                    }
                }
                if categories.count >= 8 { break }
            }
        }

        // 策略四：通用链接匹配
        if categories.count < 3 {
            print("[LuoliAV] 使用通用链接策略解析分类")
            let linkPattern = "<a[^>]*href=\"([^\"]+)\"[^>]*>([^<]+)</a>"
            let allLinkMatches = allMatches(pattern: linkPattern, in: html)
            for groups in allLinkMatches {
                guard groups.count >= 3 else { continue }
                let href = groups[1].trimmingCharacters(in: .whitespaces)
                let name = groups[2].trimmingCharacters(in: .whitespacesAndNewlines)
                guard name.count >= 2 && name.count <= 8 else { continue }
                guard !name.contains(" ") else { continue }
                if let cid = extractCid(from: href),
                   let cat = makeLuoliCategory(cid: cid, name: name, skipWords: skipWords, seen: &seen) {
                    categories.append(cat)
                }
            }
        }

        print("[LuoliAV] 共解析到 \(categories.count) 个分类")
        return categories
    }

    private func extractCid(from href: String) -> String? {
        // 从 URL 中提取分类 ID
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

    private func makeLuoliCategory(cid: String, name: String, skipWords: [String], seen: inout Set<String>) -> LuoliAVCategory? {
        guard !cid.isEmpty && !name.isEmpty else { return nil }
        guard name.count >= 2 && name.count <= 10 else { return nil }
        guard !seen.contains(cid) else { return nil }

        let lowerName = name.lowercased()
        for skip in skipWords {
            if lowerName.contains(skip.lowercased()) { return nil }
        }

        seen.insert(cid)
        return LuoliAVCategory(cid: cid, name: name)
    }

    // MARK: - HTML 解析：视频列表（4种策略）

    private func parseVideoList(from html: String, base: String) -> [LuoliAVVideo] {
        var videos: [LuoliAVVideo] = []
        var seenIDs: Set<String> = []

        // 策略一：原有结构（group item）
        let itemPattern = "<div[^>]*class=\"[^\"]*group[^\"]*item[^\"]*\"[^>]*>(.*?)</div>\\s*</div>\\s*</div>"
        let itemMatches = allMatches(pattern: itemPattern, in: html)
        for groups in itemMatches {
            guard groups.count >= 2 else { continue }
            if let vod = parseVideoItem(groups[1], base: base), !seenIDs.contains(vod.vodId) {
                seenIDs.insert(vod.vodId)
                videos.append(vod)
            }
        }
        if videos.count >= 5 {
            print("[LuoliAV] 策略一(原有结构)匹配到 \(videos.count) 条视频")
            return videos
        }

        // 策略二：多种卡片结构
        if videos.count < 5 {
            let cardSelectors = [
                "video-item", "video-card", "item-box", "list-item",
                "post-item", "content-item", "vod-item", "movie-item",
            ]
            for sel in cardSelectors {
                let pattern = "<[^>]*class=\"[^\"]*\(sel)[^\"]*\"[^>]*>(.*?)(?:</div>\\s*</div>|</li>|</div>)"
                let matches = allMatches(pattern: pattern, in: html)
                for groups in matches {
                    guard groups.count >= 2 else { continue }
                    let itemHTML = groups[1]
                    guard !isAdvertisement(itemHTML) else { continue }
                    guard let vod = parseVideoItem(itemHTML, base: base) else { continue }
                    if seenIDs.contains(vod.vodId) { continue }
                    seenIDs.insert(vod.vodId)
                    videos.append(vod)
                }
                if videos.count >= 10 { break }
            }
            if videos.count >= 5 {
                print("[LuoliAV] 策略二(卡片结构)匹配到 \(videos.count) 条视频")
                return videos
            }
        }

        // 策略三：单条正则（img + title + link）
        if videos.isEmpty {
            let singlePatterns = [
                "<a[^>]*href=\"([^\"]+)\"[^>]*>[\\s\\S]*?<img[^>]*data-original=\"([^\"]+)\"[^>]*>[\\s\\S]*?<a[^>]*class=\"[^\"]*font-bold[^\"]*\"[^>]*>([^<]+)</a>",
                "<a[^>]*href=\"([^\"]+)\"[^>]*>[\\s\\S]*?<img[^>]*src=\"([^\"]+)\"[^>]*>[\\s\\S]*?<h[0-9][^>]*>([^<]+)</h[0-9]>",
                "<div[^>]*>[\\s\\S]*?<a[^>]*href=\"([^\"]+)\"[^>]*>[\\s\\S]*?<img[^>]*data-src=\"([^\"]+)\"[^>]*>[\\s\\S]*?<a[^>]*>([^<]+)</a>",
            ]
            for pattern in singlePatterns {
                let matches = allMatches(pattern: pattern, in: html)
                for groups in matches {
                    guard groups.count >= 4 else { continue }
                    let href = groups[1]
                    let img = groups[2]
                    let title = groups[3].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty && title.count >= 2 else { continue }

                    var vodId = href
                    if let r = vodId.range(of: "\\?.*$", options: .regularExpression) {
                        vodId.removeSubrange(r)
                    }

                    let pageUrl: String
                    if vodId.hasPrefix("http") { pageUrl = vodId }
                    else if vodId.hasPrefix("/") { pageUrl = "\(base)\(vodId)" }
                    else { pageUrl = "\(base)/\(vodId)" }

                    let cover = normalizeImageURL(img, base: base)
                    guard !seenIDs.contains(vodId) else { continue }
                    seenIDs.insert(vodId)
                    videos.append(LuoliAVVideo(vodId: vodId, title: title, cover: cover, pageUrl: pageUrl, remarks: ""))
                }
                if videos.count >= 5 { break }
            }
            if videos.count >= 3 {
                print("[LuoliAV] 策略三(单条正则)匹配到 \(videos.count) 条视频")
                return videos
            }
            videos.removeAll()
            seenIDs.removeAll()
        }

        // 策略四：兜底模式（通用 a + img 组合）
        if videos.isEmpty {
            print("[LuoliAV] 使用策略四(兜底模式)")
            let genericPattern = "<a[^>]*href=\"([^\"]+)\"[^>]*>[\\s\\S]*?<img[^>]*>[\\s\\S]*?</a>"
            let matches = allMatches(pattern: genericPattern, in: html)
            for groups in matches {
                guard groups.count >= 1 else { continue }
                let itemHTML = groups[0]
                guard !isAdvertisement(itemHTML) else { continue }
                guard let vod = parseVideoItem(itemHTML, base: base) else { continue }
                guard !vod.title.isEmpty && !vod.cover.isEmpty else { continue }
                if seenIDs.contains(vod.vodId) { continue }
                seenIDs.insert(vod.vodId)
                videos.append(vod)
            }
            print("[LuoliAV] 策略四匹配到 \(videos.count) 条视频")
        }

        if videos.isEmpty {
            print("[LuoliAV] ===== 视频列表解析失败调试信息 =====")
            print("[LuoliAV] HTML 长度: \(html.count)")
            print("[LuoliAV] 包含 img 标签: \(html.contains("<img"))")
            print("[LuoliAV] 包含 data-original: \(html.contains("data-original"))")
            print("[LuoliAV] ====================================")
        }

        return videos
    }

    private func parseVideoItem(_ item: String, base: String) -> LuoliAVVideo? {
        // 链接提取
        guard let hrefGroups = firstMatch(pattern: "<a[^>]*href=\"([^\"]+)\"[^>]*>", in: item),
              hrefGroups.count >= 2 else { return nil }
        var vodId = hrefGroups[1]
        if let r = vodId.range(of: "\\?.*$", options: .regularExpression) {
            vodId.removeSubrange(r)
        }
        guard !vodId.isEmpty else { return nil }

        let pageUrl: String
        if vodId.hasPrefix("http") { pageUrl = vodId }
        else if vodId.hasPrefix("/") { pageUrl = "\(base)\(vodId)" }
        else { pageUrl = "\(base)/\(vodId)" }

        // 封面图提取（8种属性）
        let cover = extractCover(from: item, base: base)

        // 标题提取（多种方式）
        var title = ""
        let titlePatterns = [
            "<a[^>]*class=\"[^\"]*font-bold[^\"]*\"[^>]*>([^<]+)</a>",
            "<h[0-9][^>]*>([^<]+)</h[0-9]>",
            "class=\"[^\"]*title[^\"]*\"[^>]*>([^<]+)<",
            "class=\"[^\"]*video-title[^\"]*\"[^>]*>([^<]+)<",
            "<a[^>]*>([^<]+)</a>\\s*</div>\\s*$",
            "title=\"([^\"]+)\"",
            "alt=\"([^\"]+)\"",
        ]
        for pat in titlePatterns {
            if let groups = firstMatch(pattern: pat, in: item), groups.count >= 2 {
                let t = groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && t.count >= 2 {
                    title = t
                    break
                }
            }
        }
        guard !title.isEmpty else { return nil }
        title = decodeHTMLEntities(title)

        // 备注/时长提取
        var remarks = ""
        let remarkPatterns = [
            "class=\"[^\"]*duration[^\"]*\"[^>]*>([^<]+)<",
            "class=\"[^\"]*time[^\"]*\"[^>]*>([^<]+)<",
            "class=\"[^\"]*badge[^\"]*\"[^>]*>([^<]+)<",
            "class=\"[^\"]*remarks[^\"]*\"[^>]*>([^<]+)<",
            "<span[^>]*>([0-9:]+)</span>",
        ]
        for pat in remarkPatterns {
            if let groups = firstMatch(pattern: pat, in: item), groups.count >= 2 {
                let r = groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !r.isEmpty {
                    remarks = r
                    break
                }
            }
        }

        return LuoliAVVideo(vodId: vodId, title: title, cover: cover, pageUrl: pageUrl, remarks: remarks)
    }

    // MARK: - 封面图提取（8种属性）

    private func extractCover(from html: String, base: String) -> String {
        // 按优先级尝试
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

    private func parsePageCount(from html: String, cid: String, currentPage: Int) -> Int {
        let pattern = "list\\.php\\?cid=\(cid)&amp;page=(\\d+)"
        let matches = allMatches(pattern: pattern, in: html)
        let pages = matches.compactMap { groups -> Int? in
            guard groups.count >= 2 else { return nil }
            return Int(groups[1])
        }
        return pages.max() ?? (currentPage + 2)
    }

    // MARK: - HTML 解析：播放地址（6+策略）

    private func extractPlayURL(from html: String) -> String? {
        // 策略1: m3u8直链
        if let groups = firstMatch(pattern: "(https?://[^\"'\\s<>]+\\.m3u8[^\"'\\s<>]*)", in: html),
           groups.count >= 2 {
            let url = decodeHTMLEntities(groups[1]).replacingOccurrences(of: "\\/", with: "/")
            print("[LuoliAV] 策略1(m3u8直链)提取到播放地址")
            return url
        }

        // 策略2: mp4直链
        if let groups = firstMatch(pattern: "(https?://[^\"'\\s<>]+\\.mp4[^\"'\\s<>]*)", in: html),
           groups.count >= 2 {
            let url = decodeHTMLEntities(groups[1]).replacingOccurrences(of: "\\/", with: "/")
            print("[LuoliAV] 策略2(mp4直链)提取到播放地址")
            return url
        }

        // 策略3: JS变量
        let jsVarPatterns = [
            "var[^;]*video[^=]*=\\s*[\"']([^\"']+\\.m3u8[^\"']*)[\"']",
            "var[^;]*video[^=]*=\\s*[\"']([^\"']+\\.mp4[^\"']*)[\"']",
            "video_url\\s*=\\s*[\"']([^\"']+)[\"']",
            "videoUrl\\s*=\\s*[\"']([^\"']+)[\"']",
            "play_url\\s*=\\s*[\"']([^\"']+)[\"']",
            "m3u8_url\\s*=\\s*[\"']([^\"']+)[\"']",
            "src\\s*[=:]\\s*[\"']([^\"']+\\.(?:m3u8|mp4)[^\"']*)[\"']",
        ]
        for pat in jsVarPatterns {
            if let groups = firstMatch(pattern: pat, in: html), groups.count >= 2 {
                let url = decodeHTMLEntities(groups[1]).replacingOccurrences(of: "\\/", with: "/")
                if !url.isEmpty && (url.contains(".m3u8") || url.contains(".mp4") || url.hasPrefix("http")) {
                    print("[LuoliAV] 策略3(JS变量)提取到播放地址")
                    return url
                }
            }
        }

        // 策略4: video标签
        let videoPatterns = [
            "<video[^>]*src=\"([^\"]+)\"[^>]*>",
            "<video[^>]*data-src=\"([^\"]+)\"[^>]*>",
            "<source[^>]*src=\"([^\"]+)\"[^>]*>",
        ]
        for pat in videoPatterns {
            if let groups = firstMatch(pattern: pat, in: html), groups.count >= 2 {
                let url = decodeHTMLEntities(groups[1]).replacingOccurrences(of: "\\/", with: "/")
                if !url.isEmpty {
                    print("[LuoliAV] 策略4(video标签)提取到播放地址")
                    return url
                }
            }
        }

        // 策略5: 播放器配置JSON
        let jsonConfigPatterns = [
            "var\\s+player_data\\s*=\\s*(\\{[\\s\\S]{0,2000}?\\})",
            "playerConfig\\s*=\\s*(\\{[\\s\\S]{0,2000}?\\})",
            "window\\.playerData\\s*=\\s*(\\{[\\s\\S]{0,2000}?\\})",
            "\"video\"\\s*:\\s*(\\{[\\s\\S]{0,2000}?\\})",
        ]
        for pat in jsonConfigPatterns {
            if let groups = firstMatch(pattern: pat, in: html), groups.count >= 2 {
                if let url = extractURLFromJSONContent(groups[1]) {
                    print("[LuoliAV] 策略5(播放器配置)提取到播放地址")
                    return url
                }
            }
        }

        // 策略6: DPlayer / CKPlayer 配置
        let playerPatterns = [
            "<div[^>]*class=\"[^\"]*dplayer[^\"]*\"[^>]*data-config=\"([^\"]+)\"[^>]*>",
            "new\\s+[A-Z]\\w*Player[\\s\\S]{0,500}?[\"'](https?://[^\"']+\\.(?:m3u8|mp4)[^\"']*)[\"']",
            "ckplayer[\\s\\S]{0,500}?[\"']video[\"']\\s*[=:]\\s*[\"']([^\"']+)[\"']",
        ]
        for pat in playerPatterns {
            if let groups = firstMatch(pattern: pat, in: html), groups.count >= 2 {
                let url = decodeHTMLEntities(groups[1]).replacingOccurrences(of: "\\/", with: "/")
                if !url.isEmpty {
                    print("[LuoliAV] 策略6(播放器配置)提取到播放地址")
                    return url
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
