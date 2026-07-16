import Foundation
import Kanna
import CommonCrypto

// MARK: - 吸瓜平台网络服务
// 基于 Python 蜘蛛脚本 (51吸瓜动态版.py) 的 Swift 原生实现
// 使用 Kanna 进行 HTML 解析 (已在 Podfile 中)，CommonCrypto 进行 AES 解密
// 域名通过 WelfareDomainStore 管理（与其他福利平台统一）
class XiguaService: ObservableObject {
    static let shared = XiguaService()

    // MARK: - 域名 (通过 WelfareDomainStore 管理)
    private let defaultHosts = [
        "https://advise.nlwkmsv.cc",
    ]
    private let platformName = "通用吸瓜"

    @Published var currentHost: String = ""
    @Published var isHostReady: Bool = false

    // MARK: - HTTP 配置
    private let defaultHeaders: [String: String] = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Connection": "keep-alive",
        "Cache-Control": "no-cache",
    ]

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    // MARK: - AES 解密常量 (与 Python 脚本一致)
    private let aesKey: [UInt8] = Array("f5d965df75336270".utf8)
    private let aesIV:  [UInt8] = Array("97b60394abc2fbe1".utf8)

    // MARK: - 域名管理方法

    /// 获取当前平台所有可用域名（自定义域名在前，默认域名在后）
    private var allHosts: [String] {
        let customs = WelfareDomainStore.shared.domains(for: platformName)
        return customs + defaultHosts
    }

    /// 重新探测域名（添加/删除域名后调用）
    func reprobe() {
        currentHost = ""
        isHostReady = false
        Task { _ = await probeHost() }
    }

    /// 清除所有自定义域名并重新探测
    func resetDomain() {
        WelfareDomainStore.shared.clearDomains(for: platformName)
        currentHost = ""
        isHostReady = false
        Task { _ = await probeHost() }
    }

    // MARK: - 站点探测
    /// 探测可用站点，从用户配置的域名列表依次尝试
    @discardableResult
    func probeHost() async -> String? {
        let hosts = allHosts

        for host in hosts {
            guard let url = URL(string: host) else { continue }
            var req = URLRequest(url: url)
            defaultHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            req.setValue(host, forHTTPHeaderField: "Origin")
            req.setValue("\(host)/", forHTTPHeaderField: "Referer")

            do {
                let (data, resp) = try await session.data(for: req)
                guard let httpResp = resp as? HTTPURLResponse,
                      httpResp.statusCode == 200,
                      let html = String(data: data, encoding: .utf8) else { continue }

                if let doc = try? HTML(html: html, encoding: .utf8) {
                    if doc.css("#index article a").first != nil {
                        await MainActor.run {
                            self.currentHost = host
                            self.isHostReady = true
                        }
                        print("[Xigua] 选用可用站点: \(host)")
                        return host
                    }
                }
            } catch {
                print("[Xigua] 站点探测失败 \(host): \(error.localizedDescription)")
                continue
            }
        }

        // 回退到第一个域名
        let fallback = hosts.first ?? "https://advise.nlwkmsv.cc"
        await MainActor.run {
            self.currentHost = fallback
            self.isHostReady = true
        }
        print("[Xigua] 未检测到可用站点，回退: \(fallback)")
        return fallback
    }

    // MARK: - 通用 HTTP GET
    private func fetchHTML(_ path: String) async throws -> String {
        let urlStr = path.hasPrefix("http") ? path : "\(currentHost)\(path)"
        guard let url = URL(string: urlStr) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        defaultHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue(currentHost, forHTTPHeaderField: "Origin")
        req.setValue("\(currentHost)/", forHTTPHeaderField: "Referer")

        let (data, resp) = try await session.data(for: req)
        guard let httpResp = resp as? HTTPURLResponse,
              (200...299).contains(httpResp.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        return html
    }

    // MARK: - 首页内容
    func fetchHomeContent() async -> XiguaHomeResult {
        do {
            let html = try await fetchHTML("/")
            let doc = try HTML(html: html, encoding: .utf8)
            let categories = parseCategories(doc)
            let videos = parseVideoList(doc, containerSelector: "#index article a")
            return XiguaHomeResult(categories: categories, videos: videos)
        } catch {
            print("[Xigua] fetchHomeContent error: \(error)")
            return XiguaHomeResult(categories: [], videos: [])
        }
    }

    // MARK: - 分类内容
    func fetchCategoryContent(tid: String, page: Int = 1) async -> XiguaCategoryResult {
        do {
            let path: String
            if tid.hasPrefix("/") {
                path = page > 1 ? "\(tid)page/\(page)/" : tid
            } else {
                path = "/\(tid)"
            }
            let html = try await fetchHTML(path)
            let doc = try HTML(html: html, encoding: .utf8)
            let videos = parseVideoList(doc, containerSelector: "#archive article a, #index article a")
            return XiguaCategoryResult(videos: videos, page: page, pagecount: 99999, total: 999999)
        } catch {
            print("[Xigua] fetchCategoryContent error: \(error)")
            return XiguaCategoryResult(videos: [], page: page, pagecount: 1, total: 0)
        }
    }

    // MARK: - 视频详情
    func fetchDetail(vodId: String) async -> XiguaDetail {
        do {
            let urlStr = vodId.hasPrefix("http") ? vodId : "\(currentHost)\(vodId)"
            let html = try await fetchHTML(urlStr)
            let doc = try HTML(html: html, encoding: .utf8)
            let vodContent = extractDescription(doc)
            let episodes = extractEpisodes(doc, html: html)
            return XiguaDetail(vodId: vodId, vodContent: vodContent, playFrom: "通用吸瓜", playEpisodes: episodes)
        } catch {
            print("[Xigua] fetchDetail error: \(error)")
            return XiguaDetail(vodId: vodId, vodContent: "页面加载失败", playFrom: "通用吸瓜", playEpisodes: [XiguaEpisode(name: "加载失败", url: vodId)])
        }
    }

    // MARK: - 搜索
    func fetchSearch(keyword: String, page: Int = 1) async -> XiguaSearchResult {
        do {
            let path = page > 1 ? "/search/\(keyword)/\(page)" : "/search/\(keyword)/"
            let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            let html = try await fetchHTML(encodedPath)
            let doc = try HTML(html: html, encoding: .utf8)
            let videos = parseVideoList(doc, containerSelector: "#archive article a, #index article a")
            return XiguaSearchResult(videos: videos, page: page)
        } catch {
            print("[Xigua] fetchSearch error: \(error)")
            return XiguaSearchResult(videos: [], page: page)
        }
    }

    // MARK: - 播放地址
    func fetchPlayerURL(flag: String, videoUrl: String) -> XiguaPlayerResult {
        var url = videoUrl
        var parse = 1
        if isDirectPlayable(url) { parse = 0 }
        print("[Xigua] 播放请求: parse=\(parse), url=\(url)")
        return XiguaPlayerResult(parse: parse, url: url, headers: defaultHeaders)
    }

    // MARK: - URL 规范化 (处理 // 前缀、相对路径等)

    /// 规范化 URL：确保有 http/https 前缀，处理 // 前缀和相对路径
    private func normalizeURL(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return "" }
        // 已经是完整 URL
        if u.hasPrefix("http://") || u.hasPrefix("https://") {
            return u
        }
        // 协议相对 URL (//example.com/xxx)
        if u.hasPrefix("//") {
            return "https:" + u
        }
        // 相对路径 (/xxx/xxx.jpg)
        if u.hasPrefix("/") {
            return currentHost + u
        }
        // 其他情况，默认加上 https://
        if !u.contains("://") {
            return "https://" + u
        }
        return u
    }

    // MARK: - 图片解密 (AES-CBC)
    func decryptImage(_ encryptedData: Data) -> Data? {
        guard encryptedData.count > 0 else { return nil }
        let keyData = Data(aesKey)
        let ivData = Data(aesIV)
        let encryptedCount = encryptedData.count
        let bufferSize = encryptedCount + kCCBlockSizeAES128
        var decryptedData = Data(count: bufferSize)
        var decryptedLength = 0
        let status = decryptedData.withUnsafeMutableBytes { decryptedBytes in
            encryptedData.withUnsafeBytes { encryptedBytes in
                ivData.withUnsafeBytes { ivBytes in
                    keyData.withUnsafeBytes { keyBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress!, kCCKeySizeAES128, ivBytes.baseAddress!,
                            encryptedBytes.baseAddress!, encryptedCount,
                            decryptedBytes.baseAddress!, bufferSize,
                            &decryptedLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            print("[Xigua] AES 解密失败，状态码: \(status)")
            return nil
        }
        return decryptedData.prefix(decryptedLength)
    }

    // MARK: - Private: HTML 解析

    private func parseCategories(_ doc: HTMLDocument) -> [XiguaCategory] {
        let selectors = [".category-list ul li", ".nav-menu li", ".menu li", "nav ul li"]
        for selector in selectors {
            var categories: [XiguaCategory] = []
            for item in doc.css(selector) {
                guard let link = item.css("a").first else { continue }
                let href = (link["href"] ?? "").trimmingCharacters(in: .whitespaces)
                let name = (link.text ?? "").trimmingCharacters(in: .whitespaces)
                guard !href.isEmpty, href != "#", !name.isEmpty else { continue }
                categories.append(XiguaCategory(typeId: href, typeName: name))
            }
            if !categories.isEmpty { return categories }
        }
        return [
            XiguaCategory(typeId: "/", typeName: "首页"),
            XiguaCategory(typeId: "/latest/", typeName: "最新"),
            XiguaCategory(typeId: "/hot/", typeName: "热门"),
        ]
    }

    private func parseVideoList(_ doc: HTMLDocument, containerSelector: String) -> [XiguaVideo] {
        var videos: [XiguaVideo] = []
        for article in doc.css(containerSelector) {
            guard let href = article["href"], !href.isEmpty else { continue }
            let title: String
            if let h2 = article.css("h2").first {
                title = (h2.text ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            } else {
                title = (article.text ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            }
            guard !title.isEmpty else { continue }
            let date: String
            if let dateEl = article.css("span[itemprop=\"datePublished\"]").first {
                date = (dateEl.text ?? "").trimmingCharacters(in: .whitespaces)
            } else if let metaEl = article.css(".post-meta, .entry-meta, time").first {
                date = (metaEl.text ?? "").trimmingCharacters(in: .whitespaces)
            } else { date = "" }
            let picURL = normalizeURL(extractBannerImage(article))
            videos.append(XiguaVideo(vodId: href, vodName: title, vodPic: picURL, vodRemarks: date))
        }
        return videos
    }

    private func extractBannerImage(_ article: XMLElement) -> String {
        guard let scriptText = article.css("script").first?.text else { return "" }
        let pattern = #"loadBannerDirect\('([^']+)'"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: scriptText, range: NSRange(scriptText.startIndex..., in: scriptText)),
              let range = Range(match.range(at: 1), in: scriptText) else { return "" }
        return String(scriptText[range])
    }

    private func extractDescription(_ doc: HTMLDocument) -> String {
        let keywordLinks = doc.css(".tags .keywords a")
        if keywordLinks.first != nil {
            let tags = keywordLinks.compactMap { link -> String? in
                guard let title = link.text, let href = link["href"], !title.isEmpty, !href.isEmpty else { return nil }
                return title
            }
            if !tags.isEmpty { return tags.joined(separator: " ") }
        }
        if let postTitle = doc.css(".post-title").first?.text {
            return postTitle.trimmingCharacters(in: .whitespaces)
        }
        return "通用吸瓜视频"
    }

    private func extractEpisodes(_ doc: HTMLDocument, html: String) -> [XiguaEpisode] {
        var episodes: [XiguaEpisode] = []
        var usedNames = Set<String>()
        for (index, dplayer) in doc.css(".dplayer").enumerated() {
            guard let configAttr = dplayer["data-config"],
                  let configData = configAttr.data(using: .utf8) else { continue }
            do {
                if let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
                   let video = config["video"] as? [String: Any],
                   let videoUrl = video["url"] as? String,
                   !videoUrl.isEmpty {
                    var epName = ""
                    if let h2 = dplayer.css("h2, h3, h4").first {
                        epName = (h2.text ?? "").trimmingCharacters(in: .whitespaces)
                    }
                    let baseName = epName.isEmpty ? "视频\(index + 1)" : epName
                    var name = baseName
                    var counter = 2
                    while usedNames.contains(name) {
                        name = "\(baseName) \(counter)"; counter += 1
                    }
                    usedNames.insert(name)
                    let normalizedUrl = normalizeURL(videoUrl)
                    print("[Xigua] 解析到视频: \(name) -> \(normalizedUrl)")
                    episodes.append(XiguaEpisode(name: name, url: normalizedUrl))
                }
            } catch { continue }
        }
        if episodes.isEmpty {
            let pattern = #"data-config='([^']*)'"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let configStr = String(html[range]).replacingOccurrences(of: "&quot;", with: "\"")
                if let configData = configStr.data(using: .utf8),
                   let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
                   let video = config["video"] as? [String: Any],
                   let videoUrl = video["url"] as? String,
                   !videoUrl.isEmpty {
                    let normalizedUrl = normalizeURL(videoUrl)
                    episodes.append(XiguaEpisode(name: "视频1", url: normalizedUrl))
                    print("[Xigua] 正则提取到视频: \(normalizedUrl)")
                }
            }
        }
        return episodes
    }

    private func isDirectPlayable(_ url: String) -> Bool {
        [".m3u8", ".mp4", ".ts"].contains(where: { url.contains($0) })
    }
}