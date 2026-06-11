import UIKit

#if canImport(MPVKit)
import MPVKit
#endif

/// MPVKit 后端占位。
/// 后续接入 MPVKit.xcframework 时，只在这个文件里适配 MPVKit API。
final class MPVKitBackend: MPVBackend {
    let backendType: MPVBackendType = .mpvKit
    let name = "MPV"
    private(set) var state = PlayerEngineState()
    var onEvent: ((PlayerEngineEvent) -> Void)?

    static var isAvailable: Bool {
        #if canImport(MPVKit)
        return true
        #else
        return false
        #endif
    }

    func attach(to view: UIView) {
        // 第五步只预留后端结构，不创建真实 MPVKit 渲染层。
    }

    func load(route: PlaybackRoute) {
        let message = "MPVKit 后端已预留，等待接入 MPVKit.xcframework"
        state.errorMessage = message
        onEvent?(.failed(message))
    }

    func play() {}
    func pause() {}
    func stop() {}
    func seek(to seconds: Double) {}
    func setRate(_ rate: Double) {}
    func setVolume(_ volume: Double) {}
    func teardown() {
        state = PlayerEngineState()
    }
}
