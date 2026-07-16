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
        // 脚本使用: //ul[@class="thumbnail-group clearfix"]/li
        let items = doc.xpath("//ul[contains(@class,'thumbnail-group')]/li")
        for li in items {
            do {
                guard let name = li.xpath(".//h5/a/text()").first?.text?.trimmingCharacters(in: .whitespaces),
                      !name.isEmpty else { continue }

                var pic = li.xpath(".//img/@data-original").first?.text ?? ""
                if !pic.isEmpty && !pic.hasPrefix("http") {
                    pic = currentHost + pic
                }

                guard let href = li.xpath(".//a[@class='thumbnail']/@href").first?.text,
                      !href.isEmpty else { continue }

                // 从URL中提取ID
                let vid = href.split(separator: "/").last?.replacingOccurrences(of: ".html", with: "") ?? href

                let remark = li.xpath(".//span[@class='title']/text()").first?.text?.trimmingCharacters(in: .whitespaces)

                videos.append(FuliVideo(vodId: vid, vodName: name, vodPic: pic, duration: remark))
            }
        }
        return videos
    }
}
