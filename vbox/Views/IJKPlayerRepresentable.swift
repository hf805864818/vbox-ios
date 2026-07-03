import SwiftUI
import UIKit

#if canImport(IJKMediaFrameworkWithSSL)
import IJKMediaFrameworkWithSSL

// MARK: - IJKPlayer SwiftUI 桥接

struct IJKPlayerRepresentable: UIViewRepresentable {
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
        private var player: IJKFFMoviePlayerController?
        private var observers: [NSObjectProtocol] = []
        private var progressTimer: Timer?
        private weak var playerState: PlayerState?
        private var isStopped = false
        var currentURL: URL?

        init(playerState: PlayerState) {
            self.playerState = playerState
            observers.append(NotificationCenter.default.addObserver(
                forName: .vboxVideoGravityChanged,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let mode = note.userInfo?["mode"] as? PlayerState.VideoGravityMode else { return }
                self?.applyVideoGravity(mode)
            })
        }

        deinit {
            stop()
        }

        private func applyVideoGravity(_ mode: PlayerState.VideoGravityMode) {
            guard let player = player else { return }
            switch mode {
            case .aspectFill:
                player.scalingMode = .aspectFill
            case .aspectFit:
                player.scalingMode = .aspectFit
            case .resize:
                player.scalingMode = .fill
            }
        }

        func attach(to view: UIView, url: URL, headers: [String: String]) {
            guard !isStopped else { return }
            stopPlayer()
            currentURL = url

            let options = IJKFFOptions.byDefault()

            // 设置 HTTP headers
            if !headers.isEmpty {
                let headerLines = headers.map { "\($0.key): \($0.value)" }
                let headerValue = headerLines.joined(separator: "\r\n")
                options?.setOptionValue(headerValue, forKey: "headers", of: kIJKFFOptionCategoryFormat)
            }

            // 允许重定向、缓存清理等
            options?.setOptionIntValue(1, forKey: "dns_cache_clear", of: kIJKFFOptionCategoryFormat)
            options?.setOptionIntValue(1, forKey: "reconnect", of: kIJKFFOptionCategoryFormat)
            options?.setOptionIntValue(1, forKey: "timeout", of: kIJKFFOptionCategoryFormat)

            let player = IJKFFMoviePlayerController(contentURL: url, with: options)
            self.player = player

            if let playerView = player?.view {
                playerView.translatesAutoresizingMaskIntoConstraints = false
                playerView.backgroundColor = .black
                view.subviews.forEach { $0.removeFromSuperview() }
                view.addSubview(playerView)
                NSLayoutConstraint.activate([
                    playerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    playerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    playerView.topAnchor.constraint(equalTo: view.topAnchor),
                    playerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
                ])
            }

            setupObservers()
            setupControlObservers()
            startProgressTimer()

            player?.prepareToPlay()
            applyVideoGravity(playerState?.videoGravity ?? .aspectFill)

            playerState?.isLoading = true
            playerState?.loadingMessage = "正在启动 IJKPlayer..."
        }

        func stop() {
            guard !isStopped else { return }
            isStopped = true
            stopPlayer()
            playerState = nil
        }

        private func stopPlayer() {
            progressTimer?.invalidate()
            progressTimer = nil
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            player?.stop()
            player?.view.removeFromSuperview()
            player?.shutdown()
            player = nil
            currentURL = nil
        }

        // MARK: 播放状态监听

        private func setupObservers() {
            guard let player = player else { return }

            observers.append(NotificationCenter.default.addObserver(
                forName: NSNotification.Name.IJKMPMoviePlayerPlaybackStateDidChange,
                object: player,
                queue: .main
            ) { [weak self] _ in
                self?.handlePlaybackState()
            })

            observers.append(NotificationCenter.default.addObserver(
                forName: NSNotification.Name.IJKMPMoviePlayerPlaybackDidFinish,
                object: player,
                queue: .main
            ) { [weak self] _ in
                self?.playerState?.isPlaying = false
                self?.playerState?.isLoading = false
            })

            observers.append(NotificationCenter.default.addObserver(
                forName: NSNotification.Name.IJKMPMoviePlayerLoadStateDidChange,
                object: player,
                queue: .main
            ) { [weak self] _ in
                self?.handleLoadState()
            })
        }

        // MARK: 外部控制监听（共用 MPV 通知）

        private func setupControlObservers() {
            observers.append(NotificationCenter.default.addObserver(
                forName: .vboxMPVPlay,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.player?.play()
            })

            observers.append(NotificationCenter.default.addObserver(
                forName: .vboxMPVPause,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.player?.pause()
            })

            observers.append(NotificationCenter.default.addObserver(
                forName: .vboxMPVSeek,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let time = note.userInfo?["time"] as? Double ?? note.userInfo?["seconds"] as? Double
                guard let time = time else { return }
                self?.player?.currentPlaybackTime = TimeInterval(time)
            })

            observers.append(NotificationCenter.default.addObserver(
                forName: .vboxMPVSpeed,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let speed = note.userInfo?["speed"] as? Double else { return }
                self?.playerState?.playbackSpeed = speed
                // ijkplayer 播放中动态修改播放速度有限制，先记录到状态
            })

            observers.append(NotificationCenter.default.addObserver(
                forName: .vboxPiPTogglePlayPause,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self = self, let player = self.player else { return }
                if player.isPlaying() {
                    player.pause()
                } else {
                    player.play()
                }
            })
        }

        // MARK: 状态处理

        private func handlePlaybackState() {
            guard let player = player, let playerState = playerState else { return }
            switch player.playbackState {
            case .playing:
                playerState.isPlaying = true
                playerState.isLoading = false
            case .paused:
                playerState.isPlaying = false
            case .stopped:
                playerState.isPlaying = false
                playerState.isLoading = false
            case .interrupted:
                playerState.isPlaying = false
            default:
                break
            }
        }

        private func handleLoadState() {
            guard let player = player, let playerState = playerState else { return }
            let loadState = player.loadState
            if loadState.contains(.playthroughOK) || loadState.contains(.playable) {
                playerState.isLoading = false
            }
            if loadState.contains(.stalled) {
                playerState.isLoading = true
                playerState.loadingMessage = "IJKPlayer 缓冲中..."
            }
        }

        // MARK: 进度更新

        private func startProgressTimer() {
            progressTimer?.invalidate()
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self = self, let player = self.player, let playerState = self.playerState else { return }
                let current = player.currentPlaybackTime
                let duration = player.duration
                if current.isFinite && current >= 0 {
                    playerState.currentTime = current
                }
                if duration.isFinite && duration > 0 {
                    playerState.duration = duration
                }
                playerState.updateDanmaku(at: current)
                playerState.savePlaybackProgress()
                playerState.reportBaiduCacheProgressIfNeeded()
            }
        }
    }
}

#endif
