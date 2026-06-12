import UIKit

#if canImport(MPVKit)
import MPVKit
#endif

/// MPVKit 后端占位。
/// 只在这一层适配 MPVKit API，避免 UI/Controller 直接依赖 MPVKit。
final class MPVKitBackend: MPVBackend {
    let backendType: MPVBackendType = .mpvKit
    let name = "MPV"
    private(set) var state = PlayerEngineState()
    var onEvent: ((PlayerEngineEvent) -> Void)?
    #if canImport(MPVKit)
    private let core = MPVKitPlayerCore()
    #endif

    static var isAvailable: Bool {
        #if canImport(MPVKit)
        return true
        #else
        return false
        #endif
    }

    func attach(to view: UIView) {
        #if canImport(MPVKit)
        bindCore()
        core.attach(to: view)
        state = core.state
        #else
        state.errorMessage = "未找到 MPVKit.xcframework"
        onEvent?(.failed("未找到 MPVKit.xcframework"))
        #endif
    }

    func load(route: PlaybackRoute) {
        #if canImport(MPVKit)
        bindCore()
        core.load(route: route)
        state = core.state
        #else
        let message = "MPVKit 后端不可用，请确认 vbox/Libraries/MPV/MPVKit.xcframework 已下载并正确链接"
        state.errorMessage = message
        onEvent?(.failed(message))
        #endif
    }

    func play() {
        #if canImport(MPVKit)
        core.play()
        state = core.state
        #endif
    }

    func pause() {
        #if canImport(MPVKit)
        core.pause()
        state = core.state
        #endif
    }

    func stop() {
        #if canImport(MPVKit)
        core.stop()
        state = core.state
        #endif
    }

    func seek(to seconds: Double) {
        #if canImport(MPVKit)
        core.seek(to: seconds)
        state = core.state
        #endif
    }

    func setRate(_ rate: Double) {
        #if canImport(MPVKit)
        core.setRate(rate)
        state = core.state
        #endif
    }

    func setVolume(_ volume: Double) {
        #if canImport(MPVKit)
        core.setVolume(volume)
        state = core.state
        #endif
    }

    func teardown() {
        #if canImport(MPVKit)
        core.teardown()
        #endif
        state = PlayerEngineState()
    }

    private func bindCore() {
        #if canImport(MPVKit)
        core.onEvent = { [weak self] event in
            self?.onEvent?(event)
        }
        core.onStateChange = { [weak self] state in
            self?.state = state
        }
        #endif
    }
}
