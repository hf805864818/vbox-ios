import Foundation
import Kanna

// MARK: - 歪比（HTML 类）
// 对应脚本：歪比.py
// 站点：wbbb1.com
// 分类路径: /type/{id}.html
class WaibiService: FuliBaseService {
    static let shared = WaibiService()

    init() {
        super.init(
            platformName: "歪比",
            defaultHosts: [
                "https://wbbb1.com",
                "https://www.wbbb1.com"
            ]
        )
    }

    override func fetchHomeContent() async -> FuliHomeResult {
        do {
            let html = try await fetchHTML("/")
            let doc = try HTML(html: html, encoding: .utf8)
            let categories = parseCategories(doc)
            let videos = parseVideoList(doc)
            return FuliHomeResult(categories: categories, videos: videos)
        } catch {
            print("[歪比] 首页失败: \(error)")
            // 返回默认分类
            let defaultCats = [
                FuliCategory(typeId: "1", typeName: "电影"),
                FuliCategory(typeId: "2", typeName: "剧集"),
                FuliCategory(typeId: "3", typeName: "动漫"),
                FuliCategory(typeId: "4", typeName: "综艺")
            ]
            return FuliHomeResult(categories: defaultCats, videos: [])
        }
    }

    override func fetchCategoryContent(category: FuliCategory, subCategory: FuliCategory?, page: Int) async -> FuliCategoryResult {
        let tid = subCategory?.typeId ?? category.typeId
        // URL格式: /type/{id}.html，分页需要进一步解析
        let path: String
        if page > 1 {
            // 尝试分页路径
            path = "/type/\(tid)-\(page).html"
        } else {
            path = "/type/\(tid).html"
        }
        do {
            let html = try await fetchHTML(path)
            let doc = try HTML(html: html, encoding: .utf8)
            let videos = parseVideoList(doc)
            return FuliCategoryResult(videos: videos, page: page, hasMore: videos.count >= 20)
        } catch {
            print("[歪比] 分类失败: \(error)")
            return FuliCategoryResult(videos: [], page: page, hasMore: false)
        }
    }

    override func fetchDetail(vodId: String) async -> FuliDetail {
        let url = vodId.hasPrefix("http") ? vodId : (currentHost + vodId)
        do {
            let html = try await fetchHTML(url)
            let doc = try HTML(html: html, encoding: .utf8)

            let title = doc.xpath("//h1[@class='title'] | //h2[@class='title']").first?.text?.trimmingCharacters(in: .whitespaces)
                ?? doc.xpath("//h1").first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            let pic = doc.xpath("//div[contains(@class,'cover')]//img/@src").first?.text
                ?? doc.xpath("//meta[@property='og:image']/@content").first?.text ?? ""
            let content = doc.xpath("//div[contains(@class,'description') or contains(@class,'summary')]").first?.text?.trimmingCharacters(in: .whitespaces)

            var episodes: [FuliEpisode] = []
            // 播放列表
            let playlist = doc.xpath("//ul[contains(@class,'playlist') or contains(@class,'play-list')]/li/a | //div[contains(@class,'playlist')]//a")
            for (idx, a) in playlist.enumerated() {
                guard let href = a["href"], !href.isEmpty else { continue }
                let name = a.text?.trimmingCharacters(in: .whitespaces) ?? "集\(idx+1)"
                let fullUrl = href.hasPrefix("http") ? href : (currentHost + href)
                episodes.append(FuliEpisode(name: name, url: fullUrl))
            }
            if episodes.isEmpty {
                    if let src = doc.xpath("//video/source/@src").first?.text ?? doc.xpath("//video/@src").first?.text, !src.isEmpty {
                        episodes.append(FuliEpisode(name: "播放", url: src))
                    } else if let iframe = doc.xpath("//iframe/@src").first?.text, !iframe.isEmpty {
                        episodes.append(FuliEpisode(name: "播放", url: iframe))
                    } else {
                        episodes.append(FuliEpisode(name: "播放", url: url))
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
        let path = "/search/\(encoded)"
        do {
            let html = try await fetchHTML(path)
            let doc = try HTML(html: html, encoding: .utf8)
            let videos = parseVideoList(doc)
            return FuliSearchResult(videos: videos, page: page, hasMore: videos.count >= 20)
        } catch {
            print("[歪比] 搜索失败: \(error)")
            return FuliSearchResult(videos: [], page: page, hasMore: false)
        }
    }

    // MARK: - 解析分类
    private func parseCategories(_ doc: HTMLDocument) -> [FuliCategory] {
        var categories: [FuliCategory] = []
        // 从脚本和导航中提取
        // 实际测试发现分类链接格式为: /type/1.html
        for a in doc.xpath("//a[contains(@href,'/type/')]") {
            guard let href = a["href"], let name = a.text?.trimmingCharacters(in: .whitespaces),
                  !href.isEmpty, !name.isEmpty, name != "更多" else { continue }
            // 提取类型ID
            if let range = href.range(of: #"/type/(\d+)"#, options: .regularExpression) {
                let typeId = String(href[range].dropFirst(6))
                // 去重
                if !categories.contains(where: { $0.typeId == typeId }) {
                    categories.append(FuliCategory(typeId: typeId, typeName: name))
                }
            }
        }
        // 如果为空使用默认
        if categories.isEmpty {
            categories = [
                FuliCategory(typeId: "1", typeName: "电影"),
                FuliCategory(typeId: "2", typeName: "剧集"),
                FuliCategory(typeId: "3", typeName: "动漫"),
                FuliCategory(typeId: "4", typeName: "综艺")
            ]
        }
        return categories
    }

    // MARK: - 解析视频列表
    private func parseVideoList(_ doc: HTMLDocument) -> [FuliVideo] {
        var videos: [FuliVideo] = []
        // 查找所有包含详情链接
        let links = doc.xpath("//a[contains(@href,'/detail/')]")
        for a in links {
            guard let href = a["href"], !href.isEmpty else { continue }
            // 提取ID
            let vidId: String
            if let range = href.range(of: #"/detail/(\d+)"#, options: .regularExpression) {
                vidId = String(href[range].dropFirst(8))
            } else {
                vidId = href
            }

            var title = a.xpath(".//img/@alt").first?.text?.trimmingCharacters(in: .whitespaces)
                ?? a.text?.trimmingCharacters(in: .whitespaces) ?? ""
            // 如果标题为空从父元素找
            if title.isEmpty {
                title = a.xpath("..//img/@alt").first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            }
            guard !title.isEmpty else { continue }

            var pic = a.xpath(".//img/@data-src").first?.text ?? a.xpath(".//img/@src").first?.text ?? ""
            if !pic.isEmpty && !pic.hasPrefix("http") {
                if pic.hasPrefix("//") {
                    pic = "https:" + pic
                } else {
                    pic = currentHost + pic
                }
            }

            let duration = a.xpath(".//span[contains(@class,'duration') or contains(@class,'time') or contains(@class,'note')]").first?.text?.trimmingCharacters(in: .whitespaces)

            videos.append(FuliVideo(vodId: vidId, vodName: title, vodPic: pic, duration: duration))
        }
        return videos
    }
}
