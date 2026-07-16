import Foundation
import Kanna

// MARK: - FullHD（HTML 类）
// 对应脚本：FullHD[成人].py
// 站点：www.fullhd.xxx/zh/
// 分类: 3个主分类(最新/最佳/热门) + 支持/categories/子分类
class FullHDService: FuliBaseService {
    static let shared = FullHDService()

    init() {
        super.init(
            platformName: "FullHD",
            defaultHosts: [
                "https://www.fullhd.xxx",
                "https://fullhd.xxx"
            ]
        )
    }

    // 中文路径前缀
    private var zhBase: String { "/zh" }

    // MARK: - 硬编码主分类
    private let mainCategories: [(String, String)] = [
        ("最新视频", "latest-updates"),
        ("最佳视频", "top-rated"),
        ("热门影片", "most-popular")
    ]

    override func fetchHomeContent() async -> FuliHomeResult {
        // 主分类使用硬编码
        var categories = mainCategories.map {
            FuliCategory(typeId: $0.1, typeName: $0.0)
        }

        // 尝试从分类页获取更多分类
        do {
            let html = try await fetchHTML("\(zhBase)/categories/")
            let doc = try HTML(html: html, encoding: .utf8)
            let extraCats = parseCategoriesFromPage(doc)
            if !extraCats.isEmpty {
                categories.append(contentsOf: extraCats)
            }
        } catch {
            print("[FullHD] 获取扩展分类失败: \(error)")
        }

        // 首页推荐视频
        var videos: [FuliVideo] = []
        do {
            let html = try await fetchHTML("\(zhBase)/")
            let doc = try HTML(html: html, encoding: .utf8)
            videos = parseVideoList(doc)
        } catch {
            print("[FullHD] 首页视频失败: \(error)")
        }

        return FuliHomeResult(categories: categories, videos: videos)
    }

    override func fetchCategoryContent(category: FuliCategory, subCategory: FuliCategory?, page: Int) async -> FuliCategoryResult {
        let tid = subCategory?.typeId ?? category.typeId
        // URL格式: /zh/{cid}/ 或 /zh/{cid}/{pg}/
        let path: String
        if page > 1 {
            path = "\(zhBase)/\(tid)/\(page)/"
        } else {
            path = "\(zhBase)/\(tid)/"
        }
        do {
            let html = try await fetchHTML(path)
            let doc = try HTML(html: html, encoding: .utf8)
            let videos = parseVideoList(doc)
            return FuliCategoryResult(videos: videos, page: page, hasMore: videos.count >= 20)
        } catch {
            print("[FullHD] 分类失败: \(error)")
            return FuliCategoryResult(videos: [], page: page, hasMore: false)
        }
    }

    override func fetchDetail(vodId: String) async -> FuliDetail {
        let url = normalizeURL(vodId)
        do {
            let html = try await fetchHTML(url)
            let doc = try HTML(html: html, encoding: .utf8)

            let title = doc.xpath("//h1").first?.text?.trimmingCharacters(in: .whitespaces)
                ?? doc.xpath("//title").first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            var pic = doc.xpath("//meta[@property='og:image']/@content").first?.text
                ?? doc.xpath("//meta[@name='twitter:image']/@content").first?.text ?? ""
            pic = normalizeURL(pic)
            let content = doc.xpath("//div[@class='video-description']").first?.text?.trimmingCharacters(in: .whitespaces)
                ?? doc.xpath("//div[contains(@class,'description')]").first?.text?.trimmingCharacters(in: .whitespaces)

            var episodes: [FuliEpisode] = []
            var playURL: String? = nil

            // 1. 直接从 video/source 标签获取
            if let videoSrc = doc.xpath("//video/source/@src").first?.text, !videoSrc.isEmpty {
                playURL = videoSrc
            } else if let videoSrc = doc.xpath("//video/@src").first?.text, !videoSrc.isEmpty {
                playURL = videoSrc
            }
            // 2. 从 iframe src 获取
            if playURL == nil, let iframeSrc = doc.xpath("//iframe/@src").first?.text, !iframeSrc.isEmpty {
                playURL = iframeSrc
            }
            // 3. 从 JavaScript 中提取
            if playURL == nil {
                playURL = extractPlayURL(from: html)
            }

            if let pu = playURL, !pu.isEmpty {
                let normalized = normalizeURL(pu)
                episodes.append(FuliEpisode(name: "播放", url: normalized))
            } else {
                // 返回页面URL供 fetchPlayerURL 进一步解析
                episodes.append(FuliEpisode(name: "播放", url: url))
            }

            return FuliDetail(vodId: vodId, vodName: title, vodPic: pic, vodContent: content, playFrom: "FullHD", episodes: episodes)
        } catch {
            print("[FullHD] 详情失败: \(error)")
            return FuliDetail(vodId: vodId, vodName: "", vodPic: "", vodContent: nil, playFrom: "FullHD", episodes: [])
        }
    }

    func fetchPlayerURL(episode: FuliEpisode) async -> FuliPlayerResult {
        let url = episode.url
        // 如果已经是直接的视频URL，直接返回
        if url.contains(".m3u8") || url.contains(".mp4") || url.contains(".ts") {
            let normalized = normalizeURL(url)
            return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: currentHost), parse: 0)
        }
        // 否则需要访问页面解析出播放地址
        do {
            let pageURL = normalizeURL(url)
            let html = try await fetchHTML(pageURL)
            if let playURL = extractPlayURL(from: html) {
                let normalized = normalizeURL(playURL)
                print("[FullHD] 解析到播放地址: \(normalized.prefix(100))")
                return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: currentHost), parse: 0)
            }
            // 也尝试用 Kanna 解析
            let doc = try HTML(html: html, encoding: .utf8)
            if let src = doc.xpath("//video/source/@src | //video/@src | //iframe/@src").first?.text, !src.isEmpty {
                let normalized = normalizeURL(src)
                return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: currentHost), parse: 0)
            }
            // 最后回退：返回页面URL让 WebView 尝试解析
            print("[FullHD] 未解析到播放地址，回退到Web解析")
            return FuliPlayerResult(url: pageURL, headers: defaultHeaders(host: currentHost), parse: 1)
        } catch {
            print("[FullHD] fetchPlayerURL 失败: \(error)")
            return FuliPlayerResult(url: url, headers: defaultHeaders(host: currentHost), parse: 1)
        }
    }

    override func fetchSearch(keyword: String, page: Int) async -> FuliSearchResult {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? keyword
        let path = page > 1 ? "\(zhBase)/search/\(encoded)/\(page)/" : "\(zhBase)/search/\(encoded)/"
        do {
            let html = try await fetchHTML(path)
            let doc = try HTML(html: html, encoding: .utf8)
            let videos = parseVideoList(doc)
            return FuliSearchResult(videos: videos, page: page, hasMore: videos.count >= 20)
        } catch {
            print("[FullHD] 搜索失败: \(error)")
            return FuliSearchResult(videos: [], page: page, hasMore: false)
        }
    }

    // MARK: - 从分类页解析子分类
    private func parseCategoriesFromPage(_ doc: HTMLDocument) -> [FuliCategory] {
        var categories: [FuliCategory] = []
        for a in doc.xpath("//a[contains(@href,'/categories/')]") {
            guard let href = a["href"], let name = a.text?.trimmingCharacters(in: .whitespaces),
                  !href.isEmpty, !name.isEmpty,
                  href != "/zh/categories/" && href != "/categories/" else { continue }
            // 提取分类ID
            if let range = href.range(of: #"/categories/([^/]+)/"#, options: .regularExpression) {
                let catId = String(href[range].dropFirst(12).dropLast())
                categories.append(FuliCategory(typeId: "categories/\(catId)", typeName: name))
            }
        }
        return Array(ArraySlice(categories.prefix(30)))
    }

    // MARK: - URL 规范化
    private func normalizeURL(_ url: String, base: String? = nil) -> String {
        var result = url.trimmingCharacters(in: .whitespaces)
        guard !result.isEmpty else { return "" }
        if result.hasPrefix("http://") || result.hasPrefix("https://") {
            return result
        }
        if result.hasPrefix("//") {
            return "https:" + result
        }
        let baseHost = base ?? currentHost
        if result.hasPrefix("/") {
            return baseHost + result
        }
        // 无协议无斜杠开头，当作相对路径
        if baseHost.hasSuffix("/") {
            return baseHost + result
        }
        return baseHost + "/" + result
    }

    // MARK: - 从 HTML 字符串中提取播放 URL（多级回退）
    private func extractPlayURL(from html: String) -> String? {
        // 1. player_data / player_url JSON
        let patterns = [
            "var\\s+player_data\\s*=\\s*(\\{[^;]+\\})",
            "var\\s+player_url\\s*=\\s*['\"]([^'\"]+)['\"]",
            "player_data\\s*=\\s*(\\{[^;]+\\})",
            "\"url\"\\s*:\\s*\"([^\"]+)\"",
            "'url'\\s*:\\s*'([^']+)'"
        ]
        for pattern in patterns {
            if let groups = firstMatch(pattern: pattern, in: html), groups.count >= 2 {
                let captured = groups[1]
                // 如果是 JSON，尝试解析
                if captured.hasPrefix("{") {
                    if let data = captured.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let url = (json["url"] as? String ?? json["video_url"] as? String ?? json["src"] as? String),
                       !url.isEmpty {
                        return url
                    }
                } else {
                    return captured
                }
            }
        }

        // 2. 直接 m3u8/mp4 URL
        let urlPatterns = [
            "(https?://[^\"'\\s<>]+\\.m3u8[^\"'\\s<>]*)",
            "(https?://[^\"'\\s<>]+\\.mp4[^\"'\\s<>]*)",
            "(https?://[^\"'\\s<>]+\\.ts[^\"'\\s<>]*)",
            "(/[^\"'\\s<>]+\\.m3u8[^\"'\\s<>]*)",
            "(/[^\"'\\s<>]+\\.mp4[^\"'\\s<>]*)"
        ]
        for pattern in urlPatterns {
            if let groups = firstMatch(pattern: pattern, in: html), groups.count >= 2 {
                return groups[1]
            }
        }

        return nil
    }

    // 正则辅助
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

    // MARK: - 解析视频列表
    private func parseVideoList(_ doc: HTMLDocument) -> [FuliVideo] {
        var videos: [FuliVideo] = []
        // 多种 XPath 回退
        let xpaths = [
            "//div[contains(@class,'list-videos')]//div[contains(@class,'item')]",
            "//div[@class='item']",
            "//div[contains(@class,'video-item')]",
            "//div[contains(@class,'thumb')]/..",
            "//li[contains(@class,'video')]",
            "//div[contains(@class,'videos')]//a"
        ]
        var items: [XMLElement] = []
        for xp in xpaths {
            let found = doc.xpath(xp)
            if found.first != nil {
                items = found.toArray()
                break
            }
        }
        for item in items {
            let aTag: XMLElement?
            if let foundA = item.xpath(".//a").first {
                aTag = foundA
            } else if item.tagName == "a" {
                aTag = item
            } else {
                aTag = nil
            }
            guard let a = aTag else { continue }
            let href = a["href"] ?? ""
            guard !href.isEmpty else { continue }

            var name = a["title"] ?? ""
            if name.isEmpty {
                name = item.xpath(".//a/@title").first?.text ?? ""
            }
            if name.isEmpty {
                name = a.text?.trimmingCharacters(in: .whitespaces) ?? ""
            }
            if name.isEmpty {
                name = item.xpath(".//img/@alt").first?.text ?? ""
            }
            guard !name.isEmpty else { continue }

            var pic = item.xpath(".//img[contains(@class,'lazyload')]/@data-src").first?.text
                ?? item.xpath(".//img/@data-src").first?.text
                ?? item.xpath(".//img/@data-original").first?.text
                ?? item.xpath(".//img/@src").first?.text ?? ""
            pic = normalizeURL(pic)

            let duration = item.xpath(".//span[@class='duration']").first?.text?.trimmingCharacters(in: .whitespaces)
                ?? item.xpath(".//div[contains(@class,'duration')]").first?.text?.trimmingCharacters(in: .whitespaces)
                ?? item.xpath(".//span[contains(@class,'time')]").first?.text?.trimmingCharacters(in: .whitespaces)

            let normalizedHref = normalizeURL(href)
            videos.append(FuliVideo(vodId: normalizedHref, vodName: name, vodPic: pic, duration: duration))
        }
        return videos
    }
}
