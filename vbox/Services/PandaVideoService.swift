import Foundation

// MARK: - 熊猫视频（API 接口类型）
// 对应脚本：熊猫视频[成人].py
// 站点：spiderscloudcn2.51111666.com / spiderscloudcn1.51111666.com
class PandaVideoService: FuliBaseService {
    static let shared = PandaVideoService()

    init() {
        super.init(
            platformName: "熊猫视频",
            defaultHosts: [
                "https://spiderscloudcn2.51111666.com",
                "https://spiderscloudcn1.51111666.com"
            ]
        )
    }

    // MARK: - 域名/站点配置
    private var siteInfo: PandaSiteInfo?

    // MARK: - 接口调用
    private func api(_ path: String, params: [String: String] = [:]) async throws -> Data {
        var components = URLComponents(string: "\(currentHost)\(path)")!
        if !params.isEmpty {
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        defaultHeaders(host: currentHost).forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - 加载站点配置
    private func loadSiteInfo() async -> PandaSiteInfo? {
        if let info = siteInfo { return info }
        do {
            let data = try await api("/api/getDataInit")
            let decoded = try JSONDecoder().decode(PandaSiteInfo.self, from: data)
            siteInfo = decoded
            return decoded
        } catch {
            print("[熊猫视频] 加载站点配置失败: \(error)")
            return nil
        }
    }

    override func fetchHomeContent() async -> FuliHomeResult {
        guard let info = await loadSiteInfo() else { return .empty }

        // 分类
        var categories: [FuliCategory] = []
        for cate in info.data.class_list {
            var subs: [FuliCategory]?
            if let children = cate.sub_list, !children.isEmpty {
                subs = children.map { FuliCategory(typeId: "\($0.id)", typeName: $0.name) }
            }
            categories.append(FuliCategory(typeId: "\(cate.id)", typeName: cate.name, subCategories: subs))
        }

        // 首页推荐视频
        var videos: [FuliVideo] = []
        do {
            let data = try await api("/api/getVideoList", params: ["size": "24"])
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let list = dataObj["list"] as? [[String: Any]] {
                videos = list.compactMap { parseVideoItem($0) }
            }
        } catch {
            print("[熊猫视频] 首页视频失败: \(error)")
        }
        return FuliHomeResult(categories: categories, videos: videos)
    }

    override func fetchCategoryContent(category: FuliCategory, subCategory: FuliCategory?, page: Int) async -> FuliCategoryResult {
        let cateId = subCategory?.typeId ?? category.typeId
        do {
            let data = try await api("/api/getVideoList", params: [
                "size": "24",
                "page": "\(page)",
                "class_id": cateId
            ])
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let list = dataObj["list"] as? [[String: Any]] {
                let videos = list.compactMap { parseVideoItem($0) }
                return FuliCategoryResult(videos: videos, page: page, hasMore: videos.count >= 24)
            }
        } catch {
            print("[熊猫视频] 分类失败: \(error)")
        }
        return FuliCategoryResult(videos: [], page: page, hasMore: false)
    }

    override func fetchDetail(vodId: String) async -> FuliDetail {
        do {
            let data = try await api("/api/getVideoInfo", params: ["id": vodId])
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let info = dataObj["info"] as? [String: Any] {
                let name = info["title"] as? String ?? info["name"] as? String ?? ""
                let pic = info["image"] as? String ?? info["cover"] as? String ?? ""
                let content = info["description"] as? String ?? info["intro"] as? String
                let url = info["url"] as? String ?? info["video_url"] as? String ?? ""
                let episodes: [FuliEpisode]
                if let urls = info["urls"] as? [[String: String]], !urls.isEmpty {
                    episodes = urls.enumerated().compactMap { idx, item in
                        guard let u = item["url"] ?? item["video"], !u.isEmpty else { return nil }
                        return FuliEpisode(name: item["name"] ?? "集\(idx+1)", url: u)
                    }
                } else if !url.isEmpty {
                    episodes = [FuliEpisode(name: "播放", url: url)]
                } else {
                    episodes = []
                }
                return FuliDetail(vodId: vodId, vodName: name, vodPic: pic, vodContent: content, playFrom: "熊猫视频", episodes: episodes)
            }
        } catch {
            print("[熊猫视频] 详情失败: \(error)")
        }
        return FuliDetail(vodId: vodId, vodName: "", vodPic: "", vodContent: nil, playFrom: "熊猫视频", episodes: [])
    }

    override func fetchSearch(keyword: String, page: Int) async -> FuliSearchResult {
        do {
            let data = try await api("/api/getSearchVideo", params: [
                "keyword": keyword,
                "page": "\(page)",
                "size": "24"
            ])
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let list = dataObj["list"] as? [[String: Any]] {
                let videos = list.compactMap { parseVideoItem($0) }
                return FuliSearchResult(videos: videos, page: page, hasMore: videos.count >= 24)
            }
        } catch {
            print("[熊猫视频] 搜索失败: \(error)")
        }
        return FuliSearchResult(videos: [], page: page, hasMore: false)
    }

    // MARK: - 解析视频条目
    private func parseVideoItem(_ item: [String: Any]) -> FuliVideo? {
        guard let id = item["id"] as? Int else { return nil }
        let name = item["title"] as? String ?? item["name"] as? String ?? ""
        guard !name.isEmpty else { return nil }
        let pic = item["image"] as? String ?? item["cover"] as? String ?? ""
        let duration = item["duration"] as? String
        let score = item["score"] as? String
        return FuliVideo(vodId: "\(id)", vodName: name, vodPic: pic, duration: duration, score: score)
    }
}

// MARK: - 熊猫视频数据模型
private struct PandaSiteInfo: Codable {
    let data: PandaData
}

private struct PandaData: Codable {
    let class_list: [PandaCate]
}

private struct PandaCate: Codable {
    let id: Int
    let name: String
    let sub_list: [PandaSubCate]?
}

private struct PandaSubCate: Codable {
    let id: Int
    let name: String
}
