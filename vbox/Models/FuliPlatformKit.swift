import Foundation

// MARK: - 通用福利平台数据模型
// 为多个 HTML/API 类福利平台提供统一的数据抽象

/// 分类（支持一级 + 可选二级）
struct FuliCategory: Identifiable, Equatable {
    var id: String { "\(typeId)_\(typeName)" }
    let typeId: String
    let typeName: String
    let subCategories: [FuliCategory]?

    init(typeId: String, typeName: String, subCategories: [FuliCategory]? = nil) {
        self.typeId = typeId
        self.typeName = typeName
        self.subCategories = subCategories
    }
}

/// 视频条目
struct FuliVideo: Identifiable {
    var id: String { vodId }
    let vodId: String
    let vodName: String
    let vodPic: String
    var vodRemarks: String?
    var duration: String?
    var score: String?
    var areaName: String?

    init(vodId: String, vodName: String, vodPic: String, vodRemarks: String? = nil,
         duration: String? = nil, score: String? = nil, areaName: String? = nil) {
        self.vodId = vodId
        self.vodName = vodName
        self.vodPic = vodPic
        self.vodRemarks = vodRemarks
        self.duration = duration
        self.score = score
        self.areaName = areaName
    }
}

/// 内容类型（用于区分视频平台与漫画平台）
enum FuliContentCategory {
    case video
    case comic
}

/// 剧集
struct FuliEpisode: Identifiable {
    var id: String { "\(name)_\(url)" }
    let name: String
    let url: String
    /// 漫画/套图专用：该剧集包含的图片地址列表
    var images: [String]?

    init(name: String, url: String, images: [String]? = nil) {
        self.name = name
        self.url = url
        self.images = images
    }
}

/// 视频详情
struct FuliDetail {
    let vodId: String
    let vodName: String
    let vodPic: String
    let vodContent: String?
    let playFrom: String
    let episodes: [FuliEpisode]
}

/// 首页结果
struct FuliHomeResult {
    let categories: [FuliCategory]
    let videos: [FuliVideo]
}

/// 分类结果
struct FuliCategoryResult {
    let videos: [FuliVideo]
    let page: Int
    let hasMore: Bool
}

/// 搜索结果
struct FuliSearchResult {
    let videos: [FuliVideo]
    let page: Int
    let hasMore: Bool
}

/// 播放器结果
struct FuliPlayerResult {
    let url: String
    let headers: [String: String]
    let parse: Int // 0=直接播放, 1=需要Web解析
}

// MARK: - 分类为空时的默认首页
extension FuliHomeResult {
    static var empty: FuliHomeResult { FuliHomeResult(categories: [], videos: []) }
}
