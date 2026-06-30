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

    func loadContent(platform: WelfarePlatform, section: WelfareSection) {
        currentTask?.cancel()
        items = []; currentPage = 1; hasMoreData = true; errorMessage = nil
        currentTask = Task { await fetch(platform: platform, section: section) }
    }

    func loadMore(platform: WelfarePlatform, section: WelfareSection) {
        guard !isLoading, hasMoreData, currentTask?.isCancelled == false else { return }
        currentTask = Task { await fetch(platform: platform, section: section, append: true) }
    }

    private func fetch(platform: WelfarePlatform, section: WelfareSection, append: Bool = false) async {
        guard !Task.isCancelled else { return }
        isLoading = true

        // 从 section 名称推断 pageKind
        let pageKind = pageKindForSection(section.id)
        let keyword = section.keyword.isEmpty ? section.name : section.keyword

        let items = await WelfareCrawlerService.shared.fetch(
            platformId: platform.id,
            pageKind: pageKind,
            page: currentPage,
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
        if !append { self.items = items }
        hasMoreData = items.count >= pageSize / 2
        currentPage += 1
        isLoading = false
        errorMessage = self.items.isEmpty ? "暂无内容，请检查订阅源是否已配置" : nil
    }

    private func pageKindForSection(_ sectionId: String) -> WelfarePageKind {
        // section id 格式如 "c1"/"c2" 表示 home 分区，否则直接推断
        if sectionId.hasPrefix("c") { return .home }
        let mappings: [String: WelfarePageKind] = [
            "recommend": .home, "latest": .home, "hot": .home,
            "all": .video, "video": .video, "film": .film,
            "anime": .anime, "comic": .comic, "novel": .novel,
            "actor": .actor, "classify": .classify, "find": .find,
            "topic": .topic, "tiktok": .tiktok, "darkWeb": .darkWeb,
            "audio": .audio, "article": .article, "community": .community,
            "rank": .rank, "channel": .channel, "tag": .tag,
            "user": .user, "image": .image, "stills": .stills,
        ]
        return mappings[sectionId] ?? .home
    }
}
