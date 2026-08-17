import SwiftUI

// MARK: - 漫画/套图中转页
// 点击漫画平台卡片后进入此页，加载详情并展示套图封面与基本信息，
// 用户点击封面后进入 ComicGalleryView 上下滑动浏览全部图片。
struct ComicDetailBridgeView<Service: FuliPlatformService>: View {
    @ObservedObject var svc: Service
    let video: FuliVideo

    @State private var detail: FuliDetail?
    @State private var isLoading = true
    @State private var errorMsg: String?
    @State private var showGallery = false

    var body: some View {
        ZStack {
            VStack(spacing: 16) {
                // 封面图
                FuliCoverImage(urlString: video.vodPic, referer: svc.imageReferer, sslBypass: svc.imageSSLBypass, contentMode: .fit)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .cornerRadius(12)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .center) {
                    if isLoading {
                        ProgressView().scaleEffect(2).tint(.white)
                    } else if errorMsg != nil {
                        EmptyView()
                    } else if let first = detail?.episodes.first, let images = first.images, !images.isEmpty {
                        Button(action: { showGallery = true }) {
                            Image(systemName: "photo.stack")
                                .font(.system(size: 60))
                                .foregroundColor(.white.opacity(0.95))
                                .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 2)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let err = errorMsg {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 40)).foregroundColor(.secondary)
                        Text(err).font(.system(size: 14)).multilineTextAlignment(.center)
                        Button(action: { loadDetail() }) {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(.system(size: 13)).foregroundColor(.white)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(Color.accentColor).cornerRadius(8)
                        }
                    }
                    .padding(.horizontal, 20)
                    Spacer()
                } else if let detail = detail {
                    Text(detail.vodName)
                        .font(.system(size: 18, weight: .bold))
                        .padding(.horizontal, 16)

                    if let images = detail.episodes.first?.images, !images.isEmpty {
                        Button(action: { showGallery = true }) {
                            HStack {
                                Image(systemName: "photo.stack")
                                Text("浏览套图 (\(images.count)张)")
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 28).padding(.vertical, 10)
                            .background(Color.accentColor).cornerRadius(22)
                        }
                        .buttonStyle(.plain)

                        if let content = detail.vodContent, !content.isEmpty {
                            Text(content)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .lineLimit(4)
                                .padding(.horizontal, 16)
                        }
                    } else {
                        Text("未解析到套图图片")
                            .font(.system(size: 14)).foregroundColor(.secondary)
                        Spacer()
                    }
                    Spacer()
                }
            }
            .padding(.top, 20)
            .navigationTitle("套图详情")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { loadDetail() }
            .fullScreenCover(isPresented: $showGallery) {
                if let images = detail?.episodes.first?.images {
                    MangaReaderView(images: images, title: detail?.vodName ?? "", referer: svc.imageReferer, sslBypass: svc.imageSSLBypass)
                }
            }
        }
    }

    private func loadDetail() {
        isLoading = true; errorMsg = nil; detail = nil
        Task {
            await svc.ensureHostReady()
            let result = await svc.fetchDetail(vodId: video.vodId)
            await MainActor.run {
                detail = result; isLoading = false
                if result.episodes.isEmpty || result.episodes.first?.images?.isEmpty != false {
                    errorMsg = "未解析到套图图片"
                }
            }
        }
    }
}

// MARK: - 漫画/套图浏览页（上下滑动）
struct ComicGalleryView: View {
    let images: [String]
    let title: String
    let referer: String?
    let sslBypass: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(images.enumerated()), id: \.offset) { idx, url in
                            FuliCoverImage(urlString: url, referer: referer, sslBypass: sslBypass, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .id(idx)
                        }
                    }
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ScrollOffsetKey.self, value: proxy.frame(in: .named("gallery")).minY)
                    })
                }
                .coordinateSpace(name: "gallery")

                // 顶部渐变 + 页码指示器
                VStack {
                    HStack {
                        Spacer()
                        Text("\(currentImageIndex) / \(images.count)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.black.opacity(0.55))
                            .cornerRadius(12)
                            .padding(.trailing, 16)
                            .padding(.top, 4)
                    }
                    Spacer()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("完成") { dismiss() }
                .foregroundColor(.white))
            .onPreferenceChange(ScrollOffsetKey.self) { value in
                scrollOffset = -value
            }
        }
    }

    private var currentImageIndex: Int {
        let estimated = Int(scrollOffset / UIScreen.main.bounds.height) + 1
        return max(1, min(estimated, images.count))
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}


// MARK: - 漫画直接阅读器（跳过详情页）
/// 分类页点击漫画后直接进入长卷浏览，自动加载详情和图片列表
struct ComicDirectReaderView<Service: FuliPlatformService>: View {
    let video: FuliVideo
    let svc: Service

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    @State private var images: [String] = []
    @State private var title: String = ""
    @State private var isLoading = true
    @State private var errorMsg: String?

    var body: some View {
        ZStack {
            if !images.isEmpty {
                MangaReaderView(
                    images: images,
                    title: title,
                    referer: svc.imageReferer,
                    sslBypass: svc.imageSSLBypass
                )
            } else if let err = errorMsg {
                VStack(spacing: 16) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text(err)
                        .font(.system(size: 14))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                    Button(action: { loadImages() }) {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(Color.accentColor)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
            } else if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("加载中...")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.25)) {
                settings.isTabBarHidden = true
            }
            loadImages()
        }
        .onDisappear {
            withAnimation(.easeInOut(duration: 0.25)) {
                settings.isTabBarHidden = false
            }
        }
    }

    private func loadImages() {
        isLoading = true
        errorMsg = nil
        images = []

        Task {
            await svc.ensureHostReady()
            let detail = await svc.fetchDetail(vodId: video.vodId)
            await MainActor.run {
                isLoading = false
                if let first = detail.episodes.first, let imgs = first.images, !imgs.isEmpty {
                    self.title = detail.vodName
                    self.images = imgs
                } else {
                    self.errorMsg = "未解析到套图图片"
                }
            }
        }
    }
}
