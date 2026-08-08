import Foundation
import AVFoundation
import AVKit
import UIKit

// MARK: - 通知

extension Notification.Name {
    /// AVPlayer PiP 代理失败，回退到帧桥接 PiP
    static let vboxAVPlayerPiPFallback = Notification.Name("vbox.avplayer.pip.fallback")
    /// AVPlayer PiP 状态变化
    static let vboxAVPlayerPiPStatusChanged = Notification.Name("vbox.avplayer.pip.status")
}

// MARK: - AVPlayer 代理画中画管理器

/// AVPlayer 代理画中画管理器。
///
/// **问题背景**：MPV 引擎使用 OpenGL ES 离屏 FBO 渲染帧到 AVSampleBufferDisplayLayer，
/// 但 iOS 在 App 进入后台时会暂停 GPU 操作，导致 PiP 窗口画面冻结（有声音）。
///
/// **解决方案**：使用 AVPlayer 的原生 PiP 支持作为代理。
/// AVPlayer 的 PiP 由系统级视频解码管线驱动，不依赖 OpenGL ES 渲染，
/// 后台时画面正常更新。MPV 仍在后台播放以提供音频。
///
/// **转封装回退**：当 AVPlayer 无法直接播放原始 URL（如 MKV/FLV 格式）时，
/// 自动通过 RemuxProxyServer 将容器实时转封装为 fMP4 后播放。
///
/// 使用方式：
/// 1. 调用 `startProxyPiP(url:headers:currentPosition:)` 启动
/// 2. 监听 `.vboxAVPlayerPiPFallback` 通知处理回退
/// 3. 调用 `stopProxyPiP()` 停止
final class MPVAVPlayerPiPProxy: NSObject {

    static let shared = MPVAVPlayerPiPProxy()

    // MARK: - 公开属性

    /// 是否正在运行
    private(set) var isActive = false
    /// 是否支持 PiP
    var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }
    /// 是否正在尝试转封装路径
    private(set) var isTryingRemux = false

    // MARK: - 私有属性

    private var avPlayer: AVPlayer?
    private var pipController: AVPictureInPictureController?
    private var sourceURL: URL?
    private var sourceHeaders: [String: String] = [:]
    private var lastKnownPosition: Double = 0
    private var startRetries: Int = 0
    private let maxRetries = 2
    private var statusObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    private var audioSessionActive = false

    // MARK: - 初始化

    private override init() {
        super.init()
        setupNotifications()
    }

    // MARK: - 公开方法

    /// 启动 AVPlayer 代理 PiP
    /// - Parameters:
    ///   - url: 视频源 URL（与 MPV 相同的播放地址）
    ///   - headers: HTTP 请求头（用于云存储鉴权）
    ///   - currentPosition: MPV 当前播放位置（秒）
    func startProxyPiP(url: URL, headers: [String: String] = [:], currentPosition: Double) {
        guard isSupported else {
            print("[AVPlayerPiP] 设备不支持 PiP")
            return
        }

        // 如果已有活跃的代理，先停止
        if isActive {
            stopProxyPiP()
        }

        sourceURL = url
        sourceHeaders = headers
        lastKnownPosition = currentPosition
        startRetries = 0
        isTryingRemux = false
        isActive = true

        print("[AVPlayerPiP] 启动代理 PiP: url=\(url.host ?? "")\(url.path), pos=\(currentPosition)")

        // 创建 AVPlayer
        let player = AVPlayer()
        self.avPlayer = player

        // 创建 AVPlayerItem（带请求头）
        let asset: AVURLAsset
        if !headers.isEmpty {
            let options = ["AVURLAssetHTTPHeaderFieldsKey": headers]
            asset = AVURLAsset(url: url, options: options)
        } else {
            asset = AVURLAsset(url: url)
        }

        let playerItem = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: playerItem)

        // 静音 AVPlayer（MPV 负责音频输出，避免双倍音量）
        player.volume = 0
        player.isMuted = true

        // Seek 到当前播放位置
        let seekTime = CMTime(seconds: currentPosition, preferredTimescale: 1000)
        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)

        // 设置 PiP
        setupPiPController(for: player)

        // 监听状态
        setupObservers(for: player, playerItem: playerItem)

        // 播放
        player.play()

        // 激活音频会话
        activateAudioSession()

        NotificationCenter.default.post(name: .vboxAVPlayerPiPStatusChanged, object: true)
    }

    /// 停止 AVPlayer 代理 PiP
    func stopProxyPiP() {
        isActive = false
        isTryingRemux = false

        timeObserver.map { avPlayer?.removeTimeObserver($0) }
        timeObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil

        pipController?.stopPictureInPicture()
        pipController = nil

        avPlayer?.pause()
        avPlayer?.replaceCurrentItem(with: nil)
        avPlayer = nil

        sourceURL = nil
        sourceHeaders = [:]

        deactivateAudioSession()

        print("[AVPlayerPiP] 代理 PiP 已停止")
        NotificationCenter.default.post(name: .vboxAVPlayerPiPStatusChanged, object: false)
    }

    /// 同步播放位置（由 MPV 定时回调）
    func syncPosition(_ position: Double) {
        lastKnownPosition = position
    }

    // MARK: - 私有方法

    private func setupPiPController(for player: AVPlayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

        let controller = AVPictureInPictureController(playerLayer: AVPlayerLayer(player: player))
        controller.delegate = self
        // iOS 16+ 支持自动启动 PiP
        if #available(iOS 16.0, *) {
            controller.canStartPictureInPictureAutomaticallyFromInline = true
        }
        self.pipController = controller

        print("[AVPlayerPiP] PiP Controller 已设置")
    }

    private func setupObservers(for player: AVPlayer, playerItem: AVPlayerItem) {
        // 监听播放状态
        statusObserver = playerItem.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self else { return }

            switch item.status {
            case .readyToPlay:
                print("[AVPlayerPiP] AVPlayer 已就绪")
                self.startRetries = 0
            case .failed:
                print("[AVPlayerPiP] AVPlayer 加载失败: \(item.error?.localizedDescription ?? "unknown")")
                self.handlePlaybackFailure()
            default:
                break
            }
        }

        // 定时同步位置
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 1000),
            queue: .main
        ) { [weak self] time in
            self?.lastKnownPosition = time.seconds
        }
    }

    private func handlePlaybackFailure() {
        startRetries += 1

        if startRetries <= maxRetries {
            print("[AVPlayerPiP] 重试 \(startRetries)/\(maxRetries)...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, let url = self.sourceURL else { return }
                let pos = self.lastKnownPosition
                self.stopProxyPiP()
                self.startProxyPiP(url: url, headers: self.sourceHeaders, currentPosition: pos)
            }
            return
        }

        // 重试次数用尽，尝试转封装路径
        if let sourceURL, !isTryingRemux {
            tryRemuxPath(sourceURL: sourceURL)
        } else {
            // 转封装也失败，回退到帧桥接 PiP
            print("[AVPlayerPiP] 所有路径失败，回退到帧桥接 PiP")
            NotificationCenter.default.post(
                name: .vboxAVPlayerPiPFallback,
                object: nil
            )
            stopProxyPiP()
        }
    }

    /// 尝试通过转封装路径重试 AVPlayer PiP
    private func tryRemuxPath(sourceURL: URL) {
        guard !isTryingRemux else { return }
        isTryingRemux = true

        print("[AVPlayerPiP] 原始 URL 播放失败，尝试转封装路径...")

        // 确保转封装服务器已启动
        if !RemuxProxyServer.shared.isRunning {
            RemuxProxyServer.shared.start()
        }

        // 获取上游 URL（如果是本地代理 URL，需要查找原始上游 URL）
        let upstreamURL: URL
        let upstreamHeaders: [String: String]
        let provider: String

        if let info = DoubanImageProxyServer.shared.upstreamInfo(for: sourceURL) {
            upstreamURL = info.url
            upstreamHeaders = info.headers
            provider = info.provider
            print("[AVPlayerPiP] 从本地代理获取上游: provider=\(provider), host=\(upstreamURL.host ?? "")")
        } else {
            // 非本地代理 URL，直接使用
            upstreamURL = sourceURL
            upstreamHeaders = sourceHeaders
            provider = "direct"
            print("[AVPlayerPiP] 直接使用原始 URL 进行转封装")
        }

        // 注册转封装流
        guard let remuxURL = RemuxProxyServer.shared.registerStream(
            url: upstreamURL,
            headers: upstreamHeaders,
            provider: provider
        ) else {
            print("[AVPlayerPiP] 转封装流注册失败，回退到帧桥接 PiP")
            NotificationCenter.default.post(
                name: .vboxAVPlayerPiPFallback,
                object: nil
            )
            stopProxyPiP()
            return
        }

        print("[AVPlayerPiP] 转封装流已注册: \(remuxURL)")

        // 停止当前 AVPlayer
        avPlayer?.pause()
        avPlayer?.replaceCurrentItem(with: nil)
        pipController = nil

        // 用转封装 URL 创建新的 AVPlayer
        let player = AVPlayer()
        self.avPlayer = player

        let asset: AVURLAsset
        if !upstreamHeaders.isEmpty {
            let options = ["AVURLAssetHTTPHeaderFieldsKey": upstreamHeaders]
            asset = AVURLAsset(url: remuxURL, options: options)
        } else {
            asset = AVURLAsset(url: remuxURL)
        }

        let playerItem = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: playerItem)
        player.volume = 0
        player.isMuted = true

        let seekTime = CMTime(seconds: lastKnownPosition, preferredTimescale: 1000)
        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)

        setupPiPController(for: player)
        setupObservers(for: player, playerItem: playerItem)
        player.play()

        print("[AVPlayerPiP] 转封装路径 AVPlayer 已启动")
    }

    private func activateAudioSession() {
        guard !audioSessionActive else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            audioSessionActive = true
        } catch {
            print("[AVPlayerPiP] 音频会话激活失败: \(error)")
        }
    }

    private func deactivateAudioSession() {
        guard audioSessionActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false)
            audioSessionActive = false
        } catch {
            print("[AVPlayerPiP] 音频会话停用失败: \(error)")
        }
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePiPFallback(_:)),
            name: .vboxAVPlayerPiPFallback,
            object: nil
        )
    }

    @objc private func handlePiPFallback(_ notification: Notification) {
        // 如果当前不活跃，忽略
        guard isActive else { return }
        print("[AVPlayerPiP] 收到回退通知，停止代理")
        stopProxyPiP()
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension MPVAVPlayerPiPProxy: AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        print("[AVPlayerPiP] PiP 即将开始")
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        print("[AVPlayerPiP] PiP 已开始")
        NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: true)
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        print("[AVPlayerPiP] PiP 即将停止")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        print("[AVPlayerPiP] PiP 已停止")
        stopProxyPiP()
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        print("[AVPlayerPiP] PiP 启动失败: \(error)")
        handlePlaybackFailure()
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        print("[AVPlayerPiP] 恢复用户界面")
        completionHandler(true)
    }
}