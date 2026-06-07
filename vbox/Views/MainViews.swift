import SwiftUI

// vbox 主入口在 App/VBoxApp.swift

// 主标签视图
struct MainTabView: View {
    @State private var selectedTab = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            // 主内容
            TabView(selection: $selectedTab) {
                HomeView()
                    .tabItem {
                        Image(systemName: selectedTab == 0 ? "house.fill" : "house")
                        Text("首页")
                    }
                    .tag(0)

                DoubanHomeView()
                    .tabItem {
                        Image(systemName: selectedTab == 1 ? "film.fill" : "film")
                        Text("豆瓣")
                    }
                    .tag(1)

                SearchView()
                    .tabItem {
                        Image(systemName: selectedTab == 2 ? "magnifyingglass.circle.fill" : "magnifyingglass.circle")
                        Text("搜索")
                    }
                    .tag(2)

                CategoryView()
                    .tabItem {
                        Image(systemName: selectedTab == 3 ? "square.grid.3x3.fill" : "square.grid.3x3")
                        Text("分类")
                    }
                    .tag(3)

                ProfileView()
                    .tabItem {
                        Image(systemName: selectedTab == 4 ? "person.fill" : "person")
                        Text("我的")
                    }
                    .tag(4)
            }
            .accentColor(Color(hex: "E11D48"))

            // 底部毛玻璃导航栏
            GlassBottomTabBar(selectedTab: $selectedTab)
        }
        .ignoresSafeArea(.keyboard)
    }
}

// 毛玻璃底部导航栏
struct GlassBottomTabBar: View {
    @Binding var selectedTab: Int

    private let tabs: [(icon: String, iconFilled: String, title: String)] = [
        ("house", "house.fill", "首页"),
        ("film", "film.fill", "豆瓣"),
        ("magnifyingglass.circle", "magnifyingglass.circle.fill", "搜索"),
        ("square.grid.3x3", "square.grid.3x3.fill", "分类"),
        ("person", "person.fill", "我的")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<tabs.count, id: \.self) { index in
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selectedTab = index
                    }
                }) {
                    VStack(spacing: 4) {
                        ZStack {
                            if selectedTab == index {
                                // 液态背景效果
                                LiquidBackground()
                                    .frame(width: 44, height: 44)
                                    .blur(radius: 8)
                            }

                            Image(systemName: selectedTab == index ? tabs[index].iconFilled : tabs[index].icon)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(selectedTab == index ? Color(hex: "E11D48") : .secondary)
                        }
                        .frame(height: 44)

                        Text(tabs[index].title)
                            .font(.system(size: 10, weight: selectedTab == index ? .semibold : .regular))
                            .foregroundColor(
                                selectedTab == index
                                    ? Color(hex: "E11D48")
                                    : Color.secondary
                            )
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            // 毛玻璃效果
            ZStack {
                Color.black.opacity(0.8)

                // 液态渐变背景
                LinearGradient(
                    colors: [
                        Color(hex: "0F0F23").opacity(0.9),
                        Color(hex: "1E1B4B").opacity(0.9)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay(
                // 顶部高光线
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.1),
                                Color.white.opacity(0.0),
                                Color.white.opacity(0.0),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 1),
                alignment: .top
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}

// 液态背景效果
struct LiquidBackground: View {
    @State private var phase: Double = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 动态流动的渐变
                ForEach(0..<3) { index in
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(hex: "E11D48").opacity(0.3),
                                    Color(hex: "F43F5E").opacity(0.2),
                                    Color(hex: "7C3AED").opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 60, height: 60)
                        .offset(
                            x: CGFloat(phase + Double(index) * 2.0).truncatingRemainder(dividingBy: 10) - 5,
                            y: CGFloat(cos(phase * 2 + Double(index))).truncatingRemainder(dividingBy: 10) - 5
                        )
                        .blur(radius: 12)
                }
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: true)) {
                phase = 10
            }
        }
    }
}

// MARK: - 首页视图（豆瓣推荐）
struct HomeView: View {
    @StateObject private var doubanService = DoubanService.shared
    @EnvironmentObject private var settings: AppSettings
    @State private var isLoading = true
    @State private var bannerSubjects: [DoubanSubject] = []
    @State private var hotMovies: [DoubanSubject] = []
    @State private var hotTV: [DoubanSubject] = []
    @State private var hotVariety: [DoubanSubject] = []
    @State private var top250: [DoubanSubject] = []
    @State private var currentIndex = 0

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                if isLoading {
                    VStack(spacing: 20) {
                        ProgressView().scaleEffect(1.5).padding(.top, 100)
                        Text("正在加载...").font(.system(size: 14)).foregroundColor(.secondary)
                    }
                } else {
                    if !bannerSubjects.isEmpty {
                        BannerCarousel(subjects: bannerSubjects, currentIndex: $currentIndex)
                    }
                    CategoryTilesView()
                    if !hotMovies.isEmpty {
                        SectionHeader(title: "热门电影", icon: "flame.fill")
                        HorizontalSubjectRow(subjects: hotMovies)
                    }
                    if !top250.isEmpty {
                        SectionHeader(title: "TOP250", icon: "crown.fill")
                        HorizontalSubjectRow(subjects: top250)
                    }
                    if !hotTV.isEmpty {
                        SectionHeader(title: "热门剧集", icon: "tv.fill")
                        HorizontalSubjectRow(subjects: hotTV)
                    }
                    if !hotVariety.isEmpty {
                        SectionHeader(title: "热门综艺", icon: "theatermasks.fill")
                        HorizontalSubjectRow(subjects: hotVariety)
                    }
                }
            }
            .padding(.bottom, 100)
        }
        .background(Color.white)
        .onAppear { loadData() }
    }

    private func loadData() {
        isLoading = true
        Task {
            do {
                async let banner = doubanService.fetchTop250(start: 0, count: 10)
                async let movies = doubanService.fetchHotMovies(start: 0, count: 10)
                async let tv = doubanService.fetchHotTV(start: 0, count: 10)
                async let variety = doubanService.fetchHotVariety(start: 0, count: 10)
                async let top = doubanService.fetchTop250(start: 0, count: 10)
                bannerSubjects = try await banner
                hotMovies = try await movies
                hotTV = try await tv
                hotVariety = try await variety
                top250 = try await top
            } catch {
                print("Douban API error: \(error)")
            }
            isLoading = false
        }
    }
}

// 搜索栏头部
struct SearchBarHeader: View {
    @State private var searchText = ""
    var onSearch: ((String) -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            // 搜索输入框
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Color.secondary)

                TextField("搜索视频...", text: $searchText)
                    .foregroundColor(.primary)
                    .onSubmit { submit() }
                    .submitLabel(.search)

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.2), Color.white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )

            // 搜索按钮
            Button(action: { submit() }) {
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(Color(hex: "E11D48"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [Color(hex: "0F0F23").opacity(0.95), Color(hex: "000000").opacity(0.98)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func submit() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        onSearch?(q)
    }
}

// 推荐轮播
struct FeaturedCarousel: View {
    let videos: [VodItem]
    @State private var currentIndex = 0

    var body: some View {
        TabView(selection: $currentIndex) {
            ForEach(0..<min(5, videos.count), id: \.self) { index in
                FeaturedCard(video: videos[index])
                    .tag(index)
            }
        }
        .frame(height: 200)
        .tabViewStyle(.page(indexDisplayMode: .never))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

        if !videos.isEmpty {
            HStack(spacing: 8) {
                ForEach(0..<min(5, videos.count), id: \.self) { index in
                    Circle()
                        .fill(currentIndex == index ? Color(hex: "E11D48") : Color.white.opacity(0.3))
                        .frame(width: currentIndex == index ? 8 : 6, height: currentIndex == index ? 8 : 6)
                        .animation(.spring(response: 0.3), value: currentIndex)
                }
            }
            .padding(.bottom, 8)
        }
    }
}

// 推荐卡片
struct FeaturedCard: View {
    let video: VodItem
    @State private var showDetail = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 封面图片
            AsyncImage(url: URL(string: video.vodPic)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure(_):
                    ZStack {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.title)
                                .foregroundColor(.gray)
                            Text("封面加载失败")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                case .empty:
                    ZStack {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                        ProgressView()
                    }
                @unknown default:
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                }
            }
            .frame(width: UIScreen.main.bounds.width - 32, height: 200)
            .clipped()

            // 渐变遮罩
            LinearGradient(
                colors: [
                    Color.black.opacity(0.0),
                    Color.black.opacity(0.6),
                    Color.black.opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // 信息内容
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(video.vodName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Spacer()

                    // 播放按钮
                    Button(action: { showDetail = true }) {
                        ZStack {
                            Circle()
                                .fill(Color(hex: "E11D48"))

                            Image(systemName: "play.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .frame(width: 44, height: 44)
                    }
                }

                HStack(spacing: 8) {
                    Label(video.vodYear ?? "", systemImage: "calendar")
                    Label(video.vodRemarks ?? "", systemImage: "film")
                }
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.8))
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.15),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .onTapGesture { showDetail = true }
        .fullScreenCover(isPresented: $showDetail) {
            VideoDetailView(video: video)
        }
    }
}

// 视频卡片
struct VideoCard: View {
    let video: VodItem
    @State private var showDetail = false

    var body: some View {
        Button(action: { showDetail = true }) {
            VStack(alignment: .leading, spacing: 10) {
                // 封面
                ZStack(alignment: .topTrailing) {
                    AsyncImage(url: URL(string: video.vodPic)) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure(_):
                            ZStack {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.25))
                                VStack(spacing: 8) {
                                    Image(systemName: "photo")
                                        .font(.title2)
                                        .foregroundColor(.gray)
                                    Text("加载失败")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        case .empty:
                            ZStack {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.15))
                                ProgressView()
                            }
                        @unknown default:
                            Rectangle()
                                .fill(Color.gray.opacity(0.25))
                        }
                    }
                    .frame(height: 140)
                    .clipped()

                    // 播放时长
                    Text(video.vodRemarks ?? "")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.7))
                        )
                        .padding(8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                // 标题和信息
                VStack(alignment: .leading, spacing: 6) {
                    Text(video.vodName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 8) {
                        Text(video.vodRemarks ?? "")
                            .font(.system(size: 11))
                            .foregroundColor(Color.secondary)

                        Text("•")
                            .font(.system(size: 11))
                            .foregroundColor(Color.secondary)

                        Text(video.vodYear ?? "")
                            .font(.system(size: 11))
                            .foregroundColor(Color.secondary)
                    }
                }
            }
            .padding(12)
            .background(
                // 毛玻璃卡片背景
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.black.opacity(0.2))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.1),
                                Color.white.opacity(0.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
        }
            .buttonStyle(PlainButtonStyle())
            .fullScreenCover(isPresented: $showDetail) {
                VideoDetailView(video: video)
            }
    }
}

// 分区头部
struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.black)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - 搜索视图
struct SearchView: View {
    @StateObject private var spiderManager = SpiderManager.shared
    @EnvironmentObject private var settings: AppSettings
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var searchResults: [VodItem] = []
    @State private var isSearchLoading = false

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(searchText: $searchText, isSearching: $isSearching, onSearch: { performSearch() })

            ZStack {
                if isSearching {
                    searchContentView
                        .transition(.opacity)
                } else {
                    defaultContentView
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isSearching)
        }
        .background(Color(hex: "000000"))
        .onChange(of: settings.searchQuery) { query in
            guard !query.isEmpty else { return }
            searchText = query
            searchResults = []
            isSearchLoading = true
            performSearch()
        }
    }

    @ViewBuilder
    private var searchContentView: some View {
        if !searchResults.isEmpty {
            SearchResultsView(results: searchResults)
        } else if isSearchLoading {
            VStack(spacing: 20) {
                ProgressView().scaleEffect(1.5).padding(.top, 80)
                Text("搜索中...").font(.system(size: 14)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 20) {
                Image(systemName: "magnifyingglass").font(.system(size: 40)).foregroundColor(.gray).padding(.top, 80)
                Text("未找到结果").font(.system(size: 16)).foregroundColor(.secondary)
                if spiderManager.loadedSiteCount > 0 {
                    Text("已加载 " + String(spiderManager.loadedSiteCount) + " 个站点").font(.system(size: 13)).foregroundColor(.orange)
                }
                if let err = spiderManager.engineError {
                    Text("引擎错误: " + err).font(.system(size: 12)).foregroundColor(.red).padding(.horizontal, 16)
                }
                if spiderManager.enginesCount > 0 {
                    Text("蜘蛛引擎: " + String(spiderManager.enginesCount)).font(.system(size: 12)).foregroundColor(.green)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var defaultContentView: some View {
        if !spiderManager.allSites.isEmpty {
            ScrollView {
                LazyVStack(spacing: 6) {
                    SectionHeader(title: "全部站点 (" + String(spiderManager.loadedSiteCount) + ")", icon: "list.star")
                        .padding(.top, 8)
                    ForEach(spiderManager.allSites, id: \.key) { site in
                        SiteRow(site: site)
                    }
                }
                .padding(.bottom, 100)
            }
        } else {
            SearchSuggestionsView()
        }
    }

    private func performSearch() {
        guard !searchText.isEmpty else { return }
        isSearching = true
        isSearchLoading = true
        searchResults = []
        let keyword = searchText
        var seen = Set<String>()
        print("[SearchView] 开始搜索: \(keyword)")

        Task {
            // 路1: 流式切片搜索
            async let streamingTask: Void = {
                await self.spiderManager.searchStream(keyword: keyword) { batch in
                    var newItems: [VodItem] = []
                    for item in batch {
                        let id = item.vodId.isEmpty ? item.vodName : item.vodId
                        if seen.insert(id).inserted {
                            newItems.append(item)
                        }
                    }
                    if !newItems.isEmpty {
                        print("[SearchView] 流式回调 +\(newItems.count) 条，累计 \(seen.count) 条")
                        Task { @MainActor in
                            self.searchResults.append(contentsOf: newItems)
                            self.isSearchLoading = false
                        }
                    }
                }
            }()

            // 路2: 网盘资源搜索
            async let cloudTask: Void = {
                let cloudItems = await self.spiderManager.cloudSearch(keyword: keyword)
                var newItems: [VodItem] = []
                for var item in cloudItems {
                    let id = item.vodId.isEmpty ? item.vodName : item.vodId
                    if seen.insert(id).inserted {
                        item.vodRemarks = "☁️" + (item.vodRemarks ?? "网盘")
                        newItems.append(item)
                    }
                }
                if !newItems.isEmpty {
                    print("[SearchView] 网盘回调 +\(newItems.count) 条")
                    await MainActor.run {
                        self.searchResults.append(contentsOf: newItems)
                        self.isSearchLoading = false
                    }
                }
            }()

            _ = await (streamingTask, cloudTask)
            print("[SearchView] 搜索结束，共 \(seen.count) 条")
            await MainActor.run { self.isSearchLoading = false }
        }
    }
}

// 搜索栏
struct SearchBar: View {
    @Binding var searchText: String
    @Binding var isSearching: Bool
    var onSearch: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            // 搜索输入框
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Color.secondary)

                TextField("搜索视频、剧集...", text: $searchText)
                    .foregroundColor(.primary)
                    .onSubmit {
                        performSearch()
                    }

                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                        isSearching = false
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.2),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )

            // 取消按钮
            if isSearching {
                Button("取消") {
                    searchText = ""
                    isSearching = false
                    UIApplication.shared.endEditing()
                }
                .foregroundColor(Color(hex: "E11D48"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [
                    Color(hex: "0F0F23").opacity(0.95),
                    Color(hex: "000000").opacity(0.98)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func performSearch() {
        guard !searchText.isEmpty else { return }
        onSearch?()
    }
}

// 搜索建议视图
struct SearchSuggestionsView: View {
    private let hotSearches = ["三体", "狂飙", "庆余年", "繁花", "肖申克的救赎"]
    private let recentSearches = ["黑袍纠察队", "权力的游戏", "绝命毒师"]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                // 热门搜索
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "flame.fill")
                            .foregroundColor(Color(hex: "E11D48"))
                        Text("热门搜索")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                    }

                    FlowLayout(spacing: 10) {
                        ForEach(hotSearches, id: \.self) { keyword in
                            KeywordButton(keyword: keyword)
                        }
                    }
                }
                .padding(.horizontal, 16)

                // 最近搜索
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "clock.fill")
                            .foregroundColor(Color(hex: "E11D48"))
                        Text("最近搜索")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                    }

                    ForEach(recentSearches, id: \.self) { keyword in
                        RecentSearchRow(keyword: keyword)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 20)
        }
    }
}

// 关键词按钮
struct KeywordButton: View {
    let keyword: String

    var body: some View {
        Button(action: {}) {
            Text(keyword)
                .font(.system(size: 14))
                .foregroundColor(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.2))
                )
                .overlay(
                    Capsule()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.15),
                                    Color.white.opacity(0.0)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// 最近搜索行
struct RecentSearchRow: View {
    let keyword: String

    var body: some View {
        HStack {
            Text(keyword)
                .font(.system(size: 15))
                .foregroundColor(.primary)

            Spacer()

            Button(action: {}) {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
                    .foregroundColor(Color.secondary)
            }
        }
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
        )
    }
}

// 搜索结果视图 — 双栏布局：左边站点列表 + 右边封面详情
struct SearchResultsView: View {
    let results: [VodItem]
    @State private var selectedSource: String? = nil
    @State private var selectedVideo: VodItem? = nil

    /// 按站点来源分组（来自 vodRemarks）
    private var grouped: [(source: String, videos: [VodItem])] {
        var dict: [String: [VodItem]] = [:]
        for video in results {
            let source = video.vodRemarks?.isEmpty == false ? video.vodRemarks ?? "" : "搜索结果"
            if dict[source] == nil {
                dict[source] = []
            }
            dict[source]?.append(video)
        }
        // 转换为数组并按视频数量排序
        return dict.map { (source: $0.key, videos: $0.value) }
            .sorted { $0.videos.count > $1.videos.count }
    }

    private var sources: [String] { grouped.map { $0.source } }
    private var currentVideos: [VodItem] {
        let sel = selectedSource ?? sources.first ?? ""
        return grouped.first(where: { $0.source == sel })?.videos ?? []
    }

    var body: some View {
        Group {
            if grouped.count <= 1 {
                singleColumnList(results)
            } else {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        // 左侧：站点列表 - 响应式宽度
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 2) {
                                ForEach(sources, id: \.self) { name in
                                    let sel = (selectedSource ?? sources.first ?? "") == name
                                    Button(action: { selectedSource = name }) {
                                        Text(name)
                                            .font(.system(size: 13, weight: sel ? .bold : .regular))
                                            .foregroundColor(sel ? .white : .gray)
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, 11)
                                            .padding(.horizontal, 10)
                                            .background(sel ? Color.blue.opacity(0.2) : Color.clear)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(width: min(110, geometry.size.width * 0.25))
                        .background(Color(hex: "1A1A2E"))

                        Divider().background(Color.white.opacity(0.1))

                        // 右侧：视频列表
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 12) {
                                ForEach(currentVideos) { item in
                                    SearchResultRow(video: item)
                                        .onTapGesture {
                                            selectedVideo = item
                                        }
                                }
                            }
                            .padding(12)
                        }
                    }
                }
                .fullScreenCover(item: $selectedVideo) { video in
                    VideoDetailView(video: video)
                }
                .onAppear {
                    if selectedSource == nil { selectedSource = sources.first }
                }
            }
        }
    }

    private func singleColumnList(_ items: [VodItem]) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 12) {
                ForEach(items) { item in
                    SearchResultRow(video: item)
                        .onTapGesture {
                            selectedVideo = item
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .fullScreenCover(item: $selectedVideo) { video in
            VideoDetailView(video: video)
        }
    }
}

// 搜索结果行 — 封面 + 详情标签
struct SearchResultRow: View {
    let video: VodItem

    var body: some View {
        HStack(spacing: 12) {
                // 封面图
                AsyncImage(url: URL(string: video.vodPic)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure(_):
                        ZStack {
                            Rectangle().fill(Color.gray.opacity(0.25))
                            VStack(spacing: 6) {
                                Image(systemName: "film").font(.title2).foregroundColor(.gray)
                                Text("加载失败").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    case .empty:
                        ZStack {
                            Rectangle().fill(Color.gray.opacity(0.15))
                            ProgressView()
                        }
                    @unknown default:
                        Rectangle().fill(Color.gray.opacity(0.25))
                    }
                }
                .frame(width: 85, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // 详情
                VStack(alignment: .leading, spacing: 5) {
                    Text(video.vodName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)

                    // 标签
                    HStack(spacing: 5) {
                        if let r = video.vodRemarks, !r.isEmpty {
                            TagBadge(text: r)
                        }
                        if let y = video.vodYear, !y.isEmpty {
                            TagBadge(text: y)
                        }
                        if let a = video.vodArea, !a.isEmpty {
                            TagBadge(text: a)
                        }
                    }

                    if let d = video.vodDirector, !d.isEmpty {
                        Text("导演: \(d)").font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                    }
                    if let a = video.vodActor, !a.isEmpty {
                        Text("主演: \(a)").font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                    }

                    Spacer()
                }

                Spacer()

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(Color(hex: "E11D48"))
            }
            .padding(10)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// 标签徽章
struct TagBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.blue)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.blue.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

// MARK: - 分类视图
struct CategoryView: View {
    private let categories = [
        ("电影", "film.fill"),
        ("电视剧", "tv.fill"),
        ("综艺", "mic.fill"),
        ("动漫", "sparkles"),
        ("纪录片", "book.fill"),
        ("直播", "dot.radiowaves.left.and.right"),
        ("音乐", "music.note"),
        ("体育", "sportscourt.fill")
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ],
                spacing: 16
            ) {
                ForEach(categories, id: \.0) { category in
                    CategoryCard(name: category.0, icon: category.1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(Color(hex: "000000"))
    }
}

// 分类卡片
struct CategoryCard: View {
    let name: String
    let icon: String

    var body: some View {
        Button(action: {}) {
            VStack(spacing: 12) {
                ZStack {
                    // 液态背景
                    LiquidBackground()
                        .frame(width: 60, height: 60)
                        .blur(radius: 10)

                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(hex: "E11D48"), Color(hex: "F43F5E")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .frame(width: 60, height: 60)

                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.black.opacity(0.2))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.1),
                                Color.white.opacity(0.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 个人中心视图
struct ProfileView: View {
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // 用户信息
                UserInfoSection()

                // 功能列表
                VStack(spacing: 1) {
                    ProfileMenuItem(icon: "heart.fill", title: "我的收藏", badge: "12")
                    ProfileMenuItem(icon: "clock.fill", title: "观看历史")
                    ProfileMenuItem(icon: "arrow.down.circle.fill", title: "下载管理")
                    ProfileMenuItem(icon: "globe", title: "云盘播放")
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 20)

                VStack(spacing: 1) {
                    ProfileMenuItem(icon: "gearshape.fill", title: "设置")
                    ProfileMenuItem(icon: "info.circle.fill", title: "关于")
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .padding(.bottom, 100)
        }
        .background(Color(hex: "000000"))
    }
}

// 用户信息区域
struct UserInfoSection: View {
    var body: some View {
        VStack(spacing: 16) {
            // 头像
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "E11D48"), Color(hex: "F43F5E")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)

                Image(systemName: "person.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.white)
            }
            .overlay(
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.2),
                                Color.white.opacity(0.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 3
                    )
            )

            Text("访客用户")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)

            Text("登录后同步收藏和历史记录")
                .font(.system(size: 13))
                .foregroundColor(Color.secondary)

            // 登录按钮
            Button(action: {}) {
                Text("立即登录")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "E11D48"), Color(hex: "F43F5E")],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
            }
            .padding(.horizontal, 40)
        }
        .padding(.top, 30)
        .padding(.bottom, 20)
    }
}

// 个人中心菜单项
struct ProfileMenuItem: View {
    let icon: String
    let title: String
    let badge: String?

    init(icon: String, title: String, badge: String? = nil) {
        self.icon = icon
        self.title = title
        self.badge = badge
    }

    var body: some View {
        Button(action: {}) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(Color(hex: "E11D48"))
                    .frame(width: 32)

                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)

                Spacer()

                if let badge = badge {
                    Text(badge)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color(hex: "E11D48"))
                        )
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundColor(Color.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                Color.primary.opacity(0.05)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}


// MARK: - 数据模型
// Mock数据
let mockVideos: [VodItem] = [
    VodItem(vodId: "test_001", vodName: "三体", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_002", vodName: "狂飙", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_003", vodName: "庆余年", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_004", vodName: "繁花", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_005", vodName: "肖申克的救赎", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_006", vodName: "黑袍纠察队", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_007", vodName: "权力的游戏", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_008", vodName: "绝命毒师", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_009", vodName: "复仇者联盟", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_010", vodName: "泰坦尼克号", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_011", vodName: "盗梦空间", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_012", vodName: "星际穿越", vodPic: "https://via.placeholder.com/300x200"),
]

// MARK: - 站点行组件
struct SiteRow: View {
    let site: SiteConfig

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(site.name).font(.system(size: 14, weight: .medium))
                Text(site.key).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            Text(site.type == 3 ? "JS" : "API").font(.system(size: 10)).foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color(hex: "E11D48")).cornerRadius(4)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.primary.opacity(0.05))
    }
}

// MARK: - 流式布局
@available(iOS 16.0, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height + spacing } - spacing
        return CGSize(width: proposal.width ?? 0, height: height > 0 ? height : 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for subview in row.subviews {
                subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += subview.dimensions(in: .unspecified).width + spacing
            }
            y += row.height + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var currentRow = Row()
        var currentX: CGFloat = 0
        let maxWidth = proposal.width ?? 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, !currentRow.subviews.isEmpty {
                rows.append(currentRow)
                currentRow = Row()
                currentX = 0
            }
            currentRow.subviews.append(subview)
            currentX += size.width + spacing
        }
        if !currentRow.subviews.isEmpty {
            rows.append(currentRow)
        }
        return rows
    }

    private struct Row {
        var subviews: [LayoutSubviews.Element] = []
        var height: CGFloat {
            subviews.map { $0.dimensions(in: .unspecified).height }.max() ?? 0
        }
    }
}
