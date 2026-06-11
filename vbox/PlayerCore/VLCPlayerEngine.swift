import UIKit

#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

/// VLC 播放内核封装。
/// 当前只接入 PlayerCore，不替换现有 PlayerViewsV2 的 VLC 播放主流程。
final class VLCPlayerEngine: NSObject, PlayerEngine {
    let type: PlayerEngineType = .vlc
    let name = "VLC"

    private(set) var state = PlayerEngineState()
    var onEvent: ((PlayerEngineEvent) -> Void)?

    private weak var containerView: UIView?
    private var renderView: UIView?
    #if canImport(MobileVLCKit)
    private let mediaPlayer = VLCMediaPlayer()
    #endif
    private var progressTimer: Timer?
    private var didFinish = false

    deinit {
        teardown()
    }

    func attach(to view: UIView) {
        containerView = view

        #if canImport(MobileVLCKit)
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
        mediaPlayer.drawable = drawable
        #endif
    }

    func load(route: PlaybackRoute) {
        #if canImport(MobileVLCKit)
        didFinish = false
        progressTimer?.invalidate()
        progressTimer = nil

        let media = VLCMedia(url: route.url)
        var options: [AnyHashable: Any] = [:]
        for (key, value) in route.headers {
            let lowerKey = key.lowercased()
            if lowerKey == "user-agent" {
                options["http-user-agent"] = value
            } else if lowerKey == "referer" || lowerKey == "referrer" {
                options["http-referrer"] = value
            }
        }
        if !options.isEmpty {
            media.addOptions(options)
        }

        mediaPlayer.media = media
        if let renderView {
            mediaPlayer.drawable = renderView
        }

        state = PlayerEngineState(isBuffering: true)
        onEvent?(.buffering(true))
        onEvent?(.log("VLC 内核加载线路：\(route.title)"))
        startProgressTimer()
        #else
        let message = "当前构建未包含 VLC 内核"
        state.errorMessage = message
        onEvent?(.failed(message))
        #endif
    }

    func play() {
        #if canImport(MobileVLCKit)
        mediaPlayer.play()
        state.isPlaying = true
        state.isBuffering = false
        onEvent?(.buffering(false))
        onEvent?(.ready)
        #endif
    }

    func pause() {
        #if canImport(MobileVLCKit)
        mediaPlayer.pause()
        #endif
        state.isPlaying = false
    }

    func stop() {
        progressTimer?.invalidate()
        progressTimer = nil
        #if canImport(MobileVLCKit)
        mediaPlayer.stop()
        #endif
        state.isPlaying = false
        state.currentTime = 0
    }

    func seek(to seconds: Double) {
        #if canImport(MobileVLCKit)
        let duration = currentDuration()
        guard duration.isFinite, duration > 0 else { return }
        mediaPlayer.position = Float(max(0, min(seconds / duration, 1)))
        #endif
        state.currentTime = max(0, seconds)
    }

    func setRate(_ rate: Double) {
        #if canImport(MobileVLCKit)
        mediaPlayer.rate = Float(rate)
        #endif
    }

    func setVolume(_ volume: Double) {
        #if canImport(MobileVLCKit)
        mediaPlayer.audio?.volume = Int32(min(max(volume, 0), 1) * 100)
        #endif
    }

    func teardown() {
        progressTimer?.invalidate()
        progressTimer = nil
        #if canImport(MobileVLCKit)
        mediaPlayer.stop()
        mediaPlayer.drawable = nil
        #endif
        renderView?.removeFromSuperview()
        renderView = nil
        containerView = nil
        state = PlayerEngineState()
    }

    private func startProgressTimer() {
        #if canImport(MobileVLCKit)
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pollProgress()
        }
        #endif
    }

    private func pollProgress() {
        #if canImport(MobileVLCKit)
        let current = Double(mediaPlayer.time.intValue) / 1000.0
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
        #endif
    }

    private func currentDuration() -> Double {
        #if canImport(MobileVLCKit)
        Double(mediaPlayer.media?.length.intValue ?? 0) / 1000.0
        #else
        0
        #endif
    }
}
