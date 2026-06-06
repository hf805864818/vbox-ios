import SwiftUI
import AVKit
import AVFoundation

// MARK: - 新版本播放器 (爱奇艺风格)
struct VideoPlayerViewV2: View {
    let video: VodItem
    @State private var player: AVPlayer?
    @State private var playerItem: AVPlayerItem?
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
    @State private var showQualityPicker = false
    @State private var showDanmakuSettings = false
    @State private var isLandscape = false
    @State private var controlsTimer: Timer?
    @State private var timeObserver: Any?
    @State private var danmakuOpacity: Double = 0.8
    @State private var danmakuFontSize: CGFloat = 16
    @State private var selectedQuality = 1
    @State private var durationObserver: NSKeyValueObservation?
    @State private var endObserver: Any?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let qualities = ["标清", "高清", "蓝光"]
    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0]

    private func log(_ msg: String) {
        print("[PlayerV2] \(msg)")
        debugLog = msg
    }

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
                        AVPlayerControllerRepresentableV2(player: player)
                            .ignoresSafeArea()

                        if showDanmaku {
                            DanmakuOverlayViewV2(
                                showDanmaku: $showDanmaku,
                                opacity: danmakuOpacity,
                                fontSize: danmakuFontSize
                            )
                            .allowsHitTesting(false)
                        }

                        Color.black.opacity(0.01)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    showControls.toggle()
                                }
                                if showControls {
                                    startControlsTimer()
                                }
                            }

                        if showControls {
                            playerControlsView
                        }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                handleGestureChange(value, geo: geo)
                            }
                            .onEnded { value in
                                handleGestureEnd(value, geo: geo)
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isPlaying.toggle()
                            if isPlaying {
                                player.play()
                            } else {
                                player.pause()
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            setupPlayer()
            setupOrientation()
        }
        .onDisappear {
            player?.pause()
            if let observer = timeObserver {
                player?.removeTimeObserver(observer)
            }
            controlsTimer?.invalidate()
        }
        .sheet(isPresented: $showSettings) {
            PlayerSettingsViewV2(speed: $playbackSpeed, onSpeedChange: changePlaybackSpeed)
        }
        .sheet(isPresented: $showEpisodePicker) {
            EpisodePickerViewV2(video: video)
        }
        .sheet(isPresented: $showQualityPicker) {
            QualityPickerViewV2(selectedQuality: $selectedQuality, onQualityChange: changeQuality)
        }
        .sheet(isPresented: $showDanmakuSettings) {
            DanmakuSettingsViewV2(
                showDanmaku: $showDanmaku,
                opacity: $danmakuOpacity,
                fontSize: $danmakuFontSize
            )
        }
    }

    // MARK: - 爱奇艺风格控制栏
    private var playerControlsView: some View {
        VStack(spacing: 0) {
            if !isLocked {
                topControlBar
            }
            Spacer()
            if !isLocked {
                bottomControlBar
            }
        }
        .transition(.move(edge: .bottom))
    }

    private var topControlBar: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.black.opacity(0.3)))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(video.vodName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let remarks = video.vodRemarks {
                    Text(remarks)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 12) {
                Button(action: { showDanmakuSettings = true }) {
                    Image(systemName: showDanmaku ? "text.bubble.fill" : "text.bubble")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                }

                AirPlayViewV2().frame(width: 22, height: 22)

                Button(action: { showSettings = true }) {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, isLandscape ? 0 : 60)
        .padding(.bottom, 8)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.7), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var bottomControlBar: some View {
        VStack(spacing: 8) {
            progressSliderView

            HStack(spacing: 16) {
                Button(action: { isPlaying.toggle() }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                }

                Button(action: { player?.seek(to: CMTime(seconds: max(0, currentTime - 10), preferredTimescale: 600)) }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                }

                Button(action: { player?.seek(to: CMTime(seconds: min(duration, currentTime + 10), preferredTimescale: 600)) }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                }

                Text(formatTime(currentTime) + " / " + formatTime(duration))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(minWidth: 80)

                Spacer()

                if isLandscape {
                    HStack(spacing: 12) {
                        Button(action: { showQualityPicker = true }) {
                            Text(qualities[selectedQuality])
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.2))
                                .cornerRadius(4)
                        }

                        Button(action: { showEpisodePicker = true }) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                        }
                    }
                }

                Button(action: toggleLock) {
                    Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, isLandscape ? 20 : 40)
        }
        .background(
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var progressSliderView: some View {
        GeometryReader { sliderGeo in
            ZStack(alignment: .leading) {
                let progress = duration > 0 ? currentTime / duration : 0
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: 4)

                Capsule()
                    .fill(Color(hex: "E11D48"))
                    .frame(width: sliderGeo.size.width * progress, height: 4)
            }
            .frame(height: 4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let player = player else { return }
                        let newTime = (value.location.x / sliderGeo.size.width) * duration
                        currentTime = max(0, min(duration, newTime))
                        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
                    }
            )
        }
        .frame(height: 4)
    }

    // MARK: - 手势处理
    private func handleGestureChange(_ value: DragGesture.Value, geo: GeometryProxy) {
        let translation = value.translation

        if abs(translation.width) > abs(translation.height) {
        } else {
            if value.startLocation.x < geo.size.width / 2 {
            } else {
            }
        }
    }

    private func handleGestureEnd(_ value: DragGesture.Value, geo: GeometryProxy) {
        let translation = value.translation

        if abs(translation.width) > abs(translation.height) {
            let seekAmount = Double(translation.width) / geo.size.width * 60
            guard let player = player else { return }
            let newTime = currentTime + seekAmount
            currentTime = max(0, min(duration, newTime))
            player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
        }
    }

    // MARK: - 播放器设置
    private func setupPlayer() {
        Task {
            await resolvePlayUrl()
        }
    }

    private func resolvePlayUrl() async {
        log("开始解析: \(video.vodId)")
        let spider = SpiderManager.shared

        if let detail = await spider.getDetail(ids: video.vodId, name: video.vodName) {
            if let pu = detail.vodPlayUrl, !pu.isEmpty, let url = URL(string: pu) {
                await MainActor.run { [self] in initPlayer(url: url) }
                return
            }
        }

        if let pr = await spider.getPlayerContent(vodId: video.vodId, flag: "play", url: video.vodPlayUrl ?? "") {
            let pu = pr.playUrl ?? pr.url
            if let pu = pu, !pu.isEmpty, let url = URL(string: pu) {
                await MainActor.run { [self] in initPlayer(url: url) }
                return
            }
        }

        await MainActor.run {
            isLoading = false
            loadError = "无法获取播放地址"
        }
    }

    private func initPlayer(url: URL) {
        let asset = AVURLAsset(url: url)
        playerItem = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: playerItem)

        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { time in
            self.currentTime = time.seconds
        }

        p.play()
        player = p
        isPlaying = true
        isLoading = false

        observePlayerDuration()
    }

    private func observePlayerDuration() {
        guard let playerItem = playerItem else { return }

        durationObserver = playerItem.observe(\.duration, options: [.new, .initial]) { item, _ in
            if item.duration.seconds.isFinite && item.duration.seconds > 0 {
                self.duration = item.duration.seconds
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
        }
    }

    private func changePlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        player?.rate = Float(speed)
    }

    private func changeQuality(_ quality: Int) {
        selectedQuality = quality
    }

    private func toggleLock() {
        withAnimation(.easeInOut(duration: 0.3)) {
            isLocked.toggle()
        }
        if !isLocked {
            startControlsTimer()
        }
    }

    private func startControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [self] _ in
            withAnimation(.easeInOut(duration: 0.25)) {
                showControls = false
            }
        }
    }

    private func setupOrientation() {
        isLandscape = UIDevice.current.orientation.isLandscape ||
                     UIScreen.main.bounds.width > UIScreen.main.bounds.height

        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [self] _ in
            isLandscape = UIDevice.current.orientation.isLandscape
        }
    }
}

// MARK: - 工具函数
func formatTime(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "00:00" }
    let total = Int(t)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

// MARK: - AVPlayer 控制器封装 V2
struct AVPlayerControllerRepresentableV2: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

// MARK: - 弹幕数据模型
private struct DanmakuItemData: Identifiable {
    let text: String
    var x: CGFloat
    let y: CGFloat
    let id: Int
}

// MARK: - 弹幕覆盖层 V2
struct DanmakuOverlayViewV2: View {
    @Binding var showDanmaku: Bool
    let opacity: Double
    let fontSize: CGFloat

    @State private var danmakuItems: [DanmakuItemData] = []
    @State private var allDanmaku: [(time: Double, text: String)] = []
    @State private var currentIndex = 0
    let timer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ForEach(danmakuItems) { item in
                Text(item.text)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundColor(.white.opacity(opacity))
                    .shadow(color: .black, radius: 2)
                    .position(x: item.x, y: item.y)
            }
        }
        .onReceive(timer) { _ in
            guard showDanmaku else { return }
            guard currentIndex < allDanmaku.count else { return }

            let item = allDanmaku[currentIndex]
            let y = CGFloat.random(in: 50...250)
            danmakuItems.append(DanmakuItemData(text: item.text, x: UIScreen.main.bounds.width + 50, y: y, id: currentIndex))
            let itemId = currentIndex
            currentIndex += 1

            DispatchQueue.main.async { [self] in
                withAnimation(.linear(duration: 8)) {
                    if let idx = danmakuItems.firstIndex(where: { $0.id == itemId }) {
                        var updatedItem = danmakuItems[idx]
                        updatedItem.x = -100
                        danmakuItems[idx] = updatedItem
                    }
                }
            }

            danmakuItems.removeAll { $0.x < -150 }
        }
    }
}

// MARK: - 播放速度设置 V2
struct PlayerSettingsViewV2: View {
    @Binding var speed: Double
    var onSpeedChange: (Double) -> Void
    let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("播放速度") {
                    ForEach(speeds, id: \.self) { s in
                        Button(action: {
                            speed = s
                            onSpeedChange(s)
                            dismiss()
                        }) {
                            HStack {
                                Text("\(s, specifier: "%.2f")x")
                                Spacer()
                                if s == speed {
                                    Image(systemName: "checkmark").foregroundColor(Color(hex: "E11D48"))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("播放设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 选集弹窗 V2
struct EpisodePickerViewV2: View {
    let video: VodItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                    ForEach(1..<101, id: \.self) { ep in
                        Button(action: { dismiss() }) {
                            Text("\(ep)")
                                .font(.system(size: 14))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.1)))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("选集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 清晰度选择 V2
struct QualityPickerViewV2: View {
    @Binding var selectedQuality: Int
    var onQualityChange: (Int) -> Void
    let qualities = ["标清", "高清", "蓝光"]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("清晰度选择") {
                    ForEach(0..<qualities.count, id: \.self) { index in
                        Button(action: {
                            selectedQuality = index
                            onQualityChange(index)
                            dismiss()
                        }) {
                            HStack {
                                Text(qualities[index])
                                Spacer()
                                if index == selectedQuality {
                                    Image(systemName: "checkmark").foregroundColor(Color(hex: "E11D48"))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("清晰度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 弹幕设置 V2
struct DanmakuSettingsViewV2: View {
    @Binding var showDanmaku: Bool
    @Binding var opacity: Double
    @Binding var fontSize: CGFloat

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("弹幕开关") {
                    Toggle("开启弹幕", isOn: $showDanmaku)
                }

                Section("弹幕透明度") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("透明度: \(Int(opacity * 100))%")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        Slider(value: $opacity, in: 0...1, step: 0.1)
                            .accentColor(Color(hex: "E11D48"))
                    }
                    .padding(.vertical, 4)
                }

                Section("弹幕字体大小") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("字号: \(Int(fontSize))")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        Slider(value: $fontSize, in: 12...24, step: 2)
                            .accentColor(Color(hex: "E11D48"))
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("弹幕设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - AirPlay V2
struct AirPlayViewV2: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        AVRoutePickerView()
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}