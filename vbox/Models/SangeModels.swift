import Foundation

// MARK: - 大分类（视频 / 短视频 / 漫画 / 小说 / 直播）
struct SangeBigCategory: Identifiable, Hashable {
    var id: String
    var name: String
    /// 对应后端模块：video / shortVideo / comic / novel
    var navType: SangeNavType
    /// 排序
    var sort: Int = 0
    /// 该大分类下的小分类
    var subCategories: [SangeSubCategory] = []

    init(dict: [String: Any]) {
        self.id = dictString(dict, keys: ["id", "navId", "typeId", "classifyId"]) ?? UUID().uuidString
        self.name = dictString(dict, keys: ["name", "navName", "typeName", "classifyName", "title"]) ?? "未命名"
        self.sort = dictInt(dict, keys: ["sort", "order", "seq"]) ?? 0

        if let type = dictString(dict, keys: ["navType", "type", "module"]) {
            self.navType = SangeNavType(rawValue: type) ?? .video
        } else {
            self.navType = .video
        }

        if let subs = dict["subNavList"] as? [[String: Any]] {
            self.subCategories = subs.compactMap { SangeSubCategory(dict: $0, parentType: self.navType) }
        } else if let subs = dict["subList"] as? [[String: Any]] {
            self.subCategories = subs.compactMap { SangeSubCategory(dict: $0, parentType: self.navType) }
        } else if let subs = dict["classifyList"] as? [[String: Any]] {
            self.subCategories = subs.compactMap { SangeSubCategory(dict: $0, parentType: self.navType) }
        }
    }

    static let samples: [SangeBigCategory] = [
        SangeBigCategory(dict: ["id": "video", "name": "视频", "navType": "video"]),
        SangeBigCategory(dict: ["id": "shortVideo", "name": "短视频", "navType": "shortVideo"]),
        SangeBigCategory(dict: ["id": "comic", "name": "漫画", "navType": "comic"]),
        SangeBigCategory(dict: ["id": "novel", "name": "小说", "navType": "novel"])
    ]
}

// MARK: - 小分类
struct SangeSubCategory: Identifiable, Hashable {
    var id: String
    var name: String
    var parentType: SangeNavType
    var sort: Int = 0

    init(dict: [String: Any], parentType: SangeNavType) {
        self.id = dictString(dict, keys: ["id", "subNavId", "classifyId", "typeId"]) ?? UUID().uuidString
        self.name = dictString(dict, keys: ["name", "subNavName", "classifyName", "typeName", "title"]) ?? "未命名"
        self.sort = dictInt(dict, keys: ["sort", "order", "seq"]) ?? 0
        self.parentType = parentType
    }
}

// MARK: - 导航类型
enum SangeNavType: String, CaseIterable {
    case video       // 长视频
    case shortVideo  // 短视频 / 抖音
    case comic       // 漫画
    case novel       // 小说

    var displayName: String {
        switch self {
        case .video: return "视频"
        case .shortVideo: return "抖音"
        case .comic: return "漫画"
        case .novel: return "小说"
        }
    }

    var icon: String {
        switch self {
        case .video: return "play.rectangle.fill"
        case .shortVideo: return "play.square.stack.fill"
        case .comic: return "book.fill"
        case .novel: return "text.book.closed.fill"
        }
    }
}

// MARK: - 资源条目
struct SangeVideoItem: Identifiable, Hashable {
    var id: String
    var name: String
    var cover: String
    var playUrl: String?
    var duration: String?
    var remarks: String?
    var navType: SangeNavType

    init(dict: [String: Any], navType: SangeNavType = .video) {
        self.id = dictString(dict, keys: ["id", "vodId", "videoId", "movId", "comicId", "novelId"]) ?? UUID().uuidString
        self.name = dictString(dict, keys: ["name", "title", "vodName", "videoName", "comicName", "novelName"]) ?? "未命名"
        self.cover = dictString(dict, keys: ["cover", "coverUrl", "coverImage", "image", "pic", "vodPic", "thumb"]) ?? ""
        self.playUrl = dictString(dict, keys: ["playUrl", "url", "videoUrl", "vodPlayUrl", "streamUrl", "m3u8"])
        self.duration = dictString(dict, keys: ["duration", "time", "length", "vodDuration"])
        self.remarks = dictString(dict, keys: ["remarks", "typeName", "classifyName", "tag", "score"])
        self.navType = navType
    }

    /// 转成 vbox 播放器所需的 VodItem
    func toVodItem() -> VodItem {
        var item = VodItem(
            vodId: id,
            vodName: name,
            vodPic: cover,
            vodRemarks: remarks.map { $0.hasPrefix("[福利]") ? $0 : "[福利]\($0)" } ?? "[福利]",
            vodPlayFrom: navType == .shortVideo ? "抖音" : "空虚视频"
        )
        item.vodPlayUrl = playUrl
        return item
    }
}

// MARK: - 字典解析辅助（兼容多种字段名）
func dictString(_ dict: [String: Any], keys: [String]) -> String? {
    for key in keys {
        if let value = dict[key] {
            if let str = value as? String, !str.isEmpty { return str }
            if let num = value as? NSNumber { return num.stringValue }
            if let int = value as? Int { return String(int) }
        }
    }
    return nil
}

func dictInt(_ dict: [String: Any], keys: [String]) -> Int? {
    for key in keys {
        if let value = dict[key] {
            if let int = value as? Int { return int }
            if let str = value as? String, let int = Int(str) { return int }
            if let num = value as? NSNumber { return num.intValue }
        }
    }
    return nil
}
