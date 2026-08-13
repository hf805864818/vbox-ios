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
        let url = result.playUrl ?? result.url ?? ""
        let headers = result.header ?? [:]
        let parse = result.parse ?? 0
        return FuliPlayerResult(url: url, headers: headers, parse: parse)
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
    private func parseEpisodes(playFrom: String, playUrl: String) -> [FuliEpisode] {
        guard !playUrl.isEmpty else { return [] }

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
                let epName = parts[0]
                let epUrl = parts[1]

                let displayName = hasMultipleLines ? "[\(lineName)] \(epName)" : epName
                episodes.append(FuliEpisode(name: displayName, url: epUrl))
            }
        }

        return episodes
    }
}
