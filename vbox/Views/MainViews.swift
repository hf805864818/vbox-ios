import SwiftUI

// vbox 主入口在 App/VBoxApp.swift

// 主标签视图
struct MainTabView: View {
    @State private var selectedTab = 0
    @State private var tabHistory: [Int] = [0]
    @EnvironmentObject private var settings: AppSettings

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

                SearchView()
                    .tabItem {
                        Image(systemName: selectedTab == 1 ? "magnifyingglass.circle.fill" : "magnifyingglass.circle")
                        Text("搜索")
                    }
                    .tag(1)

                LiveTVView()
                    .tabItem {
                        Image(systemName: selectedTab == 2 ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                        Text("直播")
                    }
                    .tag(2)

                ProfileView()
                    .tabItem {
                        Image(systemName: selectedTab == 3 ? "person.fill" : "person")
                        Text("设置")
                    }
                    .tag(3)
            }
            .accentColor(Color(hex: "E11D48"))

            // 底部悬浮半圆导航栏
            GlassBottomTabBar(selectedTab: $selectedTab)
        }
        .ignoresSafeArea(.keyboard)
        .edgeSwipeBack {
            guard selectedTab != 0 else { return }
            if tabHistory.last == selectedTab { tabHistory.removeLast() }
            selectedTab = tabHistory.last ?? 0
            if tabHistory.isEmpty { tabHistory = [selectedTab] }
        }
        .onChange(of: settings.searchRequestId) { _ in
            guard !settings.searchQuery.isEmpty else { return }
            selectedTab = 1
        }
        .onChange(of: selectedTab) { newValue in
            guard tabHistory.last != newValue else { return }
            tabHistory.append(newValue)
            if tabHistory.count > 8 { tabHistory.removeFirst(tabHistory.count - 8) }
        }
    }
}

extension View {
    func edgeSwipeBack(_ action: @escaping () -> Void) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .global)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = abs(value.translation.height)
                    guard value.startLocation.x < 28, dx > 90, dx > dy * 1.4 else { return }
                    action()
                }
        )
    }
}

// 毛玻璃底部导航栏
struct GlassBottomTabBar: View {
    @Binding var selectedTab: Int
    @EnvironmentObject private var settings: AppSettings

    private let tabs: [(icon: String, iconFilled: String, title: String)] = [
        ("house", "house.fill", "首页"),
        ("magnifyingglass.circle", "magnifyingglass.circle.fill", "搜索"),
        ("antenna.radiowaves.left.and.right", "dot.radiowaves.left.and.right", "直播"),
        ("person", "person.fill", "设置")
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<tabs.count, id: \.self) { index in
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selectedTab = index
                    }
                }) {
                    VStack(spacing: 1) {
                        Image(systemName: selectedTab == index ? tabs[index].iconFilled : tabs[index].icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(selectedTab == index ? activeColor : inactiveColor)
                            .frame(height: 22)

                        Text(tabs[index].title)
                            .font(.system(size: 10, weight: selectedTab == index ? .semibold : .regular))
                            .foregroundColor(selectedTab == index ? activeColor : inactiveColor)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: min(UIScreen.main.bounds.width - 120, 300))
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .background(Capsule().fill(tabBarBaseColor))
                .overlay(
                    Capsule()
                        .stroke(tabBarStrokeColor, lineWidth: 1)
                )
        )
        .clipShape(Capsule())
        .padding(.horizontal, 36)
        .padding(.bottom, 8)
    }

    private var activeColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color.blue
    }

    private var inactiveColor: Color {
        if settings.usesLiquidSkin { return Color.white.opacity(0.72) }
        if settings.usesFrostedSkin { return Color(uiColor: .secondaryLabel) }
        return Color.gray
    }

    private var tabBarBaseColor: Color {
        if settings.usesLiquidSkin { return Color.black.opacity(0.34) }
        if settings.usesFrostedSkin { return Color(uiColor: .secondarySystemBackground).opacity(0.62) }
        return Color(uiColor: .systemBackground).opacity(0.86)
    }

    private var tabBarStrokeColor: Color {
        settings.usesVisualSkin ? Color.white.opacity(0.28) : Color.gray.opacity(0.2)
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
    private static var cachedBannerSubjects: [DoubanSubject] = []
    private static var cachedHotMovies: [DoubanSubject] = []
    private static var cachedHotTV: [DoubanSubject] = []
    private static var cachedHotVariety: [DoubanSubject] = []
    private static var cachedTop250: [DoubanSubject] = []
    private static var cachedShowingMovies: [DoubanSubject] = []
    private static var cachedHotGaiaMovies: [DoubanSubject] = []
    private static var cachedAmericanTV: [DoubanSubject] = []
    private static var hasHomeCache: Bool {
        !cachedBannerSubjects.isEmpty || !cachedHotMovies.isEmpty || !cachedHotTV.isEmpty || !cachedTop250.isEmpty
    }
    @State private var isLoading: Bool
    @State private var bannerSubjects: [DoubanSubject]
    @State private var hotMovies: [DoubanSubject]
    @State private var hotTV: [DoubanSubject]
    @State private var hotVariety: [DoubanSubject]
    @State private var top250: [DoubanSubject]
    @State private var showingMovies: [DoubanSubject]
    @State private var hotGaiaMovies: [DoubanSubject]
    @State private var americanTV: [DoubanSubject]
    @State private var currentIndex = 0

    init() {
        _isLoading = State(initialValue: !Self.hasHomeCache)
        _bannerSubjects = State(initialValue: Self.cachedBannerSubjects)
        _hotMovies = State(initialValue: Self.cachedHotMovies)
        _hotTV = State(initialValue: Self.cachedHotTV)
        _hotVariety = State(initialValue: Self.cachedHotVariety)
        _top250 = State(initialValue: Self.cachedTop250)
        _showingMovies = State(initialValue: Self.cachedShowingMovies)
        _hotGaiaMovies = State(initialValue: Self.cachedHotGaiaMovies)
        _americanTV = State(initialValue: Self.cachedAmericanTV)
    }

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
                        BannerCarousel(subjects: bannerSubjects, currentIndex: $currentIndex, settings: settings)
                    }
                    CategoryTilesView(settings: settings)
                    if !hotMovies.isEmpty {
                        SectionHeader(title: "热门电影", icon: "flame.fill")
                        HorizontalSubjectRow(subjects: hotMovies, settings: settings)
                    }
                    if !top250.isEmpty {
                        SectionHeader(title: "TOP250", icon: "crown.fill")
                        HorizontalSubjectRow(subjects: top250, settings: settings)
                    }
                    if !hotTV.isEmpty {
                        SectionHeader(title: "热门剧集", icon: "tv.fill")
                        HorizontalSubjectRow(subjects: hotTV, settings: settings)
                    }
                    if !hotVariety.isEmpty {
                        SectionHeader(title: "热门综艺", icon: "theatermasks.fill")
                        HorizontalSubjectRow(subjects: hotVariety, settings: settings)
                    }
                    if !showingMovies.isEmpty {
                        SectionHeader(title: "影院热映", icon: "film.fill")
                        HorizontalSubjectRow(subjects: showingMovies, settings: settings)
                    }
                    if !hotGaiaMovies.isEmpty {
                        SectionHeader(title: "豆瓣热门", icon: "flame.fill")
                        HorizontalSubjectRow(subjects: hotGaiaMovies, settings: settings)
                    }
                    if !americanTV.isEmpty {
                        SectionHeader(title: "值得看的英美剧", icon: "globe")
                        HorizontalSubjectRow(subjects: americanTV, settings: settings)
                    }
                }
            }
            .padding(.bottom, 100)
        }
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
        .refreshable { await loadData(force: true) }
        .onAppear {
            guard !Self.hasHomeCache else {
                restoreHomeCache()
                return
            }
            Task { await loadData(force: false) }
        }
    }

    @MainActor
    private func loadData(force: Bool) async {
        if !force, Self.hasHomeCache {
            restoreHomeCache()
            return
        }
        isLoading = true
        do {
            async let banner = doubanService.fetchTop250(start: 0, count: 10)
            async let movies = doubanService.fetchHotMovies(start: 0, count: 10)
            async let tv = doubanService.fetchHotTV(start: 0, count: 10)
            async let variety = doubanService.fetchHotVariety(start: 0, count: 10)
            async let top = doubanService.fetchTop250(start: 0, count: 10)
            async let showing = doubanService.fetchUpcomingCN(start: 0, count: 10)
            async let hotGaia = doubanService.fetchHotGaia(start: 0, count: 10)
            async let american = doubanService.fetchAmericanTV(start: 0, count: 10)
            bannerSubjects = try await banner
            hotMovies = try await movies
            hotTV = try await tv
            hotVariety = try await variety
            top250 = try await top
            showingMovies = try await showing
            hotGaiaMovies = try await hotGaia
            americanTV = try await american
            Self.cachedBannerSubjects = bannerSubjects
            Self.cachedHotMovies = hotMovies
            Self.cachedHotTV = hotTV
            Self.cachedHotVariety = hotVariety
            Self.cachedTop250 = top250
            Self.cachedShowingMovies = showingMovies
            Self.cachedHotGaiaMovies = hotGaiaMovies
            Self.cachedAmericanTV = americanTV
        } catch {
            print("Douban API error: \(error)")
        }
        isLoading = false
    }

    private func restoreHomeCache() {
        bannerSubjects = Self.cachedBannerSubjects
        hotMovies = Self.cachedHotMovies
        hotTV = Self.cachedHotTV
        hotVariety = Self.cachedHotVariety
        top250 = Self.cachedTop250
        showingMovies = Self.cachedShowingMovies
        hotGaiaMovies = Self.cachedHotGaiaMovies
        americanTV = Self.cachedAmericanTV
        isLoading = false
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
                            colors: [Color(uiColor: .systemBackground).opacity(0.2), Color(uiColor: .systemBackground).opacity(0.05)],
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
                        .fill(currentIndex == index ? Color(hex: "E11D48") : Color(uiColor: .systemBackground).opacity(0.3))
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
            AsyncImage(url: DoubanImageProxyServer.shared.resolvedURL(for: video.vodPic)) { phase in
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
                            Color(uiColor: .systemBackground).opacity(0.15),
                            Color(uiColor: .systemBackground).opacity(0.0)
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
                    AsyncImage(url: DoubanImageProxyServer.shared.resolvedURL(for: video.vodPic)) { phase in
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
                                Color(uiColor: .systemBackground).opacity(0.1),
                                Color(uiColor: .systemBackground).opacity(0.0)
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
                .foregroundColor(.primary)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - 搜索视图（新 UI）
struct SearchView: View {
    @StateObject private var spiderManager = SpiderManager.shared
    @EnvironmentObject private var settings: AppSettings
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var searchResults: [VodItem] = []
    @State private var isSearchLoading = false
    @State private var searchHistory: [String] = []
    @State private var selectedDoubanTab = 0
    @State private var doubanSubjects: [String: [DoubanSubject]] = [:]
    @State private var searchDebugLogs: [String] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var doubanLoading = false
    @State private var hasLoadedDefaultData = false
    
    private let doubanTabs = ["豆瓣周榜", "华语口碑剧集", "一周口碑电影榜", "国内即将上映"]
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部搜索栏
            HStack(spacing: 8) {
                // 输入框
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                    TextField("搜索影片、剧集", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .onChange(of: searchText) { value in
                            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                resetSearchState()
                            }
                        }
                    if !searchText.isEmpty {
                        Button(action: {
                            searchText = ""
                            resetSearchState()
                        }) {
                            Image(systemName: "xmark")
                                .foregroundColor(.gray)
                                .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(10)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)
                
                // 豆瓣高分开关
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.gray.opacity(0.15))
                    Image(systemName: "star.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "E11D48"))
                }
                .frame(width: 36, height: 36)
                
                // 搜索按钮
                Button(action: { performSearch() }) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 40, height: 36)
                .background(Color(hex: "E11D48"))
                .cornerRadius(10)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            
            // 分隔线
            Rectangle()
                .fill(Color.gray.opacity(0.1))
                .frame(height: 1)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            
            // 搜索调试面板（搜索框下方）
            if UserDefaults.standard.bool(forKey: "show_search_debug") && !searchDebugLogs.isEmpty {
                VStack(spacing: 0) {
                    HStack {
                        Text("搜索调试")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                        Spacer()
                        Text("\(searchResults.count)条/\(Set(searchResults.compactMap { $0.vodRemarks }).count)源")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: true) {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(searchDebugLogs.enumerated()), id: \.offset) { idx, log in
                                    Text(log)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(log.hasPrefix("✅") ? .green.opacity(0.9) :
                                                           log.hasPrefix("❌") ? .red.opacity(0.9) :
                                                           log.hasPrefix("📦") ? .yellow.opacity(0.9) :
                                                           log.hasPrefix("☁️") ? .cyan.opacity(0.9) :
                                                           .white.opacity(0.7))
                                        .id(idx)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.bottom, 6)
                        }
                        .onChange(of: searchDebugLogs.count) { _ in
                            if let last = searchDebugLogs.indices.last {
                                withAnimation { proxy.scrollTo(last) }
                            }
                        }
                    }
                    .frame(height: 120)
                }
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.85))
                .cornerRadius(10)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            
            ZStack {
                if isSearching && !isSearchLoading && !searchResults.isEmpty {
                    // 已有搜索结果：展示结果页
                    SearchResultsView(results: searchResults)
                } else if isSearching && !isSearchLoading && searchResults.isEmpty {
                    // 已结束搜索但无结果：展示空态
                    VStack(spacing: 20) {
                        Spacer()
                        Image(systemName: "magnifyingglass").font(.system(size: 40)).foregroundColor(.gray)
                        Text("未找到结果").font(.system(size: 16)).foregroundColor(.gray)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // 默认/搜索中：保持默认内容（搜索历史 + 豆瓣榜单），顶部以小条提示「搜索中」
                    ZStack(alignment: .top) {
                        defaultContentView
                        if isSearching && isSearchLoading {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.8)
                                Text("搜索中...").font(.system(size: 13)).foregroundColor(.gray)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(uiColor: .systemBackground).opacity(0.95))
                            .clipShape(Capsule())
                            .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
                            .padding(.top, 6)
                            .transition(.opacity)
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isSearching)
        }
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
        .onChange(of: settings.searchRequestId) { _ in
            runTriggeredSearch()
        }
        .onAppear {
            if !hasLoadedDefaultData {
                hasLoadedDefaultData = true
                Task {
                    await loadSearchHistory()
                    await loadDoubanData(force: false)
                }
                // 首次出现：如果有外部搜索请求则执行
                if !settings.searchQuery.isEmpty {
                    runTriggeredSearch()
                }
            }
            // 从详情页返回时：不做任何操作，保持现有搜索结果
        }
        .onDisappear {
            // 离开搜索页时停止搜索
            searchTask?.cancel()
            searchTask = nil
            isSearching = false
            isSearchLoading = false
        }
    }
    
    @ViewBuilder
    private var defaultContentView: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                // 搜索历史
                if !searchHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 14))
                                .foregroundColor(Color(hex: "E11D48"))
                            Text("搜索历史")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.primary)
                            Spacer()
                            Button("清空") {
                                searchHistory = []
                                cacheSearchHistory()
                            }
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: "E11D48"))
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(searchHistory, id: \.self) { keyword in
                                    SearchHistoryChip(keyword: keyword) {
                                        searchText = keyword
                                        performSearch()
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.bottom, 16)
                    .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
                }
                
                // 豆瓣栏目标签
                HStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(0..<doubanTabs.count, id: \.self) { index in
                                Button(action: {
                                    selectedDoubanTab = index
                                    Task { await loadDoubanData(force: false) }
                                }) {
                                    VStack(spacing: 6) {
                                        Text(doubanTabs[index])
                                            .font(.system(size: 14, weight: selectedDoubanTab == index ? .semibold : .medium))
                                            .foregroundColor(selectedDoubanTab == index ? Color(hex: "E11D48") : .secondary)
                                        Rectangle()
                                            .fill(selectedDoubanTab == index ? Color(hex: "E11D48") : Color.clear)
                                            .frame(height: 2)
                                            .clipShape(RoundedRectangle(cornerRadius: 1))
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(Color.clear)
                                }
                                .buttonStyle(PlainButtonStyle())
                                if index < doubanTabs.count - 1 {
                                    Rectangle()
                                        .fill(Color.gray.opacity(0.15))
                                        .frame(width: 1)
                                        .padding(.vertical, 6)
                                }
                            }
                        }
                    }
                    .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
                }
                
                // 豆瓣数据列表
                if doubanLoading {
                    VStack(spacing: 16) {
                        ForEach(0..<6, id: \.self) { _ in
                            DoubanSkeletonCardItem()
                        }
                    }
                    .padding(.top, 12)
                } else if let subjects = doubanSubjects[doubanTabs[selectedDoubanTab]], !subjects.isEmpty {
                    LazyVStack(spacing: 12) {
                        ForEach(subjects) { subject in
                            SearchDoubanCardItem(subject: subject) {
                                runKeywordSearch(subject.title)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                
                // 分隔线
                Divider().frame(height: 1).background(Color.gray.opacity(0.15)).padding(.vertical, 8)
                
                // 全部站点（保持原样）
                if !spiderManager.allSites.isEmpty {
                    SectionHeader(title: "全部站点 (" + String(spiderManager.loadedSiteCount) + ")", icon: "list.star")
                        .padding(.top, 8)
                    ForEach(spiderManager.allSites, id: \.key) { site in
                        SiteRow(site: site)
                    }
                } else {
                    SearchSuggestionsView(onSelect: runKeywordSearch)
                }
            }
            .padding(.bottom, 100)
        }
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
    }
    
    private func performSearch() {
        searchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchText.isEmpty else {
            resetSearchState()
            return
        }
        isSearching = true
        isSearchLoading = true
        searchResults = []
        searchDebugLogs = []
        
        // 保存搜索历史
        if !searchHistory.contains(searchText) {
            searchHistory.insert(searchText, at: 0)
            if searchHistory.count > 10 {
                searchHistory.removeLast(searchHistory.count - 10)
            }
            cacheSearchHistory()
        }
        
        let keyword = searchText
        addSearchLog("🔍 开始搜索: \(keyword)")
        
        // 取消之前的搜索任务
        searchTask?.cancel()
        searchTask = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await self.spiderManager.searchStream(keyword: keyword, onBatch: { batch in
                        if !batch.isEmpty {
                            Task { @MainActor in
                                self.searchResults.append(contentsOf: batch)
                                self.isSearchLoading = false
                            }
                        }
                    }, onLog: { msg in
                        self.addSearchLog(msg)
                    })
                }
                
                group.addTask {
                    let cloudItems = await self.spiderManager.cloudSearch(keyword: keyword, onLog: { msg in
                        self.addSearchLog(msg)
                    })
                    if !cloudItems.isEmpty {
                        let newItems = cloudItems.map { item -> VodItem in
                            var newItem = item
                            newItem.vodRemarks = "☁️" + (item.vodRemarks ?? "网盘")
                            return newItem
                        }
                        self.addSearchLog("☁️ 合计 +\(newItems.count)条")
                        await MainActor.run {
                            self.searchResults.append(contentsOf: newItems)
                            self.isSearchLoading = false
                        }
                    } else {
                        self.addSearchLog("☁️ 合计 0条")
                    }
                }
                
                await group.waitForAll()
            }
            
            let totalCount = self.searchResults.count
            let sourceCount = Set(self.searchResults.compactMap { $0.vodRemarks }).count
            self.addSearchLog("✅ 搜索结束: 共\(totalCount)条/\(sourceCount)个源")
            await MainActor.run { self.isSearchLoading = false }
        }
    }
    
    private func addSearchLog(_ msg: String) {
        Task { @MainActor in
            searchDebugLogs.append(msg)
            if searchDebugLogs.count > 50 { searchDebugLogs.removeFirst(searchDebugLogs.count - 50) }
        }
    }

    private func runKeywordSearch(_ keyword: String) {
        searchText = keyword
        performSearch()
    }

    private func runTriggeredSearch() {
        let query = settings.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchText = query
        performSearch()
    }

    private func resetSearchState() {
        settings.searchQuery = ""
        isSearching = false
        isSearchLoading = false
        searchResults = []
    }
    
    private func loadSearchHistory() {
        if let saved = UserDefaults.standard.stringArray(forKey: "searchHistory"), !saved.isEmpty {
            searchHistory = saved
        }
    }
    
    private func cacheSearchHistory() {
        UserDefaults.standard.set(searchHistory, forKey: "searchHistory")
    }
    
    @MainActor
    private func loadDoubanData(force: Bool = false) async {
        doubanLoading = true
        let tabName = doubanTabs[selectedDoubanTab]
        if !force, let existing = doubanSubjects[tabName], !existing.isEmpty {
            doubanLoading = false
            return
        }
        
        do {
            let subjects = try await DoubanService.shared.fetchByTab(tabName, start: 0, count: 20)
            doubanSubjects[tabName] = subjects
            doubanLoading = false
        } catch {
            print("Douban fetch error: \(error)")
            doubanLoading = false
        }
    }
}

// MARK: - 搜索栏组件
struct SearchBar: View {
    @Binding var searchText: String
    @Binding var isSearching: Bool
    var onSearch: (() -> Void)?
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(Color.gray)
                TextField("搜索视频、剧集...", text: $searchText).foregroundColor(.primary).onSubmit { performSearch() }
                if !searchText.isEmpty {
                    Button(action: { searchText = ""; isSearching = false }) { Image(systemName: "xmark.circle.fill").foregroundColor(Color.gray) }
                }
            }.padding(.horizontal, 14).padding(.vertical, 12).background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.gray.opacity(0.1))).overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.gray.opacity(0.3), lineWidth: 1))
            if isSearching { Button("取消") { searchText = ""; isSearching = false; UIApplication.shared.endEditing() }.foregroundColor(Color(hex: "E11D48")) }
        }.padding(.horizontal, 16).padding(.vertical, 12).background(Color(uiColor: .systemBackground))
    }
    private func performSearch() { guard !searchText.isEmpty else { return }; onSearch?() }
}

struct SearchSuggestionsView: View {
    var onSelect: (String) -> Void = { _ in }
    var body: some View {
        Color(uiColor: .systemBackground)
    }
}

struct KeywordButton: View {
    let keyword: String
    var onSelect: (String) -> Void = { _ in }
    var body: some View {
        Button(action: { onSelect(keyword) }) { Text(keyword).font(.system(size: 14)).foregroundColor(.primary).padding(.horizontal, 16).padding(.vertical, 8).background(Capsule().fill(Color.gray.opacity(0.1))).overlay(Capsule().stroke(Color.gray.opacity(0.3), lineWidth: 1)) }.buttonStyle(PlainButtonStyle())
    }
}

struct RecentSearchRow: View {
    let keyword: String
    var onSelect: (String) -> Void = { _ in }
    var body: some View {
        Button(action: { onSelect(keyword) }) {
        HStack {
            Text(keyword).font(.system(size: 15)).foregroundColor(.primary)
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(Color.gray)
        }
        .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct SearchHistoryChip: View {
    let keyword: String
    let onSelect: () -> Void
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "E11D48"))
                Text(keyword)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.gray.opacity(0.08)))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct SearchHistoryDeleteButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
                    .foregroundColor(Color.gray)
        }
        .padding(.vertical, 12)
    }
}

struct SearchResultsView: View {
    let results: [VodItem]
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedSource: String? = nil
    @State private var selectedVideo: VodItem? = nil
    private var grouped: [(source: String, videos: [VodItem])] {
        var dict: [String: [VodItem]] = [:]
        for video in results { let source = video.vodRemarks?.isEmpty == false ? video.vodRemarks ?? "" : "搜索结果"; if dict[source] == nil { dict[source] = [] }; dict[source]?.append(video) }
        return dict.map { (source: $0.key, videos: $0.value) }.sorted { $0.videos.count > $1.videos.count }
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
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 2) {
                                ForEach(sources, id: \.self) { name in
                                    let sel = (selectedSource ?? sources.first ?? "") == name
                                    Button(action: { selectedSource = name }) {
                                        SourceNameLabel(name: name, isSelected: sel)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, 10)
                                            .padding(.horizontal, 7)
                                            .background(sel ? Color(hex: "E11D48") : Color.clear)
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 6)
                        }
                        .frame(width: min(108, max(98, geometry.size.width * 0.23)))
                        .background(searchPanelBackground)
                        Divider().background(settings.usesVisualSkin ? Color.white.opacity(0.22) : Color.gray.opacity(0.3))
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 12) {
                                ForEach(currentVideos) { item in
                                    SearchResultRow(video: item).onTapGesture { selectedVideo = item }
                                }
                            }
                            .padding(12)
                        }
                        .background(searchPanelBackground)
                    }
                }
                .fullScreenCover(item: $selectedVideo) { video in
                    VideoDetailView(video: video)
                }
                .onAppear { if selectedSource == nil { selectedSource = sources.first } }
            }
        }
    }
    private func singleColumnList(_ items: [VodItem]) -> some View {
        ScrollView(showsIndicators: false) { LazyVStack(spacing: 12) { ForEach(items) { item in SearchResultRow(video: item).onTapGesture { selectedVideo = item } } }.padding(.horizontal, 16).padding(.vertical, 20) }.background(searchPanelBackground).fullScreenCover(item: $selectedVideo) { video in VideoDetailView(video: video) }
    }

    private var searchPanelBackground: Color {
        settings.usesVisualSkin ? Color.black.opacity(settings.usesLiquidSkin ? 0.18 : 0.08) : Color(uiColor: .systemBackground)
    }
}

struct SourceNameLabel: View {
    let name: String
    let isSelected: Bool

    private var hasCloudIcon: Bool {
        name.contains("☁️") || name.contains("云") || name.contains("资源")
    }

    private var cleanName: String {
        name.replacingOccurrences(of: "☁️", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if hasCloudIcon {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 10))
                        .foregroundColor(isSelected ? .white : Color.gray.opacity(0.45))
                } else {
                    Color.clear
                }
            }
            .frame(width: 14, height: 14)

            Text(cleanName)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : .primary)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .multilineTextAlignment(.leading)
        }
    }
}

struct SearchResultRow: View {
    let video: VodItem
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: DoubanImageProxyServer.shared.resolvedURL(for: video.vodPic)) { phase in switch phase { case .success(let image): image.resizable().aspectRatio(contentMode: .fill); case .failure(_): ZStack { Rectangle().fill(Color.gray.opacity(0.15)); VStack { Image(systemName: "film").font(.title2).foregroundColor(.gray); Text("加载失败").font(.caption2).foregroundColor(.gray) } }; case .empty: ZStack { Rectangle().fill(Color.gray.opacity(0.1)); ProgressView() }; @unknown default: Rectangle().fill(Color.gray.opacity(0.15)) } }.frame(width: 85, height: 110).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) { Text(video.vodName).font(.system(size: 15, weight: .semibold)).foregroundColor(.primary).lineLimit(2); HStack(spacing: 5) { if let r = video.vodRemarks, !r.isEmpty { PlainTagBadge(text: r) }; if let y = video.vodYear, !y.isEmpty { PlainTagBadge(text: y) }; if let a = video.vodArea, !a.isEmpty { PlainTagBadge(text: a) } }; if let d = video.vodDirector, !d.isEmpty { Text("导演: \(d)").font(.system(size: 11)).foregroundColor(.gray).lineLimit(1) }; if let a = video.vodActor, !a.isEmpty { Text("主演: \(a)").font(.system(size: 11)).foregroundColor(.gray).lineLimit(1) } }
            .frame(minHeight: 110, alignment: .top)
            Spacer()
            Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundColor(Color(hex: "E11D48"))
        }.padding(10).background(rowBackground).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var rowBackground: Color {
        if settings.usesLiquidSkin { return Color.black.opacity(0.28) }
        if settings.usesFrostedSkin { return Color(uiColor: .secondarySystemGroupedBackground).opacity(0.58) }
        return Color.gray.opacity(0.05)
    }
}

struct TagBadge: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 11)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.gray.opacity(0.15)).clipShape(Capsule()) }
}

struct PlainTagBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.gray)
            .padding(.horizontal, 0)
            .padding(.vertical, 0)
    }
}

// MARK: - 豆瓣卡片组件
struct SearchDoubanCardItem: View {
    let subject: DoubanSubject
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                AsyncImage(url: DoubanImageProxyServer.shared.resolvedURL(for: subject.coverImageURL)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.gray.opacity(0.15))
                }
                .frame(width: 70, height: 95)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(subject.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .foregroundColor(.primary)

                    if let rating = subject.rating, let value = rating.value {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.yellow)
                            Text(String(format: "%.1f", value))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.yellow)
                        }
                    }

                    Text(subject.card_subtitle ?? subject.genreText ?? "")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)

                    Text("点击搜索 “\(subject.title)”")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "E11D48"))
                }

                Spacer()
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(Color(hex: "E11D48"))
            }
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct DoubanCardItem: View {
    let subject: DoubanSubject
    
    var body: some View {
        NavigationLink(destination: VideoDetailView(
            video: DoubanService.shared.toVodItem(subject: subject)
        )) {
            HStack(spacing: 12) {
                // 封面图
                AsyncImage(url: DoubanImageProxyServer.shared.resolvedURL(for: subject.coverImageURL)) { image in
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.gray.opacity(0.15))
                }
                .frame(width: 70, height: 95)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.gray.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.05), radius: 4, y: 2)
                
                // 信息
                VStack(alignment: .leading, spacing: 6) {
                    Text(subject.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    
                    // 评分
                    if let rating = subject.rating, let value = rating.value {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.yellow)
                            Text(String(format: "%.1f", value))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.yellow)
                        }
                    }
                    
                    // 副标题/简介
                    Text(subject.card_subtitle ?? subject.genreText ?? "")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    
                    // 标签
                    HStack(spacing: 4) {
                        if let year = subject.year, !year.isEmpty {
                            Text(year)
                                .font(.system(size: 10))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.gray.opacity(0.1))
                                .clipShape(Capsule())
                        }
                        if let genres = subject.genres, !genres.isEmpty {
                            Text(genres.prefix(2).joined(separator: " "))
                                .font(.system(size: 10))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(hex: "E11D48").opacity(0.1))
                                .foregroundColor(Color(hex: "E11D48"))
                                .clipShape(Capsule())
                        }
                    }
                }
                
                Spacer()
            }
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 豆瓣骨架屏
struct DoubanSkeletonCardItem: View {
    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color.gray.opacity(0.15))
                .frame(width: 70, height: 95)
                .cornerRadius(8)
            VStack(alignment: .leading, spacing: 6) {
                Rectangle()
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 120, height: 14)
                Rectangle()
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 80, height: 10)
                Rectangle()
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 60, height: 10)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - 分类视图
struct CategoryView: View {
    @EnvironmentObject private var settings: AppSettings
    private let categories = [
        (name: "电影", icon: "film.fill", type: "movie"),
        (name: "电视剧", icon: "tv.fill", type: "tv"),
        (name: "综艺", icon: "mic.fill", type: "variety"),
        (name: "动漫", icon: "sparkles", type: "animation"),
        (name: "纪录片", icon: "book.fill", type: "documentary"),
        (name: "直播", icon: "dot.radiowaves.left.and.right", type: "live"),
        (name: "音乐", icon: "music.note", type: "music"),
        (name: "体育", icon: "sportscourt.fill", type: "sports")
    ]
    
    @State private var selectedCategory: (name: String, type: String)?
    @State private var showCategorySheet = false

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
                ForEach(categories, id: \.name) { category in
                    CategoryCard(name: category.name, icon: category.icon, onTap: {
                        selectedCategory = (name: category.name, type: category.type)
                        showCategorySheet = true
                    })
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
        .sheet(isPresented: $showCategorySheet) {
            if let category = selectedCategory {
                CategoryDetailView(categoryType: category.type, categoryName: category.name)
            }
        }
    }
}

// 分类卡片
struct CategoryCard: View {
    let name: String
    let icon: String
    let onTap: () -> Void
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Button(action: onTap) {
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
                    .fill(cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(uiColor: .systemBackground).opacity(0.1),
                                Color(uiColor: .systemBackground).opacity(0.0)
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

    private var cardBackground: Color {
        if settings.usesLiquidSkin { return Color.black.opacity(0.30) }
        if settings.usesFrostedSkin { return Color(uiColor: .secondarySystemGroupedBackground).opacity(0.62) }
        return Color(uiColor: .secondarySystemGroupedBackground).opacity(0.8)
    }
}

// MARK: - 个人中心视图
struct ProfileView: View {
    @EnvironmentObject private var settings: AppSettings

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
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
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
                                Color(uiColor: .systemBackground).opacity(0.2),
                                Color(uiColor: .systemBackground).opacity(0.0)
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
                Text(site.name).font(.system(size: 14, weight: .medium)).foregroundColor(.primary)
                Text(site.key).font(.system(size: 11)).foregroundColor(.gray)
            }
            Spacer()
            Text(site.type == 3 ? "JS" : "API").font(.system(size: 10)).foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color(hex: "E11D48")).cornerRadius(4)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.gray.opacity(0.08))
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
