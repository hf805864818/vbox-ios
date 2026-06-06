import SwiftUI
import AVKit
import AVFoundation
import Combine
import UIKit
import MediaPlayer

// 屏幕方向辅助类
class OrientationHelper {
    static func lockOrientation(_ orientation: UIInterfaceOrientationMask) {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
        }
    }
    
    static func unlockOrientation() {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .all))
        }
    }
    
    static func rotateToLandscape() {
        // 强制旋转到横屏 - 使用 UIDevice 的 orientation 属性
        DispatchQueue.main.async {
            let orientation = UIInterfaceOrientation.landscapeRight.rawValue
            UIDevice.current.setValue(orientation, forKey: "orientation")
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}

// MARK: - 新版本播放器 (爱奇艺风格) - 简化版本，确保编译通过
struct VideoPlayerViewV2: View {
    let video: VodItem
    @StateObject private var playerState = PlayerState()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 播放器主体 - 始终显示，包含加载状态
            PlayerContainerView(
                player: playerState.player,
                playerState: playerState,
                video: video
            )
            
            // 错误提示
            if let error = playerState.loadError {
                ErrorView(error: error, onRetry: { playerState.retry(video: video) })
            }
        }
        .onAppear {
            // 强制横屏
            OrientationHelper.rotateToLandscape()
            playerState.setupPlayer(video: video)
        }
        .onDisappear {
            // 恢复竖屏
            OrientationHelper.lockOrientation(.portrait)
            OrientationHelper.unlockOrientation()
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
    @Published var isOrientationLocked = false  // 屏幕锁定状态
    
    // 选集相关
    @Published var episodeList: [(index: Int, title: String, url: String)] = []
    @Published var currentEpisodeIndex = 0
    
    // 手势控制
    @Published var brightness: Double = UIScreen.main.brightness
    @Published var volume: Double = AVAudioSession.sharedInstance().outputVolume
    
    // 弹幕（LogVar API）
    @Published var danmakuItems: [DanmakuRenderItem] = []
    
    private var timeObserver: Any?
    private var statusObserver: AnyCancellable?
    private var failureObserver: AnyCancellable?
    private var endObserver: AnyCancellable?
    
    private var currentTask: Task<Void, Never>?
    private var danmakuAnimTask: Task<Void, Never>?
    
    func setupPlayer(video: VodItem) {
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self = self else { return }
            await resolvePlayUrl(video: video)
        }
    }
    
    func cleanup() {
        currentTask?.cancel()
        currentTask = nil
        danmakuAnimTask?.cancel()
        danmakuAnimTask = nil
        cleanupObservers()
        player?.pause()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player = nil
    }
    
    func retry(video: VodItem) {
        currentTask?.cancel()
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
                loadError = "该资源在所有可用站点中均未找到播放源，请尝试更换资源"
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
                await handlePlaySliceUrl(firstUrl, spider: spider, video: video)
                return
            }
        }
        
        // 情况B: 单集或直链
        await handlePlaySliceUrl(finalPlayUrl, spider: spider, video: video)
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
    private func handlePlaySliceUrl(_ urlString: String, spider: SpiderManager, video: VodItem) async {
        print("[PlayerV2] 处理地址: \(urlString.prefix(80))...")
        
        // 检查是否是直链
        let isDirectLink: Bool = {
            guard urlString.hasPrefix("http") else { return false }
            let cleanPath: String
            if let url = URL(string: urlString) {
                cleanPath = url.path
            } else if let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                      let url = URL(string: encoded) {
                cleanPath = url.path
            } else {
                cleanPath = urlString
            }
            let ext = (cleanPath as NSString).pathExtension.lowercased()
            let videoExts = ["m3u8", "mp4", "flv", "m4v", "ts", "webm", "mkv", "avi", "mov"]
            if videoExts.contains(ext) { return true }
            return cleanPath.contains("/hls/") || cleanPath.contains("/video/")
        }()
        
        if isDirectLink {
            print("[PlayerV2] 直链模式: 直接使用")
            if let url = createURL(from: urlString) {
                await MainActor.run { initPlayer(url: url, vodItem: video) }
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
                    await MainActor.run { initPlayer(url: url, vodItem: video) }
                    return
                }
                print("[PlayerV2] ❌ 解析后的URL创建失败")
            }
        }
        
                // playerContent 失败，尝试解析器（parsePlayUrl）
        print("[PlayerV2] [切片] 尝试解析器...")
        if let parsedUrl = await spider.parsePlayUrl(from: urlString) {
            print("[PlayerV2] [切片] 解析器成功: \(parsedUrl.prefix(80))...")
            if let url = createURL(from: parsedUrl) {
                await MainActor.run { initPlayer(url: url, vodItem: video) }
                return
            }
        }
        
        // 所有方式失败
        print("[PlayerV2] [切片] 所有播放方式均失败")
        await MainActor.run {
            cleanupObservers()
            player?.pause()
            if let observer = timeObserver {
                player?.removeTimeObserver(observer)
                timeObserver = nil
            }
            player = nil
            loadError = "切片播放地址解析失败，请检查网络或尝试其他资源"
            isLoading = false
        }
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
        } else if playUrl.contains("$$") {
            urls = playUrl.components(separatedBy: "$$")
        } else if playUrl.contains("|") {
            urls = playUrl.components(separatedBy: "|")
        } else {
            urls = [playUrl]
        }
        return urls.filter { !$0.isEmpty }
    }
    
    private func initPlayer(url: URL, vodItem: VodItem? = nil) {
        print("[PlayerV2] 初始化播放器: \(url.absoluteString.prefix(100))...")
        
        // 清理旧的观察者
        if let oldObserver = timeObserver {
            player?.removeTimeObserver(oldObserver)
            timeObserver = nil
        }
        cleanupObservers()
        player?.pause()
        player = nil
        
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
        
        // 解析选集信息
        if let v = vodItem { parseAndLoadEpisodes(video: v) }
        
        // 拉取弹幕
        if let v = vodItem { fetchDanmaku(videoName: v.vodName) }
        
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
    
    // MARK: - 选集解析
    func parseAndLoadEpisodes(video: VodItem) {
        guard let playUrl = video.vodPlayUrl, !playUrl.isEmpty else { return }
        var episodes: [(Int, String, String)] = []
        let parts = playUrl.components(separatedBy: "#")
        for (idx, part) in parts.enumerated() {
            if let range = part.range(of: "$") {
                let title = String(part[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let url = String(part[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                episodes.append((idx + 1, title, url))
            } else if !part.isEmpty {
                episodes.append((idx + 1, "第\(idx+1)集", part))
            }
        }
        if !episodes.isEmpty { episodeList = episodes }
    }
    
    // MARK: - 弹幕拉取（LogVar API）
    func fetchDanmaku(videoName: String, episode: Int = 0) {
        guard showDanmaku else { return }
        danmakuAnimTask?.cancel()
        danmakuAnimTask = Task { [weak self] in
            guard let self = self else { return }
            let service = LogVarDanmakuService.shared
            guard let animeId = await service.searchAnime(keyword: videoName) else { return }
            let ep = episode > 0 ? episode : currentEpisodeIndex > 0 ? currentEpisodeIndex : 1
            let items = await service.fetchDanmaku(animeId: animeId, episode: ep)
            let renderItems = items.filter { $0.type == 1 || $0.type == 4 || $0.type == 5 }
                .map { item -> DanmakuRenderItem in
                    DanmakuRenderItem(id: item.id, content: item.content,
                        x: UIScreen.main.bounds.width + 50,
                        y: item.type == 5 ? 60 : item.type == 4 ? UIScreen.main.bounds.height - 60 : CGFloat.random(in: 50...300),
                        color: item.color)
                }
            await MainActor.run { self.danmakuItems = renderItems }
            await startDanmakuAnimation()
        }
    }
    
    private func startDanmakuAnimation() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 300_000_000)
            await MainActor.run {
                for i in danmakuItems.indices.reversed() {
                    danmakuItems[i].x -= 3
                    if danmakuItems[i].x < -200 { danmakuItems.remove(at: i) }
                }
            }
        }
    }
}

// MARK: - 播放器容器视图
struct PlayerContainerView: View {
    let player: AVPlayer?
    @ObservedObject var playerState: PlayerState
    let video: VodItem
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            // 视频层（如果有播放器）
            if let player = player {
                AVPlayerControllerRepresentableV2(player: player)
                    .ignoresSafeArea()
            }
            
            // 加载层（如果没有播放器且正在加载）
            if player == nil && playerState.isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("正在解析播放地址...")
                        .foregroundColor(.white.opacity(0.8))
                        .font(.subheadline)
                }
            }
            
            // 弹幕层（LogVar API 数据驱动）
            if playerState.showDanmaku && !playerState.danmakuItems.isEmpty {
                DanmakuOverlayViewV2(
                    items: playerState.danmakuItems,
                    opacity: playerState.danmakuOpacity,
                    fontSize: playerState.danmakuFontSize
                )
                .allowsHitTesting(false)
            }
            
            // 手势控制层（左侧亮度/右侧音量/双击暂停/单击控制栏）
            GestureControlView(playerState: playerState)
            
            // 控制层 - 始终显示，只是控制栏可以隐藏/显示
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
    let player: AVPlayer?
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
                
                // 屏幕锁定按钮
                Button(action: { 
                    playerState.isOrientationLocked.toggle()
                    if playerState.isOrientationLocked {
                        OrientationHelper.lockOrientation(.landscape)
                    } else {
                        OrientationHelper.unlockOrientation()
                    }
                }) {
                    Image(systemName: playerState.isOrientationLocked ? "lock.fill" : "lock.open")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.3))
                        .clipShape(Circle())
                }
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
                    // 播放/暂停 - 只有在有播放器时才可用
                    Button(action: { 
                        if let p = player {
                            playerState.isPlaying ? p.pause() : p.play()
                            playerState.isPlaying.toggle()
                        }
                    }) {
                        Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22))
                            .foregroundColor(player == nil ? .gray : .white)
                            .frame(width: 44, height: 44)
                    }
                    .disabled(player == nil)
                    
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
        // 侧边栏弹窗 - 播放设置
        .overlay(
            SidePanelView(isPresented: $playerState.showSettings, title: "播放设置") {
                PlayerSettingsPanelV2(speed: $playerState.playbackSpeed, onSpeedChange: { speed in
                    player?.rate = Float(speed)
                })
            }
        )
        // 侧边栏弹窗 - 选集
        .overlay(
            SidePanelView(isPresented: $playerState.showEpisodePicker, title: "选集") {
                EpisodePickerPanelV2(video: video, playerState: playerState)
            }
        )
        // 侧边栏弹窗 - 清晰度
        .overlay(
            SidePanelView(isPresented: $playerState.showQualityPicker, title: "清晰度") {
                QualityPickerPanelV2(selectedQuality: $playerState.selectedQuality, onQualityChange: { _ in })
            }
        )
        // 侧边栏弹窗 - 弹幕设置
        .overlay(
            SidePanelView(isPresented: $playerState.showDanmakuSettings, title: "弹幕设置") {
                DanmakuSettingsPanelV2(
                    showDanmaku: $playerState.showDanmaku,
                    opacity: $playerState.danmakuOpacity,
                    fontSize: $playerState.danmakuFontSize
                )
            }
        )
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

// MARK: - 弹幕覆盖层
// MARK: - AirPlay 视图

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

// MARK: - 侧边栏弹窗容器
struct SidePanelView<Content: View>: View {
    @Binding var isPresented: Bool
    let title: String
    let content: Content
    
    init(isPresented: Binding<Bool>, title: String, @ViewBuilder content: () -> Content) {
        self._isPresented = isPresented
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if isPresented {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isPresented = false
                            }
                        }
                    
                    HStack {
                        Spacer()
                        
                        VStack(spacing: 0) {
                            HStack {
                                Text(title)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                                
                                Spacer()
                                
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        isPresented = false
                                    }
                                }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundColor(.white)
                                        .frame(width: 36, height: 36)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color.black.opacity(0.9))
                            
                            content
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(hex: "1A1A1A"))
                        }
                        .frame(width: geometry.size.width * 0.45)
                        .background(Color(hex: "1A1A1A"))
                        .cornerRadius(12, corners: [.topLeft, .bottomLeft])
                        .transition(.move(edge: .trailing))
                    }
                    .ignoresSafeArea()
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isPresented)
        }
    }
}

// MARK: - 播放设置面板 (侧边栏版本)
struct PlayerSettingsPanelV2: View {
    @Binding var speed: Double
    var onSpeedChange: (Double) -> Void
    
    let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("播放速度")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(speeds, id: \.self) { s in
                        Button(action: {
                            speed = s
                            onSpeedChange(s)
                        }) {
                            let speedText = s == floor(s) ? String(format: "%.0f", s) : String(format: "%.2f", s)
                            Text(speedText + "X")
                                .font(.system(size: 16, weight: speed == s ? .semibold : .regular))
                                .foregroundColor(speed == s ? Color(hex: "00BEFF") : .white)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(speed == s ? Color(hex: "00BEFF").opacity(0.2) : Color.white.opacity(0.1))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(speed == s ? Color(hex: "00BEFF") : Color.clear, lineWidth: 1)
                                )
                        }
                    }
                }
                .padding(.horizontal, 16)
                
                Spacer()
            }
        }
    }
}

// MARK: - 选集面板 (侧边栏版本)
// MARK: - 清晰度面板 (侧边栏版本)
struct QualityPickerPanelV2: View {
    @Binding var selectedQuality: Int
    var onQualityChange: (Int) -> Void
    
    let qualities = ["标清", "高清", "蓝光"]
    
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(0..<qualities.count, id: \.self) { index in
                    Button(action: {
                        selectedQuality = index
                        onQualityChange(index)
                    }) {
                        HStack {
                            Text(qualities[index])
                                .font(.system(size: 16, weight: selectedQuality == index ? .semibold : .regular))
                                .foregroundColor(selectedQuality == index ? Color(hex: "00BEFF") : .white)
                            
                            Spacer()
                            
                            if selectedQuality == index {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Color(hex: "00BEFF"))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedQuality == index ? Color(hex: "00BEFF").opacity(0.1) : Color.clear)
                        )
                    }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - 弹幕设置面板 (侧边栏版本)
struct DanmakuSettingsPanelV2: View {
    @Binding var showDanmaku: Bool
    @Binding var opacity: Double
    @Binding var fontSize: CGFloat
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HStack {
                    Text("开启弹幕")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Toggle("弹幕", isOn: $showDanmaku)
                        .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                
                VStack(spacing: 8) {
                    HStack {
                        Text("弹幕透明度")
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                        Spacer()
                        Text("\(Int(opacity * 100))%")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 16)
                    
                    Slider(value: $opacity, in: 0...1, step: 0.1)
                        .padding(.horizontal, 16)
                }
                
                VStack(spacing: 8) {
                    HStack {
                        Text("弹幕字体大小")
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                        Spacer()
                        Text("\(Int(fontSize))px")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 16)
                    
                    Slider(value: $fontSize, in: 12...24, step: 1)
                        .padding(.horizontal, 16)
                }
                
                Spacer()
            }
        }
    }
}

// MARK: - View Extension for Corner Radius
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners
    
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}
