import SwiftUI
import UIKit

// MARK: - AliPlayer SwiftUI 桥接（运行时动态调用，不依赖编译期 canImport）

struct AliPlayerRepresentable: UIViewRepresentable {
    let url: String
    let headers: [String: String]
    let userAgent: String?
    let referer: String?
    @ObservedObject var playerState: PlayerState
    let onStatusChange: ((AliPlayerStatus) -> Void)?
    let onTimeUpdate: ((Double) -> Void)?
    let onDurationChange: ((Double) -> Void)?
    let onBufferUpdate: ((Double) -> Void)?
    let onError: ((String) -> Void)?
    let onReady: (() -> Void)?
    let onSeekDone: (() -> Void)?

    enum AliPlayerStatus: Int {
        case idle = 0
        case initialized = 1
        case prepared = 2
        case started = 3
        case paused = 4
        case stopped = 5
        case completed = 6
        case error = 7
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIView {
        let containerView = UIView(frame: .zero)
        containerView.backgroundColor = .black
        containerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        guard let player = createAliPlayer() else {
            let label = UILabel()
            label.text = "AliPlayer 不可用"
            label.textColor = .white
            label.textAlignment = .center
            containerView.addSubview(label)
            return containerView
        }

        player.setPlayerView(containerView)

        let config = createAVPConfig()
        config.referer = referer
        config.httpHeaders = headers
        config.networkTimeout = 15000
        config.maxDelayTime = 5000
        config.maxBufferDuration = 30000
        config.highBufferDuration = 3000
        config.startBufferDuration = 500
        config.positionTimerIntervalMs = 250
        player.setConfig(config)

        player.setPictureInPictureEnable(true)

        let source = createAVPUrlSource()
        source.playerUrl = url
        player.setUrlSource(source)

        player.setAutoPlay(false)
        player.setLoop(false)
        player.setRate(1.0)

        player.setDelegate(context.coordinator)

        context.coordinator.player = player
        context.coordinator.containerView = containerView

        DispatchQueue.main.async {
            player.prepare()
        }

        return containerView
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.player?.redraw()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.cleanup()
    }

    // MARK: - Coordinator

    class Coordinator: NSObject {
        let parent: AliPlayerRepresentable
        var player: AliPlayerProxy?
        var containerView: UIView?
        weak var timer: Timer?
        var observers: [NSObjectProtocol] = []

        init(_ parent: AliPlayerRepresentable) {
            self.parent = parent
            super.init()
            setupNotifications()
        }

        func setupNotifications() {
            let center = NotificationCenter.default

            observers.append(center.addObserver(forName: .vboxMPVPlay, object: nil, queue: .main) { [weak self] _ in
                self?.player?.start()
                self?.startTimer()
            })

            observers.append(center.addObserver(forName: .vboxMPVPause, object: nil, queue: .main) { [weak self] _ in
                self?.player?.pause()
                self?.stopTimer()
            })

            observers.append(center.addObserver(forName: .vboxMPVStop, object: nil, queue: .main) { [weak self] _ in
                self?.player?.stop()
                self?.stopTimer()
            })

            observers.append(center.addObserver(forName: .vboxMPVSeek, object: nil, queue: .main) { [weak self] note in
                guard let position = note.userInfo?["position"] as? Double else { return }
                self?.player?.seek(toTime: Int64(position * 1000), seekMode: 1)
            })

            observers.append(center.addObserver(forName: .vboxMPVSpeed, object: nil, queue: .main) { [weak self] note in
                guard let speed = note.userInfo?["speed"] as? Float else { return }
                self?.player?.setRate(speed)
                self?.parent.playerState.playbackSpeed = Double(speed)
            })

            observers.append(center.addObserver(forName: .vboxPiPTogglePlayPause, object: nil, queue: .main) { [weak self] _ in
                guard let player = self?.player else { return }
                if player.playerStatus() == 3 {
                    player.pause()
                } else {
                    player.start()
                }
            })
        }

        func startTimer() {
            stopTimer()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self = self, let player = self.player else { return }
                let pos = Double(player.currentPosition()) / 1000.0
                let dur = Double(player.duration()) / 1000.0
                DispatchQueue.main.async {
                    self.parent.onTimeUpdate?(pos)
                    if dur > 0 {
                        self.parent.onDurationChange?(dur)
                    }
                    let buf = Double(player.bufferedPosition()) / 1000.0
                    self.parent.onBufferUpdate?(buf)
                }
            }
        }

        func stopTimer() {
            timer?.invalidate()
            timer = nil
        }

        func cleanup() {
            stopTimer()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            player?.stop()
            player?.destroy()
            player = nil
        }
    }
}

// MARK: - Runtime Proxy Objects (uses @objc dynamic dispatch, no compile-time import needed)

/// 运行时代理，通过 NSClassFromString 创建 AliPlayer 实例
class AliPlayerProxy: NSObject {
    private let obj: NSObject

    init?() {
        guard let cls = NSClassFromString("AliPlayer") as? NSObject.Type else { return nil }
        self.obj = cls.init()
        super.init()
    }

    func setPlayerView(_ view: UIView) { obj.perform(NSSelectorFromString("setPlayerView:"), with: view) }
    func setConfig(_ config: AVPConfigProxy) { obj.perform(NSSelectorFromString("setConfig:"), with: config.obj) }
    func setPictureInPictureEnable(_ enable: Bool) { obj.perform(NSSelectorFromString("setPictureInPictureEnable:"), with: enable) }
    func setUrlSource(_ source: AVPUrlSourceProxy) { obj.perform(NSSelectorFromString("setUrlSource:"), with: source.obj) }
    func setAutoPlay(_ auto: Bool) { obj.perform(NSSelectorFromString("setAutoPlay:"), with: auto) }
    func setLoop(_ loop: Bool) { obj.perform(NSSelectorFromString("setLoop:"), with: loop) }
    func setRate(_ rate: Float) { obj.perform(NSSelectorFromString("setRate:"), with: rate) }
    func setDelegate(_ delegate: Any?) { obj.perform(NSSelectorFromString("setDelegate:"), with: delegate) }
    func prepare() { obj.perform(NSSelectorFromString("prepare")) }
    func start() { obj.perform(NSSelectorFromString("start")) }
    func pause() { obj.perform(NSSelectorFromString("pause")) }
    func stop() { obj.perform(NSSelectorFromString("stop")) }
    func destroy() { obj.perform(NSSelectorFromString("destroy")) }
    func redraw() { obj.perform(NSSelectorFromString("redraw")) }
    func seek(toTime: Int64, seekMode: Int) {
        let sel = NSSelectorFromString("seekToTime:seekMode:")
        typealias SeekFunc = @convention(c) (NSObject, Selector, Int64, Int) -> Void
        if let imp = obj.method(for: sel) {
            unsafeBitCast(imp, to: SeekFunc.self)(obj, sel, toTime, seekMode)
        }
    }
    func currentPosition() -> Int64 {
        guard let v = obj.value(forKey: "currentPosition") as? NSNumber else { return 0 }
        return v.int64Value
    }
    func duration() -> Int64 {
        guard let v = obj.value(forKey: "duration") as? NSNumber else { return 0 }
        return v.int64Value
    }
    func bufferedPosition() -> Int64 {
        guard let v = obj.value(forKey: "bufferedPosition") as? NSNumber else { return 0 }
        return v.int64Value
    }
    func playerStatus() -> Int {
        let sel = NSSelectorFromString("playerStatus")
        typealias StatusFunc = @convention(c) (NSObject, Selector) -> Int
        if let imp = obj.method(for: sel) {
            return unsafeBitCast(imp, to: StatusFunc.self)(obj, sel)
        }
        return 0
    }

    // 让 Coordinator 能接收 AVPDelegate 回调
    var backing: NSObject { obj }
}

class AVPConfigProxy {
    let obj: NSObject
    init() {
        let cls = NSClassFromString("AVPConfig") as! NSObject.Type
        obj = cls.init()
    }
    var referer: String? {
        get { obj.value(forKey: "referer") as? String }
        set { obj.setValue(newValue, forKey: "referer") }
    }
    var httpHeaders: [String: String]? {
        get { obj.value(forKey: "httpHeaders") as? [String: String] }
        set { obj.setValue(newValue, forKey: "httpHeaders") }
    }
    var networkTimeout: Int {
        get { (obj.value(forKey: "networkTimeout") as? NSNumber)?.intValue ?? 0 }
        set { obj.setValue(NSNumber(value: newValue), forKey: "networkTimeout") }
    }
    var maxDelayTime: Int {
        get { (obj.value(forKey: "maxDelayTime") as? NSNumber)?.intValue ?? 0 }
        set { obj.setValue(NSNumber(value: newValue), forKey: "maxDelayTime") }
    }
    var maxBufferDuration: Int {
        get { (obj.value(forKey: "maxBufferDuration") as? NSNumber)?.intValue ?? 0 }
        set { obj.setValue(NSNumber(value: newValue), forKey: "maxBufferDuration") }
    }
    var highBufferDuration: Int {
        get { (obj.value(forKey: "highBufferDuration") as? NSNumber)?.intValue ?? 0 }
        set { obj.setValue(NSNumber(value: newValue), forKey: "highBufferDuration") }
    }
    var startBufferDuration: Int {
        get { (obj.value(forKey: "startBufferDuration") as? NSNumber)?.intValue ?? 0 }
        set { obj.setValue(NSNumber(value: newValue), forKey: "startBufferDuration") }
    }
    var positionTimerIntervalMs: Int {
        get { (obj.value(forKey: "positionTimerIntervalMs") as? NSNumber)?.intValue ?? 0 }
        set { obj.setValue(NSNumber(value: newValue), forKey: "positionTimerIntervalMs") }
    }
}

class AVPUrlSourceProxy {
    let obj: NSObject
    init() {
        let cls = NSClassFromString("AVPUrlSource") as! NSObject.Type
        obj = cls.init()
    }
    var playerUrl: String? {
        get { obj.value(forKey: "playerUrl") as? String }
        set { obj.setValue(newValue, forKey: "playerUrl") }
    }
}

// Helper to create proxy objects
private func createAliPlayer() -> AliPlayerProxy? {
    return AliPlayerProxy()
}
private func createAVPConfig() -> AVPConfigProxy {
    return AVPConfigProxy()
}
private func createAVPUrlSource() -> AVPUrlSourceProxy {
    return AVPUrlSourceProxy()
}

private func log(_ msg: String) {
    NSLog("[AliPlayerRepresentable] \(msg)")
}