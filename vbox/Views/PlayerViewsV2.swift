import SwiftUI
import AVKit
import AVFoundation

// MARK: - 新版本播放器 (爱奇艺风格) - 简化版本，确保编译通过
struct VideoPlayerViewV2: View {
    let video: VodItem
    @StateObject private var playerState = PlayerState()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 播放器主体
            if let player = playerState.player {
                PlayerContainerView(
                    player: player,
                    playerState: playerState,
                    video: video
                )
            }
            
            // 加载指示器
            if playerState.isLoading {
                LoadingView()
            }
            
            // 错误提示
            if let error = playerState.loadError {
                ErrorView(error: error, onRetry: { playerState.retry(video: video) })
            }
        }
        .onAppear {
            playerState.setupPlayer(video: video)
        }
        .onDisappear {
            playerState.cleanup()
        }
    }
}

// MARK: - 播放器状态管理
class PlayerState: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isPlaying = true
    @Published var showControls = true
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isLoading = true
    @Published var loadError: String?
    @Published var showSettings = false
    @Published var showEpisodePicker = false
    @Published var showQualityPicker = false
    @Published var showDanmakuSettings = false
    @Published var selectedQuality = 1
    @Published var playbackSpeed: Double = 1.0
    @Published var showDanmaku = true
    @Published var danmakuOpacity: Double = 0.8
    @Published var danmakuFontSize: CGFloat = 16
    
    private var timeObserver: Any?
    
    func setupPlayer(video: VodItem) {
        Task { await resolvePlayUrl(video: video) }
    }
    
    func cleanup() {
        player?.pause()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player = nil
    }
    
    func retry(video: VodItem) {
        loadError = nil
        isLoading = true
        setupPlayer(video: video)
    }
    
    private func resolvePlayUrl(video: VodItem) async {
        print("开始解析播放地址: \(video.vodId)")
        
        let spider = SpiderManager.shared
        var playUrl: String? = video.vodPlayUrl
        
        // 获取详情
        if let detail = await spider.getDetail(ids: video.vodId, name: video.vodName) {
            if let pu = detail.vodPlayUrl, !pu.isEmpty {
                playUrl = pu
            }
        }
        
        guard let finalUrl = playUrl, !finalUrl.isEmpty else {
            await MainActor.run {
                loadError = "无法获取播放地址"
                isLoading = false
            }
            return
        }
        
        await handlePlayUrl(finalUrl, spider: spider, video: video)
    }
    
    private func handlePlayUrl(_ urlString: String, spider: SpiderManager, video: VodItem) async {
        // 检查是否是直链
        let isDirectLink = urlString.hasPrefix("http") && (
            urlString.contains(".m3u8") ||
            urlString.contains(".mp4") ||
            urlString.contains(".flv") ||
            urlString.contains(".m4v")
        )
        
        if isDirectLink, let url = URL(string: urlString) {
            await MainActor.run { initPlayer(url: url) }
            return
        }
        
        // 需要解析的链接
        if let pr = await spider.getPlayerContent(vodId: video.vodId, flag: "play", url: urlString) {
            if let pu = pr.playUrl ?? pr.url, !pu.isEmpty, let url = URL(string: pu) {
                await MainActor.run { initPlayer(url: url) }
                return
            }
        }
        
        await MainActor.run {
            loadError = "无法解析播放地址"
            isLoading = false
        }
    }
    
    private func initPlayer(url: URL) {
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: playerItem)
        p.automaticallyWaitsToMinimizeStalling = true
        
        self.player = p
        self.isPlaying = true
        self.isLoading = false
        
        // 添加时间观察者
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTime = time.seconds
            if let itemDuration = p.currentItem?.duration {
                self?.duration = itemDuration.seconds.isFinite ? itemDuration.seconds : 0
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            p.play()
        }
    }
}

// MARK: - 播放器容器视图
struct PlayerContainerView: View {
    let player: AVPlayer
    @ObservedObject var playerState: PlayerState
    let video: VodItem
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            // 视频层
            AVPlayerControllerRepresentableV2(player: player)
                .ignoresSafeArea()
            
            // 弹幕层
            if playerState.showDanmaku {
                DanmakuOverlayViewV2(
                    showDanmaku: $playerState.showDanmaku,
                    opacity: playerState.danmakuOpacity,
                    fontSize: playerState.danmakuFontSize
                )
                .allowsHitTesting(false)
            }
            
            // 手势层
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        playerState.showControls.toggle()
                    }
                }
            
            // 控制层
            if playerState.showControls {
                PlayerControlsView(
                    player: player,
                    playerState: playerState,
                    video: video
                )
            }
        }
    }
}

// MARK: - 加载视图
struct LoadingView: View {
    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                Text("正在解析播放地址...")
                    .foregroundColor(.white.opacity(0.8))
                    .font(.subheadline)
            }
            Spacer()
        }
    }
}

// MARK: - 错误视图
struct ErrorView: View {
    let error: String
    let onRetry: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 50))
                    .foregroundColor(.orange)
                Text("加载失败")
                    .foregroundColor(.white)
                    .font(.title2)
                Text(error)
                    .foregroundColor(.white.opacity(0.7))
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                HStack(spacing: 20) {
                    Button(action: onRetry) {
                        Text("重试")
                            .foregroundColor(.white)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .cornerRadius(8)
                    }
                    
                    Button(action: { dismiss() }) {
                        Text("返回")
                            .foregroundColor(.white)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 12)
                            .background(Color.gray)
                            .cornerRadius(8)
                    }
                }
            }
            Spacer()
        }
    }
}

// MARK: - 播放器控制视图
struct PlayerControlsView: View {
    let player: AVPlayer
    @ObservedObject var playerState: PlayerState
    let video: VodItem
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack {
            // 顶部返回栏
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.3))
                        .clipShape(Circle())
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            
            Spacer()
            
            // 底部控制栏
            VStack(spacing: 0) {
                // 进度条区域
                HStack(spacing: 12) {
                    Text(formatTime(playerState.currentTime))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                    
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            // 背景轨道
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.3))
                                .frame(height: 4)
                            
                            // 进度条
                            if playerState.duration > 0 {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(hex: "00BEFF"))
                                    .frame(width: max(0, min(CGFloat(playerState.currentTime / playerState.duration) * geometry.size.width, geometry.size.width)), height: 4)
                            }
                        }
                    }
                    .frame(height: 20)
                    
                    Text(formatTime(playerState.duration))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                
                // 按钮控制栏
                HStack(spacing: 20) {
                    // 播放/暂停
                    Button(action: { 
                        playerState.isPlaying ? player.pause() : player.play()
                        playerState.isPlaying.toggle()
                    }) {
                        Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                    }
                    
                    // 下一个（如果是多集）
                    Button(action: { /* 下一集 */ }) {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                    }
                    
                    Spacer()
                    
                    // 选集
                    Button(action: { playerState.showEpisodePicker = true }) {
                        VStack(spacing: 2) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 18))
                            Text("选集")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                    }
                    
                    // 清晰度
                    Button(action: { playerState.showQualityPicker = true }) {
                        Text("高清")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
                            )
                    }
                    
                    // AirPlay
                    AirPlayViewV2()
                        .frame(width: 44, height: 44)
                    
                    // 弹幕
                    Button(action: { playerState.showDanmakuSettings = true }) {
                        VStack(spacing: 2) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 18))
                            Text("弹幕")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(playerState.showDanmaku ? Color(hex: "00BEFF") : .white)
                        .frame(width: 44, height: 44)
                    }
                    
                    // 更多设置
                    Button(action: { playerState.showSettings = true }) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.black.opacity(0),
                        Color.black.opacity(0.6),
                        Color.black.opacity(0.8)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .sheet(isPresented: $playerState.showSettings) {
            PlayerSettingsViewV2(speed: $playerState.playbackSpeed, onSpeedChange: { speed in
                player.rate = Float(speed)
            })
        }
        .sheet(isPresented: $playerState.showEpisodePicker) {
            EpisodePickerViewV2(video: video)
        }
        .sheet(isPresented: $playerState.showQualityPicker) {
            QualityPickerViewV2(selectedQuality: $playerState.selectedQuality, onQualityChange: { _ in })
        }
        .sheet(isPresented: $playerState.showDanmakuSettings) {
            DanmakuSettingsViewV2(
                showDanmaku: $playerState.showDanmaku,
                opacity: $playerState.danmakuOpacity,
                fontSize: $playerState.danmakuFontSize
            )
        }
    }
    
    private func formatTime(_ time: Double) -> String {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

// MARK: - AVPlayer 控制器封装 V2
struct AVPlayerControllerRepresentableV2: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspectFill
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}

// MARK: - 弹幕设置视图
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
                    Slider(value: $opacity, in: 0...1, step: 0.1)
                }

                Section("弹幕字体大小") {
                    Slider(value: $fontSize, in: 12...24, step: 2)
                }
            }
            .navigationTitle("弹幕设置")
        }
    }
}

// MARK: - 弹幕数据模型
private struct DanmakuItemData: Identifiable {
    let text: String
    var x: CGFloat
    let y: CGFloat
    let id: Int
}

// MARK: - 弹幕覆盖层
struct DanmakuOverlayViewV2: View {
    @Binding var showDanmaku: Bool
    let opacity: Double
    let fontSize: CGFloat

    @State private var danmakuItems: [DanmakuItemData] = []
    @State private var itemPositions: [Int: CGFloat] = [:]
    @State private var currentIndex = 0
    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ForEach(danmakuItems) { item in
                let xPos = itemPositions[item.id] ?? item.x
                Text(item.text)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundColor(.white.opacity(opacity))
                    .shadow(color: .black, radius: 2)
                    .position(x: xPos, y: item.y)
            }
        }
        .onReceive(timer) { _ in
            if showDanmaku {
                // 添加新弹幕
                if currentIndex < 20 && currentIndex % 3 == 0 {
                    let y = CGFloat.random(in: 50...200)
                    let newItem = DanmakuItemData(
                        text: "弹幕 \(currentIndex)",
                        x: UIScreen.main.bounds.width + 50,
                        y: y,
                        id: currentIndex
                    )
                    danmakuItems.append(newItem)
                    itemPositions[currentIndex] = UIScreen.main.bounds.width + 50
                }
                currentIndex += 1
                
                // 移动弹幕
                for id in itemPositions.keys {
                    if let currentX = itemPositions[id] {
                        itemPositions[id] = currentX - 3
                    }
                }
                
                // 移除屏幕外的弹幕
                danmakuItems.removeAll { item in
                    let x = itemPositions[item.id] ?? 0
                    return x < -200
                }
                itemPositions = itemPositions.filter { $0.value > -200 }
            }
        }
    }
}

// MARK: - AirPlay 视图
struct AirPlayViewV2: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        AVRoutePickerView()
    }
    
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - 播放设置视图
struct PlayerSettingsViewV2: View {
    @Binding var speed: Double
    var onSpeedChange: (Double) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("播放速度") {
                    ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { s in
                        Button("\(s)x") {
                            speed = s
                            onSpeedChange(s)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("播放设置")
        }
    }
}

// MARK: - 选集选择视图
struct EpisodePickerViewV2: View {
    let video: VodItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(1..<21, id: \.self) { ep in
                    Button("第\(ep)集") {
                        dismiss()
                    }
                }
            }
            .navigationTitle("选集")
        }
    }
}

// MARK: - 清晰度选择视图
struct QualityPickerViewV2: View {
    @Binding var selectedQuality: Int
    var onQualityChange: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(0..<3, id: \.self) { index in
                    Button(["标清", "高清", "蓝光"][index]) {
                        selectedQuality = index
                        onQualityChange(index)
                        dismiss()
                    }
                }
            }
            .navigationTitle("清晰度")
        }
    }
}
