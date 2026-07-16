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

    private let defaultDomains = ["https://heiliao.com", "https://heiliao.app", "https://51hl.online", "https://hl.dspqyb.com"]

    private var activeBaseURL: String {
        let customs = WelfareDomainStore.shared.domains(for: "黑料不打烊")
        if let first = customs.first { return first }
        return defaultDomains.first ?? "https://heiliao.com"
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

        guard result == kCCSuccess else { return nil }
        return outData.prefix(numBytesDecrypted)
    }

    func fetchDecryptedImageData(for urlString: String) async -> Data? {
        let cacheKey = urlString as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached as Data
        }

        let fullURL = normalizeImageURL(urlString, base: activeBaseURL)
        guard let url = URL(string: fullURL) else { return nil }

        var req = URLRequest(url: url)
        req.setValue(activeBaseURL + "/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 15

        do {
            let (data, resp) = try await session.data(for: req)
            guard let httpResp = resp as? HTTPURLResponse,
                  httpResp.statusCode == 200 else { return nil }

            if needsDecrypt(urlString) {
                if let decrypted = aesDecrypt(data) {
                    imageCache.setObject(decrypted as NSData, forKey: cacheKey)
                    return decrypted
                }
                return nil
            }
            imageCache.setObject(data as NSData, forKey: cacheKey)
            return data
        } catch {
            return nil
        }
    }

    func needsDecrypt(_ urlString: String) -> Bool {
        guard !urlString.isEmpty else { return false }
        let lower = urlString.lowercased()
        for domain in decryptDomains where lower.contains(domain) { return true }
        for path in decryptPaths where lower.contains(path) { return true }
        return false
    }

    // MARK: - 自适应分类获取

    func fetchCategories() async -> [HeiliaoCategory] {
        if let cached = cachedCategories { return cached }

        // 尝试多个默认域名
        let bases = WelfareDomainStore.shared.domains(for: "黑料不打烊").isEmpty ? defaultDomains : [activeBaseURL]
        for base in bases {
            guard let html = await fetchHTML(base, referer: base + "/") else { continue }
            let parsed = parseCategories(from: html)
            if !parsed.isEmpty {
                if WelfareDomainStore.shared.domains(for: "黑料不打烊").isEmpty {
                    WelfareDomainStore.shared.setDomains([base], for: "黑料不打烊")
                }
                cachedCategories = parsed
                return parsed
            }
        }

        return fallbackCategories
    }

    func resetDomain() {
        cachedCategories = nil
        imageCache.removeAllObjects()
        WelfareDomainStore.shared.clearDomains(for: "黑料不打烊")
    }

    func reprobe() {
        cachedCategories = nil
        imageCache.removeAllObjects()
    }

    // MARK: - 分类视频列表

    func fetchVideos(cid: String, page: Int) async -> (videos: [HeiliaoVideo], pageCount: Int) {
        let base = activeBaseURL
        let url: String
        if page == 1 {
            url = "\(base)/\(cid)/"
        } else {
            url = "\(base)/\(cid)/page/\(page)/"
        }

        guard let html = await fetchHTML(url, referer: base + "/") else {
            return ([], 1)
        }

        let videos = parseVideoList(from: html, base: base)
        print("[Heiliao] 分类 cid=\(cid) page=\(page): \(videos.count)条")
        return (videos, 9999)
    }

    // MARK: - 视频详情（获取播放地址）

    func fetchPlayURL(pageUrl: String) async -> String? {
        let base = activeBaseURL
        let url = pageUrl.hasPrefix("http") ? pageUrl : "\(base)\(pageUrl)"
        guard let html = await fetchHTML(url, referer: base + "/") else { return nil }

        if let playURL = extractPlayURL(from: html) {
            print("[Heiliao] 播放地址: \(playURL.prefix(100))...")
            return playURL
        }
        return url
    }

    // MARK: - 搜索

    func search(keyword: String, page: Int) async -> [HeiliaoVideo] {
        let base = activeBaseURL
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "\(base)/index/search?word=\(encoded)"
        guard let html = await fetchHTML(url, referer: base + "/") else { return [] }
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
            print("[Heiliao] fetchHTML error: \(error)")
            return nil
        }
    }

    // MARK: - HTML 解析：分类（自适应）

    private func parseCategories(from html: String) -> [HeiliaoCategory] {
        var categories: [HeiliaoCategory] = []

        let navPattern = "<nav[^>]*>(.*?)</nav>"
        var navHTML: String
        if let groups = firstMatch(pattern: navPattern, in: html), groups.count >= 2 {
            navHTML = groups[1]
        } else {
            navHTML = html
        }

        let linkPattern = "<a[^>]*href=\"([^\"]+)\"[^>]*>([^<]+)</a>"
        let matches = allMatches(pattern: linkPattern, in: navHTML)
        var seen: Set<String> = []

        for groups in matches {
            guard groups.count >= 3 else { continue }
            let href = groups[1]
            let name = groups[2].trimmingCharacters(in: .whitespaces)
            if href == "#" || href == "/" || href.hasPrefix("http") { continue }
            if name.isEmpty || name.count > 10 { continue }

            let cid = href.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .components(separatedBy: "/").first ?? ""
            if cid.isEmpty || cid.contains("page") { continue }

            let trimmedCID = href.hasPrefix("/") ? href : "/\(href)"
            if !seen.contains(cid) {
                seen.insert(cid)
                categories.append(HeiliaoCategory(cid: cid, name: name))
            }
        }

        return categories
    }

    // MARK: - HTML 解析：视频列表

    private let videoSelectors = [
        ".video-item", ".video-list .item", ".list-item", ".post-item"
    ]

    private func parseVideoList(from html: String, base: String) -> [HeiliaoVideo] {
        var videos: [HeiliaoVideo] = []

        for sel in videoSelectors {
            let cleanedSel = sel.replacingOccurrences(of: ".", with: "\\.")
            let pattern = "<[^>]*class=\"[^\"]*\(cleanedSel)[^\"]*\"[^>]*>(.*?)(?:</div>\\s*</div>|</li>|</article>)"
            let matches = allMatches(pattern: pattern, in: html)

            for groups in matches {
                guard groups.count >= 2 else { continue }
                if let vod = parseVideoItem(groups[1], base: base) {
                    videos.append(vod)
                }
            }

            if !videos.isEmpty { break }
        }

        return videos
    }

    private func parseVideoItem(_ item: String, base: String) -> HeiliaoVideo? {
        let titleSelectors = ["class=\"[^\"]*title[^\"]*\"", "h3", "h4", "class=\"[^\"]*video-title[^\"]*\""]
        var title = ""
        for sel in titleSelectors {
            if let groups = firstMatch(pattern: "<[^>]*\(sel)[^>]*>([^<]+)</[^>]+>", in: item), groups.count >= 2 {
                title = groups[1].trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard !title.isEmpty else { return nil }

        guard let linkGroups = firstMatch(pattern: "<a[^>]*href=\"([^\"]+)\"[^>]*>", in: item),
              linkGroups.count >= 2 else { return nil }
        let href = linkGroups[1]

        let pageUrl: String
        if href.hasPrefix("http") {
            pageUrl = href
        } else if href.hasPrefix("/") {
            pageUrl = "\(base)\(href)"
        } else {
            pageUrl = "\(base)/\(href)"
        }

        let vodId = href.hasPrefix("http") ? href : (href.hasPrefix("/") ? href : "/\(href)")

        let (cover, needsDec) = extractCoverWithDecrypt(from: item, base: base)

        var remarks = ""
        let remarkSelectors = ["class=\"[^\"]*date[^\"]*\"", "class=\"[^\"]*time[^\"]*\"", "class=\"[^\"]*remarks[^\"]*\"", "class=\"[^\"]*duration[^\"]*\""]
        for sel in remarkSelectors {
            if let groups = firstMatch(pattern: "<[^>]*\(sel)[^>]*>([^<]+)<", in: item), groups.count >= 2 {
                remarks = groups[1].trimmingCharacters(in: .whitespaces)
                break
            }
        }

        return HeiliaoVideo(vodId: vodId, title: title, cover: cover, pageUrl: pageUrl, remarks: remarks, needsDecrypt: needsDec)
    }

    private func extractCoverWithDecrypt(from html: String, base: String) -> (String, Bool) {
        var onloadURL = ""
        if let onloadGroups = firstMatch(pattern: "onload=\"[^\"]*(?:loadShareImg|loadImg)\\s*\\([^,]+,\\s*'([^']+)'\\)", in: html),
           onloadGroups.count >= 2 {
            onloadURL = onloadGroups[1]
        }

        var rawURL = ""
        if let imgGroups = firstMatch(pattern: "<img[^>]*src=\"([^\"]+)\"[^>]*>", in: html),
           imgGroups.count >= 2 {
            rawURL = imgGroups[1]
        } else if let imgGroups = firstMatch(pattern: "<img[^>]*data-src=\"([^\"]+)\"[^>]*>", in: html),
                  imgGroups.count >= 2 {
            rawURL = imgGroups[1]
        }

        let finalURL = onloadURL.isEmpty ? rawURL : onloadURL
        let normalized = normalizeImageURL(finalURL, base: base)
        let needsDec = !onloadURL.isEmpty || needsDecrypt(finalURL)
        return (normalized, needsDec)
    }

    private func normalizeImageURL(_ url: String, base: String) -> String {
        if url.hasPrefix("http") { return url }
        if url.hasPrefix("//") { return "https:\(url)" }
        if url.hasPrefix("/") { return "\(base)\(url)" }
        return "\(base)/\(url)"
    }

    // MARK: - 播放地址提取

    private func extractPlayURL(from html: String) -> String? {
        let dplayerPattern = "<div[^>]*class=\"[^\"]*dplayer[^\"]*\"[^>]*config=\"([^\"]+)\"[^>]*>"
        if let groups = firstMatch(pattern: dplayerPattern, in: html), groups.count >= 2 {
            let raw = groups[1]
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#34;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&#38;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&#60;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&#62;", with: ">")
            if let urlGroups = firstMatch(pattern: "\"url\"\\s*:\\s*\"([^\"]+)\"", in: raw),
               urlGroups.count >= 2 {
                let url = urlGroups[1].replacingOccurrences(of: "\\/", with: "/")
                return normalizeImageURL(url, base: activeBaseURL)
            }
        }

        let m3u8Patterns = [
            "https://hls\\.[^\"'\\s]+\\.m3u8[^\"'\\s]*",
            "https://[^\"'\\s]+\\.m3u8\\?auth_key=[^\"'\\s]+",
        ]
        for pat in m3u8Patterns {
            if let groups = firstMatch(pattern: pat, in: html), groups.count >= 1 {
                return groups[0]
            }
        }

        let jsPatterns = [
            "video[\\s\\S]{0,500}?url[\\s\"'`:=]+([^\"'`\\s]+\\.m3u8[^\"'`\\s]*)",
            "videoUrl[\\s\"'`:=]+([^\"'`\\s]+\\.m3u8[^\"'`\\s]*)",
            "src[\\s\"'`:=]+([^\"'`\\s]+\\.m3u8[^\"'`\\s]*)",
        ]
        for pat in jsPatterns {
            if let groups = firstMatch(pattern: pat, in: html), groups.count >= 2 {
                var url = groups[1]
                if url.hasPrefix("//") { url = "https:\(url)" }
                else if url.hasPrefix("/") { url = "\(activeBaseURL)\(url)" }
                else if !url.hasPrefix("http") { url = "https://\(url)" }
                return url
            }
        }

        return nil
    }
}
