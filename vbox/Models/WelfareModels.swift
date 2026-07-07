import Foundation

// MARK: - 福利专区数据模型（自适应页面，由爬虫配置驱动）

struct WelfarePlatform: Identifiable, Hashable {
    let id: String
    let name: String
    let searchPrefix: String
    let contentType: WelfareContentType
    /// 自适应页面列表（由 WelfareCrawlerConfig 动态生成）
    let pages: [WelfarePage]

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: WelfarePlatform, rhs: WelfarePlatform) -> Bool { lhs.id == rhs.id }

    /// 从爬虫配置自适应生成平台（使用配置中的 pageSections）
    static func adaptive(id: String, name: String, searchPrefix: String) -> WelfarePlatform {
        guard let cfg = WelfareCrawlerConfig.config(for: id) else {
            let kinds = WelfareCrawlerService.shared.pages(for: id)
            let pages = kinds.map { WelfarePage(id: "\(id)_\($0.rawValue)", name: $0.displayName,
                                                icon: $0.icon, kind: $0,
                                                sections: defaultSections(for: $0, prefix: name)) }
            return WelfarePlatform(id: id, name: name, searchPrefix: searchPrefix,
                                   contentType: .video, pages: pages)
        }
        let kinds = cfg.pages
        let pages = kinds.map { kind in
            WelfarePage(id: "\(id)_\(kind.rawValue)", name: kind.displayName,
                        icon: kind.icon, kind: kind,
                        sections: sectionsFor(kind: kind, prefix: name, config: cfg))
        }
        return WelfarePlatform(id: id, name: name, searchPrefix: searchPrefix,
                               contentType: cfg.contentType, pages: pages)
    }
}

struct WelfarePage: Identifiable, Hashable {
    let id: String; let name: String; let icon: String
    let kind: WelfarePageKind
    let sections: [WelfareSection]
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: WelfarePage, rhs: WelfarePage) -> Bool { lhs.id == rhs.id }
}

struct WelfareSection: Identifiable, Hashable {
    let id: String; let name: String; let keyword: String
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: WelfareSection, rhs: WelfareSection) -> Bool { lhs.id == rhs.id }
}

/// 根据配置中的 pageSections 生成分区，否则使用默认分区
private func sectionsFor(kind: WelfarePageKind, prefix: String, config: WelfareCrawlerConfig) -> [WelfareSection] {
    if let names = config.pageSections[kind.rawValue], !names.isEmpty {
        return names.enumerated().map { i, name in
            // 第一个分区 = 默认/全部：不筛选，显示所有内容
            // 后续分区 = 具体分类：用分类名作为搜索关键词
            WelfareSection(id: "\(kind.rawValue)_\(i)", name: name, keyword: i == 0 ? "" : name)
        }
    }
    return defaultSections(for: kind, prefix: prefix)
}

/// 默认分区（当配置未指定 pageSections 时使用）
/// 返回空数组=不展示假分类，无数据时直接显示加载失败
private func defaultSections(for kind: WelfarePageKind, prefix: String) -> [WelfareSection] {
    []
}

// MARK: - 62 个平台自适应定义

extension WelfarePlatform {
    static let allPlatforms: [WelfarePlatform] = {
        let defs: [(id: String, name: String, prefix: String)] = [
            // 视频聚合类 (15)
            ("91av","91av","91av"), ("hgsp","hgsp","hgsp"), ("hsxs","hsxs","hsxs"),
            ("hxsp","hxsp","hxsp"), ("ll51","51ll","51ll"), ("lld","lld","lld"),
            ("mtyx","mtyx","mtyx"), ("one","one","one"), ("pfdsp","pfdsp","pfdsp"),
            ("txvlog","txvlog","txvlog"), ("wmq","wmq","wmq"), ("xbk","xbk","xbk"),
            ("zlt","zlt","zlt"),
            // 多类型综合 (3)
            ("lls","lls","lls"), ("hhlz","hhlz","hhlz"), ("mimei","mimei","mimei"),
            // 漫画阅读 (5)
            ("akmh","akmh","akmh"), ("jmtt","jmtt","jmtt"), ("nc","nc","nc"),
            ("mw","mw","mw"), ("wwmh","wwmh","wwmh"),
            // 演员/AV信息 (7)
            ("avin","insav","insav"), ("javdb","javdb","javdb"), ("djr","djr","djr"),
            ("lxs","lxs","lxs"), ("44hhqq","44hhqq","44hhqq"), ("missav","missav","missav"), ("mmav","mmav","mmav"),
            ("oksp","oksp","oksp"),
            // 分类/频道类 (6)
            ("pron91","91pron","91pron"), ("tv91","91tv","91tv"), ("mdtv","mdtv","mdtv"),
            ("pdl","pdl","pdl"), ("qp","qp","qp"), ("zpc91","91zpc","91zpc"),
            // 内容发现 (7)
            ("dsp91","91dsp","91dsp"), ("sp91","91sp","91sp"), ("ttav","ttav","ttav"),
            ("xjsp","xjsp","xjsp"), ("fl2","fl2","fl2"), ("byfm","byfm","byfm"),
            ("yxfm","yxfm","yxfm"),
            // 图片/文章/社区 (6)
            ("hu4","4hu","4hu"), ("awjd","awjd","awjd"), ("cgw","cgw","cgw"),
            ("cg51","51cg","51cg"), ("ttt","ttt","ttt"), ("sgp","sgp","sgp"),
            // 影视下载/暗网类 (4)
            ("dm51","51dm","51dm"), ("awjm","awjm","awjm"), ("qysq","qysq","qysq"),
            ("kpsp","kptv","kptv"),
            // 其他特色 (6)
            ("dh50","50dh","50dh"), ("hjsq","hjsq","hjsq"), ("yfg","yfg","yfg"),
            ("km","km","km"), ("gdcm","gdcm","gdcm"), ("wwsq","wwsq","wwsq"),
            // 知名平台 (2)
            ("rryy","rryy","rryy"), ("xvideos","xvideos","xvideos"),
            // YBox独有 (7)
            ("gsjh","gsjh","gsjh"), ("hhl","hhl","hhl"), ("hjll","hjll","hjll"),
            ("hsck","hsck","hsck"), ("jmbox","jmbox","jmbox"), ("mmmh","mmmh","mmmh"),
        ]
        return defs.map { WelfarePlatform.adaptive(id: $0.id, name: $0.name, searchPrefix: $0.prefix) }
    }()
}
