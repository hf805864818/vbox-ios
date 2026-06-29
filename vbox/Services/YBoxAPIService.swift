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

    private func parseResponse(json: [String: Any], platformId: String) -> [VodItem] {
        var items: [VodItem] = []

        if let list = json["list"] as? [[String: Any]] {
            for dict in list {
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

                items.append(VodItem(
                    vodId: id,
                    vodName: name,
                    vodPic: pic,
                    vodRemarks: remarks,
                    vodYear: dict["vod_year"] as? String ?? dict["year"] as? String,
                    vodArea: dict["vod_area"] as? String,
                    vodDirector: dict["vod_director"] as? String,
                    vodActor: dict["vod_actor"] as? String ?? dict["actor"] as? String,
                    vodContent: dict["vod_content"] as? String ?? dict["content"] as? String
                ))
            }
        }

        if let dataObj = json["data"] as? [String: Any] {
            if let list = dataObj["list"] as? [[String: Any]] {
                for dict in list {
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

                    items.append(VodItem(
                        vodId: id,
                        vodName: name,
                        vodPic: pic,
                        vodRemarks: remarks,
                        vodYear: dict["vod_year"] as? String ?? dict["year"] as? String,
                        vodArea: dict["vod_area"] as? String,
                        vodDirector: dict["vod_director"] as? String,
                        vodActor: dict["vod_actor"] as? String ?? dict["actor"] as? String,
                        vodContent: dict["vod_content"] as? String ?? dict["content"] as? String
                    ))
                }
            }
        }

        print("[YBoxAPI] \(platformId): \(items.count) 条")
        return items
    }
}
