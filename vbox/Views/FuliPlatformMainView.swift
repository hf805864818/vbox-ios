import SwiftUI

// MARK: - 分类页面状态缓存
/// 用于在 TabView 页面切换或从详情页返回时保持分类数据不丢失
/// 因为 TabView(.page) 会卸载离屏页面，导致 @State 重置
final class CategoryTabStateCache: ObservableObject {
    struct State {
        var videos: [FuliVideo] = []
        var isLoading = true
        var isLoadingMore = false
        var currentPage = 1
        var hasMore = true
        var loadError: String? = nil
        var hasLoaded = false
        var selectedSubId: String? = nil
    }

    private var states: [String: State] = [:]

    func state(for key: String) -> State {
        if let s = states[key] { return s }
        let s = State()
        states[key] = s
        return s
    }

    func update(_ key: String, _ mutate: (inout State) -> Void) {
        var s = state(for: key)
        mutate(&s)
        states[key] = s
        objectWillChange.send()
    }
}

// MARK: - 通用福利平台主页面
// 统一入口：动态分类 Tab（含二级子分类） + 搜索 Tab
struct FuliPlatformMainView<Service: FuliPlatformService>: View {
    let platform: YBoxPlatform2
    @StateObject private var svc: Service
    @StateObject private var tabStateCache = CategoryTabStateCache()

    init(platform: YBoxPlatform2, service: Service) {
        self.platform = platform
        _svc = StateObject(wrappedValue: service)
    }

    @State private var categories: [FuliCategory] = []
    @State private var selectedTab = 0
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var hasLoadedHome = false
    @State private var showCategoryNav = false  // 分类导航悬浮弹窗开关

    var body: some View {
        ZStack {
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
                        Button(action: {
                            svc.isHostReady = false
                            loadHome()
                        }) {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(.system(size: 14))
                                .padding(.horizontal, 20).padding(.vertical, 8)
                                .background(Color.accentColor.opacity(0.1)).cornerRadius(8)
                        }
                        Spacer()
                    }
                    .padding(20)
                } else {
                    // 顶部 Tab 栏（分类 + 搜索）— 支持自动滚动定位
                    FuliCategoryTabBar(categories: categories, selectedTab: $selectedTab) { idx in
                        // Tab 切换时的回调（可选处理）
                    }
                    Divider()

                    // Tab 内容
                    TabView(selection: $selectedTab) {
                        ForEach(Array(categories.enumerated()), id: \.offset) { idx, cat in
                            FuliCategoryTabView(
                                svc: svc,
                                category: cat,
                                stateCache: tabStateCache,
                                cacheKey: cat.typeId
                            )
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
            // 导航栏右上角分类导航按钮
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showCategoryNav = true
                        }
                    } label: {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .disabled(categories.isEmpty)
                }
            }
            .onAppear {
                if !hasLoadedHome {
                    loadHome()
                    hasLoadedHome = true
                }
            }

            // —— 分类导航悬浮弹窗 ——
            if showCategoryNav && !categories.isEmpty {
                FuliCategoryNavigatorView(
                    categories: categories,
                    selectedIndex: $selectedTab,
                    onSelect: { idx in
                        withAnimation {
                            selectedTab = idx
                        }
                    },
                    onSelectSub: { parentIdx, sub in
                        let cat = categories[parentIdx]
                        let cacheKey = cat.typeId
                        tabStateCache.update(cacheKey) { $0.selectedSubId = sub.typeId }
                        NotificationCenter.default.post(
                            name: NSNotification.Name("FuliCategoryNavSubSelected"),
                            object: nil,
                            userInfo: ["cacheKey": cacheKey]
                        )
                    },
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showCategoryNav = false
                        }
                    }
                )
            }
        }
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
                    // 探测成功但分类解析失败时，重置域名就绪状态，
                    // 确保下次进入或点击重试时会重新探测域名（可能切换到其他可用域名）
                    svc.isHostReady = false
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
    @ObservedObject var stateCache: CategoryTabStateCache
    let category: FuliCategory
    let cacheKey: String

    init(svc: Service, category: FuliCategory, stateCache: CategoryTabStateCache, cacheKey: String) {
        self.svc = svc
        self.category = category
        self.stateCache = stateCache
        self.cacheKey = cacheKey
    }

    /// 漫画类型点击时，通过 fullScreenCover 呈现阅读器（物理覆盖底栏）
    @State private var selectedComicVideo: FuliVideo? = nil

    private var state: CategoryTabStateCache.State {
        stateCache.state(for: cacheKey)
    }

    private var selectedSub: FuliCategory? {
        guard let subId = state.selectedSubId else { return nil }
        return category.subCategories?.first { $0.typeId == subId }
    }

    var body: some View {
        VStack(spacing: 0) {
            subCategoryBar
            contentArea
        }
        .onAppear {
            if !state.hasLoaded {
                refresh(force: false)
                stateCache.update(cacheKey) { $0.hasLoaded = true }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FuliCategoryNavSubSelected"))) { notif in
            guard let key = notif.userInfo?["cacheKey"] as? String,
                  key == cacheKey else { return }
            refresh(force: true)
        }
        .fullScreenCover(item: $selectedComicVideo) { video in
            ComicDirectReaderView(video: video, svc: svc)
        }
    }

    @ViewBuilder
    private var subCategoryBar: some View {
        if let subs = category.subCategories, !subs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    subButton(title: "全部", isSelected: selectedSub == nil) {
                        selectSub(nil)
                    }
                    ForEach(subs) { sub in
                        subButton(title: sub.typeName, isSelected: selectedSub?.typeId == sub.typeId) {
                            selectSub(sub)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            Divider()
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        if state.isLoading && state.videos.isEmpty {
            Spacer(); ProgressView(); Spacer()
        } else if let err = state.loadError, state.videos.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Text(err).font(.system(size: 14)).foregroundColor(.secondary)
                Button("重试") { refresh(force: true) }
                    .font(.system(size: 14))
                Spacer()
            }
        } else {
            videoGrid
        }
    }

    private var videoGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 14
            ) {
                ForEach(state.videos) { video in
                    videoCard(for: video)
                }
            }
            .padding(12)
            if state.isLoadingMore { ProgressView().padding() }
            if !state.hasMore && !state.videos.isEmpty {
                Text("已加载全部").font(.system(size: 12)).foregroundColor(.secondary).padding(.bottom, 20)
            }
        }
        .refreshable {
            await refreshAsync()
        }
    }

    private func videoCard(for video: FuliVideo) -> some View {
        Group {
            if svc.contentCategory == .comic {
                FuliVideoCard(video: video, imageReferer: svc.imageReferer, imageSSLBypass: svc.imageSSLBypass)
                    .onTapGesture { selectedComicVideo = video }
            } else {
                NavigationLink(destination: detailView(for: video)) {
                    FuliVideoCard(video: video, imageReferer: svc.imageReferer, imageSSLBypass: svc.imageSSLBypass)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            if video.id == state.videos[max(0, state.videos.count - 4)].id { loadMore() }
        }
    }

    private func selectSub(_ sub: FuliCategory?) {
        stateCache.update(cacheKey) { $0.selectedSubId = sub?.typeId }
        refresh(force: true)
    }

    private func detailView(for video: FuliVideo) -> some View {
        if svc.contentCategory == .comic {
            return AnyView(ComicDirectReaderView(video: video, svc: svc))
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
        if !force && !state.videos.isEmpty { return }
        Task {
            await refreshAsync()
        }
    }

    private func refreshAsync() async {
        stateCache.update(cacheKey) {
            $0.currentPage = 1
            $0.hasMore = true
            $0.isLoading = true
            $0.loadError = nil
        }
        await svc.ensureHostReady()
        let result = await svc.fetchCategoryContent(category: category, subCategory: selectedSub, page: 1)
        stateCache.update(cacheKey) {
            $0.videos = result.videos
            $0.isLoading = false
            $0.hasMore = result.hasMore
            if result.videos.isEmpty { $0.loadError = "暂无内容" }
        }
    }

    private func loadMore() {
        let s = state
        guard !s.isLoadingMore, s.hasMore else { return }
        stateCache.update(cacheKey) { $0.isLoadingMore = true }
        let next = s.currentPage + 1
        Task {
            let result = await svc.fetchCategoryContent(category: category, subCategory: selectedSub, page: next)
            stateCache.update(cacheKey) {
                if !result.videos.isEmpty {
                    $0.videos.append(contentsOf: result.videos)
                    $0.currentPage = next
                    $0.hasMore = result.hasMore
                } else {
                    $0.hasMore = false
                }
                $0.isLoadingMore = false
            }
        }
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
    /// 漫画搜索结果点击时，通过 fullScreenCover 呈现阅读器
    @State private var selectedComicVideo: FuliVideo? = nil

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            searchContentArea
        }
        .fullScreenCover(item: $selectedComicVideo) { video in
            ComicDirectReaderView(video: video, svc: svc)
        }
    }

    private var searchBar: some View {
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
    }

    @ViewBuilder
    private var searchContentArea: some View {
        if isLoading && videos.isEmpty {
            Spacer(); ProgressView(); Spacer()
        } else {
            searchResultGrid
        }
    }

    private var searchResultGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 14
            ) {
                ForEach(videos) { video in
                    searchResultCard(for: video)
                }
            }
            .padding(12)
        }
    }

    private func searchResultCard(for video: FuliVideo) -> some View {
        Group {
            if svc.contentCategory == .comic {
                FuliVideoCard(video: video, imageReferer: svc.imageReferer, imageSSLBypass: svc.imageSSLBypass)
                    .onTapGesture { selectedComicVideo = video }
            } else {
                NavigationLink(destination: searchDetailView(for: video)) {
                    FuliVideoCard(video: video, imageReferer: svc.imageReferer, imageSSLBypass: svc.imageSSLBypass)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            if video.id == videos[max(0, videos.count - 4)].id { loadMore() }
        }
    }

    private func searchDetailView(for video: FuliVideo) -> some View {
        if svc.contentCategory == .comic {
            return AnyView(ComicDirectReaderView(video: video, svc: svc))
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
