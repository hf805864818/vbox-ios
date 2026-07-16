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
        let url = vodId.hasPrefix("http") ? vodId : (currentHost + vodId)
        do {
            let html = try await fetchHTML(url)
            let doc = try HTML(html: html, encoding: .utf8)

            let title = doc.xpath("//h1").first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            let pic = doc.xpath("//meta[@property='og:image']/@content").first?.text ?? ""
            let content = doc.xpath("//div[@class='video-description']").first?.text?.trimmingCharacters(in: .whitespaces)

            var episodes: [FuliEpisode] = []
            // 详情页直接就是播放页，返回页面URL供解析
            if let videoSrc = doc.xpath("//video/source/@src").first?.text, !videoSrc.isEmpty {
                episodes.append(FuliEpisode(name: "播放", url: videoSrc))
            } else if let videoSrc = doc.xpath("//video/@src").first?.text, !videoSrc.isEmpty {
                episodes.append(FuliEpisode(name: "播放", url: videoSrc))
            } else {
                // 返回页面URL供web解析
                episodes.append(FuliEpisode(name: "播放", url: url))
            }

            return FuliDetail(vodId: vodId, vodName: title, vodPic: pic, vodContent: content, playFrom: "FullHD", episodes: episodes)
        } catch {
            print("[FullHD] 详情失败: \(error)")
            return FuliDetail(vodId: vodId, vodName: "", vodPic: "", vodContent: nil, playFrom: "FullHD", episodes: [])
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

    // MARK: - 解析视频列表
    private func parseVideoList(_ doc: HTMLDocument) -> [FuliVideo] {
        var videos: [FuliVideo] = []
        // 脚本使用: div.item > a, img.lazyload[data-src], span.duration
        let items = doc.xpath("//div[contains(@class,'list-videos')]//div[contains(@class,'item')] | //div[@class='item']")
        for item in items {
            guard let a = item.xpath(".//a").first else { continue }
            let href = a["href"] ?? ""
            guard !href.isEmpty else { continue }

            var name = a["title"] ?? ""
            if name.isEmpty {
                name = item.xpath(".//a/@title").first?.text ?? ""
            }
            if name.isEmpty {
                name = a.text?.trimmingCharacters(in: .whitespaces) ?? ""
            }
            guard !name.isEmpty else { continue }

            var pic = item.xpath(".//img[contains(@class,'lazyload')]/@data-src").first?.text
                ?? item.xpath(".//img/@data-src").first?.text
                ?? item.xpath(".//img/@src").first?.text ?? ""
            if !pic.isEmpty && !pic.hasPrefix("http") {
                if pic.hasPrefix("//") {
                    pic = "https:" + pic
                } else {
                    pic = currentHost + pic
                }
            }

            let duration = item.xpath(".//span[@class='duration']").first?.text?.trimmingCharacters(in: .whitespaces)

            videos.append(FuliVideo(vodId: href, vodName: name, vodPic: pic, duration: duration))
        }
        return videos
    }
}
