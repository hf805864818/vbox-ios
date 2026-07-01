import SwiftUI
import UIKit
#if canImport(AliyunPlayer)
import AliyunPlayer

// MARK: - AliPlayer SwiftUI 桥接

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

        let player = AliPlayer()
        player.setPlayerView(containerView)

        // 配置
        let config = AVPConfig()
        config.referer = referer
        config.httpHeaders = headers
        config.networkTimeout = 15000
        config.maxDelayTime = 5000
        config.maxBufferDuration = 30000
        config.highBufferDuration = 3000
        config.startBufferDuration = 500
        config.positionTimerIntervalMs = 250
        player.setConfig(config)

        // 启用画中画
        player.setPictureInPictureEnable(true)

        // 设置 URL 源
        let source = AVPUrlSource()
        source.playerUrl = url
        player.setUrlSource(source)

        player.setAutoPlay(false)
        player.setLoop(false)
        player.setRate(1.0)

        player.setDelegate(context.coordinator)

        context.coordinator.player = player
        context.coordinator.containerView = containerView

        // 延迟 prepare，等 view 布局完成
        DispatchQueue.main.async {
            player.prepare()
        }

        return containerView
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // 尺寸变化时重绘
        context.coordinator.player?.redraw()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.cleanup()
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, AVPDelegate, AliPlayerPictureInPictureDelegate {
        let parent: AliPlayerRepresentable
        var player: AliPlayer?
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

            // 播放
            observers.append(center.addObserver(forName: .vboxMPVPlay, object: nil, queue: .main) { [weak self] _ in
                self?.player?.start()
                self?.startTimer()
            })

            // 暂停
            observers.append(center.addObserver(forName: .vboxMPVPause, object: nil, queue: .main) { [weak self] _ in
                self?.player?.pause()
                self?.stopTimer()
            })

            // 停止
            observers.append(center.addObserver(forName: .vboxMPVStop, object: nil, queue: .main) { [weak self] _ in
                self?.player?.stop()
                self?.stopTimer()
            })

            // 跳转
            observers.append(center.addObserver(forName: .vboxMPVSeek, object: nil, queue: .main) { [weak self] note in
                guard let position = note.userInfo?["position"] as? Double else { return }
                self?.player?.seek(toTime: Int64(position * 1000), seekMode: 1)
            })

            // 倍速
            observers.append(center.addObserver(forName: .vboxMPVSpeed, object: nil, queue: .main) { [weak self] note in
                guard let speed = note.userInfo?["speed"] as? Float else { return }
                self?.player?.setRate(speed)
                self?.parent.playerState.playbackSpeed = Double(speed)
            })

            // 画中画切换播放/暂停
            observers.append(center.addObserver(forName: .vboxPiPTogglePlayPause, object: nil, queue: .main) { [weak self] _ in
                guard let player = self?.player else { return }
                if player.playerStatus == 3 {
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

        // MARK: - AVPDelegate

        func onPlayerEvent(_ player: Any, eventCode: Int) {
            switch eventCode {
            case 0: // PrepareDone
                self.player?.start()
                startTimer()
                DispatchQueue.main.async { self.parent.onReady?() }
            case 1: // AutoPlayStart
                startTimer()
            case 2: // SeekingEnd
                DispatchQueue.main.async { self.parent.onSeekDone?() }
            case 3: // EOF / Completion
                stopTimer()
                DispatchQueue.main.async {
                    self.parent.playerState.isPlaying = false
                }
            default:
                break
            }
        }

        func onPlayerEvent(_ player: Any, eventWith eventStr: String, description: String) {
            // 备用事件回调
        }

        func onError(_ player: Any, errorModel: AVPErrorModel) {
            stopTimer()
            DispatchQueue.main.async {
                self.parent.onError?(errorModel.message ?? "Unknown error")
            }
        }

        func onPlayerStatusChanged(_ player: Any, oldStatus: Int, newStatus: Int) {
            DispatchQueue.main.async {
                self.parent.playerState.isPlaying = (newStatus == 3) // started
                self.parent.onStatusChange?(AliPlayerStatus(rawValue: newStatus) ?? .idle)
            }
        }

        func onVideoSizeChanged(_ player: Any, width: Int, height: Int) {
            // 视频尺寸变化
        }

        func onSeekDone(_ player: Any) {
            DispatchQueue.main.async { self.parent.onSeekDone?() }
        }

        // MARK: - AliPlayerPictureInPictureDelegate

        func pictureInPictureControllerWillStartPicture(inPicture controller: Any) {
            log("[AliPlayer] PiP will start")
        }

        func pictureInPictureControllerDidStartPicture(inPicture controller: Any) {
            log("[AliPlayer] PiP did start")
            DispatchQueue.main.async {
                self.parent.playerState.isPiPActive = true
                NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: nil)
            }
        }

        func pictureInPictureControllerWillStopPicture(inPicture controller: Any) {
            log("[AliPlayer] PiP will stop")
        }

        func pictureInPictureControllerDidStopPicture(inPicture controller: Any) {
            log("[AliPlayer] PiP did stop")
            DispatchQueue.main.async {
                self.parent.playerState.isPiPActive = false
                NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: nil)
            }
        }

        func picture(inPictureController controller: Any, failedToStartPictureInPictureWithError error: any Error) {
            log("[AliPlayer] PiP failed: \(error.localizedDescription)")
        }

        func picture(inPictureController controller: Any, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            completionHandler(true)
        }
    }
}

private func log(_ msg: String) {
    NSLog("[AliPlayerRepresentable] \(msg)")
}

#endif