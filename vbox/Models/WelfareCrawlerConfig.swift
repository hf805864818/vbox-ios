import Foundation

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
    let baseURL: String        // 平台API基础URL，为空则纯搜索回退
    let parserType: WelfareParserType
    let apiMode: APIMode       // API 模式（open=无需加密GET, encrypted=需要加密POST）
    let htmlTemplate: HTMLTemplateType? // HTML模板类型 (仅 parserType==.htmlRegex 时有效)
    let pages: [WelfarePageKind] // 支持的页面类型
    let pageSections: [String: [String]] // 页面下的分区定义 (pageKind -> [sectionNames])
}

// MARK: - 全部 62 个平台爬虫配置（基于 ybox 抓包数据映射）
extension WelfareCrawlerConfig {
    static let all: [WelfareCrawlerConfig] = [
        // ═══ 香蕉秀/小视频（自建明文API） ═══
        .make("banana",  "香蕉秀",  "香蕉",   "https://zfvwi8.ipajx0.cc",    .apiJson, [.home,.video,.tiktok,.search], apiMode: .open),
        .make("huanxiang", "幻想次元", "幻想", "https://zfvwi8.ipajx0.cc",   .apiJson, [.home,.video], apiMode: .open),

        // ═══ 直播源（hclyz 136个源） ═══
        .make("live_hclyz", "综合直播", "直播", "http://api.hclyz.com:81/mf", .apiJson, [.home,.channel], apiMode: .open),

        // ═══ 18禁漫画 ═══
        .make("comic18",  "18禁漫画", "漫画",  "https://www.18akmanhua.com", .htmlRegex, [.home,.comic,.search], apiMode: .open, htmlTemplate: .generic),

        // ═══ 原62个平台配置 ═══
        // ═══ 视频聚合类 (15个) ═══
        .make("91av",   "91av",   "91av",   "https://api1.i91avapi2.com",         .pwaApi,     [.home,.video,.actor,.search]),
        .make("hgsp",   "hgsp",   "hgsp",   "https://api.nzp1ve.com",             .encPost,    [.home,.video,.actor,.search]),
        .make("hsxs",   "hsxs",   "hsxs",   "https://api.b7f3192.com",            .pwaApi,     [.home,.video,.anime,.comic,.actor,.darkWeb,.search]),
        .make("hxsp",   "hxsp",   "hxsp",   "https://api2.kpsvvkl.cc",            .apiJson,    [.home,.video,.classify,.tiktok,.search]),
        .make("ll51",   "51ll",   "51ll",   "https://api1.i91avapi2.com",         .pwaApi,     [.home,.video,.tiktok,.darkWeb,.search]),
        .make("lld",    "lld",    "lld",    "https://kmsvip.xyz",                 .apiJson,    [.home,.video,.search]),
        .make("mtyx",   "mtyx",   "mtyx",   "https://api2.uhqechyr.com",          .apiJson,    [.home,.video,.tiktok,.topic,.search]),
        .make("one",    "one",    "one",    "https://sapi01.gg-gv.com",           .apiJson,    [.home,.film,.find,.search]),
        .make("pfdsp",  "pfdsp",  "pfdsp",  "https://api3.caanrrim.cc",           .pwaApi,     [.home,.video,.find,.search]),
        .make("txvlog", "txvlog", "txvlog", "https://bpi4.xbtcunxd.info",         .apiJson,    [.home,.video,.tiktok,.search]),
        .make("wmq",    "wmq",    "wmq",    "https://api2.piifvly.com",           .apiJson,    [.home,.video,.tiktok,.tag,.user,.search]),
        .make("xbk",    "xbk",    "xbk",    "https://api1.gdapi1.com",            .apiJson,    [.home,.video,.tiktok,.search]),
        .make("zlt",    "zlt",    "zlt",    "https://wapi1.haijbpi1.com",         .apiJson,    [.home,.video,.actor,.search]),

        // ═══ 多类型综合 (3个) ═══
        .make("lls",    "lls",    "lls",    "https://jszyapi.com",                .apiJson,    [.home,.film,.anime,.comic,.novel,.search], apiMode: .open),
        .make("hhlz",   "hhlz",   "hhlz",   "https://api.byfm2.app",              .apiJson,    [.film,.comic,.novel,.search]),
        .make("mimei",  "mimei",  "mimei",  "https://public.mime15.fun",          .pwaApi,     [.anime,.comic,.novel,.classify,.search]),

        // ═══ 漫画阅读 (5个) ═══
        .make("akmh",   "akmh",   "akmh",   "https://www.18akmanhua.com",        .apiJson,    [.anime,.comic,.search]),
        .make("jmtt",   "jmtt",   "jmtt",   "https://www.comicbox.xyz",           .htmlRegex,  [.home,.comic,.rank,.search], htmlTemplate: .generic),
        .make("nc",     "nc",     "nc",     "https://rrs0a03ak.pye57rf.com",      .apiJson,    [.comic,.search]),
        .make("mw",     "mw",     "mw",     "https://manwats.cc",                 .htmlRegex,  [.comic,.novel,.search], htmlTemplate: .manwats),
        .make("wwmh",   "wwmh",   "wwmh",   "https://kx75.fun",                   .apiJson,    [.comic,.search]),

        // ═══ 演员/AV信息 (7个) ═══
        .make("avin",   "insav",  "insav",  "https://api.3e7ea36.com",            .apiJson,    [.video,.find,.actor,.search]),
        .make("javdb",  "javdb",  "javdb",  "https://tokyohot-api-7oovsx.uxuzr.com",.apiJson,[.video,.actor,.classify,.search]),
        .make("djr",    "djr",    "djr",    "https://jdforrepam.com",             .apiJson,    [.video,.actor,.tag,.search]),
        .make("lxs",    "lxs",    "lxs",    "https://api.em1oifd0.com",           .apiJson,    [.video,.actor,.search]),
        .make("missav", "missav", "missav", "https://missav.ws",                  .htmlRegex,  [.video,.actor,.classify,.search], htmlTemplate: .generic),
        .make("mmav",   "mmav",   "mmav",   "https://sm-api.wieuc.com",           .apiJson,    [.video,.topic,.search]),
        .make("oksp",   "oksp",   "oksp",   "https://api55.gwqqbp.com",           .encPost,    [.video,.film,.actor,.search]),

        // ═══ 分类/频道类 (6个) ═══
        .make("pron91", "91pron", "91pron", "https://api1.i91avapi2.com",         .pwaApi,     [.classify,.rank,.search]),
        .make("tv91",   "91tv",   "91tv",   "https://api2.uhqechyr.com",          .apiJson,    [.home,.channel,.tag,.search]),
        .make("mdtv",   "mdtv",   "mdtv",   "https://api2.kpsvvkl.cc",            .apiJson,    [.home,.channel,.tag,.search]),
        .make("pdl",    "pdl",    "pdl",    "https://api3.boygzqzff.cc",          .pwaApi,     [.home,.channel,.rank,.search]),
        .make("qp",     "qp",     "qp",     "https://api.hichatapi.info",         .apiJson,    [.channel,.tag,.search]),
        .make("zpc91",  "91zpc",  "91zpc",  "https://api1.i91avapi2.com",         .pwaApi,     [.home,.classify,.search]),

        // ═══ 内容发现 (7个) ═══
        .make("dsp91",  "91dsp",  "91dsp",  "https://api1.i91avapi2.com",         .pwaApi,     [.home,.video,.tiktok,.user,.search]),
        .make("sp91",   "91sp",   "91sp",   "https://api1.i91avapi2.com",         .pwaApi,     [.film,.tiktok,.actor,.search]),
        .make("ttav",   "ttav",   "ttav",   "https://api3.caanrrim.cc",           .pwaApi,     [.home,.film,.find,.tiktok,.user,.darkWeb,.search]),
        .make("xjsp",   "xjsp",   "xjsp",   "https://api1.zwcdjpuxs.cc",          .apiJson,    [.video,.classify,.tiktok,.actor,.search]),
        .make("fl2",    "fl2",    "fl2",    "https://yjwx257.com",                .encPost,    [.video,.actor,.find,.search]),
        .make("byfm",   "byfm",   "byfm",   "https://api.byfm2.app",              .apiJson,    [.video,.actor,.classify,.audio,.search]),
        .make("yxfm",   "yxfm",   "yxfm",   "https://api.byfm2.app",              .apiJson,    [.video,.actor,.audio,.search]),

        // ═══ 图片/文章/社区 (6个) ═══
        .make("hu4",    "4hu",    "4hu",    "https://api.em1oifd0.com",           .apiJson,    [.video,.image,.novel,.stills,.search]),
        .make("awjd",   "awjd",   "awjd",   "https://a7waex8.live",               .apiJson,    [.home,.video,.article,.search]),
        .make("cgw",    "cgw",    "cgw",    "https://a7waex8.live",               .apiJson,    [.article,.video,.search]),
        .make("cg51",   "51cg",   "51cg",   "https://api1.i91avapi2.com",         .pwaApi,     [.home,.video,.community,.topic,.user,.search]),
        .make("ttt",    "ttt",    "ttt",    "https://api3.caanrrim.cc",           .pwaApi,     [.home,.video,.tiktok,.tag,.user,.search]),
        .make("sgp",    "sgp",    "sgp",    "https://a7waex8.live",               .apiJson,    [.video,.actor,.article,.search]),

        // ═══ 影视下载/暗网类 (4个) ═══
        .make("dm51",   "51dm",   "51dm",   "https://api1.i91avapi2.com",         .pwaApi,     [.anime,.film,.darkWeb,.search]),
        .make("awjm",   "awjm",   "awjm",   "https://a7waex8.live",               .apiJson,    [.video,.actor,.darkWeb,.search]),
        .make("qysq",   "qysq",   "qysq",   "https://api.hichatapi.info",         .apiJson,    [.home,.video,.darkWeb,.search]),
        .make("kpsp",   "kptv",   "kptv",   "https://api2.kpsvvkl.cc",            .apiJson,    [.home,.darkWeb,.search]),

        // ═══ 其他特色 (6个) ═══
        .make("dh50",   "50dh",   "50dh",   "https://ujvxsl.uizipgcq.com",        .pwaApi,     [.home,.classify,.user,.search]),
        .make("hjsq",   "hjsq",   "hjsq",   "https://alipa.mamnvbyiu5od.com",     .encPost,    [.home,.video,.tiktok,.user,.search]),
        .make("yfg",    "yfg",    "yfg",    "https://api-al.ass6.store",          .apiJson,    [.video,.user,.search]),
        .make("km",     "km",     "km",     "https://1080.hlkjsm.com",            .htmlRegex,  [.video,.user,.search], htmlTemplate: .wurenren),
        .make("gdcm",   "gdcm",   "gdcm",   "https://tth.txh069.com",             .htmlRegex,  [.home,.video,.search], htmlTemplate: .generic),
        .make("wwsq",   "wwsq",   "wwsq",   "https://we.killcovid2020.com",       .htmlRegex,  [.video,.search], htmlTemplate: .generic),

        // ═══ 知名平台 (2个) ═══
        .make("rryy",   "rryy",   "rryy",   "https://jszyapi.com",                .apiJson,    [.search], apiMode: .open),
        .make("xvideos","xvideos","xvideos","https://api.hichatapi.info",          .apiJson,    [.video,.classify,.search]),

        // ═══ YBox独有 (7个) ═══
        .make("gsjh",   "gsjh",   "gsjh",   "https://hsck123.com",                .htmlRegex,  [.video,.search], htmlTemplate: .stui),
        .make("hhl",    "hhl",    "hhl",    "https://api-al.ass6.store",          .apiJson,    [.video,.search]),
        .make("hjll",   "hjll",   "hjll",   "https://api-al.ass6.store",          .apiJson,    [.video,.search]),
        .make("hsck",   "hsck",   "hsck",   "https://hsck123.com",                .htmlRegex,  [.video,.search], htmlTemplate: .stui),
        .make("jmbox",  "jmbox",  "jmbox",  "https://www.comicbox.xyz",           .htmlRegex,  [.video,.search]),
        .make("mmmh",   "mmmh",   "mmmh",   "https://sdhvb.meme06.live",           .apiJson,    [.comic,.search]),
    ]

    /// 根据platformId查找配置
    static func config(for id: String) -> WelfareCrawlerConfig? {
        all.first { $0.platformId == id }
    }

    private static func make(_ id: String, _ name: String, _ prefix: String,
                              _ url: String, _ parser: WelfareParserType,
                              _ pages: [WelfarePageKind],
                              apiMode: APIMode = .encrypted,
                              htmlTemplate: HTMLTemplateType? = nil) -> WelfareCrawlerConfig {
        WelfareCrawlerConfig(platformId: id, platformName: name, searchPrefix: prefix,
                             baseURL: url, parserType: parser, apiMode: apiMode,
                             htmlTemplate: htmlTemplate,
                             pages: pages, pageSections: [:])
    }
}
