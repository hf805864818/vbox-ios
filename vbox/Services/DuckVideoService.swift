import Foundation
import Kanna

// MARK: - 小鸭子看看（HTML 类）
// 对应脚本：小鸭子看看[成人].py
// 站点：tw.xiaoyakankan.com
// 分类为硬编码(5大分类)，URL格式: /cat/{tid}.html
class DuckVideoService: FuliBaseService {
    static let shared = DuckVideoService()

    init() {
        super.init(
            platformName: "小鸭子看看",
            defaultHosts: [
                "https://tw.xiaoyakankan.com",
                "https://xiaoyakankan.com",
                "https://www.xiaoyakankan.com"
            ]
        )
    }

    // MARK: - 硬编码分类（从脚本提取，含子分类）
    private let categoryData: [(name: String, id: String, subs: [(name: String, id: String)])] = [
        ("电影", "10", [
            ("全部", "10"), ("动作片", "1001"), ("喜剧片", "1002"), ("爱情片", "1003"),
            ("科幻片", "1004"), ("恐怖片", "1005"), ("剧情片", "1006"), ("战争片", "1007"),
            ("纪录片", "1008"), ("微电影", "1009"), ("动漫电影", "1010"), ("奇幻片", "1011"),
            ("动画片", "1013"), ("犯罪片", "1014"), ("悬疑片", "1016"), ("欧美片", "1017"),
            ("邵氏电影", "1019"), ("同性片", "1021"), ("家庭片", "1024"), ("古装片", "1025"),
            ("历史片", "1026"), ("4K电影", "1027")
        ]),
        ("连续剧", "11", [
            ("全部", "11"), ("国产剧", "1101"), ("香港剧", "1102"), ("台湾剧", "1105"),
            ("韩国剧", "1103"), ("欧美剧", "1104"), ("日本剧", "1106"), ("泰国剧", "1108"),
            ("港台剧", "1110"), ("日韩剧", "1111"), ("东南亚剧", "1112"), ("海外剧", "1107")
        ]),
        ("综艺", "12", [
            ("全部", "12"), ("内地综艺", "1201"), ("港台综艺", "1202"),
            ("日韩综艺", "1203"), ("欧美综艺", "1204"), ("国外综艺", "1205")
        ]),
        ("动漫", "13", [
            ("全部", "13"), ("国产动漫", "1301"), ("日韩动漫", "1302"),
            ("欧美动漫", "1303"), ("海外动漫", "1305"), ("里番", "1307")
        ]),
        ("福利", "15", [
            ("全部", "15"), ("韩国情色片", "1551"), ("日本情色片", "1552"),
            ("大陆情色片", "1555"), ("香港情色片", "1553"), ("台湾情色片", "1554"),
            ("美国情色片", "1556"), ("欧洲情色片", "1557"), ("印度情色片", "1558"),
            ("东南亚情色片", "1559"), ("其它情色片", "1550")
        ])
    ]

    override func fetchHomeContent() async -> FuliHomeResult {
        // 构建分类（带子分类）
        let categories = categoryData.map { cat in
            let subs = cat.subs.map {
                FuliCategory(typeId: $0.id, typeName: $0.name)
            }
            return FuliCategory(typeId: cat.id, typeName: cat.name, subCategories: subs)
        }

        // 首页推荐视频
        var videos: [FuliVideo] = []
        do {
            let html = try await fetchHTML("/")
            let doc = try HTML(html: html, encoding: .utf8)
            videos = parseVideoList(doc)
        } catch {
            print("[小鸭子看看] 首页视频失败: \(error)")
        }

        return FuliHomeResult(categories: categories, videos: videos)
    }

    override func fetchCategoryContent(category: FuliCategory, subCategory: FuliCategory?, page: Int) async -> FuliCategoryResult {
        // 使用子分类ID或主分类ID
        let tid = subCategory?.typeId ?? category.typeId
        // URL格式: /cat/{tid}.html 或 /cat/{tid}-{pg}.html
        let path = page > 1 ? "/cat/\(tid)-\(page).html" : "/cat/\(tid).html"
        do {
            let html = try await fetchHTML(path)
            let doc = try HTML(html: html, encoding: .utf8)
            let videos = parseVideoList(doc)
            return FuliCategoryResult(videos: videos, page: page, hasMore: videos.count >= 20)
        } catch {
            print("[小鸭子看看] 分类失败: \(error)")
            return FuliCategoryResult(videos: [], page: page, hasMore: false)
        }
    }

    override func fetchDetail(vodId: String) async -> FuliDetail {
        // URL格式: /post/{vod_id}.html
        let path = "/post/\(vodId).html"
        do {
            let html = try await fetchHTML(path)
            let doc = try HTML(html: html, encoding: .utf8)

            let title = doc.xpath("//title").first?.text?
                .replacingOccurrences(of: " - 小鴨看看", with: "")
                .trimmingCharacters(in: .whitespaces) ?? ""
            var pic = doc.xpath("//img/@data-poster").first?.text ?? ""
            if pic.hasPrefix("//") {
                pic = "https:" + pic
            }
            let desc = doc.xpath("//meta[@name='description']/@content").first?.text?.trimmingCharacters(in: .whitespaces)

            // 从JavaScript中提取播放信息
            var episodes: [FuliEpisode] = []
            let ppPattern = #"var pp\s*=\s*(\{.*?\});"#
            if let regex = try? NSRegularExpression(pattern: ppPattern, options: .dotMatchesLineSeparators),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let jsonStr = String(html[range])
                if let jsonData = jsonStr.data(using: .utf8),
                   let pp = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let lines = pp["lines"] as? [[Any]] {
                    for (lineIdx, line) in lines.enumerated() {
                        if line.count > 3, let urls = line[3] as? [String] {
                            for (epIdx, url) in urls.enumerated() {
                                if url.contains(".m3u8") || url.contains(".mp4") || url.contains(".flv") {
                                    let epName = lines.count > 1 ? "线路\(lineIdx+1)-集\(epIdx+1)" : "集\(epIdx+1)"
                                    episodes.append(FuliEpisode(name: epName, url: url))
                                }
                            }
                        }
                    }
                }
            }

            if episodes.isEmpty {
                episodes.append(FuliEpisode(name: "播放", url: path))
            }

            return FuliDetail(vodId: vodId, vodName: title, vodPic: pic, vodContent: desc, playFrom: "小鸭子看看", episodes: episodes)
        } catch {
            print("[小鸭子看看] 详情失败: \(error)")
            return FuliDetail(vodId: vodId, vodName: "", vodPic: "", vodContent: nil, playFrom: "小鸭子看看", episodes: [])
        }
    }

    override func fetchSearch(keyword: String, page: Int) async -> FuliSearchResult {
        // 脚本使用Google搜索，这里尝试站内搜索
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let path = "/search?q=\(encoded)"
        do {
            let html = try await fetchHTML(path)
            let doc = try HTML(html: html, encoding: .utf8)
            let videos = parseVideoList(doc)
            return FuliSearchResult(videos: videos, page: page, hasMore: videos.count >= 20)
        } catch {
            print("[小鸭子看看] 搜索失败: \(error)")
            return FuliSearchResult(videos: [], page: page, hasMore: false)
        }
    }

    // MARK: - 解析视频列表
    private func parseVideoList(_ doc: HTMLDocument) -> [FuliVideo] {
        var videos: [FuliVideo] = []
        // 脚本使用正则匹配: <a class="link" href="(/post/[^"]+\.html)"
        // 也可以用XPath: //a[@class='link']
        let items = doc.xpath("//a[@class='link']")
        for a in items {
            guard let href = a["href"], !href.isEmpty else { continue }
            // 提取vod_id
            let vidId: String
            if let range = href.range(of: #"/post/([^/]+)\.html"#, options: .regularExpression) {
                vidId = String(href[range].dropFirst(6).dropLast(5))
            } else {
                vidId = href
            }

            // 提取标题
            var title = a.xpath(".//img/@alt").first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            if title.isEmpty {
                title = a["title"] ?? ""
            }
            if title.isEmpty {
                title = a.text?.trimmingCharacters(in: .whitespaces) ?? ""
            }
            guard !title.isEmpty else { continue }

            // 提取图片
            var pic = a.xpath(".//img/@data-src").first?.text ?? a.xpath(".//img/@src").first?.text ?? ""
            if !pic.isEmpty {
                if pic.hasPrefix("//") {
                    pic = "https:" + pic
                } else if !pic.hasPrefix("http") {
                    pic = currentHost + pic
                }
            }

            // 备注
            let tag1 = a.xpath(".//div[contains(@class,'tag1')]").first?.text?.trimmingCharacters(in: .whitespaces)
            let tag2 = a.xpath(".//div[contains(@class,'tag2')]").first?.text?.trimmingCharacters(in: .whitespaces)
            let remark = [tag1, tag2].compactMap { $0 }.joined(separator: " / ")

            videos.append(FuliVideo(vodId: vidId, vodName: title, vodPic: pic, duration: remark))
        }
        return videos
    }
}
