import Foundation

// MARK: - YBox 分类/平台模型

struct YBoxCategory2: Identifiable {
    var id: String { name }
    let name: String
    let platforms: [YBoxPlatform2]
}

struct YBoxPlatform2: Identifiable {
    var id: String { crawlerPlatformId ?? name }
    let name: String
    let icon: String
    let type: PlatformType2
    let baseURL: String
    let desc: String
    let crawlerPlatformId: String?

    init(name: String, icon: String, type: PlatformType2,
         baseURL: String, desc: String, crawlerPlatformId: String? = nil) {
        self.name = name; self.icon = icon; self.type = type
        self.baseURL = baseURL; self.desc = desc
        self.crawlerPlatformId = crawlerPlatformId
    }

    enum PlatformType2: String { case video, live, comic, audio }
}

// MARK: - 香蕉秀数据模型（zfvwi8 API 返回格式，by QClaw 2026-07-07）

/// 首页分类（来自 /index → data.v2cats 或 data.v2navs）
struct YBoxBananaCategory: Identifiable {
    var id: String { cateId }
    let cateId: String
    let name: String
    let type: String  // "vod"/"special"/"actor"
    /// 子分类列表（二级分类，来自 listing 子项）
    let subCates: [YBoxBananaSubCategory]
}

struct YBoxBananaSubCategory: Identifiable {
    var id: String { cateId }
    let cateId: String
    let name: String
}

/// 视频条目（来自 /vod/listing-{cateid}-x-x-x-x-x-x-x-x-{page}）
struct YBoxBananaVideo: Identifiable {
    var id: String { vodId }
    let vodId: String
    let title: String
    let cover: String          // coverpic
    let duration: String
    let score: String?         // scorenum
    let mosaic: String         // "1"=有码 "2"=无码 "0"=未知
    let cateId: String
    let cateName: String?
    let areaName: String?
    let year: String
    let tags: [String]
    let playCount: Int
    let commentCount: Int
    // 播放路径：/vod/reqplay/{vodId}
    var playPath: String { "/vod/reqplay/\(vodId)" }
}

/// 短视频条目（来自 /minivod/reqlist?page={page}）
struct YBoxBananaMiniVideo: Identifiable {
    var id: String { vodId }
    let vodId: String
    let title: String
    let cover: String
    let videoUrl: String?
    let duration: String
    let userName: String
    let userAvatar: String
    var playPath: String { "/minivod/reqplay/\(vodId)" }
}

/// 专题（来自 /special/listing-0-0-{page}）
struct YBoxBananaSpecial: Identifiable {
    var id: String { spId }
    let spId: String
    let spName: String
    let spCover: String
    let itemCount: Int
}

/// 专题内视频
struct YBoxBananaSpecialVideo: Identifiable {
    var id: String { vodId }
    let vodId: String
    let title: String
    let cover: String
    let duration: String
    let score: String?
    var playPath: String { "/vod/reqplay/\(vodId)" }
}

/// 演员条目（暂用，后续可通过 /index 的 actor 导航获取完整列表）
struct YBoxBananaActor: Identifiable {
    var id: String { actorId }
    let actorId: String
    let name: String
    let avatar: String?
    let videoCount: Int
}

// MARK: - 直播/漫画模型（保留）

struct YBoxLiveItem2: Identifiable {
    var id: String { title }
    let title: String; let img: String; let number: String
    let channels: [YBoxLiveChannel2]
}

struct YBoxLiveChannel2: Identifiable {
    var id: String { title }
    let title: String; let address: String; let img: String
}

struct YBoxComicItem2: Identifiable {
    var id: String { title }
    let title: String; let cover: String; let href: String?
}

// MARK: - YBox 服务
class YBoxService2: ObservableObject {
    static let shared = YBoxService2()

    @Published var categories: [YBoxCategory2] = []
    @Published var liveSources: [YBoxLiveItem2] = []
    @Published var isLiveLoaded = false

    // MARK: - API 网关（从 ybox 抓包确认，by QClaw 2026-07-07）
    private let apiGateway = "https://zfvwi8.ipajx0.cc"

    /// 生成设备认证 token（32位 hex 字符串）
    private var cookieAuth: String {
        // 使用固定的设备标识生成；可替换为用户自定义 token
        let deviceId = Bundle.main.bundleIdentifier ?? "avbox.ios.client"
        let hash = deviceId.data(using: .utf8)!.map { String(format: "%02x", $0) }.joined()
        // 补足到 32 位
        let padding = "a1b2c3d4e5f60708"
        let token = (hash + padding).prefix(32)
        return String(token)
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = [
            "User-Agent": "Dart/3.4 (dart:io)",
            "Accept-Encoding": "gzip",
        ]
        return URLSession(configuration: c)
    }()

    // MARK: - 请求封装

    /// 通用 GET 请求，支持 gzip 解压，返回解析后的 JSON 字典
    private func fetchJSON(path: String, query: [String: String] = [:]) async throws -> [String: Any] {
        var components = URLComponents(string: "\(apiGateway)\(path)")
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        var req = URLRequest(url: url)
        req.setValue("5.2.0", forHTTPHeaderField: "x-version")
        req.setValue("xj2", forHTTPHeaderField: "x-channel")
        req.setValue(cookieAuth, forHTTPHeaderField: "x-cookie-auth")
        req.setValue("gzip", forHTTPHeaderField: "accept-encoding")

        let (data, response) = try await session.data(for: req)
        guard let httpResp = response as? HTTPURLResponse,
              (200...299).contains(httpResp.statusCode) else {
            throw URLError(.badServerResponse)
        }

        // 处理 gzip 解压（URLSession 默认自动解压，但显式检查）
        var body = data
        if let contentEncoding = (httpResp.allHeaderFields["Content-Encoding"] as? String)?.lowercased(),
           contentEncoding == "gzip" {
            // URLSession 已自动解压，无需手动处理
        }

        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return json
    }

    /// 解析标准 ybox 响应：{"retcode": 0, "data": {...}}
    private func parseData(from json: [String: Any]) -> [String: Any]? {
        guard let retcode = json["retcode"] as? Int, retcode == 0,
              let data = json["data"] as? [String: Any] else {
            return nil
        }
        return data
    }

    /// 解析 data 中的数组字段
    private func parseDataArray(from json: [String: Any], key: String? = nil) -> [[String: Any]]? {
        guard let data = json["data"] as? [String: Any] else { return nil }
        if let k = key {
            return data[k] as? [[String: Any]]
        }
        // 尝试常见键名
        return (data["rows"] as? [[String: Any]]) ??
               (data["vodrows"] as? [[String: Any]]) ??
               (data["list"] as? [[String: Any]])
    }

    // MARK: - 分类构建

    init() { buildCategories() }

    private func buildCategories() {
        let bananaURL = baseURL(for: "banana", defaultURL: apiGateway)
        let liveURL = baseURL(for: "live_hclyz", defaultURL: "http://api.hclyz.com:81/mf")
        let comic18URL = baseURL(for: "comic18", defaultURL: "https://www.18akmanhua.com")
        let kmURL = baseURL(for: "km", defaultURL: "https://1080.hlkjsm.com")
        let byfmURL = baseURL(for: "byfm", defaultURL: "https://api.byfm2.app")

        let yboxVideo: [YBoxPlatform2] = [
            YBoxPlatform2(name: "香蕉秀", icon: "leaf.fill", type: .video,
                         baseURL: bananaURL, desc: "短视频/长视频"),
            YBoxPlatform2(name: "幻想次元", icon: "sparkles", type: .video,
                         baseURL: bananaURL, desc: "二次元角色扮演"),
            YBoxPlatform2(name: "午夜寻欢", icon: "moon.stars.fill", type: .video,
                         baseURL: bananaURL, desc: "夜间精彩"),
            YBoxPlatform2(name: "绿帽淫妻", icon: "heart.slash.fill", type: .video,
                         baseURL: bananaURL, desc: "专题视频"),
            YBoxPlatform2(name: "1080视频", icon: "play.rectangle.fill", type: .video,
                         baseURL: kmURL, desc: "综合视频站", crawlerPlatformId: "km"),
            YBoxPlatform2(name: "BYFM有声", icon: "headphones", type: .audio,
                         baseURL: byfmURL, desc: "有声小说50类"),
        ]

        let yboxLive: [YBoxPlatform2] = [
            YBoxPlatform2(name: "卫视直播", icon: "tv.fill", type: .live, baseURL: liveURL, desc: "CCTV/卫视/广播"),
            YBoxPlatform2(name: "蜜桃直播", icon: "flame.fill", type: .live, baseURL: liveURL, desc: "娱乐直播"),
            YBoxPlatform2(name: "卡哇伊", icon: "suit.heart.fill", type: .live, baseURL: liveURL, desc: "才艺互动"),
            YBoxPlatform2(name: "番茄社区", icon: "person.2.fill", type: .live, baseURL: liveURL, desc: "社区直播"),
        ]

        let yboxComic: [YBoxPlatform2] = [
            YBoxPlatform2(name: "18禁漫画", icon: "book.fill", type: .comic, baseURL: comic18URL, desc: "日漫/韩漫/同人"),
            YBoxPlatform2(name: "ComicBox", icon: "books.vertical.fill", type: .comic, baseURL: "https://www.comicbox.xyz", desc: "综合漫画站"),
        ]

        // 从 WelfareCrawlerConfig 导入所有爬虫平台
        let allCrawlerConfigs = WelfareCrawlerConfig.all
        let yboxReservedIds: Set<String> = ["banana", "huanxiang", "km", "live_hclyz", "comic18"]

        var crawlerVideo: [YBoxPlatform2] = []
        var crawlerLive: [YBoxPlatform2] = []
        var crawlerComic: [YBoxPlatform2] = []

        for cfg in allCrawlerConfigs {
            guard !yboxReservedIds.contains(cfg.platformId) else { continue }
            let platform = YBoxPlatform2(
                name: cfg.platformName, icon: iconForPlatform(cfg.platformId),
                type: platformTypeForContentType(cfg.contentType),
                baseURL: cfg.effectiveBaseURL, desc: descForPlatform(cfg.platformId),
                crawlerPlatformId: cfg.platformId
            )
            switch cfg.contentType {
            case .comic: crawlerComic.append(platform)
            case .live: crawlerLive.append(platform)
            case .video, .mixed, .audio: crawlerVideo.append(platform)
            }
        }

        categories = [
            YBoxCategory2(name: "视频", platforms: yboxVideo + crawlerVideo),
            YBoxCategory2(name: "直播", platforms: yboxLive + crawlerLive),
            YBoxCategory2(name: "漫画", platforms: yboxComic + crawlerComic),
        ]
    }

    private func platformTypeForContentType(_ ct: WelfareContentType) -> YBoxPlatform2.PlatformType2 {
        switch ct {
        case .video, .mixed, .audio: return .video
        case .live: return .live
        case .comic: return .comic
        }
    }

    // MARK: - 平台图标/描述

    private func iconForPlatform(_ id: String) -> String {
        let icons: [String: String] = [
            "91av": "play.circle.fill", "hgsp": "play.rectangle.fill", "hsxs": "sparkles.tv.fill",
            "hxsp": "film.fill", "ll51": "play.square.stack.fill", "lld": "play.tv.fill",
            "mtyx": "tv.music.note.fill", "one": "1.circle.fill", "pfdsp": "photo.tv",
            "txvlog": "camera.fill", "wmq": "play.display", "xbk": "rectangle.stack.fill",
            "zlt": "square.grid.3x3.fill", "lls": "square.on.square", "hhlz": "globe",
            "mimei": "heart.circle.fill", "avin": "person.fill.viewfinder", "javdb": "film.stack.fill",
            "djr": "star.bubble.fill", "lxs": "person.2.fill", "44hhqq": "play.circle.fill",
            "missav": "play.slash.fill", "mmav": "moon.circle.fill", "oksp": "eye.fill",
            "pron91": "rectangle.3.group.fill", "tv91": "tv.fill", "mdtv": "tv.and.mediabox",
            "pdl": "list.bullet.rectangle.fill", "qp": "tag.fill", "zpc91": "square.grid.2x2.fill",
            "dsp91": "sparkle.magnifyingglass", "sp91": "magnifyingglass.circle.fill",
            "ttav": "play.circle", "xjsp": "theatermasks.fill", "fl2": "flame.fill",
            "byfm": "headphones.circle.fill", "yxfm": "music.note.list",
            "hu4": "photo.on.rectangle.fill", "awjd": "newspaper.fill", "cgw": "doc.text.fill",
            "cg51": "person.3.fill", "ttt": "bubble.left.and.bubble.right.fill",
            "sgp": "camera.aperture", "dm51": "arrow.down.to.line", "awjm": "icloud.and.arrow.down.fill",
            "qysq": "eye.slash.fill", "kpsp": "tv.badge.wifi",
            "dh50": "50.square.fill", "hjsq": "antenna.radiowaves.left.and.right",
            "yfg": "gift.fill", "gdcm": "lightbulb.fill",
            "wwsq": "globe.asia.australia.fill", "rryy": "r.square.fill", "xvideos": "x.square.fill",
            "gsjh": "building.columns.fill", "hhl": "h.square.fill",
            "hjll": "j.square.fill", "hsck": "shippingbox.fill",
            "jmbox": "tray.full.fill", "mmmh": "books.vertical.fill",
            "akmh": "book.pages.fill", "jmtt": "books.vertical.fill",
            "nc": "book.closed.fill", "mw": "text.book.closed.fill", "wwmh": "character.book.closed.fill",
        ]
        return icons[id] ?? "app.fill"
    }

    private func descForPlatform(_ id: String) -> String {
        let descs: [String: String] = [
            "91av": "视频聚合", "hgsp": "视频聚合", "hsxs": "多类型综合",
            "hxsp": "视频聚合", "ll51": "短视频/暗网", "lld": "视频聚合",
            "mtyx": "话题/短视频", "one": "电影/发现", "pfdsp": "视频聚合",
            "txvlog": "短视频", "wmq": "标签/用户", "xbk": "短视频",
            "zlt": "演员/视频", "lls": "电影/动漫/漫画/小说", "hhlz": "电影/漫画/小说",
            "mimei": "动漫/漫画/小说", "avin": "演员信息", "javdb": "演员/分类",
            "djr": "演员/标签", "lxs": "演员信息", "44hhqq": "视频聚合",
            "missav": "演员/分类", "mmav": "话题/视频", "oksp": "电影/演员",
            "pron91": "分类/排行", "tv91": "频道/标签", "mdtv": "频道/标签",
            "pdl": "频道/排行", "qp": "频道/标签", "zpc91": "分类",
            "dsp91": "发现/用户", "sp91": "电影/演员", "ttav": "发现/暗网",
            "xjsp": "分类/演员", "fl2": "演员/发现", "byfm": "演员/音频",
            "yxfm": "演员/音频", "hu4": "图片/小说/剧照", "awjd": "文章/视频",
            "cgw": "文章/视频", "cg51": "社区/话题", "ttt": "短视频/用户",
            "sgp": "演员/文章", "dm51": "动漫/暗网", "awjm": "暗网",
            "qysq": "暗网", "kpsp": "暗网", "dh50": "分类/用户",
            "hjsq": "短视频/用户", "yfg": "用户", "gdcm": "视频聚合",
            "wwsq": "视频聚合", "rryy": "知名平台", "xvideos": "知名平台",
            "gsjh": "黄色仓库", "hhl": "视频聚合", "hjll": "视频聚合",
            "hsck": "黄色仓库", "jmbox": "综合站",
            "akmh": "爱看漫画", "jmtt": "漫画天堂", "nc": "漫画阅读",
            "mw": "漫画/小说", "wwmh": "漫画阅读", "mmmh": "漫画阅读",
        ]
        return descs[id] ?? "资源平台"
    }

    private func baseURL(for platformId: String, defaultURL: String) -> String {
        WelfareCrawlerConfig.config(for: platformId)?.effectiveBaseURL ?? defaultURL
    }

    private var liveBaseURL: String {
        baseURL(for: "live_hclyz", defaultURL: "http://api.hclyz.com:81/mf")
    }
    private var comic18BaseURL: String {
        baseURL(for: "comic18", defaultURL: "https://www.18akmanhua.com")
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - 香蕉秀 API（zfvwi8.ipajx0.cc，by QClaw 2026-07-07）
    //
    // 基于 ybox App 抓包还原的真实 API：
    //   GET /vod/listing-0-0-0-0-0-0-0-0-0-1           → 拉取在线分类（12类）
    //   GET /vod/listing-{cateid}-0-0-0-0-0-0-0-0-{page}  → 分类视频列表（16条/页）
    //   GET /special/listing-0-0-{page}                     → 专题列表（16条/页）
    //   GET /special/vodlist-{spid}-0-0-{page}              → 专题内视频
    //   GET /minivod/reqlist?page={page}                    → 短视频列表（10条/页）
    //   GET /vod/reqplay/{vodid}                             → 获取长视频播放 m3u8 地址
    //   GET /minivod/reqplay/{vodid}                        → 获取短视频播放 m3u8 地址
    //
    // 请求头：x-version:5.2.0, x-channel:xj2, x-cookie-auth:<hex>
    // 响应格式：{"retcode":0,"errmsg":"...","data":{...}}, gzip 压缩
    // ═══════════════════════════════════════════════════════════

    /// 获取首页分类导航（从 /vod/listing-0 拉取在线分类；/index 不再含 v2cats）
    func fetchBananaCategories() async -> [YBoxBananaCategory] {
        do {
            // 从 listing API 拉取线上分类列表（12类）
            let listingJson = try await fetchJSON(path: "/vod/listing-0-0-0-0-0-0-0-0-0-1")
            if let listingData = listingJson["data"] as? [String: Any],
               let cats = listingData["categories"] as? [[String: Any]], !cats.isEmpty {
                return cats.compactMap { cat in
                    guard let cateId = cat["cateid"] as? String,
                          let name = cat["catename"] as? String else { return nil }
                    return YBoxBananaCategory(cateId: cateId, name: name, type: "vod", subCates: [])
                }
            }
            return defaultCategories
        } catch {
            print("[YBox] fetchBananaCategories error: \(error)")
            return defaultCategories
        }
    }

    /// 默认分类（兜底，与 zfvwi8 线上数据对应）
    private var defaultCategories: [YBoxBananaCategory] {
        [
            YBoxBananaCategory(cateId: "0", name: "推荐", type: "vod", subCates: []),
            YBoxBananaCategory(cateId: "9", name: "国产精品", type: "vod", subCates: []),
            YBoxBananaCategory(cateId: "7", name: "辣妹大奶", type: "vod", subCates: []),
            YBoxBananaCategory(cateId: "8", name: "日本无码", type: "vod", subCates: []),
            YBoxBananaCategory(cateId: "6", name: "情欲女同", type: "vod", subCates: []),
            YBoxBananaCategory(cateId: "3", name: "日韩专区", type: "vod", subCates: []),
            YBoxBananaCategory(cateId: "16", name: "香蕉原创", type: "vod", subCates: []),
            YBoxBananaCategory(cateId: "17", name: "中文字幕", type: "vod", subCates: []),
            YBoxBananaCategory(cateId: "10", name: "动漫专区", type: "vod", subCates: []),
        ]
    }

    /// 获取分类视频列表（GET /vod/listing-{cateId}-0-0-0-0-0-0-0-0-{page}）
    /// 8 个筛选参数：areaid, yearid, definition, duration, freetype, mosaic, langvoice, orderby
    func fetchBananaVideos(cateId: String, page: Int = 1,
                           filters: BananaVideoFilter = BananaVideoFilter()) async -> [YBoxBananaVideo] {
        let path = "/vod/listing-\(cateId)-\(filters.area)-\(filters.year)-\(filters.definition)-\(filters.duration)-\(filters.freetype)-\(filters.mosaic)-\(filters.langvoice)-\(filters.orderby)-\(page)"
        do {
            let json = try await fetchJSON(path: path)
            guard let data = json["data"] as? [String: Any],
                  let vodrows = data["vodrows"] as? [[String: Any]] else { return [] }
            return vodrows.map { parseVideo($0) }
        } catch {
            print("[YBox] fetchBananaVideos(\(cateId), page:\(page)) error: \(error)")
            return []
        }
    }

    /// 获取专题列表（GET /special/listing-0-0-{page}）
    func fetchBananaSpecials(page: Int = 1) async -> [YBoxBananaSpecial] {
        let path = "/special/listing-0-0-\(page)"
        do {
            let json = try await fetchJSON(path: path)
            guard let data = json["data"] as? [String: Any],
                  let rows = data["rows"] as? [[String: Any]] else { return [] }
            return rows.compactMap { sp in
                guard let spId = (sp["spid"] as? String) ?? (sp["id"] as? String),
                      let spName = sp["spname"] as? String ?? sp["title"] as? String else {
                    return nil
                }
                return YBoxBananaSpecial(
                    spId: spId,
                    spName: spName,
                    spCover: sp["spcover"] as? String ?? sp["coverpic"] as? String ?? "",
                    itemCount: sp["itemcount"] as? Int ?? sp["vod_count"] as? Int ?? 0
                )
            }
        } catch {
            print("[YBox] fetchBananaSpecials error: \(error)")
            return []
        }
    }

    /// 获取专题/演员内视频列表
    /// 注意：zfvwi8 网关无按 spId 筛视频的端点，暂时使用全局视频列表
    func fetchBananaSpecialVideos(spId: String, page: Int = 1) async -> [YBoxBananaSpecialVideo] {
        // zfvwi8 不支持按 spId 筛选，降级为全量视频列表
        let path = "/vod/listing-0-0-0-0-0-0-0-0-0-\(page)"
        do {
            let json = try await fetchJSON(path: path)
            guard let data = json["data"] as? [String: Any],
                  let vodrows = data["vodrows"] as? [[String: Any]] else { return [] }
            return vodrows.map { row in
                YBoxBananaSpecialVideo(
                    vodId: (row["vodid"] as? String) ?? String(row["vodid"] as? Int ?? 0),
                    title: row["title"] as? String ?? "",
                    cover: row["coverpic"] as? String ?? "",
                    duration: row["duration"] as? String ?? "00:00",
                    score: row["scorenum"] as? String
                )
            }
        } catch {
            print("[YBox] fetchBananaSpecialVideos(\(spId)) error: \(error)")
            return []
        }
    }

    /// 获取短视频列表（GET /minivod/reqlist?page={page}）
    func fetchBananaMiniVideos(page: Int = 1) async -> [YBoxBananaMiniVideo] {
        let path = "/minivod/reqlist"
        do {
            let json = try await fetchJSON(path: path, query: ["page": "\(page)"])
            guard let data = json["data"] as? [String: Any],
                  let rows = data["rows"] as? [[String: Any]] else { return [] }
            return rows.map { row in
                let vod = row["vodrow"] as? [String: Any] ?? row
                // 字段名是 "user" 不是 "userinfo"
                let user = row["user"] as? [String: Any] ?? [:]
                // play_url 是相对路径，需补全
                let rawPlayUrl: String? = (vod["play_url"] as? String) ?? (vod["vodPlayUrl"] as? String)
                let playUrl: String? = rawPlayUrl.map { $0.hasPrefix("/") ? "\(apiGateway)\($0)" : $0 }
                return YBoxBananaMiniVideo(
                    vodId: (vod["vodid"] as? String) ?? String(vod["vodid"] as? Int ?? 0),
                    title: vod["title"] as? String ?? vod["vodname"] as? String ?? "",
                    cover: vod["coverpic"] as? String ?? vod["vodpic"] as? String ?? "",
                    videoUrl: playUrl,
                    duration: vod["duration"] as? String ?? "00:00",
                    userName: user["nickname"] as? String ?? user["name"] as? String ?? "",
                    userAvatar: user["avatar"] as? String ?? user["headimg"] as? String ?? ""
                )
            }
        } catch {
            print("[YBox] fetchBananaMiniVideos error: \(error)")
            return []
        }
    }

    /// 获取播放地址。长视频用 /vod/reqplay，短视频用 /minivod/reqplay
    /// 返回 m3u8 播放链接
    func fetchBananaPlayURL(vodId: String, isLongVideo: Bool = true) async -> String? {
        let path = isLongVideo ? "/vod/reqplay/\(vodId)" : "/minivod/reqplay/\(vodId)"
        do {
            let json = try await fetchJSON(path: path)
            // 先检查 retcode
            guard let retcode = json["retcode"] as? Int, retcode == 0 else {
                let msg = json["errmsg"] as? String ?? "未知错误"
                print("[YBox] fetchBananaPlayURL(\(vodId)) retcode!=0, errmsg: \(msg)")
                return nil
            }
            guard let data = json["data"] as? [String: Any] else { return nil }

            // 优先取 httpurl 字段
            if let url = data["httpurl"] as? String, !url.isEmpty { return url }

            // 备选：从 httpurls 数组取第一个
            if let urls = data["httpurls"] as? [[String: Any]], let first = urls.first,
               let url = first["httpurl"] as? String {
                return url
            }

            return nil
        } catch {
            print("[YBox] fetchBananaPlayURL(\(vodId)) error: \(error)")
            return nil
        }
    }

    // MARK: - 视频解析工具

    private func parseVideo(_ row: [String: Any]) -> YBoxBananaVideo {
        YBoxBananaVideo(
            vodId: (row["vodid"] as? String) ?? String(row["vodid"] as? Int ?? 0),
            title: row["title"] as? String ?? "",
            cover: row["coverpic"] as? String ?? "",
            duration: row["duration"] as? String ?? "00:00",
            score: row["scorenum"] as? String,
            mosaic: row["mosaic"] as? String ?? "0",
            cateId: row["cateid"] as? String ?? "0",
            cateName: row["catename"] as? String,
            areaName: row["areaname"] as? String,
            year: row["year"] as? String ?? "",
            tags: (row["tags"] as? [String]) ?? [],
            playCount: row["playcount_total"] as? Int ?? (row["playcount"] as? Int ?? 0),
            commentCount: row["commentcount"] as? Int ?? 0
        )
    }

    // MARK: - 直播

    func loadLiveSources() async {
        guard !isLiveLoaded else { return }
        do {
            guard let url = URL(string: "\(liveBaseURL)/json.txt") else { return }
            let (data, _) = try await session.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pt = json["pingtai"] as? [[String: Any]] else { return }
            var sources: [YBoxLiveItem2] = []
            for item in pt {
                let addr = item["address"] as? String ?? ""
                let channels = await fetchLiveChannels(address: addr)
                sources.append(YBoxLiveItem2(
                    title: item["title"] as? String ?? "",
                    img: item["xinimg"] as? String ?? "",
                    number: item["Number"] as? String ?? "0",
                    channels: channels
                ))
            }
            await MainActor.run { self.liveSources = sources; self.isLiveLoaded = true }
        } catch { print("[YBox] 直播加载失败: \(error)") }
    }

    func fetchLiveChannels(address: String) async -> [YBoxLiveChannel2] {
        guard let url = URL(string: "\(liveBaseURL)/" + address) else { return [] }
        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            if let zhubo = json["zhubo"] as? [[String: Any]] {
                return zhubo.map { YBoxLiveChannel2(title: $0["title"] as? String ?? "",
                                                      address: $0["address"] as? String ?? "",
                                                      img: $0["img"] as? String ?? "") }
            }
            var chs: [YBoxLiveChannel2] = []
            for (k, v) in json {
                if let s = v as? String, s.hasPrefix("http") {
                    chs.append(YBoxLiveChannel2(title: k, address: s, img: ""))
                }
            }
            return chs
        } catch { return [] }
    }

    // MARK: - 漫画

    func fetch18Comics() async -> [YBoxComicItem2] {
        guard let url = URL(string: comic18BaseURL) else { return [] }
        do {
            let (data, _) = try await session.data(from: url)
            guard let html = String(data: data, encoding: .utf8) else { return [] }
            var items: [YBoxComicItem2] = []
            let pattern = ##"<a[^>]*href="([^"]*)"[^>]*>.*?<img[^>]*src="([^"]*)"[^>]*alt="([^"]*)"##
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                let nsRange = NSRange(html.startIndex..., in: html)
                let matches = regex.matches(in: html, range: nsRange)
                for m in matches.prefix(50) {
                    let href = Range(m.range(at: 1), in: html).map { String(html[$0]) } ?? ""
                    let src = Range(m.range(at: 2), in: html).map { String(html[$0]) } ?? ""
                    let alt = Range(m.range(at: 3), in: html).map { String(html[$0]) } ?? ""
                    if !alt.isEmpty {
                        let cover = src.hasPrefix("http") ? src : "https://www.18akmanhua.com" + src
                        items.append(YBoxComicItem2(title: alt, cover: cover, href: href))
                    }
                }
            }
            return items
        } catch { return [] }
    }
}

// MARK: - 视频筛选参数

struct BananaVideoFilter {
    var area: String = "0"        // 地区筛选（cateid 编码）
    var year: String = "0"        // 年份筛选
    var definition: String = "0"  // 清晰度
    var duration: String = "0"    // 时长
    var freetype: String = "0"    // 免费/付费
    var mosaic: String = "0"      // 有码/无码（1=有码 2=无码）
    var langvoice: String = "0"   // 语言/配音
    var orderby: String = "0"     // 排序（0=默认 1=最新 2=最热）

    /// 预设：香蕉原创 (cateid=16)
    static let bananaOriginal = BananaVideoFilter()

    /// 预设：无码专区
    static let uncensored = BananaVideoFilter(mosaic: "2")

    /// 预设：中文字幕
    static let chineseSub = BananaVideoFilter(langvoice: "1")
}
