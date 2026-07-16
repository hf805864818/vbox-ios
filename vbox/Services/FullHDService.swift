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

    // MARK: - 播放地址解析（重写基类方法，支持4级解析策略）

    override func fetchPlayerURL(episode: FuliEpisode) async -> FuliPlayerResult {
        let url = episode.url

        // 策略0：如果已经是直接的视频URL，直接返回
        if url.contains(".m3u8") || url.contains(".mp4") || url.contains(".ts") {
            let normalized = normalizeURL(url)
            print("[FullHD] 策略0 - 直接视频URL: \(normalized.prefix(80))")
            return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: currentHost), parse: 0)
        }

        do {
            let pageURL = normalizeURL(url)
            let html = try await fetchHTML(pageURL)

            // 策略1：直接从 video/source 标签提取视频URL
            if let videoURL = extractVideoURL(from: html) {
                let normalized = normalizeURL(videoURL)
                print("[FullHD] 策略1成功 - 从video标签解析: \(normalized.prefix(80))")
                return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: currentHost), parse: 0)
            }

            // 策略2：从 iframe 中提取播放地址（支持两级iframe嵌套）
            if let iframeURL = extractIframeURL(from: html) {
                print("[FullHD] 策略2 - 发现iframe: \(iframeURL.prefix(80))")
                // 第一级 iframe
                do {
                    let iframeHTML = try await fetchHTML(iframeURL)
                    if let videoURL = extractVideoURL(from: iframeHTML) {
                        let normalized = normalizeURL(videoURL, base: iframeURL)
                        print("[FullHD] 策略2成功 - 从一级iframe解析: \(normalized.prefix(80))")
                        return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: currentHost), parse: 0)
                    }
                    // 第一级 iframe 中也有 iframe，再深入一层
                    if let innerIframeURL = extractIframeURL(from: iframeHTML) {
                        let innerFull = normalizeURL(innerIframeURL, base: iframeURL)
                        do {
                            let innerHTML = try await fetchHTML(innerFull)
                            if let videoURL = extractVideoURL(from: innerHTML) {
                                let normalized = normalizeURL(videoURL, base: innerFull)
                                print("[FullHD] 策略2成功 - 从二级iframe解析: \(normalized.prefix(80))")
                                return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: currentHost), parse: 0)
                            }
                            // 二级iframe中也尝试JS提取
                            if let jsURL = extractPlayURL(from: innerHTML) {
                                let normalized = normalizeURL(jsURL, base: innerFull)
                                print("[FullHD] 策略2成功 - 从二级iframe JS解析: \(normalized.prefix(80))")
                                return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: currentHost), parse: 0)
                            }
                        } catch {
                            print("[FullHD] 二级iframe请求失败: \(error)")
                        }
                    }
                    // 一级iframe中也尝试JS提取
                    if let jsURL = extractPlayURL(from: iframeHTML) {
                        let normalized = normalizeURL(jsURL, base: iframeURL)
                        print("[FullHD] 策略2成功 - 从一级iframe JS解析: \(normalized.prefix(80))")
                        return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: currentHost), parse: 0)
                    }
                } catch {
                    print("[FullHD] iframe请求失败: \(error)")
                }
            }

            // 策略3：从JavaScript中提取播放URL（player_data / player_url等）
            if let jsURL = extractPlayURL(from: html) {
                let normalized = normalizeURL(jsURL)
                print("[FullHD] 策略3成功 - 从JS解析: \(normalized.prefix(80))")
                return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: currentHost), parse: 0)
            }

            // 策略4：回退到WebView解析
            print("[FullHD] 所有策略失败，回退到WebView解析")
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

    // MARK: - 辅助方法：从HTML提取视频URL

    private func extractVideoURL(from html: String) -> String? {
        let doc = try? HTML(html: html, encoding: .utf8)
        guard let d = doc else { return nil }

        // 优先从 video/source 标签提取
        let videoSelectors = [
            "//video/source/@src",
            "//video/@src",
            "//video/source/@data-src",
            "//video/@data-src",
            "//video/source/@data-original",
            "//video/@data-original",
            "//video[contains(@class,'video')]/@src",
            "//video[contains(@id,'player')]/@src",
            "//source/@src",
            "//source/@data-src",
        ]
        for sel in videoSelectors {
            if let src = d.xpath(sel).first?.text?.trimmingCharacters(in: .whitespaces),
               !src.isEmpty, !src.hasPrefix("about:") {
                return src
            }
        }
        return nil
    }

    // MARK: - 辅助方法：从HTML提取iframe URL

    private func extractIframeURL(from html: String) -> String? {
        let doc = try? HTML(html: html, encoding: .utf8)
        guard let d = doc else { return nil }

        let iframeSelectors = [
            "//iframe[@id='player_iframe']/@src",
            "//iframe[contains(@class,'player')]/@src",
            "//iframe[contains(@id,'play')]/@src",
            "//iframe[contains(@id,'video')]/@src",
            "//div[contains(@class,'player')]//iframe/@src",
            "//div[contains(@id,'player')]//iframe/@src",
            "//iframe/@src",
            "//embed/@src",
        ]
        for sel in iframeSelectors {
            if let src = d.xpath(sel).first?.text?.trimmingCharacters(in: .whitespaces),
               !src.isEmpty, !src.hasPrefix("about:") {
                return normalizeURL(src)
            }
        }
        return nil
    }

    // MARK: - 从 HTML 字符串中提取播放 URL（多级回退）
    private func extractPlayURL(from html: String) -> String? {
        // 1. player_data / player_url JSON
        let patterns = [
            "var\\s+player_data\\s*=\\s*(\\{[^;]+\\})",
            "var\\s+player_url\\s*=\\s*['\"]([^'\"]+)['\"]",
            "player_data\\s*=\\s*(\\{[^;]+\\})",
            "player_url\\s*=\\s*['\"]([^'\"]+)['\"]",
            "var\\s+video_url\\s*=\\s*['\"]([^'\"]+)['\"]",
            "video_url\\s*=\\s*['\"]([^'\"]+)['\"]",
            "var\\s+videoSrc\\s*=\\s*['\"]([^'\"]+)['\"]",
            "\"url\"\\s*:\\s*\"([^\"]+)\"",
            "'url'\\s*:\\s*'([^']+)'",
            "\"video_url\"\\s*:\\s*\"([^\"]+)\"",
            "\"src\"\\s*:\\s*\"([^\"]+)\"",
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

    // MARK: - 解析视频列表（增强版）
    private func parseVideoList(_ doc: HTMLDocument) -> [FuliVideo] {
        var videos: [FuliVideo] = []
        var seen: Set<String> = []

        // 多种 XPath 回退选择器（按优先级排序）
        let xpathSelectors = [
            // FullHD 标准列表
            "//div[contains(@class,'list-videos')]//div[contains(@class,'item')]",
            "//div[@class='item']",
            "//div[contains(@class,'video-item')]",
            // 缩略图容器
            "//div[contains(@class,'thumb')]/..",
            "//div[contains(@class,'thumbnail')]/..",
            "//div[contains(@class,'video') and contains(@class,'item')]",
            // 列表项
            "//li[contains(@class,'video')]",
            "//li[contains(@class,'item')]",
            // 网格布局
            "//div[contains(@class,'videos')]//a",
            "//div[contains(@class,'grid')]//div[contains(@class,'item')]",
            // 通用回退：所有包含视频链接的元素
            "//a[contains(@href,'/video') or contains(@href,'/videos') or contains(@href,'/view')]",
        ]

        var items: [XMLElement] = []
        for xp in xpathSelectors {
            let found = doc.xpath(xp)
            let arr = Array(found)
            if arr.count >= 3 { // 至少找到3个才算有效列表
                items = arr
                print("[FullHD] 使用XPath: \(xp) 找到 \(arr.count) 项")
                break
            }
        }
        // 如果没有找到>=3的，用第一个有结果的
        if items.isEmpty {
            for xp in xpathSelectors {
                let found = doc.xpath(xp)
                let arr = Array(found)
                if !arr.isEmpty {
                    items = arr
                    print("[FullHD] 使用XPath(回退): \(xp) 找到 \(arr.count) 项")
                    break
                }
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

            // 提取标题（多种方式）
            var name = a["title"] ?? ""
            if name.isEmpty {
                name = item.xpath(".//a/@title").first?.text ?? ""
            }
            if name.isEmpty {
                name = item.xpath(".//img/@alt").first?.text ?? ""
            }
            if name.isEmpty {
                name = a.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            if name.isEmpty {
                name = item.xpath(".//*[contains(@class,'title')]/text()").first?.text?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            if name.isEmpty {
                name = item.xpath(".//h3/text() | .//h4/text() | .//h5/text()").first?.text?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            guard !name.isEmpty else { continue }

            // 增强封面图提取（支持懒加载、背景图等多种方式）
            var pic = ""
            let picSelectors = [
                // 懒加载属性（最优先）
                ".//img[contains(@class,'lazyload')]/@data-src",
                ".//img[contains(@class,'lazy')]/@data-src",
                ".//img/@data-src",
                ".//img/@data-original",
                ".//img/@data-lazy",
                ".//img/@data-url",
                // 标准src
                ".//img/@src",
                // 背景图方式
                ".//div[contains(@class,'thumb')]/@style",
                ".//div[contains(@class,'image')]/@style",
                ".//div[contains(@class,'img')]/@style",
                ".//a[contains(@class,'thumb')]/@style",
                // 兜底：从img标签获取
                ".//@data-src",
                ".//@data-original",
                ".//@src",
            ]
            for sel in picSelectors {
                if let p = item.xpath(sel).first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !p.isEmpty {
                    // 如果是 style 属性，从中提取 background-image URL
                    if sel.contains("style") {
                        if let bgURL = extractBackgroundImageURL(from: p) {
                            pic = bgURL
                            break
                        }
                    } else if !p.hasPrefix("data:") {
                        pic = p
                        break
                    }
                }
            }
            pic = normalizeURL(pic)

            // 提取时长/备注
            let duration = item.xpath(".//span[@class='duration']").first?.text?.trimmingCharacters(in: .whitespaces)
                ?? item.xpath(".//div[contains(@class,'duration')]").first?.text?.trimmingCharacters(in: .whitespaces)
                ?? item.xpath(".//span[contains(@class,'time')]").first?.text?.trimmingCharacters(in: .whitespaces)
                ?? item.xpath(".//div[contains(@class,'time')]").first?.text?.trimmingCharacters(in: .whitespaces)
                ?? item.xpath(".//span[contains(@class,'length')]").first?.text?.trimmingCharacters(in: .whitespaces)

            let normalizedHref = normalizeURL(href)

            // 去重（基于URL）
            if seen.contains(normalizedHref) { continue }
            seen.insert(normalizedHref)

            videos.append(FuliVideo(vodId: normalizedHref, vodName: name, vodPic: pic, duration: duration))
        }

        print("[FullHD] 解析到 \(videos.count) 个视频")
        return videos
    }

    // MARK: - 从 style 属性中提取背景图URL

    private func extractBackgroundImageURL(from style: String) -> String? {
        // 匹配 background-image: url('...') 或 background: url('...')
        let patterns = [
            "background-image:\\s*url\\(['\"]?([^'\")]+)['\"]?\\)",
            "background:\\s*url\\(['\"]?([^'\")]+)['\"]?\\)",
            "url\\(['\"]?([^'\")]+)['\"]?\\)",
        ]
        for pattern in patterns {
            if let groups = firstMatch(pattern: pattern, in: style), groups.count >= 2 {
                let url = groups[1].trimmingCharacters(in: .whitespaces)
                if !url.isEmpty, !url.hasPrefix("data:") {
                    return url
                }
            }
        }
        return nil
    }
}
