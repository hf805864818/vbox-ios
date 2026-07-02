import SwiftUI

// MARK: - 豆瓣分类浏览视图（带筛选的大分类页面）
struct DoubanCategoryBrowserView: View {
    @StateObject private var viewModel = DoubanCategoryViewModel()
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    // 大分类标签
    @State private var selectedTab = 0
    private let tabs = ["电影", "剧集", "综艺", "动漫", "纪录片"]

    var body: some View {
        VStack(spacing: 0) {
            // 顶部分类标签栏
            categoryTabBar

            // 筛选器区域
            filterBar

            // 内容区域
            contentView
        }
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
        .task {
            await viewModel.loadData(reset: true)
        }
    }

    // MARK: - 分类标签栏
    private var categoryTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(0..<tabs.count, id: \.self) { index in
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTab = index
                        }
                        Task {
                            await switchToCategory(index: index)
                        }
                    }) {
                        VStack(spacing: 4) {
                            Text(tabs[index])
                                .font(.system(size: 15, weight: selectedTab == index ? .bold : .medium))
                                .foregroundColor(selectedTab == index ? .primary : .gray)

                            // 选中指示器
                            Rectangle()
                                .fill(selectedTab == index ? Color(hex: "E11D48") : Color.clear)
                                .frame(height: 3)
                                .cornerRadius(1.5)
                        }
                        .frame(width: 60)
                        .padding(.horizontal, 8)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color.gray.opacity(0.2)),
            alignment: .bottom
        )
    }

    // MARK: - 筛选栏
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // 类型筛选
                FilterChipView(
                    title: "类型",
                    options: viewModel.selectedCategory.filters.genres,
                    selection: Binding(
                        get: { viewModel.filters.genre ?? "全部" },
                        set: { newValue in
                            var newFilters = viewModel.filters
                            newFilters.genre = newValue
                            Task {
                                await viewModel.updateFilters(newFilters)
                            }
                        }
                    )
                )

                // 年代筛选
                FilterChipView(
                    title: "年代",
                    options: viewModel.selectedCategory.filters.years,
                    selection: Binding(
                        get: { viewModel.filters.year ?? "全部" },
                        set: { newValue in
                            var newFilters = viewModel.filters
                            newFilters.year = newValue
                            Task {
                                await viewModel.updateFilters(newFilters)
                            }
                        }
                    )
                )

                // 平台筛选
                FilterChipView(
                    title: "平台",
                    options: viewModel.selectedCategory.filters.platforms,
                    selection: Binding(
                        get: { viewModel.filters.platform ?? "全部" },
                        set: { newValue in
                            var newFilters = viewModel.filters
                            newFilters.platform = newValue
                            Task {
                                await viewModel.updateFilters(newFilters)
                            }
                        }
                    )
                )

                // 地区筛选
                FilterChipView(
                    title: "地区",
                    options: viewModel.selectedCategory.filters.regions,
                    selection: Binding(
                        get: { viewModel.filters.region ?? "全部" },
                        set: { newValue in
                            var newFilters = viewModel.filters
                            newFilters.region = newValue
                            Task {
                                await viewModel.updateFilters(newFilters)
                            }
                        }
                    )
                )

                // 排序筛选
                FilterChipView(
                    title: "排序",
                    options: DoubanFilterParams.SortType.allCases.map { $0.displayName },
                    selection: Binding(
                        get: { viewModel.filters.sort.displayName },
                        set: { newValue in
                            if let sortType = DoubanFilterParams.SortType.allCases.first(where: { $0.displayName == newValue }) {
                                var newFilters = viewModel.filters
                                newFilters.sort = sortType
                                Task {
                                    await viewModel.updateFilters(newFilters)
                                }
                            }
                        }
                    )
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
    }

    // MARK: - 内容区域
    private var contentView: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 16) {
                if viewModel.isLoading && viewModel.subjects.isEmpty {
                    LoadingPlaceholderView()
                        .padding(.top, 100)
                } else if let error = viewModel.errorMessage {
                    ErrorPlaceholderView(message: error) {
                        Task {
                            await viewModel.loadData(reset: true)
                        }
                    }
                    .padding(.top, 80)
                } else if viewModel.subjects.isEmpty {
                    EmptyPlaceholderView(categoryName: viewModel.selectedCategory.name)
                        .padding(.top, 100)
                } else {
                    // 内容网格
                    SubjectGridContentView(
                        subjects: viewModel.subjects,
                        settings: settings,
                        onLoadMore: {
                            Task {
                                await viewModel.loadMore()
                            }
                        }
                    )

                    if viewModel.isLoading && !viewModel.subjects.isEmpty {
                        ProgressView()
                            .padding()
                    }
                }
            }
        }
    }

    // MARK: - 切换分类
    private func switchToCategory(index: Int) async {
        let category: DoubanCategoryConfig
        switch index {
        case 0: category = .movie
        case 1: category = .tv
        case 2: category = .variety
        case 3: category = .animation
        case 4: category = .documentary
        default: category = .movie
        }
        await viewModel.switchCategory(category)
    }
}

// MARK: - 筛选芯片视图
struct FilterChipView: View {
    let title: String
    let options: [String]
    @Binding var selection: String
    @State private var showPicker = false

    var body: some View {
        Button(action: { showPicker = true }) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                Text(selection)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                Capsule()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .sheet(isPresented: $showPicker) {
            FilterPickerDetailView(title: "选择\(title)", options: options, selection: $selection)
        }
    }
}

// MARK: - 筛选选择器详情页
struct FilterPickerDetailView: View {
    let title: String
    let options: [String]
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(options, id: \.self) { option in
                    Button(action: {
                        selection = option
                        dismiss()
                    }) {
                        HStack {
                            Text(option)
                                .font(.system(size: 15))
                                .foregroundColor(.primary)
                            Spacer()
                            if option == selection {
                                Image(systemName: "checkmark")
                                    .foregroundColor(Color(hex: "E11D48"))
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 内容网格视图
struct SubjectGridContentView: View {
    let subjects: [DoubanSubject]
    let settings: AppSettings
    let onLoadMore: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(subjects) { subject in
                DoubanGridSubjectCell(subject: subject, settings: settings)
                    .onAppear {
                        // 当显示最后一个项目时加载更多
                        if subject.id == subjects.last?.id {
                            onLoadMore()
                        }
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - 豆瓣网格单元格（用于分类浏览）
struct DoubanGridSubjectCell: View {
    let subject: DoubanSubject
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 封面图
            ZStack(alignment: .topTrailing) {
                if let urlString = subject.coverImageURL,
                   let url = DoubanImageProxyServer.shared.proxiedURL(for: urlString) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure(_):
                            placeholderView
                        case .empty:
                            placeholderView
                        @unknown default:
                            placeholderView
                        }
                    }
                } else {
                    placeholderView
                }

                // 评分标签
                if subject.ratingValue > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.yellow)
                        Text(String(format: "%.1f", subject.ratingValue))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(4)
                    .padding(6)
                }
            }
            .aspectRatio(2/3, contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)

            // 标题
            Text(subject.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)

            // 副标题（年份/类型）
            if let year = subject.year, !year.isEmpty {
                Text(year)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
        }
        .onTapGesture {
            dismiss()
            settings.triggerSearch(subject.title)
        }
    }

    private var placeholderView: some View {
        ZStack {
            Rectangle()
                .fill(Color.gray.opacity(0.15))
            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.system(size: 30))
                    .foregroundColor(.gray.opacity(0.5))
                Text("暂无封面")
                    .font(.system(size: 10))
                    .foregroundColor(.gray.opacity(0.5))
            }
        }
    }
}

// MARK: - 加载占位视图
struct LoadingPlaceholderView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("加载中...")
                .font(.system(size: 14))
                .foregroundColor(.gray)
        }
    }
}

// MARK: - 错误占位视图
struct ErrorPlaceholderView: View {
    let message: String
    let retryAction: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundColor(.orange)

            Text("加载失败")
                .font(.system(size: 16, weight: .bold))

            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button(action: retryAction) {
                Text("重新加载")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color(hex: "E11D48"))
                    .cornerRadius(8)
            }
        }
    }
}

// MARK: - 空数据占位视图
struct EmptyPlaceholderView: View {
    let categoryName: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "film")
                .font(.system(size: 50))
                .foregroundColor(.gray.opacity(0.5))

            Text("暂无\(categoryName)内容")
                .font(.system(size: 14))
                .foregroundColor(.gray)
        }
    }
}
