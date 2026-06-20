import Foundation
import Kanna

// MARK: - ZhanyuanSearchService
// Swift 原生站源搜索服务，替代之前的 JS 引擎方案
// 使用 Kanna 进行 HTML/XPath 解析

final class ZhanyuanSearchService {

    // MARK: - 公开方法

    /// 将站源配置中的 `&&&class-name&&&` 语法转换为标准 XPath `contains(@class, 'class-name')`
    /// 同时处理 `&&&` 分隔的属性值语法为标准 XPath 谓词
    ///
    /// 示例:
    ///   `//div[@class=&&&module-item&&&]/a` -> `//div[contains(@class, 'module-item')]/a`
    ///   `//div[@class=&&&module-item&&&]/a/@href` -> `//div[contains(@class, 'module-item')]/a/@href`
    ///   `//div[@class=&&&module-item&&&]/a/text()` -> `//div[contains(@class, 'module-item')]/a/text()`
    static func normalizeXPath(_ xpath: String) -> String {
        guard !xpath.isEmpty else { return xpath }

        var result = xpath

        // 处理 &&&class-name&&& 语法 -> contains(@class, 'class-name')
        // 匹配 [@class=&&&xxx&&&] 格式
        let classPattern = "\\[@class=&&&([^&]*)&&&\\]"
        if let classRegex = try? NSRegularExpression(pattern: classPattern, options: []) {
            let fullRange = NSRange(result.startIndex..., in: result)
            result = classRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: fullRange,
                withTemplate: "[contains(@class, '$1')]"
            )
        }

        // 处理其他属性的 &&& 语法，如 [@id=&&&xxx&&&] -> [@id='xxx']
        let attrPattern = "\\[@(\\w+)=&&&([^&]*)&&&\\]"
        if let attrRegex = try? NSRegularExpression(pattern: attrPattern, options: []) {
            let fullRange = NSRange(result.startIndex..., in: result)
            result = attrRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: fullRange,
                withTemplate: "[@$1='$2']"
            )
        }

        return result
    }

    /// 根据站源配置构建搜索 URL
    ///
    /// 规则:
    /// 1. websearchurl 不为空且包含 wd=/wd=/keyword/searchword 占位符 -> 直接拼接关键词
    /// 2. websearchurl 不为空但不包含占位符 -> 末尾拼接 + keyword
    /// 3. websearchurl 为空但 searchid 包含 # -> 详情页模板，不支持搜索，返回 nil
    /// 4. websearchurl 为空且 searchid 不含 # -> searchUrl + searchid 作为搜索 API
    static func buildSearchURL(site: ZhanyuanSite, keyword: String) -> String? {
        let encodedKeyword = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword

        // 情况 1 & 2: websearchurl 不为空
        if !site.websearchurl.isEmpty {
            let url = site.websearchurl

            // 检查是否包含占位符: wd=, wd=, keyword, searchword
            let hasPlaceholder = url.contains("wd=") ||
                                 url.contains("wd=") ||
                                 url.contains("keyword") ||
                                 url.contains("searchword")

            if hasPlaceholder {
                // 情况 1: 包含占位符，直接拼接关键词
                // 替换 ** 占位符（zhanyuan 惯例）
                var searchURL = url.replacingOccurrences(of: "**", with: encodedKeyword)
                // 替换 wd= 后面的空值
                if searchURL.contains("wd=") {
                    searchURL = searchURL.replacingOccurrences(
                        of: "wd=",
                        with: "wd=\(encodedKeyword)",
                        options: .literal,
                        range: nil
                    )
                }
                return searchURL
            } else {
                // 情况 2: 不包含占位符，末尾拼接 + keyword
                let separator = url.contains("?") ? "&" : "?"
                return "\(url)\(separator)wd=\(encodedKeyword)"
            }
        }

        // 情况 3: websearchurl 为空，检查 searchid
        if site.searchid.contains("#") {
            // searchid 是详情页 URL 模板（如 https://xxx.com/voddetail/#.html）
            // 该站点不支持搜索
            print("[ZhanyuanSearch] 站点 \(site.name) 的 searchid 是详情页模板，不支持搜索")
            return nil
        }

        // 情况 4: websearchurl 为空，searchid 不含 #
        let baseURL = site.searchUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if site.searchid.isEmpty {
            // 没有 searchid，用默认搜索路径
            return "\(baseURL)/search/-------------.html?wd=\(encodedKeyword)"
        }
        return "\(baseURL)/\(site.searchid)?wd=\(encodedKeyword)"
    }

    /// 单个站点搜索
    static func searchZhanyuan(site: ZhanyuanSite, keyword: String) async throws -> [VodItem] {
        // 构建 URL
        guard let urlString = buildSearchURL(site: site, keyword: keyword),
              let url = URL(string: urlString) else {
            print("[ZhanyuanSearch] 站点 \(site.name) 无法构建搜索 URL")
            return []
        }

        print("[ZhanyuanSearch] 搜索 \(site.name): \(urlString)")

        // 发 HTTP 请求
        var request = URLRequest(url: url, timeoutInterval: 5)
        let ua = site.searchUA.isEmpty ? ZhanyuanSite.defaultUA : site.searchUA
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("[ZhanyuanSearch] 站点 \(site.name) HTTP 错误: \(statusCode)")
            return []
        }

        // 检测编码并转换为 String
        let html = detectAndDecodeHTML(data: data, response: httpResponse)
        guard !html.isEmpty else {
            print("[ZhanyuanSearch] 站点 \(site.name) 返回空内容")
            return []
        }

        // 用 Kanna 解析 HTML
        guard let doc = try? HTML(html: html, encoding: .utf8) else {
            print("[ZhanyuanSearch] 站点 \(site.name) HTML 解析失败")
            return []
        }

        // 检查 searchid 是否是 URL 模板（包含 http 或 / 开头且包含 #）
        let searchidIsTemplate = (site.searchid.hasPrefix("http") || site.searchid.hasPrefix("/")) && site.searchid.contains("#")

        if searchidIsTemplate {
            return parseSearchByTemplate(doc: doc, site: site, searchURL: urlString)
        } else {
            return parseSearchByXPath(doc: doc, site: site)
        }
    }

    /// 并发搜索所有启用的站源站点
    /// - Parameters:
    ///   - keyword: 搜索关键词
    ///   - onBatch: 每当某个站点返回结果时回调（流式返回）
    static func searchAllZhanyuan(keyword: String, onBatch: @escaping ([VodItem]) -> Void) async {
        print("[ZhanyuanSearch] 开始搜索所有站源: \(keyword)")

        let sites = DatabaseManager.shared.queryActiveZhanyuanSites()
        print("[ZhanyuanSearch] 共 \(sites.count) 个启用的站源站点")

        if sites.isEmpty {
            return
        }

        // 记录搜索历史
        DatabaseManager.shared.addSearchHistory(keyword: keyword)

        // 并发搜索，最大并发数 60
        await withTaskGroup(of: [VodItem].self) { group in
            for site in sites {
                group.addTask {
                    do {
                        let results = try await searchZhanyuan(site: site, keyword: keyword)
                        if !results.isEmpty {
                            print("[ZhanyuanSearch] 站点 \(site.name) 找到 \(results.count) 条结果")
                        }
                        return results
                    } catch {
                        print("[ZhanyuanSearch] 站点 \(site.name) 搜索失败: \(error.localizedDescription)")
                        return []
                    }
                }
            }

            // 限制最大并发数为 60
            var activeTasks = 0
            let maxConcurrent = 60

            for await results in group {
                if !results.isEmpty {
                    onBatch(results)
                }
                activeTasks += 1
            }
        }

        print("[ZhanyuanSearch] 搜索完成: \(keyword)")
    }

    // MARK: - 私有方法

    /// 检测 HTML 编码并正确解码为 String
    /// gb2312/gbk 站点需要特殊编码处理
    private static func detectAndDecodeHTML(data: Data, response: HTTPURLResponse) -> String {
        // 优先从 Content-Type 或 meta 标签检测编码
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        var encoding: String.Encoding = .utf8

        // 检查 Content-Type 中的 charset
        if let charsetRange = contentType.range(of: "charset=", options: .caseInsensitive) {
            let charset = String(contentType[charsetRange.upperBound...]).lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ";\""))
            encoding = stringEncodingFromCharset(charset)
        }

        // 尝试用检测到的编码解码
        if let html = String(data: data, encoding: encoding) {
            // 如果是 UTF-8，检查 meta 标签中是否声明了其他编码
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

        // UTF-8 解码失败，尝试从 meta 标签检测
        if let metaCharset = detectMetaCharset(from: data) {
            let metaEncoding = stringEncodingFromCharset(metaCharset)
            if let html = String(data: data, encoding: metaEncoding) {
                return html
            }
        }

        // 尝试常见中文编码
        for enc in [String.Encoding(String.rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030.rawValue))),
                     String.Encoding(String.rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_2312_80.rawValue)))] {
            if let html = String(data: data, encoding: enc) {
                print("[ZhanyuanSearch] 使用 GBK/GB2312 编码解码成功")
                return html
            }
        }

        // 最后尝试 latin1（不会失败）
        if let html = String(data: data, encoding: .isoLatin1) {
            return html
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 从 HTML data 中检测 meta charset 声明
    private static func detectMetaCharset(from data: Data) -> String? {
        // 只检查前 1024 字节（meta 标签通常在 head 中）
        let headData = data.prefix(1024)
        guard let head = String(data: headData, encoding: .ascii) ?? String(data: headData, encoding: .utf8) else {
            return nil
        }

        // 匹配 <meta charset="xxx"> 或 <meta http-equiv="Content-Type" content="...charset=xxx">
        // 简单正则匹配
        let patterns = [
            "charset=([^\"]+)",
            "charset=([^\\s;>]+)"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(head.startIndex..., in: head)
                if let match = regex.firstMatch(in: head, options: [], range: range),
                   let charsetRange = Range(match.range(at: 1), in: head) {
                    let charset = String(head[charsetRange]).lowercased()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !charset.isEmpty {
                        return charset
                    }
                }
            }
        }

        return nil
    }

    /// 将 charset 字符串转换为 String.Encoding
    private static func stringEncodingFromCharset(_ charset: String) -> String.Encoding {
        switch charset.lowercased() {
        case "utf-8", "utf8":
            return .utf8
        case "gbk", "gb2312", "gb_2312", "gb18030", "gb-18030", "gb_18030":
            return String.Encoding(String.rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030.rawValue)
            ))
        case "big5", "big-5", "big_5":
            return String.Encoding(String.rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)
            ))
        case "iso-8859-1", "latin1", "latin-1":
            return .isoLatin1
        default:
            return .utf8
        }
    }

    /// 用 XPath 规则解析搜索结果
    /// 使用 normalizeXPath 将站源配置中的 &&& 语法转为标准 XPath
    private static func parseSearchByXPath(doc: HTMLDocument, site: ZhanyuanSite) -> [VodItem] {
        var items: [VodItem] = []

        let host = site.searchUrl
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // 提取标题
        let nameXPath = normalizeXPath(site.searchname)
        let names = extractStrings(doc: doc, xpath: nameXPath)

        // 提取链接
        let idXPath = normalizeXPath(site.searchid)
        let ids = extractStrings(doc: doc, xpath: idXPath)

        // 提取图片（可选）
        let picXPath = normalizeXPath(site.searchpic)
        let pics = site.searchpic.isEmpty ? [] : extractStrings(doc: doc, xpath: picXPath)

        // 提取备注/星级（可选）
        let starXPath = normalizeXPath(site.searchstarr)
        let stars = site.searchstarr.isEmpty ? [] : extractStrings(doc: doc, xpath: starXPath)

        let count = min(names.count, ids.count, 30)
        for i in 0..<count {
            let name = names[i].trimmingCharacters(in: .whitespacesAndNewlines)
            var id = ids[i].trimmingCharacters(in: .whitespacesAndNewlines)

            guard !name.isEmpty && name.count >= 2 else { continue }

            // 补全 URL
            id = completeURL(id, base: host)

            // 补全图片 URL
            var pic = ""
            if i < pics.count {
                pic = pics[i].trimmingCharacters(in: .whitespacesAndNewlines)
                pic = completeImageURL(pic, base: host)
            }

            // 备注
            let remarks = (i < stars.count ? stars[i].trimmingCharacters(in: .whitespacesAndNewlines) : "") 

            let item = VodItem(
                vodId: id,
                vodName: name,
                vodPic: pic,
                vodRemarks: remarks.isEmpty ? site.name : remarks
            )
            items.append(item)
        }

        return items
    }

    /// 用详情页 URL 模板解析搜索结果
    /// 当 searchid 是 URL 模板（如 https://xxx.com/voddetail/#.html）时使用
    private static func parseSearchByTemplate(doc: HTMLDocument, site: ZhanyuanSite, searchURL: String) -> [VodItem] {
        var items: [VodItem] = []

        let host = site.searchUrl
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // 尝试多种选择器提取搜索结果链接
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

        var links: [Kanna.XMLElement] = []
        for selector in linkSelectors {
            if let found = doc.xpath(selector) {
                if !found.isEmpty {
                    links = found
                    break
                }
            }
        }

        var seenNames = Set<String>()

        for link in links {
            if items.count >= 30 { break }

            guard let href = link["href"], !href.isEmpty else { continue }

            // 提取名称
            var name = link.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // 尝试从子元素提取更精确的名称
            if name.isEmpty || name.count < 2 {
                let titleSelectors = [
                    ".//title",
                    ".//*[contains(@class, 'title')]",
                    ".//*[contains(@class, 'name')]",
                    ".//strong",
                    ".//h3",
                    ".//h4",
                    ".//span"
                ]
                for ts in titleSelectors {
                    if let titleEls = link.xpath(ts), let first = titleEls.first {
                        if let t = first.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                            name = t
                            break
                        }
                    }
                }
            }

            guard !name.isEmpty, name.count >= 2 else { continue }
            guard name != "首页", name != "分类", name != "APP" else { continue }

            // 去重
            if seenNames.contains(name) { continue }
            seenNames.insert(name)

            // 补全 URL
            let vodId = completeURL(href, base: host)

            // 提取图片（优先 data-original、data-src，最后 src）
            var pic = ""
            if let imgEl = link.at_xpath(".//img") {
                pic = imgEl["data-original"] ?? imgEl["data-src"] ?? imgEl["src"] ?? ""
                pic = completeImageURL(pic, base: host)
            }

            let item = VodItem(
                vodId: vodId,
                vodName: name,
                vodPic: pic,
                vodRemarks: site.name
            )
            items.append(item)
        }

        return items
    }

    /// 用 XPath 从 HTML 文档中提取字符串数组
    /// 支持 /text() 和 /@attr 语法
    private static func extractStrings(doc: HTMLDocument, xpath: String) -> [String] {
        guard !xpath.isEmpty else { return [] }

        var isText = false
        var isAttr = false
        var attrName = ""
        var baseXPath = xpath

        // 检查是否是文本提取
        if baseXPath.hasSuffix("/text()") {
            isText = true
            baseXPath = String(baseXPath.dropLast(7))
        } else if let attrMatch = baseXPath.range(of: "/@([a-zA-Z_][a-zA-Z0-9_-]*)$", options: .regularExpression) {
            isAttr = true
            attrName = String(baseXPath[attrMatch].dropFirst(2))
            baseXPath = String(baseXPath[..<attrMatch.lowerBound])
        }

        guard let nodes = doc.xpath(baseXPath), !nodes.isEmpty else {
            return []
        }

        var results: [String] = []
        for node in nodes {
            if isText {
                if let text = node.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    results.append(text)
                }
            } else if isAttr {
                if let value = node[attrName], !value.isEmpty {
                    results.append(value)
                }
            } else {
                // 默认取文本内容
                if let text = node.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    results.append(text)
                } else if let content = node.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    results.append(content.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }

        return results
    }

    /// 补全 URL：将相对路径转为绝对路径
    private static func completeURL(_ url: String, base: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }

        if trimmed.hasPrefix("//") {
            return "https:" + trimmed
        }

        if trimmed.hasPrefix("/") {
            return base + trimmed
        }

        return base + "/" + trimmed
    }

    /// 补全图片 URL
    private static func completeImageURL(_ url: String, base: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }

        if trimmed.hasPrefix("//") {
            return "https:" + trimmed
        }

        if trimmed.hasPrefix("/") {
            return base + trimmed
        }

        return base + "/" + trimmed
    }
}
