import UIKit

/// MPV 占位内核。
/// 当前构建还没有接入 libmpv/MPVKit 时，保留类型和接口，避免后续 UI/控制层重构时反复改结构。
final class MPVPlayerEngineStub: PlayerEngine {
    let type: PlayerEngineType = .mpv
    let name = "MPV"
    private(set) var state = PlayerEngineState()
    var onEvent: ((PlayerEngineEvent) -> Void)?

    func attach(to view: UIView) {
        // 第一阶段只做占位，不创建真实渲染层。
    }

    func load(route: PlaybackRoute) {
        state.errorMessage = "当前构建未包含 MPV 内核"
        onEvent?(.failed("当前构建未包含 MPV 内核"))
    }

    func play() {}

    func pause() {}

    func stop() {}

    func seek(to seconds: Double) {}

    func setRate(_ rate: Double) {}

    func setVolume(_ volume: Double) {}

    func teardown() {}
}
