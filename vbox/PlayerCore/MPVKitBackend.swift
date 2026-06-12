import UIKit

/// MPVKit 后端占位。
/// 后续接入 MPVKit.xcframework 时，只在这个文件里适配 MPVKit API。
final class MPVKitBackend: MPVBackend {
    let backendType: MPVBackendType = .mpvKit
    let name = "MPV"
    private(set) var state = PlayerEngineState()
    var onEvent: ((PlayerEngineEvent) -> Void)?

    static var isAvailable: Bool {
        // MPVKit.xcframework wrapper 已放入仓库，但在底层 Libmpv/FFmpeg 依赖补齐前，
        // 不主动 import/link，避免 App 启动时加载不完整动态库导致闪退。
        return false
    }

    func attach(to view: UIView) {
        // 第五步只预留后端结构，不创建真实 MPVKit 渲染层。
    }

    func load(route: PlaybackRoute) {
        let message = "MPVKit wrapper 已放入工程，等待补齐底层依赖后启用"
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
