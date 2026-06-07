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
        // 最后使用 cover.medium
        if let coverUrl = cover?.medium {
            return DoubanImages(small: coverUrl, medium: coverUrl, large: coverUrl)
        }
        return nil
    }
    
    /// 获取封面图 URL（带 HTTPS 处理）
    var coverImageURL: String? {
        guard let rawUrl = images?.large else { return nil }
        
        // 处理相对 URL
        if rawUrl.hasPrefix("//") {
            return "https:" + rawUrl
        } else if !rawUrl.hasPrefix("http") {
            return "https://" + rawUrl
        }
        return rawUrl
    }
    
    var ratingValue: Double {
        return rating?.value ?? 0
    }
    
    var genreText: String {
        return genres?.joined(separator: " / ") ?? ""
    }
}

/// 豆瓣封面图结构
struct DoubanCover: Codable {
    let small: String?
    let medium: String?
    let large: String?
}
    
    var ratingValue: Double {
        return rating?.value ?? 0
    }
    
    var yearValue: String {
        return year ?? ""
    }
    
    var genreText: String {
        return genres?.joined(separator: "/") ?? ""
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
            "Accept": "application/json"
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
    
    func fetchTop250(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollection("movie_top250", start: start, count: count)
    }
    
    func fetchHotMovies(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollection("movie_real_time_hotest", start: start, count: count)
    }
    
    func fetchHotTV(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollection("tv_hot", start: start, count: count)
    }
    
    func fetchHotVariety(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollection("tv_variety_show_hot", start: start, count: count)
    }
    
    func fetchHotAnimation(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        return try await fetchCollection("tv_animation_hot", start: start, count: count)
    }
    
    func fetchRecommendFeed(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        // 使用电影实时热门作为推荐内容
        return try await fetchCollection("movie_real_time_hotest", start: start, count: count)
    }
    
    func toVodItem(subject: DoubanSubject) -> VodItem {
        return VodItem(
            vodId: subject.id,
            vodName: subject.title,
            vodPic: subject.cover_url ?? "",
            vodRemarks: subject.card_subtitle ?? subject.genreText,
            vodYear: subject.year
        )
    }
}
