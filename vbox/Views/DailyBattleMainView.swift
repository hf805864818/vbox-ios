import SwiftUI

// MARK: - 每日大乱斗主页面
// 架构对标 YBoxXjspMainView，简化版（无演员/短视频Tab）

struct DailyBattleMainView: View {
    let platform: YBoxPlatform2

    @StateObject private var svc: DailyBattleService

    init(platform: YBoxPlatform2) {
        self.platform = platform
        _svc = StateObject(wrappedValue: DailyBattleService.from(platform: platform))
    }
    @State private var selectedTab = 0
    private let tabs = ["首页", "搜索"]

    var body: some View {
        VStack(spacing: 0) {
            // 顶部Tab
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
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 8).padding(.horizontal, 8)

            Divider()

            TabView(selection: $selectedTab) {
                DailyBattleHomeTab(platform: platform, svc: svc).tag(0)
                DailyBattleSearchTab(platform: platform, svc: svc).tag(1)
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

struct DailyBattleHomeTab: View {
    let platform: YBoxPlatform2
    @ObservedObject var svc: DailyBattleService

    @State private var categories: [DailyBattleCategory] = []
    @State private var selectedCateIdx = 0
    @State private var videos: [DailyBattleVideo] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var currentPage = 1
    @State private var hasMore = true
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            if categories.isEmpty && isLoading {
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
                // 分类横向滚动
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
                                NavigationLink(destination: DailyBattlePlayerView(
                                    vodId: video.vodId, title: video.title,
                                    cover: video.cover, remarks: video.remarks,
                                    platform: platform, svc: svc
                                )) {
                                    DailyBattleVideoCard(
                                        cover: video.cover, title: video.title,
                                        remarks: video.remarks
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
            if categories.isEmpty { loadCategories() }
        }
        .background(Color.clear)
    }

    private func loadCategories() {
        Task {
            let result = await svc.fetchHome()
            await MainActor.run {
                categories = result.categories; isLoading = false
                if !result.categories.isEmpty { refreshVideos() }
                else { loadError = "暂时无法连接服务器" }
            }
        }
    }

    private func refreshVideos() {
        guard !categories.isEmpty else { return }
        currentPage = 1; hasMore = true; isLoading = true; loadError = nil
        let catURL = categories[selectedCateIdx].url
        Task {
            let result = await svc.fetchCategoryList(url: catURL, page: 1)
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
        let catURL = categories[selectedCateIdx].url
        Task {
            let result = await svc.fetchCategoryList(url: catURL, page: next)
            await MainActor.run {
                videos.append(contentsOf: result)
                currentPage = next
                hasMore = result.count >= 10
                isLoadingMore = false
            }
        }
    }
}

// MARK: - 视频卡片

struct DailyBattleVideoCard: View {
    let cover: String
    let title: String
    let remarks: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: URL(string: cover)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Rectangle()
                            .fill(Color.gray.opacity(0.18))
                            .overlay(Image(systemName: "play.rectangle.fill")
                                .foregroundColor(.white.opacity(0.5)))
                    }
                }
                .frame(height: 88)
                .frame(maxWidth: .infinity)
                .clipped()
                .cornerRadius(8)

                // 时长标签
                if !remarks.isEmpty {
                    Text(remarks)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(4)
                        .padding(4)
                }
            }

            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }
}

// MARK: - 搜索Tab

struct DailyBattleSearchTab: View {
    let platform: YBoxPlatform2
    var presetKeyword: String? = nil
    @ObservedObject var svc: DailyBattleService

    @State private var keyword = ""
    @State private var results: [DailyBattleVideo] = []
    @State private var isSearching = false
    @State private var showEmpty = false
    @State private var hasPreset = false

    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏
            HStack(spacing: 8) {
                TextField("搜索\(svc.siteName)...", text: $keyword)
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
                            NavigationLink(destination: DailyBattlePlayerView(
                                vodId: video.vodId, title: video.title,
                                cover: video.cover, remarks: video.remarks,
                                platform: platform, svc: svc
                            )) {
                                DailyBattleVideoCard(
                                    cover: video.cover, title: video.title,
                                    remarks: video.remarks
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .onAppear {
            if let pre = presetKeyword, !hasPreset {
                hasPreset = true
                keyword = pre
                performSearch()
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

// MARK: - 播放器页面（对接 VideoDetailView，与香蕉秀统一播放体验）

struct DailyBattlePlayerView: View {
    let vodId: String
    let title: String
    let cover: String
    let remarks: String
    let platform: YBoxPlatform2
    let svc: DailyBattleService

    @State private var isLoading = true
    @State private var errorMsg: String?
    @State private var vodItem: VodItem?

    @State private var episodes: [(name: String, url: String)] = []
    @State private var keywordItems: [String] = []
    @State private var showEpisodePicker = false
    @State private var showPlayer = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                coverSection
                titleSection
                if !remarks.isEmpty { remarksSection }
                if vodItem != nil { playButton }
                if episodes.count > 1 { episodesSection }
                if !keywordItems.isEmpty { keywordsSection }
                Spacer().frame(height: 40)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear { loadDetail() }
        .fullScreenCover(isPresented: $showPlayer) {
            if let vod = vodItem { VideoDetailView(video: vod) }
        }
    }

    // MARK: - 封面
    @ViewBuilder private var coverSection: some View {
        ZStack {
            AsyncImage(url: URL(string: cover)) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fit).cornerRadius(12)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.2))
                        .aspectRatio(16/9, contentMode: .fit).cornerRadius(12)
                }
            }
            .frame(maxWidth: .infinity)

            if isLoading {
                ProgressView().scaleEffect(2).tint(.white)
            } else if let e = errorMsg {
                VStack(spacing: 12) {
                    Image(systemName: "play.slash")
                        .font(.system(size: 40)).foregroundColor(.white.opacity(0.8))
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

    // MARK: - 标题
    @ViewBuilder private var titleSection: some View {
        Text(title)
            .font(.system(size: 17, weight: .bold))
            .padding(.horizontal, 16)
    }

    // MARK: - 备注
    @ViewBuilder private var remarksSection: some View {
        Text(remarks)
            .font(.system(size: 13))
            .foregroundColor(.secondary)
            .padding(.horizontal, 16)
    }

    // MARK: - 播放按钮
    @ViewBuilder private var playButton: some View {
        Button(action: { showPlayer = true }) {
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

    // MARK: - 选集
    @ViewBuilder private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("选集")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.leading, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(0..<episodes.count, id: \.self) { i in
                        let ep = episodes[i]
                        Button(action: {
                            vodItem = VodItem(
                                vodId: vodId, vodName: "\(title) · \(ep.name)",
                                vodPic: cover, vodRemarks: "[福利]\(svc.siteName)",
                                vodPlayUrl: ep.url
                            )
                            showPlayer = true
                        }) {
                            Text(ep.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.primary)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Color.clear)
                                .cornerRadius(12)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - 关键词标签
    @ViewBuilder private var keywordsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("相关标签")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.leading, 16)
            FlowLayout(spacing: 6) {
                ForEach(keywordItems, id: \.self) { kw in
                    NavigationLink(
                        destination: DailyBattleSearchTab(platform: platform, presetKeyword: kw, svc: svc)
                    ) {
                        Text(kw)
                            .font(.system(size: 12))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.clear)
                            .cornerRadius(10)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func loadDetail() {
        isLoading = true; errorMsg = nil
        Task {
            let detail = await svc.fetchDetail(vodId: vodId)
            let rawParts = detail.playUrl.components(separatedBy: "#")
            let eps: [(name: String, url: String)] = rawParts.compactMap { part in
                let comps = part.components(separatedBy: "$")
                guard comps.count >= 2 else { return nil }
                return (comps[0], comps[1])
            }

            await MainActor.run {
                episodes = eps
                keywordItems = detail.keywords

                if let firstEp = eps.first {
                    vodItem = VodItem(
                        vodId: vodId, vodName: title, vodPic: cover,
                        vodRemarks: "[福利]\(svc.siteName)", vodPlayUrl: firstEp.url
                    )
                    isLoading = false
                } else {
                    errorMsg = "未找到可播放的视频源"
                    isLoading = false
                }
            }
        }
    }
}


