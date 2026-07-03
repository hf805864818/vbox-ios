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
    /// 分类编码（扩展字段）
    var typeCode: String?
    /// 分类封面（扩展字段）
    var cover: String?

    init(dict: [String: Any], parentType: SangeNavType) {
        self.id = dictString(dict, keys: ["id", "subNavId", "classifyId", "typeId"]) ?? UUID().uuidString
        self.name = dictString(dict, keys: ["name", "subNavName", "classifyName", "typeName", "title"]) ?? "未命名"
        self.sort = dictInt(dict, keys: ["sort", "order", "seq"]) ?? 0
        self.parentType = parentType
        self.typeCode = dictString(dict, keys: ["typeCode", "code", "subTypeCode", "categoryCode"])
        self.cover = dictString(dict, keys: ["cover", "coverUrl", "image", "pic", "icon"])
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
    /// 播放量
    var playCount: String?
    /// 点赞数
    var likeCount: String?
    /// 收费类型（0=免费, 1=付费, 2=VIP）
    var chargeType: Int?
    /// 价格
    var price: String?
    /// 发布者
    var publisherName: String?
    /// 默认播放地址（详情接口返回的主播放线路）
    var defaultPlayUrl: String?
    /// 简介 / 描述
    var intro: String?
    /// 导演
    var director: String?
    /// 主演
    var actors: String?
    /// 年份
    var year: String?
    /// 地区
    var area: String?
    /// 分类 ID
    var classifyId: String?
    /// 播放列表（详情页可能返回多集）
    var playList: [[String: String]]?

    init(dict: [String: Any], navType: SangeNavType = .video) {
        self.id = dictString(dict, keys: ["id", "vodId", "videoId", "movId", "comicId", "novelId"]) ?? UUID().uuidString
        self.name = dictString(dict, keys: ["name", "title", "vodName", "videoName", "comicName", "novelName"]) ?? "未命名"
        self.cover = dictString(dict, keys: ["cover", "coverH", "coverUrl", "coverImage", "image", "pic", "vodPic", "thumb"]) ?? ""
        self.playUrl = dictString(dict, keys: ["playUrl", "url", "videoUrl", "vodPlayUrl", "streamUrl", "m3u8"])
        self.duration = dictString(dict, keys: ["duration", "time", "length", "vodDuration"])
        self.remarks = dictString(dict, keys: ["remarks", "typeName", "classifyName", "tag", "score"])
        self.navType = navType
        // 扩展字段
        self.playCount = dictString(dict, keys: ["playCount", "plays", "viewCount", "views", "vodPlayNum", "playNum"])
        self.likeCount = dictString(dict, keys: ["likeCount", "likes", "likeNum", "thumbUp", "praiseNum"])
        self.chargeType = dictInt(dict, keys: ["chargeType", "isFree", "payType", "vodPay", "isPay"])
        self.price = dictString(dict, keys: ["price", "vipPrice", "vodPrice", "money", "cost"])
        self.publisherName = dictString(dict, keys: ["publisherName", "publisher", "author", "uploader", "vodAuthor", "nickname"])
        // 详情字段
        self.defaultPlayUrl = dictString(dict, keys: ["defaultPlayUrl", "defaultUrl", "mainPlayUrl"])
        // 如果 defaultPlayUrl 为空，回退到 playUrl
        if self.defaultPlayUrl == nil {
            self.defaultPlayUrl = self.playUrl
        }
        self.intro = dictString(dict, keys: ["intro", "description", "content", "vodContent", "vodIntro", "blurb"])
        self.director = dictString(dict, keys: ["director", "vodDirector"])
        self.actors = dictString(dict, keys: ["actors", "actor", "vodActor", "starring"])
        self.year = dictString(dict, keys: ["year", "vodYear", "releaseYear"])
        self.area = dictString(dict, keys: ["area", "region", "country", "vodArea"])
        self.classifyId = dictString(dict, keys: ["classifyId", "typeId", "navId"])

        // 解析播放列表（可能是数组或 JSON 字符串）
        if let pl = dict["playList"] as? [[String: String]] {
            self.playList = pl
        } else if let plStr = dict["playList"] as? String,
                  let data = plStr.data(using: .utf8),
                  let pl = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            self.playList = pl
        }
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
        item.vodPlayUrl = defaultPlayUrl ?? playUrl
        return item
    }
}

// MARK: - 推荐分类
struct SangeRecommendCategory: Identifiable, Hashable {
    var id: String { recId }
    /// 推荐分类ID
    var recId: String
    /// 推荐分类名称
    var recName: String
    /// 推荐分类编码
    var recCode: String?
    /// 推荐类型
    var recType: String?
    /// UI展示类型
    var uiType: String?
    /// 视频列表
    var videoList: [SangeVideoItem]

    init(dict: [String: Any]) {
        self.recId = dictString(dict, keys: ["recId", "id", "recommendId", "categoryId"]) ?? UUID().uuidString
        self.recName = dictString(dict, keys: ["recName", "name", "recommendName", "title", "categoryName"]) ?? "推荐"
        self.recCode = dictString(dict, keys: ["recCode", "code", "recommendCode", "categoryCode"])
        self.recType = dictString(dict, keys: ["recType", "type", "recommendType", "categoryType"])
        self.uiType = dictString(dict, keys: ["uiType", "ui_style", "layoutType", "showType", "style"])

        // 解析 videoList，兼容多种字段名
        var list: [[String: Any]] = []
        if let videos = dict["videoList"] as? [[String: Any]] {
            list = videos
        } else if let videos = dict["list"] as? [[String: Any]] {
            list = videos
        } else if let videos = dict["vodList"] as? [[String: Any]] {
            list = videos
        } else if let videos = dict["items"] as? [[String: Any]] {
            list = videos
        } else if let videos = dict["data"] as? [[String: Any]] {
            list = videos
        }

        // 根据 recType 或 uiType 推断 navType，默认 .video
        let navType: SangeNavType
        if let type = self.recType {
            navType = SangeNavType(rawValue: type) ?? .video
        } else if let code = self.recCode {
            navType = SangeNavType(rawValue: code) ?? .video
        } else {
            navType = .video
        }

        self.videoList = list.compactMap { SangeVideoItem(dict: $0, navType: navType) }
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
