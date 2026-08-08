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

    // 持有当前活跃的 Coordinator，以便外部（如画中画按钮）能操作 AliPlayer
    static weak var currentCoordinator: Coordinator?

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
        containerView.tag = 9527  // 播放器视图标识，用于 findCurrentPlayerView 查找
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
        player.setPictureinPictureDelegate(context.coordinator)

        let source = AVPUrlSourceProxy(urlString: url)
        player.setUrlSource(source)

        player.setAutoPlay(false)
        player.setLoop(false)
        player.setRate(1.0)

        player.setDelegate(context.coordinator)

        context.coordinator.player = player
        context.coordinator.containerView = containerView
        Self.currentCoordinator = context.coordinator

        DispatchQueue.main.async {
            player.prepare()
            context.coordinator.applyVideoGravity(self.playerState.videoGravity)
        }

        return containerView
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.player?.redraw()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if Self.currentCoordinator === coordinator {
            Self.currentCoordinator = nil
        }
        coordinator.cleanup()
    }

    /// 尝试让当前 AliPlayer 进入原生系统画中画
    @discardableResult
    static func enterPictureInPicture() -> Bool {
        guard let coordinator = currentCoordinator, let player = coordinator.player else {
            log("[PiP] 没有可用的 AliPlayer 实例")
            return false
        }
        return player.enterPictureInPicture()
    }

    /// 尝试让当前 AliPlayer 退出原生系统画中画
    @discardableResult
    static func exitPictureInPicture() -> Bool {
        guard let coordinator = currentCoordinator, let player = coordinator.player else {
            return false
        }
        return player.exitPictureInPicture()
    }

    // MARK: - Coordinator

    class Coordinator: NSObject {
        let parent: AliPlayerRepresentable
        var player: AliPlayerProxy?
        var containerView: UIView?
        weak var timer: Timer?
        var observers: [NSObjectProtocol] = []
        private var didFinish = false

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

            observers.append(center.addObserver(forName: .vboxVideoGravityChanged, object: nil, queue: .main) { [weak self] note in
                guard let mode = note.userInfo?["mode"] as? PlayerState.VideoGravityMode else { return }
                self?.applyVideoGravity(mode)
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

        func applyVideoGravity(_ mode: PlayerState.VideoGravityMode) {
            guard let player = player else { return }
            // AliPlayer scalingMode: 0=aspectFit, 1=aspectFill, 2=fill
            switch mode {
            case .aspectFill:
                player.setScalingMode(1)
            case .aspectFit:
                player.setScalingMode(0)
            case .resize:
                player.setScalingMode(2)
            }
        }

        func startTimer() {
            stopTimer()
            didFinish = false
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self = self, let player = self.player else { return }
                let pos = Double(player.currentPosition()) / 1000.0
                let dur = Double(player.duration()) / 1000.0
                DispatchQueue.main.async {
                    let playerState = self.parent.playerState
                    self.parent.onTimeUpdate?(pos)
                    if dur > 0 {
                        self.parent.onDurationChange?(dur)
                    }
                    let buf = Double(player.bufferedPosition()) / 1000.0
                    self.parent.onBufferUpdate?(buf)

                    // 跳过片头：AliPlayer 首次播放且进度极小
                    if playerState.skipIntroEnabled, playerState.skipIntroSeconds > 0,
                       !playerState.skipIntroTriggered, !playerState.isSwitchingEpisode,
                       pos < 2, dur > Double(playerState.skipIntroSeconds) {
                        playerState.skipIntroTriggered = true
                        let skipMs = Int64(playerState.skipIntroSeconds * 1000)
                        playerState.log("[PlayerV2] ⏩ AliPlayer 跳过片头 \(playerState.formatDuration(Double(playerState.skipIntroSeconds)))")
                        player.seek(toTime: skipMs, seekMode: 1)
                    }

                    // 跳过片尾：接近结尾时自动播放下一集
                    if playerState.skipOutroEnabled, playerState.skipOutroSeconds > 0,
                       !playerState.skipOutroTriggered, !playerState.isSwitchingEpisode,
                       dur > 0, pos > 0,
                       pos >= dur - Double(playerState.skipOutroSeconds) {
                        playerState.skipOutroTriggered = true
                        playerState.log("[PlayerV2] ⏩ AliPlayer 跳过片尾 \(playerState.formatDuration(Double(playerState.skipOutroSeconds)))，自动播放下一集")
                        playerState.playNextEpisode()
                    }

                    // 播放结束：自然播放到末尾
                    if !self.didFinish, dur > 1, pos >= max(0, dur - 0.8) {
                        self.didFinish = true
                        playerState.isPlaying = false
                        playerState.log("[PlayerV2] AliPlayer 播放结束")
                        if !playerState.isSwitchingEpisode {
                            playerState.playNextEpisodeIfAvailable()
                        }
                    }
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

        // MARK: - PiP Delegate (runtime selectors, called by AliPlayer internally)

        @objc func pictureInPictureControllerWillStartPictureInPicture(_ controller: Any) {
            log("[PiP] will start")
        }

        @objc func pictureInPictureControllerDidStartPictureInPicture(_ controller: Any) {
            log("[PiP] did start")
            DispatchQueue.main.async {
                self.parent.playerState.isPiPActive = true
                NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: nil)
            }
        }

        @objc func pictureInPictureControllerWillStopPictureInPicture(_ controller: Any) {
            log("[PiP] will stop")
        }

        @objc func pictureInPictureControllerDidStopPictureInPicture(_ controller: Any) {
            log("[PiP] did stop")
            DispatchQueue.main.async {
                self.parent.playerState.isPiPActive = false
                NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: nil)
            }
        }

        @objc func pictureInPictureController(_ controller: Any, failedToStartPictureInPictureWithError error: Error) {
            log("[PiP] failed: \(error.localizedDescription)")
        }

        @objc func pictureInPictureController(_ controller: Any, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            log("[PiP] restore UI")
            completionHandler(true)
        }
    }
}

// MARK: - Runtime Proxy Objects (uses @objc dynamic dispatch, no compile-time import needed)

/// 运行时代理，通过 NSClassFromString 创建 AliPlayer 实例
class AliPlayerProxy: NSObject {
    private let obj: NSObject

    override init() {
        guard let cls = NSClassFromString("AliPlayer") as? NSObject.Type else {
            fatalError("AliPlayer not available")
        }
        self.obj = cls.init()
        super.init()
    }

    static func create() -> AliPlayerProxy? {
        guard NSClassFromString("AliPlayer") != nil else { return nil }
        return AliPlayerProxy()
    }

    func setPlayerView(_ view: UIView) { obj.perform(NSSelectorFromString("setPlayerView:"), with: view) }
    func setConfig(_ config: AVPConfigProxy) { obj.perform(NSSelectorFromString("setConfig:"), with: config.obj) }
    func setPictureInPictureEnable(_ enable: Bool) { obj.perform(NSSelectorFromString("setPictureInPictureEnable:"), with: enable) }
    func setPictureinPictureDelegate(_ delegate: Any?) { obj.perform(NSSelectorFromString("setPictureinPictureDelegate:"), with: delegate) }
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
    func setScalingMode(_ mode: Int) {
        let sel = NSSelectorFromString("setScalingMode:")
        typealias ScalingFunc = @convention(c) (NSObject, Selector, Int) -> Void
        if let imp = obj.method(for: sel) {
            unsafeBitCast(imp, to: ScalingFunc.self)(obj, sel, mode)
        }
    }
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

    /// 运行时尝试调用 AliPlayer 原生画中画进入方法（不同 SDK 版本方法名可能不同）
    @discardableResult
    func enterPictureInPicture() -> Bool {
        let candidates = ["startPictureInPicture", "enterPictureInPicture", "startPiP"]
        for name in candidates {
            let sel = NSSelectorFromString(name)
            if obj.responds(to: sel) {
                obj.perform(sel)
                log("[PiP] 调用 AliPlayer.\(name) 进入原生画中画")
                return true
            }
        }
        log("[PiP] ⚠️ 当前 AliPlayer SDK 未暴露进入画中画方法")
        return false
    }

    /// 运行时尝试调用 AliPlayer 原生画中画退出方法
    @discardableResult
    func exitPictureInPicture() -> Bool {
        let candidates = ["stopPictureInPicture", "exitPictureInPicture", "stopPiP"]
        for name in candidates {
            let sel = NSSelectorFromString(name)
            if obj.responds(to: sel) {
                obj.perform(sel)
                return true
            }
        }
        return false
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
    init(urlString: String? = nil) {
        let cls = NSClassFromString("AVPUrlSource") as! NSObject.Type
        // 优先使用 SDK 提供的工厂方法，避免直接 init 后属性类型不匹配导致 AliPlayer 内部崩溃
        if let urlString = urlString,
           cls.responds(to: NSSelectorFromString("urlWithString:")),
           let result = cls.perform(NSSelectorFromString("urlWithString:"), with: urlString)?.takeUnretainedValue() as? NSObject {
            obj = result
        } else {
            obj = cls.init()
        }
    }
    var playerUrl: String? {
        get {
            // 部分 SDK 版本内部把 playerUrl 当作 NSURL 使用
            if let url = obj.value(forKey: "playerUrl") as? URL {
                return url.absoluteString
            }
            return obj.value(forKey: "playerUrl") as? String
        }
        set {
            // 崩溃日志显示 AliPlayer 内部可能对 playerUrl 调用 absoluteString，因此优先存为 URL
            if let newValue {
                obj.setValue(URL(string: newValue), forKey: "playerUrl")
            } else {
                obj.setValue(nil, forKey: "playerUrl")
            }
        }
    }
}

// Helper to create proxy objects
private func createAliPlayer() -> AliPlayerProxy? {
    return AliPlayerProxy.create()
}
private func createAVPConfig() -> AVPConfigProxy {
    return AVPConfigProxy()
}

private func log(_ msg: String) {
    NSLog("[AliPlayerRepresentable] \(msg)")
}