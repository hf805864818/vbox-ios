import UIKit

/// MPV 不可用占位后端。
/// 真实 MPVKit/libmpv framework 未接入时，用它返回明确错误。
final class MPVUnavailableBackend: MPVBackend {
    let backendType: MPVBackendType
    let name: String
    private(set) var state = PlayerEngineState()
    var onEvent: ((PlayerEngineEvent) -> Void)?

    init(backendType: MPVBackendType, name: String? = nil) {
        self.backendType = backendType
        self.name = name ?? backendType.displayName
    }

    func attach(to view: UIView) {}

    func load(route: PlaybackRoute) {
        let message = MPVIntegrationStatus.disabledReason(for: backendType)
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
