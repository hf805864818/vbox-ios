import Foundation
import Kanna

// MARK: - 香蕉视频（HTML 类，与香蕉秀不同源）
// 对应脚本：香蕉视频[成人].py
// 站点：618013.xyz 系列
class BananaVideoService: FuliBaseService {
    static let shared = BananaVideoService()

    init() {
        super.init(
            platformName: "香蕉视频",
            defaultHosts: [
                "https://618013.xyz",
                "https://618012.xyz",
                "https://618011.xyz"
            ]
        )
    }

    override func fetchHomeContent() async -> FuliHomeResult {
        do {
            let html = try await fetchHTML("/")
            let doc = try HTML(html: html, encoding: .utf8)
            let categories = parseCategories(doc)
            let videos = parseVideoList(doc, selector: "//div[contains(@class,'video-item')]//a | //div[contains(@class,'item')]//a")
            return FuliHomeResult(categories: categories, videos: videos)
        } catch {
            print("[香蕉视频] 首页失败: \(error)")
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
            let videos = parseVideoList(doc, selector: "//div[contains(@class,'video-item')]//a | //div[contains(@class,'item')]//a")
            return FuliCategoryResult(videos: videos, page: page, hasMore: videos.count >= 24)
        } catch {
            print("[香蕉视频] 分类失败: \(error)")
            return FuliCategoryResult(videos: [], page: page, hasMore: false)
        }
    }

    override func fetchDetail(vodId: String) async -> FuliDetail {
        let url = vodId.hasPrefix("http") ? vodId : "\(currentHost)\(vodId)"
        do {
            let html = try await fetchHTML(url)
            let doc = try HTML(html: html, encoding: .utf8)
            let title = doc.xpath("//h1").first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            let pic = doc.xpath("//meta[@property='og:image']/@content").first?.text
                ?? doc.xpath("//div[@class='video-cover']//img/@src").first?.text ?? ""
            let content = doc.xpath("//div[@class='video-description'] | //div[@class='summary']").first?.text?.trimmingCharacters(in: .whitespaces)

            var episodes: [FuliEpisode] = []
            // 播放列表
            let playlist = doc.xpath("//ul[contains(@class,'playlist') or contains(@class,'episode-list')]/li/a")
            for (idx, a) in playlist.enumerated() {
                guard let href = a["href"], !href.isEmpty else { continue }
                let name = a.text?.trimmingCharacters(in: .whitespaces) ?? "集\(idx+1)"
                episodes.append(FuliEpisode(name: name, url: href))
            }
            if episodes.isEmpty {
                if let src = doc.xpath("//video/source/@src").first?.text ?? doc.xpath("//video/@src").first?.text, !src.isEmpty {
                    episodes.append(FuliEpisode(name: "播放", url: src))
                } else if let iframe = doc.xpath("//iframe/@src").first?.text, !iframe.isEmpty {
                    episodes.append(FuliEpisode(name: "播放", url: iframe))
                } else {
                    let pattern = #"(https?://[^\"'\s]+\.(?:m3u8|mp4|ts))"#
                    if let regex = try? NSRegularExpression(pattern: pattern),
                       let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                       let range = Range(match.range(at: 1), in: html) {
                        episodes.append(FuliEpisode(name: "播放", url: String(html[range])))
                    }
                }
            }
            return FuliDetail(vodId: vodId, vodName: title, vodPic: pic, vodContent: content, playFrom: "香蕉视频", episodes: episodes)
        } catch {
            print("[香蕉视频] 详情失败: \(error)")
            return FuliDetail(vodId: vodId, vodName: "", vodPic: "", vodContent: nil, playFrom: "香蕉视频", episodes: [])
        }
    }

    override func fetchSearch(keyword: String, page: Int) async -> FuliSearchResult {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let path = page > 1 ? "/search?k=\(encoded)&page=\(page)" : "/search?k=\(encoded)"
        do {
            let html = try await fetchHTML(path)
            let doc = try HTML(html: html, encoding: .utf8)
            let videos = parseVideoList(doc, selector: "//div[contains(@class,'video-item')]//a | //div[contains(@class,'item')]//a")
            return FuliSearchResult(videos: videos, page: page, hasMore: videos.count >= 24)
        } catch {
            print("[香蕉视频] 搜索失败: \(error)")
            return FuliSearchResult(videos: [], page: page, hasMore: false)
        }
    }

    private func parseCategories(_ doc: HTMLDocument) -> [FuliCategory] {
        var categories: [FuliCategory] = []
        for a in doc.xpath("//ul[@class='nav-menu']/li/a | //nav//ul/li/a") {
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
                ?? a.xpath(".//div[@class='title'] | .//span[@class='title'] | .//h2 | .//h3").first?.text?.trimmingCharacters(in: .whitespaces)
                ?? a.text?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !title.isEmpty else { continue }
            let pic = a.xpath(".//img/@data-src").first?.text ?? a.xpath(".//img/@src").first?.text ?? ""
            let duration = a.xpath(".//span[@class='duration'] | .//span[@class='time']").first?.text?.trimmingCharacters(in: .whitespaces)
            videos.append(FuliVideo(vodId: href, vodName: title, vodPic: pic, duration: duration))
        }
        return videos
    }
}
