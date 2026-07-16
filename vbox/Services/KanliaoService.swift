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

    private let platformName = "今日看料"

    private let candidateDomains = [
        "https://kanliao2.one",
        "https://kanliao7.org",
        "https://kanliao7.net",
        "https://kanliao14.com",
    ]

    private var _activeBaseURL: String?
    private var activeBaseURL: String {
        if let cached = _activeBaseURL { return cached }
        let customs = WelfareDomainStore.shared.domains(for: platformName)
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

    // MARK: - HTML 实体解码

    private func decodeHTMLEntities(_ string: String) -> String {
        var result = string
        // 常见命名实体
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
        // 十六进制实体 &#xhhh;
        if let regex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);", options: []) {
            let matches = regex.matches(in: result, options: [], range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let hexRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range(at: 0), in: result),
                      let num = Int(result[hexRange], radix: 16),
                      let scalar = UnicodeScalar(num) else { continue }
                result.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }
        return result
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
                    WelfareDomainStore.shared.addDomain(for: platformName, domain)
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
            print("[Kanliao] 分类解析失败，使用 fallback 分类")
            return fallbackCategories
        }

        cachedCategories = parsed
        print("[Kanliao] 解析到 \(parsed.count) 个分类")
        return parsed
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
        guard let html = await fetchHTML(url, referer: base) else {
            print("[Kanliao] fetchPlayURL: 无法获取页面 HTML")
            return nil
        }

        // 第一层：直接从页面提取
        if let playURL = extractPlayURL(from: html) {
            print("[Kanliao] 第一层提取到播放地址: \(playURL.prefix(80))...")
            return normalizePlayURL(playURL, base: base)
        }

        // 第二层：iframe 递归解析
        if let iframeURL = extractIframeURL(from: html, base: base) {
            print("[Kanliao] 发现 iframe，尝试第二层解析: \(iframeURL.prefix(80))...")
            if let iframeHTML = await fetchHTML(iframeURL, referer: url) {
                if let playURL = extractPlayURL(from: iframeHTML) {
                    print("[Kanliao] 第二层(iframe)提取到播放地址: \(playURL.prefix(80))...")
                    return normalizePlayURL(playURL, base: base)
                }
                // 第三层：iframe 内还有 iframe
                if let iframeURL2 = extractIframeURL(from: iframeHTML, base: iframeURL) {
                    print("[Kanliao] 发现第二层 iframe，尝试第三层解析")
                    if let iframeHTML2 = await fetchHTML(iframeURL2, referer: iframeURL) {
                        if let playURL = extractPlayURL(from: iframeHTML2) {
                            print("[Kanliao] 第三层提取到播放地址: \(playURL.prefix(80))...")
                            return normalizePlayURL(playURL, base: base)
                        }
                    }
                }
            }
        }

        print("[Kanliao] 未能提取到播放地址")
        return nil
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

    // MARK: - 网络请求（含代理支持）

    private func fetchHTML(_ urlString: String, referer: String) async -> String? {
        let proxyEnabled = WelfareProxyStore.shared.isProxyEnabled(for: platformName)
        let finalURL: String
        let finalReferer: String

        if proxyEnabled {
            guard let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            finalURL = WelfareProxyStore.shared.proxyURL + encoded
            finalReferer = WelfareProxyStore.shared.proxyURL
            print("[Kanliao] 使用代理请求: \(urlString.prefix(60))...")
        } else {
            finalURL = urlString
            finalReferer = referer
        }

        guard let url = URL(string: finalURL) else {
            print("[Kanliao] fetchHTML: URL 无效 - \(finalURL.prefix(80))")
            return nil
        }
        var req = URLRequest(url: url)
        req.setValue(finalReferer, forHTTPHeaderField: "Referer")
        if proxyEnabled {
            req.setValue(finalReferer, forHTTPHeaderField: "Origin")
        } else {
            req.setValue(referer, forHTTPHeaderField: "Origin")
        }
        req.timeoutInterval = 20

        do {
            let (data, resp) = try await session.data(for: req)
            guard let httpResp = resp as? HTTPURLResponse,
                  (200...299).contains(httpResp.statusCode) else {
                print("[Kanliao] fetchHTTP 状态码异常: \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            let raw = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii)
                ?? String(data: data, encoding: .isoLatin1)
            return raw
        } catch {
            print("[Kanliao] fetchHTML error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 分类 ID 规范化

    private func normalizeCategoryID(_ href: String) -> String {
        var cid = href.trimmingCharacters(in: .whitespacesAndNewlines)
        // 移除域名部分
        if cid.hasPrefix("http") {
            if let url = URL(string: cid) {
                cid = url.path
            }
        }
        // 确保以 / 开头
        if !cid.hasPrefix("/") {
            cid = "/" + cid
        }
        // 确保以 / 结尾
        if !cid.hasSuffix("/") {
            cid = cid + "/"
        }
        return cid
    }

    // MARK: - HTML 解析：分类（双策略：导航栏 + 侧边栏）

    private func parseCategories(from html: String, base: String) -> [KanliaoCategory] {
        var categories: [KanliaoCategory] = []
        var seen: Set<String> = []

        let skipWords = ["about", "contact", "tags", "tag", "top", "start", "time",
                         "首页", "home", "search", "搜索", "关于", "联系",
                         "register", "login", "注册", "登录", "vip", "会员"]

        let knownPaths = ["/category/", "/dy/", "/ks/", "/douyu/", "/hy/", "/hj/",
                          "/tt/", "/wh/", "/asmr/", "/xb/", "/xsp/", "/rdgz/"]

        // 策略一：导航栏解析
        let navBlockPatterns = [
            "<nav[^>]*class=\"[^\"]*navbar[^\"]*\"[^>]*>(.*?)</nav>",
            "<ul[^>]*class=\"[^\"]*(?:navbar-nav|nav-menu|menu|main-nav|nav-list)[^\"]*\"[^>]*>(.*?)</ul>",
            "<div[^>]*class=\"[^\"]*(?:header-menu|nav-wrap|top-nav)[^\"]*\"[^>]*>(.*?)</div>",
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
        let navMatches = allMatches(pattern: linkPattern, in: navHTML)

        for groups in navMatches {
            guard groups.count >= 3 else { continue }
            let href = groups[1].trimmingCharacters(in: .whitespaces)
            let name = groups[2].trimmingCharacters(in: .whitespacesAndNewlines)

            if href.isEmpty || name.isEmpty { continue }
            if href == "#" || href == "/" { continue }
            if name.count < 2 || name.count > 8 { continue }

            // 跳过词过滤
            let lowerHref = href.lowercased()
            let lowerName = name.lowercased()
            if skipWords.contains(where: { lowerHref.contains($0) || lowerName.contains($0) }) { continue }

            // 判断是否为分类链接
            let isCat = knownPaths.contains(where: { href.contains($0) })
                || href.contains("/category/")
                || (href.hasPrefix("/") && href.split(separator: "/").count <= 3 && !href.contains("."))

            if isCat {
                let cid = normalizeCategoryID(href)
                if !seen.contains(cid) {
                    seen.insert(cid)
                    categories.append(KanliaoCategory(cid: cid, name: name))
                }
            }
        }

        // 如果导航栏解析结果不足，尝试策略二：侧边栏解析
        if categories.count < 3 {
            let sidebarPatterns = [
                "<div[^>]*class=\"[^\"]*(?:sidebar|side-nav|widget|category-list|cat-list)[^\"]*\"[^>]*>(.*?)</div>",
                "<aside[^>]*>(.*?)</aside>",
                "<ul[^>]*class=\"[^\"]*(?:cat|category|sidebar)[^\"]*\"[^>]*>(.*?)</ul>",
            ]

            for pat in sidebarPatterns {
                for groups in allMatches(pattern: pat, in: html) {
                    guard groups.count >= 2 else { continue }
                    let sidebarHTML = groups[1]
                    let sidebarMatches = allMatches(pattern: linkPattern, in: sidebarHTML)

                    for sm in sidebarMatches {
                        guard sm.count >= 3 else { continue }
                        let href = sm[1].trimmingCharacters(in: .whitespaces)
                        let name = sm[2].trimmingCharacters(in: .whitespacesAndNewlines)

                        if href.isEmpty || name.isEmpty { continue }
                        if href == "#" || href == "/" { continue }
                        if name.count < 2 || name.count > 10 { continue }
                        if href.hasPrefix("http") && !href.contains(base) { continue }

                        let lowerHref = href.lowercased()
                        let lowerName = name.lowercased()
                        if skipWords.contains(where: { lowerHref.contains($0) || lowerName.contains($0) }) { continue }

                        let cid = normalizeCategoryID(href)
                        if !seen.contains(cid) {
                            seen.insert(cid)
                            categories.append(KanliaoCategory(cid: cid, name: name))
                        }
                    }
                }
                if categories.count >= 5 { break }
            }
        }

        return categories
    }

    // MARK: - HTML 解析：视频列表（多种容器模式）

    private func parseVideoList(from html: String, base: String) -> [KanliaoVideo] {
        var videos: [KanliaoVideo] = []
        var seenIDs: Set<String> = []

        // 多种容器模式
        let containerPatterns = [
            // article 标签
            "<article[^>]*>(.*?)</article>",
            // 常见列表项 class
            "<div[^>]*class=\"[^\"]*(?:post-card|video-card|video-item|item-wrap|entry-card|list-item)[^\"]*\"[^>]*>(.*?)(?:</div>\\s*</div>|</div>)",
            // li 列表项
            "<li[^>]*class=\"[^\"]*(?:video-item|post-item|list-item|item)[^\"]*\"[^>]*>(.*?)</li>",
            // figure 包裹
            "<figure[^>]*>(.*?)</figure>",
        ]

        for pattern in containerPatterns {
            let matches = allMatches(pattern: pattern, in: html)

            for groups in matches {
                guard groups.count >= 2 else { continue }
                let itemHTML = groups[1]

                // 广告过滤
                if isAdvertisement(itemHTML) { continue }

                guard let vod = parseVideoItem(itemHTML, base: base) else { continue }

                // 去重
                if seenIDs.contains(vod.vodId) { continue }
                seenIDs.insert(vod.vodId)

                videos.append(vod)
            }

            if !videos.isEmpty {
                print("[Kanliao] 使用容器模式匹配到 \(videos.count) 条视频")
                break
            }
        }

        // 如果上述模式都没匹配到，尝试通用链接+图片模式
        if videos.isEmpty {
            print("[Kanliao] 容器模式未匹配到视频，尝试通用模式")
            let genericPattern = "<a[^>]*href=\"([^\"]+)\"[^>]*>[\\s\\S]*?<img[^>]*>[\\s\\S]*?</a>"
            let matches = allMatches(pattern: genericPattern, in: html)

            for groups in matches {
                guard groups.count >= 1 else { continue }
                let itemHTML = groups[0]

                if isAdvertisement(itemHTML) { continue }

                guard let vod = parseVideoItem(itemHTML, base: base) else { continue }
                if vod.title.isEmpty || vod.cover.isEmpty { continue }

                if seenIDs.contains(vod.vodId) { continue }
                seenIDs.insert(vod.vodId)

                videos.append(vod)
            }
            print("[Kanliao] 通用模式匹配到 \(videos.count) 条视频")
        }

        return videos
    }

    private func parseVideoItem(_ item: String, base: String) -> KanliaoVideo? {
        // 提取链接
        guard let linkGroups = firstMatch(pattern: "<a[^>]*href=\"([^\"]+)\"[^>]*>", in: item),
              linkGroups.count >= 2 else { return nil }

        let href = linkGroups[1]
        guard !href.isEmpty else { return nil }

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

        // 标题提取（6种模式）
        var title = ""
        let titlePatterns = [
            "<h2[^>]*>(.*?)</h2>",
            "<h3[^>]*>(.*?)</h3>",
            "<h4[^>]*>(.*?)</h4>",
            "(?:post-card-title|entry-title|video-title|item-title)[^>]*>(.*?)<",
            "title=\"([^\"]+)\"",
            "alt=\"([^\"]+)\"",
        ]

        for pat in titlePatterns {
            if let groups = firstMatch(pattern: pat, in: item), groups.count >= 2 {
                var t = groups[1]
                // 移除内嵌标签
                t = t.replacingOccurrences(of: "<[^>]+>", with: "")
                t = t.replacingOccurrences(of: "\n", with: " ")
                t = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && t.count >= 2 {
                    title = t
                    break
                }
            }
        }

        guard !title.isEmpty else { return nil }

        // 封面图提取
        let cover = extractImage(from: item, base: base)

        // 备注/时间
        var remarks = ""
        if let dateGroups = firstMatch(pattern: "<time[^>]*datetime=\"([^\"]+)\"[^>]*>", in: item), dateGroups.count >= 2 {
            remarks = dateGroups[1]
        } else if let metaGroups = firstMatch(pattern: "(?:post-meta|entry-meta|post-card-info|video-meta)[^>]*>(.*?)<", in: item), metaGroups.count >= 2 {
            remarks = metaGroups[1].trimmingCharacters(in: .whitespaces)
        }

        return KanliaoVideo(vodId: vodId, title: title, cover: cover, pageUrl: pageUrl, remarks: remarks)
    }

    // MARK: - 封面图提取（增强版）

    private func extractImage(from html: String, base: String) -> String {
        // 1. background-image 样式
        if let bgGroups = firstMatch(pattern: "background-image:\\s*url\\([\"']?([^\"')]+)[\"']?\\)", in: html),
           bgGroups.count >= 2 {
            let url = bgGroups[1].trimmingCharacters(in: .whitespaces)
            if !url.hasPrefix("data:") && !url.isEmpty {
                return normalizeImageURL(url, base: base)
            }
        }

        // 2. style 属性中的 background-image
        if let styleGroups = firstMatch(pattern: "style=\"[^\"]*background-image:\\s*url\\([\"']?([^\"')]+)[\"']?\\)", in: html),
           styleGroups.count >= 2 {
            let url = styleGroups[1].trimmingCharacters(in: .whitespaces)
            if !url.hasPrefix("data:") && !url.isEmpty {
                return normalizeImageURL(url, base: base)
            }
        }

        // 3. 9种懒加载属性
        let lazyAttrs = [
            "data-src", "data-original", "data-lazy-src", "data-lazy",
            "data-srcset", "data-cover", "data-url", "data-image", "data-thumb"
        ]
        for attr in lazyAttrs {
            if let imgGroups = firstMatch(pattern: "<img[^>]*\(attr)=\"([^\"]+)\"[^>]*>", in: html),
               imgGroups.count >= 2 {
                let url = imgGroups[1].trimmingCharacters(in: .whitespaces)
                if !url.hasPrefix("data:") && !url.isEmpty {
                    return normalizeImageURL(url, base: base)
                }
            }
        }

        // 4. srcset 属性（取第一张）
        if let srcsetGroups = firstMatch(pattern: "<img[^>]*srcset=\"([^\"]+)\"[^>]*>", in: html),
           srcsetGroups.count >= 2 {
            let srcsetValue = srcsetGroups[1]
            // srcset 格式: "url1 1x, url2 2x" 或 "url1 320w, url2 640w"
            if let firstURL = srcsetValue.components(separatedBy: ",").first?
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: " ")
                .first?
                .trimmingCharacters(in: .whitespaces),
               !firstURL.hasPrefix("data:") && !firstURL.isEmpty {
                return normalizeImageURL(firstURL, base: base)
            }
        }

        // 5. figure > img 结构
        if let figGroups = firstMatch(pattern: "<figure[^>]*>[\\s\\S]*?<img[^>]*src=\"([^\"]+)\"[^>]*>[\\s\\S]*?</figure>", in: html),
           figGroups.count >= 2 {
            let url = figGroups[1].trimmingCharacters(in: .whitespaces)
            if !url.hasPrefix("data:") && !url.isEmpty {
                return normalizeImageURL(url, base: base)
            }
        }

        // 6. noscript 备用图片
        if let noscriptGroups = firstMatch(pattern: "<noscript>[\\s\\S]*?<img[^>]*src=\"([^\"]+)\"[^>]*>[\\s\\S]*?</noscript>", in: html),
           noscriptGroups.count >= 2 {
            let url = noscriptGroups[1].trimmingCharacters(in: .whitespaces)
            if !url.hasPrefix("data:") && !url.isEmpty {
                return normalizeImageURL(url, base: base)
            }
        }

        // 7. 普通 img src
        if let imgGroups = firstMatch(pattern: "<img[^>]*src=\"([^\"]+)\"[^>]*>", in: html),
           imgGroups.count >= 2 {
            let url = imgGroups[1].trimmingCharacters(in: .whitespaces)
            if !url.hasPrefix("data:") && !url.isEmpty {
                return normalizeImageURL(url, base: base)
            }
        }

        return ""
    }

    private func normalizeImageURL(_ url: String, base: String) -> String {
        var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        // 处理 HTML 实体编码
        trimmed = decodeHTMLEntities(trimmed)

        // 处理转义的斜杠
        trimmed = trimmed.replacingOccurrences(of: "\\/", with: "/")

        if trimmed.hasPrefix("http") { return trimmed }
        if trimmed.hasPrefix("//") { return "https:\(trimmed)" }
        if trimmed.hasPrefix("/") {
            // 确保 base 不以 / 结尾
            let cleanBase = base.hasSuffix("/") ? String(base.dropLast()) : base
            return "\(cleanBase)\(trimmed)"
        }
        let cleanBase = base.hasSuffix("/") ? base : "\(base)/"
        return "\(cleanBase)\(trimmed)"
    }

    // MARK: - 广告过滤（增强）

    private func isAdvertisement(_ html: String) -> Bool {
        let adKeywords = [
            "热搜HOT", "手机链接", "DNS设置", "修改DNS", "WIFI设置",
            "广告", "推广", "ad-", "ad_", "advertisement", "sponsor",
            "广告位", "赞助商", "推荐", "点击进入", "立即查看",
            " telegram", "Telegram", "电报群",
        ]
        let lower = html.lowercased()
        for keyword in adKeywords {
            if lower.contains(keyword.lowercased()) { return true }
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

        if let maxPage = pageNumbers.max(), maxPage > 1 { return maxPage }
        if html.contains("next") || html.contains("下一页") { return 9999 }
        return 1
    }

    // MARK: - 播放地址提取（增强版：7种策略）

    private func extractPlayURL(from html: String) -> String? {
        // 策略1: DPlayer data-config
        let dplayerPattern = "<div[^>]*class=\"[^\"]*dplayer[^\"]*\"[^>]*data-config=\"([^\"]+)\"[^>]*>"
        if let groups = firstMatch(pattern: dplayerPattern, in: html), groups.count >= 2 {
            let configStr = decodeHTMLEntities(groups[1])
            if let url = extractURLFromJSONContent(configStr) {
                return url
            }
        }

        // 策略2: DPlayer config 属性
        let dplayerConfigPattern = "<div[^>]*class=\"[^\"]*dplayer[^\"]*\"[^>]*config=\"([^\"]+)\"[^>]*>"
        if let groups = firstMatch(pattern: dplayerConfigPattern, in: html), groups.count >= 2 {
            let configStr = decodeHTMLEntities(groups[1])
            if let url = extractURLFromJSONContent(configStr) {
                return url
            }
        }

        // 策略3: 内嵌 JSON 配置（video, playerConfig, player_data 等）
        let jsonConfigPatterns = [
            "var\\s+video\\s*=\\s*(\\{[\\s\\S]*?\\})",
            "playerConfig\\s*=\\s*(\\{[\\s\\S]*?\\})",
            "player_data\\s*=\\s*(\\{[\\s\\S]*?\\})",
            "\"video\"\\s*:\\s*(\\{[\\s\\S]*?\\})",
            "window\\.playerData\\s*=\\s*(\\{[\\s\\S]*?\\})",
        ]
        for pat in jsonConfigPatterns {
            if let groups = firstMatch(pattern: pat, in: html), groups.count >= 2 {
                let jsonStr = groups[1]
                if let url = extractURLFromJSONContent(jsonStr) {
                    return url
                }
            }
        }

        // 策略4: 直接 m3u8/mp4 URL
        if let url = extractVideoURLFromText(html) {
            return url
        }

        // 策略5: video 标签及其属性
        let videoTagPatterns = [
            "<video[^>]*src=\"([^\"]+)\"[^>]*>",
            "<video[^>]*data-src=\"([^\"]+)\"[^>]*>",
            "<video[^>]*data-original=\"([^\"]+)\"[^>]*>",
        ]
        for pat in videoTagPatterns {
            if let groups = firstMatch(pattern: pat, in: html), groups.count >= 2 {
                let url = groups[1].replacingOccurrences(of: "\\/", with: "/")
                if !url.isEmpty {
                    return decodeHTMLEntities(url)
                }
            }
        }

        // 策略6: source 标签
        if let groups = firstMatch(pattern: "<source[^>]*src=\"([^\"]+)\"[^>]*>", in: html),
           groups.count >= 2 {
            let url = groups[1].replacingOccurrences(of: "\\/", with: "/")
            if !url.isEmpty {
                return decodeHTMLEntities(url)
            }
        }

        // 策略7: 脚本中的视频变量
        let jsVarPatterns = [
            "video_url\\s*[=:]\\s*[\"']([^\"']+)[\"']",
            "videoUrl\\s*[=:]\\s*[\"']([^\"']+)[\"']",
            "play_url\\s*[=:]\\s*[\"']([^\"']+)[\"']",
            "m3u8\\s*[=:]\\s*[\"']([^\"']+)[\"']",
            "mp4\\s*[=:]\\s*[\"']([^\"']+)[\"']",
            "src\\s*[=:]\\s*[\"']([^\"']+\\.(?:m3u8|mp4)[^\"']*)[\"']",
        ]
        for pat in jsVarPatterns {
            if let groups = firstMatch(pattern: pat, in: html), groups.count >= 2 {
                let url = groups[1].replacingOccurrences(of: "\\/", with: "/")
                if !url.isEmpty && (url.contains(".m3u8") || url.contains(".mp4")) {
                    return decodeHTMLEntities(url)
                }
            }
        }

        return nil
    }

    // MARK: - 从 JSON 内容中提取视频 URL

    private func extractURLFromJSONContent(_ jsonString: String) -> String? {
        let decoded = decodeHTMLEntities(jsonString)

        // 常见的视频 URL 键名
        let urlKeys = ["url", "src", "video_url", "videoUrl", "play_url", "playUrl",
                       "m3u8_url", "mp4_url", "video", "movie", "source"]

        for key in urlKeys {
            // 匹配 "key": "value" 格式
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

    // MARK: - 从文本中提取视频 URL

    private func extractVideoURLFromText(_ text: String) -> String? {
        // m3u8 链接
        let m3u8Pattern = "(https?://[^\"'\\s<>]+\\.m3u8[^\"'\\s<>]*)"
        if let groups = firstMatch(pattern: m3u8Pattern, in: text), groups.count >= 2 {
            let url = groups[1].replacingOccurrences(of: "\\/", with: "/")
            return decodeHTMLEntities(url)
        }

        // mp4 链接
        let mp4Pattern = "(https?://[^\"'\\s<>]+\\.mp4[^\"'\\s<>]*)"
        if let groups = firstMatch(pattern: mp4Pattern, in: text), groups.count >= 2 {
            let url = groups[1].replacingOccurrences(of: "\\/", with: "/")
            return decodeHTMLEntities(url)
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

        // 跳过明显的广告/统计 iframe
        let skipPatterns = ["google", "facebook", "baidu", "cnzz", "51.la", "tongji",
                            "ads", "advert", "googletag", "doubleclick"]
        let lower = iframeSrc.lowercased()
        for skip in skipPatterns {
            if lower.contains(skip) { return nil }
        }

        // 规范化 URL
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
