import Foundation

// MARK: - 豆瓣 Chart 排行榜服务
/// 对接 movie.douban.com/j/chart/top_list JSON API
actor DoubanChartService {
    static let shared = DoubanChartService()
    
    private init() {}
    
    // MARK: - 排行榜分类定义
    struct ChartCategory: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let typeId: Int
        let icon: String
        
        static let all: [ChartCategory] = [
            ChartCategory(name: "剧情", typeId: 11, icon: "film.fill"),
            ChartCategory(name: "喜剧", typeId: 24, icon: "face.smiling.fill"),
            ChartCategory(name: "动作", typeId: 5, icon: "figure.run"),
            ChartCategory(name: "爱情", typeId: 13, icon: "heart.fill"),
            ChartCategory(name: "科幻", typeId: 17, icon: "atom"),
            ChartCategory(name: "动画", typeId: 25, icon: "paintbrush.fill"),
            ChartCategory(name: "悬疑", typeId: 10, icon: "magnifyingglass"),
            ChartCategory(name: "惊悚", typeId: 19, icon: "exclamationmark.triangle.fill"),
            ChartCategory(name: "恐怖", typeId: 20, icon: "skull.fill"),
            ChartCategory(name: "纪录片", typeId: 1, icon: "doc.text.fill"),
            ChartCategory(name: "短片", typeId: 23, icon: "video.fill"),
            ChartCategory(name: "音乐", typeId: 14, icon: "music.note"),
            ChartCategory(name: "歌舞", typeId: 7, icon: "music.mic"),
            ChartCategory(name: "家庭", typeId: 28, icon: "house.fill"),
            ChartCategory(name: "儿童", typeId: 8, icon: "figure.child"),
            ChartCategory(name: "传记", typeId: 2, icon: "person.text.rectangle.fill"),
            ChartCategory(name: "历史", typeId: 4, icon: "clock.arrow.circlepath"),
            ChartCategory(name: "战争", typeId: 22, icon: "shield.fill"),
            ChartCategory(name: "犯罪", typeId: 3, icon: "lock.shield.fill"),
            ChartCategory(name: "西部", typeId: 27, icon: "sun.haze.fill"),
            ChartCategory(name: "奇幻", typeId: 16, icon: "wand.and.stars"),
            ChartCategory(name: "冒险", typeId: 15, icon: "map.fill"),
            ChartCategory(name: "灾难", typeId: 12, icon: "tornado"),
            ChartCategory(name: "武侠", typeId: 29, icon: "figure.martial.arts"),
            ChartCategory(name: "古装", typeId: 30, icon: "crown.fill"),
            ChartCategory(name: "运动", typeId: 18, icon: "sportscourt.fill"),
            ChartCategory(name: "黑色电影", typeId: 31, icon: "moon.fill")
        ]
    }
    
    // MARK: - API 响应模型
    struct ChartItem: Codable {
        let id: String
        let title: String
        let cover_url: String?
        let score: String?
        let vote_count: Int?
        let rank: Int?
        let types: [String]?
        let regions: [String]?
        let release_date: String?
        let actors: [String]?
        let url: String?
    }
    
    // MARK: - 排行榜条目
    struct ChartSubject: Identifiable, Hashable {
        let id: String
        let rank: Int
        let title: String
        let originalTitle: String?
        let coverURL: String?
        let rating: Double
        let ratingCount: String?
        let year: String?
        let info: String?
        let detailURL: String?
    }
    
    // MARK: - 获取分类排行榜
    func fetchCategoryRanking(
        category: ChartCategory,
        start: Int = 0,
        count: Int = 20
    ) async throws -> [ChartSubject] {
        let urlString = "https://movie.douban.com/j/chart/top_list?type=\(category.typeId)&interval_id=100:90&action=&start=\(start)&limit=\(count)"
        
        guard let url = URL(string: urlString) else {
            throw ChartError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://movie.douban.com/chart", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChartError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw ChartError.httpError(httpResponse.statusCode)
        }
        
        let items = try JSONDecoder().decode([ChartItem].self, from: data)
        
        return items.enumerated().map { (index, item) in
            ChartSubject(
                id: item.id,
                rank: item.rank ?? (start + index + 1),
                title: item.title,
                originalTitle: nil,
                coverURL: item.cover_url,
                rating: Double(item.score ?? "0") ?? 0,
                ratingCount: item.vote_count.map { "\($0)" },
                year: item.release_date.map { String($0.prefix(4)) },
                info: (item.types ?? []).joined(separator: " / "),
                detailURL: item.url ?? "https://movie.douban.com/subject/\(item.id)/"
            )
        }
    }
    
    // MARK: - 错误类型
    enum ChartError: LocalizedError {
        case invalidURL
        case invalidResponse
        case httpError(Int)
        
        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "无效的排行榜 URL"
            case .invalidResponse:
                return "服务器响应异常"
            case .httpError(let code):
                return "HTTP 错误: \(code)"
            }
        }
    }
}