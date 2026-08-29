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

    // ===== 诊断日志新增属性 =====
    private var pollCount: Int = 0
    private var lastBufferingState: Bool? = nil
    private var lastLoggedCodec: String = ""
    private var loadStartTime: CFTimeInterval = 0
    private var firstFrameLogged = false
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
        loadStartTime = CACurrentMediaTime()
        firstFrameLogged = false
        pollCount = 0
        lastBufferingState = nil
        lastLoggedCodec = ""

        renderView?.markReloading()

        player.media = route.url.absoluteString

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

        let urlString = route.url.absoluteString.lowercased()
        let isQuarkM3U8 = urlString.contains("media.m3u8")
            || urlString.contains("drive.quark.cn/qv/")
            || (urlString.contains("127.0.0.1") && urlString.contains("quark-m3u8"))
        let isQuarkDownload = (urlString.contains("dl-") && urlString.contains("drive.quark.cn"))
            || (urlString.contains("127.0.0.1") && urlString.contains("quark-stream"))
        if isQuarkM3U8 {
            player.videoDecoders = ["VT", "FFmpeg"]
            onEvent?(.log("[MDK-Diag] decoder=VT+FFmpeg (m3u8) buffer=256KB readahead=8s"))
        } else if isQuarkDownload {
            player.videoDecoders = ["FFmpeg"]
            player.setProperty(name: "avformat.fflags", value: "+fastseek")
            player.setProperty(name: "avformat.reconnect", value: "1")
            player.setProperty(name: "avformat.reconnect_streamed", value: "1")
            player.setProperty(name: "avformat.reconnect_delay_max", value: "2000")
            player.setProperty(name: "avformat.timeout", value: "30000000")
            player.setProperty(name: "avformat.rw_timeout", value: "30000000")
            onEvent?(.log("[MDK-Diag] decoder=FFmpeg (download_url)"))
        } else {
            player.videoDecoders = ["VT", "FFmpeg"]
            onEvent?(.log("[MDK-Diag] decoder=VT+FFmpeg (default)"))
        }

        // [优化6] 缓冲预热
        if isQuarkM3U8 || isQuarkDownload {
            player.setProperty(name: "avio.buffer_size", value: "262144")
            player.setProperty(name: "readahead", value: "8.0")
            player.setProperty(name: "avformat.analyzeduration", value: "1000000")
            player.setProperty(name: "framedrop", value: "1")
        }

        player.onStateChanged { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .Playing:
                self.state.isBuffering = false
                self.state.isPlaying = true
                self.onEvent?(.buffering(false))
                self.onEvent?(.ready)
                if !self.firstFrameLogged {
                    self.firstFrameLogged = true
                    let elapsed = CACurrentMediaTime() - self.loadStartTime
                    self.onEvent?(.log("[MDK-Diag] first_frame_ms=\(Int(elapsed * 1000))"))
                }
            case .Paused:
                self.state.isPlaying = false
            case .Stopped:
                self.state.isPlaying = false
            @unknown default:
                break
            }
        }

        setupPiPControlObservers()
        activateAudioSession()

        state = PlayerEngineState(isBuffering: true)
        onEvent?(.buffering(true))
        onEvent?(.log("MDK 内核加载线路：\(route.title)"))
        startProgressTimer()
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
            renderView?.updateVideoSize(width: state.width, height: state.height)

            // ===== 诊断：首次获取到视频编码信息时记录 =====
            let codecName = video.codec.name ?? "unknown"
            if codecName != lastLoggedCodec {
                lastLoggedCodec = codecName
                onEvent?(.log("[MDK-Diag] codec=\(codecName) \(state.width)x\(state.height) duration=\(Int(total))s"))
            }
        }

        onEvent?(.progress(current: state.currentTime, duration: state.duration))

        // ===== 诊断：缓冲状态变化日志 =====
        let isBuffering = state.isBuffering
        if lastBufferingState != isBuffering {
            lastBufferingState = isBuffering
            if isBuffering {
                onEvent?(.log("[MDK-Diag] BUFFERING_START pos=\(String(format: "%.1f", current))s"))
            } else {
                onEvent?(.log("[MDK-Diag] BUFFERING_END pos=\(String(format: "%.1f", current))s"))
            }
        }

        // ===== 诊断：每 5 秒输出一次播放状态快照 =====
        pollCount += 1
        if pollCount % 10 == 0 {
            onEvent?(.log("[MDK-Diag] SNAP pos=\(String(format: "%.1f", current))/\(String(format: "%.1f", total))s buf=\(isBuffering ? "Y" : "N")"))
        }

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
