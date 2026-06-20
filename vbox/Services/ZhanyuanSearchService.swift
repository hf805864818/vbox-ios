import Foundation
import Kanna

// MARK: - ZhanyuanSearchService
// Swift 原生站源搜索服务，替代之前的 JS 引擎方案
// 使用 Kanna 进行 HTML/XPath 解析

final class ZhanyuanSearchService {

    // MARK: - 公开方法

    /// 将站源配置中的 `&&&class-name&&&` 语法转换为标准 XPath `contains(@class, 'class-name')`
    static func normalizeXPath(_ xpath: String) -> String {
        guard !xpath.isEmpty else { return xpath }
        var result = xpath

        // 处理 [@class=&&&xxx&&&] -> [contains(@class, 'xxx')]
        let classPattern = "\\[@class=&&&([^&]*)&&&\\]"
        if let classRegex = try? NSRegularExpression(pattern: classPattern, options: []) {
            let fullRange = NSRange(result.startIndex..., in: result)
            result = classRegex.stringByReplacingMatches(
                in: result, options: [], range: fullRange,
                withTemplate: "[contains(@class, '$1')]"
            )
        }

        // 处理其他属性的 &&& 语法
        let attrPattern = "\\[@(\\w+)=&&&([^&]*)&&&\\]"
        if let attrRegex = try? NSRegularExpression(pattern: attrPattern, options: []) {
            let fullRange = NSRange(result.startIndex..., in: result)
            result = attrRegex.stringByReplacingMatches(
                in: result, options: [], range: fullRange,
                withTemplate: "[@$1='$2']"
            )
        }

        return result
    }

    /// 根据站源配置构建搜索 URL
    static func buildSearchURL(site: ZhanyuanSite, keyword: String) -> String? {
        let encodedKeyword = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword

        if !site.websearchurl.isEmpty {
            let url = site.websearchurl
            let hasPlaceholder = url.contains("wd=") || url.contains("keyword") || url.contains("searchword")

            if hasPlaceholder {
                var searchURL = url.replacingOccurrences(of: "**", with: encodedKeyword)
                if searchURL.contains("wd=") {
                    searchURL = searchURL.replacingOccurrences(of: "wd=", with: "wd=\(encodedKeyword)")
                }
                return searchURL
            } else {
                let separator = url.contains("?") ? "&" : "?"
                return "\(url)\(separator)wd=\(encodedKeyword)"
            }
        }

        if site.searchid.contains("#") {
            return nil
        }

        let baseURL = site.searchUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if site.searchid.isEmpty {
            return "\(baseURL)/search/-------------.html?wd=\(encodedKeyword)"
        }
        return "\(baseURL)/\(site.searchid)?wd=\(encodedKeyword)"
    }

    /// 单个站点搜索
    static func searchZhanyuan(site: ZhanyuanSite, keyword: String) async throws -> [VodItem] {
        guard let urlString = buildSearchURL(site: site, keyword: keyword),
              let url = URL(string: urlString) else {
            return []
        }

        var request = URLRequest(url: url, timeoutInterval: 5)
        let ua = site.searchUA.isEmpty ? ZhanyuanSite.defaultUA : site.searchUA
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return []
        }

        let html = detectAndDecodeHTML(data: data, response: httpResponse)
        guard !html.isEmpty else { return [] }

        guard let doc = try? HTML(html: html, encoding: .utf8) else {
            return []
        }

        let searchidIsTemplate = (site.searchid.hasPrefix("http") || site.searchid.hasPrefix("/")) && site.searchid.contains("#")

        if searchidIsTemplate {
            return parseSearchByTemplate(doc: doc, site: site, searchURL: urlString)
        } else {
            return parseSearchByXPath(doc: doc, site: site)
        }
    }

    /// 并发搜索所有启用的站源站点
    /// 优先从 SQLite 读取，如果为空则从 SpiderManager 内存数据回退
    static func searchAllZhanyuan(keyword: String, onBatch: @escaping ([VodItem]) -> Void) async {
        var sites = DatabaseManager.shared.queryActiveZhanyuanSites()

        // SQLite 为空时，从 SpiderManager 内存中的 zhanyuan 站点回退
        if sites.isEmpty {
            sites = loadZhanyuanSitesFromMemory()
        }

        guard !sites.isEmpty else { return }

        print("[ZhanyuanSearch] 共 \(sites.count) 个站源站点参与搜索")

        DatabaseManager.shared.addSearchHistory(keyword: keyword)

        await withTaskGroup(of: [VodItem].self) { group in
            for site in sites {
                group.addTask {
                    do {
                        return try await searchZhanyuan(site: site, keyword: keyword)
                    } catch {
                        return []
                    }
                }
            }

            for await results in group {
                if !results.isEmpty {
                    onBatch(results)
                }
            }
        }
    }

    /// 从 SpiderManager 内存数据中提取 zhanyuan 站点配置
    private static func loadZhanyuanSitesFromMemory() -> [ZhanyuanSite] {
        // SpiderManager 是 ObservableObject，@Published 属性需要在主线程访问
        let spiderSites: [SiteConfig]
        if Thread.isMainThread {
            spiderSites = SpiderManager.shared.allSites
        } else {
            spiderSites = DispatchQueue.main.sync {
                SpiderManager.shared.allSites
            }
        }

        var zhanyuanSites: [ZhanyuanSite] = []

        for s in spiderSites {
            // type=2 是 zhanyuan 站源
            guard s.type == 2 else { continue }
            guard let api = s.api, !api.isEmpty else { continue }

            // zhanyuan 站点的搜索配置在 ext 字段中（JSON 格式）
            // api 字段是站点基础 URL
            let extJSON = s.ext ?? "{}"
            let site = parseSiteConfig(name: s.name ?? "未知", baseUrl: api, extJSON: extJSON)
            zhanyuanSites.append(site)
        }

        print("[ZhanyuanSearch] SQLite 为空，从内存加载 \(zhanyuanSites.count) 个 zhanyuan 站点")
        return zhanyuanSites
    }

    /// 从站点配置解析为 ZhanyuanSite 模型
    /// - Parameters:
    ///   - name: 站点名称
    ///   - baseUrl: 站点基础 URL（api 字段）
    ///   - extJSON: 搜索配置 JSON（ext 字段）
    private static func parseSiteConfig(name: String, baseUrl: String, extJSON: String) -> ZhanyuanSite {
        if let data = extJSON.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return ZhanyuanSite(
                name: json["name"] as? String ?? name,
                searchUrl: json["searchUrl"] as? String ?? baseUrl,
                searchUA: json["searchUA"] as? String ?? "",
                playUA: json["playUA"] as? String ?? "",
                websearchurl: json["websearchurl"] as? String ?? "",
                searchname: json["searchname"] as? String ?? "",
                searchid: json["searchid"] as? String ?? "",
                searchpic: json["searchpic"] as? String ?? "",
                searchstarr: json["searchstarr"] as? String ?? "",
                detaillist: json["detaillist"] as? String ?? "",
                detailxl: json["detailxl"] as? String ?? "",
                detailjs: json["detailjs"] as? String ?? "",
                detailjsurl: json["detailjsurl"] as? String ?? "",
                isActive: true,
                updatedAt: Int64(Date().timeIntervalSince1970)
            )
        }

        // ext 不是有效 JSON，用 baseUrl 作为 searchUrl
        return ZhanyuanSite(
            name: name,
            searchUrl: baseUrl,
            searchUA: "",
            playUA: "",
            websearchurl: "",
            searchname: "",
            searchid: "",
            searchpic: "",
            searchstarr: "",
            detaillist: "",
            detailxl: "",
            detailjs: "",
            detailjsurl: "",
            isActive: true,
            updatedAt: Int64(Date().timeIntervalSince1970)
        )
    }

    // MARK: - 私有方法

    /// 检测 HTML 编码并正确解码为 String
    private static func detectAndDecodeHTML(data: Data, response: HTTPURLResponse) -> String {
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        var encoding: String.Encoding = .utf8

        if let charsetRange = contentType.range(of: "charset=", options: .caseInsensitive) {
            let charset = String(contentType[charsetRange.upperBound...]).lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "\";").union(.whitespacesAndNewlines))
            encoding = stringEncodingFromCharset(charset)
        }

        if let html = String(data: data, encoding: encoding) {
            if encoding == .utf8 {
                if let metaCharset = detectMetaCharset(from: data) {
                    let metaEncoding = stringEncodingFromCharset(metaCharset)
                    if metaEncoding != .utf8, let redecoded = String(data: data, encoding: metaEncoding) {
                        return redecoded
                    }
                }
            }
            return html
        }

        if let metaCharset = detectMetaCharset(from: data) {
            let metaEncoding = stringEncodingFromCharset(metaCharset)
            if let html = String(data: data, encoding: metaEncoding) {
                return html
            }
        }

        // 尝试 GBK/GB2312
        let encodings: [UInt] = [0x0632, 0x0631] // GB18030, GB2312
        for encValue in encodings {
            let nsEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encValue))
            let swiftEnc = String.Encoding(rawValue: nsEnc)
            if let html = String(data: data, encoding: swiftEnc) {
                return html
            }
        }

        if let html = String(data: data, encoding: .isoLatin1) {
            return html
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 从 HTML data 中检测 meta charset
    private static func detectMetaCharset(from data: Data) -> String? {
        let headData = data.prefix(1024)
        guard let head = String(data: headData, encoding: .ascii) ?? String(data: headData, encoding: .utf8) else {
            return nil
        }

        let patterns = ["charset=([^\"]+)", "charset=([^\\s;>]+)"]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(head.startIndex..., in: head)
                if let match = regex.firstMatch(in: head, options: [], range: range),
                   let charsetRange = Range(match.range(at: 1), in: head) {
                    let charset = String(head[charsetRange]).lowercased()
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    if !charset.isEmpty { return charset }
                }
            }
        }
        return nil
    }

    /// charset -> String.Encoding
    private static func stringEncodingFromCharset(_ charset: String) -> String.Encoding {
        switch charset.lowercased() {
        case "utf-8", "utf8":
            return .utf8
        case "gbk", "gb2312", "gb_2312", "gb18030", "gb-18030", "gb_18030":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632)))
        case "big5", "big-5", "big_5":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0A03)))
        case "iso-8859-1", "latin1", "latin-1":
            return .isoLatin1
        default:
            return .utf8
        }
    }

    /// 用 XPath 规则解析搜索结果
    private static func parseSearchByXPath(doc: HTMLDocument, site: ZhanyuanSite) -> [VodItem] {
        var items: [VodItem] = []
        let host = site.searchUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let names = extractStrings(doc: doc, xpath: normalizeXPath(site.searchname))
        let ids = extractStrings(doc: doc, xpath: normalizeXPath(site.searchid))
        let pics = site.searchpic.isEmpty ? [] : extractStrings(doc: doc, xpath: normalizeXPath(site.searchpic))
        let stars = site.searchstarr.isEmpty ? [] : extractStrings(doc: doc, xpath: normalizeXPath(site.searchstarr))

        let count = min(names.count, ids.count, 30)
        for i in 0..<count {
            let name = names[i].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            var id = ids[i].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !name.isEmpty && name.count >= 2 else { continue }

            id = completeURL(id, base: host)

            var pic = ""
            if i < pics.count {
                pic = pics[i].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                pic = completeImageURL(pic, base: host)
            }

            let remarks = i < stars.count ? stars[i].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) : ""

            items.append(VodItem(
                vodId: id, vodName: name, vodPic: pic,
                vodRemarks: remarks.isEmpty ? site.name : remarks
            ))
        }

        return items
    }

    /// 用详情页 URL 模板解析搜索结果
    private static func parseSearchByTemplate(doc: HTMLDocument, site: ZhanyuanSite, searchURL: String) -> [VodItem] {
        var items: [VodItem] = []
        let host = site.searchUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let linkSelectors = [
            "//a[contains(@href, 'detail')]",
            "//a[contains(@href, 'vod')]",
            "//a[contains(@href, '/id/')]",
            "//a[contains(@href, '.html')]",
            "//*[contains(@class, 'module-card-item')]//a",
            "//*[contains(@class, 'search-list-item')]//a",
            "//*[contains(@class, 'stui-vodlist__thumb')]//a",
            "//*[contains(@class, 'vodlist')]//li//a",
            "//li//a"
        ]

        var links: [XMLElement] = []
        for selector in linkSelectors {
            let results = doc.xpath(selector)
            if results.count > 0 {
                links = []
                for node in results {
                    if let el = node as? XMLElement {
                        links.append(el)
                    }
                }
                if !links.isEmpty { break }
            }
        }

        var seenNames = Set<String>()
        for link in links {
            if items.count >= 30 { break }
            guard let href = link["href"], !href.isEmpty else { continue }

            var name = link.text?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""

            if name.isEmpty || name.count < 2 {
                let titleSelectors = [".//title", ".//*[contains(@class, 'title')]", ".//*[contains(@class, 'name')]", ".//strong", ".//h3", ".//h4", ".//span"]
                for ts in titleSelectors {
                    let titleResults = link.xpath(ts)
                    if let first = titleResults.first, let el = first as? XMLElement {
                        if let t = el.text?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), !t.isEmpty {
                            name = t
                            break
                        }
                    }
                }
            }

            guard !name.isEmpty, name.count >= 2 else { continue }
            guard name != "首页", name != "分类", name != "APP" else { continue }
            if seenNames.contains(name) { continue }
            seenNames.insert(name)

            let vodId = completeURL(href, base: host)

            var pic = ""
            if let imgEl = link.at_xpath(".//img") {
                pic = imgEl["data-original"] ?? imgEl["data-src"] ?? imgEl["src"] ?? ""
                pic = completeImageURL(pic, base: host)
            }

            items.append(VodItem(vodId: vodId, vodName: name, vodPic: pic, vodRemarks: site.name))
        }

        return items
    }

    /// 用 XPath 从 HTML 文档中提取字符串数组
    private static func extractStrings(doc: HTMLDocument, xpath: String) -> [String] {
        guard !xpath.isEmpty else { return [] }

        var isText = false
        var isAttr = false
        var attrName = ""
        var baseXPath = xpath

        if baseXPath.hasSuffix("/text()") {
            isText = true
            baseXPath = String(baseXPath.dropLast(7))
        } else if let attrMatch = baseXPath.range(of: "/@([a-zA-Z_][a-zA-Z0-9_-]*)$", options: .regularExpression) {
            isAttr = true
            attrName = String(baseXPath[attrMatch].dropFirst(2))
            baseXPath = String(baseXPath[..<attrMatch.lowerBound])
        }

        let results = doc.xpath(baseXPath)
        guard results.count > 0 else { return [] }

        var strings: [String] = []
        for node in results {
            guard let el = node as? XMLElement else { continue }

            if isText {
                if let text = el.text?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), !text.isEmpty {
                    strings.append(text)
                }
            } else if isAttr {
                if let value = el[attrName], !value.isEmpty {
                    strings.append(value)
                }
            } else {
                if let text = el.text?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), !text.isEmpty {
                    strings.append(text)
                }
            }
        }

        return strings
    }

    /// 补全 URL
    private static func completeURL(_ url: String, base: String) -> String {
        let trimmed = url.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return trimmed }
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        if trimmed.hasPrefix("/") { return base + trimmed }
        return base + "/" + trimmed
    }

    /// 补全图片 URL
    private static func completeImageURL(_ url: String, base: String) -> String {
        let trimmed = url.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return trimmed }
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        if trimmed.hasPrefix("/") { return base + trimmed }
        return base + "/" + trimmed
    }
}
