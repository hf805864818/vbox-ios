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

    /// 加载指定平台 + 子分类的内容
    func loadContent(platform: WelfarePlatform, subcategory: WelfareSubCategory) {
        currentTask?.cancel()
        items = []
        currentPage = 1
        hasMoreData = true
        errorMessage = nil

        currentTask = Task {
            await fetchPage(platform: platform, subcategory: subcategory)
        }
    }

    /// 加载更多（分页）
    func loadMore(platform: WelfarePlatform, subcategory: WelfareSubCategory) {
        guard !isLoading, hasMoreData, currentTask?.isCancelled == false else { return }
        currentTask = Task {
            await fetchPage(platform: platform, subcategory: subcategory, append: true)
        }
    }

    private func fetchPage(platform: WelfarePlatform, subcategory: WelfareSubCategory, append: Bool = false) async {
        guard !Task.isCancelled else { return }
        isLoading = true

        // 构建搜索关键词：平台前缀 + 子分类关键词
        let keyword = "\(platform.searchPrefix) \(subcategory.keyword)".trimmingCharacters(in: .whitespaces)

        // 收集搜索结果
        var results: [VodItem] = []
        var seenIds = Set(append ? items.map(\.vodId) : [])

        await SpiderManager.shared.searchStream(
            keyword: keyword,
            onBatch: { batch in
                guard !Task.isCancelled else { return }
                let newItems = batch.filter { seenIds.insert($0.vodId).inserted }
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
