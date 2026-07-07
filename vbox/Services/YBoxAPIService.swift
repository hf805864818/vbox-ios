import Foundation

struct YBoxVideoItem: Codable {
    let vod_id: String?
    let vod_name: String?
    let vod_pic: String?
    let vod_remarks: String?
    let type_name: String?
    let vod_year: String?
    let vod_area: String?
    let vod_actor: String?
    let vod_director: String?
    let vod_content: String?
    let vod_play_from: String?
    let vod_play_url: String?
}

struct YBoxListResponse: Codable {
    let code: Int?
    let msg: String?
    let page: Int?
    let pagecount: Int?
    let limit: String?
    let total: Int?
    let list: [YBoxVideoItem]?
}

final class YBoxAPIService {
    static let shared = YBoxAPIService()

    private let baseURL = "https://ybox.vip"
    private let timeout: TimeInterval = 15

    private init() {}

    // MARK: - PageType 映射（用于 ybox.vip 代理路径）
    private let pageTypeMapping: [String: String] = [
        "home":      "",
        "video":     "/video",
        "film":      "/video",
        "actor":     "/actor/video",
        "search2":   "/search2",
        "search":    "/search",
        "shortVideo":"/shortVideo",
        "tiktok":    "/shortVideo",
        "topic":     "/topic/video",
        "tag":       "/tag",
        "user":      "/user",
        "anime":     "/play/anim",
        "cartoon":   "/cartoon",
        "comic":     "/read/comic",
        "novel":     "/read/novel",
        "classify":  "/classify/video",
        "channel":   "/channel",
        "image":     "/image",
        "stills":    "/stills",
        "audio":     "/audio",
        "find":      "/search2",
        "darkWeb":   "",
    ]

    /// 将 WelfarePageKind 映射为 pageTypeMapping 的 key
    static func proxyPageTypeKey(for kind: WelfarePageKind) -> String {
        switch kind {
        case .home:      return "home"
        case .video:     return "video"
        case .film:      return "film"
        case .anime:     return "anime"
        case .comic:     return "comic"
        case .novel:     return "novel"
        case .actor:     return "actor"
        case .search:    return "search"
        case .classify:  return "classify"
        case .find:      return "find"
        case .topic:     return "topic"
        case .tiktok:    return "tiktok"
        case .darkWeb:   return "darkWeb"
        case .audio:     return "audio"
        case .article:   return "home"
        case .community: return "home"
        case .rank:      return "home"
        case .channel:   return "channel"
        case .tag:       return "tag"
        case .user:      return "user"
        case .image:     return "image"
        case .stills:    return "stills"
        }
    }

    // MARK: - 对外接口：通过 ybox.vip 代理获取带播放链接的 VodItem 列表

    /// 通过 WelfarePageKind 获取内容（供 WelfareCrawlerService 回退调用）
    func fetchPlatformItems(platformId: String, kind: WelfarePageKind, page: Int = 1) async -> [VodItem] {
        let typeKey = Self.proxyPageTypeKey(for: kind)
        return await fetchPlatformContent(platformId: platformId, pageType: typeKey, page: page)
    }

    /// 通过字符串 pageType 获取内容（原有接口，保留向后兼容）
    func fetchPlatformContent(platformId: String, pageType: String, page: Int = 1) async -> [VodItem] {
        let apiPath = pageTypeMapping[pageType] ?? ""
        let urlStr: String
        if apiPath.isEmpty {
            urlStr = "\(baseURL)/app/\(platformId)"
        } else {
            urlStr = "\(baseURL)/app/\(platformId)\(apiPath)"
        }

        guard let url = URL(string: urlStr) else {
            print("[YBoxAPI] URL无效: \(urlStr)")
            return []
        }

        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = timeout
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("https://ybox.vip", forHTTPHeaderField: "Origin")
            req.setValue("https://ybox.vip", forHTTPHeaderField: "Referer")

            let (data, response) = try await URLSession.shared.data(for: req)

            guard let httpResp = response as? HTTPURLResponse else {
                print("[YBoxAPI] 无效响应")
                return []
            }

            guard httpResp.statusCode == 200 else {
                print("[YBoxAPI] HTTP \(httpResp.statusCode): \(urlStr)")
                return []
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return parseResponse(json: json, platformId: platformId)
            }
        } catch {
            print("[YBoxAPI] 请求失败: \(error.localizedDescription)")
        }

        return []
    }

    // MARK: - 响应解析

    private func parseResponse(json: [String: Any], platformId: String) -> [VodItem] {
        var items: [VodItem] = []

        // 顶层 list
        if let list = json["list"] as? [[String: Any]] {
            for dict in list { items.append(buildVodItem(from: dict)) }
        }

        // data.list 嵌套
        if let dataObj = json["data"] as? [String: Any] {
            if let list = dataObj["list"] as? [[String: Any]] {
                for dict in list { items.append(buildVodItem(from: dict)) }
            }
            // 部分代理返回 data 字段本身就是列表的场景
            if items.isEmpty, let nestedList = json["data"] as? [[String: Any]] {
                for dict in nestedList { items.append(buildVodItem(from: dict)) }
            }
        }

        print("[YBoxAPI] \(platformId): \(items.count) 条")
        return items
    }

    /// 从字典构建 VodItem（含播放链接字段）
    private func buildVodItem(from dict: [String: Any]) -> VodItem {
        let id = dict["vod_id"] as? String
            ?? dict["id"] as? String
            ?? dict["detail_id"] as? String
            ?? dict["topic_id"] as? String
            ?? dict["user_id"] as? String
            ?? UUID().uuidString

        let name = dict["vod_name"] as? String
            ?? dict["name"] as? String
            ?? dict["title"] as? String
            ?? dict["topic_name"] as? String
            ?? dict["user_name"] as? String
            ?? ""

        let pic = dict["vod_pic"] as? String
            ?? dict["pic"] as? String
            ?? dict["image"] as? String
            ?? dict["cover"] as? String
            ?? ""

        var remarks = dict["vod_remarks"] as? String
            ?? dict["remarks"] as? String
            ?? dict["duration"] as? String
            ?? dict["type_name"] as? String
            ?? ""

        if !remarks.hasPrefix("[福利]") {
            remarks = "[福利]" + remarks
        }

        // 播放链接字段
        let playFrom = dict["vod_play_from"] as? String
        var playUrl = dict["vod_play_url"] as? String

        // 如果是多集格式（第01集$URL#第02集$URL#...），提取第一个可用链接
        if let url = playUrl, url.contains("#") {
            playUrl = extractFirstPlayableURL(from: url)
        }

        return VodItem(
            vodId: id,
            vodName: name,
            vodPic: pic,
            vodRemarks: remarks,
            vodYear: dict["vod_year"] as? String ?? dict["year"] as? String,
            vodArea: dict["vod_area"] as? String,
            vodDirector: dict["vod_director"] as? String,
            vodActor: dict["vod_actor"] as? String ?? dict["actor"] as? String,
            vodContent: dict["vod_content"] as? String ?? dict["content"] as? String,
            vodPlayFrom: playFrom,
            vodPlayUrl: playUrl
        )
    }

    /// 从多集格式播放链接中提取第一个可用的URL
    private func extractFirstPlayableURL(from raw: String) -> String? {
        let parts = raw.components(separatedBy: "#")
        for part in parts {
            let segments = part.components(separatedBy: "$")
            // 格式: "第01集$https://..."
            if segments.count >= 2, let urlStr = segments.last?.trimmingCharacters(in: .whitespaces) {
                if urlStr.hasPrefix("http") { return urlStr }
            }
        }
        return nil
    }
}
