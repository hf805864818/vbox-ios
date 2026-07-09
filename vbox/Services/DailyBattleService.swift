import Foundation
import Kanna

// MARK: - 每日大乱斗 / 每日大赛 HTML 抓取服务
// Python Spider → Swift 原生实现，基于 Kanna HTML 解析
// 支持多站点配置：每日大乱斗 (bshzjjgq.cc) / 每日大赛 (mrds66.com)

// MARK: - 站点配置

struct DailyBattleSiteConfig {
    let name: String
    let hosts: [String]
    let domainPatterns: [String]  // 外链过滤白名单域名片段

    static let battle = DailyBattleSiteConfig(
        name: "每日大乱斗",
        hosts: [
            "https://border.bshzjjgq.cc",
            "https://blood.bshzjjgq.cc"
        ],
        domainPatterns: ["bshzjjgq.cc", "mrdld.com"]
    )

    static let dailyContest = DailyBattleSiteConfig(
        name: "每日大赛",
        hosts: [
            "https://www.mrds66.com",
            "https://mrdsa2.com",
            "https://mrdsa1.com",
            "https://mrdsk.com"
        ],
        domainPatterns: ["mrds", "mrdsk"]
    )
}

// MARK: - 数据模型

struct DailyBattleCategory: Identifiable, Codable {
    let id: String
    let name: String
    let url: String
}

struct DailyBattleVideo: Identifiable, Codable {
    let id = UUID()
    let vodId: String
    let title: String
    let cover: String
    let remarks: String
    let tag: String
}

struct DailyBattleDetail {
    let playFrom: String
    let playUrl: String
    let content: String
    let keywords: [String]
}

// MARK: - SSL 跳过 Delegate (对应 Python verify=False)

private class SSLBypassDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    /// 会话级 SSL 挑战
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
    /// 任务级 SSL 挑战（async/await 触发的是这一层）
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - 服务

@MainActor
class DailyBattleService: ObservableObject {
    /// 默认实例（每日大乱斗）
    static let shared = DailyBattleService(config: .battle)
    /// 每日大赛实例
    static let contest = DailyBattleService(config: .dailyContest)

    private let config: DailyBattleSiteConfig
    var siteName: String { config.name }

    private let headers: [String: String] = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9"
    ]

    private(set) var currentHost: String = ""
    /// probeHost() 是否已完成，用于控制加载时机
    @Published var isReady = false

    /// 从平台配置创建服务实例
    static func from(platform: YBoxPlatform2) -> DailyBattleService {
        if platform.name == "每日大赛" {
            return contest
        }
        return shared
    }

    private let sslDelegate = SSLBypassDelegate()
    private let session: URLSession

    init(config: DailyBattleSiteConfig) {
        self.config = config
        currentHost = config.hosts[0]
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 15
        sessionConfig.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: sessionConfig, delegate: sslDelegate, delegateQueue: nil)
    }

    // MARK: - 站点存活探测

    func probeHost() async -> String {
        for host in config.hosts {
            do {
                let (data, response) = try await session.data(for: request(url: host))
                if let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) {
                    // 跟随重定向并解析 JS 跳转提取最终 URL（对应每日大赛多层 JS 跳转）
                    var finalURL: URL? = httpResp.url
                    if let html = String(data: data, encoding: .utf8) {
                        // 解析 <a href="https://xxx" ...>window.location.replace... 跳转
                        if let hrefRegex = try? NSRegularExpression(pattern: "<a[^>]+href=\"([^\"]+)\"", options: []),
                           let firstMatch = hrefRegex.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)) {
                            let hrefRange = firstMatch.range(at: 1)
                            let hrefStr = (html as NSString).substring(with: hrefRange)
                            if let jsRedirectURL = URL(string: hrefStr, relativeTo: finalURL) {
                                print("[DailyBattle:\(config.name)] 🔀 JS 跳转 → \(jsRedirectURL.absoluteString)")
                                // 跟进一次跳转
                                do {
                                    let (_, secondResp) = try await session.data(for: request(url: jsRedirectURL.absoluteString))
                                    if let secondHttp = secondResp as? HTTPURLResponse, (200...299).contains(secondHttp.statusCode) {
                                        finalURL = secondHttp.url ?? jsRedirectURL
                                    }
                                } catch {
                                    print("[DailyBattle:\(config.name)] ⚠️ 跳转失败: \(error)")
                                }
                            }
                        }
                    }
                    // 只提取 origin（scheme + host）
                    if let final = finalURL {
                        let scheme = final.scheme ?? "https"
                        let hostPart = final.host ?? ""
                        if !hostPart.isEmpty {
                            currentHost = "\(scheme)://\(hostPart)"
                            isReady = true
                            print("[DailyBattle:\(config.name)] ✅ 使用站点: \(currentHost)")
                            return currentHost
                        }
                    }
                    // fallback: 使用原始 host
                    currentHost = host
                    isReady = true
                    print("[DailyBattle:\(config.name)] ✅ 使用原始站点: \(currentHost)")
                    return currentHost
                }
            } catch {
                print("[DailyBattle:\(config.name)] ⚠️ \(host) 不可达: \(error.localizedDescription)")
            }
        }
        isReady = true
        return currentHost
    }

    // MARK: - 首页：分类 + 推荐视频

    func fetchHome() async -> (categories: [DailyBattleCategory], videos: [DailyBattleVideo]) {
        do {
            let html = try await fetchHTML(url: currentHost)
            guard let doc = try? HTML(html: html, encoding: .utf8) else { return ([], []) }

            // 提取分类
            var cats: [DailyBattleCategory] = []
            let skipNames = Set(["首页", "更多", "官方QQ群", "商务合作", "求瓜投稿", "往期内容",
                                 "吃瓜电报群", "官方推特", "常见问题", "世界杯直播", "吃瓜首页",
                                 "吃瓜QQ群", "回家的路", "51AV"])
            // 对应 Python 脚本中的 category_selectors
            let navSelectors = [
                ".category-list ul li a", ".nav-menu li a", ".menu li a", "nav ul li a",
                ".mobile-nav-categories a", "nav a", ".nav-categories a"
            ]
            for sel in navSelectors {
                let items = Array(doc.css(sel))
                if !items.isEmpty {
                    for el in items {
                        guard let href = el["href"], href != "#",
                              let name = el.text?.trimmingCharacters(in: CharacterSet.whitespaces),
                              !name.isEmpty, !skipNames.contains(name),
                              name.count <= 8 else { continue }
                        if cats.contains(where: { $0.url == href }) { continue }
                        let u = href.hasPrefix("/") ? href : "/\(href)"
                        cats.append(DailyBattleCategory(id: u, name: name, url: u))
                    }
                    break
                }
            }
            if cats.isEmpty {
                // 按站点配置提供 fallback 分类
                if config.name == "每日大赛" {
                    cats = [
                        DailyBattleCategory(id: "/category/mrds/", name: "每日大赛", url: "/category/mrds/")
                    ]
                } else {
                    cats = [
                        DailyBattleCategory(id: "/category/mrld/", name: "今日乱斗", url: "/category/mrld/"),
                        DailyBattleCategory(id: "/category/bkdg/", name: "必看大瓜", url: "/category/bkdg/")
                    ]
                }
            }

            // 提取推荐视频（过滤广告外链）
            // 对应 Python: data('#index article, article')
            // 先用 CSS 选择器，失败则回退到 XPath
            var rawArticles = doc.css("article")
            if Array(rawArticles).isEmpty {
                rawArticles = doc.xpath("//*[@id='index']//article | //article")
            }
            let videos = parseVideos(rawArticles)
            print("[DailyBattle:\(config.name)] fetchHome: \(cats.count) 分类, \(videos.count) 视频")

            return (cats, videos)
        } catch {
            print("[DailyBattle:\(config.name)] fetchHome error: \(error)")
            return ([], [])
        }
    }

    // MARK: - 分类列表（分页）

    func fetchCategoryList(url: String, page: Int) async -> [DailyBattleVideo] {
        do {
            let fullURL = buildCategoryURL(base: url, page: page)
            let html = try await fetchHTML(url: fullURL)
            guard let doc = try? HTML(html: html, encoding: .utf8) else { return [] }
            // 对应 Python: data('#archive article, #index article, article')
            // 使用 XPath 替代逗号分隔的 CSS 选择器，//* 匹配任意元素类型
            let articles = doc.xpath("//*[@id='archive']//article | //*[@id='index']//article | //article")
            let isFolder = url.contains("/mrdg")
            let videos = parseVideos(articles, tag: isFolder ? "folder" : "")
            print("[DailyBattle:\(config.name)] fetchCategoryList(\(url), p\(page)): \(videos.count) 视频")
            return videos
        } catch {
            print("[DailyBattle:\(config.name)] fetchCategoryList(\(url), p\(page)) error: \(error)")
            return []
        }
    }

    private func buildCategoryURL(base: String, page: Int) -> String {
        let path: String
        if base.hasPrefix("http") {
            path = base
        } else {
            path = currentHost + (base.hasPrefix("/") ? base : "/\(base)")
        }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return page == 1 ? "\(trimmed)/" : "\(trimmed)/\(page)/"
    }

    // MARK: - 详情 → 提取播放地址

    func fetchDetail(vodId: String) async -> DailyBattleDetail {
        do {
            let url = vodId.hasPrefix("http") ? vodId : "\(currentHost)\(vodId.hasPrefix("/") ? "" : "/")\(vodId)"
            let html = try await fetchHTML(url: url)
            guard let doc = try? HTML(html: html, encoding: .utf8) else {
                return DailyBattleDetail(playFrom: config.name, playUrl: "解析失败", content: "", keywords: [])
            }

            var playUrls: [String] = []
            var usedNames = Set<String>()

            // 1. 从 dplayer data-config 提取
            for (idx, dp) in doc.css(".dplayer").enumerated() {
                if let configStr = dp["data-config"],
                   let configData = configStr.data(using: .utf8),
                   let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
                   let video = config["video"] as? [String: Any],
                   let videoURL = video["url"] as? String, !videoURL.isEmpty {

                    // 尝试获取集数名称 - 查找上一级标题
                    var epName = "视频\(idx + 1)"
                    let headings = dp.xpath("./preceding::h2|./preceding::h3|./preceding::h4")
                    if let heading = Array(headings).last?.text?.trimmingCharacters(in: CharacterSet.whitespaces), !heading.isEmpty {
                        epName = heading
                    }

                    var name = epName
                    var count = 2
                    while usedNames.contains(name) {
                        name = "\(epName) \(count)"
                        count += 1
                    }
                    usedNames.insert(name)
                    playUrls.append("\(name)$\(videoURL)")
                }
            }

            // 2. 回退：从页面内链接提取
            if playUrls.isEmpty {
                let contentArea = doc.css(".post-content a, article a")
                let kw = ["点击观看", "观看", "播放", "视频", "第一弹", "第二弹", "第三弹", "第四弹", "第五弹", "第六弹", "第七弹", "第八弹", "第九弹", "第十弹"]

                for (idx, link) in contentArea.enumerated() {
                    guard let linkText = link.text,
                          let href = link["href"] else { continue }

                    let matched = kw.contains(where: { linkText.contains($0) })
                    guard matched else { continue }

                    var epName = linkText
                        .replacingOccurrences(of: "点击观看：", with: "")
                        .replacingOccurrences(of: "点击观看", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if epName.isEmpty { epName = "视频\(idx + 1)" }

                    let fullHref: String
                    if href.hasPrefix("http") {
                        fullHref = href
                    } else if href.hasPrefix("/") {
                        fullHref = "\(currentHost)\(href)"
                    } else {
                        fullHref = "\(currentHost)/\(href)"
                    }

                    playUrls.append("\(epName)$\(fullHref)")
                }
            }

            let playUrl = playUrls.isEmpty ? "未找到视频源$\(url)" : playUrls.joined(separator: "#")

            // 提取标签
            var tagItems: [String] = []
            var seenNames = Set<String>()
            for tag in doc.css(".tags a, .keywords a, .post-tags a") {
                if let name = tag.text?.trimmingCharacters(in: .whitespaces), !name.isEmpty, !seenNames.contains(name) {
                    seenNames.insert(name)
                    tagItems.append(name)
                }
            }

            let content = tagItems.isEmpty
                ? (doc.css("h1").first?.text ?? doc.css(".post-title").first?.text ?? config.name)
                : tagItems.joined(separator: " · ")

            let tagLinks: [String] = []
            var kwItems: [String] = []
            var seenKw = Set<String>()
            for tag in doc.css(".tags a, .keywords a, .post-tags a") {
                if let name = tag.text?.trimmingCharacters(in: .whitespaces), !name.isEmpty, !seenKw.contains(name) {
                    seenKw.insert(name)
                    kwItems.append(name)
                }
            }
            return DailyBattleDetail(playFrom: config.name, playUrl: playUrl, content: content, keywords: kwItems)
        } catch {
            print("[DailyBattle:\(config.name)] fetchDetail(\(vodId)) error: \(error)")
            return DailyBattleDetail(playFrom: config.name, playUrl: "获取失败", content: config.name, keywords: [])
        }
    }

    // MARK: - 搜索

    func search(keyword: String, page: Int = 1) async -> [DailyBattleVideo] {
        do {
            let enc = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? keyword
            let url = page == 1
                ? "\(currentHost)/search/\(enc)/"
                : "\(currentHost)/search/\(enc)/\(page)/"
            let html = try await fetchHTML(url: url)
            guard let doc = try? HTML(html: html, encoding: .utf8) else { return [] }
            return parseVideos(doc.css("article"))
        } catch {
            print("[DailyBattle:\(config.name)] search(\(keyword), p\(page)) error: \(error)")
            return []
        }
    }

    // MARK: - 私有工具

    private func request(url: String) -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(currentHost, forHTTPHeaderField: "Origin")
        req.setValue("\(currentHost)/", forHTTPHeaderField: "Referer")
        return req
    }

    private func fetchHTML(url: String) async throws -> String {
        let (data, response) = try await session.data(for: request(url: url))
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            throw NSError(domain: "DailyBattle", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \( (response as? HTTPURLResponse)?.statusCode ?? -1)"])
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "DailyBattle", code: -1, userInfo: [NSLocalizedDescriptionKey: "编码错误"])
        }
        return html
    }

    // MARK: - 视频列表解析

    private func parseVideos(_ articles: XPathObject, tag: String = "") -> [DailyBattleVideo] {
        var videos: [DailyBattleVideo] = []
        var skippedNoTitle = 0, skippedNoHref = 0, skippedAd = 0
        for article in articles {
            // 提取标题
            var title = article.css("h2").first?.text
                ?? article.css(".entry-title").first?.text
                ?? article.css(".post-title").first?.text
                ?? ""

            if title.isEmpty, let tagName = article.tagName, tagName == "a" {
                title = article.text ?? ""
            }
            guard !title.isEmpty else { skippedNoTitle += 1; continue }

            // 提取链接
            let anchor: XMLElement?
            if article.tagName == "a" {
                anchor = article
            } else {
                anchor = article.css("a").first
            }
            guard let href = anchor?["href"], !href.isEmpty else { skippedNoHref += 1; continue }
            // 跳过广告外链（非 / 开头且非本站域名的 URL）
            if href.hasPrefix("http") && !config.domainPatterns.contains(where: { href.contains($0) }) { skippedAd += 1; continue }

            // 提取封面
            let cover = extractCover(from: article)

            // 提取备注
            let remarks = article.css("time").first?.text ?? ""

            videos.append(DailyBattleVideo(
                vodId: tag.isEmpty ? href : "\(href)@folder",
                title: title.trimmingCharacters(in: .whitespaces),
                cover: cover,
                remarks: remarks,
                tag: tag
            ))
        }
        if skippedNoTitle > 0 || skippedNoHref > 0 || skippedAd > 0 {
            print("[DailyBattle:\(config.name)] parseVideos: \(videos.count)保留, 跳过: 无标题\(skippedNoTitle) 无链接\(skippedNoHref) 广告\(skippedAd)")
        }
        return videos
    }

    /// 图片 URL（去除 ybox.vip 代理, 直接返回原始 URL）
    /// 每日大乱斗/大赛封面图 AES 加密, 由 PlatformAsyncImage(.dailyBattle) 解密
    /// 对应 Python 脚本 _proc_url(): 本地代理解密, 非 ybox.vip 外部代理
    func proxyImageURL(_ url: String) -> String {
        // 不再使用 ybox.vip 代理, 直接返回原始 URL
        // 封面图 AES 解密由 PlatformImageLoader / PlatformAsyncImage 处理
        return url
    }

    /// 从 article 元素提取封面图片 URL
    /// 对应 Python getimg(text, elem, html_content) 方法
    private func extractCover(from article: XMLElement) -> String {
        // 优先从 script 标签文本提取（对应 Python 第一参数 k('script').text()）
        let scriptText = article.css("script").first?.text ?? ""
        let rawHTML = article.toHTML ?? ""
        var raw: String? = nil

        // 1. loadBannerDirect('...') — 优先从 script 文本匹配，再回退到完整 HTML
        if let m = firstMatch(pattern: #"loadBannerDirect\('([^']+)'"#, in: scriptText) {
            raw = m
        } else if let m = firstMatch(pattern: #"loadBannerDirect\('([^']+)'"#, in: rawHTML) {
            raw = m
        }
        // 2. data:image
        else if let m = firstMatch(pattern: #"(data:image/[a-zA-Z0-9+/=;,]+)"#, in: rawHTML) {
            raw = m
        }
        // 3. https?://...jpg|png|jpeg|webp
        else if let m = firstMatch(pattern: #"(https?://[^"'\s)]+\.(?:jpg|png|jpeg|webp))"#, in: rawHTML, caseInsensitive: true) {
            raw = m
        }
        // 4. url(...)
        else if let m = firstMatch(pattern: #"url\s*\(\s*['"]?([^"'\)]+)['"]?\s*\)"#, in: rawHTML, caseInsensitive: true) {
            raw = m
        }
        // 5. img src / data-src
        else if let img = article.css("img").first {
            raw = img["src"] ?? img["data-src"] ?? img["data-original"]
        }

        guard let cover = raw, !cover.isEmpty else { return "" }
        // 将相对 URL 转为绝对 URL (对应 Python _proc_url 中的相对路径处理)
        var finalURL = cover
        if !finalURL.hasPrefix("http") && !finalURL.hasPrefix("data:") {
            if finalURL.hasPrefix("/") {
                finalURL = "\(currentHost)\(finalURL)"
            } else {
                finalURL = "\(currentHost)/\(finalURL)"
            }
        }
        return finalURL
    }

    private func firstMatch(pattern: String, in text: String, caseInsensitive: Bool = false) -> String? {
        let opts: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: opts) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
