import Foundation
import Kanna

// MARK: - 每日大乱斗 HTML 抓取服务
// Python Spider → Swift 原生实现，基于 Kanna HTML 解析
// 数据源: border.bshzjjgq.cc / blood.bshzjjgq.cc

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
}

// MARK: - 服务

@MainActor
class DailyBattleService: ObservableObject {
    static let shared = DailyBattleService()

    private let headers: [String: String] = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9"
    ]

    private let dynamicHosts = [
        "https://border.bshzjjgq.cc",
        "https://blood.bshzjjgq.cc"
    ]

    private(set) var currentHost: String = ""

    init() {
        currentHost = dynamicHosts[0]
    }

    // MARK: - 站点存活探测

    func probeHost() async -> String {
        for host in dynamicHosts {
            do {
                let (_, response) = try await session.data(for: request(url: host))
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                    currentHost = host
                    print("[DailyBattle] ✅ 使用站点: \(host)")
                    return host
                }
            } catch {
                print("[DailyBattle] ⚠️ \(host) 不可达: \(error.localizedDescription)")
            }
        }
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
            let navSelectors = [".mobile-nav-categories a", "nav a", ".nav-categories a"]
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
                cats = [
                    DailyBattleCategory(id: "/category/mrld/", name: "今日乱斗", url: "/category/mrld/"),
                    DailyBattleCategory(id: "/category/bkdg/", name: "必看大瓜", url: "/category/bkdg/")
                ]
            }

            // 提取推荐视频（过滤广告外链）
            let rawArticles = doc.css("article")
            let videos = parseVideos(rawArticles)

            return (cats, videos)
        } catch {
            print("[DailyBattle] fetchHome error: \(error)")
            return ([], [])
        }
    }

    // MARK: - 分类列表（分页）

    func fetchCategoryList(url: String, page: Int) async -> [DailyBattleVideo] {
        do {
            let fullURL = buildCategoryURL(base: url, page: page)
            let html = try await fetchHTML(url: fullURL)
            guard let doc = try? HTML(html: html, encoding: .utf8) else { return [] }
            let articles = doc.css("#archive article, #index article, article")
            let isFolder = url.contains("/mrdg")
            return parseVideos(articles, tag: isFolder ? "folder" : "")
        } catch {
            print("[DailyBattle] fetchCategoryList(\(url), p\(page)) error: \(error)")
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
                return DailyBattleDetail(playFrom: "每日大乱斗", playUrl: "解析失败", content: "")
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
                ? (doc.css("h1").first?.text ?? doc.css(".post-title").first?.text ?? "每日大乱斗")
                : tagItems.joined(separator: " · ")

            return DailyBattleDetail(playFrom: "每日大乱斗", playUrl: playUrl, content: content)
        } catch {
            print("[DailyBattle] fetchDetail(\(vodId)) error: \(error)")
            return DailyBattleDetail(playFrom: "每日大乱斗", playUrl: "获取失败", content: "每日大乱斗")
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
            print("[DailyBattle] search(\(keyword), p\(page)) error: \(error)")
            return []
        }
    }

    // MARK: - 私有工具

    private var session: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }

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
        for article in articles {
            // 提取标题
            var title = article.css("h2").first?.text
                ?? article.css(".entry-title").first?.text
                ?? article.css(".post-title").first?.text
                ?? ""

            if title.isEmpty, let tagName = article.tagName, tagName == "a" {
                title = article.text ?? ""
            }
            guard !title.isEmpty else { continue }

            // 提取链接
            let anchor: XMLElement?
            if article.tagName == "a" {
                anchor = article
            } else {
                anchor = article.css("a").first
            }
            guard let href = anchor?["href"], !href.isEmpty else { continue }
            // 跳过广告外链（非 / 开头且非本站域名的 URL）
            if href.hasPrefix("http") && !href.contains("bshzjjgq.cc") && !href.contains("mrdld.com") { continue }

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
        return videos
    }

    /// 从 article 元素提取封面图片 URL
    private func extractCover(from article: XMLElement) -> String {
        let rawHTML = article.toHTML ?? ""

        // 1. loadBannerDirect('...')
        if let m = firstMatch(pattern: #"loadBannerDirect\('([^']+)'"#, in: rawHTML) {
            return m
        }

        // 2. data:image
        if let m = firstMatch(pattern: #"(data:image/[a-zA-Z0-9+/=;,]+)"#, in: rawHTML) {
            return m
        }

        // 3. https?://...jpg|png|jpeg|webp
        if let m = firstMatch(pattern: #"(https?://[^"'\s)]+\.(?:jpg|png|jpeg|webp))"#, in: rawHTML, caseInsensitive: true) {
            return m
        }

        // 4. url(...)
        if let m = firstMatch(pattern: #"url\s*\(\s*['"]?([^"'\)]+)['"]?\s*\)"#, in: rawHTML, caseInsensitive: true) {
            return m
        }

        // 5. img src / data-src
        if let img = article.css("img").first {
            if let src = img["src"], !src.isEmpty { return src }
            if let ds = img["data-src"], !ds.isEmpty { return ds }
            if let ds = img["data-original"], !ds.isEmpty { return ds }
        }

        return ""
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
