import SwiftUI

// MARK: - 香蕉秀主页面（基于 zfvwi8.ipajx0.cc 真实 API，by QClaw 2026-07-07）
//
// 页面架构（对标 yBox 原生）：
//   首页Tab → 分类列表(12类) → 视频网格(2列) → 播放
//   短视频Tab → /minivod/reqlist → 抖音式竖屏滑动 + 点击进入播放
//   演员Tab   → /special/listing  → 演员/专题列表 → 视频列表 → 播放
//   注：zfvwi8 网关无独立演员 API，暂用专题列表模拟
//
// API 来源：ybox App HTTPS 抓包还原

struct YBoxXjspMainView: View {
    let platform: YBoxPlatform2
    @State private var selectedTab = 0
    private let tabs = ["首页", "短视频", "演员"]

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
                YBoxBananaHomeTab(platform: platform).tag(0)
                YBoxBananaShortVideoTab(platform: platform).tag(1)
                YBoxBananaActorTab(platform: platform).tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle(platform.name)
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - 首页Tab：分类列表 → 视频网格

struct YBoxBananaHomeTab: View {
    let platform: YBoxPlatform2
    @StateObject private var svc = YBoxService2.shared
    @State private var categories: [YBoxBananaCategory] = []
    @State private var selectedCateIdx = 0
    @State private var videos: [YBoxBananaVideo] = []
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
                // 错误重试
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
                                    .foregroundColor(selectedCateIdx == idx ? .white : .primary)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(selectedCateIdx == idx ? Color.accentColor : Color(UIColor.secondarySystemBackground))
                                    .cornerRadius(16)
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }

                // 子分类行（如果有）
                if !categories.isEmpty {
                    let subCates = categories[selectedCateIdx].subCates
                    if !subCates.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(subCates) { sub in
                                    NavigationLink(destination: YBoxBananaVideoGrid(
                                        cateId: sub.cateId, title: sub.name, platform: platform
                                    )) {
                                        Text(sub.name)
                                            .font(.system(size: 12))
                                            .foregroundColor(.accentColor)
                                            .padding(.horizontal, 10).padding(.vertical, 4)
                                            .background(Color.accentColor.opacity(0.1))
                                            .cornerRadius(10)
                                    }
                                }
                            }
                            .padding(.horizontal, 12).padding(.bottom, 6)
                        }
                    }
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
                                NavigationLink(destination: YBoxBananaPlayerView(
                                    vodId: video.vodId, title: video.title,
                                    cover: video.cover, duration: video.duration,
                                    platform: platform
                                )) {
                                    BananaVideoCard(
                                        cover: video.cover, title: video.title,
                                        duration: video.duration, score: video.score,
                                        areaName: video.areaName
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
        .onAppear {
            if categories.isEmpty { loadCategories() }
        }
    }

    private func loadCategories() {
        Task {
            let result = await svc.fetchBananaCategories()
            await MainActor.run {
                categories = result; isLoading = false
                if !result.isEmpty { refreshVideos() }
                else { loadError = "暂时无法连接服务器" }
            }
        }
    }

    private func refreshVideos() {
        guard !categories.isEmpty else { return }
        currentPage = 1; hasMore = true; isLoading = true; loadError = nil
        let cateId = categories[selectedCateIdx].cateId
        Task {
            let result = await svc.fetchBananaVideos(cateId: cateId, page: 1)
            await MainActor.run {
                videos = result; isLoading = false
                hasMore = result.count >= 16
                if result.isEmpty { loadError = "暂无内容" }
            }
        }
    }

    private func loadMore() {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        let next = currentPage + 1
        let cateId = categories[selectedCateIdx].cateId
        Task {
            let result = await svc.fetchBananaVideos(cateId: cateId, page: next)
            await MainActor.run {
                if !result.isEmpty { videos.append(contentsOf: result); currentPage = next; hasMore = result.count >= 16 }
                else { hasMore = false }
                isLoadingMore = false
            }
        }
    }
}

// MARK: - 分类视频网格（从子分类进入）

struct YBoxBananaVideoGrid: View {
    let cateId: String
    let title: String
    let platform: YBoxPlatform2
    @StateObject private var svc = YBoxService2.shared
    @State private var videos: [YBoxBananaVideo] = []
    @State private var isLoading = true
    @State private var currentPage = 1
    @State private var hasMore = true
    @State private var isLoadingMore = false

    var body: some View {
        Group {
            if videos.isEmpty && isLoading {
                VStack { Spacer(); ProgressView(); Spacer() }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                        spacing: 14
                    ) {
                        ForEach(videos) { video in
                            NavigationLink(destination: YBoxBananaPlayerView(
                                vodId: video.vodId, title: video.title,
                                cover: video.cover, duration: video.duration,
                                platform: platform
                            )) {
                                BananaVideoCard(
                                    cover: video.cover, title: video.title,
                                    duration: video.duration, score: video.score,
                                    areaName: video.areaName
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
                }
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadVideos() }
    }

    private func loadVideos() {
        Task {
            let result = await svc.fetchBananaVideos(cateId: cateId, page: 1)
            await MainActor.run { videos = result; isLoading = false; hasMore = result.count >= 16 }
        }
    }

    private func loadMore() {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        let next = currentPage + 1
        Task {
            let result = await svc.fetchBananaVideos(cateId: cateId, page: next)
            await MainActor.run {
                if !result.isEmpty { videos.append(contentsOf: result); currentPage = next; hasMore = result.count >= 16 }
                else { hasMore = false }
                isLoadingMore = false
            }
        }
    }
}

// MARK: - 短视频Tab（/minivod/reqlist，抖音式竖屏滑动播放）

struct YBoxBananaShortVideoTab: View {
    let platform: YBoxPlatform2
    @StateObject private var svc = YBoxService2.shared
    @State private var videos: [YBoxBananaMiniVideo] = []
    @State private var isLoading = true
    @State private var currentPage = 1
    @State private var loadError: String?
    @State private var activeIndex: Int = 0

    var body: some View {
        GeometryReader { geo in
            if isLoading && videos.isEmpty {
                VStack { Spacer(); ProgressView().scaleEffect(1.5); Spacer() }
                    .frame(width: geo.size.width, height: geo.size.height)
            } else if let err = loadError, videos.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 50)).foregroundColor(.secondary)
                    Text(err).font(.system(size: 15)).multilineTextAlignment(.center)
                    Button(action: { loadError = nil; loadVideos() }) {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.system(size: 14))
                            .padding(.horizontal,20).padding(.vertical,8)
                            .background(Color.accentColor.opacity(0.1)).cornerRadius(8)
                    }
                    Spacer()
                }
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(videos.enumerated()), id: \.offset) { idx, video in
                            BananaShortVideoCell(
                                video: video, platform: platform,
                                cellHeight: geo.size.height, cellWidth: geo.size.width,
                                isActive: idx == activeIndex
                            )
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(idx)
                            .onAppear {
                                activeIndex = idx
                                if idx >= videos.count - 3 { loadMore() }
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
            }
        }
        .onAppear { loadVideos() }
    }

    private func loadVideos() {
        isLoading = true; loadError = nil
        Task {
            let result = await svc.fetchBananaMiniVideos(page: 1)
            await MainActor.run {
                videos = result; isLoading = false
                if result.isEmpty { loadError = "暂无短视频数据" }
            }
        }
    }

    private func loadMore() {
        let next = currentPage + 1
        Task {
            let result = await svc.fetchBananaMiniVideos(page: next)
            await MainActor.run {
                if !result.isEmpty { videos.append(contentsOf: result); currentPage = next }
            }
        }
    }
}

// MARK: - 短视频竖屏 Cell（封面+点击播放）

struct BananaShortVideoCell: View {
    let video: YBoxBananaMiniVideo
    let platform: YBoxPlatform2
    let cellHeight: CGFloat
    let cellWidth: CGFloat
    var isActive: Bool = false
    @State private var showPlayer = false

    var body: some View {
        ZStack {
            // 模糊背景
            AsyncImage(url: URL(string: video.cover)) { phase in
                if let img = phase.image {
                    img.resizable().scaledToFill()
                        .frame(width: cellWidth, height: cellHeight)
                        .clipped().blur(radius: 25).overlay(Color.black.opacity(0.35))
                } else {
                    Color.black.opacity(0.85)
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 16) {
                Spacer()
                // 封面大图
                AsyncImage(url: URL(string: video.cover)) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fit)
                            .frame(maxHeight: cellHeight * 0.55)
                            .cornerRadius(16)
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: cellHeight * 0.4)
                            .cornerRadius(16)
                    }
                }

                // 播放按钮
                Button(action: { showPlayer = true }) {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.2)).frame(width: 80, height: 80)
                        Image(systemName: "play.fill")
                            .font(.system(size: 36)).foregroundColor(.white)
                    }
                }

                // 标题
                VStack(spacing: 6) {
                    Text(video.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2).multilineTextAlignment(.center)

                    HStack(spacing: 6) {
                        if !video.userAvatar.isEmpty {
                            AsyncImage(url: URL(string: video.userAvatar)) { phase in
                                if let img = phase.image {
                                    img.resizable().scaledToFill()
                                        .frame(width: 22, height: 22).clipShape(Circle())
                                }
                            }
                        }
                        if !video.userName.isEmpty {
                            Text("@\(video.userName)")
                                .font(.system(size: 13)).foregroundColor(.white.opacity(0.75))
                        }
                    }
                    Text(video.duration)
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, 32)
                Spacer()
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            YBoxBananaPlayerView(
                vodId: video.vodId, title: video.title, cover: video.cover,
                duration: video.duration, platform: platform,
                isLongVideo: false
            )
        }
    }
}

// MARK: - 演员Tab（zfvwi8 无演员 API，暂用专题列表；yBox 原生有演员导航）

struct YBoxBananaActorTab: View {
    let platform: YBoxPlatform2
    @StateObject private var svc = YBoxService2.shared
    @State private var actors: [YBoxBananaSpecial] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var currentPage = 1

    var body: some View {
        Group {
            if isLoading && actors.isEmpty {
                VStack { Spacer(); ProgressView().scaleEffect(1.5); Spacer() }
            } else if let err = loadError, actors.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 50)).foregroundColor(.secondary)
                    Text(err).font(.system(size: 15))
                    Button(action: { loadError = nil; loadSpecials() }) {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.system(size: 14))
                            .padding(.horizontal,20).padding(.vertical,8)
                            .background(Color.accentColor.opacity(0.1)).cornerRadius(8)
                    }
                    Spacer()
                }
            } else if actors.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.2.slash").font(.system(size: 40)).foregroundColor(.secondary)
                    Text("暂无演员数据").foregroundColor(.secondary)
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                        spacing: 14
                    ) {
                        ForEach(actors) { sp in
                            NavigationLink(destination: YBoxBananaSpecialVideoList(
                                special: sp, platform: platform
                            )) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ZStack(alignment: .bottomTrailing) {
                                        AsyncImage(url: URL(string: sp.spCover)) { phase in
                                            switch phase {
                                            case .success(let img):
                                                img.resizable().aspectRatio(contentMode: .fill)
                                            default:
                                                ZStack {
                                                    Color.gray.opacity(0.2)
                                                    Image(systemName: "photo").foregroundColor(.gray)
                                                }
                                            }
                                        }
                                        .frame(height: 120).cornerRadius(12).clipped()

                                        Text("\(sp.itemCount)部")
                                            .font(.system(size: 10)).foregroundColor(.white)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.black.opacity(0.5)).cornerRadius(4)
                                            .padding(6)
                                    }
                                    Text(sp.spName)
                                        .font(.system(size: 13, weight: .medium)).lineLimit(2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .onAppear { loadSpecials() }
    }

    private func loadSpecials() {
        isLoading = true; loadError = nil
        Task {
            let result = await svc.fetchBananaSpecials(page: 1)
            await MainActor.run {
                actors = result; isLoading = false
                if result.isEmpty { loadError = "暂时无法连接服务器" }
            }
        }
    }
}

// MARK: - 专题视频列表

// MARK: - 演员/专题详情页（zfvwi8 无 session 级视频过滤，兜底全列表）
struct YBoxBananaSpecialVideoList: View {
    let special: YBoxBananaSpecial
    let platform: YBoxPlatform2
    @StateObject private var svc = YBoxService2.shared
    @State private var videos: [YBoxBananaSpecialVideo] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        Group {
            if videos.isEmpty && isLoading {
                VStack { Spacer(); ProgressView().scaleEffect(1.5); Spacer() }
            } else if let err = loadError, videos.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "film.slash").font(.system(size: 50)).foregroundColor(.secondary)
                    Text(err).font(.system(size: 15))
                    Button(action: { loadError = nil; loadVideos() }) {
                        Label("重试", systemImage: "arrow.clockwise").font(.system(size: 14))
                            .padding(.horizontal,20).padding(.vertical,8)
                            .background(Color.accentColor.opacity(0.1)).cornerRadius(8)
                    }
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // 头信息
                        HStack(spacing: 12) {
                            AsyncImage(url: URL(string: special.spCover)) { phase in
                                if let img = phase.image {
                                    img.resizable().aspectRatio(contentMode: .fill)
                                        .frame(width: 70, height: 90).cornerRadius(10).clipped()
                                }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(special.spName).font(.system(size: 18, weight: .bold))
                                Text("共 \(special.itemCount) 部作品").font(.system(size: 13)).foregroundColor(.secondary)
                                if videos.isEmpty {
                                    Text("视频列表加载中...").font(.system(size: 12)).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.top, 8)

                        Divider()

                        if !videos.isEmpty {
                            LazyVGrid(
                                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                                spacing: 14
                            ) {
                                ForEach(videos) { video in
                                    NavigationLink(destination: YBoxBananaPlayerView(
                                        vodId: video.vodId, title: video.title,
                                        cover: video.cover, duration: video.duration,
                                        platform: platform
                                    )) {
                                        BananaVideoCard(
                                            cover: video.cover, title: video.title,
                                            duration: video.duration, score: video.score,
                                            areaName: nil
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
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle(special.spName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadVideos() }
    }

    private func loadVideos() {
        isLoading = true; loadError = nil
        Task {
            let result = await svc.fetchBananaSpecialVideos(spId: special.spId, page: 1)
            await MainActor.run {
                videos = result; isLoading = false
                if result.isEmpty { loadError = "暂无相关视频" }
            }
        }
    }
}

// MARK: - 视频卡片组件

// MARK: - 香蕉秀视频卡片（MissAV 样式：小长方形封面，by QClaw 2026-07-07）
struct BananaVideoCard: View {
    let cover: String
    let title: String
    let duration: String
    let score: String?
    let areaName: String?

    private var bottomLabel: String {
        var parts: [String] = []
        if let s = score, !s.isEmpty { parts.append(s) }
        if let a = areaName, !a.isEmpty { parts.append(a) }
        if !duration.isEmpty { parts.append(duration) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: URL(string: cover)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Rectangle()
                            .fill(Color.gray.opacity(0.18))
                            .overlay(Image(systemName: "play.rectangle.fill").foregroundColor(.white.opacity(0.5)))
                    }
                }
                .frame(height: 88)
                .frame(maxWidth: .infinity)
                .clipped()

                LinearGradient(
                    colors: [Color.black.opacity(0.0), Color.black.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 88)

                if !bottomLabel.isEmpty {
                    Text(bottomLabel)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Capsule())
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 播放页

struct YBoxBananaPlayerView: View {
    let vodId: String
    let title: String
    let cover: String
    let duration: String
    let platform: YBoxPlatform2
    var isLongVideo: Bool = true

    @StateObject private var svc = YBoxService2.shared
    @State private var playURL: String?
    @State private var isLoading = true
    @State private var errorMsg: String?
    @State private var showPlayer = false
    @State private var vodItem: VodItem?

    var body: some View {
        VStack(spacing: 12) {
            AsyncImage(url: URL(string: cover)) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fit).cornerRadius(12)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.2))
                        .aspectRatio(16/9, contentMode: .fit).cornerRadius(12)
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .center) {
                if isLoading {
                    ProgressView().scaleEffect(2).tint(.white)
                } else if let _ = playURL {
                    Button(action: { showPlayer = true }) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 60)).foregroundColor(.white.opacity(0.9))
                    }
                } else if let e = errorMsg {
                    VStack(spacing: 12) {
                        Image(systemName: "play.slash")
                            .font(.system(size: 40)).foregroundColor(.white.opacity(0.8))
                        Text(e).font(.system(size: 14)).foregroundColor(.white.opacity(0.9))
                        HStack(spacing: 16) {
                            Button(action: { loadPlayURL() }) {
                                Label("重试", systemImage: "arrow.clockwise")
                                    .font(.system(size: 13)).foregroundColor(.white)
                                    .padding(.horizontal, 16).padding(.vertical, 8)
                                    .background(Color.accentColor).cornerRadius(8)
                            }
                            Button(action: {
                                // 尝试切换长短视频端点
                                isLongVideo.toggle()
                                loadPlayURL()
                            }) {
                                Label("切换线路", systemImage: "arrow.triangle.swap")
                                    .font(.system(size: 13)).foregroundColor(.white)
                                    .padding(.horizontal, 16).padding(.vertical, 8)
                                    .background(Color.white.opacity(0.2)).cornerRadius(8)
                            }
                        }
                    }
                }
            }

            Text(title)
                .font(.system(size: 18, weight: .bold)).padding(.horizontal, 16)
            Label("时长: \(duration)", systemImage: "clock")
                .font(.system(size: 13)).foregroundColor(.secondary)
            Spacer()
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle("播放").navigationBarTitleDisplayMode(.inline)
        .onAppear { loadPlayURL() }
        .fullScreenCover(isPresented: $showPlayer) {
            if let vod = vodItem { VideoDetailView(video: vod) }
        }
    }

    private func loadPlayURL() {
        isLoading = true; errorMsg = nil
        Task {
            if let url = await svc.fetchBananaPlayURL(vodId: vodId, isLongVideo: isLongVideo) {
                await MainActor.run {
                    playURL = url; isLoading = false
                    vodItem = VodItem(
                        vodId: vodId, vodName: title, vodPic: cover,
                        vodRemarks: "[福利]\(platform.name)", vodPlayUrl: url
                    )
                }
            } else {
                await MainActor.run {
                    errorMsg = "获取播放地址失败，请检查网络"; isLoading = false
                }
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

// MARK: - 通用爬虫平台内容视图
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
                    Text("加载平台配置...").font(.system(size: 13)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            guard let pid = platform.crawlerPlatformId,
                  let cfg = WelfareCrawlerConfig.config(for: pid) else { return }
            welfarePlatform = WelfarePlatform.adaptive(
                id: cfg.platformId, name: cfg.platformName, searchPrefix: cfg.searchPrefix
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
                    Button(action: { selectedChannelURL = ch.address; showPlayer = true }) {
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
                    vodId: url, vodName: item.title, vodPic: item.img,
                    vodRemarks: "[福利]直播", vodPlayUrl: url
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
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ], spacing: 16) {
                        ForEach(comics) { comic in
                            Button(action: {
                                selectedComic = VodItem(
                                    vodId: comic.href ?? comic.title,
                                    vodName: comic.title, vodPic: comic.cover,
                                    vodRemarks: "[福利]漫画"
                                )
                                showPlayer = true
                            }) {
                                VStack(spacing: 4) {
                                    AsyncImage(url: URL(string: comic.cover)) { p in
                                        if let img = p.image {
                                            img.resizable().aspectRatio(contentMode: .fill)
                                                .frame(height: 140).cornerRadius(8)
                                        } else {
                                            RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.2)).frame(height: 140)
                                        }
                                    }
                                    Text(comic.title).font(.system(size: 11)).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle("漫画")
        .fullScreenCover(isPresented: $showPlayer) {
            if let vod = selectedComic { VideoDetailView(video: vod) }
        }
        .onAppear {
            Task {
                let result = await ybox.fetch18Comics()
                await MainActor.run { comics = result; isLoading = false }
            }
        }
    }
}
