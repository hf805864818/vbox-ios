import Combine
import UIKit

/// 播放器统一控制层。
/// 当前只作为 PlayerCore 架构能力存在，不接管现有 PlayerViewsV2 播放流程。
@MainActor
final class PlayerEngineController: ObservableObject {
    @Published private(set) var currentEngineType: PlayerEngineType
    @Published private(set) var currentRoute: PlaybackRoute?
    @Published private(set) var state: PlayerEngineState
    @Published private(set) var lastEvent: PlayerEngineEvent?
    @Published private(set) var logs: [String]

    private var currentEngine: PlayerEngine
    private weak var renderView: UIView?

    init(initialEngineType: PlayerEngineType = .system) {
        self.currentEngineType = initialEngineType
        self.currentEngine = Self.makeEngine(initialEngineType)
        self.currentRoute = nil
        self.state = currentEngine.state
        self.lastEvent = nil
        self.logs = []
        bindEngineEvents()
    }

    func attach(to view: UIView) {
        renderView = view
        currentEngine.attach(to: view)
        appendLog("已绑定渲染容器：\(currentEngine.name)")
    }

    func load(route: PlaybackRoute, preferredEngine: PlayerEngineType? = nil) {
        if let preferredEngine, preferredEngine != currentEngineType {
            switchEngine(preferredEngine, reloadCurrentRoute: false)
        }

        currentRoute = route
        appendLog("加载线路：\(route.title)，内核：\(currentEngine.name)")
        currentEngine.load(route: route)
        state = currentEngine.state
    }

    func play() {
        currentEngine.play()
        state = currentEngine.state
    }

    func pause() {
        currentEngine.pause()
        state = currentEngine.state
    }

    func stop() {
        currentEngine.stop()
        state = currentEngine.state
    }

    func seek(to seconds: Double) {
        currentEngine.seek(to: seconds)
        state = currentEngine.state
    }

    func setRate(_ rate: Double) {
        currentEngine.setRate(rate)
    }

    func setVolume(_ volume: Double) {
        currentEngine.setVolume(volume)
    }

    func switchEngine(_ type: PlayerEngineType) {
        switchEngine(type, reloadCurrentRoute: true)
    }

    func teardown() {
        currentEngine.teardown()
        currentRoute = nil
        state = PlayerEngineState()
        lastEvent = nil
        appendLog("播放器控制层已释放")
    }

    private func switchEngine(_ type: PlayerEngineType, reloadCurrentRoute: Bool) {
        guard type != currentEngineType else { return }

        let routeToReload = reloadCurrentRoute ? currentRoute : nil
        currentEngine.teardown()
        currentEngine = Self.makeEngine(type)
        currentEngineType = type
        bindEngineEvents()

        if let renderView {
            currentEngine.attach(to: renderView)
        }

        appendLog("切换内核：\(currentEngine.name)")

        if let routeToReload {
            currentEngine.load(route: routeToReload)
            state = currentEngine.state
        } else {
            state = currentEngine.state
        }
    }

    private func bindEngineEvents() {
        currentEngine.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: PlayerEngineEvent) {
        lastEvent = event
        state = currentEngine.state

        switch event {
        case .ready:
            appendLog("内核就绪：\(currentEngine.name)")
        case .buffering(let buffering):
            appendLog(buffering ? "开始缓冲" : "缓冲结束")
        case .progress:
            break
        case .ended:
            appendLog("播放结束")
        case .failed(let message):
            appendLog("播放失败：\(message)")
        case .log(let message):
            appendLog(message)
        }
    }

    private func appendLog(_ message: String) {
        logs.append(message)
        if logs.count > 80 {
            logs.removeFirst(logs.count - 80)
        }
    }

    private static func makeEngine(_ type: PlayerEngineType) -> PlayerEngine {
        switch type {
        case .system:
            return AVPlayerEngine()
        case .vlc:
            return UnsupportedPlayerEngine(type: .vlc, name: "VLC")
        case .mpv:
            return MPVPlayerEngineStub()
        }
    }
}
