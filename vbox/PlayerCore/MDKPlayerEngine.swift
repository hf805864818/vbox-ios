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

    func load(route: PlaybackRoute) {
        #if canImport(swift_mdk)
        didFinish = false
        progressTimer?.invalidate()
        progressTimer = nil
        currentRoute = route

        // 设置 Media URL
        player.media = route.url.absoluteString

        // 设置 HTTP Headers
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

        // 开启硬解；copy=1 让 VT 解码器输出可 CPU 访问的 buffer（部分场景备用）
        player.setProperty(name: "hwdec", value: "videotoolbox")
        player.setProperty(name: "copy", value: "1")
        player.videoDecoders = ["VT", "FFmpeg"]

        // 绑定状态回调
        player.onStateChanged { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .Playing:
                self.state.isBuffering = false
                self.state.isPlaying = true
                self.onEvent?(.buffering(false))
                self.onEvent?(.ready)
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
        state.isBuffering = false
        onEvent?(.buffering(false))
        onEvent?(.ready)
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
        DispatchQueue.main.async { [weak self] in
            self?.renderView?.setPiPEnabled(false)
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
