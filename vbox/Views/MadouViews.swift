import SwiftUI
import AVKit

// MARK: - 麻豆免费在线播放 主页面
// 参考香蕉秀 YBoxXjspMainView 的架构：
//   顶部Tab（推荐/分类） → 横向动态分类栏 → 视频网格(2列) → 点击播放
//   分类完全从站点首页动态解析，不硬编码
struct MadouMainView: View {
    let platform: YBoxPlatform2
    @State private var selectedTab = 0
    private let tabs = ["推荐", "分类"]
    
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
            .padding(.top, 8).padding(.horizontal, 8)
            Divider()
            
            TabView(selection: $selectedTab) {
                MadouHomeTab(platform: platform).tag(0)
                MadouCategoryTab(platform: platform).tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 推荐Tab：首页视频网格（对应 Python homeVideoContent）
struct MadouHomeTab: View {
    let platform: YBoxPlatform2
    @StateObject private var svc = MadouService.shared
    @State private var videos: [MadouVideo] = []
    @State private var isLoading = true
    @State private var loadError: String?
    
    var body: some View {
        Group {
            if isLoading && videos.isEmpty {
                VStack { Spacer(); ProgressView(); Text("加载中...").font(.system(size: 13)).foregroundColor(.secondary); Spacer() }
            } else if let err = loadError, videos.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 50)).foregroundColor(.secondary)
                    Text(err).font(.system(size: 15)).multilineTextAlignment(.center)
                    Button(action: { loadError = nil; loadVideos() }) {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.system(size: 14))
                            .padding(.horizontal, 20).padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.1)).cornerRadius(8)
                    }
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                        spacing: 14
                    ) {
                        ForEach(videos) { video in
                            NavigationLink(destination: MadouPlayerView(vodId: video.vodId, platform: platform)) {
                                MadouVideoCard(cover: video.cover, title: video.title, remarks: video.remarks)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .onAppear { if videos.isEmpty { loadVideos() } }
    }
    
    private func loadVideos() {
        isLoading = true
        Task {
            let result = await svc.fetchHomeVideos()
            await MainActor.run {
                videos = result
                isLoading = false
                if result.isEmpty { loadError = "暂无推荐内容" }
            }
        }
    }
}

// MARK: - 分类Tab：动态分类 → 视频网格
struct MadouCategoryTab: View {
    let platform: YBoxPlatform2
    @StateObject private var svc = MadouService.shared
    @State private var categories: [MadouCategory] = []
    @State private var selectedCateIdx = 0
    @State private var videos: [MadouVideo] = []
    @State private var isLoading = true
    @State private var isLoadingCate = true
    @State private var isLoadingMore = false
    @State private var currentPage = 1
    @State private var hasMore = true
    @State private var loadError: String?
    
    var body: some View {
        VStack(spacing: 0) {
            if isLoadingCate {
                VStack { Spacer(); ProgressView(); Spacer() }
            } else if categories.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "tray").font(.system(size: 50)).foregroundColor(.secondary)
                    Text("未找到分类").font(.system(size: 15)).foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                // 动态分类横向滚动栏（从站点首页解析，非硬编码）
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(categories.enumerated()), id: \.offset) { idx, cat in
                            Button(action: {
                                selectedCateIdx = idx
                                refreshVideos()
                            }) {
                                Text(cat.name)
                                    .font(.system(size: 13, weight: selectedCateIdx == idx ? .semibold : .regular))
                                    .foregroundColor(selectedCateIdx == idx ? .white : .secondary)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(
                                        RoundedRectangle(cornerRadius: 16)
                                            .fill(selectedCateIdx == idx ? Color.accentColor : Color.clear)
                                    )
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
                } else if let err = loadError, videos.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.system(size: 50)).foregroundColor(.secondary)
                        Text(err).font(.system(size: 15)).multilineTextAlignment(.center)
                        Button(action: { loadError = nil; refreshVideos() }) {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(.system(size: 14))
                                .padding(.horizontal, 20).padding(.vertical, 8)
                                .background(Color.accentColor.opacity(0.1)).cornerRadius(8)
                        }
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                            spacing: 14
                        ) {
                            ForEach(videos) { video in
                                NavigationLink(destination: MadouPlayerView(vodId: video.vodId, platform: platform)) {
                                    MadouVideoCard(cover: video.cover, title: video.title, remarks: video.remarks)
                                }
                                .buttonStyle(.plain)
                                .onAppear {
                                    if video.vodId == videos[max(0, videos.count - 3)].vodId { loadMore() }
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
            let result = await svc.fetchCategories()  // 动态从站点首页解析
            await MainActor.run {
                categories = result
                isLoadingCate = false
                if !result.isEmpty { refreshVideos() }
            }
        }
    }
    
    private func refreshVideos() {
        guard !categories.isEmpty else { return }
        currentPage = 1; hasMore = true; isLoading = true; loadError = nil
        let cateId = categories[selectedCateIdx].cateId
        Task {
            let result = await svc.fetchVideos(cateId: cateId, page: 1)
            await MainActor.run {
                videos = result; isLoading = false
                hasMore = result.count >= 16
                if result.isEmpty { loadError = "该分类暂无内容" }
            }
        }
    }
    
    private func loadMore() {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        let next = currentPage + 1
        let cateId = categories[selectedCateIdx].cateId
        Task {
            let result = await svc.fetchVideos(cateId: cateId, page: next)
            await MainActor.run {
                if !result.isEmpty {
                    videos.append(contentsOf: result); currentPage = next
                    hasMore = result.count >= 16
                } else { hasMore = false }
                isLoadingMore = false
            }
        }
    }
}

// MARK: - 视频卡片（复用香蕉秀 BananaVideoCard 的风格）
struct MadouVideoCard: View {
    let cover: String
    let title: String
    let remarks: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                // 封面图
                if !cover.isEmpty {
                    AsyncImage(url: URL(string: cover)) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        case .failure:
                            Rectangle().fill(Color.gray.opacity(0.2))
                                .overlay(Image(systemName: "photo").foregroundColor(.gray))
                        case .empty:
                            Rectangle().fill(Color.gray.opacity(0.15))
                                .overlay(ProgressView())
                        @unknown default:
                            Rectangle().fill(Color.gray.opacity(0.15))
                        }
                    }
                    .frame(height: 140)
                    .clipped()
                    .cornerRadius(8)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.15))
                        .frame(height: 140)
                        .cornerRadius(8)
                        .overlay(Image(systemName: "photo").foregroundColor(.gray))
                }
                
                // 观看数标签
                if !remarks.isEmpty {
                    Text(remarks)
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(4)
                        .padding(4)
                }
            }
            
            Text(title)
                .font(.system(size: 12))
                .lineLimit(2)
                .foregroundColor(.primary)
        }
    }
}

// MARK: - 播放页（详情 → 解析播放地址 → AVPlayer）
struct MadouPlayerView: View {
    let vodId: String
    let platform: YBoxPlatform2
    @StateObject private var svc = MadouService.shared
    @State private var isLoading = true
    @State private var title: String = ""
    @State private var cover: String = ""
    @State private var info: String = ""
    @State private var playPath: String?
    @State private var playURL: String = ""
    @State private var needParse: Bool = false
    @State private var player: AVPlayer?
    @State private var error: String?
    
    var body: some View {
        VStack(spacing: 0) {
            if player != nil && !playURL.isEmpty && !needParse {
                // 直接播放
                VideoPlayer(player: player!)
                    .frame(height: 210)
                    .background(Color.black)
            } else if !playURL.isEmpty && needParse {
                // iframe / 嗅探模式：显示 WebView 或提示
                VStack(spacing: 12) {
                    Spacer().frame(height: 50)
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 40)).foregroundColor(.secondary)
                    Text("该视频需要内嵌播放")
                        .font(.system(size: 14)).foregroundColor(.secondary)
                    if let url = URL(string: playURL) {
                        Link("尝试在浏览器中打开", destination: url)
                            .font(.system(size: 14, weight: .medium))
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .frame(height: 210)
            } else {
                // 加载中 / 封面
                ZStack {
                    if !cover.isEmpty {
                        AsyncImage(url: URL(string: cover)) { phase in
                            switch phase {
                            case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                            default: Rectangle().fill(Color.gray.opacity(0.2))
                            }
                        }
                        .frame(height: 210)
                        .background(Color.black)
                    } else {
                        Rectangle().fill(Color.black).frame(height: 210)
                    }
                    if isLoading {
                        ProgressView().scaleEffect(1.5)
                    }
                }
            }
            
            // 视频信息
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !title.isEmpty {
                        Text(title).font(.system(size: 16, weight: .semibold))
                    }
                    if !info.isEmpty {
                        Text(info)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .lineLimit(6)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadContent() }
    }
    
    private func loadContent() {
        isLoading = true
        Task {
            // 1. 获取详情
            let detail = await svc.fetchDetail(vodId: vodId)
            await MainActor.run {
                title = detail.title
                cover = detail.cover
                info = stripHTML(detail.info)
            }
            
            // 2. 获取播放地址
            let playPathStr = detail.playPath ?? vodId.replacingOccurrences(of: "voddetail", with: "vodplay")
            let result = await svc.fetchPlayURL(playPath: playPathStr)
            await MainActor.run {
                playURL = result.url
                needParse = result.needParse
                isLoading = false
                
                if !result.url.isEmpty && !result.needParse {
                    player = AVPlayer(url: URL(string: result.url)!)
                } else if result.url.isEmpty {
                    error = "无法获取播放地址"
                }
            }
        }
    }
    
    private func stripHTML(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else { return html }
        let range = NSRange(html.startIndex..., in: html)
        return regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
