import Foundation

// MARK: - 远程可配置 CMS V10 福利源
/// 只读取 welfare_platforms.json 中 serviceType = remote_cms_v10 的平台配置。
/// 设计目标：后续同类 CMS V10 福利源尽量只改远程源，不再为每个平台新增专用 Service。
final class RemoteCMSV10Service: FuliBaseService {
    static private let cache = NSCache<NSString, RemoteCMSV10Service>()

    static func service(for platform: WelfarePlatform) -> RemoteCMSV10Service {
        let key = platform.platformKey as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let svc = RemoteCMSV10Service(platform: platform)
        cache.setObject(svc, forKey: key)
        return svc
    }

    private let platform: WelfarePlatform
    private var childCategoryCache: [FuliCategory]?
    private let cacheLock = NSLock()

    init(platform: WelfarePlatform) {
        self.platform = platform
        super.init(platformName: platform.name, defaultHosts: platform.defaultHosts)
    }

    override var contentCategory: FuliContentCategory {
        (platform.contentType ?? platform.category).lowercased() == "comic" ? .comic : .video
    }

    override var imageReferer: String? {
        platform.imageReferer
    }

    private var isArticleHTMLMode: Bool {
        (platform.detailMode ?? "").lowercased() == "article_html"
            || (platform.apiKind ?? "").lowercased() == "mac_art_html"
    }

    func defaultHeaders(host: String) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": isArticleHTMLMode
                ? "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
                : "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/104.0.5112.97 Mobile Safari/537.36",
            "Accept": isArticleHTMLMode
                ? "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
                : "application/json,text/plain,*/*",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Referer": "\(host.hasSuffix("/") ? host : "\(host)/")"
        ]

        for (key, value) in platform.headers ?? [:] {
            let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isAllowedHeader(normalized), !value.isEmpty else { continue }
            headers[normalized] = value
        }
        return headers
    }

    private var apiBase: String {
        let path = platform.apiPath ?? "/api.php/provide/vod/"
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return currentHost + normalizedPath
    }

    override func fetchHomeContent() async -> FuliHomeResult {
        await ensureHostReady()
        if isArticleHTMLMode {
            return await fetchArticleHomeContent()
        }

        do {
            let data = try await fetchJSON("\(apiBase)?ac=list")
            let categories = await parseCategories(from: data)
            var videos: [FuliVideo] = []
            if let first = categories.first {
                videos = await fetchCategoryContent(category: first, subCategory: nil, page: 1).videos
            }
            return FuliHomeResult(categories: categories, videos: videos)
        } catch {
            print("[\(platformName)] 远程 CMS V10 首页失败: \(error)")
            return .empty
        }
    }

    override func fetchCategoryContent(category: FuliCategory, subCategory: FuliCategory?, page: Int) async -> FuliCategoryResult {
        await ensureHostReady()
        if isArticleHTMLMode {
            return await fetchArticleCategoryContent(category: category, subCategory: subCategory, page: page)
        }

        let tid = subCategory?.typeId ?? category.typeId

        do {
            let data = try await fetchJSON("\(apiBase)?ac=detail&t=\(tid)&pg=\(page)")
            let videos = parseList(from: data)
            if !videos.isEmpty || subCategory != nil || tid != platform.rootTypeId {
                return FuliCategoryResult(videos: videos, page: page, hasMore: hasMore(from: data, count: videos.count, page: page))
            }

            // 部分 CMS 父级分类本身不返回数据（如艾旦福利图片 t=33），此时聚合自动发现的子分类。
            let children = await ensureChildCategories()
            var merged: [FuliVideo] = []
            var more = false
            for child in children {
                let childData = try await fetchJSON("\(apiBase)?ac=detail&t=\(child.typeId)&pg=\(page)")
                let childVideos = parseList(from: childData)
                merged.append(contentsOf: childVideos)
                more = more || hasMore(from: childData, count: childVideos.count, page: page)
                if merged.count >= 80 { break }
            }
            return FuliCategoryResult(videos: merged, page: page, hasMore: more)
        } catch {
            print("[\(platformName)] 远程 CMS V10 分类失败: \(error)")
            return FuliCategoryResult(videos: [], page: page, hasMore: false)
        }
    }

    override func fetchDetail(vodId: String) async -> FuliDetail {
        await ensureHostReady()
        if isArticleHTMLMode {
            return await fetchArticleDetail(vodId: vodId)
        }

        do {
            let data = try await fetchJSON("\(apiBase)?ac=detail&ids=\(vodId)")
            guard let list = data["list"] as? [[String: Any]],
                  let item = list.first else {
                return emptyDetail(vodId: vodId)
            }
            return parseDetail(item) ?? emptyDetail(vodId: vodId)
        } catch {
            print("[\(platformName)] 远程 CMS V10 详情失败: \(error)")
            return emptyDetail(vodId: vodId)
        }
    }

    override func fetchSearch(keyword: String, page: Int) async -> FuliSearchResult {
        await ensureHostReady()
        if isArticleHTMLMode {
            return FuliSearchResult(videos: [], page: page, hasMore: false)
        }

        do {
            let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let data = try await fetchJSON("\(apiBase)?ac=detail&wd=\(encoded)&pg=\(page)")
            let videos = parseList(from: data)
            return FuliSearchResult(videos: videos, page: page, hasMore: hasMore(from: data, count: videos.count, page: page))
        } catch {
            print("[\(platformName)] 远程 CMS V10 搜索失败: \(error)")
            return FuliSearchResult(videos: [], page: page, hasMore: false)
        }
    }

    override func fetchPlayerURL(episode: FuliEpisode) async -> FuliPlayerResult {
        let direct = episode.url.contains(".m3u8") || episode.url.contains(".mp4") || episode.url.contains(".ts")
        return FuliPlayerResult(url: episode.url, headers: defaultHeaders(host: currentHost), parse: direct ? 0 : 1)
    }

    private func fetchArticleHomeContent() async -> FuliHomeResult {
        do {
            let rootId = platform.rootTypeId ?? "33"
            let html = try await fetchHTML(articleListURL(typeId: rootId, page: 1))
            let children = parseArticleCategories(from: html, rootId: rootId)
            setCachedChildren(children)
            let rootName = platform.rootTypeName ?? platform.name
            let category = FuliCategory(typeId: rootId, typeName: rootName, subCategories: children)
            let videos = parseArticleList(from: html)
            return FuliHomeResult(categories: [category], videos: videos)
        } catch {
            print("[\(platformName)] HTML 图文首页失败: \(error)")
            return .empty
        }
    }

    private func fetchArticleCategoryContent(category: FuliCategory, subCategory: FuliCategory?, page: Int) async -> FuliCategoryResult {
        let tid = subCategory?.typeId ?? category.typeId
        do {
            let html = try await fetchHTML(articleListURL(typeId: tid, page: page))
            let videos = parseArticleList(from: html)
            return FuliCategoryResult(videos: videos, page: page, hasMore: articleHasMore(from: html, page: page))
        } catch {
            print("[\(platformName)] HTML 图文分类失败: \(error)")
            return FuliCategoryResult(videos: [], page: page, hasMore: false)
        }
    }

    private func fetchArticleDetail(vodId: String) async -> FuliDetail {
        do {
            let html = try await fetchHTML(articleDetailURL(id: vodId))
            let title = parseFirstText(from: html, pattern: #"<h1[^>]*>([\s\S]*?)</h1>"#)
                ?? parseFirstText(from: html, pattern: #"<title[^>]*>([\s\S]*?)</title>"#)
                ?? ""
            let images = parseImageURLs(from: html)
            let pic = images.first ?? ""
            return FuliDetail(
                vodId: vodId,
                vodName: title,
                vodPic: pic,
                vodContent: nil,
                playFrom: platformName,
                episodes: [FuliEpisode(name: "浏览套图", url: pic, images: images)]
            )
        } catch {
            print("[\(platformName)] HTML 图文详情失败: \(error)")
            return emptyDetail(vodId: vodId)
        }
    }

    private func parseCategories(from json: [String: Any]) async -> [FuliCategory] {
        guard let classes = json["class"] as? [[String: Any]] else { return [] }
        let all = classes.compactMap { item -> FuliCategory? in
            let id = stringValue(item["type_id"])
            let name = item["type_name"] as? String ?? ""
            guard !id.isEmpty, !name.isEmpty else { return nil }
            return FuliCategory(typeId: id, typeName: name)
        }

        guard let rootId = platform.rootTypeId, !rootId.isEmpty else { return all }
        let rootName = platform.rootTypeName
            ?? all.first(where: { $0.typeId == rootId })?.typeName
            ?? platform.name
        let children = await discoverChildCategories(from: all, rootId: rootId)
        setCachedChildren(children)
        return [FuliCategory(typeId: rootId, typeName: rootName, subCategories: children)]
    }

    private func discoverChildCategories(from all: [FuliCategory], rootId: String) async -> [FuliCategory] {
        let mode = (platform.childDiscovery ?? "type_id_1").lowercased()
        guard mode == "type_id_1" else { return [] }

        var indexed: [(Int, FuliCategory)] = []
        await withTaskGroup(of: (Int, FuliCategory)?.self) { group in
            for (index, category) in all.enumerated() where category.typeId != rootId {
                group.addTask { [weak self] in
                    guard let self = self else { return nil }
                    return await self.categoryBelongsToRoot(category, rootId: rootId) ? (index, category) : nil
                }
            }

            for await result in group {
                if let result = result { indexed.append(result) }
            }
        }

        return indexed
            .sorted { $0.0 < $1.0 }
            .map { $0.1 }
    }

    private func categoryBelongsToRoot(_ category: FuliCategory, rootId: String) async -> Bool {
        do {
            let data = try await fetchJSON("\(apiBase)?ac=detail&t=\(category.typeId)&pg=1")
            guard let list = data["list"] as? [[String: Any]] else { return false }
            return list.contains { stringValue($0["type_id_1"]) == rootId }
        } catch {
            return false
        }
    }

    private func ensureChildCategories() async -> [FuliCategory] {
        cacheLock.lock()
        if let cached = childCategoryCache {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        do {
            let data = try await fetchJSON("\(apiBase)?ac=list")
            _ = await parseCategories(from: data)
        } catch {
            print("[\(platformName)] 子分类发现失败: \(error)")
        }

        cacheLock.lock()
        let cached = childCategoryCache ?? []
        cacheLock.unlock()
        return cached
    }

    private func setCachedChildren(_ children: [FuliCategory]) {
        cacheLock.lock()
        childCategoryCache = children
        cacheLock.unlock()
    }

    private func parseList(from json: [String: Any]) -> [FuliVideo] {
        guard let list = json["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard isItemAllowed(item) else { return nil }
            return parseVideoItem(item)
        }
    }

    private func isItemAllowed(_ item: [String: Any]) -> Bool {
        if let rootId = platform.rootTypeId, !rootId.isEmpty {
            let parent = stringValue(item["type_id_1"])
            if !parent.isEmpty, parent != rootId { return false }
        }

        let playUrl = (item["vod_play_url"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = (platform.itemRule?.vodPlayUrl ?? (contentCategory == .comic ? "empty" : "required")).lowercased()
        switch rule {
        case "required":
            return !playUrl.isEmpty
        case "empty":
            return playUrl.isEmpty
        default:
            return true
        }
    }

    private func parseVideoItem(_ item: [String: Any]) -> FuliVideo? {
        let id = stringValue(item["vod_id"])
        let name = item["vod_name"] as? String ?? ""
        let pic = normalizeUrl(
            (item["vod_pic"] as? String)
            ?? (item["vod_pic_thumb"] as? String)
            ?? (item["vod_pic_slide"] as? String)
            ?? "",
            host: currentHost
        )
        let remarks = item["vod_remarks"] as? String
        guard !id.isEmpty, !name.isEmpty else { return nil }
        return FuliVideo(vodId: id, vodName: name, vodPic: pic, vodRemarks: remarks)
    }

    private func parseDetail(_ item: [String: Any]) -> FuliDetail? {
        let id = stringValue(item["vod_id"])
        let name = item["vod_name"] as? String ?? ""
        let pic = normalizeUrl(item["vod_pic"] as? String ?? "", host: currentHost)
        let content = item["vod_content"] as? String
        guard !id.isEmpty else { return nil }

        if contentCategory == .comic || (platform.detailMode ?? "").lowercased() == "comic_images" {
            let images = parseImages(from: item)
            return FuliDetail(
                vodId: id,
                vodName: name,
                vodPic: pic,
                vodContent: content,
                playFrom: platformName,
                episodes: [FuliEpisode(name: "浏览套图", url: pic, images: images)]
            )
        }

        return FuliDetail(
            vodId: id,
            vodName: name,
            vodPic: pic,
            vodContent: content,
            playFrom: item["vod_play_from"] as? String ?? platformName,
            episodes: parseEpisodes(from: item)
        )
    }

    private func parseEpisodes(from item: [String: Any]) -> [FuliEpisode] {
        let playUrl = item["vod_play_url"] as? String ?? ""
        guard !playUrl.isEmpty else { return [] }

        var episodes: [FuliEpisode] = []
        let groups = playUrl.components(separatedBy: "$$$")
        for (index, group) in groups.enumerated() {
            for pair in group.components(separatedBy: "#") {
                let parts = pair.components(separatedBy: "$")
                guard parts.count >= 2 else { continue }
                let name = parts[0].isEmpty ? "线路\(index + 1)" : parts[0]
                let url = normalizeUrl(parts[1], host: currentHost)
                if !url.isEmpty { episodes.append(FuliEpisode(name: name, url: url)) }
            }
        }
        return episodes
    }

    private func parseImages(from item: [String: Any]) -> [String] {
        var images: [String] = []
        if let content = item["vod_content"] as? String {
            let pattern = #"<img[^>]+src=["']([^"']+)["']"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                for match in regex.matches(in: content, range: NSRange(content.startIndex..., in: content)) {
                    if let range = Range(match.range(at: 1), in: content) {
                        let url = normalizeUrl(String(content[range]), host: currentHost)
                        if !url.isEmpty { images.append(url) }
                    }
                }
            }
        }

        if images.isEmpty {
            let pic = normalizeUrl(item["vod_pic"] as? String ?? "", host: currentHost)
            if !pic.isEmpty { images.append(pic) }
        }
        return images
    }

    private func articleListURL(typeId: String, page: Int) -> String {
        let pageSuffix = page <= 1 ? "" : "-\(page)"
        let template = platform.articleListPath ?? "/arttype/{typeId}{pageSuffix}.html"
        let path = template
            .replacingOccurrences(of: "{typeId}", with: typeId)
            .replacingOccurrences(of: "{page}", with: "\(page)")
            .replacingOccurrences(of: "{pageSuffix}", with: pageSuffix)
        return absoluteURL(path)
    }

    private func articleDetailURL(id: String) -> String {
        let template = platform.articleDetailPath ?? "/artdetail-{id}.html"
        let path = template.replacingOccurrences(of: "{id}", with: id)
        return absoluteURL(path)
    }

    private func absoluteURL(_ path: String) -> String {
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
        return currentHost + (path.hasPrefix("/") ? path : "/\(path)")
    }

    private func parseArticleCategories(from html: String, rootId: String) -> [FuliCategory] {
        let pattern = #"<a[^>]+href=["'][^"']*/arttype/(\d+)(?:-\d+)?\.html["'][^>]*>([\s\S]*?)</a>"#
        var result: [FuliCategory] = []
        var seen = Set<String>()
        for match in regexMatches(pattern: pattern, in: html) {
            guard match.count >= 3 else { continue }
            let id = match[1]
            let name = cleanHTMLText(match[2])
            guard id != rootId, !id.isEmpty, !name.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            result.append(FuliCategory(typeId: id, typeName: name))
        }
        return result
    }

    private func parseArticleList(from html: String) -> [FuliVideo] {
        let pattern = #"<a[^>]+href=["'][^"']*/artdetail-(\d+)\.html["'][^>]*>([\s\S]*?)</a>"#
        var result: [FuliVideo] = []
        var seen = Set<String>()
        for match in regexMatches(pattern: pattern, in: html) {
            guard match.count >= 3 else { continue }
            let id = match[1]
            let title = cleanHTMLText(match[2])
            guard !id.isEmpty, !title.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            let pic = nearbyArticleImage(for: id, in: html) ?? ""
            result.append(FuliVideo(vodId: id, vodName: title, vodPic: pic, vodRemarks: "套图"))
        }
        return result
    }

    private func nearbyArticleImage(for id: String, in html: String) -> String? {
        guard let idRange = html.range(of: "artdetail-\(id).html") else { return nil }
        let lower = html.index(idRange.lowerBound, offsetBy: -1200, limitedBy: html.startIndex) ?? html.startIndex
        let upper = html.index(idRange.upperBound, offsetBy: 1200, limitedBy: html.endIndex) ?? html.endIndex
        let block = String(html[lower..<upper])
        return parseImageURLs(from: block).first
    }

    private func articleHasMore(from html: String, page: Int) -> Bool {
        html.contains("arttype/") && html.contains("-\(page + 1).html")
    }

    private func parseImageURLs(from html: String) -> [String] {
        let pattern = #"<img[^>]+(?:src|data-src|data-original|data-lazy-src)=["']([^"']+)["']"#
        var result: [String] = []
        var seen = Set<String>()
        for match in regexMatches(pattern: pattern, in: html) {
            guard match.count >= 2 else { continue }
            let url = normalizeUrl(match[1], host: currentHost)
            guard !url.isEmpty, isLikelyContentImage(url), !seen.contains(url) else { continue }
            seen.insert(url)
            result.append(url)
        }
        return result
    }

    private func isLikelyContentImage(_ url: String) -> Bool {
        let lower = url.lowercased()
        guard lower.contains(".jpg") || lower.contains(".jpeg") || lower.contains(".png") || lower.contains(".webp") else {
            return false
        }
        return !lower.contains("logo") && !lower.contains("icon") && !lower.contains("avatar")
    }

    private func parseFirstText(from html: String, pattern: String) -> String? {
        regexMatches(pattern: pattern, in: html).first.flatMap { match in
            guard match.count >= 2 else { return nil }
            let text = cleanHTMLText(match[1])
            return text.isEmpty ? nil : text
        }
    }

    private func regexMatches(pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).compactMap { index in
                guard let range = Range(match.range(at: index), in: text) else { return nil }
                return String(text[range])
            }
        }
    }

    private func cleanHTMLText(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetchJSON(_ urlString: String) async throws -> [String: Any] {
        let data = try await fetchData(urlString)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return json
    }

    private func hasMore(from json: [String: Any], count: Int, page: Int) -> Bool {
        let pageCount = intValue(json["pagecount"]) ?? page
        let limit = intValue(json["limit"]) ?? 20
        return page < pageCount || count >= limit
    }

    private func emptyDetail(vodId: String) -> FuliDetail {
        FuliDetail(vodId: vodId, vodName: "", vodPic: "", vodContent: nil, playFrom: platformName, episodes: [])
    }

    private func normalizeUrl(_ url: String, host: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return trimmed }
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        if trimmed.hasPrefix("/") { return host + trimmed }
        if !trimmed.contains("://") { return "https://" + trimmed }
        return trimmed
    }

    private func stringValue(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? Int { return String(value) }
        if let value = value as? Double { return String(Int(value)) }
        return ""
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        if let value = value as? Double { return Int(value) }
        return nil
    }

    private func isAllowedHeader(_ key: String) -> Bool {
        let lower = key.lowercased()
        return ["user-agent", "referer", "accept", "accept-language", "origin"].contains(lower)
    }
}
