import Foundation
import Kanna

// MARK: - 4H 视频（HTML 类）
// 对应脚本：4H视频[成人].py
// 站点：4h05.cc 系列动态域名
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

    override func fetchHomeContent() async -> FuliHomeResult {
        do {
            let html = try await fetchHTML("/")
            let doc = try HTML(html: html, encoding: .utf8)
            let categories = parseCategories(doc)
            let videos = parseVideoList(doc, selector: "//div[@class='video-item']//a")
            return FuliHomeResult(categories: categories, videos: videos)
        } catch {
            print("[4H视频] 首页失败: \(error)")
            return .empty
        }
    }

    override func fetchCategoryContent(category: FuliCategory, subCategory: FuliCategory?, page: Int) async -> FuliCategoryResult {
        let tid = subCategory?.typeId ?? category.typeId
        let path = tid.hasPrefix("/") ? tid : "/category/\(tid)"
        let pagePath = page > 1 ? "\(path)\(path.hasSuffix("/") ? "" : "/")\(page)/" : path
        do {
            let html = try await fetchHTML(pagePath)
            let doc = try HTML(html: html, encoding: .utf8)
            let videos = parseVideoList(doc, selector: "//div[@class='video-item']//a")
            return FuliCategoryResult(videos: videos, page: page, hasMore: videos.count >= 20)
        } catch {
            print("[4H视频] 分类失败: \(error)")
            return FuliCategoryResult(videos: [], page: page, hasMore: false)
        }
    }

    override func fetchDetail(vodId: String) async -> FuliDetail {
        let url = vodId.hasPrefix("http") ? vodId : "\(currentHost)\(vodId)"
        do {
            let html = try await fetchHTML(url)
            let doc = try HTML(html: html, encoding: .utf8)
            let title = doc.xpath("//h1[@class='title']").first?.text ?? doc.xpath("//h2").first?.text ?? ""
            let pic = doc.xpath("//video/@poster").first?.text ?? doc.xpath("//div[@class='video-cover']//img/@src").first?.text ?? ""
            let content = doc.xpath("//div[@class='description']").first?.text?.trimmingCharacters(in: .whitespaces)
            let videoUrl = doc.xpath("//video/source/@src").first?.text ?? doc.xpath("//video/@src").first?.text ?? ""
            let episodes: [FuliEpisode]
            if !videoUrl.isEmpty {
                episodes = [FuliEpisode(name: "播放", url: videoUrl)]
            } else if let iframe = doc.xpath("//iframe/@src").first?.text, !iframe.isEmpty {
                episodes = [FuliEpisode(name: "播放", url: iframe)]
            } else {
                episodes = []
            }
            return FuliDetail(vodId: vodId, vodName: title, vodPic: pic, vodContent: content, playFrom: "4H视频", episodes: episodes)
        } catch {
            print("[4H视频] 详情失败: \(error)")
            return FuliDetail(vodId: vodId, vodName: "", vodPic: "", vodContent: nil, playFrom: "4H视频", episodes: [])
        }
    }

    override func fetchSearch(keyword: String, page: Int) async -> FuliSearchResult {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? keyword
        let path = page > 1 ? "/search/\(encoded)/\(page)/" : "/search/\(encoded)/"
        do {
            let html = try await fetchHTML(path)
            let doc = try HTML(html: html, encoding: .utf8)
            let videos = parseVideoList(doc, selector: "//div[@class='video-item']//a")
            return FuliSearchResult(videos: videos, page: page, hasMore: videos.count >= 20)
        } catch {
            print("[4H视频] 搜索失败: \(error)")
            return FuliSearchResult(videos: [], page: page, hasMore: false)
        }
    }

    // MARK: - 解析分类
    private func parseCategories(_ doc: HTMLDocument) -> [FuliCategory] {
        var categories: [FuliCategory] = []
        for item in doc.xpath("//ul[@class='nav-menu']/li/a | //div[@class='category-list']/ul/li/a") {
            guard let href = item["href"], let name = item.text?.trimmingCharacters(in: .whitespaces),
                  !href.isEmpty, !name.isEmpty, href != "#" else { continue }
            categories.append(FuliCategory(typeId: href, typeName: name))
        }
        if categories.isEmpty {
            categories = [
                FuliCategory(typeId: "/", typeName: "首页"),
                FuliCategory(typeId: "/category/最新/", typeName: "最新"),
                FuliCategory(typeId: "/category/热门/", typeName: "热门")
            ]
        }
        return categories
    }

    // MARK: - 解析视频列表
    private func parseVideoList(_ doc: HTMLDocument, selector: String) -> [FuliVideo] {
        var videos: [FuliVideo] = []
        for a in doc.xpath(selector) {
            guard let href = a["href"], !href.isEmpty else { continue }
            let title: String
            if let t = a.xpath(".//img/@alt").first?.text {
                title = t
            } else if let t = a.xpath(".//span[@class='title']").first?.text {
                title = t.trimmingCharacters(in: .whitespaces)
            } else {
                title = (a.text ?? "").trimmingCharacters(in: .whitespaces)
            }
            guard !title.isEmpty else { continue }
            let pic = a.xpath(".//img/@data-src").first?.text ?? a.xpath(".//img/@src").first?.text ?? ""
            let duration = a.xpath(".//span[@class='duration']").first?.text?.trimmingCharacters(in: .whitespaces)
            videos.append(FuliVideo(vodId: href, vodName: title, vodPic: pic, duration: duration))
        }
        return videos
    }
}
