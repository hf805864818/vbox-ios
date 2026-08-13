import Foundation

// MARK: - CMS V10 内容类型
enum CMSV10ContentType {
    case video   // 有 vod_play_url，可播放
    case comic   // 无 vod_play_url，按套图/图片处理
}

// MARK: - CMS V10 通用解析助手
/// 对应远端 sources/welfare-js/aidan.py 的通用 CMS V10 API 逻辑。
/// 阶段4 清理后仅被 AidanVideoService 复用，避免重复代码。
final class CMSV10Helper {
    static let shared = CMSV10Helper()
    private init() {}

    // 与 aidan.py 一致的保留分类顺序
    let classOrder: [String] = [
        "6", "7", "8", "9", "10", "11", "12", "20", "21", "22", "70", "69",
        "13", "14", "15", "16", "30", "63", "31", "23", "24", "25", "71",
        "26", "27", "28", "29", "64", "17", "18", "37", "65", "66", "67", "68"
    ]

    // 需要过滤掉的非福利分类 ID
    let blockIDs: Set<String> = [
        "1", "2", "3", "4", "5", "32", "33", "34", "35", "36", "38", "39",
        "40", "41", "42", "43", "44", "45", "46", "47", "48", "49", "50",
        "51", "52", "53", "54", "55", "56", "57", "58", "59", "60", "61", "62"
    ]

    // 需要过滤掉的非福利分类名称
    let blockNames: Set<String> = [
        "电影", "电视剧", "综艺", "动漫", "福利视频", "明星", "福利图片",
        "爱蜜社", "头条女神", "美媛馆", "嗲囡囡", "波萝社", "魅妍社", "爱尤物",
        "秀人网", "尤果网", "推女神", "DGC套图", "尤蜜荟", "模范学院", "尤物馆",
        "优星馆", "蜜桃社", "影私荟", "顽味生活", "星乐园", "花の颜", "御女郎",
        "糖果画报", "花漾", "星颜社", "画语界", "直播", "央视", "卫视"
    ]

    // MARK: - 分类解析
    /// 从 CMS V10 /api.php/provide/vod/?ac=list 返回的 JSON 中解析分类列表
    func parseClasses(from json: [String: Any]) -> [FuliCategory] {
        guard let classes = json["class"] as? [[String: Any]] else { return [] }

        let mapped = classes.reduce(into: [String: String]()) { dict, item in
            let id = stringValue(from: item["type_id"])
            let name = item["type_name"] as? String ?? ""
            if !id.isEmpty { dict[id] = name }
        }

        var result: [FuliCategory] = []
        var used = Set<String>()

        // 1. 按 classOrder 保留原始顺序
        for id in classOrder {
            guard let name = mapped[id], !name.isEmpty,
                  !blockIDs.contains(id), !blockNames.contains(name) else { continue }
            result.append(FuliCategory(typeId: id, typeName: name))
            used.insert(id)
        }

        // 2. 追加未在 classOrder 中但合法的新分类
        for item in classes {
            let id = stringValue(from: item["type_id"])
            let name = item["type_name"] as? String ?? ""
            guard !id.isEmpty, !used.contains(id),
                  !blockIDs.contains(id), !blockNames.contains(name) else { continue }
            result.append(FuliCategory(typeId: id, typeName: name))
            used.insert(id)
        }

        return result
    }

    // MARK: - 条目过滤
    /// 判断某条 vod 是否通过非福利过滤（与 aidan.py _ok 一致）
    func isItemAllowed(_ item: [String: Any]) -> Bool {
        let cid = stringValue(from: item["type_id"])
        let tname = item["type_name"] as? String ?? ""
        let vclass = item["vod_class"] as? String ?? ""
        return !blockIDs.contains(cid)
            && !blockNames.contains(tname)
            && !blockNames.contains(vclass)
    }

    /// 判断条目是否符合指定内容类型
    func matchesContentType(_ item: [String: Any], type: CMSV10ContentType) -> Bool {
        let playUrl = (item["vod_play_url"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPlayUrl = !playUrl.isEmpty
        switch type {
        case .video: return hasPlayUrl
        case .comic: return !hasPlayUrl
        }
    }

    // MARK: - 视频条目解析
    func parseVideoItem(_ item: [String: Any], host: String) -> FuliVideo? {
        guard isItemAllowed(item) else { return nil }
        let id = stringValue(from: item["vod_id"])
        let name = item["vod_name"] as? String ?? ""
        let pic = normalizePic(item["vod_pic"] as? String, host: host)
        let remarks = item["vod_remarks"] as? String
        guard !id.isEmpty, !name.isEmpty else { return nil }
        return FuliVideo(vodId: id, vodName: name, vodPic: pic, vodRemarks: remarks)
    }

    // MARK: - 详情解析
    func parseDetail(_ item: [String: Any], host: String, contentType: CMSV10ContentType) -> FuliDetail? {
        let id = stringValue(from: item["vod_id"])
        let name = item["vod_name"] as? String ?? ""
        let pic = normalizePic(item["vod_pic"] as? String, host: host)
        let content = item["vod_content"] as? String
        guard !id.isEmpty else { return nil }

        switch contentType {
        case .video:
            let episodes = parseEpisodes(from: item, host: host)
            return FuliDetail(
                vodId: id, vodName: name, vodPic: pic,
                vodContent: content, playFrom: "艾旦福利视频", episodes: episodes
            )
        case .comic:
            let images = parseImages(from: item, host: host)
            let episodes = [FuliEpisode(name: "浏览套图", url: pic, images: images)]
            return FuliDetail(
                vodId: id, vodName: name, vodPic: pic,
                vodContent: content, playFrom: "艾旦福利套图", episodes: episodes
            )
        }
    }

    // MARK: - 剧集解析
    /// CMS V10 vod_play_url 常见格式：
    ///   "线路A$$$第1集$url1#第2集$url2$$$线路B$$$..."
    private func parseEpisodes(from item: [String: Any], host: String) -> [FuliEpisode] {
        let playUrl = item["vod_play_url"] as? String ?? ""
        guard !playUrl.isEmpty else { return [] }

        var episodes: [FuliEpisode] = []
        let lineSegments = playUrl.components(separatedBy: "$$$")

        for (lineIndex, segment) in lineSegments.enumerated() {
            let pairs = segment.components(separatedBy: "#")
            for pair in pairs {
                let parts = pair.components(separatedBy: "$")
                if parts.count >= 2 {
                    let rawName = parts[0].trimmingCharacters(in: .whitespaces)
                    let epName = rawName.isEmpty ? "线路\(lineIndex + 1)" : rawName
                    let epUrl = normalizeUrl(parts[1].trimmingCharacters(in: .whitespaces), host: host)
                    if !epUrl.isEmpty {
                        episodes.append(FuliEpisode(name: epName, url: epUrl))
                    }
                }
            }
        }
        return episodes
    }

    // MARK: - 图片解析
    /// 从 vod_content 的 HTML 中提取 <img src="...">，兜底返回封面图
    private func parseImages(from item: [String: Any], host: String) -> [String] {
        var images: [String] = []
        if let content = item["vod_content"] as? String {
            let pattern = #"<img[^>]+src=["']([^"']+)["']"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
                for match in matches {
                    if let range = Range(match.range(at: 1), in: content) {
                        let url = normalizeUrl(String(content[range]), host: host)
                        if !url.isEmpty { images.append(url) }
                    }
                }
            }
        }
        if images.isEmpty {
            if let pic = item["vod_pic"] as? String, !pic.isEmpty {
                images.append(normalizePic(pic, host: host))
            }
        }
        return images
    }

    // MARK: - URL 规范化
    func normalizeUrl(_ url: String, host: String) -> String {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return "" }
        if u.hasPrefix("http://") || u.hasPrefix("https://") { return u }
        if u.hasPrefix("//") { return "https:" + u }
        if u.hasPrefix("/") { return host + u }
        if !u.contains("://") { return "https://" + u }
        return u
    }

    func normalizePic(_ pic: String?, host: String) -> String {
        guard let pic = pic, !pic.isEmpty else { return "" }
        return normalizeUrl(pic, host: host)
    }

    // MARK: - 通用类型安全取值
    private func stringValue(from value: Any?) -> String {
        if let v = value as? String { return v }
        if let v = value as? Int { return String(v) }
        if let v = value as? Double { return String(Int(v)) }
        return ""
    }
}
