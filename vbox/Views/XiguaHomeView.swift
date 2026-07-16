import SwiftUI
import AVKit

// MARK: - 吸瓜平台主页面
// 分类作为顶层 Tab 动态切换 + 搜索 + 域名管理入口
// 基于 Python 蜘蛛脚本 (51吸瓜动态版.py) 的数据结构
struct XiguaMainView: View {
    let platform: YBoxPlatform2
    @StateObject private var svc = XiguaService.shared
    @State private var categories: [XiguaCategory] = []
    @State private var selectedTab = 0
    @State private var isLoading = true

    /// 所有 Tab 标签 (分类 + 搜索)
    private var allTabs: [String] {
        let catNames = categories.map { $0.typeName }
        return catNames + ["搜索"]
    }

    /// 是否是搜索 Tab
    private var isSearchTab: Bool {
        selectedTab == categories.count
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView().scaleEffect(1.5)
                Text("连接站点...").font(.system(size: 14)).foregroundColor(.secondary).padding(.top, 12)
                Spacer()
            } else if categories.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 50)).foregroundColor(.secondary)
                    Text("无法加载分类").font(.system(size: 15, weight: .medium))
                    Button(action: { loadCategories() }) {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.system(size: 14))
                            .padding(.horizontal, 20).padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.1)).cornerRadius(8)
                    }
                    Spacer()
                }
            } else {
                // 顶部 Tab 栏 (可滚动)
                ScrollView(.horizontal, showsIndicators: false) {
                    ScrollViewReader { proxy in
                        HStack(spacing: 0) {
                            ForEach(Array(allTabs.enumerated()), id: \.offset) { idx, tabName in
                                Button(action: {
                                    withAnimation { selectedTab = idx }
                                }) {
                                    VStack(spacing: 6) {
                                        HStack(spacing: 4) {
                                            Text(tabName)
                                                .font(.system(size: 14, weight: selectedTab == idx ? .bold : .regular))
                                                .foregroundColor(selectedTab == idx ? .primary : .secondary)
                                            // 搜索 Tab 显示图标
                                            if idx == categories.count {
                                                Image(systemName: "magnifyingglass")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(selectedTab == idx ? .primary : .secondary)
                                            }
                                        }
                                        if selectedTab == idx {
                                            Capsule().fill(Color.accentColor).frame(width: 20, height: 3)
                                        } else {
                                            Capsule().fill(Color.clear).frame(width: 20, height: 3)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                }
                                .buttonStyle(.plain)
                                .id(idx)
                            }
                        }
                        .padding(.vertical, 4)
                        .onChange(of: selectedTab) { newVal in
                            withAnimation { proxy.scrollTo(newVal, anchor: .center) }
                        }
                    }
                }
                .padding(.top, 4)

                Divider()

                // 内容区
                TabView(selection: $selectedTab) {
                    ForEach(Array(categories.enumerated()), id: \.offset) { idx, cat in
                        XiguaCategoryTab(
                            category: cat,
                            platform: platform,
                            svc: svc
                        )
                        .tag(idx)
                    }

                    XiguaSearchTab(platform: platform, svc: svc)
                        .tag(categories.count)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if categories.isEmpty { loadCategories() }
        }
    }

    private func loadCategories() {
        isLoading = true
        Task {
            if !svc.isHostReady {
                _ = await svc.probeHost()
            }
            let result = await svc.fetchHomeContent()
            await MainActor.run {
                categories = result.categories
                isLoading = false
            }
        }
    }
}

// MARK: - 单个分类 Tab (懒加载视频列表)
struct XiguaCategoryTab: View {
    let category: XiguaCategory
    let platform: YBoxPlatform2
    @ObservedObject var svc: XiguaService

    @State private var videos: [XiguaVideo] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var currentPage = 1
    @State private var hasMore = true
    @State private var loadError: String?
    @State private var hasLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            if let err = loadError, videos.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 50)).foregroundColor(.secondary)
                    Text(err).font(.system(size: 15, weight: .medium)).multilineTextAlignment(.center)
                    Button(action: { loadError = nil; refreshVideos() }) {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.system(size: 14))
                            .padding(.horizontal, 20).padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.1)).cornerRadius(8)
                    }
                    Spacer()
                }
                .padding(20)
            } else if videos.isEmpty && isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                        spacing: 14
                    ) {
                        ForEach(videos) { video in
                            NavigationLink(destination: XiguaPlayerView(
                                vodId: video.vodId,
                                title: video.vodName,
                                cover: video.vodPic,
                                platform: platform
                            )) {
                                XiguaVideoCard(
                                    cover: video.vodPic,
                                    title: video.vodName,
                                    remarks: video.vodRemarks ?? ""
                                )
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                if video.vodId == videos[max(0, videos.count - 4)].vodId { loadMore() }
                            }
                        }
                    }
                    .padding(12)

                    if isLoadingMore { ProgressView().padding() }
                    if !hasMore && !videos.isEmpty {
                        Text("已加载全部")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                            .padding(.bottom, 20)
                    }
                }
            }
        }
        .onAppear {
            if !hasLoaded { refreshVideos() }
        }
    }

    private func refreshVideos() {
        currentPage = 1; hasMore = true; isLoading = true; loadError = nil; hasLoaded = true
        Task {
            let result = await svc.fetchCategoryContent(tid: category.typeId, page: 1)
            await MainActor.run {
                videos = result.videos
                isLoading = false
                hasMore = result.videos.count >= 20
                if result.videos.isEmpty { loadError = "暂无内容" }
            }
        }
    }

    private func loadMore() {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        let next = currentPage + 1
        Task {
            let result = await svc.fetchCategoryContent(tid: category.typeId, page: next)
            await MainActor.run {
                if !result.videos.isEmpty {
                    videos.append(contentsOf: result.videos)
                    currentPage = next
                    hasMore = result.videos.count >= 20
                } else {
                    hasMore = false
                }
                isLoadingMore = false
            }
        }
    }
}

// MARK: - 搜索 Tab
struct XiguaSearchTab: View {
    let platform: YBoxPlatform2
    @ObservedObject var svc: XiguaService

    @State private var searchText = ""
    @State private var videos: [XiguaVideo] = []
    @State private var isLoading = false
    @State private var hasSearched = false
    @State private var currentPage = 1
    @State private var hasMore = true
    @State private var isLoadingMore = false

    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索视频...", text: $searchText)
                        .font(.system(size: 15))
                        .onSubmit { performSearch() }
                }
                .padding(10)
                .background(Color(.systemGray6))
                .cornerRadius(10)

                if !searchText.isEmpty {
                    Button("搜索") { performSearch() }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()

            if isLoading {
                Spacer(); ProgressView().scaleEffect(1.5); Spacer()
            } else if !hasSearched {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40)).foregroundColor(.secondary)
                    Text("输入关键词搜索视频").font(.system(size: 15)).foregroundColor(.secondary)
                    Spacer()
                }
            } else if videos.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40)).foregroundColor(.secondary)
                    Text("未找到相关视频").font(.system(size: 15)).foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                        spacing: 14
                    ) {
                        ForEach(videos) { video in
                            NavigationLink(destination: XiguaPlayerView(
                                vodId: video.vodId,
                                title: video.vodName,
                                cover: video.vodPic,
                                platform: platform
                            )) {
                                XiguaVideoCard(
                                    cover: video.vodPic,
                                    title: video.vodName,
                                    remarks: video.vodRemarks ?? ""
                                )
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                if video.vodId == videos[max(0, videos.count - 4)].vodId { loadMore() }
                            }
                        }
                    }
                    .padding(12)

                    if isLoadingMore { ProgressView().padding() }
                    if !hasMore && !videos.isEmpty {
                        Text("已加载全部")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                            .padding(.bottom, 20)
                    }
                }
            }
        }
    }

    private func performSearch() {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        hasSearched = true; isLoading = true; currentPage = 1; hasMore = true
        videos = []

        Task {
            if !svc.isHostReady { _ = await svc.probeHost() }
            let result = await svc.fetchSearch(keyword: searchText, page: 1)
            await MainActor.run {
                videos = result.videos
                isLoading = false
                hasMore = result.videos.count >= 20
            }
        }
    }

    private func loadMore() {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        let next = currentPage + 1

        Task {
            let result = await svc.fetchSearch(keyword: searchText, page: next)
            await MainActor.run {
                if !result.videos.isEmpty {
                    videos.append(contentsOf: result.videos)
                    currentPage = next
                    hasMore = result.videos.count >= 20
                } else {
                    hasMore = false
                }
                isLoadingMore = false
            }
        }
    }
}

// MARK: - 视频卡片 (2列网格用)
struct XiguaVideoCard: View {
    let cover: String
    let title: String
    let remarks: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 封面图
            ZStack(alignment: .bottomTrailing) {
                Rectangle()
                    .fill(Color(.systemGray5))
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .cornerRadius(8)
                    .overlay(
                        Group {
                            if let url = URL(string: cover) {
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    case .failure:
                                        Image(systemName: "photo")
                                            .font(.system(size: 24))
                                            .foregroundColor(.secondary)
                                    default:
                                        ProgressView()
                                    }
                                }
                            } else {
                                Image(systemName: "photo")
                                    .font(.system(size: 24))
                                    .foregroundColor(.secondary)
                            }
                        }
                    )
                    .clipped()
                    .cornerRadius(8)

                // 备注标签
                if !remarks.isEmpty {
                    Text(remarks)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(4)
                        .padding(6)
                }
            }

            // 标题
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }
}

// MARK: - 播放页面
struct XiguaPlayerView: View {
    let vodId: String
    let title: String
    let cover: String
    let platform: YBoxPlatform2

    @StateObject private var svc = XiguaService.shared
    @State private var detail: XiguaDetail?
    @State private var selectedEpisode: XiguaEpisode?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var vodItem: VodItem?
    @State private var showPlayer = false

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView().scaleEffect(1.5)
                Text("加载视频详情...").font(.system(size: 14)).foregroundColor(.secondary).padding(.top, 12)
                Spacer()
            } else if let err = loadError {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 50)).foregroundColor(.secondary)
                    Text(err).font(.system(size: 15, weight: .medium)).multilineTextAlignment(.center)
                    Button(action: { loadError = nil; loadDetail() }) {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.system(size: 14))
                            .padding(.horizontal, 20).padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.1)).cornerRadius(8)
                    }
                    Spacer()
                }
                .padding(20)
            } else if let detail = detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // 封面 + 播放按钮
                        ZStack(alignment: .center) {
                            Rectangle()
                                .fill(Color.black)
                                .aspectRatio(16/9, contentMode: .fit)
                                .overlay(
                                    Group {
                                        if let url = URL(string: cover) {
                                            AsyncImage(url: url) { phase in
                                                switch phase {
                                                case .success(let image):
                                                    image.resizable().aspectRatio(contentMode: .fill)
                                                default:
                                                    Color.gray.opacity(0.3)
                                                }
                                            }
                                        } else {
                                            Color.gray.opacity(0.3)
                                        }
                                    }
                                )
                                .clipped()

                            if let ep = selectedEpisode {
                                Button(action: { playEpisode(ep) }) {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 64))
                                        .foregroundColor(.white.opacity(0.9))
                                        .background(Circle().fill(Color.black.opacity(0.3)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 12)

                        // 视频信息
                        VStack(alignment: .leading, spacing: 8) {
                            Text(title)
                                .font(.system(size: 18, weight: .bold))
                                .padding(.horizontal, 12)

                            if !detail.vodContent.isEmpty {
                                Text(detail.vodContent)
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                    .lineLimit(5)
                                    .padding(.horizontal, 12)
                            }
                        }
                        .padding(.top, 8)

                        Divider().padding(.horizontal, 12)

                        // 剧集列表
                        if !detail.playEpisodes.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("剧集列表")
                                    .font(.system(size: 15, weight: .semibold))
                                    .padding(.horizontal, 12)

                                LazyVGrid(
                                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                                    spacing: 8
                                ) {
                                    ForEach(detail.playEpisodes) { ep in
                                        Button(action: {
                                            selectedEpisode = ep
                                            playEpisode(ep)
                                        }) {
                                            Text(ep.name)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(selectedEpisode?.id == ep.id ? .white : .primary)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 10)
                                                .background(
                                                    selectedEpisode?.id == ep.id
                                                        ? Color.accentColor
                                                        : Color(.systemGray6)
                                                )
                                                .cornerRadius(8)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 12)
                            }
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadDetail() }
        .fullScreenCover(isPresented: $showPlayer) {
            if let vod = vodItem {
                VideoPlayerViewV2(video: vod)
            }
        }
    }

    private func loadDetail() {
        isLoading = true; loadError = nil

        Task {
            if !svc.isHostReady { _ = await svc.probeHost() }

            let result = await svc.fetchDetail(vodId: vodId)
            await MainActor.run {
                detail = result
                isLoading = false

                if result.playEpisodes.isEmpty {
                    loadError = "未找到可播放视频源"
                } else if let firstEp = result.playEpisodes.first {
                    selectedEpisode = firstEp
                }
            }
        }
    }

    private func playEpisode(_ episode: XiguaEpisode) {
        let result = svc.fetchPlayerURL(flag: "", videoUrl: episode.url)

        guard !result.url.isEmpty else {
            loadError = "播放地址无效"
            return
        }

        vodItem = VodItem(
            vodId: vodId,
            vodName: "\(title) \(episode.name)",
            vodPic: cover,
            vodRemarks: "[福利]通用吸瓜",
            vodPlayUrl: result.url,
            customHeaders: result.headers
        )
        showPlayer = true
    }
}