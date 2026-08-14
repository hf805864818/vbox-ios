//
//  WelfarePlatformConfig.swift
//  vbox
//
//  Phase 2：iOS 客户端新增文件（不改任何现有代码）
//  作用：定义福利平台远程配置的数据模型，对应远端 sources/welfare_platforms.json 的 schema。
//
//  使用方式：
//    let data = try JSONDecoder().decode(WelfarePlatformConfig.self, from: jsonData)
//    for platform in data.platforms { ... }
//
//  注意：本文件是纯数据模型，所有逻辑（加载/缓存/路由）放在其他 WelfareRemote/* 文件中。
//

import Foundation

// MARK: - 顶层配置（对应 welfare_platforms.json 根对象）

/// 福利平台远程配置完整模型
/// JSON 示例（远端 sources/welfare_platforms.json）：
/// ```json
/// {
///   "_meta": { ... },
///   "schemaVersion": 1,
///   "categories": [ ... ],
///   "platforms": [ ... ]
/// }
/// ```
struct WelfarePlatformConfig: Codable, Equatable {
    /// 元数据（仅作说明用，不参与业务逻辑）
    let meta: WelfarePlatformConfigMeta?
    /// schema 版本号（用于将来字段变更兼容性检查）
    let schemaVersion: Int
    /// 平台分类列表（视频 / 直播 / 漫画）
    let categories: [WelfareCategory]
    /// 平台列表
    let platforms: [WelfarePlatform]

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case schemaVersion
        case categories
        case platforms
    }

    /// 校验当前 JSON 是否合法（解码失败时返回 false）
    static func isValid(jsonData: Data) -> Bool {
        do {
            _ = try JSONDecoder().decode(WelfarePlatformConfig.self, from: jsonData)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - 元数据

/// 远端 welfare_platforms.json 的 _meta 字段
/// 仅作日志/调试用途，不影响业务逻辑。
struct WelfarePlatformConfigMeta: Codable, Equatable {
    let name: String?
    let type: String?
    let description: String?
    let version: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case name
        case type
        case description
        case version
        case updatedAt
    }
}

// MARK: - 平台分类

/// 福利平台分类（视频 / 直播 / 漫画）
/// 与 WelfareHomeView 中的 WelfareTab 概念一致。
struct WelfareCategory: Codable, Equatable, Identifiable {
    /// 唯一 key（建议与现有 WelfareTab 命名一致：video / live / comic）
    let key: String
    /// 显示名称（中文）
    let name: String
    /// SF Symbol 图标
    let icon: String

    var id: String { key }
}

// MARK: - 平台元数据

/// 福利平台完整元数据
/// 对应 welfare_platforms.json 中 platforms 数组的每个元素。
struct WelfarePlatform: Codable, Equatable, Identifiable {
    /// 平台唯一 key（不可变，迁移用户排序数据时用作主键）
    let platformKey: String
    /// 平台显示名称（如 "香蕉秀"）
    let name: String
    /// 分类 key（video / live / comic）
    let category: String
    /// SF Symbol 图标
    let icon: String
    /// 平台描述（用于卡片副标题）
    let desc: String
    /// 对应客户端 Service 实现类型（用于路由分发）
    ///   - "ybox_special"    → 香蕉秀专用（fetchBanana* 系列）
    ///   - "daily_battle"    → 每日大乱斗 / 每日大赛
    ///   - "kanliao"         → 今日看料
    ///   - "aidan_video"     → 艾旦福利视频（CMS V10）
    ///   - "welfare_spider"  → 福利专区专用远程 Spider 脚本（JS）
    ///   - "python_spider"   → 福利专区 Python 蜘蛛脚本
    /// 阶段3 改造：删除 14 个死 case 注释（mystery_movie/sihu_video/xcp/luoli_av/madou_free/jiujiu/korean_porn/heiliao/xigua/fuli_base/sb_aggregation/aidan_comic/remote_cms_v10/ybox_xjsp）
    let serviceType: String
    /// 默认域名列表（按顺序回退探测）
    let defaultHosts: [String]
    /// 排序权重（同 category 内按 sortOrder 升序展示）
    let sortOrder: Int
    /// 是否默认开启代理（远程配置字段，当前所有平台默认关闭）
    let defaultProxy: Bool?
    /// 备注（仅作说明，不影响业务）
    let notes: String?
    /// 福利专区专用 Spider 脚本路径。
    ///
    /// 仅当 serviceType == "welfare_spider" 时使用；普通福利平台和普通远程源不会读取该字段。
    let api: String?
    /// 福利专区专用脚本类型，当前识别 "python" 和 "javascript"。
    let scriptType: String?
    /// 福利专区专用脚本执行引擎标记，预留给后续运行时扩展。
    let engine: String?
    /// JS Spider 是否需要 SSL 绕过（访问自签名证书服务器时启用）。
    /// 仅当 scriptType == "javascript" 时生效。
    let sslBypass: Bool?
    /// 是否允许进入普通首页。福利 Spider 默认不允许。
    let visibleInHome: Bool?
    /// 是否允许进入普通全局搜索。福利 Spider 默认不允许。
    let visibleInGlobalSearch: Bool?
    /// 是否允许注册到普通 Spider 源池。福利 Spider 默认不允许。
    let visibleInNormalSpider: Bool?
    /// 远程 CMS V10 API 类型标记，当前识别 "cms_v10"。
    let apiKind: String?
    /// CMS V10 API 路径，默认 "/api.php/provide/vod/"。
    let apiPath: String?
    /// 需要展示的大分类 ID，如艾旦福利视频为 5，福利图片为 33。
    let rootTypeId: String?
    /// 大分类显示名称，用于生成“全部”分类。
    let rootTypeName: String?
    /// 子分类发现方式，当前支持 "type_id_1"。
    let childDiscovery: String?
    /// 内容类型：video / comic。
    let contentType: String?
    /// 详情处理模式：video / comic_images。
    let detailMode: String?
    /// HTML 图文列表路径模板，如 "/arttype/{typeId}{pageSuffix}.html"。
    let articleListPath: String?
    /// HTML 图文详情路径模板，如 "/artdetail-{id}.html"。
    let articleDetailPath: String?
    /// 图片防盗链 Referer。
    let imageReferer: String?
    /// 图片请求是否需要 SSL 绕过。
    let imageSSLBypass: Bool?
    /// 远程源自定义请求头，仅通用远程 Service 使用。
    let headers: [String: String]?
    /// 播放器 Referer 策略："auto"（默认，域名不匹配时用CDN自身Referer）/ "keep"（始终保留脚本返回的Referer）。
    /// 直播类福利源常用 "keep"，因为播放CDN域名与主站域名不同但仍需主站Referer防盗链。
    let playerRefererMode: String?
    /// 条目过滤规则。
    let itemRule: WelfareRemoteItemRule?

    var id: String { platformKey }

    enum CodingKeys: String, CodingKey {
        case platformKey
        case name
        case category
        case icon
        case desc
        case serviceType
        case defaultHosts
        case sortOrder
        case defaultProxy
        case notes
        case api
        case scriptType
        case engine
        case sslBypass
        case visibleInHome
        case visibleInGlobalSearch
        case visibleInNormalSpider
        case apiKind
        case apiPath
        case rootTypeId
        case rootTypeName
        case childDiscovery
        case contentType
        case detailMode
        case articleListPath
        case articleDetailPath
        case imageReferer
        case imageSSLBypass
        case headers
        case playerRefererMode
        case itemRule
    }

    /// 获取当前第一个可用域名
    var primaryHost: String { defaultHosts.first ?? "" }

    /// 是否为福利专区专用 Spider 平台（含 JS 和 Python）。
    var isWelfareSpider: Bool {
        serviceType == WelfareServiceType.welfareSpider.rawValue
            || serviceType == WelfareServiceType.pythonSpider.rawValue
    }

    /// 福利 Spider 是否允许进入普通 Spider 源池，默认 false。
    var allowsNormalSpiderRegistration: Bool {
        visibleInNormalSpider ?? false
    }
}

/// 远程通用福利源条目过滤规则。
struct WelfareRemoteItemRule: Codable, Equatable {
    /// vod_play_url 规则：required / empty / any。
    let vodPlayUrl: String?
}

// MARK: - 分类枚举（与 WelfareHomeView 中的 WelfareTab 对齐）

/// 福利分类枚举（远程源版本，与现有 WelfareTab 等价）
/// 不放在 WelfareHomeView 内部，便于外部 View 复用。
enum RemoteWelfareCategory: String, CaseIterable, Identifiable {
    case video = "video"
    case live = "live"
    case comic = "comic"

    var id: String { rawValue }

    /// 中文显示名
    var displayName: String {
        switch self {
        case .video: return "视频"
        case .live: return "直播"
        case .comic: return "漫画"
        }
    }

    /// SF Symbol 图标（与 WelfareTab 保持一致）
    var icon: String {
        switch self {
        case .video: return "play.rectangle.fill"
        case .live: return "antenna.radiowaves.left.and.right"
        case .comic: return "books.vertical.fill"
        }
    }

    /// 从 category key 安全转换为枚举（未知 key 兜底为 video）
    static func from(key: String) -> RemoteWelfareCategory {
        RemoteWelfareCategory(rawValue: key) ?? .video
    }
}

// MARK: - 业务 ServiceType 枚举（用于 switch 路由）

/// 客户端 Service 实现类型枚举
/// 与 WelfarePlatform.serviceType 字符串对应。
/// 新增 Service 时只需在此处加一个 case，并在 WelfarePlatformRouter 中加一个 case 分支。
enum WelfareServiceType: String, CaseIterable {
    case yboxSpecial = "ybox_special"          // 香蕉秀专用
    case dailyBattle = "daily_battle"          // 每日大乱斗 / 每日大赛
    case kanliao = "kanliao"                   // 今日看料
    case aidanVideo = "aidan_video"            // 艾旦福利视频（CMS V10 专用）
    case fuliBase = "fuli_base"                // 通用 FuliBaseService 子类（熊猫视频等）
    case remoteCmsV10 = "remote_cms_v10"       // 远程可配置 CMS V10 福利源
    case welfareSpider = "welfare_spider"      // 福利专区专用远程 Spider 脚本（JS）
    case pythonSpider = "python_spider"        // 福利专区 Python 蜘蛛脚本

    /// 未知 serviceType：远程 JSON 中的 serviceType 在枚举中找不到时使用，
    /// 路由会显示 UnsupportedPlatformView 错误页，不会兜底到其他平台。
    case unknown = "unknown"

    init(raw: String) {
        self = WelfareServiceType(rawValue: raw) ?? .unknown
    }
}
