import SwiftUI

// MARK: - Category Detail View (新版：带筛选器)
struct CategoryDetailView: View {
    let categoryType: String
    let categoryName: String
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var doubanService = DoubanService.shared
    @State private var subjects: [DoubanSubject] = []
    @State private var filteredSubjects: [DoubanSubject] = []
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var currentPage = 0
    @State private var hasMoreData = true
    private let pageSize = 20

    // 订阅源相关
    @State private var hasSubscription = false
    @State private var subscriptionSites: [SiteConfig] = []

    // 筛选状态
    @State private var selectedGenre: String = "全部"
    @State private var selectedYear: String = "全部"
    @State private var selectedSort: String = "热度"

    // 筛选选项
    private let genres = ["全部", "喜剧", "爱情", "动作", "悬疑", "科幻", "动画", "剧情", "恐怖", "犯罪", "冒险", "奇幻", "战争", "历史", "传记", "音乐", "家庭", "武侠", "古装", "真人秀", "脱口秀"]
    private let years = ["全部", "2026", "2025", "2024", "2023", "2022", "2021", "2020", "2019", "2018", "2017", "2010年代", "2000年代", "更早"]
    private let sorts = ["热度", "评分", "年份"]

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏
            HStack {
                Text(hasSubscription ? "\(categoryName) · 订阅源" : "找\(categoryName)")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // 筛选器区域（有订阅源时显示）
            if hasSubscription {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        FilterChip(title: "类型", options: genres, selection: $selectedGenre)
                        FilterChip(title: "年代", options: years, selection: $selectedYear)
                        FilterChip(title: "排序", options: sorts, selection: $selectedSort)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
                Divider()
                    .padding(.horizontal, 16)
            }

            // 内容区域
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 16) {
                    if isLoading && filteredSubjects.isEmpty {
                        CategoryLoadingView()
                    } else if let error = errorMessage {
                        CategoryErrorView(message: error, retryAction: loadData)
                    } else if filteredSubjects.isEmpty {
                        CategoryEmptyView(categoryName: categoryName)
                    } else {
                        SubjectGridView(
                            subjects: filteredSubjects,
                            settings: settings,
                            onLoadMore: loadMoreData
                        )

                        if isLoading && !filteredSubjects.isEmpty {
                            ProgressView()
                                .padding()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
        .onAppear {
            checkSubscription()
            loadData()
        }
        .onChange(of: selectedGenre) { _ in applyFilters() }
        .onChange(of: selectedYear) { _ in applyFilters() }
        .onChange(of: selectedSort) { _ in applyFilters() }
    }

    private func checkSubscription() {
        let spider = SpiderManager.shared
        let sub = spider.subManager
        hasSubscription = sub.isLoaded && !sub.allSites.isEmpty
    }

    private func loadData() {
        isLoading = true
        errorMessage = nil
        currentPage = 0
        hasMoreData = true
        subjects = []
        filteredSubjects = []

        Task {
            do {
                let newSubjects = try await fetchDataForCategory(start: 0, count: pageSize)
                await MainActor.run {
                    subjects = newSubjects
                    applyFilters()
                    hasMoreData = newSubjects.count == pageSize
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func loadMoreData() {
        guard !isLoading && hasMoreData else { return }

        isLoading = true
        currentPage += 1
        let start = currentPage * pageSize

        Task {
            do {
                let newSubjects = try await fetchDataForCategory(start: start, count: pageSize)
                await MainActor.run {
                    subjects.append(contentsOf: newSubjects)
                    applyFilters()
                    hasMoreData = newSubjects.count == pageSize
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }

    /// 获取分类关键词（用于订阅源搜索）
    private var categorySearchKeyword: String {
        switch categoryType {
        case "movie", "电影": return "电影"
        case "tv", "电视剧", "剧集": return "电视剧"
        case "variety", "综艺": return "综艺"
        case "animation", "动漫": return "动漫"
        case "documentary", "纪录片": return "纪录片"
        case "hot", "热门": return "热门"
        default: return categoryName
        }
    }

    private func applyFilters() {
        var result = subjects

        // 类型筛选
        if selectedGenre != "全部" {
            result = result.filter { subject in
                subject.genres?.contains(selectedGenre) ?? false
            }
        }

        // 年代筛选
        if selectedYear != "全部" {
            result = result.filter { subject in
                guard let year = subject.year else { return false }
                if selectedYear == "2010年代" {
                    return year >= "2010" && year < "2020"
                } else if selectedYear == "2000年代" {
                    return year >= "2000" && year < "2010"
                } else if selectedYear == "更早" {
                    return year < "2000"
                } else {
                    return year == selectedYear
                }
            }
        }

        // 排序
        switch selectedSort {
        case "评分":
            result.sort { $0.ratingValue > $1.ratingValue }
        case "年份":
            result.sort { ($0.year ?? "") > ($1.year ?? "") }
        default: // 热度 - 保持原始顺序
            break
        }

        filteredSubjects = result
    }

    private func fetchDataForCategory(start: Int, count: Int) async throws -> [DoubanSubject] {
        if hasSubscription {
            // 有订阅源时：通过 SpiderManager 搜索该分类关键词获取数据
            return try await fetchSubscriptionCategoryData(keyword: categorySearchKeyword, start: start, count: count)
        } else {
            // 无订阅源时：显示豆瓣默认数据
            switch categoryType {
            case "movie", "电影":
                return try await doubanService.fetchHotMovies(start: start, count: count)
            case "tv", "电视剧", "剧集":
                return try await doubanService.fetchHotTV(start: start, count: count)
            case "variety", "综艺":
                return try await doubanService.fetchHotVariety(start: start, count: count)
            case "top250", "榜单":
                return try await doubanService.fetchTop250(start: start, count: count)
            case "animation", "动漫":
                return try await doubanService.fetchHotAnimation(start: start, count: count)
            case "hot", "热门":
                return try await doubanService.fetchRecommendFeed(start: start, count: count)
            case "documentary", "纪录片":
                return try await doubanService.fetchHotMovies(start: start, count: count)
            case "live", "直播":
                return []
            case "music", "音乐":
                return try await doubanService.fetchHotMovies(start: start, count: count)
            case "sports", "体育":
                return try await doubanService.fetchHotMovies(start: start, count: count)
            default:
                return []
            }
        }
    }

    /// 通过订阅源分类接口获取数据（不是搜索）
    private func fetchSubscriptionCategoryData(keyword: String, start: Int, count: Int) async throws -> [DoubanSubject] {
        let spider = SpiderManager.shared
        
        // 映射 categoryType 到订阅源分类 typeId
        let categoryTypeId: String
        switch categoryType {
        case "movie", "电影": categoryTypeId = "movie"
        case "tv", "电视剧", "剧集": categoryTypeId = "tv"
        case "variety", "综艺": categoryTypeId = "variety"
        case "animation", "动漫": categoryTypeId = "anime"
        case "documentary", "纪录片": categoryTypeId = "documentary"
        case "hot", "热门": categoryTypeId = "hot"
        case "top250", "榜单": categoryTypeId = "top"
        case "live", "直播": categoryTypeId = "live"
        case "music", "音乐": categoryTypeId = "music"
        case "sports", "体育": categoryTypeId = "sports"
        default: categoryTypeId = categoryType
        }
        
        let items = await spider.fetchCategoryContent(categoryTypeId: categoryTypeId, page: (start / count) + 1)
        
        return items.map { item in
            DoubanSubject(
                id: item.vodId,
                title: item.vodName,
                cover_url: item.vodPic,
                rating: nil,
                year: item.vodYear,
                genres: nil,
                card_subtitle: item.vodRemarks,
                intro: nil,
                photos_gadget: nil,
                cover: nil
            )
        }
    }
}

// MARK: - Subscription Site Grid
struct SubscriptionSiteGrid: View {
    let sites: [SiteConfig]
    let settings: AppSettings

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Array(sites.enumerated()), id: \.offset) { _, site in
                Button(action: {
                    settings.triggerSearch(site.name)
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.blue)
                        Text(site.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .cornerRadius(10)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
}

// MARK: - Filter Chip
struct FilterChip: View {
    let title: String
    let options: [String]
    @Binding var selection: String
    @State private var showPicker = false

    var body: some View {
        Button(action: { showPicker = true }) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(selection)
                    .font(.system(size: 12, weight: .bold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemBackground))
            .cornerRadius(16)
        }
        .buttonStyle(PlainButtonStyle())
        .sheet(isPresented: $showPicker) {
            FilterPickerSheet(title: "选择\(title)", options: options, selection: $selection)
        }
    }
}

// MARK: - Filter Picker Sheet
struct FilterPickerSheet: View {
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
                                    .foregroundColor(.blue)
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

// MARK: - Loading View
struct CategoryLoadingView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading...")
                .font(.system(size: 14))
                .foregroundColor(.gray)
        }
        .padding(.top, 100)
    }
}

// MARK: - Error View
struct CategoryErrorView: View {
    let message: String
    let retryAction: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundColor(.orange)
            Text("Load Failed")
                .font(.system(size: 16, weight: .bold))
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
            Button(action: retryAction) {
                Text("Retry")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .cornerRadius(8)
            }
        }
        .padding(.top, 80)
    }
}

// MARK: - Empty View
struct CategoryEmptyView: View {
    let categoryName: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "film")
                .font(.system(size: 50))
                .foregroundColor(.gray.opacity(0.5))
            Text("No \(categoryName) content")
                .font(.system(size: 14))
                .foregroundColor(.gray)
        }
        .padding(.top, 100)
    }
}

// MARK: - Subject Grid View
struct SubjectGridView: View {
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
                GridSubjectCard(subject: subject, settings: settings)
                    .onAppear {
                        if subject.id == subjects.last?.id {
                            onLoadMore()
                        }
                    }
            }
        }
    }
}

// MARK: - Grid Subject Card
struct GridSubjectCard: View {
    let subject: DoubanSubject
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                CoverImageView(subject: subject)
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if subject.ratingValue > 0 {
                    RatingBadge(rating: subject.ratingValue)
                        .padding(4)
                }
            }

            Text(subject.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)

            if let year = subject.year {
                Text(year)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
        }
        .onTapGesture {
            settings.triggerSearch(subject.title)
        }
    }
}

// MARK: - Cover Image View
struct CoverImageView: View {
    let subject: DoubanSubject

    var body: some View {
        Group {
            if let url = DoubanImageProxyServer.shared.resolvedURL(for: subject.coverImageURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay(ProgressView().scaleEffect(0.8))
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay(Image(systemName: "photo").foregroundColor(.gray))
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay(Image(systemName: "photo").foregroundColor(.gray))
            }
        }
    }
}

// MARK: - Rating Badge
struct RatingBadge: View {
    let rating: Double

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "star.fill")
                .font(.system(size: 8))
                .foregroundColor(.yellow)
            Text(String(format: "%.1f", rating))
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.yellow)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color.black.opacity(0.6))
        .cornerRadius(4)
    }
}
