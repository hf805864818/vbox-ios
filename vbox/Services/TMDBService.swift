import Foundation

// MARK: - TMDB 数据服务
// 提供影片搜索、海报/logo 图片、演职人员数据

final class TMDBService {
    static let shared = TMDBService()

    private let apiKey = "eea47c6a97dbc2b7cfad319971719cec"
    private let imageBaseURL = "https://image.tmdb.org/t/p"
    private let proxyBaseURL = "https://vbox.ltd"
    private let proxyToken = "199114"

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - 代理 URL

    /// 把任意远程 URL 转为 vbox.ltd 代理 URL
    /// 注意：传入的 originalURL 应当是已经编码好的完整 URL，这里只对作为 query 参数的整体做一次编码
    func proxiedURL(_ originalURL: String) -> String {
        // 把整体 URL 作为 vbox.ltd 的 `url` query 参数编码。
        // allowed 字符集保留 URL 结构和已编码的 %XX，但会把 `&` `=` 等作为 query 分隔符意义的字符编码，
        // 避免 vbox.ltd 把被代理 URL 内部的参数解析成自己的 query 参数。
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: ":/?+$,;-.~_#[]!%")
        let encoded = originalURL.addingPercentEncoding(withAllowedCharacters: allowed) ?? originalURL
        return "\(proxyBaseURL)?token=\(proxyToken)&url=\(encoded)"
    }

    /// 把远程图片 URL 转为本地代理 URL（优先本地代理，没有则走 vbox.ltd 云端代理）
    func proxiedImageURL(_ originalURL: String, size: String = "w500") -> String {
        if let localURL = DoubanImageProxyServer.shared.proxiedURL(for: originalURL) {
            return localURL.absoluteString
        }
        return proxiedURL(originalURL)
    }

    /// 生成 TMDB API 代理 URL，避免手动拼接导致双重编码
    private func apiURL(path: String) -> URL? {
        // 构造无 query 的 base URL
        guard var components = URLComponents(string: "https://api.themoviedb.org/3\(path)") else {
            return nil
        }
        // 用原始字符串保留已有的 percent-encoding，避免添加不必要的编码
        return URL(string: proxiedURL(components.string ?? components.url?.absoluteString ?? ""))
    }

    /// 生成 TMDB 图片原始 URL
    func originalImageURL(path: String, size: String = "w500") -> String {
        return "\(imageBaseURL)/\(size)\(path)"
    }

    // MARK: - 搜索

    /// 根据片名和年份搜索 TMDB，返回最佳匹配的 movie/tv id
    func searchMovie(name: String, year: String? = nil) async -> TMDBSearchResult? {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        var path = "/search/multi?api_key=\(apiKey)&language=zh-CN&query=\(encodedName)&page=1"
        if let year = year, let y = Int(year) {
            path += "&year=\(y)"
        }

        guard let url = apiURL(path: path) else { return nil }
        print("[TMDBService] search url: \(url.absoluteString)")
        do {
            let (data, response) = try await session.data(from: url)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                print("[TMDBService] search http status: \(httpResponse.statusCode)")
                let body = String(data: data, encoding: .utf8) ?? ""
                print("[TMDBService] search response body: \(body.prefix(500))")
                return nil
            }
            let decoded = try JSONDecoder().decode(TMDBSearchResponse.self, from: data)
            let candidates = decoded.results.filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
            return candidates.first
        } catch {
            print("[TMDBService] search error: \(error)")
            return nil
        }
    }

    // MARK: - 图片

    /// 获取影片图片（logos/posters/backdrops）
    func fetchImages(id: Int, mediaType: String = "movie") async -> TMDBImages? {
        let endpoint = mediaType == "tv" ? "tv" : "movie"
        guard let url = apiURL(path: "/\(endpoint)/\(id)/images?api_key=\(apiKey)&include_image_language=zh,en,null") else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("[TMDBService] images http status: \(httpResponse.statusCode), body: \(body.prefix(300))")
                return nil
            }
            return try JSONDecoder().decode(TMDBImages.self, from: data)
        } catch {
            print("[TMDBService] images error: \(error)")
            return nil
        }
    }

    // MARK: - 演职人员

    /// 获取演职人员
    func fetchCredits(id: Int, mediaType: String = "movie") async -> TMDBCredits? {
        let endpoint = mediaType == "tv" ? "tv" : "movie"
        guard let url = apiURL(path: "/\(endpoint)/\(id)/credits?api_key=\(apiKey)&language=zh-CN") else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("[TMDBService] credits http status: \(httpResponse.statusCode), body: \(body.prefix(300))")
                return nil
            }
            return try JSONDecoder().decode(TMDBCredits.self, from: data)
        } catch {
            print("[TMDBService] credits error: \(error)")
            return nil
        }
    }
}

// MARK: - Models

struct TMDBSearchResponse: Codable {
    let results: [TMDBSearchResult]
}

struct TMDBSearchResult: Codable {
    let id: Int
    let title: String?
    let name: String?
    let mediaType: String
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?

    var displayTitle: String { title ?? name ?? "" }
    var posterURL: String? { posterPath.map { "https://image.tmdb.org/t/p/w500\($0)" } }
    var backdropURL: String? { backdropPath.map { "https://image.tmdb.org/t/p/original\($0)" } }

    enum CodingKeys: String, CodingKey {
        case id, title, name
        case mediaType = "media_type"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
    }
}

struct TMDBImages: Codable {
    let id: Int
    let logos: [TMDBImage]?
    let posters: [TMDBImage]?
    let backdrops: [TMDBImage]?

    /// 最佳中文 logo，没有则取英文
    var bestLogo: TMDBImage? {
        let sorted = (logos ?? []).sorted { $0.voteAverage > $1.voteAverage }
        return sorted.first { $0.iso639_1 == "zh" }
            ?? sorted.first { $0.iso639_1 == "en" }
            ?? sorted.first
    }

    /// 最佳竖版海报
    var bestPoster: TMDBImage? {
        (posters ?? [])
            .filter { $0.aspectRatio < 1.0 }
            .sorted { $0.voteAverage > $1.voteAverage }
            .first
    }

    /// 最佳横版背景
    var bestBackdrop: TMDBImage? {
        (backdrops ?? [])
            .sorted { $0.voteAverage > $1.voteAverage }
            .first
    }
}

struct TMDBImage: Codable {
    let filePath: String
    let aspectRatio: Double
    let width: Int
    let height: Int
    let iso639_1: String?
    let voteAverage: Double

    var originalURL: String { "https://image.tmdb.org/t/p/original\(filePath)" }
    var w500URL: String { "https://image.tmdb.org/t/p/w500\(filePath)" }
    var w1280URL: String { "https://image.tmdb.org/t/p/w1280\(filePath)" }

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case aspectRatio = "aspect_ratio"
        case width, height
        case iso639_1
        case voteAverage = "vote_average"
    }
}

struct TMDBCredits: Codable {
    let id: Int
    let cast: [TMDBCast]?
    let crew: [TMDBCrew]?

    var actors: [DoubanCelebrity] {
        (cast ?? []).prefix(10).map { member in
            DoubanCelebrity(
                id: "\(member.id)",
                name: member.name,
                cover_url: member.profilePath.map { "https://image.tmdb.org/t/p/w185\($0)" },
                roles: nil,
                character: member.character
            )
        }
    }

    var directors: [DoubanCelebrity] {
        (crew ?? [])
            .filter { $0.job == "Director" }
            .map { member in
                DoubanCelebrity(
                    id: "\(member.id)",
                    name: member.name,
                    cover_url: member.profilePath.map { "https://image.tmdb.org/t/p/w185\($0)" },
                    roles: nil,
                    character: member.job
                )
            }
    }

    var writers: [DoubanCelebrity] {
        (crew ?? [])
            .filter {
                let job = $0.job?.lowercased() ?? ""
                return job == "writer" || job == "screenplay" || job == "story"
            }
            .map { member in
                DoubanCelebrity(
                    id: "\(member.id)",
                    name: member.name,
                    cover_url: member.profilePath.map { "https://image.tmdb.org/t/p/w185\($0)" },
                    roles: nil,
                    character: member.job
                )
            }
    }
}

struct TMDBCast: Codable {
    let id: Int
    let name: String
    let character: String?
    let profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, character
        case profilePath = "profile_path"
    }
}

struct TMDBCrew: Codable {
    let id: Int
    let name: String
    let job: String?
    let profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, job
        case profilePath = "profile_path"
    }
}
