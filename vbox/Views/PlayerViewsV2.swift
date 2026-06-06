import SwiftUI
import AVKit
import AVFoundation
import Combine

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
    private var statusObserver: AnyCancellable?
    private var failureObserver: AnyCancellable?
    private var endObserver: AnyCancellable?
    
    func setupPlayer(video: VodItem) {
        Task { await resolvePlayUrl(video: video) }
    }
    
    func cleanup() {
        cleanupObservers()
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
    
    // MARK: - 播放地址解析
    private func resolvePlayUrl(video: VodItem) async {
        print("[PlayerV2] 开始解析播放地址: \(video.vodId)")
        
        let spider = SpiderManager.shared
        var playUrl: String? = video.vodPlayUrl
        var playFrom: String? = video.vodPlayFrom
        
        // 步骤1: 优先通过 getDetail 获取最新详情
        print("[PlayerV2] 步骤1: 获取视频详情...")
        if let detail = await spider.getDetail(ids: video.vodId, name: video.vodName) {
            print("[PlayerV2] 步骤1: 获取详情成功")
            if let pu = detail.vodPlayUrl, !pu.isEmpty {
                playUrl = pu
                playFrom = detail.vodPlayFrom
                print("[PlayerV2] 步骤1: 使用详情中的播放地址")
            }
        } else {
            print("[PlayerV2] 步骤1: 使用传入的播放地址")
        }
        
        // 步骤2: 检查 playUrl 的类型并处理
        guard let finalPlayUrl = playUrl, !finalPlayUrl.isEmpty else {
            print("[PlayerV2] 错误: 没有可用的播放地址")
            await MainActor.run {
                loadError = "无法获取播放地址"
                isLoading = false
            }
            return
        }
        
        print("[PlayerV2] 步骤2: 处理播放地址")
        
        // 情况A: 多集格式（包含 $ 或 #）
        if finalPlayUrl.contains("$") || finalPlayUrl.contains("#") {
            print("[PlayerV2] 步骤2: 检测到多集格式")
            let urls = parsePlayUrls(playFrom: playFrom ?? "", playUrl: finalPlayUrl)
            print("[PlayerV2] 步骤2: 解析出 \(urls.count) 个地址")
            
            if let firstUrl = urls.first, !firstUrl.isEmpty {
                await handlePlayUrl(firstUrl, spider: spider, video: video)
                return
            }
        }
        
        // 情况B: 单集或直链
        await handlePlayUrl(finalPlayUrl, spider: spider, video: video)
    }
    
    // MARK: - 安全创建URL（处理编码）
    private func createURL(from urlString: String) -> URL? {
        // 先尝试直接创建
        if let url = URL(string: urlString) {
            return url
        }
        
        // 如果失败，尝试进行URL编码
        if let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            if let url = URL(string: encoded) {
                print("[PlayerV2] URL编码成功: \(urlString.prefix(50))... -> \(encoded.prefix(50))...")
                return url
            }
        }
        
        // 尝试对路径部分编码
        if let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) {
            if let url = URL(string: encoded) {
                print("[PlayerV2] URL编码成功(2): \(urlString.prefix(50))...")
                return url
            }
        }
        
        print("[PlayerV2] ❌ URL创建失败: \(urlString)")
        return nil
    }
    
    // MARK: - 处理单个播放地址
    private func handlePlayUrl(_ urlString: String, spider: SpiderManager, video: VodItem) async {
        print("[PlayerV2] 处理地址: \(urlString.prefix(80))...")
        
        // 检查是否是直链
        let isDirectLink = urlString.hasPrefix("http") && (
            urlString.contains(".m3u8") ||
            urlString.contains(".mp4") ||
            urlString.contains(".flv") ||
            urlString.contains(".m4v") ||
            urlString.contains(".ts") ||
            urlString.contains("/hls/") ||
            urlString.contains("/video/")
        )
        
        if isDirectLink {
            print("[PlayerV2] 直链模式: 直接使用")
            if let url = createURL(from: urlString) {
                await MainActor.run { initPlayer(url: url) }
                return
            }
            print("[PlayerV2] ❌ 直链URL创建失败")
        }
        
        // 需要解析的链接：调用 getPlayerContent
        print("[PlayerV2] 解析模式: 需要调用 playerContent")
        if let pr = await spider.getPlayerContent(vodId: video.vodId, flag: "play", url: urlString) {
            let pu = pr.playUrl ?? pr.url
            if let pu = pu, !pu.isEmpty {
                print("[PlayerV2] 解析成功: \(pu.prefix(80))...")
                if let url = createURL(from: pu) {
                    await MainActor.run { initPlayer(url: url) }
                    return
                }
                print("[PlayerV2] ❌ 解析后的URL创建失败")
            }
        }
        
        // 尝试 nativeDetail 作为备选
        print("[PlayerV2] 备选: 尝试 nativeDetail...")
        let nd = await spider.nativeDetail(ids: video.vodId, name: video.vodName)
        if let nd = nd, let pu = nd.vodPlayUrl, !pu.isEmpty {
            print("[PlayerV2] nativeDetail 成功")
            // 处理多集格式
            let urls = parsePlayUrls(playFrom: nd.vodPlayFrom ?? "", playUrl: pu)
            print("[PlayerV2] 解析出 \(urls.count) 个播放地址")
            for (index, videoUrl) in urls.enumerated() {
                print("[PlayerV2] 地址\(index): \(videoUrl.prefix(60))...")
            }
            let du = urls.first(where: { $0.contains(".m3u8") || $0.contains(".mp4") }) ?? urls.first ?? pu
            if !du.isEmpty {
                if let url = createURL(from: du) {
                    await MainActor.run { initPlayer(url: url) }
                    return
                }
                print("[PlayerV2] ❌ nativeDetail URL创建失败")
            }
        }
        
        // 检查是否是网盘链接
        print("[PlayerV2] 检查网盘链接...")
        let playUrlToCheck = video.vodPlayUrl ?? nd?.vodPlayUrl ?? urlString
        if !playUrlToCheck.isEmpty, let driveType = CloudDriveManager.detectDrive(from: playUrlToCheck) {
            print("[PlayerV2] 检测到 \(driveType.displayName) 网盘链接")
            do {
                let result = try await CloudDriveManager.shared.resolvePlayURL(from: playUrlToCheck)
                print("[PlayerV2] 网盘解析成功: \(result.url.prefix(60))...")
                if let url = URL(string: result.url) {
                    let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": result.headers])
                    let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                    p.automaticallyWaitsToMinimizeStalling = true
                    
                    await MainActor.run {
                        self.player = p
                        self.isPlaying = true
                        self.isLoading = false
                    }
                    
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
                    return
                }
            } catch {
                print("[PlayerV2] 网盘解析失败: \(error.localizedDescription)")
            }
        }
        
        // 所有方式失败
        print("[PlayerV2] 所有方式都失败")
        await MainActor.run {
            loadError = "无法解析播放地址"
            isLoading = false
        }
    }
    
    // MARK: - 解析多集播放地址
    private func parsePlayUrls(playFrom: String, playUrl: String) -> [String] {
        var urls: [String] = []
        if playUrl.contains("#") {
            let parts = playUrl.components(separatedBy: "#")
            for part in parts {
                if let range = part.range(of: "$") {
                    let u = String(part[range.upperBound...])
                    if !u.isEmpty { urls.append(u) }
                } else if !part.isEmpty {
                    urls.append(part)
                }
            }
        } else if playUrl.contains("$$$") {
            urls = playUrl.components(separatedBy: "$$$")
        } else {
            urls = [playUrl]
        }
        return urls.filter { !$0.isEmpty }
    }
    
    private func initPlayer(url: URL) {
        print("[PlayerV2] 初始化播放器: \(url.absoluteString.prefix(100))...")
        
        // 配置Asset选项（针对m3u8切片优化）
        var assetOptions: [String: Any] = [:]
        
        // 提取域名作为Referer
        var referer = url.absoluteString
        if let host = url.host {
            referer = "https://\(host)/"
        }
        
        // 设置HTTP头（m3u8播放通常需要正确的User-Agent和Referer）
        assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
            "Accept": "*/*",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Referer": referer
        ]
        
        print("[PlayerV2] HTTP头配置 - Referer: \(referer)")
        
        // 创建Asset和PlayerItem
        let asset = AVURLAsset(url: url, options: assetOptions)
        let playerItem = AVPlayerItem(asset: asset)
        
        // 配置PlayerItem（针对HLS/m3u8优化）
        playerItem.preferredForwardBufferDuration = 10.0 // 预缓冲10秒
        
        // 监听PlayerItem状态
        var localStatusObserver: AnyCancellable?
        localStatusObserver = playerItem.publisher(for: \.status)
            .sink { [weak self] status in
                switch status {
                case .readyToPlay:
                    print("[PlayerV2] PlayerItem 准备就绪")
                case .failed:
                    let errorDesc = playerItem.error?.localizedDescription ?? "未知错误"
                    print("[PlayerV2] ❌ PlayerItem 失败: \(errorDesc)")
                    Task { @MainActor in
                        self?.loadError = "加载失败: \(errorDesc)"
                        self?.isLoading = false
                        self?.player = nil
                    }
                case .unknown:
                    print("[PlayerV2] PlayerItem 状态未知")
                @unknown default:
                    break
                }
            }
        statusObserver = localStatusObserver
        
        // 创建播放器
        let p = AVPlayer(playerItem: playerItem)
        p.automaticallyWaitsToMinimizeStalling = true
        
        // 监听播放失败
        failureObserver = NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
            .sink { [weak self] notification in
                if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                    print("[PlayerV2] ❌ 播放失败: \(error.localizedDescription)")
                    Task { @MainActor in
                        self?.loadError = "播放失败: \(error.localizedDescription)"
                        self?.isLoading = false
                        self?.player = nil
                    }
                }
            }
        
        // 监听播放结束
        endObserver = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playerItem)
            .sink { _ in
                print("[PlayerV2] 播放结束")
            }
        
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
        
        // 延迟播放确保UI准备好
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            p.play()
            print("[PlayerV2] 播放器开始播放")
        }
    }
    
    private func cleanupObservers() {
        statusObserver?.cancel()
        failureObserver?.cancel()
        endObserver?.cancel()
        statusObserver = nil
        failureObserver = nil
        endObserver = nil
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
