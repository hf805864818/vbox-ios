import UIKit

/// MPV 后端协议。MPVKit 和 libmpv 都必须通过这一层适配，避免 UI/Controller 直接依赖第三方 API。
protocol MPVBackend: AnyObject {
    var backendType: MPVBackendType { get }
    var name: String { get }
    var state: PlayerEngineState { get }
    var onEvent: ((PlayerEngineEvent) -> Void)? { get set }

    func attach(to view: UIView)
    func load(route: PlaybackRoute)
    func play()
    func pause()
    func stop()
    func seek(to seconds: Double)
    func setRate(_ rate: Double)
    func setVolume(_ volume: Double)
    func teardown()
}
