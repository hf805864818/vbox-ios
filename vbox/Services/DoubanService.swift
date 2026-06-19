import Foundation

// MARK: - Douban Models
struct DoubanSubject: Codable, Identifiable {
    let id: String
    let title: String
    let cover_url: String?
    let rating: DoubanRating?
    let year: String?
    let genres: [String]?
    let card_subtitle: String?
    let intro: String?
    let photos_gadget: String?
    let cover: DoubanCover?
    
    // 计算属性兼容原有 UI
    var images: DoubanImages? {
        // 优先使用 photos_gadget（豆瓣新版 API）
        if let photoUrl = photos_gadget {
            return DoubanImages(small: photoUrl, medium: photoUrl, large: photoUrl)
        }
        // 其次使用 cover_url
        if let url = cover_url {
            return DoubanImages(small: url, medium: url, large: url)
        }
        // 最后使用 cover.url / cover.large / cover.medium / cover.small
        if let coverUrl = cover?.bestURL {
            return DoubanImages(small: coverUrl, medium: coverUrl, large: coverUrl)
        }
        return nil
    }
    
    /// 获取封面图 URL（带 HTTPS 处理）
    var coverImageURL: String? {
        guard let rawUrl = images?.large else { return nil }
        
        // 处理相对 URL
        let normalizedUrl: String
        if rawUrl.hasPrefix("//") {
            normalizedUrl = "https:" + rawUrl
        } else if !rawUrl.hasPrefix("http") {
            normalizedUrl = "https://" + rawUrl
        } else {
            normalizedUrl = rawUrl
        }

        return DoubanImageProxyServer.shared.markedURLString(for: normalizedUrl)
    }
    
    var ratingValue: Double {
        return rating?.value ?? 0
    }
    
    var yearString: String {
        return year ?? ""
    }
    
    var genreText: String {
        return genres?.joined(separator: " / ") ?? ""
    }

    func withCoverURL(_ url: String?) -> DoubanSubject {
        return DoubanSubject(
            id: id,
            title: title,
            cover_url: url ?? cover_url,
            rating: rating,
            year: year,
            genres: genres,
            card_subtitle: card_subtitle,
            intro: intro,
            photos_gadget: photos_gadget,
            cover: cover
        )
    }
}

/// 豆瓣封面图结构
struct DoubanCover: Codable {
    let url: String?
    let small: String?
    let medium: String?
    let large: String?

    var bestURL: String? {
        return url ?? large ?? medium ?? small
    }
}

struct DoubanRating: Codable {
    let value: Double?
    let count: Int?
    let max: Int?
    let star_count: Double?
}

struct DoubanImages: Codable {
    let small: String?
    let medium: String?
    let large: String?
}

struct DoubanCollectionResponse: Codable {
    let subject_collection_items: [DoubanSubject]?
}

struct DoubanSubjectDetailResponse: Codable {
    let cover_url: String?
    let pic: DoubanPic?

    var bestCoverURL: String? {
        return cover_url ?? pic?.large ?? pic?.normal
    }
}

struct DoubanPic: Codable {
    let large: String?
    let normal: String?
}

// MARK: - Douban Service
class DoubanService: ObservableObject {
    static let shared = DoubanService()
    private let baseURL = "https://m.douban.com/rexxar/api/v2"
    private let session: URLSession
    
    private init() {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15",
            "Referer": "https://movie.douban.com",
            "Accept": "application/json",
            "X-Forwarded-For": "1.1.1.1"
        ]
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }
    
    private func fetchCollection(_ collectionId: String, start: Int, count: Int) async throws -> [DoubanSubject] {
        let url = URL(string: "\(baseURL)/subject_collection/\(collectionId)/items?start=\(start)&count=\(count)")!
        let (data, _) = try await session.data(from: url)
        let result = try JSONDecoder().decode(DoubanCollectionResponse.self, from: data)
        return result.subject_collection_items ?? []
    }

    private func fetchCollectionWithTVCovers(_ collectionId: String, start: Int, count: Int) async throws -> [DoubanSubject] {
        var subjects = try await fetchCollection(collectionId, start: start, count: count)
        for index in subjects.indices {
            guard subjects[index].coverImageURL == nil,
                  let coverURL = try? await fetchTVDetailCoverURL(id: subjects[index].id)
            else {
                continue
            }

            subjects[index] = subjects[index].withCoverURL(coverURL)
        }
        return subjects
    }

    private func fetchTVDetailCoverURL(id: String) async throws -> String? {
        let url = URL(string: "\(baseURL)/tv/\(id)")!
        let (data, _) = try await session.data(from: url)
        let detail = try JSONDecoder().decode(DoubanSubjectDetailResponse.self, from: data)
        return detail.bestCoverURL
    }
    
    func fetchTop250(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollection("movie_top250", start: start, count: count)
    }
    
    func fetchHotMovies(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollection("movie_hot_gaia", start: start, count: count)
    }
    
    func fetchHotTV(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollection("tv_real_time_hotest", start: start, count: count)
    }
    
    func fetchHotVariety(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollectionWithTVCovers("tv_variety_show", start: start, count: count)
    }
    
    func fetchHotAnimation(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollectionWithTVCovers("tv_animation", start: start, count: count)
    }
    
    func fetchRecommendFeed(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollection("movie_showing", start: start, count: count)
    }
    
    // MARK: - 豆瓣周榜
    
    /// 豆瓣电影周榜
    func fetchMovieWeekly(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollection("movie_weekly_best", start: start, count: count)
    }
    
    /// 豆瓣剧集周榜
    func fetchTvWeekly(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollection("tv_real_time_hotest", start: start, count: count)
    }
    
    // MARK: - 华语口碑剧集
    
    /// 华语口碑剧集
    func fetchPopularChiTV(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollection("tv_chinese_best_weekly", start: start, count: count)
    }
    
    // MARK: - 一周口碑电影榜
    
    /// 一周口碑电影榜
    func fetchMovieTopWeekly(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollection("movie_hot_gaia", start: start, count: count)
    }
    
    // MARK: - 国内即将上映
    
    /// 国内即将上映（影院热映）
    func fetchUpcomingCN(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollection("movie_showing", start: start, count: count)
    }

    /// 豆瓣热门
    func fetchHotGaia(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollection("movie_hot_gaia", start: start, count: count)
    }

    /// 英美剧
    func fetchAmericanTV(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollectionWithTVCovers("tv_american", start: start, count: count)
    }

    // MARK: - 按栏目标签获取数据
    
    /// 根据栏目标签名称获取对应的豆瓣数据（统一入口）
    func fetchByTab(_ tabName: String, start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        switch tabName {
        case "豆瓣周榜":
            return try await fetchMovieWeekly(start: start, count: count)
        case "华语口碑剧集":
            return try await fetchPopularChiTV(start: start, count: count)
        case "一周口碑电影榜":
            return try await fetchMovieTopWeekly(start: start, count: count)
        case "国内即将上映":
            return try await fetchUpcomingCN(start: start, count: count)
        default:
            throw DoubanError.unknownTab(tabName)
        }
    }
    
    func toVodItem(subject: DoubanSubject) -> VodItem {
        let coverUrl = subject.coverImageURL ?? ""
        return VodItem(
            vodId: subject.id,
            vodName: subject.title,
            vodPic: coverUrl,
            vodRemarks: subject.card_subtitle ?? subject.genreText,
            vodYear: subject.year
        )
    }

    // MARK: - 演职人员搜索

    /// 根据作品名称搜索演职人员信息
    func fetchCredits(for workName: String) async -> (actors: [DoubanCelebrity], directors: [DoubanCelebrity], writers: [DoubanCelebrity]) {
        // 1. 先搜索作品获取 ID（使用豆瓣搜索API）
        let encodedName = workName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? workName
        
        // 尝试多种搜索URL格式
        let searchURLs = [
            "\(baseURL)/search?q=\(encodedName)&type=movie",
            "https://movie.douban.com/j/subject_suggest?q=\(encodedName)",
            "https://m.douban.com/rexxar/api/v2/search?type=movie&q=\(encodedName)"
        ]
        
        for urlString in searchURLs {
            guard let searchURL = URL(string: urlString) else { continue }
            
            do {
                let (data, _) = try await session.data(from: searchURL)
                
                // 尝试解析 subject_suggest 格式
                if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                   let first = json.first,
                   let id = first["id"] as? String {
                    print("[DoubanService] 找到作品ID (suggest): \(id)")
                    return await fetchCreditsById(id)
                }
                
                // 尝试解析标准搜索格式
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // 尝试 items 字段
                    if let items = json["items"] as? [[String: Any]],
                       let first = items.first,
                       let targetId = first["id"] as? String ?? first["target_id"] as? String {
                        print("[DoubanService] 找到作品ID (items): \(targetId)")
                        return await fetchCreditsById(targetId)
                    }
                    
                    // 尝试 subjects 字段
                    if let subjects = json["subjects"] as? [[String: Any]],
                       let first = subjects.first,
                       let id = first["id"] as? String {
                        print("[DoubanService] 找到作品ID (subjects): \(id)")
                        return await fetchCreditsById(id)
                    }
                    
                    // 尝试 data 字段
                    if let dataArr = json["data"] as? [[String: Any]],
                       let first = dataArr.first,
                       let id = first["id"] as? String {
                        print("[DoubanService] 找到作品ID (data): \(id)")
                        return await fetchCreditsById(id)
                    }
                }
            } catch {
                print("[DoubanService] 搜索URL失败 \(urlString): \(error)")
            }
        }

        print("[DoubanService] 所有搜索方式都失败，尝试名称匹配")
        // 搜索失败时尝试直接用名称匹配
        return await fetchCreditsByName(workName)
    }

    private func fetchCreditsById(_ id: String) async -> (actors: [DoubanCelebrity], directors: [DoubanCelebrity], writers: [DoubanCelebrity]) {
        // 使用 /celebrities 接口获取完整演职人员信息（含头像、角色）
        let url = URL(string: "\(baseURL)/movie/\(id)/celebrities")!
        do {
            let (data, _) = try await session.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            var actors: [DoubanCelebrity] = []
            var directors: [DoubanCelebrity] = []
            var writers: [DoubanCelebrity] = []

            // 解析演员
            if let list = json?["actors"] as? [[String: Any]] {
                actors = list.compactMap { parseCelebrity(from: $0, defaultRole: nil) }
            }

            // 解析导演（同时提取编剧角色）
            if let list = json?["directors"] as? [[String: Any]] {
                for dict in list {
                    guard let person = parseCelebrity(from: dict, defaultRole: "导演") else { continue }
                    directors.append(person)
                    // 如果该导演同时也是编剧，单独加入编剧列表
                    if let roles = dict["roles"] as? [String], roles.contains("编剧") {
                        var writer = person
                        writer = DoubanCelebrity(
                            id: person.id,
                            name: person.name,
                            cover_url: person.cover_url,
                            roles: ["编剧"],
                            character: nil
                        )
                        if !writers.contains(where: { $0.id == writer.id }) {
                            writers.append(writer)
                        }
                    }
                }
            }

            print("[DoubanService] 演职人员获取成功: 演员\(actors.count)人, 导演\(directors.count)人, 编剧\(writers.count)人")
            return (actors, directors, writers)
        } catch {
            print("[DoubanService] 获取演职人员失败: \(error)")
            return ([], [], [])
        }
    }

    /// 解析 celebrities 接口返回的演职人员字典
    private func parseCelebrity(from dict: [String: Any], defaultRole: String?) -> DoubanCelebrity? {
        guard let name = dict["name"] as? String else { return nil }
        let id = dict["id"] as? String ?? UUID().uuidString
        let avatarUrl = extractCelebrityAvatar(from: dict)
        let character = dict["character"] as? String
        let roles = dict["roles"] as? [String]
        return DoubanCelebrity(
            id: id,
            name: name,
            cover_url: avatarUrl,
            roles: defaultRole.map { [$0] } ?? roles,
            character: character
        )
    }

    /// 从 celebrities 接口提取头像URL（avatar.large / avatar.normal）
    private func extractCelebrityAvatar(from dict: [String: Any]) -> String? {
        if let avatar = dict["avatar"] as? [String: Any] {
            if let large = avatar["large"] as? String, !large.isEmpty { return large }
            if let normal = avatar["normal"] as? String, !normal.isEmpty { return normal }
        }
        // 兼容其他格式
        if let avatar = dict["avatar"] as? String, !avatar.isEmpty { return avatar }
        if let cover = dict["cover_url"] as? String, !cover.isEmpty { return cover }
        return nil
    }

    private func fetchCreditsByName(_ name: String) async -> (actors: [DoubanCelebrity], directors: [DoubanCelebrity], writers: [DoubanCelebrity]) {
        // 兜底：尝试搜索并解析第一个结果
        guard let url = URL(string: "\(baseURL)/search/movie?q=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)&count=1") else {
            return ([], [], [])
        }
        do {
            let (data, _) = try await session.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let subjects = json["subjects"] as? [[String: Any]],
               let first = subjects.first,
               let id = first["id"] as? String {
                return await fetchCreditsById(id)
            }
        } catch {
            print("[DoubanService] 名称搜索演职人员失败: \(error)")
        }
        return ([], [], [])
    }
}

// MARK: - 演职人员模型
struct DoubanCelebrity: Codable, Identifiable {
    let id: String
    let name: String
    let cover_url: String?
    let roles: [String]?
    let character: String?
    
    var avatarURL: String? {
        guard let url = cover_url else { return nil }
        let normalized: String
        if url.hasPrefix("//") {
            normalized = "https:" + url
        } else if !url.hasPrefix("http") {
            normalized = "https://" + url
        } else {
            normalized = url
        }
        // 使用图片代理避免豆瓣反盗链
        return DoubanImageProxyServer.shared.markedURLString(for: normalized)
    }
    
    var roleText: String {
        if let char = character, !char.isEmpty { return "饰 \(char)" }
        if let roles = roles, !roles.isEmpty { return roles.joined(separator: " / ") }
        return ""
    }
}

struct DoubanCreditsResponse: Codable {
    let actors: [DoubanCelebrity]?
    let directors: [DoubanCelebrity]?
    let writers: [DoubanCelebrity]?
}

// MARK: - Douban Error
enum DoubanError: LocalizedError {
    case unknownTab(String)
    
    var errorDescription: String? {
        switch self {
        case .unknownTab(let name):
            return "未知的豆瓣栏目标签: \(name)"
        }
    }
}
