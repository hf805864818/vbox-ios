import Foundation

// MARK: - 熊猫视频（API 接口类型）
// 对应脚本：熊猫视频[成人].py
// 站点：spiderscloudcn2.51111666.com
// 使用 POST 请求，接口: /getDataInit (分类), /forward (视频列表/详情/搜索)
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

    // MARK: - POST API 调用
    private func postAPI(_ path: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: "\(currentHost)\(path)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        defaultHeaders(host: currentHost).forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - 首页分类 + 推荐
    override func fetchHomeContent() async -> FuliHomeResult {
        // 1. 获取分类
        var categories: [FuliCategory] = []
        do {
            let data = try await postAPI("/getDataInit", body: ["name": "John", "age": 31, "city": "New York"])
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let menu0ListMap = dataObj["menu0ListMap"] as? [[String: Any]] {

                // 从脚本逻辑：筛选 typeName 为 "传媒"、"视频"、"电影" 的一级分类
                for item in menu0ListMap {
                    guard let typeName = item["typeName"] as? String else { continue }
                    if typeName == "传媒" || typeName == "视频" || typeName == "电影" {
                        if let menu2List = item["menu2List"] as? [[String: Any]] {
                            for item1 in menu2List {
                                if let tid = item1["typeId2"] as? String,
                                   let tname = item1["typeName2"] as? String {
                                    categories.append(FuliCategory(typeId: tid, typeName: tname))
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            print("[熊猫视频] 获取分类失败: \(error)")
        }

        // 如果分类为空，使用默认分类
        if categories.isEmpty {
            categories = [
                FuliCategory(typeId: "24", typeName: "精品推荐"),
                FuliCategory(typeId: "21", typeName: "麻豆传媒"),
                FuliCategory(typeId: "22", typeName: "91制片"),
                FuliCategory(typeId: "23", typeName: "蜜桃传媒"),
                FuliCategory(typeId: "30", typeName: "日本无码"),
                FuliCategory(typeId: "31", typeName: "日本有码")
            ]
        }

        // 2. 获取首页推荐视频
        var videos: [FuliVideo] = []
        do {
            let body: [String: Any] = [
                "command": "WEB_GET_INFO",
                "pageNumber": 1,
                "RecordsPage": 20,
                "typeId": "24",
                "typeMid": "1",
                "languageType": "CN",
                "content": ""
            ]
            let data = try await postAPI("/forward", body: body)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let list = dataObj["resultList"] as? [[String: Any]] {
                videos = list.compactMap { parseVideoItem($0) }
            }
        } catch {
            print("[熊猫视频] 首页视频失败: \(error)")
        }

        return FuliHomeResult(categories: categories, videos: videos)
    }

    // MARK: - 分类内容
    override func fetchCategoryContent(category: FuliCategory, subCategory: FuliCategory?, page: Int) async -> FuliCategoryResult {
        let tid = subCategory?.typeId ?? category.typeId
        do {
            let body: [String: Any] = [
                "command": "WEB_GET_INFO",
                "pageNumber": page,
                "RecordsPage": 20,
                "typeId": tid,
                "typeMid": "1",
                "languageType": "CN",
                "content": ""
            ]
            let data = try await postAPI("/forward", body: body)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let list = dataObj["resultList"] as? [[String: Any]] {
                let videos = list.compactMap { parseVideoItem($0) }
                return FuliCategoryResult(videos: videos, page: page, hasMore: videos.count >= 20)
            }
        } catch {
            print("[熊猫视频] 分类失败: \(error)")
        }
        return FuliCategoryResult(videos: [], page: page, hasMore: false)
    }

    // MARK: - 详情
    override func fetchDetail(vodId: String) async -> FuliDetail {
        // vodId 格式: "id#serverId"
        let parts = vodId.components(separatedBy: "#")
        let cid = parts.first ?? vodId
        let svid = parts.count > 1 ? parts[1] : ""

        do {
            // 先获取站点配置（用于 macVodLinkMap）
            var linkMap: [String: [String: String]] = [:]
            do {
                let initData = try await postAPI("/getDataInit", body: ["name": "John", "age": 31, "city": "New York"])
                if let json = try? JSONSerialization.jsonObject(with: initData) as? [String: Any],
                   let dataObj = json["data"] as? [String: Any],
                   let macMap = dataObj["macVodLinkMap"] as? [String: [String: String]] {
                    linkMap = macMap
                }
            } catch {}

            let body: [String: Any] = [
                "command": "WEB_GET_INFO_DETAIL",
                "type_Mid": "1",
                "id": cid,
                "languageType": "CN"
            ]
            let data = try await postAPI("/forward", body: body)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let result = dataObj["result"] as? [String: Any] {

                let name = result["vod_name"] as? String ?? ""
                var pic = result["vod_pic"] as? String ?? ""
                let content = result["vod_content"] as? String
                var videoUrl = result["vod_url"] as? String ?? ""

                // 规范化封面图 URL
                pic = normalizeUrl(pic)

                // 拼接播放链接
                if !svid.isEmpty, let linkInfo = linkMap[svid], let link2 = linkInfo["LINK_2"] {
                    // 避免重复斜杠
                    let base = link2.hasSuffix("/") ? String(link2.dropLast()) : link2
                    let path = videoUrl.hasPrefix("/") ? videoUrl : "/\(videoUrl)"
                    videoUrl = base + path
                }

                // 规范化视频 URL
                videoUrl = normalizeUrl(videoUrl)

                print("[熊猫视频] 播放URL: \(videoUrl)")

                let episodes: [FuliEpisode] = videoUrl.isEmpty ? [] : [FuliEpisode(name: "播放", url: videoUrl)]
                return FuliDetail(vodId: vodId, vodName: name, vodPic: pic, vodContent: content, playFrom: "熊猫视频", episodes: episodes)
            }
        } catch {
            print("[熊猫视频] 详情失败: \(error)")
        }
        return FuliDetail(vodId: vodId, vodName: "", vodPic: "", vodContent: nil, playFrom: "熊猫视频", episodes: [])
    }

    // MARK: - URL 规范化
    private func normalizeUrl(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return "" }
        if u.hasPrefix("http://") || u.hasPrefix("https://") {
            return u
        }
        if u.hasPrefix("//") {
            return "https:" + u
        }
        if u.hasPrefix("/") {
            return currentHost + u
        }
        if !u.contains("://") {
            return "https://" + u
        }
        return u
    }

    // MARK: - 搜索
    override func fetchSearch(keyword: String, page: Int) async -> FuliSearchResult {
        do {
            let body: [String: Any] = [
                "command": "WEB_GET_INFO",
                "pageNumber": page,
                "RecordsPage": 20,
                "typeId": "0",
                "typeMid": "1",
                "languageType": "CN",
                "content": keyword,
                "type": "1"
            ]
            let data = try await postAPI("/forward", body: body)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let list = dataObj["resultList"] as? [[String: Any]] {
                let videos = list.compactMap { parseVideoItem($0) }
                return FuliSearchResult(videos: videos, page: page, hasMore: videos.count >= 20)
            }
        } catch {
            print("[熊猫视频] 搜索失败: \(error)")
        }
        return FuliSearchResult(videos: [], page: page, hasMore: false)
    }

    // MARK: - 解析视频条目
    private func parseVideoItem(_ item: [String: Any]) -> FuliVideo? {
        guard let id = item["id"] as? Int else { return nil }
        var name = (item["vod_name"] as? String ?? "")
            .replacingOccurrences(of: "yy8ycom", with: "")
        // 清理名称中的冗余部分
        let pattern = "(.*?)-(.*?)-\\d+\\s+"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            name = regex.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: "")
        }
        guard !name.isEmpty else { return nil }

        let pic = normalizeUrl(item["vod_pic"] as? String ?? "")
        let id2 = item["vod_server_id"] as? Int ?? 0

        // vodId 格式: id#serverId
        let vodId = id2 > 0 ? "\(id)#\(id2)" : "\(id)"
        return FuliVideo(vodId: vodId, vodName: name, vodPic: pic)
    }
}
