import Foundation

// MARK: - Douban Models
struct DoubanSubject: Codable, Identifiable {
    let id: String
    let title: String
    let rating: DoubanRating?
    let images: DoubanImages?
    let genres: [String]?
    let year: String?
    let intro: String?
    
    enum CodingKeys: String, CodingKey {
        case id, title, rating, images, genres, year
    }
}

struct DoubanRating: Codable {
    let value: Double?
    let average: String?
    let count: Int?
    let max: Int?
    
    var ratingValue: Double {
        if let v = value { return v }
        if let a = average, let d = Double(a) { return d }
        return 0
    }
}

struct DoubanImages: Codable {
    let small: String?
    let medium: String?
    let large: String?
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
        self.session = URLSession(configuration: config)
    }
    
    func fetchTop250(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        let url = URL(string: "\(baseURL)/subject_collection/movie_top250/items?start=\(start)&count=\(count)")!
        let (data, _) = try await session.data(from: url)
        struct Result: Codable { let items: [DoubanSubject]? }
        let result = try JSONDecoder().decode(Result.self, from: data)
        return result.items ?? []
    }
    
    func fetchHotMovies(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        let url = URL(string: "\(baseURL)/subject_collection/movie_real_time_hotest/items?start=\(start)&count=\(count)")!
        let (data, _) = try await session.data(from: url)
        struct Result: Codable { let items: [DoubanSubject]? }
        let result = try JSONDecoder().decode(Result.self, from: data)
        return result.items ?? []
    }
    
    func fetchHotTV(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        let url = URL(string: "\(baseURL)/subject_collection/tv_hot/items?start=\(start)&count=\(count)")!
        let (data, _) = try await session.data(from: url)
        struct Result: Codable { let items: [DoubanSubject]? }
        let result = try JSONDecoder().decode(Result.self, from: data)
        return result.items ?? []
    }
    
    func fetchHotVariety(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        let url = URL(string: "\(baseURL)/subject_collection/tv_variety_show_hot/items?start=\(start)&count=\(count)")!
        let (data, _) = try await session.data(from: url)
        struct Result: Codable { let items: [DoubanSubject]? }
        let result = try JSONDecoder().decode(Result.self, from: data)
        return result.items ?? []
    }
    
    func fetchHotAnimation(start: Int = 0, count: Int = 20) async throws -> [DoubanSubject] {
        let url = URL(string: "\(baseURL)/subject_collection/tv_animation_hot/items?start=\(start)&count=\(count)")!
        let (data, _) = try await session.data(from: url)
        struct Result: Codable { let items: [DoubanSubject]? }
        let result = try JSONDecoder().decode(Result.self, from: data)
        return result.items ?? []
    }
    
    func toVodItem(subject: DoubanSubject) -> VodItem {
        return VodItem(
            vodId: subject.id,
            vodName: subject.title,
            vodPic: subject.images?.large ?? subject.images?.medium ?? subject.images?.small ?? "",
            vodRemarks: subject.genres?.joined(separator: "/") ?? "",
            vodYear: subject.year
        )
    }
}