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
        items = []
        currentPage = 1
        hasMoreData = true
        errorMessage = nil

        currentTask = Task {
            await fetchPage(platform: platform, section: section)
        }
    }

    func loadMore(platform: WelfarePlatform, section: WelfareSection) {
        guard !isLoading, hasMoreData, currentTask?.isCancelled == false else { return }
        currentTask = Task {
            await fetchPage(platform: platform, section: section, append: true)
        }
    }

    private func fetchPage(platform: WelfarePlatform, section: WelfareSection, append: Bool = false) async {
        guard !Task.isCancelled else { return }
        isLoading = true

        let sectionKeyword = section.keyword.isEmpty ? section.name : section.keyword
        let keyword = "\(platform.searchPrefix) \(sectionKeyword)".trimmingCharacters(in: .whitespaces)

        var results: [VodItem] = []
        var seenIds = Set(append ? items.map(\.vodId) : [])

        let tagItems: ([VodItem]) -> [VodItem] = { batch in
            batch.map { item in
                var tagged = item
                if !(tagged.vodRemarks ?? "").hasPrefix("[福利]") {
                    tagged.vodRemarks = "[福利]" + (tagged.vodRemarks ?? "")
                }
                return tagged
            }
        }

        await withTaskGroup(of: [VodItem].self) { group in
            group.addTask {
                let yboxItems = await YBoxAPIService.shared.fetchPlatformContent(
                    platformId: platform.id,
                    pageType: section.id
                )
                return yboxItems
            }

            group.addTask {
                var spiderResults: [VodItem] = []
                await SpiderManager.shared.searchStream(
                    keyword: keyword,
                    onBatch: { batch in
                        guard !Task.isCancelled else { return }
                        let tagged = tagItems(batch)
                        spiderResults.append(contentsOf: tagged)
                    }
                )
                return spiderResults
            }

            for await batch in group {
                guard !Task.isCancelled else { return }
                let newItems = batch.filter { seenIds.insert($0.vodId).inserted }
                results.append(contentsOf: newItems)
            }
        }

        guard !Task.isCancelled else { return }

        if append {
            items.append(contentsOf: results)
        } else {
            items = results
        }

        hasMoreData = results.count >= pageSize / 2
        currentPage += 1
        isLoading = false

        if items.isEmpty {
            errorMessage = "暂无内容，请检查订阅源是否已配置"
        } else {
            errorMessage = nil
        }
    }
}
