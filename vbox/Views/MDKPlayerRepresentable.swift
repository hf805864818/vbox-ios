import SwiftUI
import UIKit
import AVFoundation

// MARK: - MDK 画中画请求通知

extension Notification.Name {
    /// 请求当前 MDK 播放器启动画中画并进入后台小窗
    static let vboxMDKRequestStartPiP = Notification.Name("vbox.mdk.requestStartPiP")
    /// 请求当前 MDK 播放器停止画中画
    static let vboxMDKRequestStopPiP = Notification.Name("vbox.mdk.requestStopPiP")
    // MDK 播放控制通知（seek/play/pause/speed），用于百度网盘等走 MDK 兼容内核的场景
    static let vboxMDKPlay = Notification.Name("vbox.mdk.play")
    static let vboxMDKPause = Notification.Name("vbox.mdk.pause")
    static let vboxMDKSeek = Notification.Name("vbox.mdk.seek")
    static let vboxMDKSpeed = Notification.Name("vbox.mdk.speed")
}

// MARK: - SwiftUI Representable

#if canImport(swift_mdk)
struct MDKPlayerRepresentable: UIViewRepresentable {
    let url: URL
    let headers: [String: String]
    @ObservedObject var playerState: PlayerState

    func makeCoordinator() -> Coordinator {
        Coordinator(playerState: playerState)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        context.coordinator.attach(to: view, url: url, headers: headers)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if context.coordinator.currentURL != url {
            context.coordinator.attach(to: uiView, url: url, headers: headers)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    // MARK: - Coordinator

    final class Coordinator {
        private let engine = MDKPlayerEngine()
        private var observers: [NSObjectProtocol] = []
        private weak var playerState: PlayerState?
        private var isStopped = false
        var currentURL: URL?

        init(playerState: PlayerState) {
            self.playerState = playerState

            engine.onEvent = { [weak self] event in
                guard let self, let playerState = self.playerState else { return }
                // MDK 回调来自内部解码线程，所有 @Published 属性更新必须切到主线程，
                // 否则 SwiftUI 会忽略更新（如 isLoading 永远不会被清除）。
                let engine = self.engine
                DispatchQueue.main.async {
                    switch event {
                    case .ready:
                        playerState.isLoading = false
                        playerState.loadError = nil
                    case .buffering(let buffering):
                        playerState.isLoading = buffering
                    case .progress(let current, let duration):
                        playerState.currentTime = current
                        if duration.isFinite, duration > 0 {
                            playerState.duration = duration
                        }
                        playerState.updateDanmaku(at: current)
                        playerState.savePlaybackProgress()
                        playerState.reportBaiduCacheProgressIfNeeded()

                        // 跳过片头：MDK 首次播放且进度极小
                        if playerState.skipIntroEnabled, playerState.skipIntroSeconds > 0,
                           !playerState.skipIntroTriggered, !playerState.isSwitchingEpisode,
                           current < 2, duration > Double(playerState.skipIntroSeconds) {
                            playerState.skipIntroTriggered = true
                            let skip = Double(playerState.skipIntroSeconds)
                            playerState.log("[PlayerV2] ⏩ MDK 跳过片头 \(playerState.formatDuration(skip))")
                            engine.seek(to: skip)
                        }

                        // 跳过片尾：接近结尾时自动播放下一集
                        if playerState.skipOutroEnabled, playerState.skipOutroSeconds > 0,
                           !playerState.skipOutroTriggered, !playerState.isSwitchingEpisode,
                           duration > 0, current > 0,
                           current >= duration - Double(playerState.skipOutroSeconds) {
                            playerState.skipOutroTriggered = true
                            playerState.log("[PlayerV2] ⏩ MDK 跳过片尾 \(playerState.formatDuration(Double(playerState.skipOutroSeconds)))，自动播放下一集")
                            playerState.playNextEpisode()
                        }
                    case .ended:
                        playerState.isPlaying = false
                        if !playerState.isSwitchingEpisode {
                            playerState.log("[PlayerV2] MDK 播放结束")
                            playerState.playNextEpisodeIfAvailable()
                        }
                    case .failed(let msg):
                        playerState.loadError = "[MDK] \(msg)"
                    case .log(let msg):
                        playerState.log("[MDK] \(msg)")
                    }
                    playerState.isPlaying = engine.state.isPlaying
                }
            }

            // 来自 PlayerViewsV2 的 PiP 启动请求
            observers.append(NotificationCenter.default.addObserver(
                forName: .vboxMDKRequestStartPiP,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.engine.startPiP()
            })

            // 来自 PlayerViewsV2 的 PiP 停止请求
            observers.append(NotificationCenter.default.addObserver(
                forName: .vboxMDKRequestStopPiP,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.engine.stopPiP()
            })

            // === 新增: MDK seek/play/pause/speed 通知监听 ===
            // 之前 MDK 引擎缺少这些通知路由，导致百度网盘拖拽进度条时不跳转：
            // compatibilityEngineName="MDK" 不含 "MPV"，seek 通知被错误发往 VLC。
            observers.append(NotificationCenter.default.addObserver(
                forName: .vboxMDKSeek,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let seconds = note.userInfo?["seconds"] as? Double else { return }
                self?.engine.seek(to: seconds)
            })

            observers.append(NotificationCenter.default.addObserver(
                forName: .vboxMDKPlay,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.engine.play()
            })

            observers.append(NotificationCenter.default.addObserver(
                forName: .vboxMDKPause,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.engine.pause()
            })

            observers.append(NotificationCenter.default.addObserver(
                forName: .vboxMDKSpeed,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let speed = note.userInfo?["speed"] as? Double else { return }
                self?.engine.setRate(speed)
            })
        }

        deinit {
            stop()
        }

        func attach(to view: UIView, url: URL, headers: [String: String]) {
            guard !isStopped else { return }
            currentURL = url

            let episodeTitle = playerState.flatMap { state in
                state.episodeItems.indices.contains(state.currentEpisodeIndex)
                    ? state.episodeItems[state.currentEpisodeIndex].name
                    : nil
            } ?? url.absoluteString
            let route = PlaybackRoute(
                type: .localProxy,
                url: url,
                headers: headers,
                title: episodeTitle,
                priority: 0
            )

            engine.attach(to: view)
            // 同步当前画面拉伸模式，避免新建的渲染视图使用默认值 .aspectFill
            if let mode = playerState?.videoGravity {
                engine.syncVideoGravity(mode)
            }
            engine.load(route: route)
            engine.setRate(playerState?.playbackSpeed ?? 1.0)
            engine.play()

            if let resume = playerState?.currentTime, resume > 10 {
                engine.seek(to: resume)
                playerState?.log("[Progress] MDK 自动跳转到上次进度：\(Int(resume))s")
            }

            playerState?.isLoading = true
            playerState?.loadingMessage = "正在启动 MDK..."
        }

        func stop() {
            guard !isStopped else { return }
            isStopped = true
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            engine.teardown()
            currentURL = nil
            playerState = nil
        }
    }
}
#endif
