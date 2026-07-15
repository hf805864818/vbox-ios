import Foundation
import Kanna

// MARK: - 歪比（HTML 类）
// 对应脚本：歪比.py
// 站点：waibi.com / waibi.tv
class WaibiService: FuliBaseService {
    static let shared = WaibiService()

    init() {
        super.init(
            platformName: "歪比",
            defaultHosts: [
                "https://waibi.com",
                "https://waibi.tv",
                "https://waibi.net"
            ]
        )
    }

    override func fetchHomeContent() async -> FuliHomeResult {
        do {
            let html = try await fetchHTML("/")
            let doc = try HTML(html: html, encoding: .utf8)
            let categories = parseCategories(doc)
            let videos = parseVideoList(doc, selector: "//div[contains(@class,'video-item')]//a | //div[contains(@class,'vod-item')]//a")
            return FuliHomeResult(categories: categories, videos: videos)
        } catch {
            print("[歪比] 首页失败: \(error)")
            return .empty
        }
    }

    override func fetchCategoryContent(category: FuliCategory, subCategory: FuliCategory?, page: Int) async -> FuliCategoryResult {
        let tid = subCategory?.typeId ?? category.typeId
        let path: String
        if tid.hasPrefix("/") {
            path = page > 1 ? "\(tid)page/\(page)/" : tid
        } else {
            path = page > 1 ? "/vodtype/\(tid)-\(page).html" : "/vodtype/\(tid).html"
        }
        do {
            let html = try await fetchHTML(path)
            let doc = try HTML(html: html, encoding: .utf8)
            let videos = parseVideoList(doc, selector: "//div[contains(@class,'video-item')]//a | //div[contains(@class,'vod-item')]//a")
            return FuliCategoryResult(videos: videos, page: page, hasMore: videos.count >= 24)
        } catch {
            print("[歪比] 分类失败: \(error)")
            return FuliCategoryResult(videos: [], page: page, hasMore: false)
        }
    }

    override func fetchDetail(vodId: String) async -> FuliDetail {
        let url = vodId.hasPrefix("http") ? vodId : "\(currentHost)\(vodId)"
        do {
            let html = try await fetchHTML(url)
            let doc = try HTML(html: html, encoding: .utf8)
            let title = doc.xpath("//h1[@class='title'] | //h2[@class='title']").first?.text?.trimmingCharacters(in: .whitespaces)
                ?? doc.xpath("//h1").first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            let pic = doc.xpath("//div[contains(@class,'cover')]//img/@src").first?.text
                ?? doc.xpath("//meta[@property='og:image']/@content").first?.text ?? ""
            let content = doc.xpath("//div[contains(@class,'description') or contains(@class,'summary')]").first?.text?.trimmingCharacters(in: .whitespaces)

            var episodes: [FuliEpisode] = []
            // 优先解析 <ul class="playlist"> 中的链接
            let playlist = doc.xpath("//ul[contains(@class,'playlist') or contains(@class,'play-list')]/li/a")
            for (idx, a) in playlist.enumerated() {
                guard let href = a["href"], !href.isEmpty else { continue }
                let name = a.text?.trimmingCharacters(in: .whitespaces) ?? "集\(idx+1)"
                episodes.append(FuliEpisode(name: name, url: href))
            }
            // 备选：video 标签
            if episodes.isEmpty {
                if let src = doc.xpath("//video/source/@src").first?.text ?? doc.xpath("//video/@src").first?.text, !src.isEmpty {
                    episodes.append(FuliEpisode(name: "播放", url: src))
                } else if let iframe = doc.xpath("//iframe/@src").first?.text, !iframe.isEmpty {
                    episodes.append(FuliEpisode(name: "播放", url: iframe))
                }
            }
            return FuliDetail(vodId: vodId, vodName: title, vodPic: pic, vodContent: content, playFrom: "歪比", episodes: episodes)
        } catch {
            print("[歪比] 详情失败: \(error)")
            return FuliDetail(vodId: vodId, vodName: "", vodPic: "", vodContent: nil, playFrom: "歪比", episodes: [])
        }
    }

    override func fetchSearch(keyword: String, page: Int) async -> FuliSearchResult {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let path = page > 1 ? "/vodsearch/\(encoded)-\(page).html" : "/vodsearch/\(encoded).html"
        do {
            let html = try await fetchHTML(path)
            let doc = try HTML(html: html, encoding: .utf8)
            let videos = parseVideoList(doc, selector: "//div[contains(@class,'video-item')]//a | //div[contains(@class,'vod-item')]//a")
            return FuliSearchResult(videos: videos, page: page, hasMore: videos.count >= 24)
        } catch {
            print("[歪比] 搜索失败: \(error)")
            return FuliSearchResult(videos: [], page: page, hasMore: false)
        }
    }

    private func parseCategories(_ doc: HTMLDocument) -> [FuliCategory] {
        var categories: [FuliCategory] = []
        for a in doc.xpath("//ul[contains(@class,'nav-menu') or contains(@class,'navbar-nav')]/li/a") {
            guard let href = a["href"], let name = a.text?.trimmingCharacters(in: .whitespaces),
                  !href.isEmpty, !name.isEmpty, href != "#" else { continue }
            categories.append(FuliCategory(typeId: href, typeName: name))
        }
        if categories.isEmpty {
            categories = [
                FuliCategory(typeId: "/", typeName: "首页"),
                FuliCategory(typeId: "1", typeName: "电影"),
                FuliCategory(typeId: "2", typeName: "电视剧")
            ]
        }
        return categories
    }

    private func parseVideoList(_ doc: HTMLDocument, selector: String) -> [FuliVideo] {
        var videos: [FuliVideo] = []
        for a in doc.xpath(selector) {
            guard let href = a["href"], !href.isEmpty else { continue }
            let title = a.xpath(".//img/@alt").first?.text?.trimmingCharacters(in: .whitespaces)
                ?? a.xpath(".//div[@class='title'] | .//span[@class='title']").first?.text?.trimmingCharacters(in: .whitespaces)
                ?? a.text?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !title.isEmpty else { continue }
            let pic = a.xpath(".//img/@data-src").first?.text ?? a.xpath(".//img/@src").first?.text ?? ""
            let duration = a.xpath(".//span[@class='duration'] | .//span[@class='time']").first?.text?.trimmingCharacters(in: .whitespaces)
            videos.append(FuliVideo(vodId: href, vodName: title, vodPic: pic, duration: duration))
        }
        return videos
    }
}
