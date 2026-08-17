import Foundation
import Kanna

// MARK: - 熊猫视频（API 接口类型）
// 对应脚本：熊猫视频[成人].py
// 站点：spiderscloudcn2.51111666.com
// 使用 POST 请求，接口: /getDataInit (分类), /forward (视频列表/详情/搜索)
class PandaVideoService: FuliBaseService {
    static let shared = PandaVideoService()

    init() {
        super.init(
            platformName: "熊猫视频",
            defaultHosts: [
                "https://spiderscloudcn2.51111666.com",
                "https://spiderscloudcn1.51111666.com"
            ],
            platformKey: "panda_video"
        )
    }

    // MARK: - POST API 调用
    private func postAPI(_ path: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: "\(currentHost)\(path)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        defaultHeaders(host: currentHost).forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - 首页分类 + 推荐
    override func fetchHomeContent() async -> FuliHomeResult {
        // 1. 获取分类
        var categories: [FuliCategory] = []
        do {
            let data = try await postAPI("/getDataInit", body: ["name": "John", "age": 31, "city": "New York"])
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let menu0ListMap = dataObj["menu0ListMap"] as? [[String: Any]] {

                // 从脚本逻辑：筛选 typeName 为 "传媒"、"视频"、"电影" 的一级分类
                for item in menu0ListMap {
                    guard let typeName = item["typeName"] as? String else { continue }
                    if typeName == "传媒" || typeName == "视频" || typeName == "电影" {
                        if let menu2List = item["menu2List"] as? [[String: Any]] {
                            for item1 in menu2List {
                                if let tid = item1["typeId2"] as? String,
                                   let tname = item1["typeName2"] as? String {
                                    categories.append(FuliCategory(typeId: tid, typeName: tname))
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            print("[熊猫视频] 获取分类失败: \(error)")
        }

        // 如果分类为空，使用默认分类
        if categories.isEmpty {
            categories = [
                FuliCategory(typeId: "24", typeName: "精品推荐"),
                FuliCategory(typeId: "21", typeName: "麻豆传媒"),
                FuliCategory(typeId: "22", typeName: "91制片"),
                FuliCategory(typeId: "23", typeName: "蜜桃传媒"),
                FuliCategory(typeId: "30", typeName: "日本无码"),
                FuliCategory(typeId: "31", typeName: "日本有码")
            ]
        }

        // 2. 获取首页推荐视频
        var videos: [FuliVideo] = []
        do {
            let body: [String: Any] = [
                "command": "WEB_GET_INFO",
                "pageNumber": 1,
                "RecordsPage": 20,
                "typeId": "24",
                "typeMid": "1",
                "languageType": "CN",
                "content": ""
            ]
            let data = try await postAPI("/forward", body: body)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let list = dataObj["resultList"] as? [[String: Any]] {
                videos = list.compactMap { parseVideoItem($0) }
            }
        } catch {
            print("[熊猫视频] 首页视频失败: \(error)")
        }

        return FuliHomeResult(categories: categories, videos: videos)
    }

    // MARK: - 分类内容
    override func fetchCategoryContent(category: FuliCategory, subCategory: FuliCategory?, page: Int) async -> FuliCategoryResult {
        let tid = subCategory?.typeId ?? category.typeId
        do {
            let body: [String: Any] = [
                "command": "WEB_GET_INFO",
                "pageNumber": page,
                "RecordsPage": 20,
                "typeId": tid,
                "typeMid": "1",
                "languageType": "CN",
                "content": ""
            ]
            let data = try await postAPI("/forward", body: body)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let list = dataObj["resultList"] as? [[String: Any]] {
                let videos = list.compactMap { parseVideoItem($0) }
                return FuliCategoryResult(videos: videos, page: page, hasMore: videos.count >= 20)
            }
        } catch {
            print("[熊猫视频] 分类失败: \(error)")
        }
        return FuliCategoryResult(videos: [], page: page, hasMore: false)
    }

    // MARK: - 详情
    override func fetchDetail(vodId: String) async -> FuliDetail {
        // vodId 格式: "id#serverId"
        let parts = vodId.components(separatedBy: "#")
        let cid = parts.first ?? vodId
        let svid = parts.count > 1 ? parts[1] : ""

        do {
            // 先获取站点配置（用于 macVodLinkMap）
            var linkMap: [String: [String: String]] = [:]
            do {
                let initData = try await postAPI("/getDataInit", body: ["name": "John", "age": 31, "city": "New York"])
                if let json = try? JSONSerialization.jsonObject(with: initData) as? [String: Any],
                   let dataObj = json["data"] as? [String: Any],
                   let macMap = dataObj["macVodLinkMap"] as? [String: [String: String]] {
                    linkMap = macMap
                }
            } catch {}

            let body: [String: Any] = [
                "command": "WEB_GET_INFO_DETAIL",
                "type_Mid": "1",
                "id": cid,
                "languageType": "CN"
            ]
            let data = try await postAPI("/forward", body: body)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let result = dataObj["result"] as? [String: Any] {

                let name = result["vod_name"] as? String ?? ""
                var pic = result["vod_pic"] as? String ?? ""
                let content = result["vod_content"] as? String
                var videoUrl = result["vod_url"] as? String ?? ""

                // 规范化封面图 URL
                pic = normalizeUrl(pic)

                // 拼接播放链接
                if !svid.isEmpty, let linkInfo = linkMap[svid], let link2 = linkInfo["LINK_2"] {
                    // 避免重复斜杠
                    let base = link2.hasSuffix("/") ? String(link2.dropLast()) : link2
                    let path = videoUrl.hasPrefix("/") ? videoUrl : "/\(videoUrl)"
                    videoUrl = base + path
                }

                // 规范化视频 URL
                videoUrl = normalizeUrl(videoUrl)

                print("[熊猫视频] 播放URL: \(videoUrl)")

                let episodes: [FuliEpisode] = videoUrl.isEmpty ? [] : [FuliEpisode(name: "播放", url: videoUrl)]
                return FuliDetail(vodId: vodId, vodName: name, vodPic: pic, vodContent: content, playFrom: "熊猫视频", episodes: episodes)
            }
        } catch {
            print("[熊猫视频] 详情失败: \(error)")
        }
        return FuliDetail(vodId: vodId, vodName: "", vodPic: "", vodContent: nil, playFrom: "熊猫视频", episodes: [])
    }

    // MARK: - URL 规范化
    private func normalizeUrl(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return "" }
        if u.hasPrefix("http://") || u.hasPrefix("https://") {
            return u
        }
        if u.hasPrefix("//") {
            return "https:" + u
        }
        if u.hasPrefix("/") {
            return currentHost + u
        }
        if !u.contains("://") {
            return "https://" + u
        }
        return u
    }

    // MARK: - 播放地址解析（重写基类方法）

    override func fetchPlayerURL(episode: FuliEpisode) async -> FuliPlayerResult {
        let url = episode.url

        // 如果已经是直接的视频URL，直接返回
        if url.contains(".m3u8") || url.contains(".mp4") || url.contains(".ts") {
            let normalized = normalizeUrl(url)
            print("[熊猫视频] 直接视频URL: \(normalized.prefix(80))")
            return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: currentHost), parse: 0)
        }

        do {
            let pageURL = normalizeUrl(url)
            let html = try await fetchHTML(pageURL)

            // 策略1：直接从 HTML 中解析视频URL
            if let videoURL = extractVideoURL(from: html) {
                let normalized = normalizeUrl(videoURL)
                print("[熊猫视频] 策略1成功 - 从HTML解析视频地址: \(normalized.prefix(80))")
                return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: currentHost), parse: 0)
            }

            // 策略2：查找 iframe 并递归解析
            if let iframeURL = extractIframeURL(from: html) {
                let iframeFull = normalizeUrl(iframeURL)
                print("[熊猫视频] 策略2 - 发现iframe: \(iframeFull.prefix(80))")
                do {
                    let iframeHTML = try await fetchHTML(iframeFull)
                    if let videoURL = extractVideoURL(from: iframeHTML) {
                        let normalized = normalizeUrl(videoURL)
                        print("[熊猫视频] 策略2成功 - 从iframe解析视频地址: \(normalized.prefix(80))")
                        return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: currentHost), parse: 0)
                    }
                    // iframe 中可能还有 iframe，再深入一层
                    if let innerIframeURL = extractIframeURL(from: iframeHTML) {
                        let innerFull = normalizeUrl(innerIframeURL)
                        do {
                            let innerHTML = try await fetchHTML(innerFull)
                            if let videoURL = extractVideoURL(from: innerHTML) {
                                let normalized = normalizeUrl(videoURL)
                                print("[熊猫视频] 策略2成功 - 从二级iframe解析: \(normalized.prefix(80))")
                                return FuliPlayerResult(url: normalized, headers: defaultHeaders(host: currentHost), parse: 0)
                            }
                        } catch {
                            print("[熊猫视频] 二级iframe请求失败: \(error)")
                        }
                    }
                } catch {
                    print("[熊猫视频] iframe请求失败: \(error)")
                }
            }

            // 所有策略失败，回退到WebView解析
            print("[熊猫视频] 所有策略失败，回退到WebView解析")
            return FuliPlayerResult(url: pageURL, headers: defaultHeaders(host: currentHost), parse: 1)

        } catch {
            print("[熊猫视频] fetchPlayerURL 失败: \(error)")
            return FuliPlayerResult(url: url, headers: defaultHeaders(host: currentHost), parse: 1)
        }
    }

    // MARK: - 辅助方法：从HTML提取视频URL（7种解析策略）

    private func extractVideoURL(from html: String) -> String? {
        // 策略1：m3u8 绝对路径
        let m3u8AbsPattern = #"https?://[^"'\s<>]+\.m3u8[^"'\s<>]*"#
        if let range = html.range(of: m3u8AbsPattern, options: .regularExpression) {
            let url = String(html[range])
            if !isLikelyAdURL(url) {
                return url
            }
        }

        // 策略2：mp4 绝对路径
        let mp4AbsPattern = #"https?://[^"'\s<>]+\.mp4[^"'\s<>]*"#
        if let range = html.range(of: mp4AbsPattern, options: .regularExpression) {
            let url = String(html[range])
            if !isLikelyAdURL(url) {
                return url
            }
        }

        // 策略3：相对路径 m3u8
        let m3u8RelPattern = #"/[^"'\s<>]+\.m3u8[^"'\s<>]*"#
        if let range = html.range(of: m3u8RelPattern, options: .regularExpression) {
            let url = String(html[range])
            if !isLikelyAdURL(url) {
                return url
            }
        }

        // 策略4：video 标签 src
        let doc = try? HTML(html: html, encoding: .utf8)
        if let d = doc {
            let videoSelectors = [
                "//video/source/@src",
                "//video/@src",
                "//video/source/@data-src",
                "//video/@data-src",
                "//source/@src",
            ]
            for sel in videoSelectors {
                if let src = d.xpath(sel).first?.text?.trimmingCharacters(in: .whitespaces),
                   !src.isEmpty, !src.hasPrefix("about:") {
                    return src
                }
            }
        }

        // 策略5：url 字段（JSON中）
        let urlJsonPattern = #""url"\s*:\s*"([^"]+\.(?:m3u8|mp4|ts)[^"]*)""#
        if let regex = try? NSRegularExpression(pattern: urlJsonPattern),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let r = Range(match.range(at: 1), in: html) {
            return String(html[r])
        }

        // 策略6：vod_url 字段
        let vodUrlPattern = #""vod_url"\s*:\s*"([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: vodUrlPattern),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let r = Range(match.range(at: 1), in: html) {
            let url = String(html[r])
            if !url.isEmpty {
                return url
            }
        }

        // 策略7：video_url 字段
        let videoUrlPattern = #""video_url"\s*:\s*"([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: videoUrlPattern),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let r = Range(match.range(at: 1), in: html) {
            let url = String(html[r])
            if !url.isEmpty {
                return url
            }
        }

        return nil
    }

    // MARK: - 辅助方法：从HTML提取iframe URL

    private func extractIframeURL(from html: String) -> String? {
        let doc = try? HTML(html: html, encoding: .utf8)
        guard let d = doc else { return nil }

        // 优先匹配播放器相关的 iframe
        let iframeSelectors = [
            "//iframe[@id='player_iframe']/@src",
            "//iframe[contains(@class,'player')]/@src",
            "//iframe[contains(@id,'play')]/@src",
            "//iframe[contains(@name,'play')]/@src",
            "//iframe/@src",
            "//embed/@src",
        ]

        for sel in iframeSelectors {
            if let src = d.xpath(sel).first?.text?.trimmingCharacters(in: .whitespaces),
               !src.isEmpty,
               !src.hasPrefix("about:"),
               !src.hasPrefix("javascript:") {
                // 排除广告和第三方 iframe
                if !isLikelyAdURL(src) {
                    return src
                }
            }
        }
        return nil
    }

    // MARK: - 辅助方法：判断是否为广告URL

    private func isLikelyAdURL(_ url: String) -> Bool {
        let adKeywords = ["ad.", "ads.", "advert", "banner", "popup", "track", "stat", "analytic", "googleads", "doubleclick"]
        let lower = url.lowercased()
        for kw in adKeywords {
            if lower.contains(kw) {
                return true
            }
        }
        return false
    }

    // MARK: - 搜索
    override func fetchSearch(keyword: String, page: Int) async -> FuliSearchResult {
        do {
            let body: [String: Any] = [
                "command": "WEB_GET_INFO",
                "pageNumber": page,
                "RecordsPage": 20,
                "typeId": "0",
                "typeMid": "1",
                "languageType": "CN",
                "content": keyword,
                "type": "1"
            ]
            let data = try await postAPI("/forward", body: body)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let list = dataObj["resultList"] as? [[String: Any]] {
                let videos = list.compactMap { parseVideoItem($0) }
                return FuliSearchResult(videos: videos, page: page, hasMore: videos.count >= 20)
            }
        } catch {
            print("[熊猫视频] 搜索失败: \(error)")
        }
        return FuliSearchResult(videos: [], page: page, hasMore: false)
    }

    // MARK: - 解析视频条目
    private func parseVideoItem(_ item: [String: Any]) -> FuliVideo? {
        guard let id = item["id"] as? Int else { return nil }
        var name = (item["vod_name"] as? String ?? "")
            .replacingOccurrences(of: "yy8ycom", with: "")
        // 清理名称中的冗余部分
        let pattern = "(.*?)-(.*?)-\\d+\\s+"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            name = regex.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: "")
        }
        guard !name.isEmpty else { return nil }

        let pic = normalizeUrl(item["vod_pic"] as? String ?? "")
        let id2 = item["vod_server_id"] as? Int ?? 0

        // vodId 格式: id#serverId
        let vodId = id2 > 0 ? "\(id)#\(id2)" : "\(id)"
        return FuliVideo(vodId: vodId, vodName: name, vodPic: pic)
    }
}
