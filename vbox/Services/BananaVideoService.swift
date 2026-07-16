import Foundation
import Kanna

// MARK: - 香蕉视频（HTML 类，与香蕉秀不同源）
// 对应脚本：香蕉视频[成人].py
// 站点：618013.xyz 系列
// 分类ID格式: "{domain}_{id}"，URL: /index.php/vod/type/id/{id}.html
// 标题需要XOR 128解密
class BananaVideoService: FuliBaseService {
    static let shared = BananaVideoService()

    // 主域名（从脚本提取）
    private var mainDomain: String { "618013.xyz" }

    init() {
        super.init(
            platformName: "香蕉视频",
            defaultHosts: [
                "https://618013.xyz",
                "https://618012.xyz",
                "https://618011.xyz",
                "https://618010.xyz",
                "https://618009.xyz"
            ]
        )
    }

    // MARK: - 硬编码分类（从脚本提取，type_id格式: domain_id）
    private let hardcodedCategories: [(name: String, typeId: String)] = [
        ("全部视频", "618013.xyz_1"),
        ("香蕉精品", "618013.xyz_13"),
        ("制服诱惑", "618013.xyz_22"),
        ("国产视频", "618013.xyz_6"),
        ("清纯少女", "618013.xyz_8"),
        ("辣妹大奶", "618013.xyz_9"),
        ("女同专属", "618013.xyz_10"),
        ("素人出演", "618013.xyz_11"),
        ("角色扮演", "618013.xyz_12"),
        ("人妻熟女", "618013.xyz_20"),
        ("日韩剧情", "618013.xyz_23"),
        ("经典伦理", "618013.xyz_21"),
        ("成人动漫", "618013.xyz_7"),
        ("精品二区", "618013.xyz_14"),
        ("精品三区", "618013.xyz_40"),
        ("动漫中字", "618013.xyz_53"),
        ("日本无码", "618013.xyz_52"),
        ("中文字幕", "618013.xyz_33"),
        ("国产传媒", "618013.xyz_44"),
        ("国产自拍", "618013.xyz_32")
    ]

    override func fetchHomeContent() async -> FuliHomeResult {
        let categories = hardcodedCategories.map {
            FuliCategory(typeId: $0.typeId, typeName: $0.name)
        }

        var videos: [FuliVideo] = []
        do {
            let html = try await fetchHTML("/")
            let doc = try HTML(html: html, encoding: .utf8)
            videos = parseVideoList(doc)
        } catch {
            print("[香蕉视频] 首页视频失败: \(error)")
        }

        return FuliHomeResult(categories: categories, videos: videos)
    }

    override func fetchCategoryContent(category: FuliCategory, subCategory: FuliCategory?, page: Int) async -> FuliCategoryResult {
        let tid = subCategory?.typeId ?? category.typeId
        // 解析 type_id: domain_typeId
        let parts = tid.components(separatedBy: "_")
        let domain = parts.count > 1 ? parts[0] : mainDomain
        let typeId = parts.count > 1 ? parts[1] : tid

        // URL格式: https://{domain}/index.php/vod/type/id/{type_id}.html
        let categoryHost = "https://\(domain)"
        let path = page > 1
            ? "/index.php/vod/type/id/\(typeId)/page/\(page).html"
            : "/index.php/vod/type/id/\(typeId).html"

        do {
            let html = try await fetchHTMLFromHost(categoryHost, path: path)
            let doc = try HTML(html: html, encoding: .utf8)
            let videos = parseVideoList(doc, domain: domain)
            return FuliCategoryResult(videos: videos, page: page, hasMore: videos.count >= 20)
        } catch {
            print("[香蕉视频] 分类失败: \(error)")
            return FuliCategoryResult(videos: [], page: page, hasMore: false)
        }
    }

    override func fetchDetail(vodId: String) async -> FuliDetail {
        // vodId格式: domain_id 或 纯id
        let parts = vodId.components(separatedBy: "_")
        let domain = parts.count > 1 ? parts[0] : mainDomain
        let videoId = parts.count > 1 ? parts[1] : vodId

        let detailHost = "https://\(domain)"
        let path = "/index.php/vod/detail/id/\(videoId).html"
        let detailURL = detailHost + path

        do {
            let html = try await fetchHTMLFromHost(detailHost, path: path)
            let doc = try HTML(html: html, encoding: .utf8)

            let title = doc.xpath("//h1/text() | //title/text()").first?.text?
                .trimmingCharacters(in: .whitespaces) ?? ""
            var pic = doc.xpath("//div[@class='dyimg']//img/@src | //img[@class='poster']/@src | //div[contains(@class,'pic')]//img/@src").first?.text ?? ""
            pic = normalizeURL(pic, base: detailHost)
            let desc = doc.xpath("//div[@class='yp_context']/text() | //div[@class='introduction']//text() | //div[contains(@class,'content')]//text()").first?.text?
                .trimmingCharacters(in: .whitespaces)

            // 获取播放源 - 多级回退
            var episodes: [FuliEpisode] = []

            // 1. 先尝试直接从详情页提取播放URL（JS变量等）
            if let directURL = extractPlayURL(from: html, base: detailHost) {
                episodes.append(FuliEpisode(name: "播放", url: directURL))
            }

            // 2. 从 video/iframe 标签提取
            if episodes.isEmpty {
                let srcXpaths = [
                    "//video/@src", "//video/source/@src",
                    "//iframe/@src", "//iframe[contains(@id,'player')]/@src"
                ]
                for xp in srcXpaths {
                    if let src = doc.xpath(xp).first?.text, !src.isEmpty {
                        let normalized = normalizeURL(src, base: detailHost)
                        episodes.append(FuliEpisode(name: "播放", url: normalized))
                        break
                    }
                }
            }

            // 3. 解析播放链接（跳转到播放页）
            if episodes.isEmpty {
                // 尝试多种播放链接选择器
                let linkXpaths = [
                    "//a[contains(@href, 'm=')]",
                    "//a[contains(@href, '/vod/play/')]",
                    "//a[contains(@href, 'play/id')]",
                    "//div[contains(@class,'playlist')]//a",
                    "//ul[contains(@class,'episodes')]//a",
                    "//a[contains(@class,'play')]"
                ]
                var playLinks: [XMLElement] = []
                for xp in linkXpaths {
                    let found = doc.xpath(xp)
                    let arr = Array(found)
                    if !arr.isEmpty {
                        playLinks = arr
                        break
                    }
                }
                for link in playLinks {
                    let epTitle = link.text?.trimmingCharacters(in: .whitespaces) ?? "第\(episodes.count + 1)集"
                    let epHref = link["href"] ?? ""
                    if !epHref.isEmpty {
                        let playPageURL = normalizeURL(epHref, base: detailHost)
                        episodes.append(FuliEpisode(name: epTitle, url: playPageURL))
                    }
                }
            }

            // 4. 最后的回退：构造播放页URL
            if episodes.isEmpty {
                let playPageURL = detailHost + "/index.php/vod/play/id/\(videoId).html"
                episodes.append(FuliEpisode(name: "第1集", url: playPageURL))
            }

            return FuliDetail(vodId: vodId, vodName: title, vodPic: pic, vodContent: desc, playFrom: "香蕉视频", episodes: episodes)
        } catch {
            print("[香蕉视频] 详情失败: \(error)")
            return FuliDetail(vodId: vodId, vodName: "", vodPic: "", vodContent: nil, playFrom: "香蕉视频", episodes: [])
        }
    }

    func fetchPlayerURL(episode: FuliEpisode) async -> FuliPlayerResult {
        let url = episode.url
        let parts = url.components(separatedBy: "_")
        let domain = parts.count > 1 ? "https://\(parts[0])" : currentHost

        // 如果已经是直接的视频URL，直接返回
        if url.contains(".m3u8") || url.contains(".mp4") || url.contains(".ts") {
            let normalized = normalizeURL(url, base: domain)
            return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: domain), parse: 0)
        }

        // 需要访问播放页解析出实际播放地址
        do {
            let pageURL = url.hasPrefix("http") ? url : normalizeURL(url, base: domain)
            let html: String
            if pageURL.hasPrefix(currentHost) {
                html = try await fetchHTML(pageURL)
            } else {
                // 从URL中提取host
                if let urlObj = URL(string: pageURL), let host = urlObj.host {
                    let path = pageURL.replacingOccurrences(of: "https://\(host)", with: "")
                        .replacingOccurrences(of: "http://\(host)", with: "")
                    html = try await fetchHTMLFromHost("https://\(host)", path: path)
                } else {
                    html = try await fetchHTML(pageURL)
                }
            }

            // 多级回退提取播放URL
            if let playURL = extractPlayURL(from: html, base: pageURL) {
                let normalized = normalizeURL(playURL, base: pageURL)
                print("[香蕉视频] 解析到播放地址: \(normalized.prefix(100))")
                return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: currentHost), parse: 0)
            }

            // 尝试用 Kanna 解析标签
            let doc = try HTML(html: html, encoding: .utf8)
            let srcXpaths = [
                "//video/@src", "//video/source/@src",
                "//iframe/@src", "//iframe[contains(@id,'player')]/@src",
                "//source/@src"
            ]
            for xp in srcXpaths {
                if let src = doc.xpath(xp).first?.text, !src.isEmpty {
                    let normalized = normalizeURL(src, base: pageURL)
                    // 如果是 iframe，还需要进一步递归解析
                    if normalized.contains("iframe") || (!normalized.contains(".m3u8") && !normalized.contains(".mp4")) {
                        // 尝试访问 iframe 的内容
                        do {
                            let iframeHTML = try await fetchHTML(normalized)
                            if let innerURL = extractPlayURL(from: iframeHTML, base: normalized) {
                                let finalURL = normalizeURL(innerURL, base: normalized)
                                return FuliPlayerResult(url: finalURL, headers: defaultHeaders(host: currentHost), parse: 0)
                            }
                        } catch {
                            print("[香蕉视频] iframe 解析失败: \(error)")
                        }
                    }
                    return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: currentHost), parse: normalized.contains(".m3u8") || normalized.contains(".mp4") ? 0 : 1)
                }
            }

            // 最后回退
            print("[香蕉视频] 未解析到播放地址，回退到Web解析")
            return FuliPlayerResult(url: pageURL, headers: defaultHeaders(host: currentHost), parse: 1)
        } catch {
            print("[香蕉视频] fetchPlayerURL 失败: \(error)")
            return FuliPlayerResult(url: url, headers: defaultHeaders(host: currentHost), parse: 1)
        }
    }

    override func fetchSearch(keyword: String, page: Int) async -> FuliSearchResult {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let path = "/index.php/vod/search.html?wd=\(encoded)&page=\(page)"
        do {
            let html = try await fetchHTML(path)
            let doc = try HTML(html: html, encoding: .utf8)
            let videos = parseVideoList(doc)
            return FuliSearchResult(videos: videos, page: page, hasMore: videos.count >= 20)
        } catch {
            print("[香蕉视频] 搜索失败: \(error)")
            return FuliSearchResult(videos: [], page: page, hasMore: false)
        }
    }

    // MARK: - 从指定域名获取HTML
    private func fetchHTMLFromHost(_ host: String, path: String) async throws -> String {
        let urlStr = host + (path.hasPrefix("/") ? path : "/\(path)")
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        defaultHeaders(host: host).forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        return html
    }

    // MARK: - 提取播放ID
    private func extractPlayId(_ href: String) -> String {
        if let range = href.range(of: #"m=(\d+)"#, options: .regularExpression) {
            return String(href[range].dropFirst(2))
        }
        return ""
    }

    // MARK: - XOR 128 标题解密
    private func decryptTitle(_ encrypted: String) -> String {
        var decrypted: [Character] = []
        for char in encrypted {
            if let code = char.unicodeScalars.first?.value {
                decrypted.append(Character(UnicodeScalar(code ^ 128)!))
            } else {
                decrypted.append(char)
            }
        }
        return String(decrypted)
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
        if baseHost.hasSuffix("/") {
            return baseHost + result
        }
        return baseHost + "/" + result
    }

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

    // MARK: - 从 HTML 中提取播放 URL（多级回退）
    private func extractPlayURL(from html: String, base: String? = nil) -> String? {
        // 1. player_data / player_info JSON
        let jsonPatterns = [
            "var\\s+player_data\\s*=\\s*(\\{[^;]+\\})",
            "var\\s+player_info\\s*=\\s*(\\{[^;]+\\})",
            "var\\s+player_url\\s*=\\s*['\"]([^'\"]+)['\"]",
            "player_data\\s*=\\s*(\\{[^;]+\\})",
            "player_info\\s*=\\s*(\\{[^;]+\\})"
        ]
        for pattern in jsonPatterns {
            if let groups = firstMatch(pattern: pattern, in: html), groups.count >= 2 {
                let captured = groups[1]
                if captured.hasPrefix("{") {
                    if let data = captured.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        // 尝试多种字段
                        if let url = (json["url"] as? String ?? json["video_url"] as? String ?? json["src"] as? String ?? json["play_url"] as? String ?? json["video"] as? String),
                           !url.isEmpty {
                            return url
                        }
                    }
                } else {
                    return captured
                }
            }
        }

        // 2. 从 JavaScript 中提取 mac_player_data / ckplayer_data 等
        let macPatterns = [
            "mac_player_data\\s*=\\s*['\"]([^'\"]+)['\"]",
            "ckplayer\\s*=\\s*['\"]([^'\"]+)['\"]",
            "\"url\"\\s*:\\s*\"([^\"]+\\.(?:m3u8|mp4|ts)[^\"]*)\"",
            "'url'\\s*:\\s*'([^']+\\.(?:m3u8|mp4|ts)[^']*)'"
        ]
        for pattern in macPatterns {
            if let groups = firstMatch(pattern: pattern, in: html), groups.count >= 2 {
                return groups[1]
            }
        }

        // 3. 直接 m3u8/mp4 URL
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

    // MARK: - 解析视频列表
    private func parseVideoList(_ doc: HTMLDocument, domain: String? = nil) -> [FuliVideo] {
        var videos: [FuliVideo] = []
        let currentDomain = domain ?? mainDomain
        let baseHost = "https://\(currentDomain)"
        // 多种 XPath 回退
        let xpaths = [
            "//a[@class='vodbox']",
            "//div[contains(@class,'vodlist')]//a",
            "//li[contains(@class,'video')]//a",
            "//div[contains(@class,'item')]//a",
            "//a[contains(@href,'/vod/detail/')]"
        ]
        var elements: [XMLElement] = []
        for xp in xpaths {
            let found = doc.xpath(xp)
            if found.first != nil {
                elements = found.toArray()
                break
            }
        }
        for elem in elements {
            guard let link = elem["href"], !link.isEmpty else { continue }

            // 提取vod_id
            let playId = extractPlayId(link)
            let vodId = !playId.isEmpty ? "\(currentDomain)_\(playId)" : "\(currentDomain)_\(link.hashValue % 1000000)"

            // 提取标题（需要解密）
            var title = ""
            let titleElem = elem.xpath("./p[@class='km-script']/text()")
            if titleElem.first != nil, let encrypted = titleElem.first?.text, !encrypted.isEmpty {
                title = decryptTitle(encrypted)
            }
            if title.isEmpty {
                // 尝试其他选择器
                for sel in [".//p[contains(@class,'script')]/text()", ".//p/text()", ".//h3/text()", ".//h4/text()", ".//span/text()", ".//img/@alt"] {
                    if let t = elem.xpath(sel).first?.text, !t.isEmpty {
                        title = decryptTitle(t)
                        if title.isEmpty {
                            title = t.trimmingCharacters(in: .whitespaces)
                        }
                        break
                    }
                }
            }
            guard !title.isEmpty else { continue }

            // 提取封面
            var pic = elem.xpath(".//img/@data-original").first?.text
                ?? elem.xpath(".//img/@data-src").first?.text
                ?? elem.xpath(".//img/@src").first?.text ?? ""
            pic = normalizeURL(pic, base: baseHost)

            videos.append(FuliVideo(vodId: vodId, vodName: title, vodPic: pic))
        }
        return videos
    }
}
