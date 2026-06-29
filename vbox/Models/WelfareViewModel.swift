import SwiftUI
import Combine

/// 福利专区 ViewModel — 管理内容加载与分页状态
@MainActor
class WelfareViewModel: ObservableObject {
    @Published var items: [VodItem] = []
    @Published var isLoading = false
    @Published var hasMoreData = true
    @Published var errorMessage: String?

    private var currentPage = 1
    private let pageSize = 30
    private var currentTask: Task<Void, Never>?

    /// 加载指定平台 + 分区的内容
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

    /// 加载更多（分页）
    func loadMore(platform: WelfarePlatform, section: WelfareSection) {
        guard !isLoading, hasMoreData, currentTask?.isCancelled == false else { return }
        currentTask = Task {
            await fetchPage(platform: platform, section: section, append: true)
        }
    }

    private func fetchPage(platform: WelfarePlatform, section: WelfareSection, append: Bool = false) async {
        guard !Task.isCancelled else { return }
        isLoading = true

        // 构建搜索关键词：平台前缀 + 分区关键词
        let sectionKeyword = section.keyword.isEmpty ? section.name : section.keyword
        let keyword = "\(platform.searchPrefix) \(sectionKeyword)".trimmingCharacters(in: .whitespaces)

        // 收集搜索结果
        var results: [VodItem] = []
        var seenIds = Set(append ? items.map(\.vodId) : [])

        await SpiderManager.shared.searchStream(
            keyword: keyword,
            onBatch: { batch in
                guard !Task.isCancelled else { return }
                // 标记福利来源，便于播放记录过滤
                let taggedItems = batch.map { item -> VodItem in
                    var tagged = item
                    if !(tagged.vodRemarks ?? "").hasPrefix("[福利]") {
                        tagged.vodRemarks = "[福利]" + (tagged.vodRemarks ?? "")
                    }
                    return tagged
                }
                let newItems = taggedItems.filter { seenIds.insert($0.vodId).inserted }
                results.append(contentsOf: newItems)
            }
        )

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
