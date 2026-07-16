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

        do {
            let html = try await fetchHTMLFromHost(detailHost, path: path)
            let doc = try HTML(html: html, encoding: .utf8)

            let title = doc.xpath("//h1/text() | //title/text()").first?.text?
                .trimmingCharacters(in: .whitespaces) ?? ""
            var pic = doc.xpath("//div[@class='dyimg']//img/@src | //img[@class='poster']/@src").first?.text ?? ""
            if pic.hasPrefix("/") {
                pic = detailHost + pic
            }
            let desc = doc.xpath("//div[@class='yp_context']/text() | //div[@class='introduction']//text()").first?.text?
                .trimmingCharacters(in: .whitespaces)

            // 获取播放源
            var episodes: [FuliEpisode] = []
            let playLinks = doc.xpath("//a[contains(@href, 'm=')]")
            for link in playLinks {
                let epTitle = link.text?.trimmingCharacters(in: .whitespaces) ?? ""
                let epHref = link["href"] ?? ""
                let playId = extractPlayId(epHref)
                if !playId.isEmpty {
                    episodes.append(FuliEpisode(name: epTitle, url: playId))
                }
            }

            if episodes.isEmpty {
                episodes.append(FuliEpisode(name: "第1集", url: videoId))
            }

            return FuliDetail(vodId: vodId, vodName: title, vodPic: pic, vodContent: desc, playFrom: "香蕉视频", episodes: episodes)
        } catch {
            print("[香蕉视频] 详情失败: \(error)")
            return FuliDetail(vodId: vodId, vodName: "", vodPic: "", vodContent: nil, playFrom: "香蕉视频", episodes: [])
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

    // MARK: - 解析视频列表
    private func parseVideoList(_ doc: HTMLDocument, domain: String? = nil) -> [FuliVideo] {
        var videos: [FuliVideo] = []
        let currentDomain = domain ?? mainDomain
        // 脚本使用: //a[@class="vodbox"]
        let elements = doc.xpath("//a[@class='vodbox']")
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
                for sel in [".//p[contains(@class,'script')]/text()", ".//p/text()", ".//h3/text()", ".//h4/text()"] {
                    if let t = elem.xpath(sel).first?.text, !t.isEmpty {
                        title = decryptTitle(t)
                        break
                    }
                }
            }
            guard !title.isEmpty else { continue }

            // 提取封面
            var pic = elem.xpath(".//img/@data-original").first?.text
                ?? elem.xpath(".//img/@src").first?.text ?? ""
            if !pic.isEmpty {
                if pic.hasPrefix("//") {
                    pic = "https:" + pic
                } else if pic.hasPrefix("/") {
                    pic = "https://\(currentDomain)" + pic
                }
            }

            videos.append(FuliVideo(vodId: vodId, vodName: title, vodPic: pic))
        }
        return videos
    }
}
