import Foundation
import Kanna

// MARK: - 4H 视频（HTML 类）
// 对应脚本：4H视频[成人].py
// 站点：www.sihuhu.xyz（四虎视频）
// 分类为硬编码，URL格式: /vod/type/id/{tid}/page/{pg}.html
class FourHVideoService: FuliBaseService {
    static let shared = FourHVideoService()

    init() {
        super.init(
            platformName: "4H视频",
            defaultHosts: [
                "https://www.sihuhu.xyz",
                "https://sihuhu.xyz"
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
        // URL格式: /vod/type/id/{tid}/page/{pg}.html
        let path = page > 1 ? "/vod/type/id/\(tid)/page/\(page).html" : "/vod/type/id/\(tid).html"
        do {
            let html = try await fetchHTML(path)
            let doc = try HTML(html: html, encoding: .utf8)
            let videos = parseVideoList(doc)
            return FuliCategoryResult(videos: videos, page: page, hasMore: videos.count >= 20)
        } catch {
            print("[4H视频] 分类失败: \(error)")
            return FuliCategoryResult(videos: [], page: page, hasMore: false)
        }
    }

    override func fetchDetail(vodId: String) async -> FuliDetail {
        // URL格式: /vod/detail/id/{tid}.html
        let path = "/vod/detail/id/\(vodId).html"
        do {
            let html = try await fetchHTML(path)
            let doc = try HTML(html: html, encoding: .utf8)

            let title = doc.xpath("//title").first?.text?
                .replacingOccurrences(of: " - 四虎视频", with: "")
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

            return FuliDetail(vodId: vodId, vodName: title, vodPic: pic, vodContent: desc, playFrom: "4H视频", episodes: episodes)
        } catch {
            print("[4H视频] 详情失败: \(error)")
            return FuliDetail(vodId: vodId, vodName: "", vodPic: "", vodContent: nil, playFrom: "4H视频", episodes: [])
        }
    }

    override func fetchSearch(keyword: String, page: Int) async -> FuliSearchResult {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let path = "/vod/search/page/\(page)/wd/\(encoded).html"
        do {
            let html = try await fetchHTML(path)
            let doc = try HTML(html: html, encoding: .utf8)
            let videos = parseVideoList(doc)
            return FuliSearchResult(videos: videos, page: page, hasMore: videos.count >= 20)
        } catch {
            print("[4H视频] 搜索失败: \(error)")
            return FuliSearchResult(videos: [], page: page, hasMore: false)
        }
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
