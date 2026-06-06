import Foundation
import Combine

struct LogVarDanmakuItem: Identifiable, Codable {
    let id: Int
    let time: Double
    let type: Int
    let color: Int
    let content: String
    var pool: Int = 0
}

class LogVarDanmakuService: ObservableObject {
    static let shared = LogVarDanmakuService()
    private let baseURL = "https://uzdm.616222.xyz/87654321"
    private let session: URLSession
    private var cache: [String: [LogVarDanmakuItem]] = [:]
    private var searchCache: [String: Int] = [:]
    private let maxRetries = 3

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "vbox-ios/1.0"]
        session = URLSession(configuration: config)
    }

    func searchAnime(keyword: String) async -> Int? {
        let key = keyword.trimmingCharacters(in: .whitespaces)
        if let c = searchCache[key] { return c }
        guard let e = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let u = URL(string: "\(baseURL)/search/anime?keyword=\(e)") else { return nil }
        do {
            let (d, _) = try await session.data(from: u)
            if let j = try JSONSerialization.jsonObject(with: d) as? [[String: Any]],
               let f = j.first, let aid = f["anime_id"] as? Int {
                searchCache[key] = aid; return aid
            }
        } catch { print("[Danmaku] search: \(error)") }
        return nil
    }

    func fetchDanmaku(animeId: Int, episode: Int) async -> [LogVarDanmakuItem] {
        let ck = "\(animeId)_\(episode)"
        if let c = cache[ck] { return c }
        guard let u = URL(string: "\(baseURL)/danmaku/\(animeId)/\(episode)?withSegment=true") else { return [] }
        for i in 0..<maxRetries {
            do {
                let (d, _) = try await session.data(from: u)
                let items = try parseDanmakuResponse(d)
                cache[ck] = items; return items
            } catch {
                print("[Danmaku] fetch \(i+1)/\(maxRetries): \(error)")
                if i < maxRetries - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(pow(2, Double(i)) * 1_000_000_000))
                }
            }
        }
        return []
    }

    private func parseDanmakuResponse(_ d: Data) throws -> [LogVarDanmakuItem] {
        if let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let comments = j["comments"] as? [[String: Any]] {
            return comments.compactMap { dd in
                guard let cid = dd["cid"] as? Int ?? dd["id"] as? Int else { return nil }
                let time: Double = {
                    if let p = dd["p"] as? String { return Double(p.components(separatedBy: ",").first ?? "0") ?? 0 }
                    return (dd["progress"] as? Double) ?? (dd["time"] as? Double) ?? 0
                }()
                return LogVarDanmakuItem(id: cid, time: time, type: dd["type"] as? Int ?? 1, color: dd["color"] as? Int ?? 16777215, content: dd["m"] as? String ?? dd["content"] as? String ?? dd["text"] as? String ?? "")
            }
        }
        if let x = String(data: d, encoding: .utf8) { return parseDanmakuXML(x) }
        return []
    }

    private func parseDanmakuXML(_ xml: String) -> [LogVarDanmakuItem] {
        var items: [LogVarDanmakuItem] = []
        let p = NSRegularExpression.escapedPattern(for: #"<d p="([^"]+)"[^>]*>([^<]+)</d>"#)
        guard let r = try? NSRegularExpression(pattern: p) else { return [] }
        for (idx, m) in r.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).enumerated() {
            guard m.numberOfRanges >= 3, let r1 = Range(m.range(at: 1), in: xml), let r2 = Range(m.range(at: 2), in: xml) else { continue }
            let ps = String(xml[r1]).components(separatedBy: ",")
            guard ps.count >= 4, let t = Double(ps[0]), let tp = Int(ps[1]), let c = Int(ps[3]) else { continue }
            items.append(LogVarDanmakuItem(id: idx, time: t, type: tp, color: c, content: String(xml[r2])))
        }
        return items
    }

    func clearCache() { cache.removeAll(); searchCache.removeAll() }
}
