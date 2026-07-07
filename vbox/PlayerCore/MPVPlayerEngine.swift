import UIKit

/// MPV 统一播放器内核。
/// 上层只依赖 MPVPlayerEngine，底层可在 MPVKit 和 libmpv 两种后端之间切换。
final class MPVPlayerEngine: PlayerEngine {
    let type: PlayerEngineType
    let backendType: MPVBackendType
    var name: String { backend.name }
    var state: PlayerEngineState { backend.state }
    var onEvent: ((PlayerEngineEvent) -> Void)? {
        didSet {
            backend.onEvent = onEvent
        }
    }

    private let backend: MPVBackend

    init(backendType: MPVBackendType = .automatic) {
        self.backendType = backendType
        switch backendType {
        case .automatic, .mpvKit:
            self.type = .mpvKit
        case .libmpv:
            self.type = .libmpv
        }
        self.backend = MPVBackendFactory.makeBackend(backendType)
    }

    func attach(to view: UIView) {
        backend.attach(to: view)
    }

    func load(route: PlaybackRoute) {
        backend.load(route: route)
    }

    func play() {
        backend.play()
    }

    func pause() {
        backend.pause()
    }

    func stop() {
        backend.stop()
    }

    func seek(to seconds: Double) {
        backend.seek(to: seconds)
    }

    func setRate(_ rate: Double) {
        backend.setRate(rate)
    }

    func setVolume(_ volume: Double) {
        backend.setVolume(volume)
    }

    func teardown() {
        backend.teardown()
    }
}
