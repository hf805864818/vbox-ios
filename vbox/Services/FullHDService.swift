import Foundation
import Kanna

// MARK: - FullHD（HTML 类）
// 对应脚本：FullHD[成人].py
// 站点：fullhd.cc 系列
class FullHDService: FuliBaseService {
    static let shared = FullHDService()

    init() {
        super.init(
            platformName: "FullHD",
            defaultHosts: [
                "https://fullhd.cc",
                "https://fullhd.tv",
                "https://fullhd.me"
            ]
        )
    }

    override func fetchHomeContent() async -> FuliHomeResult {
        do {
            let html = try await fetchHTML("/")
            let doc = try HTML(html: html, encoding: .utf8)
            let categories = parseCategories(doc)
            let videos = parseVideoList(doc, selector: "//div[contains(@class,'video-block')]//a")
            return FuliHomeResult(categories: categories, videos: videos)
        } catch {
            print("[FullHD] 首页失败: \(error)")
            return .empty
        }
    }

    override func fetchCategoryContent(category: FuliCategory, subCategory: FuliCategory?, page: Int) async -> FuliCategoryResult {
        let tid = subCategory?.typeId ?? category.typeId
        let path: String
        if tid.hasPrefix("/") {
            path = page > 1 ? "\(tid)page/\(page)/" : tid
        } else {
            path = page > 1 ? "/category/\(tid)/page/\(page)/" : "/category/\(tid)/"
        }
        do {
            let html = try await fetchHTML(path)
            let doc = try HTML(html: html, encoding: .utf8)
            let videos = parseVideoList(doc, selector: "//div[contains(@class,'video-block')]//a")
            return FuliCategoryResult(videos: videos, page: page, hasMore: videos.count >= 20)
        } catch {
            print("[FullHD] 分类失败: \(error)")
            return FuliCategoryResult(videos: [], page: page, hasMore: false)
        }
    }

    override func fetchDetail(vodId: String) async -> FuliDetail {
        let url = vodId.hasPrefix("http") ? vodId : "\(currentHost)\(vodId)"
        do {
            let html = try await fetchHTML(url)
            let doc = try HTML(html: html, encoding: .utf8)
            let title = doc.xpath("//h1").first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            let pic = doc.xpath("//meta[@property='og:image']/@content").first?.text ?? ""
            let content = doc.xpath("//div[@class='video-description']").first?.text?.trimmingCharacters(in: .whitespaces)
            var episodes: [FuliEpisode] = []
            if let src = doc.xpath("//video/source/@src").first?.text, !src.isEmpty {
                episodes.append(FuliEpisode(name: "播放", url: src))
            } else if let src = doc.xpath("//video/@src").first?.text, !src.isEmpty {
                episodes.append(FuliEpisode(name: "播放", url: src))
            } else if let iframe = doc.xpath("//iframe/@src").first?.text, !iframe.isEmpty {
                episodes.append(FuliEpisode(name: "播放", url: iframe))
            }
            return FuliDetail(vodId: vodId, vodName: title, vodPic: pic, vodContent: content, playFrom: "FullHD", episodes: episodes)
        } catch {
            print("[FullHD] 详情失败: \(error)")
            return FuliDetail(vodId: vodId, vodName: "", vodPic: "", vodContent: nil, playFrom: "FullHD", episodes: [])
        }
    }

    override func fetchSearch(keyword: String, page: Int) async -> FuliSearchResult {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let path = page > 1 ? "/search/?s=\(encoded)&page=\(page)" : "/search/?s=\(encoded)"
        do {
            let html = try await fetchHTML(path)
            let doc = try HTML(html: html, encoding: .utf8)
            let videos = parseVideoList(doc, selector: "//div[contains(@class,'video-block')]//a")
            return FuliSearchResult(videos: videos, page: page, hasMore: videos.count >= 20)
        } catch {
            print("[FullHD] 搜索失败: \(error)")
            return FuliSearchResult(videos: [], page: page, hasMore: false)
        }
    }

    private func parseCategories(_ doc: HTMLDocument) -> [FuliCategory] {
        var categories: [FuliCategory] = []
        for a in doc.xpath("//ul[@class='nav-menu']/li/a | //div[@class='category-menu']/a") {
            guard let href = a["href"], let name = a.text?.trimmingCharacters(in: .whitespaces),
                  !href.isEmpty, !name.isEmpty, href != "#" else { continue }
            categories.append(FuliCategory(typeId: href, typeName: name))
        }
        if categories.isEmpty {
            categories = [
                FuliCategory(typeId: "/", typeName: "首页"),
                FuliCategory(typeId: "/category/new/", typeName: "最新"),
                FuliCategory(typeId: "/category/hot/", typeName: "热门")
            ]
        }
        return categories
    }

    private func parseVideoList(_ doc: HTMLDocument, selector: String) -> [FuliVideo] {
        var videos: [FuliVideo] = []
        for a in doc.xpath(selector) {
            guard let href = a["href"], !href.isEmpty else { continue }
            let title = a.xpath(".//img/@alt").first?.text?.trimmingCharacters(in: .whitespaces)
                ?? a.xpath(".//div[@class='name']").first?.text?.trimmingCharacters(in: .whitespaces)
                ?? a.text?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !title.isEmpty else { continue }
            let pic = a.xpath(".//img/@data-src").first?.text ?? a.xpath(".//img/@src").first?.text ?? ""
            let duration = a.xpath(".//span[@class='duration']").first?.text?.trimmingCharacters(in: .whitespaces)
            let score = a.xpath(".//span[@class='rate']").first?.text?.trimmingCharacters(in: .whitespaces)
            videos.append(FuliVideo(vodId: href, vodName: title, vodPic: pic, duration: duration, score: score))
        }
        return videos
    }
}
