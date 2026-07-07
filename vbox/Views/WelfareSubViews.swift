import SwiftUI

// MARK: - 香蕉秀视频列表页（分类浏览模式）
struct YBoxBananaListView: View {
    let platform: YBoxPlatform2
    @StateObject private var ybox = YBoxService2.shared
    @State private var categories: [YBoxBananaCategory] = []
    @State private var isLoading = true
    @State private var errorMsg: String?
    @EnvironmentObject private var settings: AppSettings

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView().scaleEffect(1.5)
                    Text("加载分类中...").font(.system(size: 14)).foregroundColor(.secondary)
                }
            } else if let e = errorMsg {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundColor(.orange)
                    Text(e).foregroundColor(.secondary)
                    Button("重试") { loadCategories() }
                }
            } else if categories.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray").font(.system(size: 40)).foregroundColor(.secondary)
                    Text("暂无分类")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("全部分类")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 16)
                            .padding(.top, 4)

                        LazyVGrid(columns: columns, spacing: 12) {
                            // 全部视频入口
                            NavigationLink(destination: YBoxBananaCategoryView(
                                platform: platform,
                                categoryName: "全部视频",
                                spid: nil
                            )) {
                                BananaCategoryCard(
                                    title: "全部视频",
                                    cover: nil,
                                    icon: "square.grid.2x2.fill",
                                    isAll: true
                                )
                            }
                            .buttonStyle(PlainButtonStyle())

                            // 各分类入口
                            ForEach(categories) { cat in
                                NavigationLink(destination: YBoxBananaCategoryView(
                                    platform: platform,
                                    categoryName: cat.name,
                                    spid: cat.spid
                                )) {
                                    BananaCategoryCard(
                                        title: cat.name,
                                        cover: cat.cover.isEmpty ? nil : cat.cover,
                                        icon: iconForCategory(cat.name),
                                        isAll: false
                                    )
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .padding(.bottom, 30)
                }
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle(platform.name)
        .navigationBarTitleDisplayMode(.large)
        .onAppear { loadCategories() }
    }

    private func loadCategories() {
        isLoading = true; errorMsg = nil
        Task {
            let result = await ybox.fetchBananaCategories()
            await MainActor.run {
                categories = result
                isLoading = false
                if result.isEmpty { errorMsg = "加载分类失败，请检查域名配置" }
            }
        }
    }

    private func iconForCategory(_ name: String) -> String {
        let icons: [String: String] = [
            "幻想次元": "sparkles", "午夜寻欢": "moon.stars.fill",
            "绿帽淫妻": "heart.slash.fill", "反差婊": "arrow.left.arrow.right",
            "乱蕉淫啪": "rectangle.3.group.fill", "另类蕉合": "exclamationmark.triangle.fill",
            "新片速递": "bolt.fill", "中字无码": "captions.bubble.fill",
            "香蕉新干线": "tram.fill", "猎奇": "eye.fill",
        ]
        return icons[name] ?? "play.rectangle.fill"
    }
}

// MARK: - 分类卡片（带背景图的卡片样式）
struct BananaCategoryCard: View {
    let title: String
    let cover: String?
    let icon: String
    let isAll: Bool

    private let gradientColors: [[Color]] = [
        [Color(hex: "E11D48"), Color(hex: "F43F5E")],
        [Color(hex: "7C3AED"), Color(hex: "A855F7")],
        [Color(hex: "059669"), Color(hex: "34D399")],
        [Color(hex: "D97706"), Color(hex: "F59E0B")],
        [Color(hex: "2563EB"), Color(hex: "60A5FA")],
        [Color(hex: "DC2626"), Color(hex: "F87171")],
        [Color(hex: "0891B2"), Color(hex: "22D3EE")],
        [Color(hex: "9333EA"), Color(hex: "C084FC")],
    ]

    var body: some View {
        let colors = gradientColors[abs(title.hashValue) % gradientColors.count]

        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(
                    colors: colors.map { $0.opacity(0.85) },
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(height: 90)

            // 背景封面图（如果有）
            if let c = cover, !c.isEmpty {
                AsyncImage(url: URL(string: c)) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                            .opacity(0.3)
                    }
                }
                .frame(height: 90)
                .cornerRadius(14)
            }

            // 文字内容
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - 香蕉秀分类视频列表页（支持分页）
struct YBoxBananaCategoryView: View {
    let platform: YBoxPlatform2
    let categoryName: String
    let spid: String?

    @StateObject private var ybox = YBoxService2.shared
    @State private var items: [YBoxVideoItem2] = []
    @State private var currentPage = 1
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var hasMore = true
    @State private var errorMsg: String?
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                VStack(spacing: 16) {
                    ProgressView().scaleEffect(1.5)
                    Text("加载视频中...").font(.system(size: 14)).foregroundColor(.secondary)
                }
            } else if let e = errorMsg, items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundColor(.orange)
                    Text(e).foregroundColor(.secondary)
                    Button("重试") { loadVideos() }
                }
            } else if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray").font(.system(size: 40)).foregroundColor(.secondary)
                    Text("暂无视频")
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
                        ForEach(items) { item in
                            NavigationLink(destination: YBoxBananaPlayerView(item: item)) {
                                YBoxVideoCard2(item: item)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .onAppear {
                                // 滚动到倒数第4个时预加载下一页
                                if item.vodId == items[max(0, items.count - 4)].vodId {
                                    loadMore()
                                }
                            }
                        }
                    }
                    .padding(16)

                    if isLoadingMore {
                        ProgressView().padding()
                    }
                }
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle(categoryName)
        .navigationBarTitleDisplayMode(.large)
        .onAppear { loadVideos() }
    }

    private func loadVideos() {
        isLoading = true; errorMsg = nil; currentPage = 1; hasMore = true
        Task {
            let result: [YBoxVideoItem2]
            if let sid = spid {
                result = await ybox.fetchBananaCategoryVideos(spid: sid, page: 1)
            } else {
                result = await ybox.fetchBananaAllVideos(page: 1)
            }
            await MainActor.run {
                items = result
                isLoading = false
                hasMore = result.count >= 10
                if result.isEmpty { errorMsg = "暂无视频数据" }
            }
        }
    }

    private func loadMore() {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        let nextPage = currentPage + 1
        Task {
            let result: [YBoxVideoItem2]
            if let sid = spid {
                result = await ybox.fetchBananaCategoryVideos(spid: sid, page: nextPage)
            } else {
                result = await ybox.fetchBananaAllVideos(page: nextPage)
            }
            await MainActor.run {
                if !result.isEmpty {
                    items.append(contentsOf: result)
                    currentPage = nextPage
                    hasMore = result.count >= 10
                } else {
                    hasMore = false
                }
                isLoadingMore = false
            }
        }
    }
}

// MARK: - 视频卡片
struct YBoxVideoCard2: View {
    let item: YBoxVideoItem2
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                AsyncImage(url: URL(string: item.cover)) { p in
                    switch p {
                    case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                    case .failure(_): ZStack { Color.gray.opacity(0.2); Image(systemName: "play.slash").foregroundColor(.gray) }
                    case .empty: ZStack { Color.gray.opacity(0.2); ProgressView() }
                    @unknown default: Color.gray.opacity(0.2)
                    }
                }
            }
            .frame(height: 160).cornerRadius(12)
            .overlay(alignment: .topLeading) {
                HStack {
                    if let s = item.score { Text(s).font(.system(size: 11, weight: .bold)).foregroundColor(.white).padding(.horizontal, 6).padding(.vertical, 2).background(Color.orange.opacity(0.8)).cornerRadius(4) }
                    Spacer()
                    if let d = item.duration { Text(d).font(.system(size: 10)).foregroundColor(.white).padding(.horizontal, 4).padding(.vertical, 2).background(Color.black.opacity(0.5)).cornerRadius(3) }
                }.padding(6)
            }
            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(2).frame(height: 36, alignment: .topLeading)
            if let c = item.category { Text(c).font(.system(size: 11)).foregroundColor(.secondary) }
        }
    }
}

// MARK: - 播放页（对接vbox已有播放器 VideoDetailView）
struct YBoxBananaPlayerView: View {
    let item: YBoxVideoItem2
    @StateObject private var ybox = YBoxService2.shared
    @State private var playURL: String?
    @State private var isLoading = true
    @State private var errorMsg: String?
    @State private var showPlayer = false
    @State private var vodItem: VodItem?
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 12) {
            // 封面预览
            AsyncImage(url: URL(string: item.cover)) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fit).cornerRadius(12)
                default:
                    Rectangle().fill(Color.gray.opacity(0.2)).aspectRatio(16/9, contentMode: .fit).cornerRadius(12)
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .center) {
                if isLoading {
                    ProgressView().scaleEffect(2).tint(.white)
                } else if let _ = playURL {
                    Button(action: { showPlayer = true }) {
                        Image(systemName: "play.fill").font(.system(size: 60)).foregroundColor(.white.opacity(0.9))
                    }
                } else if let e = errorMsg {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundColor(.orange)
                        Text(e).font(.system(size: 12)).foregroundColor(.white)
                    }
                }
            }

            Text(item.title).font(.system(size: 18, weight: .bold)).padding(.horizontal, 16)

            if let d = item.duration {
                Label("时长: \(d)", systemImage: "clock").font(.system(size: 13)).foregroundColor(.secondary)
            }

            Spacer()
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle("播放").navigationBarTitleDisplayMode(.inline)
        .onAppear { loadPlayURL() }
        .fullScreenCover(isPresented: $showPlayer) {
            if let vod = vodItem {
                VideoDetailView(video: vod)
            }
        }
    }

    private func loadPlayURL() {
        guard let path = item.playUrl else { errorMsg = "无播放地址"; isLoading = false; return }
        Task {
            if let url = await ybox.fetchBananaPlayURL(playPath: path) {
                await MainActor.run {
                    playURL = url
                    isLoading = false
                    // 构造成VodItem传给现有播放器
                    vodItem = VodItem(
                        vodId: item.vodId,
                        vodName: item.title,
                        vodPic: item.cover,
                        vodRemarks: item.category ?? "福利",
                        vodPlayUrl: url
                    )
                }
            } else {
                await MainActor.run { errorMsg = "获取播放地址失败"; isLoading = false }
            }
        }
    }
}

// MARK: - 1080视频/通用网页源（占位）
struct YBoxWebSourceListView: View {
    let platform: YBoxPlatform2
    @State private var isLoading = true
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.5)
            Text("\(platform.name) 接入中...").foregroundColor(.secondary)
        }
        .navigationTitle(platform.name)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { isLoading = false }
        }
    }
}

// MARK: - 直播源列表页
struct YBoxLiveSourceListView: View {
    @StateObject private var ybox = YBoxService2.shared
    @State private var sources: [YBoxLiveItem2] = []
    @State private var isLoading = true
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载直播源...")
            } else {
                List(sources) { item in
                    NavigationLink(destination: YBoxLiveChannelListView(item: item)) {
                        HStack {
                            AsyncImage(url: URL(string: item.img)) { p in
                                if let img = p.image { img.resizable().aspectRatio(contentMode: .fill).frame(width: 40, height: 40).cornerRadius(8) }
                                else { RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.2)).frame(width: 40, height: 40) }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.system(size: 15, weight: .medium))
                                Text("\(item.number)个频道").font(.system(size: 12)).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("直播源")
        .onAppear {
            Task { await ybox.loadLiveSources()
                await MainActor.run { sources = ybox.liveSources; isLoading = false }
            }
        }
    }
}

// MARK: - 通用爬虫平台内容视图（对接 WelfareCrawlerService + WelfarePlatformView）
struct YBoxCrawlerContentView: View {
    let platform: YBoxPlatform2
    @State private var welfarePlatform: WelfarePlatform?

    var body: some View {
        Group {
            if let wp = welfarePlatform {
                WelfarePlatformView(platform: wp)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("加载平台配置...")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            guard let pid = platform.crawlerPlatformId,
                  let cfg = WelfareCrawlerConfig.config(for: pid) else { return }
            welfarePlatform = WelfarePlatform.adaptive(
                id: cfg.platformId,
                name: cfg.platformName,
                searchPrefix: cfg.searchPrefix
            )
        }
    }
}

// MARK: - 直播间列表
struct YBoxLiveChannelListView: View {
    let item: YBoxLiveItem2
    @State private var channels: [YBoxLiveChannel2]
    @State private var isLoading: Bool
    @State private var selectedChannelURL: String?
    @State private var showPlayer = false
    @EnvironmentObject private var settings: AppSettings

    init(item: YBoxLiveItem2) {
        self.item = item
        _channels = State(initialValue: item.channels)
        _isLoading = State(initialValue: item.channels.isEmpty)
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载频道...")
            } else {
                List(channels) { ch in
                    Button(action: {
                        selectedChannelURL = ch.address
                        showPlayer = true
                    }) {
                        HStack {
                            Image(systemName: "play.circle").foregroundColor(Color(hex: "E11D48"))
                            VStack(alignment: .leading) {
                                Text(ch.title).font(.system(size: 15))
                                Text(ch.address).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(item.title)
        .fullScreenCover(isPresented: $showPlayer) {
            if let url = selectedChannelURL {
                VideoDetailView(video: VodItem(
                    vodId: url,
                    vodName: item.title,
                    vodPic: item.img,
                    vodRemarks: "直播",
                    vodPlayUrl: url
                ))
            }
        }
        .onAppear {
            if channels.isEmpty {
                let addr = item.channels.first?.address ?? ""
                Task {
                    let result = await YBoxService2.shared.fetchLiveChannels(address: addr)
                    await MainActor.run { channels = result; isLoading = false }
                }
            }
        }
    }
}

// MARK: - 漫画列表页
struct YBoxComicListView: View {
    @StateObject private var ybox = YBoxService2.shared
    @State private var comics: [YBoxComicItem2] = []
    @State private var isLoading = true
    @State private var selectedComic: VodItem?
    @State private var showPlayer = false
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载漫画...")
            } else if comics.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "book").font(.system(size: 50)).foregroundColor(.secondary)
                    Text("暂无漫画数据，需要添加爬虫").foregroundColor(.secondary)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
                        ForEach(comics) { comic in
                            Button(action: {
                                selectedComic = VodItem(
                                    vodId: comic.href ?? comic.title,
                                    vodName: comic.title,
                                    vodPic: comic.cover,
                                    vodRemarks: "漫画"
                                )
                                showPlayer = true
                            }) {
                                VStack(spacing: 4) {
                                    AsyncImage(url: URL(string: comic.cover)) { p in
                                        if let img = p.image { img.resizable().aspectRatio(contentMode: .fill).frame(height: 140).cornerRadius(8) }
                                        else { RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.2)).frame(height: 140) }
                                    }
                                    Text(comic.title).font(.system(size: 11)).lineLimit(1)
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle("漫画")
        .fullScreenCover(isPresented: $showPlayer) {
            if let vod = selectedComic {
                VideoDetailView(video: vod)
            }
        }
        .onAppear {
            Task {
                let result = await ybox.fetch18Comics()
                await MainActor.run { comics = result; isLoading = false }
            }
        }
    }
}
