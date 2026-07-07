import SwiftUI
import Combine

@MainActor
class WelfareViewModel: ObservableObject {
    @Published var items: [VodItem] = []
    @Published var isLoading = false
    @Published var hasMoreData = true
    @Published var errorMessage: String?

    private var currentPage = 1
    private let pageSize = 30
    private var currentTask: Task<Void, Never>?

    func loadContent(platform: WelfarePlatform, section: WelfareSection,
                     pageKind: WelfarePageKind? = nil) {
        currentTask?.cancel()
        items = []; currentPage = 1; hasMoreData = true; errorMessage = nil
        currentTask = Task { await fetch(platform: platform, section: section, pageKind: pageKind) }
    }

    func loadMore(platform: WelfarePlatform, section: WelfareSection,
                  pageKind: WelfarePageKind? = nil) {
        guard !isLoading, hasMoreData, currentTask?.isCancelled == false else { return }
        currentTask = Task { await fetch(platform: platform, section: section, pageKind: pageKind, append: true) }
    }

    private func fetch(platform: WelfarePlatform, section: WelfareSection,
                       pageKind: WelfarePageKind? = nil, append: Bool = false) async {
        guard !Task.isCancelled else { return }
        isLoading = true

        // 优先使用传入的 pageKind，否则从 section.id 推断（向后兼容）
        let pageKind = pageKind ?? pageKindForSection(section.id)
        let keyword = section.keyword

        let fetchedItems = await WelfareCrawlerService.shared.fetch(
            platformId: platform.id,
            pageKind: pageKind,
            page: currentPage,
            sectionKeyword: keyword,
            onBatch: { batch in
                guard !Task.isCancelled else { return }
                // 过滤含关键词的（搜索型）或无过滤（列表型）
                let filtered = keyword.isEmpty ? batch : batch.filter {
                    $0.vodName.localizedCaseInsensitiveContains(keyword)
                }
                if !filtered.isEmpty {
                    Task { @MainActor in
                        if append { self.items.append(contentsOf: filtered) }
                        else { self.items = filtered }
                    }
                }
            }
        )

        guard !Task.isCancelled else { return }
        // 对最终结果同样应用关键词过滤
        let finalItems = keyword.isEmpty ? fetchedItems : fetchedItems.filter {
            $0.vodName.localizedCaseInsensitiveContains(keyword)
        }
        if !append { self.items = finalItems }
        hasMoreData = fetchedItems.count >= pageSize / 2
        currentPage += 1
        isLoading = false
        errorMessage = self.items.isEmpty ? "暂无内容。请尝试其他平台，或在「我的-订阅源」中配置搜索源" : nil
    }

    private func pageKindForSection(_ sectionId: String) -> WelfarePageKind {
        // section id 格式如 "c1"/"c2" 表示 home 分区，否则直接推断
        if sectionId.hasPrefix("c") { return .home }
        let mappings: [String: WelfarePageKind] = [
            "recommend": .home, "latest": .home, "hot": .home,
            "search": .search, "video": .video, "film": .film,
            "anime": .anime, "comic": .comic, "novel": .novel,
            "actor": .actor, "classify": .classify, "find": .find,
            "topic": .topic, "tiktok": .tiktok, "darkWeb": .darkWeb,
            "audio": .audio, "article": .article, "community": .community,
            "rank": .rank, "channel": .channel, "tag": .tag,
            "user": .user, "image": .image, "stills": .stills,
        ]
        // 直接尝试用 sectionId 作为 rawValue 匹配
        if let matched = WelfarePageKind(rawValue: sectionId) { return matched }
        return mappings[sectionId] ?? .home
    }
}
