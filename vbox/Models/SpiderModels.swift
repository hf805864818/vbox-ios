import Foundation

// MARK: - 站点配置
struct SiteConfig: Codable {
    let key: String
    let name: String
    let type: Int       // 0=JSON, 1=XML, 2=HTML, 3=JS
    let api: String?
    let searchable: Int
    let quickSearch: Int
    let filterable: Int
    let ext: String?      // JS蜘蛛文件URL
    let playerType: Int?
}

struct SubscribeConfig: Codable {
    let sites: [SiteConfig]
    let parsers: [ParserConfig]?
    let ads: AdConfig?
    let flags: [String]?
    let banned: [String]?
}

struct ParserConfig: Codable {
    let key: String
    let name: String
    let type: Int
    let url: String?
    let ext: String?
    let playerType: Int?
}

struct AdConfig: Codable {
    let enabled: Bool?
}

// MARK: - 视频数据模型
struct VodCategory: Codable, Identifiable {
    var id: String { typeId }
    let typeId: String
    let typeName: String
    
    enum CodingKeys: String, CodingKey {
        case typeId = "type_id"
        case typeName = "type_name"
    }
}

struct VodItem: Codable, Identifiable {
    var id: String { vodId }
    let vodId: String
    let vodName: String
    let vodPic: String
    let vodRemarks: String?
    let vodYear: String?
    let vodArea: String?
    let vodDirector: String?
    let vodActor: String?
    let vodContent: String?
    let vodPlayFrom: String?
    let vodPlayUrl: String?
    
    // 自定义初始化方法，支持只传必需参数
    init(vodId: String, vodName: String, vodPic: String, vodRemarks: String? = nil,
         vodYear: String? = nil, vodArea: String? = nil, vodDirector: String? = nil,
         vodActor: String? = nil, vodContent: String? = nil, vodPlayFrom: String? = nil,
         vodPlayUrl: String? = nil) {
        self.vodId = vodId
        self.vodName = vodName
        self.vodPic = vodPic
        self.vodRemarks = vodRemarks
        self.vodYear = vodYear
        self.vodArea = vodArea
        self.vodDirector = vodDirector
        self.vodActor = vodActor
        self.vodContent = vodContent
        self.vodPlayFrom = vodPlayFrom
        self.vodPlayUrl = vodPlayUrl
    }
    
    enum CodingKeys: String, CodingKey {
        case vodId = "vod_id"
        case vodName = "vod_name"
        case vodPic = "vod_pic"
        case vodRemarks = "vod_remarks"
        case vodYear = "vod_year"
        case vodArea = "vod_area"
        case vodDirector = "vod_director"
        case vodActor = "vod_actor"
        case vodContent = "vod_content"
        case vodPlayFrom = "vod_play_from"
        case vodPlayUrl = "vod_play_url"
    }
}

struct HomeContentResult: Codable {
    let `class`: [VodCategory]?
    let list: [VodItem]?
}

struct CategoryContentResult: Codable {
    let page: Int?
    let pagecount: Int?
    let limit: Int?
    let total: Int?
    let list: [VodItem]?
}

struct DetailContentResult: Codable {
    let list: [VodItem]?
}

struct SearchContentResult: Codable {
    let list: [VodItem]?
}

struct PlayerContentResult: Codable {
    let parse: Int?
    let playUrl: String?
    let url: String?
    let header: [String: String]?
}
