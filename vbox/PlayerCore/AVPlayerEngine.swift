import AVFoundation
import UIKit

/// 系统 AVPlayer 内核封装。
/// 当前只作为 PlayerCore 的独立实现，不替换现有 PlayerViewsV2 播放主流程。
final class AVPlayerEngine: NSObject, PlayerEngine {
    let type: PlayerEngineType = .system
    let name = "系统"

    private(set) var state = PlayerEngineState()
    var onEvent: ((PlayerEngineEvent) -> Void)?

    private weak var containerView: UIView?
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var playerLayer: AVPlayerLayer?
    private var statusObservation: NSKeyValueObservation?
    private var loadedTimeRangesObservation: NSKeyValueObservation?
    private var bufferEmptyObservation: NSKeyValueObservation?
    private var likelyToKeepUpObservation: NSKeyValueObservation?
    private var presentationSizeObservation: NSKeyValueObservation?
    private var playbackEndObserver: NSObjectProtocol?
    private var playbackFailedObserver: NSObjectProtocol?
    private var timeObserver: Any?

    deinit {
        teardown()
    }

    func attach(to view: UIView) {
        containerView = view

        let layer: AVPlayerLayer
        if let existingLayer = playerLayer {
            layer = existingLayer
        } else {
            layer = AVPlayerLayer()
            layer.videoGravity = .resizeAspect
            playerLayer = layer
        }

        layer.frame = view.bounds
        layer.player = player
        if layer.superlayer == nil {
            view.layer.addSublayer(layer)
        }
    }

    func load(route: PlaybackRoute) {
        cleanupPlaybackObjects(keepLayer: true)

        let asset = AVURLAsset(
            url: route.url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": route.headers]
        )
        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)

        playerItem = item
        player = newPlayer
        playerLayer?.player = newPlayer

        state = PlayerEngineState(isBuffering: true)
        onEvent?(.buffering(true))
        onEvent?(.log("系统内核加载线路：\(route.title)"))

        bindObservers(item: item, player: newPlayer)
    }

    func play() {
        player?.play()
        state.isPlaying = true
    }

    func pause() {
        player?.pause()
        state.isPlaying = false
    }

    func stop() {
        player?.pause()
        player?.seek(to: .zero)
        state.isPlaying = false
        state.currentTime = 0
    }

    func seek(to seconds: Double) {
        let safeSeconds = max(0, seconds)
        let time = CMTime(seconds: safeSeconds, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setRate(_ rate: Double) {
        player?.rate = Float(rate)
    }

    func setVolume(_ volume: Double) {
        player?.volume = Float(min(max(volume, 0), 1))
    }

    func teardown() {
        cleanupPlaybackObjects(keepLayer: false)
        containerView = nil
        state = PlayerEngineState()
    }

    func layoutIfNeeded() {
        guard let containerView else { return }
        playerLayer?.frame = containerView.bounds
    }

    private func bindObservers(item: AVPlayerItem, player: AVPlayer) {
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            self?.handleStatusChange(item)
        }

        loadedTimeRangesObservation = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            self?.updateBufferedTime(item)
        }

        bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            if item.isPlaybackBufferEmpty {
                self.state.isBuffering = true
                self.onEvent?(.buffering(true))
            }
        }

        likelyToKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            if item.isPlaybackLikelyToKeepUp {
                self.state.isBuffering = false
                self.onEvent?(.buffering(false))
            }
        }

        presentationSizeObservation = item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            self.state.width = Int(item.presentationSize.width)
            self.state.height = Int(item.presentationSize.height)
        }

        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak item] time in
            guard let self, let item else { return }
            let current = time.seconds.isFinite ? time.seconds : 0
            let duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
            self.state.currentTime = current
            self.state.duration = duration
            self.onEvent?(.progress(current: current, duration: duration))
        }

        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.state.isPlaying = false
            self.onEvent?(.ended)
        }

        playbackFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self.emitFailure(error?.localizedDescription ?? "系统播放器播放失败")
        }
    }

    private func handleStatusChange(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            state.isBuffering = false
            let duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
            state.duration = duration
            state.width = Int(item.presentationSize.width)
            state.height = Int(item.presentationSize.height)
            onEvent?(.buffering(false))
            onEvent?(.ready)
        case .failed:
            emitFailure(item.error?.localizedDescription ?? "系统播放器加载失败")
        case .unknown:
            state.isBuffering = true
            onEvent?(.buffering(true))
        @unknown default:
            emitFailure("系统播放器未知状态")
        }
    }

    private func updateBufferedTime(_ item: AVPlayerItem) {
        guard let range = item.loadedTimeRanges.first?.timeRangeValue else { return }
        let buffered = range.start.seconds + range.duration.seconds
        if buffered.isFinite {
            state.bufferedTime = buffered
        }
    }

    private func emitFailure(_ message: String) {
        state.isBuffering = false
        state.isPlaying = false
        state.errorMessage = message
        onEvent?(.buffering(false))
        onEvent?(.failed(message))
    }

    private func cleanupPlaybackObjects(keepLayer: Bool) {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil

        statusObservation?.invalidate()
        loadedTimeRangesObservation?.invalidate()
        bufferEmptyObservation?.invalidate()
        likelyToKeepUpObservation?.invalidate()
        presentationSizeObservation?.invalidate()
        statusObservation = nil
        loadedTimeRangesObservation = nil
        bufferEmptyObservation = nil
        likelyToKeepUpObservation = nil
        presentationSizeObservation = nil

        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
        }
        if let playbackFailedObserver {
            NotificationCenter.default.removeObserver(playbackFailedObserver)
        }
        playbackEndObserver = nil
        playbackFailedObserver = nil

        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerItem = nil

        if keepLayer {
            playerLayer?.player = nil
        } else {
            playerLayer?.player = nil
            playerLayer?.removeFromSuperlayer()
            playerLayer = nil
        }
    }
}
