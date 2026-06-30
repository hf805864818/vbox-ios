import Foundation

// MARK: - CMS 标准 API 响应模型
struct CMSVodItem: Codable {
    let vodId: String; let vodName: String?; let vodPic: String?
    let vodRemarks: String?; let vodYear: String?; let vodArea: String?
    let vodDirector: String?; let vodActor: String?; let vodContent: String?
    let vodPlayFrom: String?; let vodPlayUrl: String?; let typeName: String?
    private enum CodingKeys: String, CodingKey {
        case vodId="vod_id", vodName="vod_name", vodPic="vod_pic"
        case vodRemarks="vod_remarks", vodYear="vod_year", vodArea="vod_area"
        case vodDirector="vod_director", vodActor="vod_actor", vodContent="vod_content"
        case vodPlayFrom="vod_play_from", vodPlayUrl="vod_play_url", typeName="type_name"
    }
    func toVodItem() -> VodItem {
        let r = (vodRemarks ?? typeName ?? ""); let tagged = r.hasPrefix("[福利]") ? r : "[福利]"+r
        return VodItem(vodId: vodId, vodName: vodName ?? "", vodPic: vodPic ?? "",
                       vodRemarks: tagged, vodYear: vodYear, vodArea: vodArea,
                       vodDirector: vodDirector, vodActor: vodActor,
                       vodContent: vodContent, vodPlayFrom: vodPlayFrom, vodPlayUrl: vodPlayUrl)
    }
}

struct CMSVodResponse: Codable { let code: Int?; let list: [CMSVodItem]? }

// MARK: - 福利爬虫引擎
@MainActor
final class WelfareCrawlerService {
    static let shared = WelfareCrawlerService()
    private let session: URLSession; private let timeout: TimeInterval = 15

    private init() {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = timeout; c.timeoutIntervalForResource = 30
        c.httpMaximumConnectionsPerHost = 3
        session = URLSession(configuration: c)
    }

    // MARK: - 主入口
    func fetch(platformId: String, pageKind: WelfarePageKind, page: Int = 1,
               onBatch: (([VodItem]) -> Void)? = nil) async -> [VodItem] {
        guard let cfg = WelfareCrawlerConfig.config(for: platformId) else {
            return await fallback(id: platformId, kind: pageKind, onBatch: onBatch)
        }
        switch cfg.parserType {
        case .apiJson:   return await fetchCMS(cfg: cfg, kind: pageKind, pg: page, onBatch: onBatch)
        case .pwaApi:    return await fetchPWA(cfg: cfg, kind: pageKind, pg: page, onBatch: onBatch)
        case .encPost:   return await fetchEncPost(cfg: cfg, kind: pageKind, pg: page, onBatch: onBatch)
        case .htmlRegex: return await fetchHTML(cfg: cfg, kind: pageKind, pg: page, onBatch: onBatch)
        case .spiderFallback: return await fallback(id: platformId, kind: pageKind, onBatch: onBatch)
        case .disabled: return []
        }
    }

    // MARK: - CMS JSON API (apiJson) - 支持 open / encrypted 两种模式
    private func fetchCMS(cfg: WelfareCrawlerConfig, kind: WelfarePageKind, pg: Int,
                          onBatch: (([VodItem]) -> Void)?) async -> [VodItem] {
        if cfg.apiMode == .open {
            return await fetchCMSOpen(cfg: cfg, kind: kind, pg: pg, onBatch: onBatch)
        }
        // encrypted 模式：POST + 加密data字段（原逻辑）
        let apiPath = cmsApiPath(for: kind)
        let urlStr = "\(cfg.baseURL)\(apiPath)"
        guard let url = URL(string: urlStr) else { return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch) }

        var req = URLRequest(url: url); req.timeoutInterval = timeout
        req.httpMethod = "POST"
        let body = "timestamp=\(Int(Date().timeIntervalSince1970))&data=\(randomHex(32))"
        req.httpBody = body.data(using: .utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(cfg.baseURL, forHTTPHeaderField: "Referer")

        guard let data = await request(req) else { return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch) }
        let items = parseVodJSON(data)
        if items.isEmpty { return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch) }
        onBatch?(items); return items
    }

    // MARK: - 开放 CMS API（GET 无需加密，如 jszyapi.com）
    /// 两步策略：①列表API获取ID → ②批量detail API获取封面+播放链接
    private func fetchCMSOpen(cfg: WelfareCrawlerConfig, kind: WelfarePageKind, pg: Int,
                               onBatch: (([VodItem]) -> Void)?) async -> [VodItem] {
        // 搜索需要关键词，无法纯无参数获取，回退到 SpiderManager
        if kind == .search {
            return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch)
        }

        // 步骤1: 获取列表（只有ID和名称，没有封面和播放链接）
        let path = cmsOpenPath(for: kind, pg: pg)
        let listURLStr = "\(cfg.baseURL)\(path)"
        guard let listURL = URL(string: listURLStr) else {
            return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch)
        }
        var listReq = URLRequest(url: listURL); listReq.timeoutInterval = timeout
        listReq.httpMethod = "GET"
        listReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        listReq.setValue(cfg.baseURL, forHTTPHeaderField: "Referer")

        guard let listData = await request(listReq) else {
            return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch)
        }
        let listItems = parseVodJSON(listData)
        guard !listItems.isEmpty else {
            return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch)
        }
        // 只取前20个防止请求过长
        let ids = listItems.prefix(20).map { $0.vodId }.joined(separator: ",")

        // 步骤2: 批量获取详情（含封面+播放链接）
        let detailURLStr = "\(cfg.baseURL)/api.php/provide/vod/?ac=detail&ids=\(ids)"
        guard let detailURL = URL(string: detailURLStr) else {
            onBatch?(listItems); return listItems
        }
        var detailReq = URLRequest(url: detailURL); detailReq.timeoutInterval = timeout
        detailReq.httpMethod = "GET"
        detailReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        detailReq.setValue(cfg.baseURL, forHTTPHeaderField: "Referer")

        guard let detailData = await request(detailReq) else {
            onBatch?(listItems); return listItems
        }
        let detailItems = parseVodJSON(detailData)
        let enriched = detailItems.isEmpty ? listItems : detailItems.map { detailItem -> VodItem in
            // 解析播放链接：格式 "第01集$URL#第02集$URL#..."
            let playURL = extractFirstPlayURL(from: detailItem.vodPlayUrl ?? "")
            var item = detailItem
            if !playURL.isEmpty { item.vodPlayUrl = playURL }
            // 确保 remarks 带前缀
            if let r = item.vodRemarks, !r.isEmpty, !r.hasPrefix("[福利]") {
                item.vodRemarks = "[福利]" + r
            }
            return item
        }

        print("[WelfareCrawler] CMS开放API: 列表\(listItems.count)条 → 详情\(enriched.count)条")
        onBatch?(enriched); return enriched
    }

    /// 从 vod_play_url 格式 "第01集$https://...#第02集$https://..." 提取第一个播放链接
    private func extractFirstPlayURL(from playUrlStr: String) -> String {
        // 格式: 剧集名$URL#剧集名$URL#...
        let parts = playUrlStr.components(separatedBy: "#")
        for part in parts {
            let pair = part.components(separatedBy: "$")
            if pair.count >= 2, let url = pair.last, url.hasPrefix("http") {
                return url
            }
        }
        // 尝试直接提取 m3u8/mp4 URL
        if let match = firstMatch(in: playUrlStr, pattern: #"https?://[^\s"'<>#\$]+"#) {
            return match
        }
        return ""
    }

    // MARK: - PWA 加密 API
    private func fetchPWA(cfg: WelfareCrawlerConfig, kind: WelfarePageKind, pg: Int,
                          onBatch: (([VodItem]) -> Void)?) async -> [VodItem] {
        let apiPath = pwaApiPath(for: kind)
        let urlStr = "\(cfg.baseURL)/pwa.php\(apiPath)"
        guard let url = URL(string: urlStr) else { return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch) }

        var req = URLRequest(url: url); req.timeoutInterval = timeout
        req.httpMethod = "POST"
        let ts = Int(Date().timeIntervalSince1970)
        let body = "client=pwa&timestamp=\(ts)&data=\(randomHex(64))"
        req.httpBody = body.data(using: .utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(cfg.baseURL, forHTTPHeaderField: "Referer")

        guard let data = await request(req) else { return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch) }
        let items = parseVodJSON(data)
        if items.isEmpty { return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch) }
        onBatch?(items); return items
    }

    // MARK: - 加密 POST JSON API
    private func fetchEncPost(cfg: WelfareCrawlerConfig, kind: WelfarePageKind, pg: Int,
                              onBatch: (([VodItem]) -> Void)?) async -> [VodItem] {
        let apiPath = encPostPath(for: kind)
        let urlStr = "\(cfg.baseURL)\(apiPath)"
        guard let url = URL(string: urlStr) else { return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch) }

        var req = URLRequest(url: url); req.timeoutInterval = timeout
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(cfg.baseURL, forHTTPHeaderField: "Referer")

        let body: [String: Any] = ["post-data": randomBase64(48)]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let data = await request(req) else { return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch) }
        let items = parseVodJSON(data)
        if items.isEmpty { return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch) }
        onBatch?(items); return items
    }

    // MARK: - HTML 正则抓取（按模板类型分发）
    private func fetchHTML(cfg: WelfareCrawlerConfig, kind: WelfarePageKind, pg: Int,
                           onBatch: (([VodItem]) -> Void)?) async -> [VodItem] {
        let template = cfg.htmlTemplate ?? .generic

        // stui 模板：解析首页视频列表 + 详情页提取 m3u8
        if template == .stui {
            switch kind {
            case .home, .video:
                return await fetchStuiHomepage(cfg: cfg, onBatch: onBatch)
            case .search:
                return await fetchStuiSearch(cfg: cfg, onBatch: onBatch)
            default:
                break
            }
        }

        // 我为人人影院模板
        if template == .wurenren {
            return await fetchWurenren(cfg: cfg, kind: kind, onBatch: onBatch)
        }

        // manwats 漫画模板
        if template == .manwats {
            return await fetchManwats(cfg: cfg, kind: kind, pg: pg, onBatch: onBatch)
        }

        // 通用：正则提取 m3u8/mp4
        let path = htmlPath(for: kind, pg: pg)
        let urlStr = "\(cfg.baseURL)\(path)"
        guard let url = URL(string: urlStr) else {
            return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch)
        }
        var req = URLRequest(url: url); req.timeoutInterval = timeout
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(cfg.baseURL, forHTTPHeaderField: "Referer")
        guard let data = await request(req), let html = String(data: data, encoding: .utf8) else {
            return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch)
        }
        let items = parseHTMLItems(html, platformId: cfg.platformId)
        if items.isEmpty { return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch) }
        onBatch?(items); return items
    }

    // MARK: - Stui CMS 模板（hsck123.com / 黄色仓库）
    private func fetchStuiHomepage(cfg: WelfareCrawlerConfig,
                                    onBatch: (([VodItem]) -> Void)?) async -> [VodItem] {
        guard let url = URL(string: cfg.baseURL) else {
            return await fallback(id: cfg.platformId, kind: .home, onBatch: onBatch)
        }
        var req = URLRequest(url: url); req.timeoutInterval = timeout
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let data = await request(req), let html = String(data: data, encoding: .utf8) else {
            return await fallback(id: cfg.platformId, kind: .home, onBatch: onBatch)
        }

        // 解析 stui-vodlist__box 视频卡片
        let items = parseStuiVodlist(html, platformId: cfg.platformId)

        // 批量获取详情页的 m3u8 播放链接
        var enriched: [VodItem] = []
        for item in items.prefix(30) {
            var v = item
            if let detailURL = item.vodPlayUrl, !detailURL.isEmpty {
                if let streamURL = await fetchStuiDetailStream(detailURL: detailURL) {
                    v.vodPlayUrl = streamURL
                }
            }
            enriched.append(v)
        }

        print("[WelfareCrawler] Stui首页: \(items.count)卡片, \(enriched.filter{$0.vodPlayUrl != nil && !$0.vodPlayUrl!.isEmpty}.count)含播放链接")
        if enriched.isEmpty { return await fallback(id: cfg.platformId, kind: .home, onBatch: onBatch) }
        onBatch?(enriched); return enriched
    }

    /// 解析 stui-vodlist__box 结构
    private func parseStuiVodlist(_ html: String, platformId: String) -> [VodItem] {
        var items: [VodItem] = []
        // 匹配每个 stui-vodlist__box 块
        let boxPattern = #"<div class="stui-vodlist__box"[^>]*>(.*?)</div>\s*</div>\s*</li>"#
        guard let boxRegex = try? NSRegularExpression(pattern: boxPattern, options: [.dotMatchesLineSeparators]) else {
            return items
        }
        let range = NSRange(html.startIndex..., in: html)
        let boxes = boxRegex.matches(in: html, range: range)

        for box in boxes.prefix(50) {
            guard let boxRange = Range(box.range(at: 1), in: html) else { continue }
            let boxHTML = String(html[boxRange])

            // 提取 title
            let titlePattern = #"title="([^"]+)""#
            let hrefPattern = #"href="([^"]+)""#
            let picPattern = #"data-original="([^"]+)""#

            let title = firstMatch(in: boxHTML, pattern: titlePattern) ?? ""
            let href = firstMatch(in: boxHTML, pattern: hrefPattern) ?? ""
            let pic = firstMatch(in: boxHTML, pattern: picPattern) ?? ""

            guard !title.isEmpty else { continue }

            // 构造详情页完整URL
            let detailURL: String
            if href.hasPrefix("http") {
                detailURL = href
            } else if href.hasPrefix("/") {
                // 提取域名根
                let baseHost = URL(string: "https://hsck123.com")?.host ?? "hsck123.com"
                detailURL = "https://\(baseHost)\(href)"
            } else {
                detailURL = "https://hsck123.com/\(href)"
            }

            items.append(VodItem(
                vodId: UUID().uuidString,
                vodName: title,
                vodPic: pic,
                vodRemarks: "[福利]",
                vodPlayUrl: detailURL
            ))
        }
        print("[WelfareCrawler] parseStuiVodlist: 从\(boxes.count)个box中解析出\(items.count)条")
        return items
    }

    /// 从详情页提取 m3u8 播放链接
    private func fetchStuiDetailStream(detailURL: String) async -> String? {
        guard let url = URL(string: detailURL) else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 10
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://hsck123.com/", forHTTPHeaderField: "Referer")

        guard let data = await request(req), let html = String(data: data, encoding: .utf8) else {
            return nil
        }
        // 提取 m3u8 链接
        let streamPatterns = [
            #"https?://[^\s"'<>]+\.m3u8[^\s"'<>]*"#,
            #"https?://[^\s"'<>]+\.mp4[^\s"'<>]*"#,
        ]
        for pat in streamPatterns {
            if let match = firstMatch(in: html, pattern: pat) {
                print("[WelfareCrawler] 详情页找到流: \(match.prefix(80))")
                return match
            }
        }
        return nil
    }

    /// Stui 站内搜索
    private func fetchStuiSearch(cfg: WelfareCrawlerConfig,
                                  onBatch: (([VodItem]) -> Void)?) async -> [VodItem] {
        // stui 站内搜索需要 JS 执行，直接走 SpiderManager 回退
        return await fallback(id: cfg.platformId, kind: .search, onBatch: onBatch)
    }

    // MARK: - 我为人人影院模板 (1080.hlkjsm.com)
    private func fetchWurenren(cfg: WelfareCrawlerConfig, kind: WelfarePageKind,
                                onBatch: (([VodItem]) -> Void)?) async -> [VodItem] {
        // 该站通过 JavaScript 动态加载内容，纯 HTTP 无法获取
        // 走 SpiderManager 关键词搜索
        return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch)
    }

    // MARK: - Manwats 漫画模板 (manwats.cc)
    private func fetchManwats(cfg: WelfareCrawlerConfig, kind: WelfarePageKind, pg: Int,
                               onBatch: (([VodItem]) -> Void)?) async -> [VodItem] {
        let urlStr: String
        switch kind {
        case .home, .comic:
            urlStr = "\(cfg.baseURL)/"
        case .novel:
            urlStr = "\(cfg.baseURL)/novel/"
        case .search:
            urlStr = "\(cfg.baseURL)/search/"
        default:
            urlStr = "\(cfg.baseURL)/"
        }
        guard let url = URL(string: urlStr) else {
            return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch)
        }
        var req = URLRequest(url: url); req.timeoutInterval = timeout
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let data = await request(req), let html = String(data: data, encoding: .utf8) else {
            return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch)
        }
        // 尝试解析漫画列表 items
        let items = parseManwatsItems(html, platformId: cfg.platformId)
        if items.isEmpty { return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch) }
        onBatch?(items); return items
    }

    private func parseManwatsItems(_ html: String, platformId: String) -> [VodItem] {
        var items: [VodItem] = []
        var seen: Set<String> = []
        // manwats.cc 模式: <a href="/book/ID" target="_blank" title="NAME">
        let cardPattern = #"<a[^>]*href="(/book/\d+)"[^>]*title="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: cardPattern, options: []) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range).prefix(50) {
            guard match.numberOfRanges >= 3,
                  let hR = Range(match.range(at: 1), in: html),
                  let tR = Range(match.range(at: 2), in: html) else { continue }
            let href = "https://manwats.cc\(String(html[hR]))"
            let title = String(html[tR])
            guard !title.isEmpty, !seen.contains(title) else { continue }
            seen.insert(title)
            items.append(VodItem(vodId: UUID().uuidString, vodName: title,
                                 vodPic: "", vodRemarks: "[福利]", vodPlayUrl: href))
        }
        
        // 回退：通用 title+链接 列表
        if items.isEmpty {
            let altPattern = #"<a[^>]*href="([^"]+)"[^>]*title="([^"]+)"[^>]*>"#
            guard let r2 = try? NSRegularExpression(pattern: altPattern, options: []) else { return [] }
            for match in r2.matches(in: html, range: range).prefix(50) {
                guard match.numberOfRanges >= 3,
                      let hR = Range(match.range(at: 1), in: html),
                      let tR = Range(match.range(at: 2), in: html) else { continue }
                items.append(VodItem(vodId: UUID().uuidString, vodName: String(html[tR]),
                                     vodPic: "", vodRemarks: "[福利]", vodPlayUrl: String(html[hR])))
            }
        }
        print("[WelfareCrawler] Manwats解析: \(items.count)条")
        return items
    }

    // MARK: - SpiderManager 回退
    private func fallback(id: String, kind: WelfarePageKind,
                          onBatch: (([VodItem]) -> Void)?) async -> [VodItem] {
        let kw = kind == .search ? "" : "\(id) \(kind.displayName)"
        var all: [VodItem] = []
        print("[WelfareCrawler] SpiderManager搜索: \"\(kw)\"")
        await SpiderManager.shared.searchStream(keyword: kw, onBatch: { batch in
            let tagged = batch.map { item -> VodItem in
                var t = item
                if !(t.vodRemarks ?? "").hasPrefix("[福利]") { t.vodRemarks = "[福利]" + (t.vodRemarks ?? "") }
                return t
            }
            all.append(contentsOf: tagged); onBatch?(tagged)
        })
        return all
    }

    // MARK: - 网络请求
    private func request(_ req: URLRequest) async -> Data? {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            return data
        } catch {
            print("[WelfareCrawler] 请求失败: \(error.localizedDescription)")
            return nil
        }
    }

    private let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"

    // MARK: - JSON 解析
    private func parseVodJSON(_ data: Data) -> [VodItem] {
        if let resp = try? JSONDecoder().decode(CMSVodResponse.self, from: data), let list = resp.list {
            return list.map { $0.toVodItem() }
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let list = (json["data"] as? [String: Any])?["list"] as? [[String: Any]] ?? json["list"] as? [[String: Any]] ?? []
        return list.compactMap { dict in
            let id = (dict["vod_id"] ?? dict["id"] ?? dict["detail_id"] ?? UUID().uuidString) as! String
            let name = (dict["vod_name"] ?? dict["name"] ?? dict["title"] ?? "") as! String
            let pic = (dict["vod_pic"] ?? dict["pic"] ?? dict["image"] ?? "") as! String
            var r = (dict["vod_remarks"] ?? dict["remarks"] ?? dict["type_name"] ?? "") as! String
            if !r.hasPrefix("[福利]") { r = "[福利]" + r }
            return VodItem(vodId: id, vodName: name, vodPic: pic, vodRemarks: r,
                           vodYear: dict["vod_year"] as? String, vodArea: dict["vod_area"] as? String,
                           vodDirector: dict["vod_director"] as? String,
                           vodActor: dict["vod_actor"] as? String ?? dict["actor"] as? String,
                           vodContent: dict["vod_content"] as? String ?? dict["content"] as? String,
                           vodPlayFrom: dict["vod_play_from"] as? String,
                           vodPlayUrl: dict["vod_play_url"] as? String)
        }
    }

    // MARK: - HTML 解析（通用正则提取）
    private func parseHTMLItems(_ html: String, platformId: String) -> [VodItem] {
        var items: [VodItem] = []
        let patterns = [
            #"https?://[^\s"'<>]+\.m3u8[^\s"'<>]*"#,
            #"https?://[^\s"'<>]+\.mp4[^\s"'<>]*"#,
        ]
        for pat in patterns {
            guard let regex = try? NSRegularExpression(pattern: pat, options: .caseInsensitive) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            for match in regex.matches(in: html, range: range).prefix(30) {
                if let r = Range(match.range, in: html) {
                    let url = String(html[r]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    let name = URL(string: url)?.lastPathComponent ?? url
                    items.append(VodItem(vodId: UUID().uuidString, vodName: name,
                                         vodPic: "", vodRemarks: "[福利]", vodPlayUrl: url))
                }
            }
        }
        // 也尝试提取带title的链接
        let linkPattern = #"<a[^>]*title="([^"]+)"[^>]*href="([^"]+)"[^>]*>"#
        if let linkRegex = try? NSRegularExpression(pattern: linkPattern, options: []) {
            let range = NSRange(html.startIndex..., in: html)
            for match in linkRegex.matches(in: html, range: range).prefix(30) {
                if let tR = Range(match.range(at: 1), in: html),
                   let hR = Range(match.range(at: 2), in: html) {
                    let title = String(html[tR]), href = String(html[hR])
                    items.append(VodItem(vodId: UUID().uuidString, vodName: title,
                                         vodPic: "", vodRemarks: "[福利]", vodPlayUrl: href))
                }
            }
        }
        print("[WelfareCrawler] 通用HTML解析: \(items.count)条"); return items
    }

    // MARK: - 正则辅助
    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        if match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) {
            return String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        if let r = Range(match.range, in: text) {
            return String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    // MARK: - API 路径映射
    private func cmsApiPath(for kind: WelfarePageKind) -> String {
        switch kind {
        case .home:      return "/api/home/getconfig"
        case .video:     return "/api/mv/list_construct"
        case .film:      return "/api/mv/list_construct"
        case .anime:     return "/api/mv/list_construct"
        case .classify:  return "/api/navigation/index"
        case .rank:      return "/api/navigation/theme"
        case .search:    return "/api/mv/list_construct"
        case .comic:     return "/api/contents/list_contents"
        case .novel:     return "/api/contents/list_contents"
        case .topic:     return "/api/tabnew/list_discovery"
        case .tiktok:    return "/api/mv/list_construct"
        case .tag:       return "/api/navigation/theme"
        case .channel:   return "/api/navigation/index"
        case .community: return "/api/navigation/index"
        case .find:      return "/api/recommend/index"
        case .user:      return "/api/navigation/index"
        default: return "/api/mv/list_construct"
        }
    }

    /// 开放CMS GET API 路径映射（如 jszyapi.com 的 AppleCMS 标准接口）
    private func cmsOpenPath(for kind: WelfarePageKind, pg: Int) -> String {
        let base = "/api.php/provide/vod/?ac=list"
        switch kind {
        case .home:
            return "\(base)&pg=\(pg)"          // 最新全部
        case .video:
            return "\(base)&t=1&pg=\(pg)"      // 电视剧
        case .film:
            return "\(base)&t=2&pg=\(pg)"      // 电影
        case .anime:
            return "\(base)&t=17&pg=\(pg)"     // 动漫
        case .comic:
            return "\(base)&t=17&pg=\(pg)"     // 漫画同动漫分类
        case .novel:
            return "\(base)&t=38&pg=\(pg)"     // 短剧/小说类
        case .classify:
            return "\(base)&pg=\(pg)"          // 分类（含class字段）
        case .search:
            return "\(base)"                   // search需要动态wd参数
        default:
            return "\(base)&pg=\(pg)"
        }
    }

    private func pwaApiPath(for kind: WelfarePageKind) -> String {
        switch kind {
        case .home, .video, .film, .find: return "/api/MvList/recommend"
        case .classify, .channel, .tag, .community, .user: return "/api/tab/listv1"
        case .tiktok: return "/api/MvList/recommend"
        case .darkWeb: return "/api/tab/listv1"
        case .search: return "/api/MvList/recommend"
        default: return "/api/MvList/recommend"
        }
    }

    private func encPostPath(for kind: WelfarePageKind) -> String {
        switch kind {
        case .home, .video, .film: return "/video/channel"
        case .actor: return "/api/video/lists"
        case .search: return "/video/listcache"
        default: return "/video/listcache"
        }
    }

    private func htmlPath(for kind: WelfarePageKind, pg: Int) -> String {
        switch kind {
        case .home: return "/"
        case .video, .film: return "/?page=\(pg)"
        case .comic: return "/booklist?page=\(pg)"
        case .novel: return "/novel/?page=\(pg)"
        case .search: return "/search/?page=\(pg)"
        default: return "/"
        }
    }

    // MARK: - 工具
    private func randomHex(_ len: Int) -> String {
        (0..<len).map { _ in String(format: "%02X", UInt8.random(in:0...255)) }.joined()
    }
    private func randomBase64(_ len: Int) -> String {
        Data((0..<len).map { _ in UInt8.random(in:0...255) }).base64EncodedString()
    }

    // MARK: - 自适应页面获取
    func pages(for platformId: String) -> [WelfarePageKind] {
        WelfareCrawlerConfig.config(for: platformId)?.pages ?? [.home, .video, .search]
    }
}
