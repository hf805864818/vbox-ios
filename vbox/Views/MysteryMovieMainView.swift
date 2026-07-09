import AVKit
import SwiftUI

// MARK: - 神秘电影主页面
// 架构对标 DailyBattleMainView，适配神秘电影数据源

struct MysteryMovieMainView: View {
    let platform: YBoxPlatform2

    @StateObject private var svc = MysteryMovieService.shared
    @State private var selectedTab = 0
    private let tabs = ["首页", "搜索"]

    var body: some View {
        VStack(spacing: 0) {
            // 顶部Tab（无背景框）
            HStack(spacing: 0) {
                ForEach(0..<tabs.count, id: \.self) { i in
                    Button(action: { withAnimation { selectedTab = i } }) {
                        VStack(spacing: 6) {
                            Text(tabs[i])
                                .font(.system(size: 15, weight: selectedTab == i ? .bold : .regular))
                                .foregroundColor(selectedTab == i ? .primary : .secondary)
                            if selectedTab == i {
                                Capsule().fill(Color.accentColor).frame(width: 24, height: 3)
                            } else {
                                Capsule().fill(Color.clear).frame(width: 24, height: 3)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 8).padding(.horizontal, 8)

            Divider()

            TabView(selection: $selectedTab) {
                MysteryMovieHomeTab(platform: platform, svc: svc).tag(0)
                MysteryMovieSearchTab(platform: platform, svc: svc).tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onAppear {
                Task { await svc.probeHost() }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .background(Color.clear)
    }
}

// MARK: - 首页Tab：分类 → 视频网格

struct MysteryMovieHomeTab: View {
    let platform: YBoxPlatform2
    @ObservedObject var svc: MysteryMovieService

    @State private var videos: [MysteryMovieVideo] = []
    @State private var selectedCateIdx = 0
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var currentPage = 1
    @State private var hasMore = true
    @State private var loadError: String?

    private let categories: [MysteryMovieCategory]

    init(platform: YBoxPlatform2, svc: MysteryMovieService) {
        self.platform = platform
        self.svc = svc
        self.categories = svc.categories
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading && videos.isEmpty {
                Spacer()
                ProgressView().scaleEffect(1.5)
                Spacer()
            } else if let err = loadError, videos.isEmpty {
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
            } else {
                // 分类横向滚动（无背景框）
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(categories.enumerated()), id: \.offset) { idx, cat in
                            Button(action: {
                                selectedCateIdx = idx; refreshVideos()
                            }) {
                                Text(cat.name)
                                    .font(.system(size: 13, weight: selectedCateIdx == idx ? .semibold : .regular))
                                    .foregroundColor(selectedCateIdx == idx ? .accentColor : .secondary)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }

                Divider()

                // 视频网格
                if videos.isEmpty && isLoading {
                    Spacer(); ProgressView(); Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                            spacing: 14
                        ) {
                            ForEach(videos) { video in
                                NavigationLink(destination: MysteryMoviePlayerView(
                                    vodId: video.vodId, title: video.title,
                                    cover: video.cover, svc: svc
                                )) {
                                    DailyBattleVideoCard(
                                        cover: video.cover,
                                        title: video.title,
                                        remarks: video.remarks,
                                        imageMode: .mysteryMovie
                                    )
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
                            Text("已加载全部")
                                .font(.system(size: 12)).foregroundColor(.secondary)
                                .padding(.bottom, 20)
                        }
                    }
                }
            }
        }
        .onAppear {
            if videos.isEmpty { refreshVideos() }
        }
        .background(Color.clear)
    }

    private func refreshVideos() {
        currentPage = 1; hasMore = true; isLoading = true; loadError = nil
        let tid = categories[selectedCateIdx].id
        Task {
            let result = await svc.fetchCategoryList(tid: tid, page: 1)
            await MainActor.run {
                videos = result; isLoading = false
                hasMore = result.count >= 10
                if result.isEmpty { loadError = "暂无内容" }
            }
        }
    }

    private func loadMore() {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        let next = currentPage + 1
        let tid = categories[selectedCateIdx].id
        Task {
            let result = await svc.fetchCategoryList(tid: tid, page: next)
            await MainActor.run {
                videos.append(contentsOf: result)
                currentPage = next
                hasMore = result.count >= 10
                isLoadingMore = false
            }
        }
    }
}

// MARK: - 搜索Tab

struct MysteryMovieSearchTab: View {
    let platform: YBoxPlatform2
    @ObservedObject var svc: MysteryMovieService

    @State private var keyword = ""
    @State private var results: [MysteryMovieVideo] = []
    @State private var isSearching = false
    @State private var showEmpty = false

    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏
            HStack(spacing: 8) {
                TextField("搜索神秘电影...", text: $keyword)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(10)
                    .submitLabel(.search)
                    .onSubmit { performSearch() }

                Button(action: { performSearch() }) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Color.accentColor)
                        .cornerRadius(10)
                }
                .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()

            if isSearching {
                Spacer(); ProgressView().scaleEffect(1.5); Spacer()
            } else if results.isEmpty && showEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 40)).foregroundColor(.secondary)
                    Text("未找到相关内容").font(.system(size: 15)).foregroundColor(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                        spacing: 14
                    ) {
                        ForEach(results) { video in
                            NavigationLink(destination: MysteryMoviePlayerView(
                                vodId: video.vodId, title: video.title,
                                cover: video.cover, svc: svc
                            )) {
                                DailyBattleVideoCard(
                                    cover: video.cover,
                                    title: video.title,
                                    remarks: video.remarks,
                                    imageMode: .mysteryMovie
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func performSearch() {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        isSearching = true; showEmpty = false
        Task {
            let result = await svc.search(keyword: kw)
            await MainActor.run {
                results = result; isSearching = false; showEmpty = true
            }
        }
    }
}

// MARK: - 播放器页面

struct MysteryMoviePlayerView: View {
    let vodId: String
    let title: String
    let cover: String
    let svc: MysteryMovieService

    @State private var isLoading = true
    @State private var errorMsg: String?
    @State private var playURL: String?
    @State private var content: String = ""
    @State private var showPlayer = false
    @State private var player = AVPlayer()

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                coverSection
                titleSection
                if playURL != nil { playButton }
                if !content.isEmpty { contentSection }
                Spacer().frame(height: 40)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear { loadDetail() }
        .onDisappear {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        .fullScreenCover(isPresented: $showPlayer) {
            ZStack {
                Color.black.ignoresSafeArea()
                if let url = playURL {
                    VideoPlayer(player: player)
                        .onAppear { player.play() }
                        .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
                }
            }
            .overlay(alignment: .topTrailing) {
                Button(action: { showPlayer = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28)).foregroundColor(.white.opacity(0.8))
                }
                .padding()
            }
        }
    }

    @ViewBuilder private var coverSection: some View {
        ZStack {
            PlatformAsyncImage(urlString: cover, mode: .mysteryMovie, contentMode: .fit)
                .cornerRadius(12)
                .frame(maxWidth: .infinity)
            if isLoading {
                ProgressView().scaleEffect(2).tint(.white)
            } else if let e = errorMsg {
                VStack(spacing: 12) {
                    Image(systemName: "play.slash").font(.system(size: 40)).foregroundColor(.white.opacity(0.8))
                    Text(e).font(.system(size: 14)).foregroundColor(.white.opacity(0.9))
                    Button(action: { loadDetail() }) {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.system(size: 13)).foregroundColor(.white)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Color.accentColor).cornerRadius(8)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var titleSection: some View {
        Text(title).font(.system(size: 17, weight: .bold)).padding(.horizontal, 16)
    }

    @ViewBuilder private var contentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("简介").font(.system(size: 13, weight: .medium)).foregroundColor(.secondary)
            Text(content).font(.system(size: 14)).foregroundColor(.primary).lineLimit(10)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var playButton: some View {
        Button(action: {
            // 设置播放器
            if let urlStr = playURL {
                let headers = ["Referer": svc.host]
                if let localURL = DoubanImageProxyServer.shared.proxiedStreamURL(
                    for: urlStr, headers: headers, provider: "mystery") {
                    player.replaceCurrentItem(with: AVPlayerItem(url: localURL))
                } else if let url = URL(string: urlStr) {
                    player.replaceCurrentItem(with: AVPlayerItem(url: url))
                }
            }
            showPlayer = true
        }) {
            Label("播放", systemImage: "play.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.clear)
                .cornerRadius(12)
                .padding(.horizontal, 16)
        }
    }

    private func loadDetail() {
        isLoading = true; errorMsg = nil; playURL = nil
        Task {
            let detail = await svc.fetchDetail(vodId: vodId)
            await MainActor.run {
                content = detail.content
                if !detail.playUrl.isEmpty {
                    playURL = detail.playUrl
                    isLoading = false
                } else {
                    errorMsg = "未找到可播放的视频源"
                    isLoading = false
                }
            }
        }
    }
}

