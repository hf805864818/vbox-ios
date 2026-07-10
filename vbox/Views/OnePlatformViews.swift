//
//  OnePlatformViews.swift
//  vbox
//
//  One 平台视图层 — 首页、分类、视频列表、详情、播放器
//
//  页面架构：
//    OnePlatformHomeView  (首页 Tab: 发现 / 每日推荐 / 专辑)
//      → OneDiscoveryTab     (发现页：分类横滚 + 视频网格)
//      → OneDailyTab         (每日推荐)
//      → OneAlbumTab         (专辑/漫画)
//        → OneVideoListView  (视频列表)
//          → OneVideoDetailView (视频详情 + 播放)
//
//  Created by FLEX++ Reverse Engineering on 2026/07/10.
//

import SwiftUI
import AVKit

// MARK: - One 平台首页

struct OnePlatformHomeView: View {
    let platform: YBoxPlatform2
    @StateObject private var svc = OnePlatformService.shared
    @State private var selectedTab = 0
    private let tabs = ["发现", "每日推荐", "专辑"]

    var body: some View {
        VStack(spacing: 0) {
            // 顶部 Tab
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
            .padding(.top, 8)
            .padding(.horizontal, 8)

            Divider()

            TabView(selection: $selectedTab) {
                OneDiscoveryTab(platform: platform).tag(0)
                OneDailyTab(platform: platform).tag(1)
                OneAlbumTab(platform: platform).tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationTitle("One 平台")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink(destination: OneSettingsView()) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16))
                }
            }
        }
    }
}

// MARK: - 发现 Tab：分类横滚 + 视频网格

struct OneDiscoveryTab: View {
    let platform: YBoxPlatform2
    @StateObject private var svc = OnePlatformService.shared
    @State private var categories: [OneCategory] = []
    @State private var selectedCateIdx = 0
    @State private var videos: [OneVideoItem] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var currentPage = 1
    @State private var hasMore = true
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            if !svc.isConfigured {
                // 未配置提示
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "lock.trianglebadge.exclamationmark")
                        .font(.system(size: 50))
                        .foregroundColor(.orange)
                    Text("需要配置 One 平台 Token")
                        .font(.system(size: 16, weight: .medium))
                    Text("请点击右上角设置按钮，填入从 ybox 中提取的 token 和 user-key")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                    NavigationLink(destination: OneSettingsView()) {
                        Text("去配置")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    Spacer()
                }
                .padding(20)
            } else if categories.isEmpty && isLoading {
                Spacer()
                ProgressView().scaleEffect(1.5)
                Spacer()
            } else if let err = loadError, videos.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 50)).foregroundColor(.secondary)
                    Text(err).font(.system(size: 15, weight: .medium))
                        .multilineTextAlignment(.center)
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
                                selectedCateIdx = idx
                                refreshVideos()
                            }) {
                                Text(cat.name)
                                    .font(.system(size: 13, weight: selectedCateIdx == idx ? .bold : .regular))
                                    .foregroundColor(selectedCateIdx == idx ? .white : .secondary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule()
                                            .fill(selectedCateIdx == idx ? Color.accentColor : Color.gray.opacity(0.15))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                Divider()

                // 视频网格
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2),
                        spacing: 12
                    ) {
                        ForEach(videos) { video in
                            NavigationLink(destination: OneVideoDetailView(
                                video: video,
                                platform: platform
                            )) {
                                OneVideoCard(video: video)
                            }
                            .buttonStyle(.plain)
                        }

                        // 加载更多
                        if hasMore && !videos.isEmpty {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                                .onAppear { loadMore() }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                }
            }
        }
        .onAppear {
            if categories.isEmpty {
                loadCategories()
            }
        }
    }

    private func loadCategories() {
        Task {
            let cats = await svc.fetchCategories()
            await MainActor.run {
                self.categories = cats
                self.isLoading = false
                if !cats.isEmpty {
                    refreshVideos()
                }
            }
        }
    }

    private func refreshVideos() {
        guard selectedCateIdx < categories.count else { return }
        let cateId = categories[selectedCateIdx].cateId
        currentPage = 1
        hasMore = true
        videos = []
        isLoading = true
        loadError = nil

        Task {
            let result = await svc.fetchVideos(categoryId: cateId, page: 1)
            await MainActor.run {
                self.videos = result.items
                self.hasMore = result.hasMore
                self.currentPage = 1
                self.isLoading = false
                if result.items.isEmpty {
                    self.loadError = "暂无视频数据"
                }
            }
        }
    }

    private func loadMore() {
        guard !isLoadingMore, hasMore else { return }
        guard selectedCateIdx < categories.count else { return }

        isLoadingMore = true
        let nextPage = currentPage + 1
        let cateId = categories[selectedCateIdx].cateId

        Task {
            let result = await svc.fetchVideos(categoryId: cateId, page: nextPage)
            await MainActor.run {
                if !result.items.isEmpty {
                    self.videos.append(contentsOf: result.items)
                    self.currentPage = nextPage
                    self.hasMore = result.hasMore
                } else {
                    self.hasMore = false
                }
                self.isLoadingMore = false
            }
        }
    }
}

// MARK: - 每日推荐 Tab

struct OneDailyTab: View {
    let platform: YBoxPlatform2
    @StateObject private var svc = OnePlatformService.shared
    @State private var videos: [OneVideoItem] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if isLoading {
                Spacer().frame(height: 80)
                ProgressView().scaleEffect(1.5)
            } else if let err = loadError {
                VStack(spacing: 16) {
                    Spacer().frame(height: 80)
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 50)).foregroundColor(.secondary)
                    Text(err).font(.system(size: 14)).foregroundColor(.secondary)
                    Button("重试") { loadDaily() }
                        .font(.system(size: 14))
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.1)).cornerRadius(8)
                }
                .frame(maxWidth: .infinity)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2),
                    spacing: 12
                ) {
                    ForEach(videos) { video in
                        NavigationLink(destination: OneVideoDetailView(
                            video: video, platform: platform
                        )) {
                            OneVideoCard(video: video)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
        .onAppear { if videos.isEmpty { loadDaily() } }
    }

    private func loadDaily() {
        isLoading = true
        loadError = nil
        Task {
            let result = await svc.fetchDailyRecommend()
            await MainActor.run {
                self.videos = result
                self.isLoading = false
                if result.isEmpty {
                    self.loadError = "今日暂无推荐"
                }
            }
        }
    }
}

// MARK: - 专辑 Tab

struct OneAlbumTab: View {
    let platform: YBoxPlatform2
    @StateObject private var svc = OnePlatformService.shared
    @State private var albums: [OneAlbum] = []
    @State private var isLoading = true
    @State private var currentPage = 1
    @State private var hasMore = true

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if isLoading && albums.isEmpty {
                Spacer().frame(height: 80)
                ProgressView().scaleEffect(1.5)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                    spacing: 12
                ) {
                    ForEach(albums) { album in
                        NavigationLink(destination: OneAlbumDetailView(album: album, platform: platform)) {
                            OneAlbumCard(album: album)
                        }
                        .buttonStyle(.plain)
                    }

                    if hasMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .onAppear { loadMore() }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
        .onAppear { if albums.isEmpty { loadAlbums() } }
    }

    private func loadAlbums() {
        Task {
            let result = await svc.fetchAlbums(page: 1)
            await MainActor.run {
                self.albums = result
                self.isLoading = false
                self.currentPage = 1
                self.hasMore = result.count >= 20
            }
        }
    }

    private func loadMore() {
        let next = currentPage + 1
        Task {
            let result = await svc.fetchAlbums(page: next)
            await MainActor.run {
                if !result.isEmpty {
                    self.albums.append(contentsOf: result)
                    self.currentPage = next
                } else {
                    self.hasMore = false
                }
            }
        }
    }
}

// MARK: - 视频卡片

struct OneVideoCard: View {
    let video: OneVideoItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 封面
            ZStack(alignment: .bottomTrailing) {
                PlatformAsyncImage(urlString: video.cover, mode: .plain)
                    .aspectRatio(3/4, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .cornerRadius(8)

                // 时长
                if !video.duration.isEmpty {
                    Text(video.duration)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(4)
                        .padding(6)
                }
            }

            // 标题
            Text(video.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            // 底部信息
            HStack(spacing: 4) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(formatCount(video.views))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                if let rating = video.rating, !rating.isEmpty {
                    Text(rating)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.orange)
                }
            }
        }
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 10000 {
            return String(format: "%.1f万", Double(count) / 10000)
        }
        return "\(count)"
    }
}

// MARK: - 专辑卡片

struct OneAlbumCard: View {
    let album: OneAlbum

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PlatformAsyncImage(urlString: album.cover, mode: .plain)
                .aspectRatio(2/3, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipped()
                .cornerRadius(8)
                .overlay(alignment: .bottomTrailing) {
                    if album.itemCount > 0 {
                        Text("\(album.itemCount)P")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(4)
                            .padding(6)
                    }
                }

            Text(album.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }
}

// MARK: - 视频详情页

struct OneVideoDetailView: View {
    let video: OneVideoItem
    let platform: YBoxPlatform2
    @StateObject private var svc = OnePlatformService.shared
    @State private var detail: OneVideoDetail?
    @State private var playURL: String?
    @State private var isLoading = true
    @State private var errorMsg: String?
    @State private var showPlayer = false
    @State private var selectedLine = 0
    @State private var vodItem: VodItem?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                // 封面 + 播放按钮
                ZStack {
                    PlatformAsyncImage(urlString: video.cover, mode: .plain)
                        .aspectRatio(16/9, contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .clipped()

                    if isLoading {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                    } else if let url = playURL {
                        Button(action: { showPlayer = true }) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 60))
                                .foregroundColor(.white.opacity(0.9))
                                .shadow(radius: 10)
                        }
                    } else if let msg = errorMsg {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 36))
                                .foregroundColor(.orange)
                            Text(msg)
                                .font(.system(size: 13))
                                .foregroundColor(.white)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .background(Color.black)

                // 标题
                VStack(alignment: .leading, spacing: 8) {
                    Text(video.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        if !video.duration.isEmpty {
                            Label(video.duration, systemImage: "clock")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        Label("\(video.views)", systemImage: "eye")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        if let rating = video.rating, !rating.isEmpty {
                            Label(rating, systemImage: "star.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.orange)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                // 播放线路选择
                if let detail = detail, !detail.playUrls.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("播放线路")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 16)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(detail.playUrls.enumerated()), id: \.offset) { idx, source in
                                    Button(action: {
                                        selectedLine = idx
                                        playURL = source.url
                                        vodItem = VodItem(
                                            vodId: video.articleId,
                                            vodName: video.title,
                                            vodPic: video.cover,
                                            vodRemarks: "[福利]One平台",
                                            vodPlayUrl: source.url
                                        )
                                    }) {
                                        Text(source.name)
                                            .font(.system(size: 13, weight: selectedLine == idx ? .bold : .regular))
                                            .foregroundColor(selectedLine == idx ? .white : .secondary)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 6)
                                            .background(
                                                Capsule()
                                                    .fill(selectedLine == idx ? Color.accentColor : Color.gray.opacity(0.15))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }

                // 标签
                if !video.tags.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("标签")
                            .font(.system(size: 14, weight: .semibold))
                        WrappingHStack(data: video.tags, spacing: 8, lineSpacing: 8) { tag in
                            Text(tag)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.gray.opacity(0.15))
                                .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                // 简介
                if let desc = detail?.description, !desc.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("简介")
                            .font(.system(size: 14, weight: .semibold))
                        Text(desc)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .lineLimit(nil)
                    }
                    .padding(.horizontal, 16)
                }

                Spacer().frame(height: 20)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showPlayer) {
            if let vod = vodItem {
                NavigationView {
                    VideoDetailView(video: vod)
                }
            }
        }
        .onAppear { loadDetail() }
    }

    private func loadDetail() {
        isLoading = true
        errorMsg = nil

        Task {
            // 先获取详情
            let d = await svc.fetchVideoDetail(articleId: video.articleId)
            // 同时获取播放地址
            let url = await svc.fetchPlayURL(articleId: video.articleId)

            await MainActor.run {
                self.detail = d

                if let playUrl = url, !playUrl.isEmpty {
                    self.playURL = playUrl
                    self.vodItem = VodItem(
                        vodId: video.articleId,
                        vodName: video.title,
                        vodPic: video.cover,
                        vodRemarks: "[福利]One平台",
                        vodPlayUrl: playUrl
                    )
                } else if let firstUrl = d?.playUrls.first?.url {
                    self.playURL = firstUrl
                    self.vodItem = VodItem(
                        vodId: video.articleId,
                        vodName: video.title,
                        vodPic: video.cover,
                        vodRemarks: "[福利]One平台",
                        vodPlayUrl: firstUrl
                    )
                } else {
                    self.errorMsg = "无法获取播放地址"
                }

                self.isLoading = false
            }
        }
    }
}

// MARK: - 专辑详情页

struct OneAlbumDetailView: View {
    let album: OneAlbum
    let platform: YBoxPlatform2
    @StateObject private var svc = OnePlatformService.shared
    @State private var chapters: [OneChapter] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                // 顶部信息
                HStack(alignment: .top, spacing: 12) {
                    PlatformAsyncImage(urlString: album.cover, mode: .plain)
                        .frame(width: 100, height: 150)
                        .clipped()
                        .cornerRadius(8)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(album.title)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let rating = album.rating, !rating.isEmpty {
                            Text("评分: \(rating)")
                                .font(.system(size: 13))
                                .foregroundColor(.orange)
                        }

                        Text("共 \(album.itemCount) 章")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        if !album.description.isEmpty {
                            Text(album.description)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }

                        Spacer()
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Divider()

                // 章节列表
                VStack(alignment: .leading, spacing: 8) {
                    Text("章节目录")
                        .font(.system(size: 15, weight: .bold))
                        .padding(.horizontal, 16)

                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                            spacing: 8
                        ) {
                            ForEach(chapters) { chap in
                                Button(action: {
                                    // 跳转阅读/播放
                                }) {
                                    Text(chap.title)
                                        .font(.system(size: 12))
                                        .foregroundColor(chap.isPaid ? .orange : .primary)
                                        .lineLimit(1)
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 4)
                                        .frame(maxWidth: .infinity)
                                        .background(Color.gray.opacity(0.1))
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                Spacer().frame(height: 20)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadChapters() }
    }

    private func loadChapters() {
        Task {
            let result = await svc.fetchChapters(albumId: album.albumId)
            await MainActor.run {
                self.chapters = result
                self.isLoading = false
            }
        }
    }
}

// MARK: - 设置页

struct OneSettingsView: View {
    @StateObject private var svc = OnePlatformService.shared
    @State private var tokenInput: String = ""
    @State private var userKeyInput: String = ""
    @State private var uuidInput: String = ""
    @State private var showSaved = false

    var body: some View {
        Form {
            Section {
                TextField("JWT Token", text: $tokenInput, axis: .vertical)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("user-key", text: $userKeyInput)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("设备 UUID", text: $uuidInput)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            } header: {
                Text("认证信息")
            } footer: {
                Text("从 ybox 中提取 One 平台的 token、user-key 和 uuid。\n提取方法：\n1. 使用 Thor / HTTP Catcher 抓包\n2. 或使用 FLEX++ Hook NSUserDefaults")
            }

            Section {
                Button(action: save) {
                    HStack {
                        Spacer()
                        Text("保存配置")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .cornerRadius(10)
                    .listRowInsets(EdgeInsets())
                }
            }
            .listRowBackground(Color.clear)

            Section("加密参数") {
                HStack {
                    Text("AES 算法")
                    Spacer()
                    Text("AES-128-CBC")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("AES Key")
                    Spacer()
                    Text("0f48a4e7...")
                        .foregroundColor(.secondary)
                        .font(.system(.footnote, design: .monospaced))
                }
                HStack {
                    Text("填充方式")
                    Spacer()
                    Text("PKCS7Padding")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("API 域名")
                    Spacer()
                    Text("api.em1oifd0.com")
                        .foregroundColor(.secondary)
                        .font(.system(.footnote, design: .monospaced))
                }
            }

            Section("状态") {
                HStack {
                    Text("配置状态")
                    Spacer()
                    if svc.isConfigured {
                        Label("已配置", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Label("未配置", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                }
            }
        }
        .navigationTitle("One 平台设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            tokenInput = svc.token
            userKeyInput = svc.userKey
            uuidInput = svc.uuid
        }
        .alert("保存成功", isPresented: $showSaved) {
            Button("确定", role: .cancel) { }
        } message: {
            Text("One 平台配置已保存")
        }
    }

    private func save() {
        svc.saveToken(tokenInput, userKey: userKeyInput, uuid: uuidInput)
        showSaved = true
    }
}

// MARK: - 辅助视图：自适应换行布局

struct WrappingHStack<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let data: Data
    let spacing: CGFloat
    let lineSpacing: CGFloat
    let content: (Data.Element) -> Content

    @State private var totalHeight: CGFloat = .zero

    var body: some View {
        GeometryReader { geo in
            self.generateContent(in: geo)
        }
        .frame(height: totalHeight)
    }

    private func generateContent(in g: GeometryProxy) -> some View {
        var width = CGFloat.zero
        var height = CGFloat.zero

        return ZStack(alignment: .topLeading) {
            ForEach(Array(data), id: \.self) { item in
                content(item)
                    .padding(.trailing, spacing)
                    .padding(.bottom, lineSpacing)
                    .alignmentGuide(.leading) { d in
                        if abs(width - d.width) > g.size.width {
                            width = 0
                            height -= d.height
                        }
                        let result = width
                        if item == data.last {
                            width = 0
                        } else {
                            width -= d.width
                        }
                        return result
                    }
                    .alignmentGuide(.top) { _ in
                        let result = height
                        if item == data.last {
                            height = 0
                        }
                        return result
                    }
            }
        }
        .background(HeightReaderView(height: $totalHeight))
    }
}

private struct HeightReaderView: View {
    @Binding var height: CGFloat

    var body: some View {
        GeometryReader { geo -> Color in
            DispatchQueue.main.async {
                height = geo.size.height
            }
            return Color.clear
        }
    }
}
