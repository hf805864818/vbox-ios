import SwiftUI

// MARK: - 通用福利平台主页面
// 统一入口：动态分类 Tab（含二级子分类） + 搜索 Tab
struct FuliPlatformMainView<Service: FuliPlatformService>: View {
    let platform: YBoxPlatform2
    @StateObject private var svc: Service

    init(platform: YBoxPlatform2, service: Service) {
        self.platform = platform
        _svc = StateObject(wrappedValue: service)
    }

    @State private var categories: [FuliCategory] = []
    @State private var selectedTab = 0
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView().scaleEffect(1.5)
                Spacer()
            } else if let err = loadError, categories.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 50)).foregroundColor(.secondary)
                    Text(err).font(.system(size: 15)).multilineTextAlignment(.center)
                    Button(action: { loadHome() }) {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.system(size: 14))
                            .padding(.horizontal, 20).padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.1)).cornerRadius(8)
                    }
                    Spacer()
                }
                .padding(20)
            } else {
                // 顶部 Tab 栏（分类 + 搜索）
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(categories.enumerated()), id: \.offset) { idx, cat in
                            tabButton(title: cat.typeName, isSelected: selectedTab == idx) {
                                withAnimation { selectedTab = idx }
                            }
                        }
                        tabButton(title: "搜索", isSelected: selectedTab == categories.count) {
                            withAnimation { selectedTab = categories.count }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(height: 44)
                Divider()

                // Tab 内容
                TabView(selection: $selectedTab) {
                    ForEach(Array(categories.enumerated()), id: \.offset) { idx, cat in
                        FuliCategoryTabView(svc: svc, category: cat)
                            .tag(idx)
                    }
                    FuliSearchTabView(svc: svc)
                        .tag(categories.count)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadHome() }
    }

    private func tabButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .bold : .regular))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .padding(.horizontal, 12)
                Capsule()
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(width: 20, height: 3)
            }
            .frame(height: 40)
        }
        .buttonStyle(.plain)
    }

    private func loadHome() {
        isLoading = true; loadError = nil
        Task {
            await svc.ensureHostReady()
            let result = await svc.fetchHomeContent()
            await MainActor.run {
                isLoading = false
                categories = result.categories
                if result.categories.isEmpty {
                    loadError = "未能解析到分类，请检查域名或网络"
                } else {
                    selectedTab = 0
                }
            }
        }
    }
}

// MARK: - 分类 Tab（含二级子分类）
struct FuliCategoryTabView<Service: FuliPlatformService>: View {
    @ObservedObject var svc: Service
    let category: FuliCategory

    @State private var selectedSub: FuliCategory? = nil
    @State private var videos: [FuliVideo] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var currentPage = 1
    @State private var hasMore = true
    @State private var loadError: String?
    @State private var hasLoaded = false  // 标记是否已加载过，避免返回时重复刷新
    @State private var isRefreshing = false  // 下拉刷新状态

    var body: some View {
        VStack(spacing: 0) {
            // 二级子分类
            if let subs = category.subCategories, !subs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        subButton(title: "全部", isSelected: selectedSub == nil) {
                            selectedSub = nil; refresh(force: true)
                        }
                        ForEach(subs) { sub in
                            subButton(title: sub.typeName, isSelected: selectedSub?.id == sub.id) {
                                selectedSub = sub; refresh(force: true)
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                Divider()
            }

            // 视频网格
            if isLoading && videos.isEmpty {
                Spacer(); ProgressView(); Spacer()
            } else if let err = loadError, videos.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Text(err).font(.system(size: 14)).foregroundColor(.secondary)
                    Button("重试") { refresh(force: true) }
                        .font(.system(size: 14))
                    Spacer()
                }
            } else {
                ScrollView {
                    // 下拉刷新指示器
                    PullToRefreshView(coordinateSpace: .named("categoryScroll"), isRefreshing: isRefreshing, onRefresh: {
                        refresh(force: true)
                    })

                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                        spacing: 14
                    ) {
                        ForEach(videos) { video in
                            NavigationLink(destination: detailView(for: video)) {
                                FuliVideoCard(video: video, imageReferer: svc.imageReferer, imageSSLBypass: svc.imageSSLBypass)
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                if video.id == videos[max(0, videos.count - 4)].id { loadMore() }
                            }
                        }
                    }
                    .padding(12)
                    if isLoadingMore { ProgressView().padding() }
                    if !hasMore && !videos.isEmpty {
                        Text("已加载全部").font(.system(size: 12)).foregroundColor(.secondary).padding(.bottom, 20)
                    }
                }
                .coordinateSpace(name: "categoryScroll")
            }
        }
        .onAppear {
            if !hasLoaded {
                refresh(force: false)
                hasLoaded = true
            }
        }
    }

    private func detailView(for video: FuliVideo) -> some View {
        if svc.contentCategory == .comic {
            return AnyView(ComicDetailBridgeView(svc: svc, video: video))
        } else {
            return AnyView(FuliVideoBridgeView(svc: svc, video: video))
        }
    }

    private func subButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : .accentColor)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(isSelected ? Color.accentColor : Color.accentColor.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
    }

    private func refresh(force: Bool) {
        // 非强制刷新且已有数据时，不重新加载
        if !force && !videos.isEmpty { return }

        currentPage = 1; hasMore = true; isLoading = true; loadError = nil
        if force { isRefreshing = true }

        Task {
            await svc.ensureHostReady()
            let result = await svc.fetchCategoryContent(category: category, subCategory: selectedSub, page: 1)
            await MainActor.run {
                videos = result.videos; isLoading = false; isRefreshing = false
                hasMore = result.hasMore
                if result.videos.isEmpty { loadError = "暂无内容" }
            }
        }
    }

    private func loadMore() {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        let next = currentPage + 1
        Task {
            let result = await svc.fetchCategoryContent(category: category, subCategory: selectedSub, page: next)
            await MainActor.run {
                if !result.videos.isEmpty {
                    videos.append(contentsOf: result.videos)
                    currentPage = next
                    hasMore = result.hasMore
                } else {
                    hasMore = false
                }
                isLoadingMore = false
            }
        }
    }
}

// MARK: - 下拉刷新控件
/// 纯 SwiftUI 实现的下拉刷新，基于 ScrollView 偏移量检测
struct PullToRefreshView: View {
    let coordinateSpace: CoordinateSpace
    let isRefreshing: Bool
    let onRefresh: () -> Void

    @State private var canTrigger = true
    @State private var dragOffset: CGFloat = 0
    private let triggerThreshold: CGFloat = 60

    var body: some View {
        GeometryReader { proxy -> Color in
            let minY = proxy.frame(in: coordinateSpace).minY
            DispatchQueue.main.async {
                dragOffset = minY
                if minY > triggerThreshold && canTrigger && !isRefreshing {
                    canTrigger = false
                    let impact = UIImpactFeedbackGenerator(style: .medium)
                    impact.impactOccurred()
                    onRefresh()
                }
                if minY <= 0 {
                    canTrigger = true
                }
            }
            return Color.clear
        }
        .frame(height: isRefreshing ? 50 : max(0, dragOffset))
        .overlay(
            VStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.9)
                Text(isRefreshing ? "正在刷新..." : (dragOffset > triggerThreshold ? "松开刷新" : "下拉刷新"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .opacity((isRefreshing || dragOffset > 10) ? 1 : 0)
        )
    }
}

// MARK: - 搜索 Tab
struct FuliSearchTabView<Service: FuliPlatformService>: View {
    @ObservedObject var svc: Service
    @State private var keyword = ""
    @State private var videos: [FuliVideo] = []
    @State private var isLoading = false
    @State private var currentPage = 1
    @State private var hasMore = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索视频", text: $keyword)
                    .submitLabel(.search)
                    .onSubmit { search() }
                if !keyword.isEmpty {
                    Button(action: { keyword = "" }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                }
                Button("搜索") { search() }
                    .disabled(keyword.isEmpty || isLoading)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground))
            .cornerRadius(10)
            .padding(12)

            if isLoading && videos.isEmpty {
                Spacer(); ProgressView(); Spacer()
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                        spacing: 14
                    ) {
                        ForEach(videos) { video in
                            NavigationLink(destination: searchDetailView(for: video)) {
                                FuliVideoCard(video: video, imageReferer: svc.imageReferer, imageSSLBypass: svc.imageSSLBypass)
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                if video.id == videos[max(0, videos.count - 4)].id { loadMore() }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func searchDetailView(for video: FuliVideo) -> some View {
        if svc.contentCategory == .comic {
            return AnyView(ComicDetailBridgeView(svc: svc, video: video))
        } else {
            return AnyView(FuliVideoBridgeView(svc: svc, video: video))
        }
    }

    private func search() {
        guard !keyword.isEmpty else { return }
        currentPage = 1; hasMore = true; isLoading = true; videos = []
        Task {
            await svc.ensureHostReady()
            let result = await svc.fetchSearch(keyword: keyword, page: 1)
            await MainActor.run {
                videos = result.videos; isLoading = false; hasMore = result.hasMore
            }
        }
    }

    private func loadMore() {
        guard !isLoading, hasMore else { return }
        isLoading = true
        let next = currentPage + 1
        Task {
            let result = await svc.fetchSearch(keyword: keyword, page: next)
            await MainActor.run {
                if !result.videos.isEmpty {
                    videos.append(contentsOf: result.videos)
                    currentPage = next
                    hasMore = result.hasMore
                } else {
                    hasMore = false
                }
                isLoading = false
            }
        }
    }
}

// MARK: - 视频卡片
struct FuliVideoCard: View {
    let video: FuliVideo
    var imageReferer: String? = nil
    var imageSSLBypass: Bool = false

    private var bottomLabel: String {
        var parts: [String] = []
        if let s = video.score, !s.isEmpty { parts.append(s) }
        if let a = video.areaName, !a.isEmpty { parts.append(a) }
        if let d = video.duration, !d.isEmpty { parts.append(d) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                FuliCoverImage(urlString: video.vodPic, referer: imageReferer, sslBypass: imageSSLBypass, contentMode: .fill)
                .frame(height: 88)
                .frame(maxWidth: .infinity)
                .clipped()

                LinearGradient(
                    colors: [Color.black.opacity(0.0), Color.black.opacity(0.55)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 88)

                if !bottomLabel.isEmpty {
                    Text(bottomLabel)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Capsule())
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(video.vodName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FuliCoverImage: View {
    let urlString: String
    let referer: String?
    var sslBypass: Bool = false
    let contentMode: ContentMode

    var body: some View {
        if let referer = referer, !referer.isEmpty {
            PlatformAsyncImage.sourceCover(urlString, referer: referer, sslBypass: sslBypass, contentMode: contentMode)
        } else {
            AsyncImage(url: URL(string: urlString)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: contentMode)
                default:
                    Rectangle()
                        .fill(Color.gray.opacity(0.18))
                        .overlay(Image(systemName: "play.rectangle.fill").foregroundColor(.white.opacity(0.5)))
                }
            }
        }
    }
}
