import SwiftUI
import WebKit

// MARK: - 色播聚合主页面

struct SBAggregationView: View {
    let platform: YBoxPlatform2
    @StateObject private var svc = SBAggregationService.shared
    @State private var videos: [SBAggregationVideo] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                List {
                    ForEach(videos) { video in
                        NavigationLink(destination: SBAggregationPlayerView(
                            address: video.address,
                            title: video.title,
                            svc: svc
                        )) {
                            DailyBattleVideoCard(
                                cover: video.cover,
                                title: video.title,
                                remarks: "第\(video.remarks)期",
                                imageMode: .plain
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle(platform.name)
            .navigationBarTitleDisplayMode(.inline)

            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(UIColor.systemBackground).opacity(0.8))
            }

            if let err = loadError, videos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("加载失败")
                        .font(.title2)
                    Text(err)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Button("重试") { load() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if videos.isEmpty { load() } }
    }

    private func load() {
        isLoading = true; loadError = nil
        Task {
            let list = await svc.fetchList()
            await MainActor.run {
                videos = list; isLoading = false
                if list.isEmpty { loadError = "暂时无法获取数据，请稍后重试" }
            }
        }
    }
}

// MARK: - 色播聚合播放器页面 (WKWebView FLV 播放器)

struct SBAggregationPlayerView: View {
    let address: String
    let title: String
    @ObservedObject var svc: SBAggregationService
    @State private var playItems: [SBAggregationPlayItem] = []
    @State private var selectedIdx = 0
    @State private var isLoading = true
    @State private var currentURL: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // 播放器
            ZStack {
                if !currentURL.isEmpty {
                    SBAggregationWebPlayer(url: currentURL)
                } else {
                    Rectangle()
                        .fill(Color.black)
                        .aspectRatio(16/9, contentMode: .fit)
                        .overlay {
                            if isLoading {
                                ProgressView().tint(.white)
                            }
                        }
                }
            }
            .background(Color.black)

            // 标题
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 线路选择
            if playItems.count > 0 {
                Text("播放线路")
                    .font(.system(size: 13)).foregroundColor(.secondary)
                    .padding(.horizontal, 16).padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(playItems.enumerated()), id: \.offset) { idx, item in
                            Button(action: {
                                selectedIdx = idx
                                currentURL = item.address
                            }) {
                                HStack {
                                    Text(item.title).font(.system(size: 14))
                                        .foregroundColor(selectedIdx == idx ? .accentColor : .primary)
                                    Spacer()
                                    if selectedIdx == idx {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 11)).foregroundColor(.accentColor)
                                    }
                                }
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                .background(selectedIdx == idx ? Color.accentColor.opacity(0.08) : Color.clear)
                            }
                            .buttonStyle(.plain)
                            if idx < playItems.count - 1 { Divider().padding(.leading, 16) }
                        }
                    }
                }
                .frame(maxHeight: 300)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal, 12).padding(.top, 6)
            } else if !isLoading {
                Spacer()
                Text("暂无可用线路").font(.system(size: 14)).foregroundColor(.secondary)
                Spacer()
            } else {
                Spacer()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if playItems.isEmpty { load() } }
    }

    private func load() {
        isLoading = true
        Task {
            let items = await svc.fetchDetail(address: address)
            await MainActor.run {
                playItems = items; isLoading = false
                if !items.isEmpty {
                    selectedIdx = 0
                    currentURL = items[0].address
                }
            }
        }
    }
}

// MARK: - WKWebView FLV 播放器

struct SBAggregationWebPlayer: UIViewRepresentable {
    let url: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>
        * { margin:0; padding:0; }
        body { background:#000; display:flex; align-items:center; justify-content:center; height:100vh; }
        video { width:100%; height:100%; object-fit:contain; }
        </style>
        </head>
        <body>
        <video id="v" controls autoplay playsinline style="width:100%;height:100%;object-fit:contain;"></video>
        <script src="https://cdn.bootcdn.net/ajax/libs/flv.js/1.6.2/flv.min.js"></script>
        <script>
        var currentPlayer = null;
        var retryCount = 0;
        function loadFlv(url) {
            console.log('loadFlv called: ' + url);
            retryCount = 0;
            tryLoad(url);
        }
        function tryLoad(url) {
            if (typeof flvjs !== 'undefined' && flvjs.isSupported()) {
                console.log('flvjs ready, creating player');
                if (currentPlayer) { currentPlayer.destroy(); currentPlayer = null; }
                try {
                    currentPlayer = flvjs.createPlayer({
                        type: 'flv',
                        url: url,
                        isLive: true,
                        hasAudio: true,
                        hasVideo: true
                    });
                    currentPlayer.attachMediaElement(document.getElementById('v'));
                    currentPlayer.load();
                    currentPlayer.play().then(function() {
                        console.log('play success');
                    }).catch(function(e) {
                        console.log('play error: ' + e);
                        // Try direct fallback
                        document.getElementById('v').src = url;
                        document.getElementById('v').play();
                    });
                } catch(e) {
                    console.log('flvjs create error: ' + e);
                    document.getElementById('v').src = url;
                    document.getElementById('v').play();
                }
            } else if (retryCount < 20) {
                retryCount++;
                console.log('flvjs not ready, retry ' + retryCount + '/20');
                setTimeout(function() { tryLoad(url); }, 300);
            } else {
                console.log('flvjs timeout, fallback to direct');
                document.getElementById('v').src = url;
                document.getElementById('v').play();
            }
        }
        </script>
        </body>
        </html>
        """

        webView.loadHTMLString(html, baseURL: nil)
        context.coordinator.flvURL = url
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.flvURL != url {
            context.coordinator.flvURL = url
            // 转义 URL 中的特殊字符，防止 JS 注入
            let escaped = url.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "'", with: "\\'")
                           .replacingOccurrences(of: "\n", with: "")
                           .replacingOccurrences(of: "\r", with: "")
            let js = "loadFlv('\(escaped)');"
            webView.evaluateJavaScript(js)
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var flvURL: String = ""

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let escaped = flvURL.replacingOccurrences(of: "\\", with: "\\\\")
                               .replacingOccurrences(of: "'", with: "\\'")
                               .replacingOccurrences(of: "\n", with: "")
                               .replacingOccurrences(of: "\r", with: "")
            let js = "loadFlv('\(escaped)');"
            webView.evaluateJavaScript(js)
        }
    }
}