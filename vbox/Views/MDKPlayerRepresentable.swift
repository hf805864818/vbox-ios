import SwiftUI
import UIKit
import AVFoundation

// MARK: - MDK 画中画请求通知

extension Notification.Name {
    /// 请求当前 MDK 播放器启动画中画并进入后台小窗
    static let vboxMDKRequestStartPiP = Notification.Name("vbox.mdk.requestStartPiP")
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
                case .ended:
                    playerState.isPlaying = false
                case .failed(let msg):
                    playerState.loadError = "[MDK] \(msg)"
                case .log(let msg):
                    playerState.log("[MDK] \(msg)")
                }
                playerState.isPlaying = self.engine.state.isPlaying
            }

            // 来自 PlayerViewsV2 的 PiP 启动请求
            observers.append(NotificationCenter.default.addObserver(
                forName: .vboxMDKRequestStartPiP,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.engine.startPiP()
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
