import AVFoundation
import UIKit

#if canImport(swift_mdk)
import swift_mdk
#endif

/// MDK 播放内核封装（wang-bin mdk-sdk + swift-mdk）。
/// 支持帧回调画中画（PiP: AVSampleBufferDisplayLayer 帧桥接）。
/// 当前只接入 PlayerCore，不替换现有 PlayerViewsV2 播放主流程。
final class MDKPlayerEngine: NSObject, PlayerEngine {
    let type: PlayerEngineType = .mdk
    let name = "MDK"

    private(set) var state = PlayerEngineState()
    var onEvent: ((PlayerEngineEvent) -> Void)?

    private weak var containerView: UIView?
    private var renderView: UIView?

    #if canImport(swift_mdk)
    private let player = Player()
    private var progressTimer: Timer?
    private var didFinish = false
    private var currentRoute: PlaybackRoute?
    #endif

    deinit {
        teardown()
    }

    func attach(to view: UIView) {
        containerView = view

        let drawable: UIView
        if let existingView = renderView {
            drawable = existingView
        } else {
            drawable = UIView(frame: view.bounds)
            drawable.backgroundColor = .black
            drawable.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            renderView = drawable
        }

        drawable.frame = view.bounds
        if drawable.superview !== view {
            drawable.removeFromSuperview()
            view.addSubview(drawable)
        }

        #if canImport(swift_mdk)
        player.setVideoSurfaceSize(Int32(view.bounds.width),
                                   Int32(view.bounds.height))
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

        // 设置 HTTP Headers（通过 property 接口）
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

        // 硬件解码 + copy=1（使VT解码输出可被CPU访问的CVPixelBuffer，用于PiP帧桥接）
        player.setProperty(name: "hwdec", value: "videotoolbox")
        player.setProperty(name: "copy", value: "1")

        // 设置解码器优先级
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
        player.state = .Stopped
        #endif
        renderView?.removeFromSuperview()
        renderView = nil
        containerView = nil
        currentRoute = nil
        state = PlayerEngineState()
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
    #endif
}
