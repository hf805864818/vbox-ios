import Foundation

// MARK: - 数据模型（保留原名避免冲突）
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
    /// 对应 WelfareCrawlerConfig 中的 platformId，nil 表示使用 YBox 自有 API
    let crawlerPlatformId: String?

    init(name: String, icon: String, type: PlatformType2,
         baseURL: String, desc: String, crawlerPlatformId: String? = nil) {
        self.name = name; self.icon = icon; self.type = type
        self.baseURL = baseURL; self.desc = desc
        self.crawlerPlatformId = crawlerPlatformId
    }

    enum PlatformType2: String {
        case video, live, comic, audio
    }
}

struct YBoxVideoItem2: Identifiable {
    var id: String { vodId }
    let vodId: String
    let title: String
    let cover: String
    let duration: String?
    let score: String?
    let playUrl: String?
    let category: String?
}

struct YBoxLiveItem2: Identifiable {
    var id: String { title }
    let title: String
    let img: String
    let number: String
    let channels: [YBoxLiveChannel2]
}

struct YBoxLiveChannel2: Identifiable {
    var id: String { title }
    let title: String
    let address: String
    let img: String
}

struct YBoxComicItem2: Identifiable {
    var id: String { title }
    let title: String
    let cover: String
    let href: String?
}

// MARK: - YBox 服务 (2)
class YBoxService2: ObservableObject {
    static let shared = YBoxService2()

    @Published var categories: [YBoxCategory2] = []
    @Published var liveSources: [YBoxLiveItem2] = []
    @Published var isLiveLoaded = false

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    init() { buildCategories() }

    private func buildCategories() {
        // ═══ YBox 原始平台（保留自有API，不通过爬虫） ═══
        let yboxVideo: [YBoxPlatform2] = [
            YBoxPlatform2(name: "香蕉秀", icon: "leaf.fill", type: .video,
                         baseURL: "https://zfvwi8.ipajx0.cc", desc: "短视频/长视频"),
            YBoxPlatform2(name: "幻想次元", icon: "sparkles", type: .video,
                         baseURL: "https://zfvwi8.ipajx0.cc", desc: "二次元角色扮演"),
            YBoxPlatform2(name: "午夜寻欢", icon: "moon.stars.fill", type: .video,
                         baseURL: "https://zfvwi8.ipajx0.cc", desc: "夜间精彩"),
            YBoxPlatform2(name: "绿帽淫妻", icon: "heart.slash.fill", type: .video,
                         baseURL: "https://zfvwi8.ipajx0.cc", desc: "专题视频"),
            YBoxPlatform2(name: "1080视频", icon: "play.rectangle.fill", type: .video,
                         baseURL: "https://1080.hlkjsm.com", desc: "综合视频站",
                         crawlerPlatformId: "km"),
            YBoxPlatform2(name: "BYFM有声", icon: "headphones", type: .audio,
                         baseURL: "https://api.byfm2.app", desc: "有声小说50类"),
        ]

        let yboxLive: [YBoxPlatform2] = [
            YBoxPlatform2(name: "卫视直播", icon: "tv.fill", type: .live,
                         baseURL: "http://api.hclyz.com:81/mf", desc: "CCTV/卫视/广播"),
            YBoxPlatform2(name: "蜜桃直播", icon: "flame.fill", type: .live,
                         baseURL: "http://api.hclyz.com:81/mf", desc: "娱乐直播"),
            YBoxPlatform2(name: "卡哇伊", icon: "suit.heart.fill", type: .live,
                         baseURL: "http://api.hclyz.com:81/mf", desc: "才艺互动"),
            YBoxPlatform2(name: "番茄社区", icon: "person.2.fill", type: .live,
                         baseURL: "http://api.hclyz.com:81/mf", desc: "社区直播"),
        ]

        let yboxComic: [YBoxPlatform2] = [
            YBoxPlatform2(name: "18禁漫画", icon: "book.fill", type: .comic,
                         baseURL: "https://www.18akmanhua.com", desc: "日漫/韩漫/同人"),
            YBoxPlatform2(name: "ComicBox", icon: "books.vertical.fill", type: .comic,
                         baseURL: "https://www.comicbox.xyz", desc: "综合漫画站"),
        ]

        // ═══ 从 WelfareCrawlerConfig 导入所有平台，按 contentType 分类 ═══
        let allCrawlerConfigs = WelfareCrawlerConfig.all

        // 已存在于 YBox 原始列表中的 platformId
        let yboxReservedIds: Set<String> = ["banana", "huanxiang", "km", "live_hclyz", "comic18"]

        var crawlerVideo: [YBoxPlatform2] = []
        var crawlerLive: [YBoxPlatform2] = []
        var crawlerComic: [YBoxPlatform2] = []

        for cfg in allCrawlerConfigs {
            guard !yboxReservedIds.contains(cfg.platformId) else { continue }

            let icon = iconForPlatform(cfg.platformId)
            let desc = descForPlatform(cfg.platformId)

            let platform = YBoxPlatform2(
                name: cfg.platformName,
                icon: icon,
                type: platformTypeForContentType(cfg.contentType),
                baseURL: cfg.baseURL,
                desc: desc,
                crawlerPlatformId: cfg.platformId
            )

            switch cfg.contentType {
            case .comic: crawlerComic.append(platform)
            case .live:  crawlerLive.append(platform)
            case .video, .mixed, .audio: crawlerVideo.append(platform)
            }
        }

        // ═══ 组装最终分类（移除数量限制，全部展示） ═══
        let allVideo = yboxVideo + crawlerVideo
        let allLive = yboxLive + crawlerLive
        let allComic = yboxComic + crawlerComic

        categories = [
            YBoxCategory2(name: "视频", platforms: allVideo),
            YBoxCategory2(name: "直播", platforms: allLive),
            YBoxCategory2(name: "漫画", platforms: allComic),
        ]
    }

    private func platformTypeForContentType(_ ct: WelfareContentType) -> YBoxPlatform2.PlatformType2 {
        switch ct {
        case .video, .mixed, .audio: return .video
        case .live: return .live
        case .comic: return .comic
        }
    }

    // MARK: - 平台图标
    private func iconForPlatform(_ id: String) -> String {
        let icons: [String: String] = [
            "91av": "play.circle.fill", "hgsp": "play.rectangle.fill", "hsxs": "sparkles.tv.fill",
            "hxsp": "film.fill", "ll51": "play.square.stack.fill", "lld": "play.tv.fill",
            "mtyx": "tv.music.note.fill", "one": "1.circle.fill", "pfdsp": "photo.tv",
            "txvlog": "camera.fill", "wmq": "play.display", "xbk": "rectangle.stack.fill",
            "zlt": "square.grid.3x3.fill", "lls": "square.on.square", "hhlz": "globe",
            "mimei": "heart.circle.fill", "avin": "person.fill.viewfinder", "javdb": "film.stack.fill",
            "djr": "star.bubble.fill", "lxs": "person.2.fill", "missav": "play.slash.fill",
            "mmav": "moon.circle.fill", "oksp": "eye.fill", "pron91": "rectangle.3.group.fill",
            "tv91": "tv.fill", "mdtv": "tv.and.mediabox", "pdl": "list.bullet.rectangle.fill",
            "qp": "tag.fill", "zpc91": "square.grid.2x2.fill",
            "dsp91": "sparkle.magnifyingglass", "sp91": "magnifyingglass.circle.fill",
            "ttav": "play.circle", "xjsp": "theatermasks.fill",
            "fl2": "flame.fill", "byfm": "headphones.circle.fill", "yxfm": "music.note.list",
            "hu4": "photo.on.rectangle.fill", "awjd": "newspaper.fill", "cgw": "doc.text.fill",
            "cg51": "person.3.fill", "ttt": "bubble.left.and.bubble.right.fill",
            "sgp": "camera.aperture",
            "dm51": "arrow.down.to.line", "awjm": "icloud.and.arrow.down.fill",
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

    // MARK: - 平台描述
    private func descForPlatform(_ id: String) -> String {
        let descs: [String: String] = [
            "91av": "视频聚合", "hgsp": "视频聚合", "hsxs": "多类型综合",
            "hxsp": "视频聚合", "ll51": "短视频/暗网", "lld": "视频聚合",
            "mtyx": "话题/短视频", "one": "电影/发现", "pfdsp": "视频聚合",
            "txvlog": "短视频", "wmq": "标签/用户", "xbk": "短视频",
            "zlt": "演员/视频", "lls": "电影/动漫/漫画/小说", "hhlz": "电影/漫画/小说",
            "mimei": "动漫/漫画/小说", "avin": "演员信息", "javdb": "演员/分类",
            "djr": "演员/标签", "lxs": "演员信息", "missav": "演员/分类",
            "mmav": "话题/视频", "oksp": "电影/演员",
            "pron91": "分类/排行", "tv91": "频道/标签", "mdtv": "频道/标签",
            "pdl": "频道/排行", "qp": "频道/标签", "zpc91": "分类",
            "dsp91": "发现/用户", "sp91": "电影/演员", "ttav": "发现/暗网",
            "xjsp": "分类/演员", "fl2": "演员/发现", "byfm": "演员/音频",
            "yxfm": "演员/音频",
            "hu4": "图片/小说/剧照", "awjd": "文章/视频", "cgw": "文章/视频",
            "cg51": "社区/话题", "ttt": "短视频/用户", "sgp": "演员/文章",
            "dm51": "动漫/暗网", "awjm": "暗网", "qysq": "暗网",
            "kpsp": "暗网", "dh50": "分类/用户", "hjsq": "短视频/用户",
            "yfg": "用户", "gdcm": "视频聚合",
            "wwsq": "视频聚合", "rryy": "知名平台", "xvideos": "知名平台",
            "gsjh": "黄色仓库", "hhl": "视频聚合", "hjll": "视频聚合",
            "hsck": "黄色仓库", "jmbox": "综合站",
            "akmh": "爱看漫画", "jmtt": "漫画天堂", "nc": "漫画阅读",
            "mw": "漫画/小说", "wwmh": "漫画阅读", "mmmh": "漫画阅读",
        ]
        return descs[id] ?? "资源平台"
    }

    // MARK: - 香蕉秀
    func fetchBananaSpecials() async -> [YBoxVideoItem2] {
        guard let url = URL(string: "https://zfvwi8.ipajx0.cc/special/listing-0-0-1") else { return [] }
        return await fetchBananaData(url: url, isSpecial: true)
    }

    func fetchBananaMiniVods(page: Int = 1) async -> [YBoxVideoItem2] {
        guard let url = URL(string: "https://zfvwi8.ipajx0.cc/minivod/reqlist?page=\(page)") else { return [] }
        return await fetchBananaData(url: url, isSpecial: false)
    }

    func fetchBananaPlayURL(playPath: String) async -> String? {
        guard let url = URL(string: "https://zfvwi8.ipajx0.cc" + playPath) else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = json["data"] as? [String: Any],
               let u = d["httpurl"] as? String { return u }
        } catch { print("[YBox] 播放地址失败: \(error)") }
        return nil
    }

    private func fetchBananaData(url: URL, isSpecial: Bool) async -> [YBoxVideoItem2] {
        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any] else { return [] }
            var items: [YBoxVideoItem2] = []

            if isSpecial {
                let rows = dataObj["rows"] as? [[String: Any]] ?? []
                for row in rows {
                    for vod in (row["vodrows"] as? [[String: Any]] ?? []) {
                        items.append(YBoxVideoItem2(
                            vodId: String(vod["vodid"] as? Int ?? 0),
                            title: vod["title"] as? String ?? "",
                            cover: vod["coverpic"] as? String ?? "",
                            duration: vod["duration"] as? String,
                            score: vod["scorenum"] as? String,
                            playUrl: vod["play_url"] as? String,
                            category: row["spname"] as? String
                        ))
                    }
                }
            } else {
                for row in (dataObj["rows"] as? [[String: Any]] ?? []) {
                    let vod = row["vodrow"] as? [String: Any] ?? row
                    items.append(YBoxVideoItem2(
                        vodId: String(vod["vodid"] as? Int ?? 0),
                        title: vod["title"] as? String ?? "",
                        cover: vod["coverpic"] as? String ?? "",
                        duration: vod["duration"] as? String,
                        score: vod["scorenum"] as? String,
                        playUrl: vod["play_url"] as? String,
                        category: nil
                    ))
                }
            }
            return items
        } catch { return [] }
    }

    // MARK: - 直播
    func loadLiveSources() async {
        guard !isLiveLoaded else { return }
        do {
            guard let url = URL(string: "http://api.hclyz.com:81/mf/json.txt") else { return }
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
        guard let url = URL(string: "http://api.hclyz.com:81/mf/" + address) else { return [] }
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

    // MARK: - 18禁漫画
    func fetch18Comics() async -> [YBoxComicItem2] {
        guard let url = URL(string: "https://www.18akmanhua.com") else { return [] }
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
