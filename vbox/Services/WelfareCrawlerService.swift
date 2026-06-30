import Foundation

// MARK: - CMS 标准 API 响应模型
struct CMSVodItem: Codable {
    let vodId: String; let vodName: String?; let vodPic: String?
    let vodRemarks: String?; let vodYear: String?; let vodArea: String?
    let vodDirector: String?; let vodActor: String?; let vodContent: String?
    let vodPlayFrom: String?; let vodPlayUrl: String?; let typeName: String?
    let typeId: String?
    private enum CodingKeys: String, CodingKey {
        case vodId="vod_id", vodName="vod_name", vodPic="vod_pic"
        case vodRemarks="vod_remarks", vodYear="vod_year", vodArea="vod_area"
        case vodDirector="vod_director", vodActor="vod_actor", vodContent="vod_content"
        case vodPlayFrom="vod_play_from", vodPlayUrl="vod_play_url", typeName="type_name"
        case typeId="type_id"
    }
    func toVodItem() -> VodItem {
        let r = (vodRemarks ?? typeName ?? ""); let tagged = r.hasPrefix("[福利]") ? r : "[福利]"+r
        var v = VodItem(vodId: vodId, vodName: vodName ?? "", vodPic: vodPic ?? "",
                       vodRemarks: tagged, vodYear: vodYear, vodArea: vodArea,
                       vodDirector: vodDirector, vodActor: vodActor,
                       vodContent: vodContent, vodPlayFrom: vodPlayFrom)
        let playURL = Self.extractFirstPlayURL(from: vodPlayUrl ?? "")
        if !playURL.isEmpty { v.vodPlayUrl = playURL }
        else { v.vodPlayUrl = vodPlayUrl }
        return v
    }

    /// 从 vod_play_url 格式 "第01集$https://...#第02集$https://..." 提取第一个播放链接
    static func extractFirstPlayURL(from playUrlStr: String) -> String {
        let parts = playUrlStr.components(separatedBy: "#")
        for part in parts {
            let pair = part.components(separatedBy: "$")
            if pair.count >= 2, let url = pair.last, url.hasPrefix("http") { return url }
        }
        if let match = firstMatchStatic(in: playUrlStr, pattern: #"https?://[^\s"'<>#\$]+"#) { return match }
        return ""
    }

    private static func firstMatchStatic(in text: String, pattern: String) -> String? {
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
}

struct CMSVodResponse: Codable { let code: Int?; let list: [CMSVodItem]? }
struct CMSTypeResponse: Codable { let code: Int?; let `class`: [CMSTypeItem]? }
struct CMSTypeItem: Codable {
    let typeId: String?; let typeName: String?
    private enum CodingKeys: String, CodingKey {
        case typeId="type_id", typeName="type_name"
    }
}

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

        // PWA加密 / encPost 平台直接走代理（非开放API必然失败）
        switch cfg.parserType {
        case .pwaApi, .encPost:
            return await proxyOrFallback(cfg: cfg, kind: pageKind, onBatch: onBatch)
        case .apiJson:
            if cfg.apiMode == .open {
                return await fetchCMSOpen(cfg: cfg, kind: pageKind, pg: page, onBatch: onBatch)
            }
            return await fetchCMS(cfg: cfg, kind: pageKind, pg: page, onBatch: onBatch)
        case .htmlRegex:
            return await fetchHTML(cfg: cfg, kind: pageKind, pg: page, onBatch: onBatch)
        case .spiderFallback:
            return await fallback(id: platformId, kind: pageKind, onBatch: onBatch)
        case .disabled:
            return []
        }
    }

    // MARK: - 获取平台分类列表（CMS API）
    func fetchCategories(platformId: String) async -> [WelfareSection] {
        guard let cfg = WelfareCrawlerConfig.config(for: platformId),
              cfg.apiMode == .open else { return [] }
        let urlStr = "\(cfg.baseURL)/api.php/provide/vod/?ac=class"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url); req.timeoutInterval = timeout
        req.httpMethod = "GET"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(cfg.baseURL, forHTTPHeaderField: "Referer")
        guard let data = await request(req) else { return [] }
        if let resp = try? JSONDecoder().decode(CMSTypeResponse.self, from: data),
           let types = resp.`class` {
            return types.compactMap { item in
                guard let name = item.typeName, !name.isEmpty else { return nil }
                return WelfareSection(id: item.typeId ?? name, name: name, keyword: name)
            }
        }
        return []
    }

    // MARK: - CMS JSON API (apiJson) - 加密模式
    private func fetchCMS(cfg: WelfareCrawlerConfig, kind: WelfarePageKind, pg: Int,
                           onBatch: (([VodItem]) -> Void)?) async -> [VodItem] {
        let apiPath = cmsApiPath(for: kind)
        let urlStr = "\(cfg.baseURL)\(apiPath)"
        guard let url = URL(string: urlStr) else {
            return await proxyOrFallback(cfg: cfg, kind: kind, onBatch: onBatch)
        }

        var req = URLRequest(url: url); req.timeoutInterval = timeout
        req.httpMethod = "POST"
        let body = "timestamp=\(Int(Date().timeIntervalSince1970))&data=\(randomHex(32))"
        req.httpBody = body.data(using: .utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(cfg.baseURL, forHTTPHeaderField: "Referer")

        guard let data = await request(req) else {
            return await proxyOrFallback(cfg: cfg, kind: kind, onBatch: onBatch)
        }
        let items = parseVodJSON(data)
        if items.isEmpty {
            return await proxyOrFallback(cfg: cfg, kind: kind, onBatch: onBatch)
        }
        onBatch?(items); return items
    }

    // MARK: - 开放 CMS API（GET 无需加密）
    private func fetchCMSOpen(cfg: WelfareCrawlerConfig, kind: WelfarePageKind, pg: Int,
                                onBatch: (([VodItem]) -> Void)?) async -> [VodItem] {
        if kind == .search {
            return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch)
        }

        // 步骤1: 获取列表
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
        let enriched = detailItems.isEmpty ? listItems : detailItems

        print("[WelfareCrawler] CMS开放API(\(cfg.platformId)): 列表\(listItems.count)条 → 详情\(enriched.count)条")
        onBatch?(enriched); return enriched
    }

    // MARK: - HTML 正则抓取（按模板类型分发）
    private func fetchHTML(cfg: WelfareCrawlerConfig, kind: WelfarePageKind, pg: Int,
                            onBatch: (([VodItem]) -> Void)?) async -> [VodItem] {
        let template = cfg.htmlTemplate ?? .generic

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

        if template == .wurenren {
            return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch)
        }

        if template == .manwats {
            return await fetchManwats(cfg: cfg, kind: kind, pg: pg, onBatch: onBatch)
        }

        // 通用 HTML 提取（先尝试，失败则回退）
        let path = htmlPath(for: kind, pg: pg)
        let urlStr = "\(cfg.baseURL)\(path)"
        guard let url = URL(string: urlStr) else {
            return await proxyOrFallback(cfg: cfg, kind: kind, onBatch: onBatch)
        }
        var req = URLRequest(url: url); req.timeoutInterval = timeout
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(cfg.baseURL, forHTTPHeaderField: "Referer")
        guard let data = await request(req), let html = String(data: data, encoding: .utf8) else {
            return await proxyOrFallback(cfg: cfg, kind: kind, onBatch: onBatch)
        }
        let items = parseHTMLItems(html, platformId: cfg.platformId)
        if items.isEmpty { return await proxyOrFallback(cfg: cfg, kind: kind, onBatch: onBatch) }
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
        let items = parseStuiVodlist(html, platformId: cfg.platformId)
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

    private func parseStuiVodlist(_ html: String, platformId: String) -> [VodItem] {
        var items: [VodItem] = []
        let boxPattern = #"<div class="stui-vodlist__box"[^>]*>(.*?)</div>\s*</div>\s*</li>"#
        guard let boxRegex = try? NSRegularExpression(pattern: boxPattern, options: [.dotMatchesLineSeparators]) else { return items }
        let range = NSRange(html.startIndex..., in: html)
        let boxes = boxRegex.matches(in: html, range: range)
        for box in boxes.prefix(50) {
            guard let boxRange = Range(box.range(at: 1), in: html) else { continue }
            let boxHTML = String(html[boxRange])
            let title = firstMatch(in: boxHTML, pattern: #"title="([^"]+)""#) ?? ""
            let href = firstMatch(in: boxHTML, pattern: #"href="([^"]+)""#) ?? ""
            let pic = firstMatch(in: boxHTML, pattern: #"data-original="([^"]+)""#) ?? firstMatch(in: boxHTML, pattern: #"src="([^"]+\.(jpg|png|webp))""#) ?? ""
            guard !title.isEmpty else { continue }
            let detailURL: String
            if href.hasPrefix("http") { detailURL = href }
            else if href.hasPrefix("/") {
                let baseHost = URL(string: cfgURLOrDefault(platformId))?.host ?? ""
                detailURL = "https://\(baseHost)\(href)"
            } else {
                detailURL = "\(cfgURLOrDefault(platformId))\(href)"
            }
            items.append(VodItem(vodId: UUID().uuidString, vodName: title,
                                  vodPic: pic, vodRemarks: "[福利]", vodPlayUrl: detailURL))
        }
        print("[WelfareCrawler] parseStuiVodlist: 从\(boxes.count)个box中解析出\(items.count)条")
        return items
    }

    private func cfgURLOrDefault(_ platformId: String) -> String {
        WelfareCrawlerConfig.config(for: platformId)?.baseURL ?? "https://hsck123.com"
    }

    private func fetchStuiDetailStream(detailURL: String) async -> String? {
        guard let url = URL(string: detailURL) else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 10
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://hsck123.com/", forHTTPHeaderField: "Referer")
        guard let data = await request(req), let html = String(data: data, encoding: .utf8) else { return nil }
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

    private func fetchStuiSearch(cfg: WelfareCrawlerConfig,
                                   onBatch: (([VodItem]) -> Void)?) async -> [VodItem] {
        return await fallback(id: cfg.platformId, kind: .search, onBatch: onBatch)
    }

    // MARK: - Manwats 漫画模板 (manwats.cc)
    private func fetchManwats(cfg: WelfareCrawlerConfig, kind: WelfarePageKind, pg: Int,
                                onBatch: (([VodItem]) -> Void)?) async -> [VodItem] {
        let urlStr: String
        switch kind {
        case .home, .comic: urlStr = "\(cfg.baseURL)/"
        case .novel: urlStr = "\(cfg.baseURL)/novel/"
        case .search: urlStr = "\(cfg.baseURL)/search/"
        default: urlStr = "\(cfg.baseURL)/"
        }
        guard let url = URL(string: urlStr) else {
            return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch)
        }
        var req = URLRequest(url: url); req.timeoutInterval = timeout
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let data = await request(req), let html = String(data: data, encoding: .utf8) else {
            return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch)
        }
        let items = parseManwatsItems(html, platformId: cfg.platformId)
        if items.isEmpty { return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch) }
        onBatch?(items); return items
    }

    private func parseManwatsItems(_ html: String, platformId: String) -> [VodItem] {
        var items: [VodItem] = []
        var seen: Set<String> = []
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
        let kw = keywordForPlatform(id: id, kind: kind)
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

    /// 根据平台ID生成搜索关键词
    private func keywordForPlatform(id: String, kind: WelfarePageKind) -> String {
        let cfg = WelfareCrawlerConfig.config(for: id)
        let prefix = cfg?.searchPrefix ?? id
        if kind == .comic { return "\(prefix) 漫画" }
        if kind == .actor { return "\(prefix) 女优" }
        if kind == .channel { return "\(prefix) 直播" }
        return prefix
    }

    /// 三级回退：直接API失败 → YBoxAPI代理 → SpiderManager搜索
    private func proxyOrFallback(cfg: WelfareCrawlerConfig, kind: WelfarePageKind,
                                   onBatch: (([VodItem]) -> Void)?) async -> [VodItem] {
        print("[WelfareCrawler] 尝试 YBoxAPI 代理: \(cfg.platformId) kind=\(kind.rawValue)")
        let proxyItems = await YBoxAPIService.shared.fetchPlatformItems(
            platformId: cfg.platformId, kind: kind
        )
        if !proxyItems.isEmpty {
            let tagged = proxyItems.map { item -> VodItem in
                var t = item
                if !(t.vodRemarks ?? "").hasPrefix("[福利]") { t.vodRemarks = "[福利]" + (t.vodRemarks ?? "") }
                return t
            }
            print("[WelfareCrawler] YBoxAPI 代理成功: \(cfg.platformId) → \(tagged.count)条")
            onBatch?(tagged); return tagged
        }
        print("[WelfareCrawler] YBoxAPI 代理无结果，回退 SpiderManager: \(cfg.platformId)")
        return await fallback(id: cfg.platformId, kind: kind, onBatch: onBatch)
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
            let pic = (dict["vod_pic"] ?? dict["pic"] ?? dict["image"] ?? dict["img"] ?? "") as! String
            var r = (dict["vod_remarks"] ?? dict["remarks"] ?? dict["type_name"] ?? "") as! String
            if !r.hasPrefix("[福利]") { r = "[福利]" + r }
            var v = VodItem(vodId: id, vodName: name, vodPic: pic, vodRemarks: r,
                           vodYear: dict["vod_year"] as? String, vodArea: dict["vod_area"] as? String,
                           vodDirector: dict["vod_director"] as? String,
                           vodActor: dict["vod_actor"] as? String ?? dict["actor"] as? String,
                           vodContent: dict["vod_content"] as? String ?? dict["content"] as? String,
                           vodPlayFrom: dict["vod_play_from"] as? String)
            let playURL = extractFirstPlayURL(from: dict["vod_play_url"] as? String ?? "")
            if !playURL.isEmpty { v.vodPlayUrl = playURL }
            else { v.vodPlayUrl = dict["vod_play_url"] as? String }
            return v
        }
    }

    /// 从 vod_play_url 格式 "第01集$https://...#第02集$https://..." 提取第一个播放链接
    private func extractFirstPlayURL(from playUrlStr: String) -> String {
        let parts = playUrlStr.components(separatedBy: "#")
        for part in parts {
            let pair = part.components(separatedBy: "$")
            if pair.count >= 2, let url = pair.last, url.hasPrefix("http") { return url }
        }
        if let match = firstMatch(in: playUrlStr, pattern: #"https?://[^\s"'<>#\$]+"#) { return match }
        return ""
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
        // 提取带title的链接
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
        // 提取图片
        let imgPattern = #"<img[^>]*src="([^"]+)"[^>]*alt="([^"]*)"[^>]*>"#
        if let imgRegex = try? NSRegularExpression(pattern: imgPattern, options: [.caseInsensitive]) {
            let range = NSRange(html.startIndex..., in: html)
            for match in imgRegex.matches(in: html, range: range).prefix(30) {
                if match.numberOfRanges >= 3,
                   let sR = Range(match.range(at: 1), in: html),
                   let aR = Range(match.range(at: 2), in: html) {
                    let src = String(html[sR]), alt = String(html[aR])
                    if !alt.isEmpty && !items.contains(where: { $0.vodName == alt }) {
                        items.append(VodItem(vodId: UUID().uuidString, vodName: alt,
                                              vodPic: src, vodRemarks: "[福利]"))
                    }
                }
            }
        }
        print("[WelfareCrawler] 通用HTML解析: \(items.count)条")
        return items
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

    /// 开放CMS GET API 路径映射
    private func cmsOpenPath(for kind: WelfarePageKind, pg: Int) -> String {
        let base = "/api.php/provide/vod/?ac=list"
        switch kind {
        case .home:      return "\(base)&pg=\(pg)"
        case .video:     return "\(base)&t=1&pg=\(pg)"
        case .film:      return "\(base)&t=2&pg=\(pg)"
        case .anime:     return "\(base)&t=17&pg=\(pg)"
        case .comic:     return "\(base)&t=17&pg=\(pg)"
        case .novel:     return "\(base)&t=38&pg=\(pg)"
        case .classify:  return "\(base)&pg=\(pg)"
        case .search:    return "\(base)"
        default:         return "\(base)&pg=\(pg)"
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
    nonisolated func pages(for platformId: String) -> [WelfarePageKind] {
        WelfareCrawlerConfig.config(for: platformId)?.pages ?? [.home, .video, .search]
    }
}
