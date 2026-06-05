import SwiftUI
import AVKit
import AVFoundation

// MARK: - 视频详情视图
struct VideoDetailView: View {
    let video: VodItem
    @State private var showPlayer = false
    @State private var isFavorite = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // 封面
                    ZStack(alignment: .bottomLeading) {
                        AsyncImage(url: URL(string: video.vodPic)) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill)
                            default:
                                Rectangle().fill(Color.gray.opacity(0.3))
                            }
                        }
                        .frame(height: 220).clipped()

                        LinearGradient(colors: [.clear, .black.opacity(0.6), .black.opacity(0.95)],
                                       startPoint: .top, endPoint: .bottom)

                        Button(action: { showPlayer = true }) {
                            ZStack {
                                Circle().fill(Color(hex: "E11D48")).frame(width: 70, height: 70)
                                Image(systemName: "play.fill").font(.system(size: 28, weight: .bold)).foregroundColor(.white).offset(x: 3)
                            }
                        }.padding(16)
                    }

                    // 信息区
                    VStack(alignment: .leading, spacing: 16) {
                        Text(video.vodName).font(.system(size: 22, weight: .bold))
                        HStack(spacing: 12) {
                            TagLabel(text: video.vodRemarks ?? "")
                            TagLabel(text: video.vodYear ?? "")
                            TagLabel(text: "高清")
                        }

                        HStack(spacing: 16) {
                            ActionButton(icon: "play.fill", title: "播放") { showPlayer = true }
                            ActionButton(icon: "list.bullet", title: "选集") {}
                            ActionButton(icon: "square.and.arrow.down", title: "下载") {}
                            ActionButton(icon: "square.and.arrow.up", title: "分享") {}
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("剧情简介").font(.system(size: 16, weight: .semibold))
                            Text(video.vodContent ?? "暂无简介").font(.system(size: 14)).foregroundColor(.secondary).lineSpacing(4)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("剧集列表").font(.system(size: 16, weight: .semibold))
                                Spacer()
                            }
                            EpisodeGridView()
                        }

                        // 弹幕区
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("弹幕").font(.system(size: 16, weight: .semibold))
                                Spacer()
                            }
                            DanmakuInputView()
                            DanmakuListView()
                        }

                        RelatedVideosView()
                    }
                    .padding(20).padding(.bottom, 100)
                }
            }
            .background(Color(hex: "000000"))
            .ignoresSafeArea()
            .fullScreenCover(isPresented: $showPlayer) {
                VideoPlayerView(video: video)
            }

            // 返回
            VStack {
                Button(action: { dismiss() }) {
                    ZStack {
                        Circle().fill(.ultraThinMaterial).frame(width: 44, height: 44)
                        Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
                    }
                }
                .padding(.leading, 16).padding(.top, 12)
                Spacer()
            }
            .zIndex(1000)
        }
    }
}

// MARK: - 辅助组件
struct TagLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundColor(.primary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().stroke(LinearGradient(colors: [.white.opacity(0.1), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
    }
}

struct ActionButton: View {
    let icon: String; let title: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(LinearGradient(colors: [Color(hex: "E11D48"), Color(hex: "F43F5E")], startPoint: .top, endPoint: .bottom))
                Text(title).font(.system(size: 12)).foregroundColor(.primary)
            }.frame(maxWidth: .infinity)
        }.buttonStyle(PlainButtonStyle())
    }
}

struct EpisodeGridView: View {
    @State private var selectedEpisode = 1
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            ForEach(1..<25) { ep in
                Button(action: { selectedEpisode = ep }) {
                    Text("\(ep)").font(.system(size: 14, weight: ep == selectedEpisode ? .semibold : .medium))
                        .foregroundColor(ep == selectedEpisode ? .white : .primary).frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(ep == selectedEpisode ? Color(hex: "E11D48") : Color.primary.opacity(0.1)))
                }.buttonStyle(PlainButtonStyle())
            }
        }
    }
}

// MARK: - 弹幕组件
struct DanmakuItem: Identifiable {
    let id = UUID()
    let text: String
    let time: Date
}

struct DanmakuInputView: View {
    @State private var text = ""
    @State private var danmakuList: [DanmakuItem] = [
        DanmakuItem(text: "来了来了！", time: Date()),
        DanmakuItem(text: "画质不错", time: Date().addingTimeInterval(-10)),
        DanmakuItem(text: "打卡", time: Date().addingTimeInterval(-30)),
    ]

    var body: some View {
        HStack(spacing: 10) {
            TextField("发条弹幕...", text: $text)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .font(.system(size: 14))
            Button(action: {
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                danmakuList.insert(DanmakuItem(text: text, time: Date()), at: 0)
                text = ""
            }) {
                Text("发送").font(.system(size: 14, weight: .medium)).foregroundColor(Color(hex: "E11D48"))
            }
        }
    }
}

struct DanmakuListView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<3) { i in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(Color(hex: "E11D48")).frame(width: 28, height: 28)
                        .overlay(Text("用").font(.system(size: 10)).foregroundColor(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("用户\(Int.random(in: 1000..<9999))").font(.system(size: 11)).foregroundColor(.secondary)
                        Text(["画质真好！", "第一集打卡", "好看！"][i]).font(.system(size: 13))
                    }
                    Spacer()
                }
            }
        }
    }
}

struct RelatedVideosView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("相关推荐").font(.system(size: 16, weight: .semibold))
            LazyVStack(spacing: 12) {
                ForEach(mockVideos.prefix(5)) { video in
                    HStack(spacing: 12) {
                        AsyncImage(url: URL(string: video.vodPic)) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Rectangle().fill(Color.gray.opacity(0.3))
                            }
                        }.frame(width: 110, height: 70).clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(video.vodName).font(.system(size: 14, weight: .medium)).lineLimit(2)
                            Text(video.vodRemarks ?? "").font(.system(size: 12)).foregroundColor(.secondary)
                        }
                        Spacer()
                    }.padding(12).background(RoundedRectangle(cornerRadius: 16).fill(.thinMaterial))
                }
            }
        }
    }
}

// MARK: - ⭐ 新播放器
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
                    // 视频画面
                    ZStack {
                        AVPlayerControllerRepresentable(player: player)
                            .ignoresSafeArea()

                        // 弹幕层
                        if showDanmaku {
                            DanmakuOverlayView()
                                .allowsHitTesting(false)
                        }

                        // 点击切换控制栏
                        Color.black.opacity(0.01)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.25)) { showControls.toggle() }
                                if showControls { startControlsTimer() }
                            }
                    }

                    // 控制栏
                    if showControls {
                        VStack(spacing: 0) {
                            // 顶部栏
                            if !isLocked {
                                HStack {
                                    Button(action: { dismiss() }) {
                                        Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
                                            .frame(width: 40, height: 40)
                                            .background(Circle().fill(.black.opacity(0.3)))
                                    }

                                    Spacer()

                                    Text(video.vodName).font(.system(size: 15, weight: .medium)).foregroundColor(.white).lineLimit(1)
                                        .frame(maxWidth: 200)

                                    Spacer()

                                    Button(action: { showDanmaku.toggle() }) {
                                        Image(systemName: showDanmaku ? "text.bubble.fill" : "text.bubble").font(.system(size: 18)).foregroundColor(.white)
                                            .frame(width: 40, height: 40)
                                    }

                                    Button(action: { showSettings = true }) {
                                        Image(systemName: "ellipsis.circle").font(.system(size: 18)).foregroundColor(.white)
                                            .frame(width: 40, height: 40)
                                    }
                                }
                                .padding(.horizontal, 16).padding(.top, 50)
                            }

                            Spacer()

                            // 解锁按钮
                            if isLocked {
                                VStack {
                                    Button(action: { isLocked = false; showControls = true; startControlsTimer() }) {
                                        Image(systemName: "lock.open").font(.system(size: 20)).foregroundColor(.white.opacity(0.8))
                                            .frame(width: 44, height: 44).background(Circle().fill(.black.opacity(0.3)))
                                    }
                                }
                                Spacer()
                            }

                            // 底部栏
                            if !isLocked {
                                VStack(spacing: 8) {
                                    // 进度条
                                    ProgressSlider(value: Binding(get: { currentTime }, set: { seekTo($0) }),
                                                   range: 0...max(duration, 1),
                                                   isDragging: .constant(false))

                                    HStack(spacing: 16) {
                                        // 锁屏
                                        Button(action: { isLocked = true; showControls = false }) {
                                            Image(systemName: "lock").font(.system(size: 14)).foregroundColor(.white.opacity(0.7))
                                        }

                                        // 播放/暂停 带圆底
                                        Button(action: togglePlayPause) {
                                            ZStack {
                                                Circle().fill(.white.opacity(0.2)).frame(width: 36, height: 36)
                                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                                    .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                                            }
                                        }

                                        // 时间
                                        Text(formatTime(currentTime))
                                            .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundColor(.white)
                                        Text("/")
                                            .font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
                                        Text(formatTime(duration))
                                            .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundColor(.white.opacity(0.7))

                                        Spacer()

                                        // 倍速胶囊
                                        Button(action: { cycleSpeed() }) {
                                            Text("\(playbackSpeed, specifier: "%.1f")x")
                                                .font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                                                .padding(.horizontal, 8).padding(.vertical, 3)
                                                .background(Capsule().fill(.white.opacity(0.2)))
                                        }

                                        // 上一集
                                        Button(action: {}) {
                                            Image(systemName: "backward.end.fill").font(.system(size: 14)).foregroundColor(.white)
                                        }

                                        // 下一集
                                        Button(action: {}) {
                                            Image(systemName: "forward.end.fill").font(.system(size: 14)).foregroundColor(.white)
                                        }

                                        // 选集
                                        Button(action: { showEpisodePicker = true }) {
                                            Image(systemName: "rectangle.split.2x2").font(.system(size: 14)).foregroundColor(.white)
                                        }

                                        // AirPlay
                                        AirPlayButton().frame(width: 24, height: 24)
                                    }
                                    .padding(.horizontal, 16).padding(.bottom, 30)
                                }
                            }
                        }
                        .background(
                            LinearGradient(colors: [.black.opacity(0.5), .clear, .black.opacity(0.7)],
                                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                        )
                        .transition(.opacity)
                    }
                }
            }
            .statusBar(hidden: true)
            .onAppear { setupPlayer() }
            .onDisappear { player?.pause(); controlsTimer?.invalidate() }
            .sheet(isPresented: $showSettings) { PlayerSettingsView(speed: $playbackSpeed, onSpeedChange: changePlaybackSpeed) }
            .sheet(isPresented: $showEpisodePicker) { EpisodePickerView() }
        }
    }

    private func startControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.25)) { showControls = false }
        }
    }

    private func cycleSpeed() {
        let speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
        let idx = speeds.firstIndex(of: playbackSpeed) ?? 2
        let next = speeds[(idx + 1) % speeds.count]
        changePlaybackSpeed(next)
    }

    // MARK: - 播放逻辑（保持原有实现）
    private func setupPlayer() {
        let urlString = video.vodPlayUrl ?? ""
        if !urlString.isEmpty {
            if let url = URL(string: urlString) { initPlayer(url: url); return }
        }
        isLoading = true
        Task { await resolvePlayUrl() }
    }

    private func initPlayer(url: URL) {
        let p = AVPlayer(url: url)
        p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak p] time in
            currentTime = time.seconds
        }
        if #available(iOS 16.0, *) {
            Task { duration = (try? await p.currentItem?.asset.load(.duration).seconds) ?? 0 }
        } else {
            p.currentItem?.asset.loadValuesAsynchronously(forKeys: ["duration"]) {
                DispatchQueue.main.async { if let d = p.currentItem?.asset.duration { duration = CMTimeGetSeconds(d) } }
            }
        }
        p.play(); player = p; isPlaying = true; isLoading = false
        startControlsTimer()
        // 异步加载弹幕
        Task { await loadDanmakuForVideo() }
    }

    private func loadDanmakuForVideo() async {
        do {
            let name = video.vodName
            let danmakuList = try await DanmakuService.shared.fetchDanmakuForVideo(videoName: name)
            log("✅ 加载到 \(danmakuList.count) 条弹幕")
            // 这里可以 post 通知给 DanmakuOverlayView
        } catch {
            log("⚠️ 弹幕加载: \(error.localizedDescription)")
        }
    }

    private func togglePlayPause() {
        guard let p = player else { return }
        if isPlaying { p.pause() } else { p.play() }
        isPlaying.toggle()
        startControlsTimer()
    }

    private func seekTo(_ time: Double) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        startControlsTimer()
    }

    private func changePlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        player?.rate = Float(speed)
    }

    private func resolvePlayUrl() async {
        // 原有解析逻辑保留不变
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
        if let pr = await spider.getPlayerContent(vodId: video.vodId, flag: "play", url: video.vodPlayUrl ?? ""),
           let pu = pr.playUrl ?? pr.url, !pu.isEmpty, let url = URL(string: pu) {
            await MainActor.run { initPlayer(url: url) }; return
        }
        let nd = await spider.nativeDetail(ids: video.vodId, name: video.vodName)
        if let nd = nd, let pu = nd.vodPlayUrl, !pu.isEmpty {
            if let url = URL(string: pu) { await MainActor.run { initPlayer(url: url) }; return }
            let urls = parsePlayUrls(playFrom: nd.vodPlayFrom ?? "", playUrl: pu)
            let du = urls.first(where: { $0.contains(".m3u8") || $0.contains(".mp4") }) ?? urls.first ?? ""
            if !du.isEmpty, let url = URL(string: du) { await MainActor.run { initPlayer(url: url) }; return }
        }
        await MainActor.run { isLoading = false; loadError = "无法获取播放地址" }
    }

    private func parsePlayUrls(playFrom: String, playUrl: String) -> [String] {
        var results: [String] = []
        if playUrl.hasPrefix("http://") || playUrl.hasPrefix("https://") { results.append(playUrl.trimmingCharacters(in: .whitespaces)); return results }
        if playUrl.contains("$$$") {
            for line in playUrl.components(separatedBy: "$$$") {
                let parts = line.components(separatedBy: "$")
                if let urlPart = parts.last?.trimmingCharacters(in: .whitespaces), urlPart.hasPrefix("http"), !results.contains(urlPart) { results.append(urlPart) }
            }
            if !results.isEmpty { return results.sorted { ($0.contains(".m3u8") ? 0 : 1) < ($1.contains(".m3u8") ? 0 : 1) } }
        }
        if playUrl.contains("#") {
            for ep in playUrl.components(separatedBy: "#") {
                let parts = ep.components(separatedBy: "$")
                if let urlPart = parts.last?.trimmingCharacters(in: .whitespaces), urlPart.hasPrefix("http"), (urlPart.contains(".m3u8") || urlPart.contains(".mp4")), !results.contains(urlPart) { results.append(urlPart) }
            }
            if !results.isEmpty { return results.sorted { ($0.contains(".m3u8") ? 0 : 1) < ($1.contains(".m3u8") ? 0 : 1) } }
        }
        if results.isEmpty && playUrl.contains("$") {
            for part in playUrl.components(separatedBy: "$") {
                let u = part.trimmingCharacters(in: .whitespaces)
                if u.hasPrefix("http") && (u.contains(".m3u8") || u.contains(".mp4") || u.count > 20), !results.contains(u) { results.append(u) }
            }
            if !results.isEmpty { return results.sorted { ($0.contains(".m3u8") ? 0 : 1) < ($1.contains(".m3u8") ? 0 : 1) } }
        }
        return results
    }
}

// MARK: - AVPlayer UIKit 桥接
struct AVPlayerControllerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let c = AVPlayerViewController()
        c.player = player
        c.showsPlaybackControls = false
        c.updatesNowPlayingInfoCenter = false
        c.videoGravity = .resizeAspectFill
        return c
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

// MARK: - 弹幕覆盖层
struct DanmakuOverlayView: View {
    @State private var danmakuItems: [(text: String, x: CGFloat, y: CGFloat, id: Int)] = []
    @State private var allDanmaku: [(time: Double, text: String)] = []
    @State private var currentIndex = 0
    let timer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(danmakuItems, id: \.id) { item in
                    Text(item.text)
                        .font(.system(size: CGFloat.random(in: 13...17), weight: .medium))
                        .foregroundColor([.white, .yellow, .green, .cyan, .orange,
                            Color(hex: "FF6B6B"), Color(hex: "4ECDC4")].randomElement()!)
                        .shadow(color: .black.opacity(0.8), radius: 2)
                        .position(x: item.x, y: item.y)
                }
            }
            .onReceive(timer) { _ in
                while currentIndex < allDanmaku.count {
                    let dm = allDanmaku[currentIndex]
                    if dm.time <= Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600) {
                        let newId = (danmakuItems.max(by: { $0.id < $1.id })?.id ?? 0) + 1
                        danmakuItems.append((text: dm.text, x: geo.size.width + 50, y: CGFloat.random(in: 30..<geo.size.height - 50), id: newId))
                        currentIndex += 1
                    } else { break }
                }
                danmakuItems = danmakuItems.compactMap { item in
                    let newX = item.x - CGFloat.random(in: 2...5)
                    return newX > -300 ? (item.text, newX, item.y, item.id) : nil
                }
            }
            .onAppear {
                if allDanmaku.isEmpty {
                    allDanmaku = (0..<50).map { i in (time: Double(i) * 2.5, text: ["来了来了","画质不错","打卡","好看！","哈哈哈","666","支持！","第一集打卡"].randomElement()!) }
                    // 异步加载真实弹幕
                    Task { await loadDanmaku() }
                }
            }
        }
    }

    private func loadDanmaku() async {
        // 这里通过 Notification 或参数传递视频名称来获取真实弹幕
        // 实际会在 VideoPlayerView 中调用 DanmakuService 后注入
    }
}

// MARK: - 进度条
struct ProgressSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @Binding var isDragging: Bool
    @State private var isEditing = false

    var body: some View {
        let pct = range.upperBound > range.lowerBound ? (value - range.lowerBound) / (range.upperBound - range.lowerBound) : 0
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // 底轨
                Capsule().fill(Color.white.opacity(0.2)).frame(height: 3)
                // 缓冲（模拟）
                Capsule().fill(Color.white.opacity(0.15)).frame(width: geo.size.width * 0.7, height: 3)
                // 已播放
                Capsule().fill(Color(hex: "E11D48")).frame(width: geo.size.width * CGFloat(pct), height: 3)
                // 拖拽点
                Circle().fill(.white).frame(width: 12, height: 12)
                    .offset(x: geo.size.width * CGFloat(pct) - 6)
                    .shadow(radius: 2)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in isEditing = true; value = range.lowerBound + Double(g.location.x / geo.size.width) * (range.upperBound - range.lowerBound) }
                    .onEnded { _ in isEditing = false }
            )
        }
        .frame(height: 20).padding(.horizontal, 16)
    }
}

// MARK: - AirPlay 按钮
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(Color(hex: "E11D48"))
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - 播放设置
struct PlayerSettingsView: View {
    @Binding var speed: Double
    let onSpeedChange: (Double) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("播放速度") {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { s in
                        Button(action: { speed = s; onSpeedChange(s); dismiss() }) {
                            HStack {
                                Text("\(s, specifier: "%.2g")x").foregroundColor(.primary)
                                Spacer()
                                if s == speed { Image(systemName: "checkmark").foregroundColor(Color(hex: "E11D48")) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("播放设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

// MARK: - 选集面板
struct EpisodePickerView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                    ForEach(1..<25) { ep in
                        Button(action: { dismiss() }) {
                            Text("\(ep)").font(.system(size: 14)).foregroundColor(.primary)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Color.primary.opacity(0.1)).cornerRadius(8)
                        }
                    }
                }.padding()
            }
            .navigationTitle("选集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

// MARK: - 工具
private func formatTime(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "00:00" }
    let total = Int(t)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

// MARK: - LogVar 弹幕 API 服务
class DanmakuService {
    static let shared = DanmakuService()
    private let baseURL = "https://uzdm.616222.xyz/api/v2"

    struct Anime: Codable {
        let animeId: Int; let animeTitle: String; let type: String?; let year: String?; let season: Int?
    }
    struct Episode: Codable {
        let episodeId: Int; let episodeTitle: String?
    }
    struct Danmaku: Codable {
        let id: Int?; let cid: Int?; let p: String?; let m: String?; let content: String?
        var time: Double {
            if let p = p, let first = p.components(separatedBy: ",").first, let t = Double(first) { return t }
            return 0
        }
        var text: String { m ?? content ?? "" }
    }

    func searchAnime(keyword: String) async throws -> [Anime] {
        guard let url = URL(string: "\(baseURL)/search/anime?keyword=\(keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword)&from=10") else { throw DanmakuError.invalidURL }
        let (data, _) = try await URLSession.shared.data(from: url)
        let r = try JSONDecoder().decode(AnimeSearchResponse.self, from: data)
        return r.animeList ?? []
    }

    func searchEpisodes(animeId: Int) async throws -> [Episode] {
        guard let url = URL(string: "\(baseURL)/search/episodes?animeId=\(animeId)") else { throw DanmakuError.invalidURL }
        let (data, _) = try await URLSession.shared.data(from: url)
        let r = try JSONDecoder().decode(EpisodeSearchResponse.self, from: data)
        return r.episodes ?? []
    }

    func fetchDanmaku(episodeId: Int, segmentIndex: Int = 0) async throws -> [Danmaku] {
        guard let url = URL(string: "\(baseURL)/segmentcomment?episodeId=\(episodeId)&segmentIndex=\(segmentIndex)") else { throw DanmakuError.invalidURL }
        let (data, _) = try await URLSession.shared.data(from: url)
        let r = try JSONDecoder().decode(DanmakuSegmentResponse.self, from: data)
        return r.comments ?? []
    }

    func fetchDanmakuForVideo(videoName: String, episodeIndex: Int = 1) async throws -> [Danmaku] {
        let animes = try await searchAnime(keyword: videoName)
        guard let first = animes.first else { throw DanmakuError.notFound }
        let episodes = try await searchEpisodes(animeId: first.animeId)
        let targetEp = episodes.first { $0.episodeTitle?.contains("\(episodeIndex)") ?? false } ?? episodes.first
        guard let ep = targetEp else { throw DanmakuError.notFound }
        return try await fetchDanmaku(episodeId: ep.episodeId)
    }
}

struct AnimeSearchResponse: Codable { let errorCode: Int?; let animeList: [DanmakuService.Anime]? }
struct EpisodeSearchResponse: Codable { let errorCode: Int?; let episodes: [DanmakuService.Episode]? }
struct DanmakuSegmentResponse: Codable { let errorCode: Int?; let comments: [DanmakuService.Danmaku]? }

enum DanmakuError: LocalizedError {
    case invalidURL; case notFound; case networkError(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效URL"; case .notFound: return "未找到弹幕"
        case .networkError(let m): return m
        }
    }
}
