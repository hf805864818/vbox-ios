import Foundation

// MARK: - 平台内容类型（首页分类用）
enum WelfareContentType: String, Codable {
    case video, live, comic, audio, mixed
}

// MARK: - 爬虫解析器类型
enum WelfareParserType: String, Codable, CaseIterable {
    case apiJson        // API JSON 接口（苹果CMS / 海洋CMS 等标准 CMS）
    case pwaApi         // PWA 加密 API（client=pwa + data/timestamp）
    case encPost        // 加密 POST JSON API（post-data / encrypt_data）
    case htmlRegex      // HTML 正则提取
    case spiderFallback // 纯 SpiderManager 关键词搜索回退
    case disabled       // 暂未配置
}

// MARK: - 页面类型枚举（自适应显示用）
enum WelfarePageKind: String, Codable, CaseIterable {
    case home, video, film, anime, comic, novel, actor, search
    case classify, find, topic, tiktok, darkWeb, audio, article
    case community, rank, channel, tag, user, image, stills

    var displayName: String { [
        .home: "首页", .video: "视频", .film: "电影", .anime: "动漫",
        .comic: "漫画", .novel: "小说", .actor: "演员", .search: "搜索",
        .classify: "分类", .find: "发现", .topic: "话题", .tiktok: "短视频",
        .darkWeb: "暗网", .audio: "音频", .article: "文章", .community: "社区",
        .rank: "排行", .channel: "频道", .tag: "标签",
        .user: "用户", .image: "图片", .stills: "剧照"
    ][self] ?? "未知" }

    var icon: String { [
        .home: "house.fill", .video: "play.rectangle.fill",
        .film: "film.fill", .anime: "sparkles.tv.fill",
        .comic: "book.pages.fill", .novel: "text.book.closed.fill",
        .actor: "person.2.fill", .search: "magnifyingglass",
        .classify: "square.grid.2x2.fill", .find: "sparkle.magnifyingglass",
        .topic: "bubble.left.and.bubble.right.fill",
        .tiktok: "play.square.stack.fill", .darkWeb: "eye.slash.fill",
        .audio: "headphones", .article: "doc.text.fill",
        .community: "person.3.fill", .rank: "list.number",
        .channel: "tv.fill", .tag: "tag.fill",
        .user: "person.crop.circle.fill", .image: "photo.on.rectangle.fill",
        .stills: "photo.stack.fill"
    ][self] ?? "app.fill" }
}

// MARK: - HTML 模板类型
enum HTMLTemplateType: String, Codable {
    case stui       // 苹果CMS stui模板 (hsck123, gsjh 等)
    case wurenren   // 我为人人影院 (hlkjsm, km)
    case manwats    // 漫画站模板 (manwats.cc, mw)
    case generic    // 通用正则提取
}

// MARK: - API 模式
enum APIMode: String, Codable {
    case open       // 开放API，无需加密（标准CMS GET接口）
    case encrypted  // 加密API，需要 POST + 加密data字段
}

// MARK: - 平台爬虫配置
struct WelfareCrawlerConfig: Codable, Identifiable {
    var id: String { platformId }
    let platformId: String
    let platformName: String
    let searchPrefix: String
    let baseURL: String
    let parserType: WelfareParserType
    let apiMode: APIMode
    let contentType: WelfareContentType
    let htmlTemplate: HTMLTemplateType?
    let pages: [WelfarePageKind]
    let pageSections: [String: [String]]

    // MARK: - 自定义域名覆盖（UserDefaults 持久化）
    /// UserDefaults 存储 key 前缀
    private static let customURLPrefix = "welfare_custom_url_"

    /// 用户自定义的 baseURL（优先使用），为空则用默认 baseURL
    var customBaseURL: String? {
        get {
            let key = Self.customURLPrefix + platformId
            let url = UserDefaults.standard.string(forKey: key)
            return url?.isEmpty == false ? url : nil
        }
        set {
            let key = Self.customURLPrefix + platformId
            if let url = newValue, !url.isEmpty {
                UserDefaults.standard.set(url, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// 生效的 baseURL：优先用户自定义，没有则用默认
    var effectiveBaseURL: String {
        customBaseURL ?? baseURL
    }

    /// 是否已设置自定义域名
    var hasCustomURL: Bool {
        customBaseURL != nil
    }

    // MARK: - 全局自定义域名管理
    /// 获取所有已设置自定义域名的平台 ID
    static var allCustomPlatformIds: [String] {
        let dict = UserDefaults.standard.dictionaryRepresentation()
        return dict.keys.compactMap { key in
            guard key.hasPrefix(customURLPrefix) else { return nil }
            let platformId = String(key.dropFirst(customURLPrefix.count))
            return platformId.isEmpty ? nil : platformId
        }
    }

    /// 清除所有自定义域名
    static func clearAllCustomURLs() {
        for pid in allCustomPlatformIds {
            UserDefaults.standard.removeObject(forKey: customURLPrefix + pid)
        }
    }
}

// MARK: - 全部平台爬虫配置（基于抓包数据精确映射，覆盖视频/直播/漫画/音频等）
extension WelfareCrawlerConfig {
    static let all: [WelfareCrawlerConfig] = [
        // ═══════════════════════════════════════════════════════════
        // MARK: 自建平台（YBox自有API，非爬虫）- 4个
        // ═══════════════════════════════════════════════════════════
        .make("banana", "香蕉秀", "香蕉", "https://zfvwi8.ipajx0.cc",
              .apiJson, .video,
              [.home, .video, .tiktok, .search],
              ["home": ["推荐", "最新", "热门"], "video": ["专题", "短视频"], "tiktok": ["热门短视频"]],
              apiMode: .open),

        .make("huanxiang", "幻想次元", "幻想", "https://zfvwi8.ipajx0.cc",
              .apiJson, .video,
              [.home, .video],
              ["home": ["推荐", "最新"]],
              apiMode: .open),

        .make("live_hclyz", "综合直播", "直播", "http://api.hclyz.com:81/mf",
              .apiJson, .live,
              [.home, .channel],
              ["home": ["卫视直播", "蜜桃直播", "卡哇伊", "番茄社区"], "channel": ["全部频道"]],
              apiMode: .open),

        .make("comic18", "18禁漫画", "漫画", "https://www.18akmanhua.com",
              .htmlRegex, .comic,
              [.home, .comic, .search],
              ["home": ["推荐漫画", "最新更新"], "comic": ["日漫", "韩漫", "同人"]],
              apiMode: .open,
              htmlTemplate: .generic),

        // ═══════════════════════════════════════════════════════════
        // MARK: 视频聚合类 (15个) - 有加密API的平台，优先走YBox代理
        // ═══════════════════════════════════════════════════════════
        .make("91av", "91av", "91av", "https://api1.i91avapi2.com",
              .pwaApi, .video,
              [.home, .video, .actor, .search],
              ["home": ["推荐", "最新"], "video": ["全部视频"], "actor": ["热门演员"]]),

        .make("hgsp", "hgsp", "hgsp", "https://api.nzp1ve.com",
              .encPost, .video,
              [.home, .video, .actor, .search],
              ["home": ["推荐", "最新"], "video": ["全部视频"]]),

        .make("hsxs", "hsxs", "hsxs", "https://api.b7f3192.com",
              .pwaApi, .video,
              [.home, .video, .anime, .comic, .actor, .darkWeb, .search],
              ["home": ["推荐", "最新"], "video": ["视频", "动漫", "漫画"], "actor": ["演员列表"]]),

        .make("hxsp", "hxsp", "hxsp", "https://api2.kpsvvkl.cc",
              .apiJson, .video,
              [.home, .video, .classify, .tiktok, .search],
              ["home": ["推荐", "最新"], "video": ["全部视频"], "classify": ["分类浏览"]]),

        .make("ll51", "51ll", "51ll", "https://api1.i91avapi2.com",
              .pwaApi, .video,
              [.home, .video, .tiktok, .darkWeb, .search],
              ["home": ["推荐", "最新"], "video": ["全部视频"], "tiktok": ["短视频"]]),

        .make("lld", "lld", "lld", "https://kmsvip.xyz",
              .apiJson, .video,
              [.home, .video, .search],
              ["home": ["推荐", "最新"], "video": ["全部视频"]]),

        .make("mtyx", "mtyx", "mtyx", "https://api2.uhqechyr.com",
              .apiJson, .video,
              [.home, .video, .tiktok, .topic, .search],
              ["home": ["推荐", "最新", "热门"], "video": ["全部视频"], "tiktok": ["短视频"]]),

        .make("one", "one", "one", "https://sapi01.gg-gv.com",
              .apiJson, .video,
              [.home, .film, .find, .search],
              ["home": ["推荐", "最新"], "film": ["电影", "剧集"]]),

        .make("pfdsp", "pfdsp", "pfdsp", "https://api3.caanrrim.cc",
              .pwaApi, .video,
              [.home, .video, .find, .search],
              ["home": ["推荐", "最新"], "video": ["全部视频"]]),

        .make("txvlog", "txvlog", "txvlog", "https://bpi4.xbtcunxd.info",
              .apiJson, .video,
              [.home, .video, .tiktok, .search],
              ["home": ["推荐", "最新"], "video": ["全部视频"], "tiktok": ["短视频"]]),

        .make("wmq", "wmq", "wmq", "https://api2.piifvly.com",
              .apiJson, .video,
              [.home, .video, .tiktok, .tag, .user, .search],
              ["home": ["推荐", "最新"], "video": ["全部视频"], "tag": ["热门标签"]]),

        .make("xbk", "xbk", "xbk", "https://api1.gdapi1.com",
              .apiJson, .video,
              [.home, .video, .tiktok, .search],
              ["home": ["推荐", "最新"], "video": ["全部视频"], "tiktok": ["短视频"]]),

        .make("zlt", "zlt", "zlt", "https://wapi1.haijbpi1.com",
              .apiJson, .video,
              [.home, .video, .actor, .search],
              ["home": ["推荐", "最新"], "video": ["全部视频"], "actor": ["热门演员"]]),

        // ═══════════════════════════════════════════════════════════
        // MARK: 多类型综合 (3个)
        // ═══════════════════════════════════════════════════════════
        .make("lls", "lls", "lls", "https://jszyapi.com",
              .apiJson, .mixed,
              [.home, .film, .anime, .comic, .novel, .search],
              ["home": ["推荐", "最新", "热门"], "film": ["电影", "电视剧"], "anime": ["动漫"], "comic": ["漫画"]],
              apiMode: .open),

        .make("hhlz", "hhlz", "hhlz", "https://api.byfm2.app",
              .apiJson, .mixed,
              [.film, .comic, .novel, .search],
              ["film": ["电影", "剧集"], "comic": ["漫画"], "novel": ["小说"]]),

        .make("mimei", "mimei", "mimei", "https://public.mime15.fun",
              .pwaApi, .mixed,
              [.anime, .comic, .novel, .classify, .search],
              ["anime": ["动漫"], "comic": ["漫画"], "novel": ["小说"]]),

        // ═══════════════════════════════════════════════════════════
        // MARK: 漫画阅读 (5个)
        // ═══════════════════════════════════════════════════════════
        .make("akmh", "akmh", "akmh", "https://www.18akmanhua.com",
              .apiJson, .comic,
              [.anime, .comic, .search],
              ["anime": ["动漫"], "comic": ["日漫", "韩漫", "同人", "3D"]]),

        .make("jmtt", "jmtt", "jmtt", "https://www.comicbox.xyz",
              .htmlRegex, .comic,
              [.home, .comic, .rank, .search],
              ["home": ["推荐漫画", "最新更新"], "comic": ["日漫", "韩漫", "同人"], "rank": ["排行榜"]],
              htmlTemplate: .generic),

        .make("nc", "nc", "nc", "https://rrs0a03ak.pye57rf.com",
              .apiJson, .comic,
              [.comic, .search],
              ["comic": ["全部漫画"]]),

        .make("mw", "mw", "mw", "https://manwats.cc",
              .htmlRegex, .comic,
              [.comic, .novel, .search],
              ["comic": ["漫画"], "novel": ["小说"]],
              htmlTemplate: .manwats),

        .make("wwmh", "wwmh", "wwmh", "https://kx75.fun",
              .apiJson, .comic,
              [.comic, .search],
              ["comic": ["全部漫画"]]),

        // ═══════════════════════════════════════════════════════════
        // MARK: 演员/AV信息 (7个)
        // ═══════════════════════════════════════════════════════════
        .make("avin", "insav", "insav", "https://api.3e7ea36.com",
              .apiJson, .video,
              [.video, .find, .actor, .search],
              ["video": ["全部视频"], "actor": ["演员信息"], "find": ["发现"]]),

        .make("javdb", "javdb", "javdb", "https://tokyohot-api-7oovsx.uxuzr.com",
              .apiJson, .video,
              [.video, .actor, .classify, .search],
              ["video": ["全部电影"], "actor": ["女优列表"], "classify": ["有码", "无码", "欧美"]]),

        .make("djr", "djr", "djr", "https://jdforrepam.com",
              .apiJson, .video,
              [.video, .actor, .tag, .search],
              ["video": ["全部视频"], "actor": ["演员"], "tag": ["标签"]]),

        .make("lxs", "lxs", "lxs", "https://api.em1oifd0.com",
              .apiJson, .video,
              [.video, .actor, .search],
              ["video": ["全部视频"], "actor": ["演员信息"]]),

        .make("44hhqq", "44hhqq", "44hhqq", "https://www.99ggdd.com",
              .htmlRegex, .video,
              [.video, .actor, .classify, .search],
              ["video": ["全部视频"], "actor": ["女优"], "classify": ["有码", "无码", "欧美", "中文"]],
              htmlTemplate: .generic),

        .make("missav", "missav", "missav", "https://missav.ws",
              .htmlRegex, .video,
              [.video, .actor, .classify, .search],
              ["video": ["全部视频"], "actor": ["女优"], "classify": ["有码", "无码", "欧美", "中文"]],
              htmlTemplate: .generic),

        .make("mmav", "mmav", "mmav", "https://sm-api.wieuc.com",
              .apiJson, .video,
              [.video, .topic, .search],
              ["video": ["全部视频"], "topic": ["话题"]]),

        .make("oksp", "oksp", "oksp", "https://api55.gwqqbp.com",
              .encPost, .video,
              [.video, .film, .actor, .search],
              ["video": ["全部视频"], "film": ["电影"], "actor": ["演员"]]),

        // ═══════════════════════════════════════════════════════════
        // MARK: 分类/频道类 (6个)
        // ═══════════════════════════════════════════════════════════
        .make("pron91", "91pron", "91pron", "https://api1.i91avapi2.com",
              .pwaApi, .video,
              [.classify, .rank, .search],
              ["classify": ["热门推荐", "最新发布", "国产精选", "日韩专区", "欧美精品"], "rank": ["排行榜"]]),

        .make("tv91", "91tv", "91tv", "https://api2.uhqechyr.com",
              .apiJson, .video,
              [.home, .channel, .tag, .search],
              ["home": ["推荐", "最新"], "channel": ["频道列表"], "tag": ["标签"]]),

        .make("mdtv", "mdtv", "mdtv", "https://api2.kpsvvkl.cc",
              .apiJson, .video,
              [.home, .channel, .tag, .search],
              ["home": ["推荐", "最新"], "channel": ["频道列表"], "tag": ["标签"]]),

        .make("pdl", "pdl", "pdl", "https://api3.boygzqzff.cc",
              .pwaApi, .video,
              [.home, .channel, .rank, .search],
              ["home": ["推荐"], "channel": ["频道列表"], "rank": ["排行榜"]]),

        .make("qp", "qp", "qp", "https://api.hichatapi.info",
              .apiJson, .video,
              [.channel, .tag, .search],
              ["channel": ["频道"], "tag": ["标签"]]),

        .make("zpc91", "91zpc", "91zpc", "https://api1.i91avapi2.com",
              .pwaApi, .video,
              [.home, .classify, .search],
              ["home": ["推荐"], "classify": ["分类浏览"]]),

        // ═══════════════════════════════════════════════════════════
        // MARK: 内容发现 (7个)
        // ═══════════════════════════════════════════════════════════
        .make("dsp91", "91dsp", "91dsp", "https://api1.i91avapi2.com",
              .pwaApi, .video,
              [.home, .video, .tiktok, .user, .search],
              ["home": ["推荐", "最新"], "video": ["全部视频"], "tiktok": ["短视频"]]),

        .make("sp91", "91sp", "91sp", "https://api1.i91avapi2.com",
              .pwaApi, .video,
              [.film, .tiktok, .actor, .search],
              ["film": ["电影"], "tiktok": ["短视频"], "actor": ["演员"]]),

        .make("ttav", "ttav", "ttav", "https://api3.caanrrim.cc",
              .pwaApi, .video,
              [.home, .film, .find, .tiktok, .user, .darkWeb, .search],
              ["home": ["推荐"], "film": ["电影"], "find": ["发现"], "tiktok": ["短视频"]]),

        .make("xjsp", "xjsp", "xjsp", "https://api1.zwcdjpuxs.cc",
              .apiJson, .video,
              [.video, .classify, .tiktok, .actor, .search],
              ["video": ["全部视频"], "classify": ["分类"], "tiktok": ["短视频"], "actor": ["演员"]]),

        .make("fl2", "fl2", "fl2", "https://yjwx257.com",
              .encPost, .video,
              [.video, .actor, .find, .search],
              ["video": ["全部视频"], "actor": ["演员"], "find": ["发现"]]),

        .make("byfm", "byfm", "byfm", "https://api.byfm2.app",
              .apiJson, .audio,
              [.video, .actor, .classify, .audio, .search],
              ["video": ["视频"], "actor": ["演员"], "classify": ["分类"], "audio": ["有声小说"]]),

        .make("yxfm", "yxfm", "yxfm", "https://api.byfm2.app",
              .apiJson, .audio,
              [.video, .actor, .audio, .search],
              ["video": ["视频"], "actor": ["演员"], "audio": ["有声小说"]]),

        // ═══════════════════════════════════════════════════════════
        // MARK: 图片/文章/社区 (6个)
        // ═══════════════════════════════════════════════════════════
        .make("hu4", "4hu", "4hu", "https://api.em1oifd0.com",
              .apiJson, .video,
              [.video, .image, .novel, .stills, .search],
              ["video": ["视频"], "image": ["图片"], "novel": ["小说"], "stills": ["剧照"]]),

        .make("awjd", "awjd", "awjd", "https://a7waex8.live",
              .apiJson, .video,
              [.home, .video, .article, .search],
              ["home": ["推荐"], "video": ["视频"], "article": ["文章"]]),

        .make("cgw", "cgw", "cgw", "https://a7waex8.live",
              .apiJson, .video,
              [.article, .video, .search],
              ["article": ["文章"], "video": ["视频"]]),

        .make("cg51", "51cg", "51cg", "https://api1.i91avapi2.com",
              .pwaApi, .video,
              [.home, .video, .community, .topic, .user, .search],
              ["home": ["推荐"], "video": ["视频"], "community": ["社区"], "topic": ["话题"]]),

        .make("ttt", "ttt", "ttt", "https://api3.caanrrim.cc",
              .pwaApi, .video,
              [.home, .video, .tiktok, .tag, .user, .search],
              ["home": ["推荐"], "video": ["视频"], "tiktok": ["短视频"], "tag": ["标签"]]),

        .make("sgp", "sgp", "sgp", "https://a7waex8.live",
              .apiJson, .video,
              [.video, .actor, .article, .search],
              ["video": ["视频"], "actor": ["演员"], "article": ["文章"]]),

        // ═══════════════════════════════════════════════════════════
        // MARK: 影视下载/暗网类 (4个)
        // ═══════════════════════════════════════════════════════════
        .make("dm51", "51dm", "51dm", "https://api1.i91avapi2.com",
              .pwaApi, .video,
              [.anime, .film, .darkWeb, .search],
              ["anime": ["动漫"], "film": ["电影"], "darkWeb": ["暗网"]]),

        .make("awjm", "awjm", "awjm", "https://a7waex8.live",
              .apiJson, .video,
              [.video, .actor, .darkWeb, .search],
              ["video": ["视频"], "actor": ["演员"], "darkWeb": ["暗网"]]),

        .make("qysq", "qysq", "qysq", "https://api.hichatapi.info",
              .apiJson, .video,
              [.home, .video, .darkWeb, .search],
              ["home": ["推荐"], "video": ["视频"], "darkWeb": ["暗网"]]),

        .make("kpsp", "kptv", "kptv", "https://api2.kpsvvkl.cc",
              .apiJson, .video,
              [.home, .darkWeb, .search],
              ["home": ["推荐"], "darkWeb": ["暗网"]]),

        // ═══════════════════════════════════════════════════════════
        // MARK: 其他特色 (6个)
        // ═══════════════════════════════════════════════════════════
        .make("dh50", "50dh", "50dh", "https://ujvxsl.uizipgcq.com",
              .pwaApi, .video,
              [.home, .classify, .user, .search],
              ["home": ["推荐"], "classify": ["分类"]]),

        .make("hjsq", "hjsq", "hjsq", "https://alipa.mamnvbyiu5od.com",
              .encPost, .video,
              [.home, .video, .tiktok, .user, .search],
              ["home": ["推荐"], "video": ["视频"], "tiktok": ["短视频"]]),

        .make("yfg", "yfg", "yfg", "https://api-al.ass6.store",
              .apiJson, .video,
              [.video, .user, .search],
              ["video": ["视频"]]),

        .make("km", "km", "km", "https://1080.hlkjsm.com",
              .htmlRegex, .video,
              [.video, .user, .search],
              ["video": ["全部视频"]],
              htmlTemplate: .wurenren),

        .make("gdcm", "gdcm", "gdcm", "https://tth.txh069.com",
              .htmlRegex, .video,
              [.home, .video, .search],
              ["home": ["推荐"], "video": ["视频"]],
              htmlTemplate: .generic),

        .make("wwsq", "wwsq", "wwsq", "https://we.killcovid2020.com",
              .htmlRegex, .video,
              [.video, .search],
              ["video": ["视频"]],
              htmlTemplate: .generic),

        // ═══════════════════════════════════════════════════════════
        // MARK: 知名平台 (2个)
        // ═══════════════════════════════════════════════════════════
        .make("rryy", "rryy", "rryy", "https://jszyapi.com",
              .apiJson, .video,
              [.search],
              ["search": ["搜索"]],
              apiMode: .open),

        .make("xvideos", "xvideos", "xvideos", "https://api.hichatapi.info",
              .apiJson, .video,
              [.video, .classify, .search],
              ["video": ["视频"], "classify": ["分类"]]),

        // ═══════════════════════════════════════════════════════════
        // MARK: YBox独有 (7个)
        // ═══════════════════════════════════════════════════════════
        .make("gsjh", "gsjh", "gsjh", "https://hsck123.com",
              .htmlRegex, .video,
              [.video, .search],
              ["video": ["全部视频"]],
              htmlTemplate: .stui),

        .make("hhl", "hhl", "hhl", "https://api-al.ass6.store",
              .apiJson, .video,
              [.video, .search],
              ["video": ["视频"]]),

        .make("hjll", "hjll", "hjll", "https://api-al.ass6.store",
              .apiJson, .video,
              [.video, .search],
              ["video": ["视频"]]),

        .make("hsck", "hsck", "hsck", "https://hsck123.com",
              .htmlRegex, .video,
              [.video, .search],
              ["video": ["全部视频"]],
              htmlTemplate: .stui),

        .make("jmbox", "jmbox", "jmbox", "https://www.comicbox.xyz",
              .htmlRegex, .video,
              [.video, .search],
              ["video": ["视频"]]),

        .make("mmmh", "mmmh", "mmmh", "https://sdhvb.meme06.live",
              .apiJson, .comic,
              [.comic, .search],
              ["comic": ["全部漫画"]]),
    ]

    /// 根据platformId查找配置
    static func config(for id: String) -> WelfareCrawlerConfig? {
        all.first { $0.platformId == id }
    }

    /// 根据内容类型获取平台
    static func configs(for contentType: WelfareContentType) -> [WelfareCrawlerConfig] {
        all.filter { $0.contentType == contentType }
    }

    private static func make(_ id: String, _ name: String, _ prefix: String,
                              _ url: String, _ parser: WelfareParserType,
                              _ contentType: WelfareContentType,
                              _ pages: [WelfarePageKind],
                              _ sections: [String: [String]] = [:],
                              apiMode: APIMode = .encrypted,
                              htmlTemplate: HTMLTemplateType? = nil) -> WelfareCrawlerConfig {
        WelfareCrawlerConfig(platformId: id, platformName: name, searchPrefix: prefix,
                             baseURL: url, parserType: parser, apiMode: apiMode,
                             contentType: contentType,
                             htmlTemplate: htmlTemplate,
                             pages: pages, pageSections: sections)
    }
}
