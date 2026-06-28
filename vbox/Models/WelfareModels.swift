import Foundation

// MARK: - 福利专区数据模型（完全对照 YBox lls_nav.json 结构）

/// 福利平台（对应 YBox ic_app_* 图标对应的内容平台）
struct WelfarePlatform: Identifiable, Hashable {
    let id: String
    let name: String
    /// 用于组合搜索关键词的前缀
    let searchPrefix: String
    /// 平台分类组（视频/动漫/漫画/小说）
    let categoryGroups: [WelfareCategoryGroup]

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: WelfarePlatform, rhs: WelfarePlatform) -> Bool { lhs.id == rhs.id }
}

/// 内容类型分组（对应 YBox 一级 Tab：视频/动漫/漫画/小说）
struct WelfareCategoryGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let subcategories: [WelfareSubCategory]

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: WelfareCategoryGroup, rhs: WelfareCategoryGroup) -> Bool { lhs.id == rhs.id }
}

/// 子分类（对应 YBox 二级分类：精选/最新/学妹/国产精选...）
struct WelfareSubCategory: Identifiable, Hashable {
    let id: String
    let name: String
    /// 搜索关键词（与平台 searchPrefix 拼接作为搜索词）
    let keyword: String

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: WelfareSubCategory, rhs: WelfareSubCategory) -> Bool { lhs.id == rhs.id }
}

// MARK: - 分类组定义（来自 YBox lls_nav.json）

extension WelfareCategoryGroup {
    /// 视频分类组
    static let video = WelfareCategoryGroup(
        id: "video",
        name: "视频",
        icon: "play.rectangle.fill",
        subcategories: [
            WelfareSubCategory(id: "jingxuan",    name: "精选",      keyword: "精选"),
            WelfareSubCategory(id: "zuixin",      name: "最新",      keyword: "最新"),
            WelfareSubCategory(id: "xuejiao",     name: "学妹",      keyword: "学妹"),
            WelfareSubCategory(id: "guochan",     name: "国产精选",   keyword: "国产精选"),
            WelfareSubCategory(id: "fuliji",      name: "福利姬",     keyword: "福利姬"),
            WelfareSubCategory(id: "erciyuan",    name: "二次元",     keyword: "二次元"),
            WelfareSubCategory(id: "wanghuang",   name: "网黄",      keyword: "网黄"),
            WelfareSubCategory(id: "luanlun",     name: "乱伦换妻",   keyword: "乱伦"),
            WelfareSubCategory(id: "zhongkou",    name: "重口",      keyword: "重口"),
            WelfareSubCategory(id: "av",          name: "岛国AV",    keyword: "AV"),
            WelfareSubCategory(id: "yiyu",        name: "异域风情",   keyword: "异域风情"),
            WelfareSubCategory(id: "chuanmei",    name: "传媒影视",   keyword: "传媒"),
            WelfareSubCategory(id: "zongyi",      name: "综艺",      keyword: "综艺"),
        ]
    )

    /// 动漫分类组
    static let cartoon = WelfareCategoryGroup(
        id: "cartoon",
        name: "动漫",
        icon: "sparkles.tv.fill",
        subcategories: [
            WelfareSubCategory(id: "dm_tuijian",       name: "推荐",     keyword: "动漫 推荐"),
            WelfareSubCategory(id: "dm_lifan",         name: "里番",     keyword: "里番"),
            WelfareSubCategory(id: "dm_3d",            name: "3D同人",   keyword: "3D 同人"),
            WelfareSubCategory(id: "dm_mmd",           name: "MMD",     keyword: "MMD"),
            WelfareSubCategory(id: "dm_jinman",        name: "禁漫原作",  keyword: "禁漫"),
            WelfareSubCategory(id: "dm_renfan",        name: "肉番",     keyword: "肉番"),
            WelfareSubCategory(id: "dm_juchangban",    name: "剧场版",   keyword: "剧场版"),
        ]
    )

    /// 漫画分类组
    static let comic = WelfareCategoryGroup(
        id: "comic",
        name: "漫画",
        icon: "book.pages.fill",
        subcategories: [
            WelfareSubCategory(id: "mh_tuijian",        name: "推荐",     keyword: "漫画 推荐"),
            WelfareSubCategory(id: "mh_zuixin",         name: "最新",     keyword: "漫画 最新"),
            WelfareSubCategory(id: "mh_cos",            name: "Cosplay", keyword: "Cosplay"),
            WelfareSubCategory(id: "mh_hanman",         name: "韩漫",     keyword: "韩漫"),
            WelfareSubCategory(id: "mh_tongren",        name: "同人",     keyword: "漫画 同人"),
            WelfareSubCategory(id: "mh_riman",          name: "日漫",     keyword: "日漫"),
            WelfareSubCategory(id: "mh_benzi",          name: "本子",     keyword: "本子"),
            WelfareSubCategory(id: "mh_ai",             name: "AI",      keyword: "AI 漫画"),
            WelfareSubCategory(id: "mh_3d",             name: "3D",      keyword: "3D 漫画"),
            WelfareSubCategory(id: "mh_fuman",          name: "腐漫",     keyword: "腐漫"),
            WelfareSubCategory(id: "mh_paihang",        name: "排行",     keyword: "漫画 排行"),
            WelfareSubCategory(id: "mh_zhenren",        name: "真人漫画",  keyword: "真人漫画"),
            WelfareSubCategory(id: "mh_guoman",         name: "国漫",     keyword: "国漫"),
        ]
    )

    /// 小说分类组
    static let novel = WelfareCategoryGroup(
        id: "novel",
        name: "小说",
        icon: "text.book.closed.fill",
        subcategories: [
            WelfareSubCategory(id: "xs_tuijian",         name: "推荐",     keyword: "小说 推荐"),
            WelfareSubCategory(id: "xs_zuixin",          name: "最新",     keyword: "小说 最新"),
            WelfareSubCategory(id: "xs_yousheng",        name: "有声小说",  keyword: "有声小说"),
            WelfareSubCategory(id: "xs_shuangwen",       name: "爽文",     keyword: "爽文"),
            WelfareSubCategory(id: "xs_renqishounv",     name: "人妻熟女",  keyword: "人妻 熟女"),
            WelfareSubCategory(id: "xs_qiangbao",        name: "强暴虐待",  keyword: "强暴"),
            WelfareSubCategory(id: "xs_xiaoyuan",        name: "校园春色",  keyword: "校园"),
            WelfareSubCategory(id: "xs_doushi",          name: "都市生活",  keyword: "都市"),
            WelfareSubCategory(id: "xs_jiating",         name: "家庭乱伦",  keyword: "家庭 乱伦"),
            WelfareSubCategory(id: "xs_mingxing",        name: "明星艳记",  keyword: "明星"),
        ]
    )

    /// 全部四个分类组
    static let allGroups: [WelfareCategoryGroup] = [.video, .cartoon, .comic, .novel]
}

// MARK: - 平台定义（来自 YBox AssetManifest.json ic_app_* 图标列表）

extension WelfarePlatform {
    /// 全部 62 个内容平台（过滤掉 bg/fav/share/telegram/live/ybox 等工具图标）
    static let allPlatforms: [WelfarePlatform] = [
        WelfarePlatform(id: "4hu",      name: "4hu",       searchPrefix: "4hu",     categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "50dh",     name: "50dh",      searchPrefix: "50dh",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "51cg",     name: "51cg",      searchPrefix: "51cg",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "51dm",     name: "51dm",      searchPrefix: "51dm",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "51fl",     name: "51fl",      searchPrefix: "51fl",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "51ll",     name: "51ll",      searchPrefix: "51ll",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "91av",     name: "91av",      searchPrefix: "91av",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "91dsp",    name: "91dsp",     searchPrefix: "91dsp",   categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "91pron",   name: "91pron",    searchPrefix: "91pron",  categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "91sp",     name: "91sp",      searchPrefix: "91sp",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "91tv",     name: "91tv",      searchPrefix: "91tv",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "91zpc",    name: "91zpc",     searchPrefix: "91zpc",   categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "akmh",     name: "akmh",      searchPrefix: "akmh",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "awjd",     name: "awjd",      searchPrefix: "awjd",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "awjm",     name: "awjm",      searchPrefix: "awjm",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "byfm",     name: "byfm",      searchPrefix: "byfm",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "cgw",      name: "cgw",       searchPrefix: "cgw",     categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "djr",      name: "djr",       searchPrefix: "djr",     categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "fl2",      name: "fl2",       searchPrefix: "fl2",     categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "gdcm",     name: "gdcm",      searchPrefix: "gdcm",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "gsjh",     name: "gsjh",      searchPrefix: "gsjh",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "hgsp",     name: "hgsp",      searchPrefix: "hgsp",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "hhl",      name: "hhl",       searchPrefix: "hhl",     categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "hhlz",     name: "hhlz",      searchPrefix: "hhlz",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "hjll",     name: "hjll",      searchPrefix: "hjll",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "hjsq",     name: "hjsq",      searchPrefix: "hjsq",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "hsck",     name: "hsck",      searchPrefix: "hsck",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "hsxs",     name: "hsxs",      searchPrefix: "hsxs",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "hxsp",     name: "hxsp",      searchPrefix: "hxsp",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "insav",    name: "insav",     searchPrefix: "insav",   categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "javdb",    name: "javdb",     searchPrefix: "javdb",   categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "jmbox",    name: "jmbox",     searchPrefix: "jmbox",   categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "jmtt",     name: "jmtt",      searchPrefix: "jmtt",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "km",       name: "km",        searchPrefix: "km",      categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "kptv",     name: "kptv",      searchPrefix: "kptv",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "lld",      name: "lld",       searchPrefix: "lld",     categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "lls",      name: "lls",       searchPrefix: "lls",     categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "lxs",      name: "lxs",       searchPrefix: "lxs",     categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "mdtv",     name: "mdtv",      searchPrefix: "mdtv",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "missav",   name: "missav",    searchPrefix: "missav",  categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "mmav",     name: "mmav",      searchPrefix: "mmav",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "mmmh",     name: "mmmh",      searchPrefix: "mmmh",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "mtyx",     name: "mtyx",      searchPrefix: "mtyx",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "mw",       name: "mw",        searchPrefix: "mw",      categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "nc",       name: "nc",        searchPrefix: "nc",      categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "oksp",     name: "oksp",      searchPrefix: "oksp",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "one",      name: "one",       searchPrefix: "one",     categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "pfdsp",    name: "pfdsp",     searchPrefix: "pfdsp",   categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "qp",       name: "qp",        searchPrefix: "qp",      categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "qysq",     name: "qysq",      searchPrefix: "qysq",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "rryy",     name: "rryy",      searchPrefix: "rryy",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "sgp",      name: "sgp",       searchPrefix: "sgp",     categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "ttav",     name: "ttav",      searchPrefix: "ttav",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "ttt",      name: "ttt",       searchPrefix: "ttt",     categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "txvlog",   name: "txvlog",    searchPrefix: "txvlog",  categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "wwmh",     name: "wwmh",      searchPrefix: "wwmh",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "wwsq",     name: "wwsq",      searchPrefix: "wwsq",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "xbk",      name: "xbk",       searchPrefix: "xbk",     categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "xjsp",     name: "xjsp",      searchPrefix: "xjsp",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "xvideos",  name: "xvideos",   searchPrefix: "xvideos", categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "yfg",      name: "yfg",       searchPrefix: "yfg",     categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "yxfm",     name: "yxfm",      searchPrefix: "yxfm",    categoryGroups: WelfareCategoryGroup.allGroups),
        WelfarePlatform(id: "zlt",      name: "zlt",       searchPrefix: "zlt",     categoryGroups: WelfareCategoryGroup.allGroups),
    ]
}
