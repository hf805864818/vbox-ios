import SwiftUI

// MARK: - 二级分类页面 ViewModel
@MainActor
final class SangeCategoryViewModel: ObservableObject {
    @Published var bigCategories: [SangeBigCategory] = []
    @Published var selectedBig: SangeBigCategory?
    @Published var isLoading = true
    @Published var errorMsg: String?

    // 推荐分类数据（多个推荐分类，每个分类下有视频列表）
    @Published var recommendCategories: [SangeRecommendCategory] = []
    @Published var isLoadingRecommend = false
    @Published var recommendError: String?

    private let api = KXSPAPIService.shared
    private var hasLoaded = false

    func load(forceRefresh: Bool = false) {
        if hasLoaded && !forceRefresh { return }
        hasLoaded = true
        isLoading = true
        errorMsg = nil
        recommendError = nil

        Task {
            if !api.isConfigured {
                await api.setup(httpUrl: nil)
            }
            guard api.isConfigured else {
                await MainActor.run {
                    isLoading = false
                    errorMsg = api.lastError ?? "初始化失败"
                }
                return
            }

            do {
                async let categoriesTask = api.fetchVideoNavList()
                isLoadingRecommend = true
                async let recommendTask = api.fetchRecommendList(page: 1, pageSize: 10)

                let (categories, recommends) = try await (categoriesTask, recommendTask)
                await MainActor.run {
                    self.bigCategories = categories.isEmpty ? SangeBigCategory.samples : categories
                    self.selectedBig = self.bigCategories.first
                    self.recommendCategories = recommends
                    self.isLoading = false
                    self.isLoadingRecommend = false
                }
            } catch {
                await MainActor.run {
                    self.bigCategories = SangeBigCategory.samples
                    self.selectedBig = self.bigCategories.first
                    self.isLoading = false
                    self.isLoadingRecommend = false
                    self.errorMsg = error.localizedDescription
                    self.recommendError = error.localizedDescription
                }
            }
        }
    }

    /// 重新加载推荐（切换分类时调用）
    func refreshRecommend() {
        guard let selected = selectedBig,
              (selected.navType == .video || selected.navType == .shortVideo) else {
            return
        }
        guard !isLoadingRecommend else { return }

        isLoadingRecommend = true
        recommendError = nil

        Task {
            do {
                let recommends = try await api.fetchRecommendList(page: 1, pageSize: 10)
                await MainActor.run {
                    self.recommendCategories = recommends
                    self.isLoadingRecommend = false
                }
            } catch {
                await MainActor.run {
                    self.isLoadingRecommend = false
                    self.recommendError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - 二级分类页面
struct SangeCategoryView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var viewModel = SangeCategoryViewModel()

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    /// 当前选中的大分类是否为视频/短视频类型（决定是否显示推荐区）
    private var shouldShowRecommend: Bool {
        guard let selected = viewModel.selectedBig else { return false }
        return selected.navType == .video || selected.navType == .shortVideo
    }

    var body: some View {
        VStack(spacing: 0) {
            bigCategoryTabBar

            if viewModel.isLoading {
                Spacer()
                ProgressView("加载中...")
                Spacer()
            } else if let error = viewModel.errorMsg, viewModel.bigCategories.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    Text(error)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        viewModel.load(forceRefresh: true)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text("重新加载")
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                    }
                }
                .padding(.horizontal, 32)
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 24) {
                        // 推荐分类（仅视频/短视频分类显示）
                        if shouldShowRecommend {
                            if viewModel.isLoadingRecommend && viewModel.recommendCategories.isEmpty {
                                recommendLoadingView
                            } else if !viewModel.recommendCategories.isEmpty {
                                ForEach(viewModel.recommendCategories) { recCategory in
                                    recommendSection(category: recCategory)
                                }
                            }
                        }

                        // 小分类网格
                        subCategoryGrid
                    }
                    .padding(.bottom, 20)
                }
                .refreshable {
                    viewModel.load(forceRefresh: true)
                }
            }
        }
        .background(Color.clear)
        .navigationTitle("三更")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear { viewModel.load() }
    }

    // MARK: 顶部大分类 Tab
    private var bigCategoryTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.bigCategories) { category in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.selectedBig = category
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: category.navType.icon)
                                .font(.system(size: 12))
                            Text(category.name)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(viewModel.selectedBig?.id == category.id ? accentColor : Color.clear)
                        .foregroundColor(viewModel.selectedBig?.id == category.id ? .white : textColor)
                        .cornerRadius(20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(accentColor.opacity(0.4),
                                        lineWidth: viewModel.selectedBig?.id == category.id ? 0 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color.clear)
    }

    // MARK: 推荐加载占位
    private var recommendLoadingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(accentColor)
                Text("推荐")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(textColor)
                Spacer()
                ProgressView()
                    .scaleEffect(0.8)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(0..<5, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.gray.opacity(0.15))
                            .frame(width: 200, height: 112)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: 推荐分类区块
    private func recommendSection(category: SangeRecommendCategory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(accentColor)
                Text(category.recName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(textColor)
                Spacer()
            }
            .padding(.horizontal, 16)

            // 横向滚动卡片
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(category.videoList) { item in
                        NavigationLink(destination: SangeVideoDetailWrapperView(item: item)) {
                            recommendCard(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: 推荐卡片（横版）
    private func recommendCard(item: SangeVideoItem) -> some View {
        let coverUrl = item.cover
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: URL(string: coverUrl)) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else if phase.error != nil {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .overlay(Image(systemName: "photo").foregroundColor(.gray.opacity(0.6)))
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.15))
                            .overlay(ProgressView())
                    }
                }
                .frame(width: 200, height: 112) // 16:9 横版
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )

                // 时长
                if let duration = item.duration, !duration.isEmpty {
                    Text(duration)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.75))
                        .foregroundColor(.white)
                        .cornerRadius(4)
                        .padding(6)
                }
            }

            // 标题
            Text(item.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(textColor)
                .lineLimit(2)
                .frame(width: 200, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    // MARK: 小分类网格
    private var subCategoryGrid: some View {
        let subs = viewModel.selectedBig?.subCategories ?? []
        return VStack(alignment: .leading, spacing: 12) {
            // 分类标题
            HStack(spacing: 6) {
                Image(systemName: viewModel.selectedBig?.navType.icon ?? "square.grid.2x2")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(accentColor)
                Text(viewModel.selectedBig?.name ?? "分类")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(textColor)
                Spacer()
                if let count = viewModel.selectedBig?.subCategories.count, count > 0 {
                    Text("\(count) 个")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)

            if subs.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("暂无子分类")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(subs) { sub in
                        NavigationLink(destination: SangeListView(
                            bigCategory: viewModel.selectedBig ?? SangeBigCategory(dict: [:]),
                            subCategory: sub
                        )) {
                            subCategoryCard(sub: sub)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: 小分类卡片
    private func subCategoryCard(sub: SangeSubCategory) -> some View {
        VStack(spacing: 8) {
            // 如果有分类封面图，优先展示；否则展示图标
            if let cover = sub.cover, !cover.isEmpty,
               let url = URL(string: KXSPAPIService.shared.fullImageUrl(cover)) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: iconFor(sub: sub))
                            .font(.system(size: 24))
                            .foregroundColor(accentColor)
                    }
                }
                .frame(width: 36, height: 36)
            } else {
                Image(systemName: iconFor(sub: sub))
                    .font(.system(size: 24))
                    .foregroundColor(accentColor)
            }

            Text(sub.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(textColor)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 90)
        .background(Color.clear)
        .cornerRadius(12)
    }

    private func iconFor(sub: SangeSubCategory) -> String {
        switch sub.parentType {
        case .video: return "play.rectangle.fill"
        case .shortVideo: return "play.square.stack.fill"
        case .comic: return "book.fill"
        case .novel: return "text.book.closed.fill"
        }
    }

    private var accentColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }

    private var textColor: Color {
        settings.usesVisualSkin ? .white : Color(uiColor: .label)
    }

    private var backgroundColor: Color {
        settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemGroupedBackground)
    }
}
