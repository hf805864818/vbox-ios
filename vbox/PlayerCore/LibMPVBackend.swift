import UIKit

#if canImport(Libmpv)
import Libmpv
#endif

/// libmpv 后端占位，UI 显示为“自由度”。
/// 后续接入 Libmpv.xcframework 时，只在这个文件里适配底层 libmpv API。
final class LibMPVBackend: MPVBackend {
    let backendType: MPVBackendType = .libmpv
    let name = "自由度"
    private(set) var state = PlayerEngineState()
    var onEvent: ((PlayerEngineEvent) -> Void)?

    static var isAvailable: Bool {
        #if canImport(Libmpv)
        return MPVIntegrationStatus.isFrameworkLinked(for: .libmpv)
        #else
        return false
        #endif
    }

    func attach(to view: UIView) {
        // 当前只预留后端结构，不创建真实 libmpv 渲染层。
    }

    func load(route: PlaybackRoute) {
        let message = MPVIntegrationStatus.disabledReason(for: .libmpv)
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
