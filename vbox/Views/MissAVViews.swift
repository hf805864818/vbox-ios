import SwiftUI
import WebKit

struct MissAVHomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var service = MissAVService.shared

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                Text("MissAV")
                    .font(.system(size: 28, weight: .bold))
                Text("视频分类 · 原生解析 · WebView兜底")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)

                ForEach(service.sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        Label(section.title, systemImage: section.icon)
                            .font(.system(size: 18, weight: .bold))

                        ForEach(section.children) { item in
                            NavigationLink(destination: MissAVVideoListView(menuItem: item)) {
                                HStack {
                                    Text(item.title)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.secondary)
                                }
                                .padding(14)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color(.secondarySystemBackground))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 40)
        }
        .navigationTitle("MissAV")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MissAVVideoListView: View {
    let menuItem: MissAVMenuItem
    @StateObject private var service = MissAVService.shared
    @State private var videos: [VodItem] = []
    @State private var loadCount = 0

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        Group {
            if service.isLoading {
                ProgressView("正在加载 \(menuItem.title)...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = service.errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 14))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                    Button("重试") {
                        loadVideos()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if videos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "film")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)
                    Text("暂无视频内容")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(videos) { video in
                            NavigationLink(destination: MissAVPlayerRouterView(video: video)) {
                                MissAVVideoCard(video: video)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                }
            }
        }
        .navigationTitle(menuItem.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if videos.isEmpty || loadCount == 0 {
                loadVideos()
            }
        }
    }

    private func loadVideos() {
        loadCount += 1
        Task {
            let loaded = await service.loadVideos(for: menuItem)
            await MainActor.run {
                videos = loaded
            }
        }
    }
}

struct MissAVVideoCard: View {
    let video: VodItem

    private var codeText: String {
        if let remarks = video.vodRemarks, !remarks.isEmpty { return remarks }
        return video.vodId.replacingOccurrences(of: "_", with: "-").uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: URL(string: video.vodPic)) { phase in
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

                Text(codeText)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Capsule())
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(video.vodName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Text(video.vodArea ?? "MissAV")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MissAVPlayerRouterView: View {
    let video: VodItem
    @StateObject private var service = MissAVService.shared
    @State private var resolvedVod: VodItem?
    @State private var showPlayer = false

    var body: some View {
        VStack(spacing: 12) {
            // 封面预览
            AsyncImage(url: URL(string: video.vodPic)) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fit).cornerRadius(12)
                default:
                    Rectangle().fill(Color.gray.opacity(0.2)).aspectRatio(16/9, contentMode: .fit).cornerRadius(12)
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .center) {
                Button(action: { showPlayer = true }) {
                    Image(systemName: "play.fill").font(.system(size: 60)).foregroundColor(.white.opacity(0.9))
                }
            }

            Text(video.vodName)
                .font(.system(size: 18, weight: .bold))
                .padding(.horizontal, 16)

            Spacer()
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle(video.vodName)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showPlayer) {
            if let vod = resolvedVod {
                VideoDetailView(video: vod)
            } else {
                // 兜底：用原始视频信息
                VideoDetailView(video: video)
            }
        }
        .task {
            await resolveAndPrepare()
        }
    }

    private func resolveAndPrepare() async {
        if let source = await service.resolvePlayableSource(for: video) {
            resolvedVod = VodItem(
                vodId: video.vodId,
                vodName: video.vodName,
                vodPic: video.vodPic,
                vodRemarks: video.vodRemarks,
                vodYear: video.vodYear,
                vodArea: video.vodArea,
                vodDirector: video.vodDirector,
                vodActor: video.vodActor,
                vodContent: video.vodContent,
                vodPlayFrom: "missav-native",
                vodPlayUrl: source.url
            )
        }
    }
}

struct MissAVWebPlayerView: UIViewRepresentable {
    let url: URL
    let cleanAds: Bool

    func makeCoordinator() -> Coordinator { Coordinator(cleanAds: cleanAds) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = MissAVService.mobileUserAgent
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        var request = URLRequest(url: url)
        request.setValue(MissAVService.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://missav.ws/", forHTTPHeaderField: "Referer")
        webView.load(request)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let cleanAds: Bool
        init(cleanAds: Bool) { self.cleanAds = cleanAds }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard cleanAds else { return }
            let js = """
            setTimeout(function() {
              document.querySelectorAll('iframe[src*=\"ad\"], .ad, .ads, [class*=\"ads\"], [id*=\"ads\"], .banner, .pop, .popup').forEach(function(e){e.remove();});
              document.querySelectorAll('video').forEach(function(v){v.setAttribute('playsinline','true'); v.muted = false;});
            }, 800);
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
