import Foundation
import Combine

// MARK: - 弹幕数据模型
struct LogVarDanmakuItem: Identifiable, Codable {
    let id: Int           // 弹幕ID
    let time: Double      // 出现时间（秒）
    let type: Int         // 类型：1=滚动 4=底部 5=顶部
    let color: Int        // 颜色（十进制）
    let content: String   // 弹幕内容
    var pool: Int = 0     // 弹幕池
}



// MARK: - 弹幕 API 客户端
class LogVarDanmakuService: ObservableObject {
    static let shared = LogVarDanmakuService()
    
    private let baseURL = "https://uzdm.616222.xyz/87654321"
    private let session: URLSession
    private var cache: [String: [LogVarDanmakuItem]] = [:]  // "animeId_episode" -> items
    private var searchCache: [String: Int] = [:]      // "keyword" -> animeId
    private var retryCount = 0
    private let maxRetries = 3
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "vbox-ios/1.0"]
        session = URLSession(configuration: config)
    }
    
    // MARK: - 搜索剧集获取 anime_id
    func searchAnime(keyword: String) async -> Int? {
        let cacheKey = keyword.trimmingCharacters(in: .whitespaces)
        if let cached = searchCache[cacheKey] { return cached }
        
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/search/anime?keyword=\(encoded)") else { return nil }
        
        do {
            let (data, _) = try await session.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = json.first,
               let animeId = first["anime_id"] as? Int {
                searchCache[cacheKey] = animeId
                return animeId
            }
        } catch { print("[Danmaku] 搜索失败: \(error.localizedDescription)") }
        return nil
    }
    
    // MARK: - 获取弹幕数据
    func fetchDanmaku(animeId: Int, episode: Int) async -> [LogVarDanmakuItem] {
        let cacheKey = "\(animeId)_\(episode)"
        if let cached = cache[cacheKey] { return cached }
        
        let urlStr = "\(baseURL)/danmaku/\(animeId)/\(episode)?withSegment=true"
        guard let url = URL(string: urlStr) else { return [] }
        
        for attempt in 0..<maxRetries {
            do {
                let (data, _) = try await session.data(from: url)
                let items = try parseDanmakuResponse(data)
                cache[cacheKey] = items
                retryCount = 0
                return items
            } catch {
                print("[Danmaku] 获取失败(\(attempt+1)/\(maxRetries)): \(error.localizedDescription)")
                if attempt < maxRetries - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1_000_000_000))
                }
            }
        }
        return []
    }
    
    // MARK: - 解析弹幕响应（兼容 XML 和 JSON）
    private func parseDanmakuResponse(_ data: Data) throws -> [LogVarDanmakuItem] {
        // 尝试 JSON 解析
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let comments = json["comments"] as? [[String: Any]] {
            return comments.compactMap { dict in
                guard let cid = dict["cid"] as? Int ?? dict["id"] as? Int,
                      let p = dict["p"] as? String ?? dict["progress"] as? Double ?? (dict["time"] as? Double) else { return nil }
                let time: Double
                if let pStr = dict["p"] as? String {
                    time = Double(pStr.components(separatedBy: ",").first ?? "0") ?? 0
                } else {
                    time = (dict["progress"] as? Double) ?? (dict["time"] as? Double) ?? 0
                }
                let type = dict["type"] as? Int ?? 1
                let color = dict["color"] as? Int ?? 16777215
                let content = dict["m"] as? String ?? dict["content"] as? String ?? dict["text"] as? String ?? ""
                return LogVarDanmakuItem(id: cid, time: time, type: type, color: color, content: content)
            }
        }
        
        // 尝试 XML（弹弹play格式）解析
        if let xmlStr = String(data: data, encoding: .utf8) {
            return parseDanmakuXML(xmlStr)
        }
        
        return []
    }
    
    private func parseDanmakuXML(_ xml: String) -> [LogVarDanmakuItem] {
        var items: [LogVarDanmakuItem] = []
        let pattern = #"<d p="([^"]+)"[^>]*>([^<]+)</d>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        
        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
        for (idx, match) in matches.enumerated() {
            guard match.numberOfRanges >= 3,
                  let pRange = Range(match.range(at: 1), in: xml),
                  let cRange = Range(match.range(at: 2), in: xml) else { continue }
            
            let pStr = String(xml[pRange])
            let content = String(xml[cRange])
            let parts = pStr.components(separatedBy: ",")
            guard parts.count >= 4,
                  let time = Double(parts[0]),
                  let type = Int(parts[1]),
                  let color = Int(parts[3]) else { continue }
            
            items.append(LogVarDanmakuItem(id: idx, time: time, type: type, color: color, content: content))
        }
        return items
    }
    
    // MARK: - 清理缓存
    func clearCache() {
        cache.removeAll()
        searchCache.removeAll()
    }
}
