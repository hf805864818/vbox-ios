import AVFoundation
import UIKit

#if canImport(mdk)
import mdk
#endif

/// MDK 播放内核封装（wang-bin mdk-sdk）。
/// 支持帧回调画中画（PiP: AVSampleBufferDisplayLayer 帧桥接）。
/// 当前只接入 PlayerCore，不替换现有 PlayerViewsV2 播放主流程。
final class MDKPlayerEngine: NSObject, PlayerEngine {
    let type: PlayerEngineType = .mdk
    let name = "MDK"

    private(set) var state = PlayerEngineState()
    var onEvent: ((PlayerEngineEvent) -> Void)?

    private weak var containerView: UIView?
    private var renderView: UIView?

    #if canImport(mdk)
    private let player = mdk::Player()
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

        #if canImport(mdk)
        player.setVideoSurfaceSize(Int32(view.bounds.width),
                                   Int32(view.bounds.height))
        #endif
    }

    func load(route: PlaybackRoute) {
        #if canImport(mdk)
        didFinish = false
        progressTimer?.invalidate()
        progressTimer = nil
        currentRoute = route

        // 设置 Media URL
        player.setMedia(route.url.absoluteString)

        // 设置 HTTP Headers
        for (key, value) in route.headers {
            let lowerKey = key.lowercased()
            if lowerKey == "user-agent" {
                player.setOption("http-header-fields",
                                 "User-Agent: \(value)")
            } else if lowerKey == "referer" || lowerKey == "referrer" {
                player.setOption("http-header-fields",
                                 "Referer: \(value)")
            }
        }

        // 硬件解码 + copy=1（使VT解码输出可被CPU访问的CVPixelBuffer，用于PiP帧桥接）
        player.setOption("hwdec", "videotoolbox")
        player.setOption("copy", "1")

        // 绑定渲染视图
        if let renderView {
            player.setVideoSurface(renderView)
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
        #if canImport(mdk)
        player.play()
        state.isPlaying = true
        state.isBuffering = false
        onEvent?(.buffering(false))
        onEvent?(.ready)
        #endif
    }

    func pause() {
        #if canImport(mdk)
        player.pause()
        #endif
        state.isPlaying = false
    }

    func stop() {
        progressTimer?.invalidate()
        progressTimer = nil
        #if canImport(mdk)
        player.stop()
        #endif
        state.isPlaying = false
        state.currentTime = 0
    }

    func seek(to seconds: Double) {
        #if canImport(mdk)
        let duration = currentDuration()
        guard duration.isFinite, duration > 0 else { return }
        let position = max(0, min(seconds / duration, 1.0))
        player.seek(Int64(position * 1000000)) // mdk seek 使用微秒
        #endif
        state.currentTime = max(0, seconds)
    }

    func setRate(_ rate: Double) {
        #if canImport(mdk)
        player.setSpeed(Float(rate))
        #endif
    }

    func setVolume(_ volume: Double) {
        #if canImport(mdk)
        player.setVolume(Int32(min(max(volume, 0), 1) * 100))
        #endif
    }

    func teardown() {
        progressTimer?.invalidate()
        progressTimer = nil
        #if canImport(mdk)
        player.stop()
        #endif
        renderView?.removeFromSuperview()
        renderView = nil
        containerView = nil
        currentRoute = nil
        state = PlayerEngineState()
    }

    // MARK: - 进度轮询

    #if canImport(mdk)
    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5,
                                              repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pollProgress()
        }
    }

    private func pollProgress() {
        let current = Double(player.position()) / 1000000.0
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
        Double(player.duration()) / 1000000.0
    }
    #endif
}
