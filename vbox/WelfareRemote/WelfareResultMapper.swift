//
//  WelfareResultMapper.swift
//  vbox
//
//  Python 福利蜘蛛结果映射工具 — 将 PythonSpiderEngine 返回的标准 Spider 模型
//  转换为福利专区使用的 Fuli* 模型。
//
//  设计目标：
//  - 纯工具类，无状态，便于单测
//  - 与 WelfareJSSpiderService 中的转换逻辑等价
//  - 不影响普通资源链、网盘、其他福利平台
//

import Foundation

/// Python 蜘蛛 → 福利专区模型映射工具
struct WelfareResultMapper {

    // MARK: - Home

    func mapHome(_ result: HomeContentResult) -> FuliHomeResult {
        let categories = (result.class ?? []).map {
            FuliCategory(typeId: $0.typeId, typeName: $0.typeName)
        }
        let videos = (result.list ?? []).compactMap { mapVideo($0) }
        return FuliHomeResult(categories: categories, videos: videos)
    }

    // MARK: - Category

    func mapCategory(_ result: CategoryContentResult) -> FuliCategoryResult {
        let videos = (result.list ?? []).compactMap { mapVideo($0) }
        let pageCount = result.pagecount ?? 1
        let page = result.page ?? 1
        return FuliCategoryResult(videos: videos, page: page, hasMore: page < pageCount)
    }

    // MARK: - Detail

    func mapDetail(_ result: DetailContentResult) -> FuliDetail {
        guard let item = result.list?.first else {
            return FuliDetail(
                vodId: "", vodName: "", vodPic: "",
                vodContent: nil, playFrom: "", episodes: []
            )
        }
        let episodes = parseEpisodes(
            playFrom: item.vodPlayFrom ?? "",
            playUrl: item.vodPlayUrl ?? ""
        )
        return FuliDetail(
            vodId: item.vodId,
            vodName: item.vodName,
            vodPic: item.vodPic,
            vodContent: item.vodContent,
            playFrom: item.vodPlayFrom ?? "",
            episodes: episodes
        )
    }

    // MARK: - Search

    func mapSearch(_ result: SearchContentResult) -> FuliSearchResult {
        let videos = (result.list ?? []).compactMap { mapVideo($0) }
        let pageCount = result.pagecount ?? 1
        let page = result.page ?? 1
        return FuliSearchResult(videos: videos, page: page, hasMore: page < pageCount)
    }

    // MARK: - Player

    func mapPlayer(_ result: PlayerContentResult) -> FuliPlayerResult {
        let url = (result.playUrl?.isEmpty == false ? result.playUrl : nil)
            ?? result.url
            ?? ""
        let headers = result.header ?? [:]
        let parse = result.parse ?? 0
        return FuliPlayerResult(url: url, headers: headers, parse: parse)
    }

    // MARK: - 漫画图片解析

    /// 解析 manga:// 或 pics:// 协议的 URL 为图片列表
    /// 格式：manga://url1&&url2&&url3...
    func parseMangaURL(_ url: String) -> [String] {
        guard url.hasPrefix("manga://") || url.hasPrefix("pics://") else {
            return []
        }
        let content = url.dropFirst(url.hasPrefix("manga://") ? 8 : 7)
        let images = content.components(separatedBy: "&&")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.hasPrefix("http") }
        return images
    }

    /// 判断 URL 是否为漫画图片协议
    func isMangaProtocol(_ url: String) -> Bool {
        url.hasPrefix("manga://") || url.hasPrefix("pics://")
    }

    // MARK: - Private Helpers

    private func mapVideo(_ item: VodItem) -> FuliVideo? {
        guard !item.vodId.isEmpty else { return nil }
        return FuliVideo(
            vodId: item.vodId,
            vodName: item.vodName,
            vodPic: item.vodPic,
            vodRemarks: item.vodRemarks
        )
    }

    /// 解析标准 spider 的 vod_play_from + vod_play_url 为 FuliEpisode 数组
    /// 格式：
    ///   vod_play_from: "线路1$$$线路2"  （多线路用 $$$ 分隔）
    ///   vod_play_url:  "第1集$url1#第2集$url2$$$第1集$url1#第2集$url2"
    ///
    /// 非标准格式（黄豆短剧等）：
    ///   vod_play_url:  "第1集$url1$$$第2集$url2$$$第3集$url3"
    ///   （$$$ 直接分隔每一集，而非分隔线路）
    private func parseEpisodes(playFrom: String, playUrl: String) -> [FuliEpisode] {
        guard !playUrl.isEmpty else { return [] }

        // 1. 先按标准格式解析（$$$ 分隔线路，# 分隔集）
        let standardEpisodes = parseStandardFormat(playFrom: playFrom, playUrl: playUrl)

        // 2. 如果没有 $$$ 分隔符，直接用标准格式
        if !playUrl.contains("$$$") {
            return standardEpisodes
        }

        // 3. 尝试非标准格式（$$$ 直接分集）
        let nonStandardEpisodes = parseNonStandardFormat(playUrl: playUrl)

        // 4. 智能判断使用哪种格式
        let urlGroups = playUrl.components(separatedBy: "$$$")
        let allBlocksLikeEpisodes = urlGroups.allSatisfy { isEpisodeName($0.components(separatedBy: "$").first ?? "") }
        let allBlocksLikeLines = urlGroups.allSatisfy { isLineName($0.components(separatedBy: "$").first ?? "") }

        // 所有 $$$ 块都像集名 且 标准格式只能解析出很少的集 → 用非标准格式
        if allBlocksLikeEpisodes && standardEpisodes.count <= 1 && nonStandardEpisodes.count > 1 {
            return nonStandardEpisodes
        }

        // 所有 $$$ 块都像线路名 → 用标准格式
        if allBlocksLikeLines {
            return standardEpisodes
        }

        // 标准格式结果像线路名（集数少且名字像线路） → 尝试非标准格式
        if standardEpisodes.count <= 5, let first = standardEpisodes.first, isLineName(first.name) {
            if nonStandardEpisodes.count > standardEpisodes.count {
                return nonStandardEpisodes
            }
        }

        // 集数差距很大（>3倍）且非标准格式集数多时，选集数多的
        if nonStandardEpisodes.count > standardEpisodes.count * 3 && nonStandardEpisodes.count > 5 {
            return nonStandardEpisodes
        }

        // 默认使用标准格式
        return standardEpisodes
    }

    /// 标准格式解析：$$$ 分隔线路，# 分隔集，$ 分隔集名和URL
    private func parseStandardFormat(playFrom: String, playUrl: String) -> [FuliEpisode] {
        let lines = playFrom.components(separatedBy: "$$$")
        let urlGroups = playUrl.components(separatedBy: "$$$")

        var episodes: [FuliEpisode] = []
        let hasMultipleLines = lines.count > 1

        for (i, group) in urlGroups.enumerated() {
            let lineName = i < lines.count ? lines[i] : "线路\(i + 1)"
            let items = group.components(separatedBy: "#")

            for item in items {
                let parts = item.components(separatedBy: "$")
                guard parts.count >= 2 else { continue }
                let epName = parts[0].isEmpty ? "第\(episodes.count + 1)集" : parts[0]
                let epUrl = parts[1]

                let displayName = hasMultipleLines ? "[\(lineName)] \(epName)" : epName
                episodes.append(FuliEpisode(name: displayName, url: epUrl))
            }
        }

        return episodes
    }

    /// 非标准格式解析：$$$ 直接分隔集，每集用 集名$URL 格式
    private func parseNonStandardFormat(playUrl: String) -> [FuliEpisode] {
        let items = playUrl.components(separatedBy: "$$$")
        var episodes: [FuliEpisode] = []

        for (index, item) in items.enumerated() {
            let parts = item.components(separatedBy: "$")
            guard parts.count >= 2 else { continue }
            let epName = parts[0].isEmpty ? "第\(index + 1)集" : parts[0]
            let epUrl = parts[1]
            guard !epName.isEmpty && epUrl.hasPrefix("http") else { continue }
            episodes.append(FuliEpisode(name: epName, url: epUrl))
        }

        return episodes
    }

    /// 判断名称是否像线路名（而非集数名）
    private func isLineName(_ name: String) -> Bool {
        let lineKeywords = ["线路", "高清", "超清", "蓝光", "标清", "备用", "极速", "流畅", "云播", "云视频",
                           "m3u8", "mp4", "ckm3u8", "kuyun", "zuidazy", "ok资源", "永久", "腾讯", "爱奇艺",
                           "优酷", "乐视", "pptv", "bilibili", "1080P", "720P", "4K", "专线"]
        for keyword in lineKeywords {
            if name.lowercased().contains(keyword.lowercased()) {
                return true
            }
        }
        return false
    }

    /// 判断名称是否像集数名
    private func isEpisodeName(_ name: String) -> Bool {
        // 第X集 / 第X话 / 第X章
        if name.range(of: "^第\\d+[集话章期回篇]", options: .regularExpression) != nil {
            return true
        }
        // 纯数字
        if name.range(of: "^\\d+$", options: .regularExpression) != nil {
            return true
        }
        // EP / E / S01E01 格式
        if name.range(of: "^[Ee][Pp]?\\d+", options: .regularExpression) != nil {
            return true
        }
        // 集 结尾
        if name.hasSuffix("集") || name.hasSuffix("话") || name.hasSuffix("章") {
            return true
        }
        return false
    }
}
