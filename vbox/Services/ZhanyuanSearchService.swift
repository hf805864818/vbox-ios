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

        // 1. 优先使用 websearchurl
        if !site.websearchurl.isEmpty {
            let url = site.websearchurl
            let hasPlaceholder = url.contains("wd=") || url.contains("keyword") || url.contains("searchword")

            if hasPlaceholder {
                var searchURL = url
                searchURL = searchURL.replacingOccurrences(of: "**", with: encodedKeyword)
                if let range = searchURL.range(of: "wd=") {
                    let afterWd = String(searchURL[range.upperBound...])
                    if afterWd.isEmpty || afterWd == "**" || afterWd.hasPrefix("&") {
                        searchURL.replaceSubrange(range.upperBound..., with: encodedKeyword)
                    }
                }
                return searchURL
            } else {
                // websearchurl 不带 wd=/keyword/searchword 参数，也需替换 ** 占位符
                var searchURL = url.replacingOccurrences(of: "**", with: encodedKeyword)
                let separator = searchURL.contains("?") ? "&" : "?"
                return "\(searchURL)\(separator)wd=\(encodedKeyword)"
            }
        }

        // 2. websearchurl 为空，使用标准 Apple CMS 搜索 URL
        //    注意：searchid 字段在此场景下是详情页 URL 模板（如 https://xxx.com/vod/detail/id/#.html）
        //    不是搜索 URL，不能直接用于搜索。必须使用标准 Apple CMS 搜索模式。
        let baseURL = site.searchUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(baseURL)/vodsearch/-------------.html?wd=\(encodedKeyword)"
    }

    /// 单个站点搜索
    static func searchZhanyuan(site: ZhanyuanSite, keyword: String) async throws -> [VodItem] {
        guard let urlString = buildSearchURL(site: site, keyword: keyword),
              let url = URL(string: urlString) else {
            print("[ZhanyuanSearch] ❌ URL构建失败: \(site.name) | websearchurl=\(site.websearchurl.prefix(50)) | searchUrl=\(site.searchUrl.prefix(30))")
            return []
        }

        print("[ZhanyuanSearch] 🔍 \(site.name): \(urlString.prefix(100))")

        var request = URLRequest(url: url, timeoutInterval: 10)
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
    static func searchAllZhanyuan(keyword: String, onBatch: @escaping ([VodItem]) -> Void, onLog: ((String) -> Void)? = nil) async {
        let log = onLog ?? { print("[ZhanyuanSearch] \($0)") }
        var sites = DatabaseManager.shared.queryActiveZhanyuanSites()
        log("zhanyuan SQLite查询: \(sites.count) 个站点")

        // SQLite 为空时，从 SpiderManager 内存中的 zhanyuan 站点回退
        if sites.isEmpty {
            sites = await loadZhanyuanSitesFromMemory()
            log("zhanyuan 内存回退: \(sites.count) 个站点")
        }

        guard !sites.isEmpty else {
            log("⚠️ zhanyuan 无可用站点，跳过")
            return
        }

        // 打印前3个站点的关键信息用于调试
        for (i, site) in sites.prefix(3).enumerated() {
            log("zhanyuan[\(i)]: \(site.name) | websearchurl=\(site.websearchurl.prefix(60)) | searchUrl=\(site.searchUrl.prefix(40))")
        }
        log("zhanyuan 共 \(sites.count) 个站源站点参与搜索")

        DatabaseManager.shared.addSearchHistory(keyword: keyword)

        var successCount = 0
        var failCount = 0
        let maxConcurrency = 30  // 限制并发数，避免网络拥塞

        // 分批处理，每批最多 maxConcurrency 个并发任务
        let batches = stride(from: 0, to: sites.count, by: maxConcurrency).map {
            Array(sites[$0..<min($0 + maxConcurrency, sites.count)])
        }

        for batch in batches {
            await withTaskGroup(of: (name: String, items: [VodItem], error: String?).self) { group in
                for site in batch {
                    group.addTask {
                        do {
                            let results = try await searchZhanyuan(site: site, keyword: keyword)
                            return (name: site.name, items: results, error: nil)
                        } catch {
                            return (name: site.name, items: [], error: error.localizedDescription)
                        }
                    }
                }

                for await result in group {
                    if !result.items.isEmpty {
                        log("✅ zhanyuan[\(result.name)] +\(result.items.count)条")
                        successCount += 1
                        onBatch(result.items)
                    } else if let err = result.error {
                        log("❌ zhanyuan[\(result.name)] 错误: \(err)")
                        failCount += 1
                    } else {
                        log("⚠️ zhanyuan[\(result.name)] 无结果")
                        failCount += 1
                    }
                }
            }
        }
        log("zhanyuan 搜索完成: 成功\(successCount)/失败\(failCount)/总计\(sites.count)")
    }

    /// 从 SpiderManager 内存数据中提取 zhanyuan 站点配置
    private static func loadZhanyuanSitesFromMemory() async -> [ZhanyuanSite] {
        // SpiderManager 是 ObservableObject，@Published 属性绑定主线程
        let spiderSites = await MainActor.run { SpiderManager.shared.allSites }

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

        let count = min(names.count, ids.count, 50)
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

            // vodRemarks 始终用站点名称，确保搜索结果按站点正确分组
            // 备注信息（如"已完结"）拼接到 vodName 后面
            let displayName = remarks.isEmpty ? name : "\(name) \(remarks)"
            items.append(VodItem(
                vodId: id, vodName: displayName, vodPic: pic,
                vodRemarks: site.name
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

    // MARK: - 详情页解析

    /// 解析 zhanyuan 站点的详情页，提取播放列表
    /// - Parameters:
    ///   - detailUrl: 详情页 URL（vodId）
    ///   - site: zhanyuan 站点配置
    /// - Returns: 包含播放列表的 VodItem
    static func fetchDetail(detailUrl: String, site: ZhanyuanSite) async throws -> VodItem {
        let ua = site.playUA.isEmpty ? site.searchUA : site.playUA
        let host = site.searchUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var request = URLRequest(url: URL(string: detailUrl)!, timeoutInterval: 8)
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "ZhanyuanDetail", code: -1, userInfo: [NSLocalizedDescriptionKey: "HTTP 错误"])
        }

        let html = detectAndDecodeHTML(data: data, response: httpResponse)
        guard !html.isEmpty else {
            throw NSError(domain: "ZhanyuanDetail", code: -2, userInfo: [NSLocalizedDescriptionKey: "返回空内容"])
        }

        guard let doc = try? HTML(html: html, encoding: .utf8) else {
            throw NSError(domain: "ZhanyuanDetail", code: -3, userInfo: [NSLocalizedDescriptionKey: "HTML 解析失败"])
        }

        // 提取标题
        var vodName = ""
        if let titleEl = doc.at_xpath("//h1") {
            vodName = titleEl.text?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
        }
        if vodName.isEmpty, let titleEl = doc.at_xpath("//title") {
            vodName = titleEl.text?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
        }
        if vodName.isEmpty {
            let fallbacks = ["//div[contains(@class,'slide-info-title')]", "//div[contains(@class,'video-info-header')]//span", "//div[contains(@class,'module-heading-title')]"]
            for fb in fallbacks {
                if let el = doc.at_xpath(fb) {
                    vodName = el.text?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
                    if !vodName.isEmpty { break }
                }
            }
        }

        // 提取图片
        var vodPic = ""
        let imgSelectors = ["//div[contains(@class,'slide-info-cover')]//img", "//div[contains(@class,'video-info-cover')]//img", "//div[contains(@class,'module-item-pic')]//img", "//img[@data-pic]", "//img"]
        for isel in imgSelectors {
            if let imgEl = doc.at_xpath(isel) {
                vodPic = imgEl["data-original"] ?? imgEl["data-src"] ?? imgEl["src"] ?? ""
                if !vodPic.isEmpty {
                    vodPic = completeImageURL(vodPic, base: host)
                    break
                }
            }
        }

        // 提取播放列表
        let playUrl = parsePlayList(doc: doc, site: site, host: host)

        print("[ZhanyuanDetail] 解析成功: \(vodName), 播放列表 \(playUrl.isEmpty ? "空" : "\(playUrl.components(separatedBy: "#").count)集")")

        return VodItem(
            vodId: detailUrl,
            vodName: vodName,
            vodPic: vodPic,
            vodRemarks: site.name,
            vodPlayFrom: site.name,
            vodPlayUrl: playUrl
        )
    }

    /// 解析播放列表：优先用 XPath 规则，无规则时用通用选择器兜底
    private static func parsePlayList(doc: HTMLDocument, site: ZhanyuanSite, host: String) -> String {
        // 1. 有 detaillist XPath 规则时，用规则解析
        if !site.detaillist.isEmpty {
            let urls = parsePlayListByXPath(doc: doc, site: site, host: host)
            if !urls.isEmpty { return urls.joined(separator: "#") }
        }

        // 2. 无规则或规则解析失败，用通用 CSS 选择器兜底
        let urls = parsePlayListGeneric(doc: doc, host: host)
        return urls.joined(separator: "#")
    }

    /// 用站点的 XPath 规则解析播放列表
    private static func parsePlayListByXPath(doc: HTMLDocument, site: ZhanyuanSite, host: String) -> [String] {
        let listXPath = normalizeXPath(site.detaillist)
        var playUrls: [String] = []

        // 提取线路名称（可选）
        var tabNames: [String] = []
        if !site.detailxl.isEmpty {
            tabNames = extractStrings(doc: doc, xpath: normalizeXPath(site.detailxl))
        }

        // 先找到 detaillist 容器
        let containers = doc.xpath(listXPath)
        guard !containers.isEmpty else {
            print("[ZhanyuanDetail] ⚠️ detaillist XPath 未匹配到容器: \(listXPath)")
            return []
        }

        let hasDetailRules = !site.detailjs.isEmpty && !site.detailjsurl.isEmpty

        for node in containers {
            guard let container = node as? XMLElement else { continue }

            if hasDetailRules {
                // 有 detailjs/detailjsurl 规则，限定在容器内查询
                let episodeNames = extractStringsFromElement(container, xpath: normalizeXPath(site.detailjs))
                let episodeUrls = extractStringsFromElement(container, xpath: normalizeXPath(site.detailjsurl))

                if !episodeNames.isEmpty && !episodeUrls.isEmpty {
                    let count = min(episodeNames.count, episodeUrls.count, 500)
                    for i in 0..<count {
                        let epName = episodeNames[i].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        var epUrl = episodeUrls[i].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        if epName.isEmpty && epUrl.isEmpty { continue }

                        epUrl = completeURL(epUrl, base: host)
                        playUrls.append("\(epName)$\(epUrl)")
                    }
                }
            } else {
                // 没有 detailjs/detailjsurl，从容器中提取所有 <a> 标签
                let links = container.xpath(".//a")
                for linkNode in links {
                    guard let linkEl = linkNode as? XMLElement else { continue }
                    let epName = linkEl.text?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
                    var epUrl = linkEl["href"] ?? ""
                    if epName.isEmpty || epUrl.isEmpty { continue }

                    epUrl = completeURL(epUrl, base: host)
                    playUrls.append("\(epName)$\(epUrl)")
                }
            }
        }

        return playUrls
    }

    /// 从单个 XMLElement 中提取字符串数组（限定在容器内查询）
    /// 将绝对 XPath（如 //a/text()）转换为相对 XPath（.//a）后查询
    private static func extractStringsFromElement(_ element: XMLElement, xpath: String) -> [String] {
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

        // 将绝对路径 //xxx 转换为相对路径 .//xxx
        if baseXPath.hasPrefix("//") {
            baseXPath = "." + baseXPath
        } else if !baseXPath.hasPrefix(".") {
            baseXPath = ".//" + baseXPath
        }

        let results = element.xpath(baseXPath)
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

    /// 通用播放列表提取（无 XPath 规则时的兜底）
    private static func parsePlayListGeneric(doc: HTMLDocument, host: String) -> [String] {
        let selectors = [
            "//*[contains(@class,'playlist')]//a",
            "//*[contains(@class,'play-list')]//a",
            "//*[contains(@class,'stui-content__playlist')]//a",
            "//*[contains(@class,'module-play-list')]//a",
            "//*[@id='y-playList']//a",
            "//*[@id='playlist']//a",
            "//*[contains(@class,'video-list')]//a",
            "//*[contains(@class,'vodlist')]//a"
        ]

        for selector in selectors {
            let results = doc.xpath(selector)
            if results.count > 0 {
                var playUrls: [String] = []
                for node in results {
                    guard let el = node as? XMLElement else { continue }
                    let epName = el.text?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
                    var epUrl = el["href"] ?? ""
                    if epName.isEmpty || epUrl.isEmpty { continue }

                    epUrl = completeURL(epUrl, base: host)
                    playUrls.append("\(epName)$\(epUrl)")
                }
                if !playUrls.isEmpty { return playUrls }
            }
        }

        return []
    }
}
