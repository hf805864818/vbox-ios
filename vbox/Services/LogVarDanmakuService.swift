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

/// 弹幕搜索结果（番剧）
struct DanmakuSearchResult: Identifiable {
    let id: Int          // animeId
    let animeTitle: String
    let type: String     // TV/剧场版/OVA 等
    let episodes: [DanmakuEpisodeInfo]
}

/// 弹幕剧集信息
struct DanmakuEpisodeInfo: Identifiable {
    let id: Int          // episodeId
    let episodeNumber: Int
    let episodeTitle: String
}

class LogVarDanmakuService: ObservableObject {
    static let shared = LogVarDanmakuService()
    /// 默认弹幕源
    private static let defaultBaseURL = "https://uzdm.616222.xyz"
    private let session: URLSession
    private var cache: [String: [LogVarDanmakuItem]] = [:]
    private var matchCache: [String: Int] = [:]
    private let maxRetries = 3

    /// 当前生效的弹幕源地址：用户开启自定义源时使用自定义URL，否则使用默认源
    private var baseURL: String {
        let enabled = UserDefaults.standard.bool(forKey: "custom_danmaku_source_enabled")
        if enabled {
            let customURL = UserDefaults.standard.string(forKey: "custom_danmaku_source_url") ?? ""
            let trimmed = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // 去掉末尾的斜杠
                return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
            }
        }
        return Self.defaultBaseURL
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "vbox-ios/1.0"]
        session = URLSession(configuration: config)
    }

    func searchAnime(keyword: String) async -> Int? {
        let key = keyword.trimmingCharacters(in: .whitespaces)
        if let c = matchCache[key] { return c }
        guard let e = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let u = URL(string: "\(baseURL)/api/v2/search/anime?keyword=\(e)") else { return nil }
        do {
            let (d, _) = try await session.data(from: u)
            if let root = try JSONSerialization.jsonObject(with: d) as? [String: Any],
               let animes = root["animes"] as? [[String: Any]],
               let first = animes.first,
               let animeId = first["animeId"] as? Int {
                matchCache[key] = animeId
                return animeId
            }
            if let j = try JSONSerialization.jsonObject(with: d) as? [[String: Any]],
               let f = j.first,
               let aid = f["anime_id"] as? Int ?? f["animeId"] as? Int {
                matchCache[key] = aid; return aid
            }
        } catch { print("[Danmaku] search: \(error)") }
        return nil
    }

    func searchAnimeDetailed(keyword: String) async -> [DanmakuSearchResult] {
        guard let e = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let u = URL(string: "\(baseURL)/api/v2/search/anime?keyword=\(e)") else { return [] }
        do {
            let (d, _) = try await session.data(from: u)
            if let root = try JSONSerialization.jsonObject(with: d) as? [String: Any],
               let animes = root["animes"] as? [[String: Any]] {
                return animes.map { anime in
                    let id = anime["animeId"] as? Int ?? 0
                    let title = anime["animeTitle"] as? String ?? ""
                    let type = anime["type"] as? String ?? "TV"
                    let episodes = (anime["episodes"] as? [[String: Any]])?.compactMap { ep in
                        DanmakuEpisodeInfo(
                            id: ep["episodeId"] as? Int ?? 0,
                            episodeNumber: ep["episodeNumber"] as? Int ?? 0,
                            episodeTitle: ep["episodeTitle"] as? String ?? ""
                        )
                    } ?? []
                    return DanmakuSearchResult(id: id, animeTitle: title, type: type, episodes: episodes)
                }
            }
        } catch { print("[Danmaku] search detailed: \(error)") }
        return []
    }

    func fetchBangumiEpisodes(animeId: Int) async -> [DanmakuEpisodeInfo] {
        guard let bangumiURL = URL(string: "\(baseURL)/api/v2/bangumi/\(animeId)") else { return [] }
        do {
            let (data, _) = try await session.data(from: bangumiURL)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bangumi = root["bangumi"] as? [String: Any],
                  let episodes = bangumi["episodes"] as? [[String: Any]] else { return [] }
            return episodes.compactMap { ep in
                let id = ep["episodeId"] as? Int ?? 0
                let num = ep["episodeNumber"] as? Int ?? Int(ep["episodeNumber"] as? String ?? "0") ?? 0
                let title = ep["episodeTitle"] as? String ?? ""
                return DanmakuEpisodeInfo(id: id, episodeNumber: num, episodeTitle: title)
            }
        } catch {
            print("[Danmaku] fetch bangumi episodes: \(error)")
        }
        return []
    }

    func matchEpisode(fileName: String) async -> Int? {
        let key = normalizeFileName(fileName)
        if let cached = matchCache[key] { return cached }
        guard let url = URL(string: "\(baseURL)/api/v2/match") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["fileName": key], options: [])

        do {
            let (data, _) = try await session.data(for: request)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (root["success"] as? Bool) == true,
                  let matches = root["matches"] as? [[String: Any]],
                  let first = matches.first,
                  let episodeId = first["episodeId"] as? Int else {
                return nil
            }
            matchCache[key] = episodeId
            return episodeId
        } catch {
            print("[Danmaku] match: \(error)")
            return nil
        }
    }

    func fetchDanmaku(animeId: Int, episode: Int) async -> [LogVarDanmakuItem] {
        let ck = "\(animeId)_\(episode)"
        if let c = cache[ck] { return c }
        // 通过 bangumi 接口获取剧集列表，找到对应集数的 episodeId
        guard let bangumiURL = URL(string: "\(baseURL)/api/v2/bangumi/\(animeId)") else { return [] }
        do {
            let (data, _) = try await session.data(from: bangumiURL)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bangumi = root["bangumi"] as? [String: Any],
                  let episodes = bangumi["episodes"] as? [[String: Any]] else { return [] }
            // 按集数匹配 episodeId
            let targetEpisode = episodes.first { ep in
                let epNum = ep["episodeNumber"] as? Int ?? Int(ep["episodeNumber"] as? String ?? "0") ?? 0
                return epNum == episode
            } ?? episodes.first  // 找不到精确匹配时用第一条
            guard let episodeId = targetEpisode?["episodeId"] as? Int else { return [] }
            return await fetchDanmaku(episodeId: episodeId)
        } catch {
            print("[Danmaku] bangumi fetch: \(error)")
            return []
        }
    }

    func fetchDanmaku(episodeId: Int) async -> [LogVarDanmakuItem] {
        let ck = "episode_\(episodeId)"
        if let cached = loadPersistentCache(key: ck) {
            cache[ck] = cached
            return cached
        }
        guard let url = URL(string: "\(baseURL)/api/v2/comment/\(episodeId)") else { return [] }
        return await fetchDanmaku(url: url, cacheKey: ck)
    }

    func matchAndFetch(fileName: String) async -> [LogVarDanmakuItem] {
        print("[Danmaku] matchAndFetch 开始，输入: \(fileName)")
        
        // 路径1: 通过 match API 匹配
        if let episodeId = await matchEpisode(fileName: fileName) {
            print("[Danmaku] ✅ match成功，episodeId=\(episodeId)")
            let items = await fetchDanmaku(episodeId: episodeId)
            if !items.isEmpty {
                print("[Danmaku] ✅ 获取到 \(items.count) 条弹幕")
                return items
            }
            print("[Danmaku] ⚠️ episodeId=\(episodeId) 但弹幕为空")
        } else {
            print("[Danmaku] ⚠️ match失败，尝试 searchAnime fallback...")
        }
        
        // 路径2: match 失败时，提取剧名通过 searchAnime 搜索
        let animeName = extractAnimeName(from: fileName)
        guard !animeName.isEmpty else {
            print("[Danmaku] ❌ 无法从文件名提取剧名: \(fileName)")
            return []
        }
        print("[Danmaku] 尝试搜索剧名: \(animeName)")
        
        if let animeId = await searchAnime(keyword: animeName) {
            print("[Danmaku] ✅ searchAnime成功，animeId=\(animeId)")
            // 尝试从文件名提取集数
            let episode = extractEpisodeNumber(from: fileName)
            let items = await fetchDanmaku(animeId: animeId, episode: episode)
            if !items.isEmpty {
                print("[Danmaku] ✅ 通过searchAnime获取到 \(items.count) 条弹幕")
                return items
            }
            print("[Danmaku] ⚠️ animeId=\(animeId) episode=\(episode) 弹幕为空")
        } else {
            print("[Danmaku] ❌ searchAnime也失败: \(animeName)")
        }
        
        return []
    }
    
    /// 从文件名提取剧名（去掉集数、季数、后缀等）
    private func extractAnimeName(from fileName: String) -> String {
        var name = (fileName as NSString).deletingPathExtension
        // 去掉常见的前缀/后缀标记
        name = name
            .replacingOccurrences(of: #"\[[^\]]+\]|\([^\)]*\)|【[^】]+】"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s._\-]+(?:S\d{1,2})?(?:E\d{1,3})?(?:EP?\d{1,3})?$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"第\s*\d{1,3}\s*[集话话期].*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name
    }
    
    /// 从文件名提取集数（默认第1集）
    private func extractEpisodeNumber(from fileName: String) -> Int {
        let name = (fileName as NSString).deletingPathExtension
        // 匹配 E01, EP01, 第1集 等格式
        let patterns = [
            #"[Ee][Pp]?(\d{1,3})(?:\b|[^0-9])"#,
            #"第\s*(\d{1,3})\s*[集话话期]"#,
            #"\.\s*(\d{1,3})\s*\."#
        ]
        for pattern in patterns {
            if let range = name.range(of: pattern, options: .regularExpression) {
                let numStr = String(name[range]).filter { $0.isNumber }
                if let num = Int(numStr), num > 0 {
                    return num
                }
            }
        }
        return 1
    }

    private func fetchDanmaku(url: URL, cacheKey: String) async -> [LogVarDanmakuItem] {
        for i in 0..<maxRetries {
            do {
                let (d, _) = try await session.data(from: url)
                let items = try parseDanmakuResponse(d)
                cache[cacheKey] = items
                savePersistentCache(items, key: cacheKey)
                return items
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
        let pattern = #"<d p="([^"]+)"[^>]*>([^<]+)</d>"#
        guard let r = try? NSRegularExpression(pattern: pattern) else { return [] }
        for (idx, m) in r.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).enumerated() {
            guard m.numberOfRanges >= 3, let r1 = Range(m.range(at: 1), in: xml), let r2 = Range(m.range(at: 2), in: xml) else { continue }
            let ps = String(xml[r1]).components(separatedBy: ",")
            guard ps.count >= 4, let t = Double(ps[0]), let tp = Int(ps[1]), let c = Int(ps[3]) else { continue }
            items.append(LogVarDanmakuItem(id: idx, time: t, type: tp, color: c, content: String(xml[r2])))
        }
        return items
    }

    private func normalizeFileName(_ fileName: String) -> String {
        let withoutExt = (fileName as NSString).deletingPathExtension
        var result = withoutExt
            .replacingOccurrences(of: #"\[[^\]]+\]|\([^\)]*\)|【[^】]+】"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 提取季数
        let seasonPattern = #"[Ss](\d{1,2})"#
        var seasonStr = ""
        if let seasonMatch = result.range(of: seasonPattern, options: .regularExpression) {
            seasonStr = "S" + String(result[seasonMatch]).uppercased().filter { $0.isNumber }
        }

        // 统一处理各种集数格式：
        // 中文格式: "第1集" / "第01集" / "第1话" → ".E01"
        // 英文格式: "E01" / "EP01" / "e01" → 保持原样
        // 纯数字: "01" / "1" (前后有空格或点号) → ".E01"
        let epCNPattern = #"第\s*(\d{1,3})\s*[集话话期]"#
        let epENPattern = #"[Ee][Pp]?(\d{1,3})\b"#
        let epNumPattern = #"(?<![0-9A-Za-z])(\d{1,3})(?![0-9A-Za-z])"#

        // 优先匹配中文集数
        if let epMatch = result.range(of: epCNPattern, options: .regularExpression) {
            let epText = String(result[epMatch])
            let epNum = epText.filter { $0.isNumber }
            let padded = String(format: "%02d", Int(epNum) ?? 1)
            result = result.replacingCharacters(in: epMatch, with: ".E\(padded)")
        }
        // 其次匹配英文集数格式
        else if let epMatch = result.range(of: epENPattern, options: .regularExpression) {
            let epText = String(result[epMatch])
            let epNum = epText.filter { $0.isNumber }
            let padded = String(format: "%02d", Int(epNum) ?? 1)
            result = result.replacingCharacters(in: epMatch, with: "E\(padded)")
        }
        // 最后尝试匹配纯数字（在空格分隔的位置）
        else if let epMatch = result.range(of: epNumPattern, options: .regularExpression) {
            let epNum = String(result[epMatch]).filter { $0.isNumber }
            if let num = Int(epNum), num > 0 && num <= 100 {
                let padded = String(format: "%02d", num)
                result = result.replacingCharacters(in: epMatch, with: ".E\(padded)")
            }
        }

        // 如果有季数但结果中没有S前缀，在开头添加
        if !seasonStr.isEmpty && !result.contains("S") {
            result = "\(seasonStr).\(result)"
        }

        // 清理多余空格和点号
        result = result
            .replacingOccurrences(of: #"\s*\.\s*"#, with: ".", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return result
    }

    private func persistentKey(_ key: String) -> String {
        "logvar_danmaku_\(key)"
    }

    private func loadPersistentCache(key: String) -> [LogVarDanmakuItem]? {
        guard let data = UserDefaults.standard.data(forKey: persistentKey(key)),
              let items = try? JSONDecoder().decode([LogVarDanmakuItem].self, from: data) else {
            return nil
        }
        return items
    }

    private func savePersistentCache(_ items: [LogVarDanmakuItem], key: String) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: persistentKey(key))
    }

    func sendDanmaku(episodeId: Int, content: String, time: Double, mode: Int = 1, color: Int = 16777215) async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/v2/comment/\(episodeId)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "time": time,
            "mode": mode,
            "color": color,
            "comment": content
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        do {
            let (data, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                print("[Danmaku] 发送成功: \(content)")
                return true
            } else if let str = String(data: data, encoding: .utf8) {
                print("[Danmaku] 发送失败: \(str)")
            }
        } catch {
            print("[Danmaku] 发送异常: \(error)")
        }
        return false
    }

    func clearCache() { cache.removeAll(); matchCache.removeAll() }
}
