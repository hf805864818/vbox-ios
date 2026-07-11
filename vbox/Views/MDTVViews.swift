//
//  MDTVViews.swift
//  vbox
//
//  麻豆平台（MDTV）视图层 — 首页、分类、视频列表、详情、播放器
//
//  页面架构：
//    MDTVHomeView           (首页 Tab: 推荐 / 分类 / 标签)
//      → MDTVRecommendTab     (推荐页：视频网格)
//      → MDTVCategoryTab      (分类页：分类网格)
//      → MDTVTagTab           (标签页：标签云)
//        → MDTVVideoListView  (视频列表)
//          → MDTVVideoDetailView (视频详情 + 播放)
//
//  Created by Reverse Engineering on 2026/07/10.
//

import SwiftUI
import AVKit

// MARK: - 麻豆平台首页

struct MDTVHomeView: View {
    let platform: YBoxPlatform2
    @StateObject private var svc = MDTVService.shared
    @State private var selectedTab = 0

    /// 当前 Tab 列表
    private var tabs: [String] { svc.homeTabs }

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

            // 动态 Tab 内容
            TabView(selection: $selectedTab) {
                ForEach(0..<tabs.count, id: \.self) { i in
                    tabContent(for: i)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationTitle("麻豆平台")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink(destination: MDTVSettingsView()) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16))
                }
            }
        }
        .onAppear {
            // 进入页面自动尝试建立连接并刷新 Tab 配置（后台进行）
            Task {
                // 1. 尝试刷新远程 Tab 配置
                _ = try? await svc.fetchTabConfig()

                // 2. 尝试加载分类来触发密钥探测
                if !svc.isKeyFound {
                    _ = try? await svc.fetchCategories()
                }
            }
        }
    }

    /// 根据 Tab 名称返回对应的内容视图
    @ViewBuilder
    private func tabContent(for index: Int) -> some View {
        if index < tabs.count {
            switch tabs[index] {
            case "推荐":
                MDTVRecommendTab(platform: platform)
            case "分类":
                MDTVCategoryTab(platform: platform)
            case "标签":
                MDTVTagTab(platform: platform)
            default:
                // 未知 Tab，默认显示视频列表
                MDTVCustomTab(platform: platform, tabName: tabs[index])
            }
        } else {
            EmptyView()
        }
    }
}

// MARK: - 自定义 Tab 内容（用于远程下发的未知 Tab）

struct MDTVCustomTab: View {
    let platform: YBoxPlatform2
    let tabName: String

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled")
                .font(.system(size: 50))
                .foregroundColor(.secondary)
            Text("\(tabName) 页面")
                .font(.system(size: 18, weight: .medium))
            Text("该 Tab 尚未配置具体内容")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

// MARK: - 推荐 Tab

struct MDTVRecommendTab: View {
    let platform: YBoxPlatform2
    @StateObject private var svc = MDTVService.shared
    @State private var videos: [MDTVVideoItem] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var currentPage = 1
    @State private var hasMore = true
    @State private var loadError: String?

    // 临时占位数据（密钥确认前显示骨架）
    private let placeholderVideos: [MDTVVideoItem] = (0..<12).map { i in
        MDTVVideoItem(
            videoId: "placeholder_\(i)",
            title: "加载中...",
            cover: "",
            duration: "00:00",
            views: 0,
            likes: 0,
            categoryId: "",
            categoryName: nil,
            tags: [],
            rating: nil,
            uploadTime: nil
        )
    }

    var body: some View {
        ScrollView {
            if isLoading && videos.isEmpty {
                // 骨架加载
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ], spacing: 12) {
                    ForEach(placeholderVideos) { video in
                        MDTVVideoCard(video: video, isPlaceholder: true)
                    }
                }
                .padding(12)
            } else if let err = loadError, videos.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary)
                    Text(err)
                        .font(.system(size: 15, weight: .medium))
                        .multilineTextAlignment(.center)
                    Button(action: {
                        loadError = nil
                        refreshVideos()
                    }) {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.system(size: 14))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.1))
                            .cornerRadius(8)
                    }
                    if !svc.isKeyFound {
                        Text("提示：正在自动探测加密密钥，请稍候...")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: 400)
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ], spacing: 12) {
                    ForEach(videos) { video in
                        NavigationLink(destination: MDTVVideoDetailView(video: video)) {
                            MDTVVideoCard(video: video)
                        }
                        .buttonStyle(.plain)
                    }

                    if isLoadingMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
                .padding(12)

                if hasMore && !videos.isEmpty {
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            loadMore()
                        }
                }
            }
        }
        .onAppear {
            if videos.isEmpty {
                refreshVideos()
            }
        }
        .refreshable {
            refreshVideos()
        }
    }

    private func refreshVideos() {
        isLoading = true
        currentPage = 1
        hasMore = true
        Task {
            do {
                let result = try await svc.fetchVideos(page: 1)
                await MainActor.run {
                    videos = result
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    loadError = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func loadMore() {
        guard !isLoadingMore && hasMore else { return }
        isLoadingMore = true
        Task {
            do {
                let result = try await svc.fetchVideos(page: currentPage + 1)
                await MainActor.run {
                    if result.isEmpty {
                        hasMore = false
                    } else {
                        videos.append(contentsOf: result)
                        currentPage += 1
                    }
                    isLoadingMore = false
                }
            } catch {
                await MainActor.run {
                    isLoadingMore = false
                }
            }
        }
    }
}

// MARK: - 分类 Tab

struct MDTVCategoryTab: View {
    let platform: YBoxPlatform2
    @StateObject private var svc = MDTVService.shared
    @State private var categories: [MDTVCategory] = []
    @State private var isLoading = true
    @State private var loadError: String?

    // 临时占位分类
    private let placeholderCategories: [MDTVCategory] = (0..<9).map { i in
        MDTVCategory(
            cateId: "cat_\(i)",
            name: "分类\(i+1)",
            icon: nil,
            sortOrder: i
        )
    }

    var body: some View {
        ScrollView {
            if isLoading {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ], spacing: 12) {
                    ForEach(placeholderCategories) { cat in
                        MDTVCategoryCard(category: cat, isPlaceholder: true)
                    }
                }
                .padding(12)
            } else if let err = loadError, categories.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "square.grid.2x2.slash")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary)
                    Text(err)
                        .font(.system(size: 15, weight: .medium))
                        .multilineTextAlignment(.center)
                    Button(action: {
                        loadError = nil
                        loadCategories()
                    }) {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.system(size: 14))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.1))
                            .cornerRadius(8)
                    }
                    Spacer()
                }
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: 400)
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ], spacing: 12) {
                    ForEach(categories) { category in
                        NavigationLink(destination: MDTVVideoListView(category: category)) {
                            MDTVCategoryCard(category: category)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
        }
        .onAppear {
            if categories.isEmpty {
                loadCategories()
            }
        }
        .refreshable {
            loadCategories()
        }
    }

    private func loadCategories() {
        isLoading = true
        Task {
            do {
                let result = try await svc.fetchCategories()
                await MainActor.run {
                    categories = result
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    loadError = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - 标签 Tab

struct MDTVTagTab: View {
    let platform: YBoxPlatform2
    @StateObject private var svc = MDTVService.shared
    @State private var tags: [MDTVTag] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else if let err = loadError, tags.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "tag.slash")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary)
                    Text(err)
                        .font(.system(size: 15, weight: .medium))
                        .multilineTextAlignment(.center)
                    Button(action: {
                        loadError = nil
                        loadTags()
                    }) {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.system(size: 14))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.1))
                            .cornerRadius(8)
                    }
                    Spacer()
                }
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: 400)
            } else {
                // 标签云
                FlexibleView(data: tags, spacing: 8, alignment: .leading) { tag in
                    NavigationLink(destination: MDTVVideoListView(tag: tag)) {
                        Text(tag.name)
                            .font(.system(size: 14))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.1))
                            .foregroundColor(.accentColor)
                            .cornerRadius(.infinity)
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
        }
        .onAppear {
            if tags.isEmpty {
                loadTags()
            }
        }
        .refreshable {
            loadTags()
        }
    }

    private func loadTags() {
        isLoading = true
        Task {
            do {
                let result = try await svc.fetchTags()
                await MainActor.run {
                    tags = result
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    loadError = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - 视频列表页

struct MDTVVideoListView: View {
    let category: MDTVCategory?
    let tag: MDTVTag?
    @StateObject private var svc = MDTVService.shared
    @State private var videos: [MDTVVideoItem] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var currentPage = 1
    @State private var hasMore = true
    @State private var loadError: String?

    init(category: MDTVCategory) {
        self.category = category
        self.tag = nil
    }

    init(tag: MDTVTag) {
        self.category = nil
        self.tag = tag
    }

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else if let err = loadError, videos.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    Text(err)
                        .font(.system(size: 14))
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        loadError = nil
                        loadVideos()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ], spacing: 12) {
                    ForEach(videos) { video in
                        NavigationLink(destination: MDTVVideoDetailView(video: video)) {
                            MDTVVideoCard(video: video)
                        }
                        .buttonStyle(.plain)
                    }

                    if isLoadingMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
                .padding(12)

                if hasMore && !videos.isEmpty {
                    Color.clear
                        .frame(height: 1)
                        .onAppear { loadMore() }
                }
            }
        }
        .navigationTitle(category?.name ?? tag?.name ?? "视频列表")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if videos.isEmpty {
                loadVideos()
            }
        }
        .refreshable {
            refreshVideos()
        }
    }

    private func loadVideos() {
        isLoading = true
        Task {
            do {
                let result = try await svc.fetchVideos(categoryId: category?.cateId, page: 1)
                await MainActor.run {
                    videos = result
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    loadError = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func refreshVideos() {
        currentPage = 1
        hasMore = true
        loadVideos()
    }

    private func loadMore() {
        guard !isLoadingMore && hasMore else { return }
        isLoadingMore = true
        Task {
            do {
                let result = try await svc.fetchVideos(categoryId: category?.cateId, page: currentPage + 1)
                await MainActor.run {
                    if result.isEmpty {
                        hasMore = false
                    } else {
                        videos.append(contentsOf: result)
                        currentPage += 1
                    }
                    isLoadingMore = false
                }
            } catch {
                await MainActor.run {
                    isLoadingMore = false
                }
            }
        }
    }
}

// MARK: - 视频详情页

struct MDTVVideoDetailView: View {
    let video: MDTVVideoItem
    @StateObject private var svc = MDTVService.shared
    @State private var detail: MDTVVideoDetail?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showPlayer = false
    @State private var player: AVPlayer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 封面图（点击播放）
                Button(action: {
                    playVideo()
                }) {
                    ZStack {
                        if let cover = URL(string: svc.imageURL(video.cover)) {
                            AsyncImage(url: cover) { phase in
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

                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.white.opacity(0.9))
                            .shadow(radius: 10)
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16/9, contentMode: .fit)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                // 标题
                Text(video.title)
                    .font(.system(size: 18, weight: .bold))
                    .padding(.horizontal, 16)

                // 信息行
                HStack(spacing: 16) {
                    Label("\(video.views)", systemImage: "eye")
                    Label("\(video.likes)", systemImage: "hand.thumbsup")
                    Label(video.duration, systemImage: "clock")
                    if let rating = video.rating {
                        Label(rating, systemImage: "star.fill")
                            .foregroundColor(.yellow)
                    }
                }
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)

                // 标签
                if !video.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(video.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 12))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.gray.opacity(0.15))
                                    .foregroundColor(.secondary)
                                    .cornerRadius(4)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                Divider()
                    .padding(.horizontal, 16)

                // 简介
                if let desc = detail?.description, !desc.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("简介")
                            .font(.system(size: 15, weight: .semibold))
                        Text(desc)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .lineSpacing(4)
                    }
                    .padding(.horizontal, 16)
                }

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                }
            }
            .padding(.vertical, 12)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadDetail()
        }
        .sheet(isPresented: $showPlayer) {
            if let player = player {
                VideoPlayer(player: player)
                    .edgesIgnoringSafeArea(.all)
                    .onAppear {
                        player.play()
                    }
            }
        }
    }

    private func loadDetail() {
        isLoading = true
        Task {
            do {
                let result = try await svc.fetchVideoDetail(video.videoId)
                await MainActor.run {
                    detail = result
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    loadError = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func playVideo() {
        Task {
            do {
                if let urlStr = try await svc.fetchPlayURL(video.videoId),
                   let url = URL(string: urlStr) {
                    await MainActor.run {
                        player = AVPlayer(url: url)
                        showPlayer = true
                    }
                }
            } catch {
                print("播放失败: \(error)")
            }
        }
    }
}

// MARK: - 设置页

struct MDTVSettingsView: View {
    @StateObject private var svc = MDTVService.shared
    @State private var customDomain = ""
    @State private var showResetAlert = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("密钥状态")
                    Spacer()
                    if svc.isKeyFound {
                        Label("已匹配", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Label("探测中", systemImage: "magnifyingglass.circle")
                            .foregroundColor(.orange)
                    }
                }

                Button(role: .destructive) {
                    showResetAlert = true
                } label: {
                    HStack {
                        Text("重置密钥配置")
                        Spacer()
                        Image(systemName: "arrow.counterclockwise")
                    }
                }

                Button(role: .destructive) {
                    svc.resetTabs()
                } label: {
                    HStack {
                        Text("重置 Tab 配置")
                        Spacer()
                        Image(systemName: "arrow.counterclockwise")
                    }
                }
            } header: {
                Text("加密配置")
            } footer: {
                Text("如果视频加载异常，可以尝试重置密钥，让系统重新自动探测正确的加密配置。")
            }

            Section {
                HStack {
                    Text("当前 Tab")
                    Spacer()
                    Text(svc.homeTabs.joined(separator: " / "))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            } header: {
                Text("首页 Tab")
            } footer: {
                Text("Tab 列表支持本地默认 + 远程热更新。服务端更新 Tab 后，下次进入页面会自动同步。")
            }

            Section {
                NavigationLink(destination: MDTVDomainSettingsView()) {
                    HStack {
                        Text("API 域名")
                        Spacer()
                        Text(svc.baseURL.replacingOccurrences(of: "https://", with: ""))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            } header: {
                Text("网络配置")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("平台标识: JGDZMX")
                        .font(.system(size: 14))
                    Text("加密算法: AES (模式自动探测)")
                        .font(.system(size: 14))
                    Text("候选密钥: 动态生成 (含 hex + UTF-8 + MD5/SHA1)")
                        .font(.system(size: 14))
                    Text("候选模式: CBC / CFB / CTR / OFB / ECB")
                        .font(.system(size: 14))
                }
                .foregroundColor(.secondary)
            } header: {
                Text("技术信息")
            }
        }
        .navigationTitle("麻豆平台设置")
        .navigationBarTitleDisplayMode(.inline)
        .alert("重置密钥配置", isPresented: $showResetAlert) {
            Button("取消", role: .cancel) { }
            Button("确定重置", role: .destructive) {
                svc.resetKeyConfig()
            }
        } message: {
            Text("重置后系统将重新自动探测正确的加密密钥和模式，确定要继续吗？")
        }
    }
}

// MARK: - 域名设置页

struct MDTVDomainSettingsView: View {
    @StateObject private var svc = MDTVService.shared
    @State private var customDomain = ""

    private let presetDomains = [
        "https://api.nzp1ve.com",
        "https://api.em1oifd0.com",
        "https://api.3459381.com",
        "https://api.c6dd5cc.com",
        "https://api.j7y675.com",
        "https://api.61c76a0.com",
        "https://api.87735d5.com",
        "https://api.b7f3192.com",
        "https://api.c9wgdr.com",
        "https://api.he0jys.com",
    ]

    var body: some View {
        Form {
            Section {
                TextField("自定义域名", text: $customDomain)
                    .autocapitalization(.none)
                    .keyboardType(.URL)
            } header: {
                Text("自定义 API 域名")
            } footer: {
                Text("输入完整域名，如 https://api.example.com")
            }

            Section {
                ForEach(presetDomains, id: \.self) { domain in
                    Button(action: {
                        customDomain = domain
                    }) {
                        HStack {
                            Text(domain.replacingOccurrences(of: "https://", with: ""))
                                .foregroundColor(.primary)
                            Spacer()
                            if svc.baseURL == domain {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            } header: {
                Text("预设域名")
            }
        }
        .navigationTitle("API 域名")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 组件：视频卡片

struct MDTVVideoCard: View {
    let video: MDTVVideoItem
    var isPlaceholder: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 封面
            ZStack(alignment: .bottomTrailing) {
                if isPlaceholder || video.cover.isEmpty {
                    Color.gray.opacity(0.3)
                } else {
                    // 暂时用占位，等密钥确认后再加载真实图片
                    Color.gray.opacity(0.3)
                }

                // 时长标签
                Text(video.duration)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(4)
                    .padding(6)
            }
            .aspectRatio(3/4, contentMode: .fit)
            .cornerRadius(8)

            // 标题
            Text(video.title)
                .font(.system(size: 13))
                .lineLimit(2)
                .foregroundColor(.primary)

            // 播放量
            HStack(spacing: 4) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 10))
                Text("\(video.views)")
                    .font(.system(size: 11))
            }
            .foregroundColor(.secondary)
        }
    }
}

// MARK: - 组件：分类卡片

struct MDTVCategoryCard: View {
    let category: MDTVCategory
    var isPlaceholder: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            if isPlaceholder {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .aspectRatio(1, contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.15))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.accentColor)
                    )
            }

            Text(category.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
    }
}

// MARK: - 工具：弹性布局（标签云）

struct FlexibleView<Data: Collection, Content: View>: View where Data.Element: Hashable {
    let data: Data
    let spacing: CGFloat
    let alignment: HorizontalAlignment
    let content: (Data.Element) -> Content

    @State private var totalHeight: CGFloat = .zero

    var body: some View {
        GeometryReader { geometry in
            self.generateContent(in: geometry)
        }
        .frame(height: totalHeight)
    }

    private func generateContent(in g: GeometryProxy) -> some View {
        var width = CGFloat.zero
        var height = CGFloat.zero

        return ZStack(alignment: Alignment(horizontal: alignment, vertical: .top)) {
            ForEach(Array(data), id: \.self) { item in
                content(item)
                    .padding(.trailing, spacing)
                    .padding(.bottom, spacing)
                    .alignmentGuide(.leading) { d in
                        if abs(width - d.width) > g.size.width {
                            width = 0
                            height -= d.height
                        }
                        let result = width
                        if item == Array(data).last {
                            width = 0
                        } else {
                            width -= d.width
                        }
                        return result
                    }
                    .alignmentGuide(.top) { d in
                        let result = height
                        if item == Array(data).last {
                            height = 0
                        }
                        return result
                    }
            }
        }
        .background(viewHeightReader($totalHeight))
    }

    private func viewHeightReader(_ binding: Binding<CGFloat>) -> some View {
        GeometryReader { geometry -> Color in
            let rect = geometry.frame(in: .local)
            DispatchQueue.main.async {
                binding.wrappedValue = rect.size.height
            }
            return .clear
        }
    }
}
