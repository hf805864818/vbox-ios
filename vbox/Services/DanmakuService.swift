import Foundation

/// LogVar 弹幕 API 服务
/// 文档: https://uzdm.616222.xyz
class DanmakuService {
    static let shared = DanmakuService()
    private let baseURL = "https://uzdm.616222.xyz/api/v2"

    // MARK: - 模型
    struct Anime: Codable {
        let animeId: Int
        let animeTitle: String
        let type: String?
        let year: String?
        let season: Int?
    }

    struct Episode: Codable {
        let episodeId: Int
        let episodeTitle: String?
    }

    struct Danmaku: Codable {
        let id: Int?
        let cid: Int?
        let p: String?         // 弹幕参数: 时间,模式,字体大小,颜色,发送时间
        let m: String?         // 弹幕内容
        let content: String?

        var time: Double {
            if let p = p {
                let parts = p.components(separatedBy: ",")
                if let first = parts.first, let t = Double(first) { return t }
            }
            return 0
        }

        var text: String { m ?? content ?? "" }
    }

    // MARK: - 搜索动漫
    func searchAnime(keyword: String) async throws -> [Anime] {
        guard let url = URL(string: "\(baseURL)/search/anime?keyword=\(keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword)&from=10") else {
            throw DanmakuError.invalidURL
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        let result = try JSONDecoder().decode(AnimeSearchResponse.self, from: data)
        return result.animeList ?? []
    }

    // MARK: - 搜索剧集
    func searchEpisodes(animeId: Int) async throws -> [Episode] {
        guard let url = URL(string: "\(baseURL)/search/episodes?animeId=\(animeId)") else {
            throw DanmakuError.invalidURL
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        let result = try JSONDecoder().decode(EpisodeSearchResponse.self, from: data)
        return result.episodes ?? []
    }

    // MARK: - 获取弹幕
    func fetchDanmaku(episodeId: Int, segmentIndex: Int = 0) async throws -> [Danmaku] {
        guard let url = URL(string: "\(baseURL)/segmentcomment?episodeId=\(episodeId)&segmentIndex=\(segmentIndex)") else {
            throw DanmakuError.invalidURL
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        let result = try JSONDecoder().decode(DanmakuSegmentResponse.self, from: data)
        return result.comments ?? []
    }

    // MARK: - 自动匹配（根据文件名）
    func matchAnime(fileName: String) async throws -> (anime: Anime?, episodes: [Episode]?, danmaku: [Danmaku]?) {
        guard let url = URL(string: "\(baseURL)/match") else {
            throw DanmakuError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        let body: [String: Any] = [
            "fileName": fileName,
            "from": 10
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        // match 返回格式比较复杂，直接返回原始 JSON
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let animeData = json["anime"] as? [String: Any],
               let animeId = animeData["animeId"] as? Int {
                let anime = Anime(animeId: animeId, animeTitle: animeData["animeTitle"] as? String ?? "", type: animeData["type"] as? String, year: animeData["year"] as? String, season: animeData["season"] as? Int)
                return (anime, nil, nil)
            }
        }
        return (nil, nil, nil)
    }

    /// 根据视频名称自动匹配并获取弹幕
    func fetchDanmakuForVideo(videoName: String, episodeIndex: Int = 1) async throws -> [Danmaku] {
        // 先搜索
        let animes = try await searchAnime(keyword: videoName)
        guard let first = animes.first else { throw DanmakuError.notFound }
        // 获取剧集列表
        let episodes = try await searchEpisodes(animeId: first.animeId)
        // 取对应集数
        let targetEp = episodes.first { $0.episodeTitle?.contains("\(episodeIndex)") ?? false } ?? episodes.first
        guard let ep = targetEp else { throw DanmakuError.notFound }
        // 获取弹幕
        return try await fetchDanmaku(episodeId: ep.episodeId)
    }
}

// MARK: - 模型和错误
struct AnimeSearchResponse: Codable {
    let errorCode: Int?
    let animeList: [DanmakuService.Anime]?
}

struct EpisodeSearchResponse: Codable {
    let errorCode: Int?
    let episodes: [DanmakuService.Episode]?
}

struct DanmakuSegmentResponse: Codable {
    let errorCode: Int?
    let comments: [DanmakuService.Danmaku]?
}

enum DanmakuError: LocalizedError {
    case invalidURL
    case notFound
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的URL"
        case .notFound: return "未找到匹配的弹幕"
        case .networkError(let msg): return msg
        }
    }
}
