import Foundation

// MARK: - 福利专区数据模型（基于 YBox 真实平台页面结构还原）

/// 内容平台
struct WelfarePlatform: Identifiable, Hashable {
    let id: String
    let name: String
    let searchPrefix: String
    /// 该平台下的页面列表（首页/视频/动漫/演员/搜索等）
    let pages: [WelfarePage]

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: WelfarePlatform, rhs: WelfarePlatform) -> Bool { lhs.id == rhs.id }
}

/// 平台内的一个页面栏目
struct WelfarePage: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    /// 页面下的内容分区（如 home_child1, home_child2 等）
    let sections: [WelfareSection]

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: WelfarePage, rhs: WelfarePage) -> Bool { lhs.id == rhs.id }
}

/// 内容分区（对应搜索关键词）
struct WelfareSection: Identifiable, Hashable {
    let id: String
    let name: String
    let keyword: String

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: WelfareSection, rhs: WelfareSection) -> Bool { lhs.id == rhs.id }
}

// MARK: - 页面模板工厂

private extension WelfarePage {
    static func home(_ prefix: String, sections: [WelfareSection] = [
        WelfareSection(id: "recommend", name: "推荐", keyword: "推荐"),
        WelfareSection(id: "latest",   name: "最新", keyword: "最新"),
        WelfareSection(id: "hot",      name: "热门", keyword: "热门"),
    ]) -> WelfarePage {
        WelfarePage(id: "\(prefix)_home", name: "首页", icon: "house.fill", sections: sections)
    }

    static func video(_ prefix: String, sections: [WelfareSection] = [
        WelfareSection(id: "all", name: "全部", keyword: ""),
    ]) -> WelfarePage {
        WelfarePage(id: "\(prefix)_video", name: "视频", icon: "play.rectangle.fill", sections: sections)
    }

    static func film(_ prefix: String, sections: [WelfareSection] = [
        WelfareSection(id: "all", name: "全部", keyword: ""),
    ]) -> WelfarePage {
        WelfarePage(id: "\(prefix)_film", name: "电影", icon: "film.fill", sections: sections)
    }

    static func anime(_ prefix: String, sections: [WelfareSection] = [
        WelfareSection(id: "all", name: "全部", keyword: ""),
    ]) -> WelfarePage {
        WelfarePage(id: "\(prefix)_anime", name: "动漫", icon: "sparkles.tv.fill", sections: sections)
    }

    static func comic(_ prefix: String, sections: [WelfareSection] = [
        WelfareSection(id: "all", name: "全部", keyword: ""),
    ]) -> WelfarePage {
        WelfarePage(id: "\(prefix)_comic", name: "漫画", icon: "book.pages.fill", sections: sections)
    }

    static func novel(_ prefix: String, sections: [WelfareSection] = [
        WelfareSection(id: "all", name: "全部", keyword: ""),
    ]) -> WelfarePage {
        WelfarePage(id: "\(prefix)_novel", name: "小说", icon: "text.book.closed.fill", sections: sections)
    }

    static func actor(_ prefix: String) -> WelfarePage {
        WelfarePage(id: "\(prefix)_actor", name: "演员", icon: "person.2.fill", sections: [
            WelfareSection(id: "all", name: "全部", keyword: ""),
        ])
    }

    static func search(_ prefix: String) -> WelfarePage {
        WelfarePage(id: "\(prefix)_search", name: "搜索", icon: "magnifyingglass", sections: [
            WelfareSection(id: "all", name: "搜索", keyword: ""),
        ])
    }

    static func classify(_ prefix: String) -> WelfarePage {
        WelfarePage(id: "\(prefix)_classify", name: "分类", icon: "square.grid.2x2.fill", sections: [
            WelfareSection(id: "all", name: "全部", keyword: ""),
        ])
    }

    static func find(_ prefix: String) -> WelfarePage {
        WelfarePage(id: "\(prefix)_find", name: "发现", icon: "sparkle.magnifyingglass", sections: [
            WelfareSection(id: "all", name: "全部", keyword: ""),
        ])
    }

    static func topic(_ prefix: String) -> WelfarePage {
        WelfarePage(id: "\(prefix)_topic", name: "话题", icon: "bubble.left.and.bubble.right.fill", sections: [
            WelfareSection(id: "all", name: "全部", keyword: ""),
        ])
    }

    static func tiktok(_ prefix: String) -> WelfarePage {
        WelfarePage(id: "\(prefix)_tiktok", name: "短视频", icon: "play.square.stack.fill", sections: [
            WelfareSection(id: "all", name: "全部", keyword: ""),
        ])
    }

    static func darkWeb(_ prefix: String) -> WelfarePage {
        WelfarePage(id: "\(prefix)_dark", name: "暗网", icon: "eye.slash.fill", sections: [
            WelfareSection(id: "all", name: "全部", keyword: ""),
        ])
    }

    static func audio(_ prefix: String) -> WelfarePage {
        WelfarePage(id: "\(prefix)_audio", name: "音频", icon: "headphones", sections: [
            WelfareSection(id: "all", name: "全部", keyword: ""),
        ])
    }

    static func article(_ prefix: String) -> WelfarePage {
        WelfarePage(id: "\(prefix)_article", name: "文章", icon: "doc.text.fill", sections: [
            WelfareSection(id: "all", name: "全部", keyword: ""),
        ])
    }

    static func community(_ prefix: String) -> WelfarePage {
        WelfarePage(id: "\(prefix)_community", name: "社区", icon: "person.3.fill", sections: [
            WelfareSection(id: "all", name: "全部", keyword: ""),
        ])
    }

    static func rank(_ prefix: String) -> WelfarePage {
        WelfarePage(id: "\(prefix)_rank", name: "排行", icon: "list.number", sections: [
            WelfareSection(id: "all", name: "全部", keyword: ""),
        ])
    }

    static func channel(_ prefix: String) -> WelfarePage {
        WelfarePage(id: "\(prefix)_channel", name: "频道", icon: "tv.fill", sections: [
            WelfareSection(id: "all", name: "全部", keyword: ""),
        ])
    }

    static func tag(_ prefix: String) -> WelfarePage {
        WelfarePage(id: "\(prefix)_tag", name: "标签", icon: "tag.fill", sections: [
            WelfareSection(id: "all", name: "全部", keyword: ""),
        ])
    }

    static func user(_ prefix: String) -> WelfarePage {
        WelfarePage(id: "\(prefix)_user", name: "用户", icon: "person.crop.circle.fill", sections: [
            WelfareSection(id: "all", name: "全部", keyword: ""),
        ])
    }

    static func image(_ prefix: String) -> WelfarePage {
        WelfarePage(id: "\(prefix)_image", name: "图片", icon: "photo.on.rectangle.fill", sections: [
            WelfareSection(id: "all", name: "全部", keyword: ""),
        ])
    }

    static func stills(_ prefix: String) -> WelfarePage {
        WelfarePage(id: "\(prefix)_stills", name: "剧照", icon: "photo.stack.fill", sections: [
            WelfareSection(id: "all", name: "全部", keyword: ""),
        ])
    }
}

// MARK: - 全部平台定义（基于 YBox 二进制逆向还原）

extension WelfarePlatform {
    static let allPlatforms: [WelfarePlatform] = [
        // ──────────────────────────────────────
        // 视频聚合类平台
        // ──────────────────────────────────────
        WelfarePlatform(id: "91av",   name: "91av",   searchPrefix: "91av",   pages: [.home("91av", sections: [
            WelfareSection(id:"c1",name:"精选",keyword:""),WelfareSection(id:"c2",name:"最新",keyword:""),
            WelfareSection(id:"c3",name:"国产",keyword:""),WelfareSection(id:"c4",name:"热门",keyword:""),
        ]), .video("91av"), .actor("91av"), .search("91av")]),

        WelfarePlatform(id: "hgsp",   name: "hgsp",   searchPrefix: "hgsp",   pages: [.home("hgsp", sections: [
            WelfareSection(id:"c1",name:"精选",keyword:""),WelfareSection(id:"c2",name:"最新",keyword:""),
            WelfareSection(id:"c3",name:"系列",keyword:""),
        ]), .video("hgsp"), .actor("hgsp"), .search("hgsp")]),

        WelfarePlatform(id: "hsxs",   name: "hsxs",   searchPrefix: "hsxs",   pages: [.home("hsxs", sections: [
            WelfareSection(id:"c1",name:"精选",keyword:""),WelfareSection(id:"c2",name:"暗网",keyword:""),
        ]), .video("hsxs"), .anime("hsxs"), .comic("hsxs"), .actor("hsxs"), .darkWeb("hsxs"), .search("hsxs")]),

        WelfarePlatform(id: "hxsp",   name: "hxsp",   searchPrefix: "hxsp",   pages: [.home("hxsp", sections: [
            WelfareSection(id:"c1",name:"精选",keyword:""),WelfareSection(id:"c2",name:"最新",keyword:""),
            WelfareSection(id:"c3",name:"热门",keyword:""),WelfareSection(id:"c4",name:"分类",keyword:""),
        ]), .video("hxsp"), .classify("hxsp"), .tiktok("hxsp"), .search("hxsp")]),

        WelfarePlatform(id: "ll51",   name: "51ll",    searchPrefix: "51ll",   pages: [.home("ll51", sections: [
            WelfareSection(id:"c1",name:"精选",keyword:""),WelfareSection(id:"c2",name:"暗网",keyword:""),
        ]), .video("ll51"), .tiktok("ll51"), .darkWeb("ll51"), .search("ll51")]),

        WelfarePlatform(id: "lld",    name: "lld",     searchPrefix: "lld",    pages: [.home("lld", sections: [
            WelfareSection(id:"c1",name:"精选",keyword:""),
        ]), .video("lld"), .search("lld")]),

        WelfarePlatform(id: "mtyx",   name: "mtyx",    searchPrefix: "mtyx",   pages: [.home("mtyx", sections: [
            WelfareSection(id:"c1",name:"精选",keyword:""),
        ]), .video("mtyx"), .tiktok("mtyx"), .topic("mtyx"), .search("mtyx")]),

        WelfarePlatform(id: "one",    name: "one",     searchPrefix: "one",    pages: [.home("one", sections: [
            WelfareSection(id:"c1",name:"精选",keyword:""),
        ]), .film("one"), .find("one", sections: [
            WelfareSection(id:"c1",name:"最新",keyword:""),WelfareSection(id:"c2",name:"热门",keyword:""),
        ]), .search("one")]),

        WelfarePlatform(id: "pfdsp",  name: "pfdsp",   searchPrefix: "pfdsp",  pages: [.home("pfdsp", sections: [
            WelfareSection(id:"c1",name:"精选",keyword:""),
        ]), .video("pfdsp"), .find("pfdsp"), .search("pfdsp")]),

        WelfarePlatform(id: "txvlog", name: "txvlog",  searchPrefix: "txvlog", pages: [.home("txvlog", sections: [
            WelfareSection(id:"c1",name:"精选",keyword:""),
        ]), .video("txvlog"), .tiktok("txvlog"), .search("txvlog")]),

        WelfarePlatform(id: "wmq",    name: "wmq",     searchPrefix: "wmq",    pages: [.home("wmq", sections: [
            WelfareSection(id:"c1",name:"精选",keyword:""),WelfareSection(id:"c2",name:"热门视频",keyword:""),
        ]), .video("wmq"), .tiktok("wmq"), .tag("wmq"), .user("wmq"), .search("wmq")]),

        WelfarePlatform(id: "xbk",    name: "xbk",     searchPrefix: "xbk",    pages: [.home("xbk", sections: [
            WelfareSection(id:"c1",name:"精选",keyword:""),
        ]), .video("xbk"), .tiktok("xbk"), .search("xbk")]),

        WelfarePlatform(id: "zlt",    name: "zlt",     searchPrefix: "zlt",    pages: [.home("zlt", sections: [
            WelfareSection(id:"c1",name:"精选",keyword:""),WelfareSection(id:"c2",name:"最新",keyword:""),
            WelfareSection(id:"c3",name:"分类",keyword:""),
        ]), .video("zlt"), .actor("zlt"), .search("zlt")]),

        // ──────────────────────────────────────
        // 多类型综合平台
        // ──────────────────────────────────────
        WelfarePlatform(id: "lls",    name: "lls",     searchPrefix: "lls",    pages: [.home("lls"), .film("lls"), .anime("lls"), .comic("lls"), .novel("lls"), .search("lls")]),

        WelfarePlatform(id: "hhlz",   name: "hhlz",    searchPrefix: "hhlz",   pages: [.film("hhlz"), .comic("hhlz"), .novel("hhlz"), .search("hhlz")]),

        WelfarePlatform(id: "mimei",  name: "mimei",   searchPrefix: "mimei",  pages: [.anime("mimei"), .comic("mimei"), .novel("mimei"), .classify("mimei"), .search("mimei")]),

        // ──────────────────────────────────────
        // 漫画阅读平台
        // ──────────────────────────────────────
        WelfarePlatform(id: "akmh",   name: "akmh",    searchPrefix: "akmh",   pages: [.anime("akmh"), .comic("akmh"), .search("akmh")]),

        WelfarePlatform(id: "jmtt",   name: "jmtt",    searchPrefix: "jmtt",   pages: [.home("jmtt"), .comic("jmtt"), .rank("jmtt"), .search("jmtt")]),

        WelfarePlatform(id: "nc",     name: "nc",      searchPrefix: "nc",     pages: [.comic("nc"), .search("nc")]),

        WelfarePlatform(id: "mw",     name: "mw",      searchPrefix: "mw",     pages: [.comic("mw"), .novel("mw"), .search("mw")]),

        WelfarePlatform(id: "wwmh",   name: "wwmh",    searchPrefix: "wwmh",   pages: [.comic("wwmh"), .search("wwmh")]),

        // ──────────────────────────────────────
        // 演员/AV信息平台
        // ──────────────────────────────────────
        WelfarePlatform(id: "avin",   name: "insav",   searchPrefix: "insav",  pages: [.video("avin"), .find("avin"), .actor("avin"), .search("avin")]),

        WelfarePlatform(id: "javdb",  name: "javdb",   searchPrefix: "javdb",  pages: [.video("javdb"), .actor("javdb"), .classify("javdb"), .search("javdb")]),

        WelfarePlatform(id: "djr",    name: "djr",     searchPrefix: "djr",    pages: [.video("djr"), .actor("djr"), .tag("djr"), .search("djr")]),

        WelfarePlatform(id: "lxs",    name: "lxs",     searchPrefix: "lxs",    pages: [.video("lxs"), .actor("lxs"), .search("lxs")]),

        WelfarePlatform(id: "missav", name: "missav",  searchPrefix: "missav", pages: [.video("missav"), .actor("missav"), .classify("missav"), .search("missav")]),

        WelfarePlatform(id: "mmav",   name: "mmav",    searchPrefix: "mmav",   pages: [.video("mmav"), .topic("mmav"), .search("mmav")]),

        WelfarePlatform(id: "oksp",   name: "oksp",    searchPrefix: "oksp",   pages: [.video("oksp"), .film("oksp"), .actor("oksp"), .search("oksp")]),

        // ──────────────────────────────────────
        // 分类/频道类平台
        // ──────────────────────────────────────
        WelfarePlatform(id: "pron91", name: "91pron",  searchPrefix: "91pron", pages: [.classify("pron91"), .rank("pron91"), .search("pron91")]),

        WelfarePlatform(id: "tv91",   name: "91tv",    searchPrefix: "91tv",   pages: [.home("tv91"), .channel("tv91"), .tag("tv91"), .search("tv91")]),

        WelfarePlatform(id: "mdtv",   name: "mdtv",    searchPrefix: "mdtv",   pages: [.home("mdtv"), .channel("mdtv"), .tag("mdtv"), .search("mdtv")]),

        WelfarePlatform(id: "pdl",    name: "pdl",     searchPrefix: "pdl",    pages: [.home("pdl"), .channel("pdl"), .rank("pdl"), .search("pdl")]),

        WelfarePlatform(id: "qp",     name: "qp",      searchPrefix: "qp",     pages: [.channel("qp"), .tag("qp"), .search("qp")]),

        WelfarePlatform(id: "zpc91",  name: "91zpc",   searchPrefix: "91zpc",  pages: [.home("zpc91"), .classify("zpc91"), .search("zpc91")]),

        // ──────────────────────────────────────
        // 内容发现平台
        // ──────────────────────────────────────
        WelfarePlatform(id: "dsp91",  name: "91dsp",   searchPrefix: "91dsp",  pages: [.home("dsp91"), .find("dsp91", sections: [
            WelfareSection(id:"c1",name:"精选",keyword:""),WelfareSection(id:"c2",name:"热门",keyword:""),
        ]), .video("dsp91"), .tiktok("dsp91"), .user("dsp91"), .search("dsp91")]),

        WelfarePlatform(id: "sp91",   name: "91sp",    searchPrefix: "91sp",   pages: [.film("sp91"), .tiktok("sp91"), .actor("sp91"), .search("sp91")]),

        WelfarePlatform(id: "ttav",   name: "ttav",    searchPrefix: "ttav",   pages: [.home("ttav"), .film("ttav", sections: [
            WelfareSection(id:"c1",name:"推荐",keyword:""),WelfareSection(id:"c2",name:"最新",keyword:""),
            WelfareSection(id:"c3",name:"热门",keyword:""),
        ]), .find("ttav"), .tiktok("ttav"), .user("ttav"), .darkWeb("ttav"), .search("ttav")]),

        WelfarePlatform(id: "xjsp",   name: "xjsp",    searchPrefix: "xjsp",   pages: [.video("xjsp"), .classify("xjsp"), .tiktok("xjsp"), .actor("xjsp"), .search("xjsp")]),

        WelfarePlatform(id: "fl2",    name: "fl2",     searchPrefix: "fl2",    pages: [.video("fl2"), .actor("fl2"), .find("fl2"), .search("fl2")]),

        WelfarePlatform(id: "byfm",   name: "byfm",    searchPrefix: "byfm",   pages: [.video("byfm"), .actor("byfm"), .classify("byfm"), .audio("byfm"), .search("byfm")]),

        WelfarePlatform(id: "yxfm",   name: "yxfm",    searchPrefix: "yxfm",   pages: [.video("yxfm"), .actor("yxfm"), .audio("yxfm"), .search("yxfm")]),

        // ──────────────────────────────────────
        // 图片/文章/社区平台
        // ──────────────────────────────────────
        WelfarePlatform(id: "hu4",    name: "4hu",     searchPrefix: "4hu",    pages: [.video("hu4"), .image("hu4"), .novel("hu4"), .stills("hu4"), .search("hu4")]),

        WelfarePlatform(id: "awjd",   name: "awjd",    searchPrefix: "awjd",   pages: [.home("awjd"), .video("awjd"), .article("awjd"), .search("awjd")]),

        WelfarePlatform(id: "cgw",    name: "cgw",     searchPrefix: "cgw",    pages: [.article("cgw"), .video("cgw"), .search("cgw")]),

        WelfarePlatform(id: "cg51",   name: "51cg",    searchPrefix: "51cg",   pages: [.home("cg51"), .video("cg51"), .community("cg51"), .topic("cg51"), .user("cg51"), .search("cg51")]),

        WelfarePlatform(id: "ttt",    name: "ttt",     searchPrefix: "ttt",    pages: [.home("ttt"), .video("ttt"), .tiktok("ttt"), .tag("ttt"), .user("ttt"), .search("ttt")]),

        WelfarePlatform(id: "sgp",    name: "sgp",     searchPrefix: "sgp",    pages: [.video("sgp"), .actor("sgp"), .article("sgp"), .search("sgp")]),

        // ──────────────────────────────────────
        // 影视下载/暗网类平台
        // ──────────────────────────────────────
        WelfarePlatform(id: "dm51",   name: "51dm",    searchPrefix: "51dm",   pages: [.anime("dm51"), .film("dm51"), .darkWeb("dm51"), .search("dm51")]),

        WelfarePlatform(id: "awjm",   name: "awjm",    searchPrefix: "awjm",   pages: [.video("awjm"), .actor("awjm"), .darkWeb("awjm"), .search("awjm")]),

        WelfarePlatform(id: "qysq",   name: "qysq",    searchPrefix: "qysq",   pages: [.home("qysq"), .video("qysq"), .darkWeb("qysq"), .search("qysq")]),

        WelfarePlatform(id: "kpsp",   name: "kptv",    searchPrefix: "kptv",   pages: [.home("kpsp"), .darkWeb("kpsp"), .search("kpsp")]),

        // ──────────────────────────────────────
        // 其他特色平台
        // ──────────────────────────────────────
        WelfarePlatform(id: "dh50",   name: "50dh",    searchPrefix: "50dh",   pages: [.home("dh50"), .classify("dh50"), .user("dh50"), .search("dh50")]),

        WelfarePlatform(id: "hjsq",   name: "hjsq",    searchPrefix: "hjsq",   pages: [.home("hjsq", sections: [
            WelfareSection(id:"c1",name:"精选",keyword:""),
        ]), .video("hjsq"), .tiktok("hjsq"), .user("hjsq"), .search("hjsq")]),

        WelfarePlatform(id: "yfg",    name: "yfg",     searchPrefix: "yfg",    pages: [.video("yfg"), .user("yfg"), .search("yfg")]),

        WelfarePlatform(id: "km",     name: "km",      searchPrefix: "km",     pages: [.video("km"), .user("km"), .search("km")]),

        WelfarePlatform(id: "gdcm",   name: "gdcm",    searchPrefix: "gdcm",   pages: [.home("gdcm"), .video("gdcm"), .search("gdcm")]),

        WelfarePlatform(id: "wwsq",   name: "wwsq",    searchPrefix: "wwsq",   pages: [.video("wwsq"), .search("wwsq")]),

        WelfarePlatform(id: "rryy",   name: "rryy",    searchPrefix: "rryy",   pages: [.search("rryy")]),

        WelfarePlatform(id: "xvideos",name: "xvideos", searchPrefix: "xvideos",pages: [.video("xvideos"), .classify("xvideos"), .search("xvideos")]),

        // ──────────────────────────────────────
        // YBox 独有/未在 ic_app 列表中的平台
        // ──────────────────────────────────────
        WelfarePlatform(id: "gsjh",   name: "gsjh",    searchPrefix: "gsjh",   pages: [.video("gsjh"), .search("gsjh")]),
        WelfarePlatform(id: "hhl",    name: "hhl",     searchPrefix: "hhl",    pages: [.video("hhl"), .search("hhl")]),
        WelfarePlatform(id: "hjll",   name: "hjll",    searchPrefix: "hjll",   pages: [.video("hjll"), .search("hjll")]),
        WelfarePlatform(id: "hsck",   name: "hsck",    searchPrefix: "hsck",   pages: [.video("hsck"), .search("hsck")]),
        WelfarePlatform(id: "jmbox",  name: "jmbox",   searchPrefix: "jmbox",  pages: [.video("jmbox"), .search("jmbox")]),
        WelfarePlatform(id: "mmmh",   name: "mmmh",    searchPrefix: "mmmh",   pages: [.comic("mmmh"), .search("mmmh")]),
    ]
}
