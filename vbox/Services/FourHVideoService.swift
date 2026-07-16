import Foundation
import Kanna

// MARK: - 4H 视频（HTML 类）
// 对应脚本：4H视频[成人].py
// 站点：4h05.cc / 4h04.cc / 4h03.cc
// 分类为硬编码，URL格式: /vod/type/id/{tid}/page/{pg}.html 或 /index.php/vod/...
class FourHVideoService: FuliBaseService {
    static let shared = FourHVideoService()

    init() {
        super.init(
            platformName: "4H视频",
            defaultHosts: [
                "https://4h05.cc",
                "https://4h04.cc",
                "https://4h03.cc"
            ]
        )
    }

    // MARK: - 自定义 Session（允许自签名证书）

    private let _sessionDelegate = _FourHSessionDelegate()
    private lazy var _customSession: URLSession = {
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
        return URLSession(configuration: c, delegate: _sessionDelegate, delegateQueue: nil)
    }()

    var session: URLSession { _customSession }

    func defaultHeaders(host: String) -> [String: String] {
        [
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Connection": "keep-alive",
            "Cache-Control": "no-cache",
            "Origin": host,
            "Referer": "\(host)/"
        ]
    }

    // MARK: - 硬编码分类（从脚本提取）
    private let hardcodedCategories: [(String, String)] = [
        ("传媒厂商", "20"), ("麻豆传媒", "21"), ("91制片", "22"),
        ("蜜桃传媒", "23"), ("天美传媒", "24"), ("精东影片", "25"),
        ("星空传媒", "26"), ("葫芦影业", "27"), ("糖心VLOG", "28"),
        ("精品推荐", "29"), ("日本无码", "30"), ("日本有码", "31"),
        ("AV解说", "32"), ("中文有码", "33"), ("中文无码", "34"),
        ("日韩极品", "35"), ("日韩无码", "36"), ("少女萝莉", "37"),
        ("水嫩萝莉", "38"), ("极品主播", "40"), ("卡通动漫", "43"),
        ("SM调教", "44"), ("探花合集", "50"), ("91大神", "51"),
        ("台湾萝莉", "54"), ("萝莉传媒", "55"), ("白虎口爆", "57"),
        ("嫩女网爆", "47"), ("嫩逼乌鸡", "42"), ("三级伦理", "45"),
        ("萝莉互口", "46"), ("黑料网爆", "48"), ("野战车震", "52"),
        ("萝莉黑瓜", "53"), ("萝莉巨乳", "58"), ("明星换脸", "73"),
        ("萝莉抠逼", "56"), ("国产大作", "39"), ("欧美萝莉", "41"),
        ("热门事件", "49"), ("少女3P", "59"), ("偷拍萝莉", "60"),
        ("强奸少女", "61"), ("重口猎奇", "62"), ("制服萝控", "63"),
        ("极品少女", "64"), ("明星爆料", "65"), ("X短视频", "66"),
        ("AV明星", "67"), ("极品萝莉", "68"), ("人妻艹妈", "69"),
        ("VR视角", "70"), ("角色扮演", "71"), ("男同男娘", "72")
    ]

    override func fetchHomeContent() async -> FuliHomeResult {
        // 分类使用硬编码
        let categories = hardcodedCategories.map {
            FuliCategory(typeId: $0.1, typeName: $0.0)
        }

        // 尝试获取首页推荐视频
        var videos: [FuliVideo] = []
        do {
            let html = try await fetchHTML("/")
            let doc = try HTML(html: html, encoding: .utf8)
            videos = parseVideoList(doc)
        } catch {
            print("[4H视频] 首页视频失败: \(error)")
        }

        return FuliHomeResult(categories: categories, videos: videos)
    }

    override func fetchCategoryContent(category: FuliCategory, subCategory: FuliCategory?, page: Int) async -> FuliCategoryResult {
        let tid = subCategory?.typeId ?? category.typeId
        // 支持多种URL格式：/vod/type/id/{tid}/page/{pg}.html 和 /index.php/vod/type/id/{tid}/page/{pg}.html
        let vodPath = page > 1 ? "/vod/type/id/\(tid)/page/\(page).html" : "/vod/type/id/\(tid).html"
        let indexPath = page > 1 ? "/index.php/vod/type/id/\(tid)/page/\(page).html" : "/index.php/vod/type/id/\(tid).html"
        let paths = [vodPath, indexPath]

        for path in paths {
            do {
                let html = try await fetchHTML(path)
                let doc = try HTML(html: html, encoding: .utf8)
                let videos = parseVideoList(doc)
                if !videos.isEmpty {
                    print("[4H视频] 分类解析成功: \(path)")
                    return FuliCategoryResult(videos: videos, page: page, hasMore: videos.count >= 20)
                }
            } catch {
                print("[4H视频] 分类尝试失败 \(path): \(error)")
            }
        }
        print("[4H视频] 分类全部失败")
        return FuliCategoryResult(videos: [], page: page, hasMore: false)
    }

    override func fetchDetail(vodId: String) async -> FuliDetail {
        // 支持多种URL格式：/vod/detail/id/{id}.html 和 /index.php/vod/detail/id/{id}.html
        let vodPath = "/vod/detail/id/\(vodId).html"
        let indexPath = "/index.php/vod/detail/id/\(vodId).html"
        let paths = [vodPath, indexPath]

        for path in paths {
            do {
                let html = try await fetchHTML(path)
                let doc = try HTML(html: html, encoding: .utf8)

                let title = doc.xpath("//title").first?.text?
                    .replacingOccurrences(of: " - 四虎视频", with: "")
                    .replacingOccurrences(of: " - 4H视频", with: "")
                    .trimmingCharacters(in: .whitespaces) ?? ""
                let pic = doc.xpath("//meta[@property='og:image']/@content").first?.text ?? ""
                let desc = doc.xpath("//meta[@name='description']/@content").first?.text

                // 获取播放源和剧集
                var episodes: [FuliEpisode] = []
                let playSources = doc.xpath("//div[@class='module-play-list']/div")
                for (sourceIdx, source) in playSources.enumerated() {
                    let sourceName = source.xpath(".//span/text()").first?.text?.trimmingCharacters(in: .whitespaces) ?? "线路\(sourceIdx+1)"
                    let episodeLinks = source.xpath(".//a")
                    for (epIdx, a) in episodeLinks.enumerated() {
                        guard let href = a["href"], !href.isEmpty else { continue }
                        let epName = a.text?.trimmingCharacters(in: .whitespaces) ?? "第\(epIdx+1)集"
                        let fullUrl = href.hasPrefix("http") ? href : (currentHost + href)
                        episodes.append(FuliEpisode(name: "\(sourceName)-\(epName)", url: fullUrl))
                    }
                }

                // 如果没有找到播放源，使用默认方式
                if episodes.isEmpty {
                    let playPageUrl = "\(currentHost)/vod/play/id/\(vodId)/sid/1/nid/1.html"
                    episodes.append(FuliEpisode(name: "第1集", url: playPageUrl))
                }

                if !episodes.isEmpty {
                    print("[4H视频] 详情解析成功: \(path)")
                    return FuliDetail(vodId: vodId, vodName: title, vodPic: pic, vodContent: desc, playFrom: "4H视频", episodes: episodes)
                }
            } catch {
                print("[4H视频] 详情尝试失败 \(path): \(error)")
            }
        }
        print("[4H视频] 详情全部失败")
        return FuliDetail(vodId: vodId, vodName: "", vodPic: "", vodContent: nil, playFrom: "4H视频", episodes: [])
    }

    override func fetchSearch(keyword: String, page: Int) async -> FuliSearchResult {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        // 支持多种URL格式：/vod/search/page/{pg}/wd/{wd}.html 和 /index.php/vod/search/page/{pg}/wd/{wd}.html
        let vodPath = "/vod/search/page/\(page)/wd/\(encoded).html"
        let indexPath = "/index.php/vod/search/page/\(page)/wd/\(encoded).html"
        let paths = [vodPath, indexPath]

        for path in paths {
            do {
                let html = try await fetchHTML(path)
                let doc = try HTML(html: html, encoding: .utf8)
                let videos = parseVideoList(doc)
                if !videos.isEmpty {
                    print("[4H视频] 搜索解析成功: \(path)")
                    return FuliSearchResult(videos: videos, page: page, hasMore: videos.count >= 20)
                }
            } catch {
                print("[4H视频] 搜索尝试失败 \(path): \(error)")
            }
        }
        print("[4H视频] 搜索全部失败")
        return FuliSearchResult(videos: [], page: page, hasMore: false)
    }

    // MARK: - 播放地址解析（重写基类方法）

    override func fetchPlayerURL(episode: FuliEpisode) async -> FuliPlayerResult {
        let url = episode.url

        // 如果已经是直接的视频URL，直接返回
        if url.contains(".m3u8") || url.contains(".mp4") || url.contains(".ts") {
            let normalized = normalizeURL(url)
            print("[4H视频] 直接视频URL: \(normalized.prefix(80))")
            return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: currentHost), parse: 0)
        }

        do {
            // 策略1：访问播放页，从HTML中直接提取视频URL
            let pageURL = normalizeURL(url)
            let html = try await fetchHTML(pageURL)

            // 策略1.1：直接从 video/source 标签提取
            if let videoURL = extractVideoURL(from: html) {
                let normalized = normalizeURL(videoURL)
                print("[4H视频] 策略1成功 - 从video标签解析: \(normalized.prefix(80))")
                return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: currentHost), parse: 0)
            }

            // 策略2：从 iframe 中提取播放地址
            if let iframeURL = extractIframeURL(from: html) {
                print("[4H视频] 策略2 - 发现iframe: \(iframeURL.prefix(80))")
                do {
                    let iframeHTML = try await fetchHTML(iframeURL)
                    if let videoURL = extractVideoURL(from: iframeHTML) {
                        let normalized = normalizeURL(videoURL, base: iframeURL)
                        print("[4H视频] 策略2成功 - 从iframe解析: \(normalized.prefix(80))")
                        return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: currentHost), parse: 0)
                    }
                    // iframe 中也可能还有 iframe，再深入一层
                    if let innerIframeURL = extractIframeURL(from: iframeHTML) {
                        let innerFull = normalizeURL(innerIframeURL, base: iframeURL)
                        do {
                            let innerHTML = try await fetchHTML(innerFull)
                            if let videoURL = extractVideoURL(from: innerHTML) {
                                let normalized = normalizeURL(videoURL, base: innerFull)
                                print("[4H视频] 策略2.2成功 - 从二级iframe解析: \(normalized.prefix(80))")
                                return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: currentHost), parse: 0)
                            }
                        } catch {
                            print("[4H视频] 二级iframe请求失败: \(error)")
                        }
                    }
                } catch {
                    print("[4H视频] iframe请求失败: \(error)")
                }
            }

            // 策略3：从JavaScript中提取播放URL（player_data / player_url等）
            if let jsURL = extractPlayURLFromJS(from: html) {
                let normalized = normalizeURL(jsURL)
                print("[4H视频] 策略3成功 - 从JS解析: \(normalized.prefix(80))")
                return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: currentHost), parse: 0)
            }

            // 策略4：回退到WebView解析
            print("[4H视频] 所有策略失败，回退到WebView解析")
            return FuliPlayerResult(url: pageURL, headers: defaultHeaders(host: currentHost), parse: 1)

        } catch {
            print("[4H视频] fetchPlayerURL 失败: \(error)")
            return FuliPlayerResult(url: url, headers: defaultHeaders(host: currentHost), parse: 1)
        }
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
            "//video[contains(@class,'video')]/@src",
            "//source/@src",
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

    // MARK: - 辅助方法：从JavaScript中提取播放URL

    private func extractPlayURLFromJS(from html: String) -> String? {
        let patterns = [
            // player_data JSON
            "var\\s+player_data\\s*=\\s*(\\{[^;]+\\})",
            "player_data\\s*=\\s*(\\{[^;]+\\})",
            // player_url 变量
            "var\\s+player_url\\s*=\\s*['\"]([^'\"]+)['\"]",
            "player_url\\s*=\\s*['\"]([^'\"]+)['\"]",
            // video_url / src 变量
            "var\\s+video_url\\s*=\\s*['\"]([^'\"]+)['\"]",
            "video_url\\s*=\\s*['\"]([^'\"]+)['\"]",
            // JSON 中的 url 字段
            "\"url\"\\s*:\\s*\"([^\"]+\\.m3u8[^\"]*)\"",
            "\"url\"\\s*:\\s*\"([^\"]+\\.mp4[^\"]*)\"",
            "'url'\\s*:\\s*'([^']+\\.m3u8[^']*)'",
            "'url'\\s*:\\s*'([^']+\\.mp4[^']*)'",
            // m3u8/mp4 直接URL
            "(https?://[^\"'\\s<>]+\\.m3u8[^\"'\\s<>]*)",
            "(https?://[^\"'\\s<>]+\\.mp4[^\"'\\s<>]*)",
            "(/[^\"'\\s<>]+\\.m3u8[^\"'\\s<>]*)",
            "(/[^\"'\\s<>]+\\.mp4[^\"'\\s<>]*)",
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
        return nil
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

    // MARK: - 解析视频列表
    private func parseVideoList(_ doc: HTMLDocument) -> [FuliVideo] {
        var videos: [FuliVideo] = []
        var seen: Set<String> = []

        // 多个 XPath 回退选择器
        let xpathSelectors = [
            // 原选择器：thumbnail-group
            "//ul[contains(@class,'thumbnail-group')]/li",
            // 常见视频列表容器
            "//div[contains(@class,'video') or contains(@class,'item') or contains(@class,'card') or contains(@class,'module-item')]",
            // 通用列表项
            "//ul[contains(@class,'video') or contains(@class,'list') or contains(@class,'items')]/li",
            // 详情链接
            "//a[contains(@href,'/detail/') or contains(@href,'/vod/')]",
        ]

        for xpath in xpathSelectors {
            let items = doc.xpath(xpath)
            for item in items {
                do {
                    // 提取名称
                    var name = ""
                    let nameSelectors = [
                        ".//h5/a/text()", ".//h4/a/text()", ".//h3/a/text()",
                        ".//a[contains(@class,'title')]/text()",
                        ".//*[contains(@class,'title')]/text()",
                        ".//a/text()",
                    ]
                    for sel in nameSelectors {
                        if let t = item.xpath(sel).first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !t.isEmpty {
                            name = t
                            break
                        }
                    }
                    guard !name.isEmpty else { continue }

                    // 提取封面图
                    var pic = ""
                    let picSelectors = [
                        ".//img/@data-original", ".//img/@data-src",
                        ".//img/@src", ".//@data-original", ".//@data-src",
                    ]
                    for sel in picSelectors {
                        if let p = item.xpath(sel).first?.text?.trimmingCharacters(in: .whitespaces),
                           !p.isEmpty, !p.hasPrefix("data:") {
                            pic = p
                            break
                        }
                    }
                    if !pic.isEmpty && !pic.hasPrefix("http") {
                        if pic.hasPrefix("//") {
                            pic = "https:" + pic
                        } else if pic.hasPrefix("/") {
                            pic = currentHost + pic
                        } else {
                            pic = currentHost + "/" + pic
                        }
                    }

                    // 提取链接
                    var href = ""
                    let hrefSelectors = [
                        ".//a[@class='thumbnail']/@href",
                        ".//a[contains(@href,'/detail/')]/@href",
                        ".//a[contains(@href,'/vod/')]/@href",
                        ".//a/@href",
                    ]
                    for sel in hrefSelectors {
                        if let h = item.xpath(sel).first?.text?.trimmingCharacters(in: .whitespaces),
                           !h.isEmpty {
                            href = h
                            break
                        }
                    }
                    guard !href.isEmpty else { continue }

                    // 从URL中提取ID
                    let vid = href.split(separator: "/").last?.replacingOccurrences(of: ".html", with: "") ?? href

                    // 去重
                    if seen.contains(vid) { continue }
                    seen.insert(vid)

                    // 提取备注/时长
                    var remark: String? = nil
                    let remarkSelectors = [
                        ".//span[@class='title']/text()",
                        ".//*[contains(@class,'duration')]/text()",
                        ".//*[contains(@class,'remark')]/text()",
                        ".//span/text()",
                    ]
                    for sel in remarkSelectors {
                        if let r = item.xpath(sel).first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !r.isEmpty {
                            remark = r
                            break
                        }
                    }

                    videos.append(FuliVideo(vodId: vid, vodName: name, vodPic: pic, duration: remark))
                }
            }
            if !videos.isEmpty { break }
        }
        return videos
    }
}

// MARK: - URLSession Delegate（允许自签名证书）

class _FourHSessionDelegate: NSObject, URLSessionDelegate {
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
