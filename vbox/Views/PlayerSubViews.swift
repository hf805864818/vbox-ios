import SwiftUI
import AVKit
import AVFoundation

// MARK: - ⭐ 新播放器 (移出 VideoDetailView 避免编译器嵌套错误)
struct VideoPlayerView: View {
    let video: VodItem
    @State private var player: AVPlayer?
    @State private var isPlaying = true
    @State private var showControls = true
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var playbackSpeed: Double = 1.0
    @State private var isLocked = false
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var debugLog = ""
    @State private var showDanmaku = true
    @State private var showSettings = false
    @State private var showEpisodePicker = false
    @State private var controlsTimer: Timer?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private func log(_ msg: String) { print("[Player] \(msg)"); debugLog = msg }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView().scaleEffect(1.5)
                        Text("加载中...").font(.system(size: 14)).foregroundColor(.secondary)
                        if !debugLog.isEmpty {
                            Text(debugLog).font(.system(size: 11)).foregroundColor(.yellow.opacity(0.8)).multilineTextAlignment(.center).padding(.horizontal, 30)
                        }
                    }
                } else if let error = loadError {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundColor(.orange)
                        Text(error).font(.system(size: 14)).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
                        Button("返回") { dismiss() }.foregroundColor(Color(hex: "E11D48"))
                    }
                } else if let player = player {
                    ZStack {
                        AVPlayerControllerRepresentable(player: player)
                            .ignoresSafeArea()
                        if showDanmaku {
                            DanmakuOverlayView()
                                .allowsHitTesting(false)
                        }
                        Color.black.opacity(0.01)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.25)) { showControls.toggle() }
                                if showControls { startControlsTimer() }
                            }
                    }
                    if showControls {
                        VStack(spacing: 0) {
                            if !isLocked {
                                HStack {
                                    Button(action: { dismiss() }) {
                                        Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
                                            .frame(width: 40, height: 40)
                                            .background(Circle().fill(.black.opacity(0.3)))
                                    }
                                    Spacer()
                                    HStack(spacing: 12) {
                                        Button(action: { showDanmaku.toggle() }) {
                                            Image(systemName: showDanmaku ? "text.bubble.fill" : "text.bubble").font(.system(size: 18)).foregroundColor(.white)
                                        }
                                        Button(action: { showSettings = true }) {
                                            Image(systemName: "gearshape.fill").font(.system(size: 18)).foregroundColor(.white)
                                        }
                                    }
                                }
                                .padding(.horizontal, 16).padding(.top, 60)
                            }
                            Spacer()
                            if !isLocked {
                                VStack(spacing: 8) {
                                    // 进度条
                                    Slider(value: $currentTime, in: 0...max(duration, 1)) { editing in
                                        if !editing { player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600)) }
                                    }
                                    .accentColor(Color(hex: "E11D48"))
                                    .padding(.horizontal, 16)

                                    HStack {
                                        HStack(spacing: 20) {
                                            Button(action: toggleLock) {
                                                Image(systemName: isLocked ? "lock.fill" : "lock.open.fill").font(.system(size: 18)).foregroundColor(.white)
                                            }
                                            Button(action: { player.seek(to: CMTime(seconds: max(0, currentTime - 10), preferredTimescale: 600)) }) {
                                                Image(systemName: "backward.fill").font(.system(size: 22)).foregroundColor(.white)
                                            }
                                            Button(action: { isPlaying ? player.pause() : player.play(); isPlaying.toggle() }) {
                                                Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.system(size: 28)).foregroundColor(.white)
                                            }
                                            Button(action: { player.seek(to: CMTime(seconds: min(duration, currentTime + 10), preferredTimescale: 600)) }) {
                                                Image(systemName: "forward.fill").font(.system(size: 22)).foregroundColor(.white)
                                            }
                                        }
                                        Spacer()
                                        HStack(spacing: 20) {
                                            Text(formatTime2(currentTime) + " / " + formatTime2(duration)).font(.system(size: 12)).foregroundColor(.white.opacity(0.8))
                                            Button(action: { showEpisodePicker = true }) {
                                                Image(systemName: "list.bullet").font(.system(size: 18)).foregroundColor(.white)
                                            }
                                            AirPlayView().frame(width: 22, height: 22)
                                        }
                                    }
                                    .padding(.horizontal, 16).padding(.bottom, 40)
                                }
                                .transition(.move(edge: .bottom))
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
            UINavigationController.attemptRotationToDeviceOrientation()
            setupPlayer()
        }
        .onDisappear { player?.pause() }
        .sheet(isPresented: $showSettings) { PlayerSettingsView(speed: $playbackSpeed, onSpeedChange: changePlaybackSpeed) }
        .sheet(isPresented: $showEpisodePicker) { EpisodePickerView() }
    }

    private func setupPlayer() {
        Task { await resolvePlayUrl() }
    }

    private func changePlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        player?.rate = Float(speed)
    }

    private func resolvePlayUrl() async {
        log("开始解析: \(video.vodId)")
        let spider = SpiderManager.shared
        if let detail = await spider.getDetail(ids: video.vodId, name: video.vodName) {
            if let pu = detail.vodPlayUrl, !pu.isEmpty, let url = URL(string: pu) {
                await MainActor.run { initPlayer(url: url) }; return
            }
            if let pf = detail.vodPlayFrom, let pu = detail.vodPlayUrl {
                let urls = parsePlayUrls(playFrom: pf, playUrl: pu)
                let du = urls.first(where: { $0.contains(".m3u8") || $0.contains(".mp4") }) ?? urls.first ?? ""
                if !du.isEmpty, let url = URL(string: du) { await MainActor.run { initPlayer(url: url) }; return }
            }
        }
        if let pr = await spider.getPlayerContent(vodId: video.vodId, flag: "play", url: video.vodPlayUrl ?? "") {
            let pu = pr.playUrl ?? pr.url
            if let pu = pu, !pu.isEmpty, let url = URL(string: pu) {
                await MainActor.run { initPlayer(url: url) }; return
            }
        }
        let nd = await spider.nativeDetail(ids: video.vodId, name: video.vodName)
        if let nd = nd, let pu = nd.vodPlayUrl, !pu.isEmpty {
            if let url = URL(string: pu) { await MainActor.run { initPlayer(url: url) }; return }
            let urls = parsePlayUrls(playFrom: nd.vodPlayFrom ?? "", playUrl: pu)
            let du = urls.first(where: { $0.contains(".m3u8") || $0.contains(".mp4") }) ?? urls.first ?? ""
            if !du.isEmpty, let url = URL(string: du) { await MainActor.run { initPlayer(url: url) }; return }
        }

        let playUrlToCheck = video.vodPlayUrl ?? nd?.vodPlayUrl ?? ""
        if !playUrlToCheck.isEmpty, let driveType = CloudDriveManager.detectDrive(from: playUrlToCheck) {
            log("🎯 检测到 \(driveType.displayName) 分享链接，尝试网盘解析...")
            let tokens = CloudDriveManager.shared.tokens(for: driveType)
            if let token = tokens.first {
                do {
                    let result = try await CloudDriveManager.shared.resolvePlayURL(from: playUrlToCheck)
                    log("✅ 网盘解析成功: \(result.url.prefix(60))...")
                    if let url = URL(string: result.url) {
                        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": result.headers])
                        let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                        p.play(); player = p; isPlaying = true; isLoading = false
                        return
                    }
                } catch {
                    log("❌ 网盘解析失败: \(error.localizedDescription)")
                }
            } else {
                log("⚠️ 未配置 \(driveType.displayName) Token，请在设置中配置")
            }
        }
        await MainActor.run { isLoading = false; loadError = "无法获取播放地址" }
    }

    private func parsePlayUrls(playFrom: String, playUrl: String) -> [String] {
        var urls: [String] = []
        if playUrl.contains("#") {
            let parts = playUrl.components(separatedBy: "#")
            for part in parts {
                if let range = part.range(of: "$") {
                    let u = String(part[range.upperBound...])
                    if !u.isEmpty { urls.append(u) }
                } else if !part.isEmpty { urls.append(part) }
            }
        } else if playUrl.contains("$$$") {
            urls = playUrl.components(separatedBy: "$$$")
        } else {
            urls = [playUrl]
        }
        return urls
    }

    private func initPlayer(url: URL) {
        let asset = AVURLAsset(url: url)
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.play()
        isPlaying = true
        isLoading = false
    }

    private func toggleLock() {
        withAnimation(.easeInOut(duration: 0.3)) { isLocked.toggle() }
        if !isLocked { startControlsTimer() }
    }

    private func startControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.25)) { showControls = false }
        }
    }
}

// MARK: - 弹幕覆盖层
struct DanmakuOverlayView: View {
    @State private var danmakuItems: [(text: String, x: CGFloat, y: CGFloat, id: Int)] = []
    @State private var allDanmaku: [(time: Double, text: String)] = []
    @State private var currentIndex = 0
    let timer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()
    var body: some View {
        GeometryReader { geo in
            ForEach(danmakuItems, id: \.id) { item in
                Text(item.text).font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                    .shadow(color: .black, radius: 2).position(x: item.x, y: item.y)
            }
        }.onReceive(timer) { _ in
            guard currentIndex < allDanmaku.count else { return }
            let item = allDanmaku[currentIndex]
            let y = CGFloat.random(in: 30...250)
            danmakuItems.append((item.text, UIScreen.main.bounds.width + 50, y, currentIndex))
            currentIndex += 1
            withAnimation(.linear(duration: 8)) {
                if let idx = danmakuItems.firstIndex(where: { $0.id == currentIndex - 1 }) {
                    danmakuItems[idx].x = -100
                }
            }
            danmakuItems.removeAll { $0.x < -150 }
        }
    }
}

// MARK: - 选集弹窗
struct EpisodePickerView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                    ForEach(1..<101) { ep in
                        Button(action: { dismiss() }) {
                            Text("\(ep)").font(.system(size: 14)).frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.1)))
                        }
                    }
                }.padding()
            }
            .navigationTitle("选集").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

// MARK: - 播放速度设置
struct PlayerSettingsView: View {
    @Binding var speed: Double
    var onSpeedChange: (Double) -> Void
    let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            List { Section("播放速度") { ForEach(speeds, id: \.self) { s in Button(action: { speed = s; onSpeedChange(s); dismiss() }) { HStack { Text("\(s, specifier: "%.2f")x"); Spacer(); if s == speed { Image(systemName: "checkmark").foregroundColor(Color(hex: "E11D48")) } } } } } }
            .navigationTitle("播放设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

// MARK: - AirPlay
struct AirPlayView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - AVPlayer 控制器封装
struct AVPlayerControllerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let c = AVPlayerViewController(); c.player = player; c.showsPlaybackControls = false; c.canStartPictureInPictureAutomaticallyFromInline = true; return c
    }
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

// MARK: - 横屏锁定
struct SupportedOrientationsModifier: ViewModifier {
    let supportedOrientations: UIInterfaceOrientationMask
    func body(content: Content) -> some View {
        content
            .onAppear { UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation"); UINavigationController.attemptRotationToDeviceOrientation() }
            .onDisappear { UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation"); UINavigationController.attemptRotationToDeviceOrientation() }
    }
}

extension View {
    func supportedOrientations(_ orientations: UIInterfaceOrientationMask) -> some View {
        self.modifier(SupportedOrientationsModifier(supportedOrientations: orientations))
    }
}

// MARK: - 工具
func formatTime2(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "00:00" }
    let total = Int(t); let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

// MARK: - 网盘链接选择视图
struct PanLinkPickerView: View {
    let video: VodItem
    var preloadedLinks: [(url: String, name: String)]? = nil
    @State private var links: [(url: String, name: String)] = []
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            ZStack { Color(hex: "0F0F23").ignoresSafeArea()
                if isLoading { VStack(spacing: 16) { ProgressView().scaleEffect(1.5).tint(.white); Text("正在解析网盘链接...").foregroundColor(.secondary) } }
                else if links.isEmpty { VStack(spacing: 16) { Image(systemName: "cloud.slash").font(.system(size: 40)).foregroundColor(.gray); Text("未找到可用的网盘链接").foregroundColor(.secondary) } }
                else { ScrollView { VStack(spacing: 12) {
                    HStack { Image(systemName: "cloud.fill").foregroundColor(.blue); Text(video.vodName).font(.system(size: 18, weight: .bold)); Spacer() }.padding(.horizontal, 20).padding(.top, 16)
                    Text("选择网盘资源播放").font(.system(size: 14)).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                    ForEach(Array(links.enumerated()), id: \.offset) { idx, link in
                        NavigationLink(destination: PanPlayerView(panURL: link.url, title: "\(video.vodName) - \(link.name)")) {
                            HStack(spacing: 14) {
                                ZStack { RoundedRectangle(cornerRadius: 12).fill(driveColor(for: link.name).opacity(0.15)).frame(width: 48, height: 48)
                                    Image(systemName: driveIcon(for: link.name)).font(.system(size: 22)).foregroundColor(driveColor(for: link.name)) }
                                VStack(alignment: .leading, spacing: 4) { Text(link.name).font(.system(size: 15, weight: .semibold)); Text(link.url).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1) }
                                Spacer()
                                Image(systemName: "play.circle.fill").font(.system(size: 28)).foregroundColor(Color(hex: "E11D48"))
                            }.padding(14).background(Color.white.opacity(0.05)).cornerRadius(14)
                        }.buttonStyle(.plain).padding(.horizontal, 16)
                    }
                }.padding(.bottom, 40) }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("关闭") { dismiss() } } }
        }
        .onAppear {
            if let pre = preloadedLinks, !pre.isEmpty { links = pre; isLoading = false; return }
            guard let playUrl = video.vodPlayUrl, let data = playUrl.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { isLoading = false; return }
            links = json.compactMap { item in guard let url = item["url"], let name = item["name"] else { return nil }; return (url, name) }
            isLoading = false
        }
    }
    private func driveColor(for name: String) -> Color { if name.contains("115") { return .orange }; if name.contains("阿里") { return .blue }; if name.contains("夸克") { return .purple }; if name.contains("百度") { return .green }; return .gray }
    private func driveIcon(for name: String) -> String { if name.contains("115") { return "1.circle.fill" }; if name.contains("阿里") { return "a.circle.fill" }; if name.contains("夸克") { return "q.circle.fill" }; if name.contains("百度") { return "b.circle.fill" }; return "cloud.fill" }
}

// MARK: - 网盘播放视图
struct PanPlayerView: View {
    let panURL: String; let title: String
    @State private var player: AVPlayer?
    @State private var isLoading = true; @State private var loadError: String?
    @State private var debugMessages: [String] = []
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack { Color.black.ignoresSafeArea()
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(1.5).tint(.white)
                    Text("解析网盘链接...").font(.system(size: 14)).foregroundColor(.secondary)
                    if !debugMessages.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(debugMessages, id: \.self) { msg in
                                Text(msg).font(.system(size: 11)).foregroundColor(.yellow.opacity(0.8))
                            }
                        }.padding(.horizontal, 30)
                    }
                }
            }
            else if let e = loadError { VStack(spacing: 16) { Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundColor(.yellow); Text(e).font(.system(size: 14)).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40); Button(action: { dismiss() }) { Text("返回").foregroundColor(.blue) } } }
            else if let p = player { AVPlayerController2(player: p).ignoresSafeArea() }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .onAppear {
            UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
            UINavigationController.attemptRotationToDeviceOrientation()
            Task {
                addDebug("📡 开始解析: \(title)")
                addDebug("🔗 网盘链接: \(panURL.prefix(60))...")
                let result = await SpiderManager.shared.resolvePanURL(panURL)
                await MainActor.run {
                    if let r = result, let url = URL(string: r.url) {
                        addDebug("✅ 解析成功，启动播放器")
                        if !r.headers.isEmpty { addDebug("📋 附加请求头: \(r.headers.keys.joined(separator: ", "))") }
                        if !r.headers.isEmpty {
                            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": r.headers])
                            let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                            p.play(); player = p; isLoading = false
                        } else {
                            let p = AVPlayer(url: url)
                            p.play(); player = p; isLoading = false
                        }
                    } else {
                        addDebug("❌ 解析失败")
                        loadError = "解析失败，请检查是否配置了网盘Token"
                    }
                }
            }
        }
    }
    private func addDebug(_ msg: String) {
        print("[PanPlayer] \(msg)")
        Task { @MainActor in debugMessages.append(msg) }
    }
}

// MARK: - AVPlayer 控制器封装
struct AVPlayerController2: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let c = AVPlayerViewController(); c.player = player; c.showsPlaybackControls = true; c.entersFullScreenWhenPlaybackBegins = true; c.canStartPictureInPictureAutomaticallyFromInline = true; return c
    }
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}
