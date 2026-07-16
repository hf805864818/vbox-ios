import Foundation
import CommonCrypto

// MARK: - 黑料不打烊 数据模型

struct HeiliaoCategory: Identifiable {
    var id: String { cid }
    let cid: String
    let name: String
}

struct HeiliaoVideo: Identifiable {
    var id: String { vodId }
    let vodId: String
    let title: String
    let cover: String
    let pageUrl: String
    let remarks: String
    let needsDecrypt: Bool
}

// MARK: - 黑料不打烊 服务

@MainActor
final class HeiliaoService: ObservableObject {
    static let shared = HeiliaoService()

    private let platformName = "黑料不打烊"

    // 默认域名列表（按优先级排列，12个以上）
    private let defaultDomains = [
        "https://heiliao.com",
        "https://heiliao.app",
        "https://www.heiliao.com",
        "https://51hl.online",
        "https://hl.dspqyb.com",
        "https://heiliao.tv",
        "https://heiliao.me",
        "https://heiliao.xyz",
        "https://heiliaoba.com",
        "https://heiliao666.com",
        "https://hl888.tv",
        "https://heiliaoku.com",
        "https://heiliao91.com",
        "https://hlvideo.com",
        "https://heiliaoshipin.com",
    ]

    private var _activeBaseURL: String?
    private var activeBaseURL: String {
        if let cached = _activeBaseURL { return cached }
        let customs = WelfareDomainStore.shared.domains(for: platformName)
        if let first = customs.first {
            _activeBaseURL = first
            return first
        }
        let first = defaultDomains.first ?? "https://heiliao.com"
        _activeBaseURL = first
        return first
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
            "Accept-Encoding": "gzip, deflate",
            "Connection": "keep-alive",
            "Cache-Control": "max-age=0",
        ]
        return URLSession(configuration: c)
    }()

    private let fallbackCategories: [HeiliaoCategory] = [
        HeiliaoCategory(cid: "hlcg", name: "最新黑料"),
        HeiliaoCategory(cid: "jrrs", name: "今日热瓜"),
        HeiliaoCategory(cid: "mrrb", name: "每日TOP10"),
        HeiliaoCategory(cid: "fczq", name: "反差女友"),
        HeiliaoCategory(cid: "xycg", name: "校园黑料"),
        HeiliaoCategory(cid: "whhl", name: "网红黑料"),
        HeiliaoCategory(cid: "mxcw", name: "明星丑闻"),
        HeiliaoCategory(cid: "ycsq", name: "原创社区"),
        HeiliaoCategory(cid: "ttsq", name: "推特社区"),
        HeiliaoCategory(cid: "shxw", name: "社会新闻"),
        HeiliaoCategory(cid: "gchl", name: "官场爆料"),
        HeiliaoCategory(cid: "ysdj", name: "影视短剧"),
        HeiliaoCategory(cid: "qqqw", name: "全球奇闻"),
        HeiliaoCategory(cid: "hlkt", name: "黑料课堂"),
        HeiliaoCategory(cid: "mrds", name: "每日大赛"),
        HeiliaoCategory(cid: "jqxs", name: "激情小说"),
        HeiliaoCategory(cid: "ttzz", name: "桃图杂志"),
        HeiliaoCategory(cid: "syzy", name: "深夜综艺"),
        HeiliaoCategory(cid: "djbl", name: "独家爆料"),
    ]

    private var cachedCategories: [HeiliaoCategory]?

    private let imageCache = NSCache<NSString, NSData>()

    private let aesKey: [UInt8] = Array("f5d965df75336270".utf8)
    private let aesIV: [UInt8]  = Array("97b60394abc2fbe1".utf8)

    private let decryptDomains = ["pic.gylhaa.cn", "new.slfpld.cn"]
    private let decryptPaths = ["/upload_01/", "/upload/"]

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

    // MARK: - AES-CBC 解密

    private func aesDecrypt(_ data: Data) -> Data? {
        let keyLength = kCCKeySizeAES128
        var numBytesDecrypted: size_t = 0
        let bufferSize = data.count + kCCBlockSizeAES128
        var outData = Data(count: bufferSize)

        let result = outData.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                aesKey.withUnsafeBytes { keyPtr in
                    aesIV.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, keyLength,
                            ivPtr.baseAddress,
                            inPtr.baseAddress, data.count,
                            outPtr.baseAddress, bufferSize,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }

        guard result == kCCSuccess else {
            print("[Heiliao] AES 解密失败，错误码: \(result)")
            return nil
        }
        return outData.prefix(numBytesDecrypted)
    }

    // MARK: - 图片加载（含代理支持 + 重试机制）

    func fetchDecryptedImageData(for urlString: String) async -> Data? {
        let cacheKey = urlString as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached as Data
        }

        let fullURL = normalizeImageURL(urlString, base: activeBaseURL)
        guard let url = URL(string: fullURL) else {
            print("[Heiliao] 图片 URL 无效: \(urlString.prefix(60))")
            return nil
        }

        let proxyEnabled = WelfareProxyStore.shared.isProxyEnabled(for: platformName)
        let finalURL: String
        let finalReferer: String

        if proxyEnabled {
            guard let encoded = fullURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            finalURL = WelfareProxyStore.shared.proxyURL + encoded
            finalReferer = WelfareProxyStore.shared.proxyURL
            print("[Heiliao] 图片使用代理: \(urlString.prefix(50))...")
        } else {
            finalURL = fullURL
            finalReferer = activeBaseURL + "/"
        }

        guard let requestURL = URL(string: finalURL) else { return nil }

        // 最多重试 2 次
        let maxRetries = 2
        var lastError: Error?

        for attempt in 0...maxRetries {
            if attempt > 0 {
                print("[Heiliao] 图片第 \(attempt) 次重试: \(urlString.prefix(50))...")
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒延迟
            }

            var req = URLRequest(url: requestURL)
            req.setValue(finalReferer, forHTTPHeaderField: "Referer")
            if proxyEnabled {
                req.setValue(finalReferer, forHTTPHeaderField: "Origin")
            }
            req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            req.setValue("image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 15

            do {
                let (data, resp) = try await session.data(for: req)
                guard let httpResp = resp as? HTTPURLResponse,
                      httpResp.statusCode == 200 else {
                    print("[Heiliao] 图片 HTTP 状态码异常: \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                    lastError = NSError(domain: "Heiliao", code: -1, userInfo: [NSLocalizedDescriptionKey: "HTTP status error"])
                    continue
                }

                guard !data.isEmpty else {
                    print("[Heiliao] 图片数据为空")
                    continue
                }

                if needsDecrypt(urlString) {
                    if let decrypted = aesDecrypt(data) {
                        imageCache.setObject(decrypted as NSData, forKey: cacheKey)
                        return decrypted
                    } else {
                        // 解密失败时的容错：尝试直接返回原始数据
                        print("[Heiliao] 图片解密失败，尝试直接使用原始数据")
                        // 检查是否为有效图片格式
                        if data.count > 100 {
                            imageCache.setObject(data as NSData, forKey: cacheKey)
                            return data
                        }
                        return nil
                    }
                }
                imageCache.setObject(data as NSData, forKey: cacheKey)
                return data
            } catch {
                lastError = error
                print("[Heiliao] 图片加载失败 (尝试\(attempt + 1)/\(maxRetries + 1)): \(error.localizedDescription)")
            }
        }

        if let error = lastError {
            print("[Heiliao] 图片加载最终失败: \(error.localizedDescription)")
        }
        return nil
    }

    func needsDecrypt(_ urlString: String) -> Bool {
        guard !urlString.isEmpty else { return false }
        let lower = urlString.lowercased()
        for domain in decryptDomains where lower.contains(domain) { return true }
        for path in decryptPaths where lower.contains(path) { return true }
        return false
    }

    // MARK: - 域名探测

    @discardableResult
    private func probeAvailableDomain() async -> String? {
        let bases = defaultDomains
        for base in bases {
            print("[Heiliao] 探测域名: \(base)")
            guard let html = await fetchHTML(base, referer: base + "/"), !html.isEmpty else { continue }
            // 检测是否为有效页面
            if html.count > 500 && (html.contains("<a") || html.contains("video") || html.contains("黑料")) {
                _activeBaseURL = base
                WelfareDomainStore.shared.setDomains([base], for: platformName)
                print("[Heiliao] 探测到可用域名: \(base)")
                return base
            }
        }
        print("[Heiliao] 未探测到可用域名")
        return nil
    }

    // MARK: - 自适应分类获取

    func fetchCategories() async -> [HeiliaoCategory] {
        if let cached = cachedCategories { return cached }

        // 优先使用自定义域名
        let customDomains = WelfareDomainStore.shared.domains(for: platformName)
        let bases = customDomains.isEmpty ? defaultDomains : customDomains

        for base in bases {
            print("[Heiliao] 尝试获取分类: \(base)")
            guard let html = await fetchHTML(base, referer: base + "/") else {
                print("[Heiliao] 获取首页 HTML 失败: \(base)")
                continue
            }

            // 空页面检测
            guard html.count > 200 else {
                print("[Heiliao] 页面内容过短，跳过: \(base) (\(html.count) 字节)")
                continue
            }

            let parsed = parseCategories(from: html)
            if !parsed.isEmpty {
                if customDomains.isEmpty {
                    WelfareDomainStore.shared.setDomains([base], for: platformName)
                }
                _activeBaseURL = base
                cachedCategories = parsed
                print("[Heiliao] 成功解析 \(parsed.count) 个分类，使用域名: \(base)")
                return parsed
            } else {
                print("[Heiliao] 分类解析为空，页面长度: \(html.count)")
            }
        }

        // 所有域名都失败，使用 fallback
        print("[Heiliao] 所有域名均失败，使用 fallback 分类")
        return fallbackCategories
    }

    func resetDomain() {
        cachedCategories = nil
        imageCache.removeAllObjects()
        WelfareDomainStore.shared.clearDomains(for: platformName)
        _activeBaseURL = nil
    }

    func reprobe() {
        cachedCategories = nil
        imageCache.removeAllObjects()
        _activeBaseURL = nil
    }

    // MARK: - 分类视频列表

    func fetchVideos(cid: String, page: Int) async -> (videos: [HeiliaoVideo], pageCount: Int) {
        let base = activeBaseURL
        let cleanCid = cid.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url: String
        if page == 1 {
            url = "\(base)/\(cleanCid)/"
        } else {
            url = "\(base)/\(cleanCid)/page/\(page)/"
        }

        guard let html = await fetchHTML(url, referer: base + "/") else {
            print("[Heiliao] fetchVideos: 无法获取 HTML")
            return ([], 1)
        }

        // 空页面检测
        guard html.count > 200 else {
            print("[Heiliao] 视频列表页面内容过短: \(html.count) 字节")
            return ([], 1)
        }

        let videos = parseVideoList(from: html, base: base)
        print("[Heiliao] 分类 cid=\(cid) page=\(page): \(videos.count)条")

        let pageCount = parsePageCount(from: html)
        return (videos, pageCount)
    }

    // MARK: - 视频详情（获取播放地址）

    func fetchPlayURL(pageUrl: String) async -> String? {
        let base = activeBaseURL
        let url = pageUrl.hasPrefix("http") ? pageUrl : "\(base)\(pageUrl)"
        guard let html = await fetchHTML(url, referer: base + "/") else {
            print("[Heiliao] fetchPlayURL: 无法获取详情页 HTML")
            return nil
        }

        // 第一层：直接提取
        if let playURL = extractPlayURL(from: html) {
            print("[Heiliao] 第一层提取到播放地址: \(playURL.prefix(80))...")
            return normalizePlayURL(playURL, base: base)
        }

        // 第二层：iframe 解析
        if let iframeURL = extractIframeURL(from: html, base: base) {
            print("[Heiliao] 发现 iframe，尝试第二层解析: \(iframeURL.prefix(60))...")
            if let iframeHTML = await fetchHTML(iframeURL, referer: url) {
                if let playURL = extractPlayURL(from: iframeHTML) {
                    print("[Heiliao] iframe 层提取到播放地址: \(playURL.prefix(80))...")
                    return normalizePlayURL(playURL, base: base)
                }
                // 第三层：iframe 内嵌 iframe
                if let iframeURL2 = extractIframeURL(from: iframeHTML, base: iframeURL) {
                    print("[Heiliao] 发现第二层 iframe，继续解析")
                    if let iframeHTML2 = await fetchHTML(iframeURL2, referer: iframeURL) {
                        if let playURL = extractPlayURL(from: iframeHTML2) {
                            print("[Heiliao] 第三层提取到播放地址")
                            return normalizePlayURL(playURL, base: base)
                        }
                    }
                }
            }
        }

        print("[Heiliao] 未能提取到播放地址")
        return nil
    }

    // MARK: - 搜索

    func search(keyword: String, page: Int) async -> [HeiliaoVideo] {
        let base = activeBaseURL
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "\(base)/index/search?word=\(encoded)"
        guard let html = await fetchHTML(url, referer: base + "/") else { return [] }
        return parseVideoList(from: html, base: base)
    }

    // MARK: - 网络请求（含代理支持 + 重试机制 + GBK编码）

    private func fetchHTML(_ urlString: String, referer: String) async -> String? {
        let proxyEnabled = WelfareProxyStore.shared.isProxyEnabled(for: platformName)
        let finalURL: String
        let finalReferer: String

        if proxyEnabled {
            guard let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            finalURL = WelfareProxyStore.shared.proxyURL + encoded
            finalReferer = WelfareProxyStore.shared.proxyURL
            print("[Heiliao] 使用代理请求: \(urlString.prefix(60))...")
        } else {
            finalURL = urlString
            finalReferer = referer
        }

        guard let url = URL(string: finalURL) else {
            print("[Heiliao] fetchHTML: URL 无效 - \(finalURL.prefix(80))")
            return nil
        }

        let maxRetries = 2
        var lastError: Error?

        for attempt in 0...maxRetries {
            if attempt > 0 {
                print("[Heiliao] 请求第 \(attempt) 次重试: \(urlString.prefix(50))...")
                try? await Task.sleep(nanoseconds: 300_000_000) // 0.3秒延迟
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
            req.timeoutInterval = 20

            do {
                let (data, resp) = try await session.data(for: req)
                guard let httpResp = resp as? HTTPURLResponse,
                      (200...299).contains(httpResp.statusCode) else {
                    let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    print("[Heiliao] HTTP 状态码异常: \(statusCode)")
                    lastError = NSError(domain: "Heiliao", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(statusCode)"])
                    continue
                }

                // 尝试多种编码解码
                var raw: String?
                // 1. UTF-8
                raw = String(data: data, encoding: .utf8)
                // 2. GBK (GB_18030_2000)
                if raw == nil || raw!.isEmpty {
                    let cfEnc = CFStringEncodings.GB_18030_2000
                    let nsEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEnc.rawValue))
                    raw = String(data: data, encoding: String.Encoding(rawValue: nsEnc))
                }
                // 3. ASCII
                if raw == nil || raw!.isEmpty {
                    raw = String(data: data, encoding: .ascii)
                }
                // 4. ISO Latin 1
                if raw == nil || raw!.isEmpty {
                    raw = String(data: data, encoding: .isoLatin1)
                }

                guard let html = raw, !html.isEmpty else {
                    print("[Heiliao] 页面内容解码失败或为空")
                    continue
                }

                // 空页面检测
                if html.count < 100 {
                    print("[Heiliao] 页面内容过短 (\(html.count) 字节)，可能是空页面")
                    lastError = NSError(domain: "Heiliao", code: -2, userInfo: [NSLocalizedDescriptionKey: "Empty page"])
                    continue
                }

                return html
            } catch {
                lastError = error
                print("[Heiliao] fetchHTML 错误 (尝试\(attempt + 1)/\(maxRetries + 1)): \(error.localizedDescription)")
            }
        }

        if let error = lastError {
            print("[Heiliao] fetchHTML 最终失败: \(error.localizedDescription)")
        }
        return nil
    }

    // MARK: - HTML 解析：分类（4种策略）

    private func parseCategories(from html: String) -> [HeiliaoCategory] {
        var categories: [HeiliaoCategory] = []
        var seen: Set<String> = []

        let skipWords = ["about", "contact", "tags", "tag", "top", "start", "time",
                         "首页", "home", "search", "搜索", "关于", "联系",
                         "register", "login", "注册", "登录", "vip", "会员",
                         "下载", "公告", "帮助", "feedback", "隐私", "协议"]

        let linkPattern = "<a[^>]*href=\"([^\"]+)\"[^>]*>([^<]+)</a>"

        // 策略一：导航栏解析
        let navPatterns = [
            "<nav[^>]*>(.*?)</nav>",
            "<div[^>]*class=\"[^\"]*(?:header|top-bar|nav-wrap|menu-wrap|navbar)[^\"]*\"[^>]*>(.*?)</div>",
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
            let matches = allMatches(pattern: linkPattern, in: navHTML)
            for groups in matches {
                guard groups.count >= 3 else { continue }
                let href = groups[1].trimmingCharacters(in: .whitespaces)
                let name = groups[2].trimmingCharacters(in: .whitespacesAndNewlines)
                if let cat = makeCategory(href: href, name: name, skipWords: skipWords, seen: &seen) {
                    categories.append(cat)
                }
            }
        }

        // 策略二：侧边栏解析
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
                    let matches = allMatches(pattern: linkPattern, in: sidebarHTML)
                    for sm in matches {
                        guard sm.count >= 3 else { continue }
                        let href = sm[1].trimmingCharacters(in: .whitespaces)
                        let name = sm[2].trimmingCharacters(in: .whitespacesAndNewlines)
                        if let cat = makeCategory(href: href, name: name, skipWords: skipWords, seen: &seen) {
                            categories.append(cat)
                        }
                    }
                }
                if categories.count >= 8 { break }
            }
        }

        // 策略三：通用链接匹配（从整页提取看起来像分类的链接）
        if categories.count < 3 {
            print("[Heiliao] 使用通用链接策略解析分类")
            let allLinkMatches = allMatches(pattern: linkPattern, in: html)
            for groups in allLinkMatches {
                guard groups.count >= 3 else { continue }
                let href = groups[1].trimmingCharacters(in: .whitespaces)
                let name = groups[2].trimmingCharacters(in: .whitespacesAndNewlines)

                // 更严格的过滤
                guard name.count >= 2 && name.count <= 6 else { continue }
                guard href.hasPrefix("/") || href.contains(activeBaseURL) else { continue }
                guard !href.contains(".html") && !href.contains(".php") && !href.contains("?") else { continue }

                if let cat = makeCategory(href: href, name: name, skipWords: skipWords, seen: &seen) {
                    categories.append(cat)
                }
            }
        }

        // 策略四：内嵌 JSON 分类
        if categories.count < 3 {
            print("[Heiliao] 尝试从内嵌 JSON 解析分类")
            let jsonPatterns = [
                "\"categories\"\\s*:\\s*\\[(.*?)\\]",
                "\"category\"\\s*:\\s*\\[(.*?)\\]",
                "\"cat_list\"\\s*:\\s*\\[(.*?)\\]",
            ]
            for pat in jsonPatterns {
                guard let groups = firstMatch(pattern: pat, in: html), groups.count >= 2 else { continue }
                let jsonContent = groups[1]
                let itemPattern = "\\{[^{}]*\"(?:id|cid|cat_id)\"\\s*:\\s*\"?([^,\"}]+)\"?[^{}]*\"(?:name|title)\"\\s*:\\s*\"([^\"]+)\"[^{}]*\\}"
                for itemGroups in allMatches(pattern: itemPattern, in: jsonContent) {
                    guard itemGroups.count >= 3 else { continue }
                    let cid = itemGroups[1].trimmingCharacters(in: .whitespaces)
                    let name = itemGroups[2].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !seen.contains(cid) && !name.isEmpty {
                        seen.insert(cid)
                        categories.append(HeiliaoCategory(cid: cid, name: name))
                    }
                }
                if categories.count >= 5 { break }
            }
        }

        print("[Heiliao] 共解析到 \(categories.count) 个分类")
        return categories
    }

    private func makeCategory(href: String, name: String, skipWords: [String], seen: inout Set<String>) -> HeiliaoCategory? {
        guard !href.isEmpty && !name.isEmpty else { return nil }
        guard href != "#" && href != "/" else { return nil }
        guard name.count >= 2 && name.count <= 8 else { return nil }

        // 跳过外部链接
        if href.hasPrefix("http") && !href.contains(activeBaseURL) { return nil }

        let lowerHref = href.lowercased()
        let lowerName = name.lowercased()
        for skip in skipWords {
            if lowerHref.contains(skip) || lowerName.contains(skip) { return nil }
        }

        // 提取分类 ID
        var cid: String
        if href.hasPrefix("http") {
            if let url = URL(string: href) {
                let path = url.path
                let components = path.split(separator: "/").filter { !$0.isEmpty }
                if components.isEmpty { return nil }
                cid = String(components[0])
            } else {
                return nil
            }
        } else {
            let clean = href.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let components = clean.split(separator: "/").filter { !$0.isEmpty }
            guard let first = components.first else { return nil }
            cid = String(first)
        }

        // 跳过 page 等非分类路径
        let invalidCIDs = ["page", "search", "tag", "index", "category", "user", "login", "register", "about", "contact"]
        if invalidCIDs.contains(cid.lowercased()) { return nil }
        if cid.contains(".") { return nil } // 跳过带扩展名的

        guard !seen.contains(cid) else { return nil }
        seen.insert(cid)

        return HeiliaoCategory(cid: cid, name: name)
    }

    // MARK: - 分页解析

    private func parsePageCount(from html: String) -> Int {
        // 查找总页数
        let patterns = [
            "共\\s*(\\d+)\\s*页",
            "totalPages?\\s*[=:]\\s*(\\d+)",
            "page-count[^\"]*\"\\s*>\\s*(\\d+)",
            "/page/(\\d+)/",
            "下一页",
            "next-page",
        ]

        var maxPage = 1
        for pat in patterns {
            if pat.contains("\\d+") {
                let matches = allMatches(pattern: pat, in: html)
                for groups in matches {
                    guard groups.count >= 2, let num = Int(groups[1]) else { continue }
                    if num > maxPage && num < 10000 {
                        maxPage = num
                    }
                }
            } else {
                if html.contains(pat) {
                    return 9999
                }
            }
        }

        return maxPage > 1 ? maxPage : 9999
    }

    // MARK: - HTML 解析：视频列表（5种策略）

    private func parseVideoList(from html: String, base: String) -> [HeiliaoVideo] {
        var videos: [HeiliaoVideo] = []
        var seenIDs: Set<String> = []

        // 策略一：CSS 类名匹配
        let classSelectors = [
            "video-item", "video-list .item", "list-item", "post-item",
            "item-box", "video-card", "post-card", "article-item",
            "content-item", "entry-item",
        ]

        for sel in classSelectors {
            let cleanedSel = sel.replacingOccurrences(of: ".", with: "\\.")
            let pattern = "<[^>]*class=\"[^\"]*\(cleanedSel)[^\"]*\"[^>]*>(.*?)(?:</div>\\s*</div>|</li>|</article>|</div>)"
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

            if videos.count >= 5 {
                print("[Heiliao] 策略一(CSS类名)匹配到 \(videos.count) 条视频")
                return videos
            }
        }

        // 策略二：li 列表匹配
        if videos.isEmpty {
            let liPattern = "<li[^>]*>(.*?)</li>"
            let matches = allMatches(pattern: liPattern, in: html)
            var count = 0
            for groups in matches {
                guard groups.count >= 2 else { continue }
                let itemHTML = groups[1]
                guard itemHTML.contains("<img") || itemHTML.contains("img src") else { continue }
                guard !isAdvertisement(itemHTML) else { continue }
                guard let vod = parseVideoItem(itemHTML, base: base) else { continue }
                if seenIDs.contains(vod.vodId) { continue }
                seenIDs.insert(vod.vodId)
                videos.append(vod)
                count += 1
            }
            if count >= 3 {
                print("[Heiliao] 策略二(li列表)匹配到 \(count) 条视频")
                return videos
            }
            videos.removeAll()
            seenIDs.removeAll()
        }

        // 策略三：div 块匹配（包含图片和标题的 div）
        if videos.isEmpty {
            let divPattern = "<div[^>]*>([\\s\\S]*?<img[\\s\\S]*?</div>)"
            let matches = allMatches(pattern: divPattern, in: html)
            var count = 0
            for groups in matches {
                guard groups.count >= 2 else { continue }
                let itemHTML = groups[1]
                guard itemHTML.contains("<a") && itemHTML.contains("<img") else { continue }
                guard !isAdvertisement(itemHTML) else { continue }
                guard let vod = parseVideoItem(itemHTML, base: base) else { continue }
                guard !vod.title.isEmpty && !vod.cover.isEmpty else { continue }
                if seenIDs.contains(vod.vodId) { continue }
                seenIDs.insert(vod.vodId)
                videos.append(vod)
                count += 1
            }
            if count >= 3 {
                print("[Heiliao] 策略三(div块)匹配到 \(count) 条视频")
                return videos
            }
            videos.removeAll()
            seenIDs.removeAll()
        }

        // 策略四：内嵌 JSON 视频列表
        if videos.isEmpty {
            let jsonPatterns = [
                "\"video_list\"\\s*:\\s*\\[(.*?)\\]",
                "\"videos\"\\s*:\\s*\\[(.*?)\\]",
                "\"list\"\\s*:\\s*\\[(.*?)\\]",
                "\"data\"\\s*:\\s*\\[(.*?)\\]",
            ]
            for pat in jsonPatterns {
                guard let groups = firstMatch(pattern: pat, in: html), groups.count >= 2 else { continue }
                let jsonContent = groups[1]
                let itemPattern = "\\{[^{}]*\"(?:id|vod_id|vid)\"\\s*:\\s*\"?([^,\"}]+)\"?[^{}]*\"(?:title|name)\"\\s*:\\s*\"([^\"]+)\"[^{}]*\"(?:cover|img|pic|image|thumb)\"\\s*:\\s*\"([^\"]+)\"[^{}]*\\}"
                for itemGroups in allMatches(pattern: itemPattern, in: jsonContent) {
                    guard itemGroups.count >= 4 else { continue }
                    let vodId = itemGroups[1]
                    let title = decodeHTMLEntities(itemGroups[2])
                    let cover = decodeHTMLEntities(itemGroups[3])
                    guard !title.isEmpty && !cover.isEmpty else { continue }
                    if seenIDs.contains(vodId) { continue }
                    seenIDs.insert(vodId)
                    let pageUrl = "\(base)/\(vodId)/"
                    let needsDec = needsDecrypt(cover)
                    let normalizedCover = normalizeImageURL(cover, base: base)
                    videos.append(HeiliaoVideo(vodId: vodId, title: title, cover: normalizedCover, pageUrl: pageUrl, remarks: "", needsDecrypt: needsDec))
                }
                if videos.count >= 3 {
                    print("[Heiliao] 策略四(内嵌JSON)匹配到 \(videos.count) 条视频")
                    return videos
                }
            }
            videos.removeAll()
            seenIDs.removeAll()
        }

        // 策略五：通用链接+图片模式
        if videos.isEmpty {
            print("[Heiliao] 使用策略五(通用链接+图片)")
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
            print("[Heiliao] 策略五匹配到 \(videos.count) 条视频")
        }

        // 解析失败时输出调试信息
        if videos.isEmpty {
            print("[Heiliao] ===== 视频列表解析失败调试信息 =====")
            print("[Heiliao] HTML 长度: \(html.count)")
            // 输出页面前 500 字符用于调试
            let preview = String(html.prefix(500))
            print("[Heiliao] 页面预览: \(preview)")
            print("[Heiliao] 包含 img 标签: \(html.contains("<img"))")
            print("[Heiliao] 包含 a 标签: \(html.contains("<a"))")
            print("[Heiliao] 包含 video: \(html.contains("video"))")
            print("[Heiliao] 包含 li: \(html.contains("<li"))")
            print("[Heiliao] ====================================")
        }

        return videos
    }

    private func parseVideoItem(_ item: String, base: String) -> HeiliaoVideo? {
        // 标题提取（多种模式）
        let titleSelectors = [
            "class=\"[^\"]*title[^\"]*\"",
            "h3", "h4", "h2",
            "class=\"[^\"]*video-title[^\"]*\"",
            "class=\"[^\"]*post-title[^\"]*\"",
            "class=\"[^\"]*entry-title[^\"]*\"",
        ]
        var title = ""
        for sel in titleSelectors {
            if let groups = firstMatch(pattern: "<[^>]*\(sel)[^>]*>(.*?)</[^>]+>", in: item), groups.count >= 2 {
                var t = groups[1]
                t = t.replacingOccurrences(of: "<[^>]+>", with: "")
                t = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && t.count >= 2 {
                    title = t
                    break
                }
            }
        }

        // 如果标题为空，尝试从 a 标签 title 属性或 img alt 属性获取
        if title.isEmpty {
            if let groups = firstMatch(pattern: "title=\"([^\"]+)\"", in: item), groups.count >= 2 {
                title = groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let groups = firstMatch(pattern: "alt=\"([^\"]+)\"", in: item), groups.count >= 2 {
                title = groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard !title.isEmpty && title.count >= 2 else { return nil }

        // 链接提取
        guard let linkGroups = firstMatch(pattern: "<a[^>]*href=\"([^\"]+)\"[^>]*>", in: item),
              linkGroups.count >= 2 else { return nil }
        let href = linkGroups[1]
        guard !href.isEmpty else { return nil }

        let pageUrl: String
        if href.hasPrefix("http") {
            pageUrl = href
        } else if href.hasPrefix("/") {
            pageUrl = "\(base)\(href)"
        } else {
            pageUrl = "\(base)/\(href)"
        }

        let vodId = href.hasPrefix("http") ? href : (href.hasPrefix("/") ? href : "/\(href)")

        // 封面图提取（增强）
        let (cover, needsDec) = extractCoverWithDecrypt(from: item, base: base)

        // 备注提取
        var remarks = ""
        let remarkSelectors = [
            "class=\"[^\"]*date[^\"]*\"",
            "class=\"[^\"]*time[^\"]*\"",
            "class=\"[^\"]*remarks[^\"]*\"",
            "class=\"[^\"]*duration[^\"]*\"",
            "class=\"[^\"]*meta[^\"]*\"",
            "class=\"[^\"]*info[^\"]*\"",
        ]
        for sel in remarkSelectors {
            if let groups = firstMatch(pattern: "<[^>]*\(sel)[^>]*>(.*?)<", in: item), groups.count >= 2 {
                var r = groups[1]
                r = r.replacingOccurrences(of: "<[^>]+>", with: "")
                r = r.trimmingCharacters(in: .whitespacesAndNewlines)
                if !r.isEmpty {
                    remarks = r
                    break
                }
            }
        }

        return HeiliaoVideo(vodId: vodId, title: title, cover: cover, pageUrl: pageUrl, remarks: remarks, needsDecrypt: needsDec)
    }

    // MARK: - 封面图提取（增强版）

    private func extractCoverWithDecrypt(from html: String, base: String) -> (String, Bool) {
        var candidates: [(url: String, fromDecrypt: Bool)] = []

        // 1. onload 解密图片（优先级最高）
        if let onloadGroups = firstMatch(pattern: "onload=\"[^\"]*(?:loadShareImg|loadImg|loadImage|decryptImg)\\s*\\([^,]+,\\s*'([^']+)'\\)", in: html),
           onloadGroups.count >= 2 {
            candidates.append((onloadGroups[1], true))
        }

        // 2. data-src / data-original 等懒加载属性
        let lazyAttrs = ["data-src", "data-original", "data-lazy-src", "data-cover", "data-url", "data-image"]
        for attr in lazyAttrs {
            if let imgGroups = firstMatch(pattern: "<img[^>]*\(attr)=\"([^\"]+)\"[^>]*>", in: html),
               imgGroups.count >= 2 {
                candidates.append((imgGroups[1], false))
            }
        }

        // 3. srcset
        if let srcsetGroups = firstMatch(pattern: "<img[^>]*srcset=\"([^\"]+)\"[^>]*>", in: html),
           srcsetGroups.count >= 2 {
            if let firstURL = srcsetGroups[1].components(separatedBy: ",").first?
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: " ")
                .first?
                .trimmingCharacters(in: .whitespaces),
               !firstURL.isEmpty {
                candidates.append((firstURL, false))
            }
        }

        // 4. background-image
        if let bgGroups = firstMatch(pattern: "background-image:\\s*url\\([\"']?([^\"')]+)[\"']?\\)", in: html),
           bgGroups.count >= 2 {
            candidates.append((bgGroups[1], false))
        }

        // 5. 普通 img src
        if let imgGroups = firstMatch(pattern: "<img[^>]*src=\"([^\"]+)\"[^>]*>", in: html),
           imgGroups.count >= 2 {
            candidates.append((imgGroups[1], false))
        }

        // 6. noscript 备用图
        if let noscriptGroups = firstMatch(pattern: "<noscript>[\\s\\S]*?<img[^>]*src=\"([^\"]+)\"[^>]*>[\\s\\S]*?</noscript>", in: html),
           noscriptGroups.count >= 2 {
            candidates.append((noscriptGroups[1], false))
        }

        // 选择第一个有效的非 data: URL
        for candidate in candidates {
            let url = candidate.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty && !url.hasPrefix("data:") else { continue }
            let normalized = normalizeImageURL(url, base: base)
            let needsDec = candidate.fromDecrypt || needsDecrypt(url)
            return (normalized, needsDec)
        }

        return ("", false)
    }

    private func normalizeImageURL(_ url: String, base: String) -> String {
        var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // HTML 实体解码
        trimmed = decodeHTMLEntities(trimmed)

        // 转义斜杠处理
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
            "广告位", "赞助商", "推荐", "点击进入", "立即查看",
            "telegram", "Telegram", "电报群",
            "DNS设置", "修改DNS", "WIFI设置", "手机链接",
            "adsbygoogle", "google_ad", "googlesyndication",
            "position: relative; width: 100%; height", // 常见广告容器
        ]
        let lower = html.lowercased()
        for keyword in adKeywords {
            if lower.contains(keyword.lowercased()) { return true }
        }
        return false
    }

    // MARK: - 播放地址提取（6种策略 + iframe支持）

    private func extractPlayURL(from html: String) -> String? {
        // 策略1: DPlayer config / data-config
        let dplayerPatterns = [
            "<div[^>]*class=\"[^\"]*dplayer[^\"]*\"[^>]*data-config=\"([^\"]+)\"[^>]*>",
            "<div[^>]*class=\"[^\"]*dplayer[^\"]*\"[^>]*config=\"([^\"]+)\"[^>]*>",
        ]
        for pat in dplayerPatterns {
            if let groups = firstMatch(pattern: pat, in: html), groups.count >= 2 {
                let configStr = decodeHTMLEntities(groups[1])
                if let url = extractURLFromJSONContent(configStr) {
                    print("[Heiliao] 策略1(DPlayer)提取到播放地址")
                    return url
                }
            }
        }

        // 策略2: 内嵌 JSON 配置
        let jsonConfigPatterns = [
            "var\\s+video\\s*=\\s*(\\{[\\s\\S]{0,2000}?\\})",
            "playerConfig\\s*=\\s*(\\{[\\s\\S]{0,2000}?\\})",
            "player_data\\s*=\\s*(\\{[\\s\\S]{0,2000}?\\})",
            "\"video\"\\s*:\\s*(\\{[\\s\\S]{0,2000}?\\})",
            "window\\.playerData\\s*=\\s*(\\{[\\s\\S]{0,2000}?\\})",
            "window\\.videoConfig\\s*=\\s*(\\{[\\s\\S]{0,2000}?\\})",
        ]
        for pat in jsonConfigPatterns {
            if let groups = firstMatch(pattern: pat, in: html), groups.count >= 2 {
                let jsonStr = groups[1]
                if let url = extractURLFromJSONContent(jsonStr) {
                    print("[Heiliao] 策略2(内嵌JSON)提取到播放地址")
                    return url
                }
            }
        }

        // 策略3: 直接 m3u8/mp4 URL 模式
        let directPatterns = [
            "https://hls\\.[^\"'\\s<>]+\\.m3u8[^\"'\\s<>]*",
            "https://[^\"'\\s<>]+\\.m3u8\\?auth_key=[^\"'\\s<>]+",
            "https?://[^\"'\\s<>]+\\.m3u8[^\"'\\s<>]*",
            "https?://[^\"'\\s<>]+\\.mp4[^\"'\\s<>]*",
        ]
        for pat in directPatterns {
            if let groups = firstMatch(pattern: pat, in: html), groups.count >= 1 {
                var url = groups[0].replacingOccurrences(of: "\\/", with: "/")
                url = decodeHTMLEntities(url)
                if !url.isEmpty {
                    print("[Heiliao] 策略3(直接URL)提取到播放地址")
                    return url
                }
            }
        }

        // 策略4: video / source 标签
        let tagPatterns = [
            "<video[^>]*src=\"([^\"]+)\"[^>]*>",
            "<video[^>]*data-src=\"([^\"]+)\"[^>]*>",
            "<source[^>]*src=\"([^\"]+)\"[^>]*>",
        ]
        for pat in tagPatterns {
            if let groups = firstMatch(pattern: pat, in: html), groups.count >= 2 {
                var url = groups[1].replacingOccurrences(of: "\\/", with: "/")
                url = decodeHTMLEntities(url)
                if !url.isEmpty {
                    print("[Heiliao] 策略4(video/source标签)提取到播放地址")
                    return url
                }
            }
        }

        // 策略5: JS 变量赋值
        let jsVarPatterns = [
            "video_url\\s*[=:]\\s*[\"']([^\"']+)[\"']",
            "videoUrl\\s*[=:]\\s*[\"']([^\"']+)[\"']",
            "play_url\\s*[=:]\\s*[\"']([^\"']+)[\"']",
            "playUrl\\s*[=:]\\s*[\"']([^\"']+)[\"']",
            "m3u8_url\\s*[=:]\\s*[\"']([^\"']+)[\"']",
            "mp4_url\\s*[=:]\\s*[\"']([^\"']+)[\"']",
            "src\\s*[=:]\\s*[\"']([^\"']+\\.(?:m3u8|mp4)[^\"']*)[\"']",
            "url\\s*[=:]\\s*[\"']([^\"']+\\.(?:m3u8|mp4)[^\"']*)[\"']",
        ]
        for pat in jsVarPatterns {
            if let groups = firstMatch(pattern: pat, in: html), groups.count >= 2 {
                var url = groups[1].replacingOccurrences(of: "\\/", with: "/")
                url = decodeHTMLEntities(url)
                if !url.isEmpty && (url.contains(".m3u8") || url.contains(".mp4")) {
                    print("[Heiliao] 策略5(JS变量)提取到播放地址")
                    return url
                }
            }
        }

        // 策略6: CKPlayer / 其他播放器配置
        let otherPlayerPatterns = [
            "ckplayer\\s*[=:(][\\s\\S]{0,500}?[\"']video[\"']\\s*[=:]\\s*[\"']([^\"']+)[\"']",
            "ckplayer\\s*[=:(][\\s\\S]{0,500}?[\"']url[\"']\\s*[=:]\\s*[\"']([^\"']+)[\"']",
            "new\\s+[A-Z]\\w*Player[\\s\\S]{0,500}?[\"'](https?://[^\"']+\\.(?:m3u8|mp4)[^\"']*)[\"']",
        ]
        for pat in otherPlayerPatterns {
            if let groups = firstMatch(pattern: pat, in: html), groups.count >= 2 {
                var url = groups[1].replacingOccurrences(of: "\\/", with: "/")
                url = decodeHTMLEntities(url)
                if !url.isEmpty {
                    print("[Heiliao] 策略6(其他播放器)提取到播放地址")
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

        // 跳过广告/统计 iframe
        let skipPatterns = ["google", "facebook", "baidu", "cnzz", "51.la", "tongji",
                            "ads", "advert", "googletag", "doubleclick", "analytics"]
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
