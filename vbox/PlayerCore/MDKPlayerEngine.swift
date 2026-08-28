import AVFoundation
import UIKit

#if canImport(swift_mdk)
import swift_mdk
#endif

/// MDK 播放内核封装（wang-bin mdk-sdk + swift-mdk）。
/// 通过 Metal 离屏纹理渲染 + AVSampleBufferDisplayLayer 帧桥接实现系统级画中画。
final class MDKPlayerEngine: NSObject, PlayerEngine {
    let type: PlayerEngineType = .mdk
    let name = "MDK"

    private(set) var state = PlayerEngineState()
    var onEvent: ((PlayerEngineEvent) -> Void)?

    private weak var containerView: UIView?
    private var renderView: MDKRenderView?

    #if canImport(swift_mdk)
    private let player = Player()
    private var progressTimer: Timer?
    private var didFinish = false
    private var currentRoute: PlaybackRoute?
    private var observers: [NSObjectProtocol] = []
    #endif

    deinit {
        teardown()
    }

    func attach(to view: UIView) {
        containerView = view

        let drawable: MDKRenderView
        if let existingView = renderView {
            drawable = existingView
        } else {
            drawable = MDKRenderView(frame: view.bounds)
            drawable.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            renderView = drawable
        }

        drawable.frame = view.bounds
        if drawable.superview !== view {
            drawable.removeFromSuperview()
            view.addSubview(drawable)
        }

        #if canImport(swift_mdk)
        drawable.attach(player: player)
        #endif
    }

    /// 同步当前画面拉伸模式到渲染视图
    func syncVideoGravity(_ mode: PlayerState.VideoGravityMode) {
        renderView?.syncVideoGravity(mode)
    }

    func load(route: PlaybackRoute) {
        #if canImport(swift_mdk)
        didFinish = false
        progressTimer?.invalidate()
        progressTimer = nil
        currentRoute = route

        // 标记加载过渡期并清屏，防止旧解码器脏帧被 blit 到屏幕导致紫屏。
        // markReloadComplete() 会在 onStateChanged .Playing 回调中调用。
        renderView?.markReloading()

        // 同步设置新 URL：mdk-sdk 内部会自动停止旧 media 并启动新 media。
        // 之前用 DispatchQueue.main.async 延迟设置 URL，导致 engine.play()
        // 在 URL 设置前就执行 player.state = .Playing，mdk 在无 media 时
        // 触发 .Playing 回调，清除 isLoading 和 isReloading，但实际未加载任何内容，
        // 造成"正在启动 MDK..."永久卡住。
        player.media = route.url.absoluteString

        // ★ 彻底修复切集黑屏：setMedia（切集）之后强制重新绑定 renderTexture 到 MDK。
        // 防止 mdk 底层在切换媒体时重置 renderer、丢失之前绑定的纹理指针导致黑屏。
        // 注意：此调用必须在主线程（renderView 属于 Metal/UI 资源）。
        DispatchQueue.main.async { [weak self] in
            self?.renderView?.rebindRenderAPI()
        }
        var headerFields = ""
        for (key, value) in route.headers {
            let lowerKey = key.lowercased()
            if lowerKey == "user-agent" {
                headerFields += "User-Agent: \(value)\r\n"
            } else if lowerKey == "referer" || lowerKey == "referrer" {
                headerFields += "Referer: \(value)\r\n"
            } else {
                headerFields += "\(key): \(value)\r\n"
            }
        }
        if !headerFields.isEmpty {
            player.setProperty(name: "http-header-fields", value: headerFields)
        }

        // [优化3] m3u8 走 VT 硬解（H264 原生支持），仅 download_url 降级 FFmpeg 软解
        // 原因：m3u8 转码流为 H264，VT 硬解 CPU 占用降 80%，不再卡首帧
        let urlString = route.url.absoluteString.lowercased()
        // m3u8 流检测：原始 m3u8 URL 或 Go 代理标记为 quark-m3u8 的 URL
        let isQuarkM3U8 = urlString.contains("media.m3u8")
            || urlString.contains("drive.quark.cn/qv/")
            || (urlString.contains("127.0.0.1") && urlString.contains("quark-m3u8"))
        // download_url 直链检测：原始 dl- 域名或 Go 代理标记为 quark-stream 的 URL
        let isQuarkDownload = (urlString.contains("dl-") && urlString.contains("drive.quark.cn"))
            || (urlString.contains("127.0.0.1") && urlString.contains("quark-stream"))
        if isQuarkM3U8 {
            // m3u8 H264 走 VT 硬解，FFmpeg 兜底
            player.videoDecoders = ["VT", "FFmpeg"]
        } else if isQuarkDownload {
            // download_url (HEVC MKV) 仍用 FFmpeg 软解 + 网络放宽
            player.videoDecoders = ["FFmpeg"]
            player.setProperty(name: "avformat.fflags", value: "+fastseek")
            player.setProperty(name: "avformat.reconnect", value: "1")
            player.setProperty(name: "avformat.reconnect_streamed", value: "1")
            player.setProperty(name: "avformat.reconnect_delay_max", value: "2000")
            player.setProperty(name: "avformat.timeout", value: "30000000")
            player.setProperty(name: "avformat.rw_timeout", value: "30000000")
        } else {
            player.videoDecoders = ["VT", "FFmpeg"]
        }

        // [优化6] 缓冲预热：对齐 iBox 的 SetBuffer/cacheZone 机制
        // 预加载更多数据后再开始播放，减少首帧后的卡顿
        if isQuarkM3U8 || isQuarkDownload {
            // 增大 I/O 缓冲区，减少频繁的小数据包回传
            player.setProperty(name: "avio.buffer_size", value: "262144") // 256KB
            // HLS 预读缓冲：提前读取更多分片数据
            player.setProperty(name: "readahead", value: "8.0") // 预读 8 秒
            // 降低首帧延迟（尽快出画面）
            player.setProperty(name: "avformat.analyzeduration", value: "1000000") // 1s
            // 允许在缓冲不足时降低帧率而非卡死
            player.setProperty(name: "framedrop", value: "1")
        }

        // 绑定状态回调
        player.onStateChanged { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .Playing:
                self.state.isBuffering = false
                self.state.isPlaying = true
                self.onEvent?(.buffering(false))
                self.onEvent?(.ready)
                // NOTE: 不再在此处调用 markReloadComplete()。
                // .Playing 表示播放已开始，但首帧可能尚未渲染到 renderTexture。
                // isReloading 的解除已移至 draw(in:) 内自适应判断：
                // 只有 renderVideo() 返回 pts >= 0（新帧真正可用）时才解除，
                // 防止旧解码器脏帧被 blit 到屏幕导致紫屏。
            case .Paused:
                self.state.isPlaying = false
            case .Stopped:
                self.state.isPlaying = false
            @unknown default:
                break
            }
        }

        // 监听 PiP 播放控制
        setupPiPControlObservers()

        // 激活音频会话（PiP 与后台播放需要）
        activateAudioSession()

        state = PlayerEngineState(isBuffering: true)
        onEvent?(.buffering(true))
        onEvent?(.log("MDK 内核加载线路：\(route.title)"))
        startProgressTimer()

        // 不调用 prepare()：setMedia + setState(.Playing) 已足够触发解码与 render callback。
        // 之前 prepare(from: 0, complete: nil) 会阻塞/卡状态，导致网盘资源长时间“正在启动 MDK...”。
        #else
        let message = "当前构建未包含 MDK 内核"
        state.errorMessage = message
        onEvent?(.failed(message))
        #endif
    }

    func play() {
        #if canImport(swift_mdk)
        player.state = .Playing
        state.isPlaying = true
        // 不在这里发送 .ready/.buffering(false)：
        // 应等 onStateChanged 的 .Playing 真正触发后再通知 UI 首帧已就绪，
        // 否则“正在启动 MDK...”会在还没出画面前就消失，露出未初始化的纹理。
        #endif
    }

    func pause() {
        #if canImport(swift_mdk)
        player.state = .Paused
        #endif
        state.isPlaying = false
    }

    func stop() {
        progressTimer?.invalidate()
        progressTimer = nil
        #if canImport(swift_mdk)
        player.state = .Stopped
        #endif
        state.isPlaying = false
        state.currentTime = 0
    }

    func seek(to seconds: Double) {
        #if canImport(swift_mdk)
        let ms = Int64(seconds * 1000)
        _ = player.seek(ms) { [weak self] _ in
            self?.state.currentTime = seconds
        }
        #endif
        state.currentTime = max(0, seconds)
    }

    func setRate(_ rate: Double) {
        #if canImport(swift_mdk)
        player.playbackRate = Float(rate)
        #endif
    }

    func setVolume(_ volume: Double) {
        #if canImport(swift_mdk)
        player.volume = Float(volume)
        #endif
    }

    func teardown() {
        progressTimer?.invalidate()
        progressTimer = nil
        #if canImport(swift_mdk)
        player.setRenderCallback(nil)
        player.state = .Stopped
        #endif
        renderView?.removeFromSuperview()
        renderView = nil
        containerView = nil
        currentRoute = nil
        state = PlayerEngineState()
        removePiPControlObservers()
    }

    // MARK: - PiP 控制

    func startPiP() {
        #if canImport(swift_mdk)
        DispatchQueue.main.async { [weak self] in
            self?.renderView?.setPiPEnabled(true)
            MDKPipManager.shared.startPiP()
        }
        #endif
    }

    func stopPiP() {
        #if canImport(swift_mdk)
        // 同步关闭帧捕获，避免回调继续向已停止的 PiP 管理器推帧导致死锁
        renderView?.setPiPEnabled(false)
        DispatchQueue.main.async {
            MDKPipManager.shared.stopPiP()
        }
        #endif
    }

    // MARK: - 进度轮询

    #if canImport(swift_mdk)
    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5,
                                              repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pollProgress()
        }
    }

    private func pollProgress() {
        let currentMs = player.position
        let current = Double(currentMs) / 1000.0
        let total = currentDuration()

        if current.isFinite {
            state.currentTime = max(0, current)
        }
        if total.isFinite, total > 0 {
            state.duration = total
        }

        if let video = player.mediaInfo.video.first {
            state.width = Int(video.codec.width)
            state.height = Int(video.codec.height)
            // 同步视频原始尺寸到渲染视图，用于 setAspectRatio 计算
            renderView?.updateVideoSize(width: state.width, height: state.height)
        }

        onEvent?(.progress(current: state.currentTime, duration: state.duration))

        if !didFinish, total > 1, current >= max(0, total - 0.8) {
            didFinish = true
            state.isPlaying = false
            state.currentTime = total
            onEvent?(.ended)
        }
    }

    private func currentDuration() -> Double {
        Double(player.mediaInfo.duration) / 1000.0
    }

    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: .mixWithOthers)
            try session.setActive(true)
        } catch {
            print("[MDK] 音频会话激活失败: \(error.localizedDescription)")
        }
    }

    private func setupPiPControlObservers() {
        removePiPControlObservers()

        observers.append(NotificationCenter.default.addObserver(forName: .vboxPiPTogglePlayPause, object: nil, queue: .main) { [weak self] note in
            guard let playing = note.object as? Bool else { return }
            playing ? self?.play() : self?.pause()
        })

        observers.append(NotificationCenter.default.addObserver(forName: .vboxMDKPiPSkip, object: nil, queue: .main) { [weak self] note in
            guard let interval = note.object as? CMTime else { return }
            let seconds = CMTimeGetSeconds(interval)
            let current = self?.state.currentTime ?? 0
            self?.seek(to: current + seconds)
        })

        observers.append(NotificationCenter.default.addObserver(forName: .vboxPiPRestoreFullScreen, object: nil, queue: .main) { [weak self] _ in
            self?.stopPiP()
        })
    }

    private func removePiPControlObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
    #endif
}
