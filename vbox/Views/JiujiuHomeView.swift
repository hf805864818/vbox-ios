import SwiftUI

// MARK: - 久久網 主页面

struct JiujiuHomeView: View {
    @StateObject private var svc = JiujiuService.shared
    @State private var categories: [JiujiuCategory] = []
    @State private var selectedCateIdx = 0
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                VStack { Spacer(); ProgressView().scaleEffect(1.5); Spacer() }
            } else if categories.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 40)).foregroundColor(.secondary)
                    Text("暂无可用分类").font(.system(size: 15)).foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    categoryTabs
                    Divider()
                    videoContent
                }
            }
        }
        .navigationTitle("久久網")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadCategories() }
    }

    private func loadCategories() {
        Task {
            let result = await svc.fetchCategories()
            await MainActor.run {
                categories = result
                isLoading = false
            }
        }
    }

    // MARK: - 分类横向滚动

    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(categories.enumerated()), id: \.offset) { idx, cat in
                    Button(action: { selectedCateIdx = idx }) {
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
    }

    // MARK: - 视频内容区

    private var videoContent: some View {
        JiujiuVideoGrid(cid: categories[selectedCateIdx].cid, title: categories[selectedCateIdx].name)
    }
}

// MARK: - 视频网格

struct JiujiuVideoGrid: View {
    let cid: String
    let title: String
    @StateObject private var svc = JiujiuService.shared
    @State private var videos: [JiujiuVideo] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var currentPage = 1
    @State private var hasMore = true

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
                            NavigationLink(destination: JiujiuPlayerView(video: video)) {
                                JiujiuVideoCard(cover: video.cover, title: video.title, remarks: video.remarks)
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
        .onAppear { loadVideos() }
    }

    private func loadVideos() {
        Task {
            let (list, pageCount) = await svc.fetchVideos(cid: cid, page: 1)
            await MainActor.run {
                videos = list; isLoading = false
                hasMore = 1 < pageCount
            }
        }
    }

    private func loadMore() {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        let next = currentPage + 1
        Task {
            let (list, pageCount) = await svc.fetchVideos(cid: cid, page: next)
            await MainActor.run {
                if !list.isEmpty { videos.append(contentsOf: list); currentPage = next; hasMore = next < pageCount }
                else { hasMore = false }
                isLoadingMore = false
            }
        }
    }
}

// MARK: - 视频卡片

struct JiujiuVideoCard: View {
    let cover: String
    let title: String
    let remarks: String

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
                .frame(height: 88).frame(maxWidth: .infinity).clipped()

                LinearGradient(
                    colors: [Color.black.opacity(0.0), Color.black.opacity(0.55)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 88)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 18)).foregroundColor(.white.opacity(0.85))
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

struct JiujiuPlayerView: View {
    let video: JiujiuVideo
    @StateObject private var svc = JiujiuService.shared
    @State private var playURL: String?
    @State private var isLoading = true
    @State private var errorMsg: String?
    @State private var showPlayer = false
    @State private var vodItem: VodItem?

    var body: some View {
        VStack(spacing: 12) {
            AsyncImage(url: URL(string: video.cover)) { phase in
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
                } else if let url = playURL {
                    VStack(spacing: 16) {
                        Button(action: { showPlayer = true }) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 60)).foregroundColor(.white.opacity(0.9))
                        }
                        Button(action: {
                            if let safariURL = URL(string: url) {
                                UIApplication.shared.open(safariURL)
                            }
                        }) {
                            Text("在浏览器打开")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5)).underline()
                        }
                    }
                } else if let e = errorMsg {
                    VStack(spacing: 12) {
                        Image(systemName: "play.slash")
                            .font(.system(size: 40)).foregroundColor(.white.opacity(0.8))
                        Text(e).font(.system(size: 14)).foregroundColor(.white.opacity(0.9))
                        Button(action: { loadPlayURL() }) {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(.system(size: 13)).foregroundColor(.white)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(Color.accentColor).cornerRadius(8)
                        }
                    }
                }
            }

            Text(video.title)
                .font(.system(size: 18, weight: .bold)).padding(.horizontal, 16)
            Spacer()
        }
        .navigationTitle("播放").navigationBarTitleDisplayMode(.inline)
        .onAppear { loadPlayURL() }
        .fullScreenCover(isPresented: $showPlayer) {
            if let vod = vodItem { VideoDetailView(video: vod) }
        }
    }

    private func loadPlayURL() {
        isLoading = true; errorMsg = nil
        Task {
            let url = await svc.fetchPlayURL(pageUrl: video.pageUrl)
            await MainActor.run {
                if let url = url {
                    playURL = url; isLoading = false
                    vodItem = VodItem(
                        vodId: video.vodId, vodName: video.title, vodPic: video.cover,
                        vodRemarks: "[福利]久久網", vodPlayUrl: url
                    )
                } else {
                    errorMsg = "获取播放地址失败，请检查网络"
                    isLoading = false
                }
            }
        }
    }
}
