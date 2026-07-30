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
        
        // 首次请求可能因 session 未预热而返回空数据，添加重试
        for attempt in 0..<2 {
            let (data, response) = try await session.data(from: url)
            
            // 检查是否被重定向到登录页
            if let httpResponse = response as? HTTPURLResponse,
               (httpResponse.statusCode == 403 || httpResponse.statusCode == 302) {
                if attempt == 1 { throw NSError(domain: "DoubanService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "豆瓣 API 访问受限 (HTTP \(httpResponse.statusCode))"]) }
                try await Task.sleep(nanoseconds: 800_000_000)
                continue
            }
            
            let result = try JSONDecoder().decode(DoubanCollectionResponse.self, from: data)
            let subjects = result.subject_collection_items ?? []
            
            if !subjects.isEmpty || attempt == 1 {
                return subjects
            }
            // 空数据则等待后重试
            try await Task.sleep(nanoseconds: 800_000_000)
        }
        return []
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

    // MARK: - 最新电影

    /// 最新电影
    func fetchLatestMovies(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollection("movie_latest", start: start, count: count)
    }

    // MARK: - 即将上映

    /// 即将上映
    func fetchComingSoon(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollection("movie_soon", start: start, count: count)
    }

    // MARK: - 热门韩剧

    /// 热门韩剧
    func fetchKoreanTV(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollectionWithTVCovers("tv_korean", start: start, count: count)
    }

    // MARK: - 热门日剧

    /// 热门日剧
    func fetchJapaneseTV(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollectionWithTVCovers("tv_japanese", start: start, count: count)
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

    // MARK: - 排行榜数据获取

    /// 排行榜类型
    enum RankingType: String, CaseIterable, Identifiable {
        case movieWeekly = "movie_weekly_best"
        case movieTop250 = "movie_top250"
        case movieShowing = "movie_showing"
        case movieHot = "movie_hot_gaia"
        case tvHot = "tv_real_time_hotest"
        case tvChinese = "tv_chinese_best_weekly"
        case tvAmerican = "tv_american"
        case variety = "tv_variety_show"
        case animation = "tv_animation"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .movieWeekly: return "口碑榜"
            case .movieTop250: return "TOP250"
            case .movieShowing: return "热映"
            case .movieHot: return "热门电影"
            case .tvHot: return "热门剧集"
            case .tvChinese: return "华语剧集"
            case .tvAmerican: return "英美剧集"
            case .variety: return "综艺"
            case .animation: return "动漫"
            }
        }

        var icon: String {
            switch self {
            case .movieWeekly: return "star.fill"
            case .movieTop250: return "crown.fill"
            case .movieShowing: return "film.fill"
            case .movieHot: return "flame.fill"
            case .tvHot: return "tv.fill"
            case .tvChinese: return "flag.fill"
            case .tvAmerican: return "globe"
            case .variety: return "theatermasks.fill"
            case .animation: return "paintbrush.fill"
            }
        }

        var collectionId: String { rawValue }
    }

    /// 获取排行榜数据
    func fetchRanking(_ type: RankingType, start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        switch type {
        case .tvAmerican:
            return try await fetchCollectionWithTVCovers(type.collectionId, start: start, count: count)
        case .variety, .animation:
            return try await fetchCollectionWithTVCovers(type.collectionId, start: start, count: count)
        default:
            return try await fetchCollection(type.collectionId, start: start, count: count)
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
    func fetchCredits(for workName: String) async -> (actors: [DoubanCelebrity], directors: [DoubanCelebrity], writers: [DoubanCelebrity], subjectId: String?) {
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
                    let result = await fetchCreditsById(id)
                    return (result.actors, result.directors, result.writers, id)
                }

                // 尝试解析标准搜索格式
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // 新格式：subjects 是字典 {items: [{target: {id: ...}, target_id: ...}]}
                    if let subjects = json["subjects"] as? [String: Any],
                       let items = subjects["items"] as? [[String: Any]],
                       let first = items.first,
                       let target = first["target"] as? [String: Any],
                       let targetId = target["id"] as? String ?? first["target_id"] as? String {
                        print("[DoubanService] 找到作品ID (subjects.items.target): \(targetId)")
                        let result = await fetchCreditsById(targetId)
                        return (result.actors, result.directors, result.writers, targetId)
                    }

                    // 旧格式：subjects 是数组 [{id: ...}]
                    if let subjects = json["subjects"] as? [[String: Any]],
                       let first = subjects.first,
                       let id = first["id"] as? String {
                        print("[DoubanService] 找到作品ID (subjects[]): \(id)")
                        let result = await fetchCreditsById(id)
                        return (result.actors, result.directors, result.writers, id)
                    }

                    // 顶层 items 数组
                    if let items = json["items"] as? [[String: Any]],
                       let first = items.first,
                       let targetId = first["id"] as? String ?? first["target_id"] as? String {
                        print("[DoubanService] 找到作品ID (items): \(targetId)")
                        let result = await fetchCreditsById(targetId)
                        return (result.actors, result.directors, result.writers, targetId)
                    }
                }
            } catch {
                print("[DoubanService] 搜索URL失败 \(urlString): \(error)")
            }
        }

        print("[DoubanService] 所有搜索方式都失败，尝试名称匹配")
        // 搜索失败时尝试直接用名称匹配
        let result = await fetchCreditsByName(workName)
        return (result.actors, result.directors, result.writers, nil)
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

    private func fetchCreditsByName(_ name: String) async -> (actors: [DoubanCelebrity], directors: [DoubanCelebrity], writers: [DoubanCelebrity], subjectId: String?) {
        // 兜底：尝试搜索并解析第一个结果
        guard let url = URL(string: "\(baseURL)/search/movie?q=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)&count=1") else {
            return ([], [], [], nil)
        }
        do {
            let (data, _) = try await session.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let subjects = json["subjects"] as? [[String: Any]],
               let first = subjects.first,
               let id = first["id"] as? String {
                let result = await fetchCreditsById(id)
                return (result.actors, result.directors, result.writers, id)
            }
        } catch {
            print("[DoubanService] 名称搜索演职人员失败: \(error)")
        }
        return ([], [], [], nil)
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

// MARK: - 豆瓣筛选参数模型
struct DoubanFilterParams {
    var genre: String?       // 类型: 喜剧、爱情、动作等
    var year: String?        // 年代: 2026、2025、2010年代等
    var platform: String?    // 平台: Netflix、HBO、BBC等
    var sort: SortType       // 排序方式
    var region: String?      // 地区: 华语、欧美、日本、韩国等
    
    enum SortType: String, CaseIterable {
        case hot = "recommend"      // 热度排序（默认）
        case rating = "rank"        // 评分排序
        case year = "time"          // 年份排序
        case latest = "latest"      // 最新上映
        
        var displayName: String {
            switch self {
            case .hot: return "热度"
            case .rating: return "评分"
            case .year: return "年份"
            case .latest: return "最新"
            }
        }
    }
    
    init(genre: String? = nil, year: String? = nil, platform: String? = nil, sort: SortType = .hot, region: String? = nil) {
        self.genre = genre
        self.year = year
        self.platform = platform
        self.sort = sort
        self.region = region
    }
}

// MARK: - 豆瓣分类配置
struct DoubanCategoryConfig: Identifiable {
    let id = UUID()
    let type: String
    let name: String
    let icon: String
    let collectionId: String
    let filters: FilterOptions
    
    struct FilterOptions {
        let genres: [String]
        let years: [String]
        let platforms: [String]
        let regions: [String]
    }
}

// MARK: - 豆瓣分类预设
extension DoubanCategoryConfig {
    // 电影分类
    static let movie = DoubanCategoryConfig(
        type: "movie",
        name: "电影",
        icon: "film.fill",
        collectionId: "movie_hot_gaia",
        filters: FilterOptions(
            genres: ["全部", "喜剧", "爱情", "动作", "科幻", "悬疑", "恐怖", "动画", "剧情", "犯罪", "冒险", "奇幻", "战争", "历史", "传记", "音乐", "家庭", "武侠", "古装"],
            years: ["全部", "2026", "2025", "2024", "2023", "2022", "2021", "2020", "2019", "2018", "2017", "2010年代", "2000年代", "90年代", "更早"],
            platforms: ["全部", "Netflix", "HBO", "BBC", "Hulu", "Apple TV+", "Disney+", "Amazon", "YouTube", "院线"],
            regions: ["全部", "华语", "欧美", "日本", "韩国", "印度", "泰国", "其他"]
        )
    )
    
    // 剧集分类
    static let tv = DoubanCategoryConfig(
        type: "tv",
        name: "剧集",
        icon: "tv.fill",
        collectionId: "tv_real_time_hotest",
        filters: FilterOptions(
            genres: ["全部", "剧情", "喜剧", "爱情", "悬疑", "犯罪", "科幻", "动画", "动作", "战争", "恐怖", "家庭", "古装", "武侠", "历史", "传记", "音乐", "真人秀", "脱口秀"],
            years: ["全部", "2026", "2025", "2024", "2023", "2022", "2021", "2020", "2019", "2018", "2017", "2010年代", "2000年代", "90年代", "更早"],
            platforms: ["全部", "Netflix", "HBO", "BBC", "Hulu", "Apple TV+", "Disney+", "Amazon", "YouTube", "腾讯视频", "爱奇艺", "优酷", "芒果TV", "央视"],
            regions: ["全部", "华语", "欧美", "日本", "韩国", "其他"]
        )
    )
    
    // 综艺分类
    static let variety = DoubanCategoryConfig(
        type: "variety",
        name: "综艺",
        icon: "theatermasks.fill",
        collectionId: "tv_variety_show",
        filters: FilterOptions(
            genres: ["全部", "真人秀", "脱口秀", "音乐", "舞蹈", "美食", "旅行", "竞技", "访谈", "情感", "喜剧", "游戏", "文化", "职场"],
            years: ["全部", "2026", "2025", "2024", "2023", "2022", "2021", "2020", "2019", "2018", "2017", "2010年代", "更早"],
            platforms: ["全部", "腾讯视频", "爱奇艺", "优酷", "芒果TV", "央视", "Netflix", "HBO", "BBC", "Hulu", "Apple TV+", "Disney+", "Amazon"],
            regions: ["全部", "华语", "欧美", "日本", "韩国", "其他"]
        )
    )
    
    // 动漫分类
    static let animation = DoubanCategoryConfig(
        type: "animation",
        name: "动漫",
        icon: "paintbrush.fill",
        collectionId: "tv_animation",
        filters: FilterOptions(
            genres: ["全部", "剧情", "喜剧", "动作", "科幻", "奇幻", "冒险", "悬疑", "恐怖", "爱情", "家庭", "动画", "短片"],
            years: ["全部", "2026", "2025", "2024", "2023", "2022", "2021", "2020", "2019", "2018", "2017", "2010年代", "2000年代", "90年代", "更早"],
            platforms: ["全部", "Netflix", "Crunchyroll", "Bilibili", "腾讯视频", "爱奇艺", "优酷", "Disney+", "HBO", "Hulu", "Amazon", "YouTube"],
            regions: ["全部", "日本", "华语", "欧美", "韩国", "其他"]
        )
    )
    
    // 纪录片分类
    static let documentary = DoubanCategoryConfig(
        type: "documentary",
        name: "纪录片",
        icon: "doc.text.fill",
        collectionId: "movie_documentary",
        filters: FilterOptions(
            genres: ["全部", "历史", "自然", "科学", "社会", "文化", "传记", "战争", "探险", "美食", "旅行", "音乐", "艺术", "体育"],
            years: ["全部", "2026", "2025", "2024", "2023", "2022", "2021", "2020", "2019", "2018", "2017", "2010年代", "2000年代", "90年代", "更早"],
            platforms: ["全部", "Netflix", "BBC", "Discovery", "National Geographic", "HBO", "Apple TV+", "Disney+", "Amazon", "YouTube", "央视", "Bilibili"],
            regions: ["全部", "华语", "欧美", "日本", "韩国", "其他"]
        )
    )
    
    // 所有分类
    static let allCategories: [DoubanCategoryConfig] = [.movie, .tv, .variety, .animation, .documentary]
}

// MARK: - DoubanService 增强：带筛选的分类获取
extension DoubanService {
    
    /// 带筛选的分类获取（统一入口）
    func fetchCategory(
        config: DoubanCategoryConfig,
        filters: DoubanFilterParams,
        start: Int = 0,
        count: Int = 20
    ) async throws -> [DoubanSubject] {
        var subjects = try await fetchCollection(config.collectionId, start: start, count: count)
        
        // 应用筛选
        subjects = applyFilters(subjects: subjects, filters: filters)
        
        // 应用排序
        subjects = applySort(subjects: subjects, sort: filters.sort)
        
        return subjects
    }
    
    // MARK: - 筛选逻辑
    private func applyFilters(subjects: [DoubanSubject], filters: DoubanFilterParams) -> [DoubanSubject] {
        var result = subjects
        
        // 类型筛选
        if let genre = filters.genre, genre != "全部" {
            result = result.filter { subject in
                subject.genres?.contains(genre) ?? false
            }
        }
        
        // 年代筛选
        if let year = filters.year, year != "全部" {
            result = result.filter { subject in
                guard let subjectYear = subject.year else { return false }
                
                switch year {
                case "2010年代":
                    return subjectYear >= "2010" && subjectYear < "2020"
                case "2000年代":
                    return subjectYear >= "2000" && subjectYear < "2010"
                case "90年代":
                    return subjectYear >= "1990" && subjectYear < "2000"
                case "更早":
                    return subjectYear < "1990"
                default:
                    return subjectYear == year
                }
            }
        }
        
        // 地区筛选（通过card_subtitle或intro判断）
        if let region = filters.region, region != "全部" {
            result = result.filter { subject in
                let text = "\(subject.card_subtitle ?? "") \(subject.intro ?? "")"
                switch region {
                case "华语":
                    return text.contains("中国大陆") || text.contains("中国") || text.contains("台湾") || text.contains("香港") || text.contains("华语")
                case "欧美":
                    return text.contains("美国") || text.contains("英国") || text.contains("法国") || text.contains("德国") || text.contains("意大利") || text.contains("西班牙") || text.contains("加拿大")
                case "日本":
                    return text.contains("日本")
                case "韩国":
                    return text.contains("韩国")
                case "印度":
                    return text.contains("印度")
                case "泰国":
                    return text.contains("泰国")
                default:
                    return true
                }
            }
        }
        
        // 平台筛选（通过card_subtitle或intro判断）
        if let platform = filters.platform, platform != "全部" {
            result = result.filter { subject in
                let text = "\(subject.card_subtitle ?? "") \(subject.intro ?? "") \(subject.title)"
                return text.contains(platform)
            }
        }
        
        return result
    }
    
    // MARK: - 排序逻辑
    private func applySort(subjects: [DoubanSubject], sort: DoubanFilterParams.SortType) -> [DoubanSubject] {
        var result = subjects
        
        switch sort {
        case .rating:
            result.sort { $0.ratingValue > $1.ratingValue }
        case .year, .latest:
            result.sort { ($0.year ?? "") > ($1.year ?? "") }
        case .hot:
            // 保持原始顺序（豆瓣返回的就是热度排序）
            break
        }
        
        return result
    }
}

// MARK: - ViewModel for SwiftUI 分类浏览
@MainActor
class DoubanCategoryViewModel: ObservableObject {
    @Published var subjects: [DoubanSubject] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var hasMoreData = true
    
    private let service = DoubanService.shared
    private var currentPage = 0
    private let pageSize = 20
    
    // 当前筛选状态
    @Published var filters = DoubanFilterParams(sort: .hot)
    @Published var selectedCategory: DoubanCategoryConfig = .movie
    
    // 加载数据
    func loadData(reset: Bool = true) async {
        if reset {
            currentPage = 0
            subjects = []
            hasMoreData = true
        }
        
        guard !isLoading && hasMoreData else { return }
        
        isLoading = true
        errorMessage = nil
        
        do {
            let newSubjects = try await service.fetchCategory(
                config: selectedCategory,
                filters: filters,
                start: currentPage * pageSize,
                count: pageSize
            )
            
            if reset {
                subjects = newSubjects
            } else {
                subjects.append(contentsOf: newSubjects)
            }
            
            hasMoreData = newSubjects.count == pageSize
            currentPage += 1
            
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    
    // 加载更多
    func loadMore() async {
        await loadData(reset: false)
    }
    
    // 更新筛选条件
    func updateFilters(_ newFilters: DoubanFilterParams) async {
        filters = newFilters
        await loadData(reset: true)
    }
    
    // 切换分类
    func switchCategory(_ category: DoubanCategoryConfig) async {
        selectedCategory = category
        filters = DoubanFilterParams(sort: .hot) // 重置筛选
        await loadData(reset: true)
    }
}

// MARK: - 豆瓣大封面图（海报）

extension DoubanService {

    /// 根据作品名称搜索豆瓣 subject ID
    func fetchSubjectIdByName(_ name: String) async -> String? {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let searchURLs = [
            "\(baseURL)/search?q=\(encodedName)&type=movie",
            "https://movie.douban.com/j/subject_suggest?q=\(encodedName)",
            "https://m.douban.com/rexxar/api/v2/search?type=movie&q=\(encodedName)"
        ]
        for urlString in searchURLs {
            guard let searchURL = URL(string: urlString) else { continue }
            guard let (data, _) = try? await session.data(from: searchURL) else { continue }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = json.first,
               let id = first["id"] as? String {
                print("[DoubanService] fetchSubjectIdByName 找到ID (suggest): \(id)")
                return id
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // 新格式：subjects 是字典 {items: [{target: {id: ...}}]}
                if let subjects = json["subjects"] as? [String: Any],
                   let items = subjects["items"] as? [[String: Any]],
                   let first = items.first,
                   let target = first["target"] as? [String: Any],
                   let id = target["id"] as? String ?? first["target_id"] as? String {
                    print("[DoubanService] fetchSubjectIdByName 找到ID (subjects.items.target): \(id)")
                    return id
                }
                // 旧格式：subjects 是数组
                if let subjects = json["subjects"] as? [[String: Any]],
                   let first = subjects.first,
                   let id = first["id"] as? String {
                    print("[DoubanService] fetchSubjectIdByName 找到ID (subjects[]): \(id)")
                    return id
                }
                // 顶层 items
                if let items = json["items"] as? [[String: Any]],
                   let first = items.first,
                   let id = first["id"] as? String ?? first["target_id"] as? String {
                    print("[DoubanService] fetchSubjectIdByName 找到ID (items): \(id)")
                    return id
                }
            }
        }
        print("[DoubanService] fetchSubjectIdByName 未找到匹配: \(name)")
        return nil
    }

    /// 拉取豆瓣大封面图（仅竖版海报）
    func fetchWallpaperURL(subjectId: String) async -> String? {
        let url = URL(string: "\(baseURL)/movie/\(subjectId)/photos?type=R&count=30")!
        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let photos = json["photos"] as? [[String: Any]] else {
            print("[DoubanService] fetchWallpaperURL 照片API请求失败")
            return nil
        }

        var portraitURL: String? = nil

        for photo in photos {
            guard let image = photo["image"] as? [String: Any],
                  let large = image["large"] as? [String: Any],
                  let rawURL = large["url"] as? String,
                  let w = large["width"] as? Int,
                  let h = large["height"] as? Int,
                  h > w else { continue }

            if portraitURL == nil { portraitURL = rawURL }
            if portraitURL != nil { break }
        }

        guard let portraitURL else {
            print("[DoubanService] fetchWallpaperURL 未找到竖版海报")
            return nil
        }

        // 去掉 imageView2 处理参数，并把 /photo/large/ 或 /photo/l/ 都转成 /photo/raw/ 取原图
        var components = URLComponents(string: portraitURL)
        components?.query = nil
        let cleanURL = components?.string ?? portraitURL
        let rawURL = cleanURL
            .replacingOccurrences(of: "/photo/large/", with: "/photo/raw/")
            .replacingOccurrences(of: "/photo/l/", with: "/photo/raw/")
        print("[DoubanService] fetchWallpaperURL 成功: 竖版 \(rawURL)")
        return DoubanImageProxyServer.shared.markedURLString(for: rawURL)
    }
}
