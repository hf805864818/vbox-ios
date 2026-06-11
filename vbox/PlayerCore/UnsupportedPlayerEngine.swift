import UIKit

/// 尚未接入 PlayerCore 的内核占位实现。
/// 例如 VLC 真实封装完成前，Controller 可以用它返回明确错误而不是崩溃。
final class UnsupportedPlayerEngine: PlayerEngine {
    let type: PlayerEngineType
    let name: String
    private(set) var state = PlayerEngineState()
    var onEvent: ((PlayerEngineEvent) -> Void)?

    init(type: PlayerEngineType, name: String) {
        self.type = type
        self.name = name
    }

    func attach(to view: UIView) {}

    func load(route: PlaybackRoute) {
        let message = "\(name) 内核尚未接入 PlayerCore"
        state.errorMessage = message
        onEvent?(.failed(message))
    }

    func play() {}

    func pause() {}

    func stop() {}

    func seek(to seconds: Double) {}

    func setRate(_ rate: Double) {}

    func setVolume(_ volume: Double) {}

    func teardown() {}
}
