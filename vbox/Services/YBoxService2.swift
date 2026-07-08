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
    let previewURL: String?  // 预览 m3u8，VIP 视频可由此重建完整播放地址
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

/// 专题/演员条目（来自 /special/listing-0-0-{page}，统一模型）
/// zfvwi8 网关返回的 rows 和 actorrows 共用此结构
/// sptype: "1"=专题(频道), "2"=演员(人物)
struct YBoxBananaSpecial: Identifiable {
    var id: String { spId }
    let spId: String
    let sptype: String     // "1"=专题, "2"=演员
    let spName: String
    let spCover: String
    let avatar: String?
    let intro: String
    let cup: String        // 罩杯/权重
    let age: String        // 年龄/权重
    let upnum: Int
    let itemCount: Int
}

/// 专题/演员内视频（来自 /special/detail/{spid}-{page} → data.vodrows）
struct YBoxBananaSpecialVideo: Identifiable {
    var id: String { vodId }
    let vodId: String
    let title: String
    let cover: String
    let duration: String
    let score: String?
    let upnum: Int
    let downnum: Int
    let playCount: Int
    let tags: [String]
    let previewURL: String?  // 预览 m3u8，VIP 视频可由此重建完整播放地址
    var playPath: String { "/vod/reqplay/\(vodId)" }
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

    /// 直接获取原始二进制数据（无 JSON 解析，用于 m3u8 等非 JSON 资源）
    private func fetchRaw(url urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, response) = try await session.data(for: req)
        guard let httpResp = response as? HTTPURLResponse,
              (200...299).contains(httpResp.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
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
        let bananaURL = apiGateway

        let yboxVideo: [YBoxPlatform2] = [
            YBoxPlatform2(name: "MissAV", icon: "star.fill", type: .video,
                         baseURL: "https://missav.ws", desc: "高清无码"),
            YBoxPlatform2(name: "香蕉秀", icon: "leaf.fill", type: .video,
                         baseURL: bananaURL, desc: "短视频/长视频"),
            YBoxPlatform2(name: "幻想次元", icon: "sparkles", type: .video,
                         baseURL: bananaURL, desc: "二次元角色扮演"),
            YBoxPlatform2(name: "午夜寻欢", icon: "moon.stars.fill", type: .video,
                         baseURL: bananaURL, desc: "夜间精彩"),
            YBoxPlatform2(name: "绿帽淫妻", icon: "heart.slash.fill", type: .video,
                         baseURL: bananaURL, desc: "专题视频"),
            YBoxPlatform2(name: "1080视频", icon: "play.rectangle.fill", type: .video,
                         baseURL: "https://1080.hlkjsm.com", desc: "综合视频站"),
        ]

        categories = [
            YBoxCategory2(name: "视频", platforms: yboxVideo),
            YBoxCategory2(name: "直播", platforms: []),
            YBoxCategory2(name: "漫画", platforms: []),
        ]
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - 香蕉秀 API（zfvwi8.ipajx0.cc，by QClaw 2026-07-07）
    //
    // 基于 ybox App 抓包还原的真实 API：
    //   GET /vod/listing-0-0-0-0-0-0-0-0-0-1           → 拉取在线分类（12类）
    //   GET /vod/listing-{cateid}-0-0-0-0-0-0-0-0-{page}  → 分类视频列表（16条/页）
    //   GET /special/listing-0-0-{page}                     → 专题列表（rows 16条/页 + actorrows 全量导航）
    //   GET /special/detail/{spid}-{page}                   → 专题/演员内视频列表（vodrows）
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

    /// 获取专题/演员导航列表
    /// GET /special/listing-0-0-{page}
    /// 返回 rows（分页列表）和 actorrows（全量导航栏数据）
    func fetchBananaSpecials(page: Int = 1) async -> (rows: [YBoxBananaSpecial], actorrows: [YBoxBananaSpecial], totalPage: Int, total: Int) {
        let path = "/special/listing-0-0-\(page)"
        do {
            let json = try await fetchJSON(path: path)
            guard let data = json["data"] as? [String: Any] else { return ([], [], 0, 0) }
            let rows = (data["rows"] as? [[String: Any]] ?? []).compactMap { parseSpecial($0) }
            let actorrows = (data["actorrows"] as? [[String: Any]] ?? []).compactMap { parseSpecial($0) }
            let pageInfo = data["pageinfo"] as? [String: Any]
            let total = pageInfo?["total"] as? Int ?? 0
            let totalPage = pageInfo?["totalpage"] as? Int ?? 0
            return (rows, actorrows, totalPage, total)
        } catch {
            print("[YBox] fetchBananaSpecials error: \(error)")
            return ([], [], 0, 0)
        }
    }

    /// 解析单条专题/演员条目
    private func parseSpecial(_ sp: [String: Any]) -> YBoxBananaSpecial? {
        guard let spId = (sp["spid"] as? String) ?? (sp["id"] as? String),
              let spName = sp["spname"] as? String ?? sp["title"] as? String else {
            return nil
        }
        return YBoxBananaSpecial(
            spId: spId,
            sptype: sp["sptype"] as? String ?? "1",
            spName: spName,
            spCover: sp["coverpic"] as? String ?? sp["spcover"] as? String ?? "",
            avatar: sp["avatar"] as? String,
            intro: sp["intro"] as? String ?? "",
            cup: sp["cup"] as? String ?? "0",
            age: sp["age"] as? String ?? "0",
            upnum: (sp["upnum"] as? NSString)?.integerValue ?? sp["upnum"] as? Int ?? 0,
            itemCount: (sp["itemcount"] as? NSString)?.integerValue ?? sp["itemcount"] as? Int ?? 0
        )
    }

    /// 获取专题/演员内视频列表
    /// GET /special/detail/{spId}-{page}  → data.vodrows（完整视频列表）
    func fetchBananaSpecialVideos(spId: String, page: Int = 1) async -> [YBoxBananaSpecialVideo] {
        let path = "/special/detail/\(spId)-\(page)"
        do {
            let json = try await fetchJSON(path: path)
            guard let retcode = json["retcode"] as? Int, retcode == 0,
                  let data = json["data"] as? [String: Any],
                  let vodrows = data["vodrows"] as? [[String: Any]] else {
                let msg = json["errmsg"] as? String ?? "未知错误"
                print("[YBox] fetchBananaSpecialVideos(\(spId), p\(page)) retcode!=0: \(msg)")
                return []
            }
            return vodrows.map { row in
                let tags = (row["tags"] as? [[String: Any]] ?? []).compactMap {
                    $0["tagname"] as? String
                }
                return YBoxBananaSpecialVideo(
                    vodId: (row["vodid"] as? String) ?? String(row["vodid"] as? Int ?? 0),
                    title: row["title"] as? String ?? "",
                    cover: row["coverpic"] as? String ?? "",
                    duration: row["duration"] as? String ?? "00:00",
                    score: row["scorenum"] as? String,
                    upnum: (row["upnum"] as? NSString)?.integerValue ?? row["upnum"] as? Int ?? 0,
                    downnum: (row["downnum"] as? NSString)?.integerValue ?? row["downnum"] as? Int ?? 0,
                    playCount: row["playcount_total"] as? Int ?? 0,
                    tags: tags,
                    previewURL: row["preview_url"] as? String
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
    /// 获取播放地址，返回 (url, retcode, errmsg)
    /// - Parameter previewURL: 视频预览 m3u8 地址（VIP 视频回退用）
    func fetchBananaPlayURL(vodId: String, isLongVideo: Bool = true, previewURL: String? = nil) async -> (url: String?, retcode: Int, errmsg: String) {
        let path = isLongVideo ? "/vod/reqplay/\(vodId)" : "/minivod/reqplay/\(vodId)"
        do {
            let json = try await fetchJSON(path: path)
            let retcode = json["retcode"] as? Int ?? -1
            let msg = json["errmsg"] as? String ?? "未知错误"
            
            guard retcode == 0 else {
                // VIP 视频 (retcode==5)：尝试从 previewURL 重建完整 m3u8
                if retcode == 5, let pvUrl = previewURL, let rebuilt = await rebuildFullM3U8(from: pvUrl) {
                    print("[YBox] fetchBananaPlayURL(\(vodId)) VIP fallback → \(rebuilt.prefix(80))...")
                    return (rebuilt, 0, "VIP 跳过成功")
                }
                print("[YBox] fetchBananaPlayURL(\(vodId)) retcode=\(retcode), errmsg: \(msg)")
                return (nil, retcode, msg)
            }
            guard let data = json["data"] as? [String: Any] else { return (nil, retcode, msg) }

            // 优先取 httpurl 字段（自动 HTTP→HTTPS 升级以兼容 iOS ATS）
            if let url = data["httpurl"] as? String, !url.isEmpty {
                return (sanitizePlayURL(url), 0, msg)
            }

            // 备选：从 httpurls 数组取第一个
            if let urls = data["httpurls"] as? [[String: Any]], let first = urls.first,
               let url = first["httpurl"] as? String {
                return (sanitizePlayURL(url), 0, msg)
            }

            return (nil, -1, "无可用播放地址")
        } catch {
            print("[YBox] fetchBananaPlayURL(\(vodId)) error: \(error)")
            return (nil, -2, error.localizedDescription)
        }
    }

    /// 将 HTTP URL 升级为 HTTPS（兼容 iOS ATS）
    private func sanitizePlayURL(_ raw: String) -> String {
        guard raw.hasPrefix("http://") else { return raw }
        let https = raw.replacingOccurrences(of: "http://", with: "https://")
        print("[YBox] sanitizePlayURL: \(raw.prefix(60))... → \(https.prefix(60))...")
        return https
    }

    /// 从预览 m3u8 重建完整 m3u8 地址（VIP 视频绕过限制）
    /// 算法：获取预览 m3u8 → 提取 KEY_CDN host + TS 路径 → 拼接 https://{KEY_CDN}/{TS_PATH}/index.m3u8
    private func rebuildFullM3U8(from previewURL: String) async -> String? {
        guard let previewData = try? await fetchRaw(url: previewURL),
              let previewText = String(data: previewData, encoding: .utf8) else {
            print("[YBox] rebuildFullM3U8: failed to fetch preview m3u8")
            return nil
        }

        // 提取 KEY URI
        let keyPattern = try? NSRegularExpression(pattern: ##"URI="([^"]+)""##)
        let keyRange = NSRange(previewText.startIndex..., in: previewText)
        var keyURI: String?
        if let match = keyPattern?.firstMatch(in: previewText, range: keyRange),
           let range = Range(match.range(at: 1), in: previewText) {
            keyURI = String(previewText[range])
        }

        // 提取第一个 TS 段 URL
        let tsPattern = try? NSRegularExpression(pattern: #"^https://[^\s]+\.ts"#, options: .anchorsMatchLines)
        var tsURL: String?
        if let match = tsPattern?.firstMatch(in: previewText, range: keyRange),
           let range = Range(match.range, in: previewText) {
            tsURL = String(previewText[range])
        }

        guard let key = keyURI, let ts = tsURL else {
            print("[YBox] rebuildFullM3U8: failed to parse key/ts from preview")
            return nil
        }

        // 提取 KEY CDN host
        let keyHost: String
        if key.hasPrefix("https://") {
            keyHost = URL(string: key)?.host ?? ""
        } else {
            // 相对路径，使用与 preview URL 相同的 host
            keyHost = URL(string: previewURL)?.host ?? ""
        }

        // 提取 TS 目录路径（去掉 host 和文件名）
        guard let tsUrlObj = URL(string: ts) else { return nil }
        let tsDir = tsUrlObj.deletingLastPathComponent().path

        let fullURL = "https://\(keyHost)\(tsDir)/index.m3u8"
        print("[YBox] rebuildFullM3U8: \(fullURL)")
        return fullURL
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
            commentCount: row["commentcount"] as? Int ?? 0,
            previewURL: row["preview_url"] as? String
        )
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
