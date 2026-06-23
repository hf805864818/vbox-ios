import Foundation

// MARK: - 豆瓣 Chart 排行榜服务
/// 负责爬取 movie.douban.com/chart 上的分类排行榜 HTML 并解析
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
            ChartCategory(name: "武侠", typeId: 29, icon: "person.fill"),
            ChartCategory(name: "古装", typeId: 30, icon: "crown.fill"),
            ChartCategory(name: "运动", typeId: 18, icon: "sportscourt.fill"),
            ChartCategory(name: "黑色电影", typeId: 31, icon: "moon.fill")
        ]
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
    
    // MARK: - 爬取分类排行榜
    func fetchCategoryRanking(
        category: ChartCategory,
        start: Int = 0,
        count: Int = 20
    ) async throws -> [ChartSubject] {
        let urlString = "https://movie.douban.com/typerank?type_name=\(category.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? category.name)&type=\(category.typeId)&interval_id=100:90&action=&start=\(start)"
        
        guard let url = URL(string: urlString) else {
            throw ChartError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChartError.invalidResponse
        }
        
        // 如果被重定向到登录页，抛出需要登录错误
        if httpResponse.statusCode == 302 || httpResponse.url?.absoluteString.contains("accounts.douban.com") == true {
            throw ChartError.needLogin
        }
        
        guard httpResponse.statusCode == 200 else {
            throw ChartError.httpError(httpResponse.statusCode)
        }
        
        guard let html = String(data: data, encoding: .utf8) else {
            throw ChartError.encodingError
        }
        
        // 检查是否被反爬拦截
        if html.contains("登录跳转") || html.contains("异常请求") {
            throw ChartError.needLogin
        }
        
        return try parseChartHTML(html: html, startRank: start + 1)
    }
    
    // MARK: - HTML 解析
    private func parseChartHTML(html: String, startRank: Int) throws -> [ChartSubject] {
        var subjects: [ChartSubject] = []
        
        // 豆瓣 typerank 页面常见的几种条目结构
        
        // 方案1：新版 div.item 结构
        let itemPattern = #"<div class=\"item\"[^>]*>.*?<\/div>\s*<\/div>"#
        if let regex = try? NSRegularExpression(pattern: itemPattern, options: [.dotMatchesLineSeparators]),
           regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html)).count > 0 {
            return try parseItemDivStructure(html: html, startRank: startRank)
        }
        
        // 方案2：表格结构
        let trPattern = #"<tr[^>]*>.*?<td[^>]*class=\"poster\".*?</tr>"#
        if let regex = try? NSRegularExpression(pattern: trPattern, options: [.dotMatchesLineSeparators]),
           regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html)).count > 0 {
            return try parseTableStructure(html: html, startRank: startRank)
        }
        
        // 方案3：通用列表结构
        return try parseGenericStructure(html: html, startRank: startRank)
    }
    
    // MARK: - 解析新版 div.item 结构
    private func parseItemDivStructure(html: String, startRank: Int) throws -> [ChartSubject] {
        var subjects: [ChartSubject] = []
        
        // 匹配每个 item 块
        let itemPattern = #"<div class=\"item\"[^>]*>(.*?)<\/div>\s*<\/div>"#
        guard let itemRegex = try? NSRegularExpression(pattern: itemPattern, options: [.dotMatchesLineSeparators]) else {
            throw ChartError.parseError("无法创建 item 正则")
        }
        
        let matches = itemRegex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
        
        for (index, match) in matches.enumerated() {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let itemHTML = String(html[range])
            
            if let subject = parseSubject(from: itemHTML, rank: startRank + index) {
                subjects.append(subject)
            }
        }
        
        return subjects
    }
    
    // MARK: - 解析表格结构
    private func parseTableStructure(html: String, startRank: Int) throws -> [ChartSubject] {
        var subjects: [ChartSubject] = []
        
        let trPattern = #"<tr[^>]*>(.*?)<\/tr>"#
        guard let trRegex = try? NSRegularExpression(pattern: trPattern, options: [.dotMatchesLineSeparators]) else {
            throw ChartError.parseError("无法创建 tr 正则")
        }
        
        let matches = trRegex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
        
        for (index, match) in matches.enumerated() {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let trHTML = String(html[range])
            
            // 只处理包含 subject 链接的行
            if trHTML.contains("/subject/"),
               let subject = parseSubject(from: trHTML, rank: startRank + index) {
                subjects.append(subject)
            }
        }
        
        return subjects
    }
    
    // MARK: - 通用列表结构解析
    private func parseGenericStructure(html: String, startRank: Int) throws -> [ChartSubject] {
        var subjects: [ChartSubject] = []
        
        // 先尝试按 subject 链接分组
        let subjectPattern = #"<a[^>]*href=\"https://movie\.douban\.com/subject/(\d+)/\"[^>]*>(.*?)</a>"#
        guard let subjectRegex = try? NSRegularExpression(pattern: subjectPattern, options: [.dotMatchesLineSeparators]) else {
            throw ChartError.parseError("无法创建 subject 正则")
        }
        
        let matches = subjectRegex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
        
        for (index, match) in matches.enumerated() {
            guard let idRange = Range(match.range(at: 1), in: html),
                  let contentRange = Range(match.range(at: 2), in: html) else { continue }
            
            let subjectId = String(html[idRange])
            let titleHTML = String(html[contentRange])
            
            // 提取标题（去掉 HTML 标签）
            let title = titleHTML.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard !title.isEmpty else { continue }
            
            // 在 title 周围 1000 字符内查找更多信息
            let matchStart = match.range.location
            let contextStart = max(0, matchStart - 500)
            let contextEnd = min(html.utf16.count, matchStart + 1000)
            let contextRange = NSRange(location: contextStart, length: contextEnd - contextStart)
            guard let contextSwiftRange = Range(contextRange, in: html) else { continue }
            let contextHTML = String(html[contextSwiftRange])
            
            let coverURL = extractCover(from: contextHTML)
            let rating = extractRating(from: contextHTML)
            let ratingCount = extractRatingCount(from: contextHTML)
            let year = extractYear(from: contextHTML)
            let info = extractInfo(from: contextHTML)
            
            subjects.append(ChartSubject(
                id: subjectId,
                rank: startRank + index,
                title: title,
                originalTitle: nil,
                coverURL: coverURL,
                rating: rating,
                ratingCount: ratingCount,
                year: year,
                info: info,
                detailURL: "https://movie.douban.com/subject/\(subjectId)/"
            ))
        }
        
        return subjects
    }
    
    // MARK: - 解析单个条目
    private func parseSubject(from html: String, rank: Int) -> ChartSubject? {
        // 提取 subject ID
        guard let idMatch = html.range(of: #"/subject/(\d+)/"#, options: .regularExpression) else { return nil }
        let idString = String(html[idMatch])
        let subjectId = idString.replacingOccurrences(of: #"\D"#, with: "", options: .regularExpression)
        guard !subjectId.isEmpty else { return nil }
        
        // 提取标题
        let title = extractTitle(from: html)
        guard !title.isEmpty else { return nil }
        
        let coverURL = extractCover(from: html)
        let rating = extractRating(from: html)
        let ratingCount = extractRatingCount(from: html)
        let year = extractYear(from: html)
        let info = extractInfo(from: html)
        let originalTitle = extractOriginalTitle(from: html)
        
        return ChartSubject(
            id: subjectId,
            rank: rank,
            title: title,
            originalTitle: originalTitle,
            coverURL: coverURL,
            rating: rating,
            ratingCount: ratingCount,
            year: year,
            info: info,
            detailURL: "https://movie.douban.com/subject/\(subjectId)/"
        )
    }
    
    // MARK: - 提取字段
    private func extractTitle(from html: String) -> String {
        // 方案1：item 中的标题链接
        let patterns = [
            #"<span class=\"pl2\">\s*<a[^>]*>([^<]+)"#,
            #"<em>([^<]+)</em>"#,
            #"class=\"title\"[^>]*>([^<]+)"#,
            #"<a[^>]*href=\"/subject/\d+/\"[^>]*>([^<]+)</a>"#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                return String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        return ""
    }
    
    private func extractOriginalTitle(from html: String) -> String? {
        let pattern = #"<span class=\"other-title\"[^>]*>([^<]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let title = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
    
    private func extractCover(from html: String) -> String? {
        let patterns = [
            #"<img[^>]*src=\"([^\"]+)\"[^>]*width=\"\d+\"[^>]*height=\"\d+\""#,
            #"<img[^>]*src=\"([^\"]+)\"[^>]*alt=\"[^\"]*\""#,
            #"<img[^>]*src=\"([^\"]+)\""#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let url = String(html[range])
                // 优先选择豆瓣图片域名
                if url.contains("doubanio.com") || url.contains("douban.com") {
                    return url
                }
            }
        }
        
        // 兜底：取第一个 img src
        let pattern = #"<img[^>]*src=\"([^\"]+)\""#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            return String(html[range])
        }
        
        return nil
    }
    
    private func extractRating(from html: String) -> Double {
        let pattern = #"<span class=\"rating_nums?\">([\d.]+)</span>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let value = Double(String(html[range])) else { return 0 }
        return value
    }
    
    private func extractRatingCount(from html: String) -> String? {
        let pattern = #"\((\d+)人评价\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }
    
    private func extractYear(from html: String) -> String? {
        let pattern = #"(\d{4})"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            let year = String(html[range])
            if year >= "1900" && year <= "2030" {
                return year
            }
        }
        return nil
    }
    
    private func extractInfo(from html: String) -> String? {
        // 提取导演/演员/地区等信息
        let patterns = [
            #"<p class=\"pl\">([^<]+)</p>"#,
            #"<span class=\"pl\">([^<]+)</span>"#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let info = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "&nbsp;", with: " ")
                if info.count > 5 {
                    return info
                }
            }
        }
        
        return nil
    }
    
    // MARK: - 错误类型
    enum ChartError: LocalizedError {
        case invalidURL
        case invalidResponse
        case httpError(Int)
        case encodingError
        case needLogin
        case parseError(String)
        
        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "无效的排行榜 URL"
            case .invalidResponse:
                return "服务器响应异常"
            case .httpError(let code):
                return "HTTP 错误: \(code)"
            case .encodingError:
                return "网页编码解析失败"
            case .needLogin:
                return "豆瓣需要登录才能访问排行榜，请先在设置中登录豆瓣账号"
            case .parseError(let msg):
                return "页面解析失败: \(msg)"
            }
        }
    }
}
