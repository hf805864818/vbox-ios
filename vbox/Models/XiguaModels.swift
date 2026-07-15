import Foundation

// MARK: - 吸瓜平台数据模型
// 基于 TVBox 蜘蛛协议，对应 Python 脚本中 homeContent / categoryContent / detailContent 的返回结构
// 域名管理通过项目统一的 WelfareDomainStore 实现

/// 视频分类
struct XiguaCategory: Identifiable, Codable {
    var id: String { typeId }
    let typeId: String
    let typeName: String

    enum CodingKeys: String, CodingKey {
        case typeId = "type_id"
        case typeName = "type_name"
    }
}

/// 视频条目
struct XiguaVideo: Identifiable, Codable {
    var id: String { vodId }
    let vodId: String
    let vodName: String
    let vodPic: String
    var vodRemarks: String?
    var vodTag: String?

    enum CodingKeys: String, CodingKey {
        case vodId = "vod_id"
        case vodName = "vod_name"
        case vodPic = "vod_pic"
        case vodRemarks = "vod_remarks"
        case vodTag = "vod_tag"
    }
}

/// 首页内容结果
struct XiguaHomeResult {
    let categories: [XiguaCategory]
    let videos: [XiguaVideo]
}

/// 分类内容结果
struct XiguaCategoryResult {
    let videos: [XiguaVideo]
    let page: Int
    let pagecount: Int
    let total: Int
}

/// 视频详情
struct XiguaDetail {
    let vodId: String
    let vodContent: String
    let playFrom: String
    let playEpisodes: [XiguaEpisode]
}

/// 剧集
struct XiguaEpisode: Identifiable {
    var id: String { "\(name)_\(url)" }
    let name: String
    let url: String
}

/// 播放内容结果
struct XiguaPlayerResult {
    let parse: Int       // 0=直接播放, 1=需要解析
    let url: String
    let headers: [String: String]
}

/// 搜索内容结果
struct XiguaSearchResult {
    let videos: [XiguaVideo]
    let page: Int
}