import AVFoundation
import AVKit
import UIKit

#if canImport(swift_mdk)
import swift_mdk
#endif

/// MDK 画中画管理器。
/// 通过 AVSampleBufferDisplayLayer 帧桥接实现系统级画中画。
/// 数据管线：MDK onFrame<VideoFrame> → CVPixelBuffer → CMSampleBuffer
///           → AVSampleBufferDisplayLayer → AVPictureInPictureController
///
/// 参考uz影视 FvpPipManager 实现：
/// - 使用 AVSampleBufferDisplayLayer 作为内容源
/// - 实现 AVPictureInPictureSampleBufferPlaybackDelegate 完整协议
/// - 支持自动PiP、跳转、暂停查询
@MainActor
final class MDKPipManager: NSObject {

    static let shared = MDKPipManager()

    // MARK: - 公开状态

    private(set) var isPipActive = false
    private(set) var isPipSupported = false
    /// PiP 是否已准备好（控制器已创建，displayLayer 已挂载）
    private(set) var isPiPReady = false

    // MARK: - 私有属性

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var displayLayerWindow: UIWindow?
    private var pipController: AVPictureInPictureController?
    private var formatDescription: CMVideoFormatDescription?
    private var pixelBufferPool: CVPixelBufferPool?
    private var videoSize: CGSize = .zero
    /// 首帧是否已推送
    private var hasEnqueuedFirstFrame = false
    /// PiP 启动重试次数
    private var pipStartRetries: Int = 0
    /// 帧推送计数
    private var frameCount: Int = 0
    private var lastFPSTime: Date = Date()
    private var estimatedFPS: Double = 30

    // MARK: - 初始化

    private override init() {
        super.init()
        checkPiPAvailability()
    }

    /// 检查当前设备是否支持画中画
    private func checkPiPAvailability() {
        if #available(iOS 15.0, *) {
            isPipSupported = AVPictureInPictureController.isPictureInPictureSupported()
        } else {
            isPipSupported = false
        }
    }

    // MARK: - PiP 生命周期

    /// 初始化 PiP（传入视频尺寸，在首帧到达前调用）
    /// 关键修复：displayLayer 必须挂载到 UIWindow 才能被 PiP 控制器识别
    func initializePiP(videoSize: CGSize) {
        guard isPipSupported else { return }
        guard videoSize.width > 0, videoSize.height > 0 else { return }

        // 如果已初始化且尺寸未变，跳过
        if isPiPReady && self.videoSize == videoSize {
            return
        }

        self.videoSize = videoSize

        // 清理旧资源
        cleanupDisplayLayer()

        // 创建 AVSampleBufferDisplayLayer
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = CGRect(origin: .zero, size: videoSize)
        layer.videoGravity = .resizeAspect
        self.displayLayer = layer

        // 关键：将 displayLayer 挂载到一个不可见的 UIWindow
        mountDisplayLayer(layer)

        // 创建 CVPixelBufferPool（复用缓冲区，避免每帧创建）
        createPixelBufferPool(width: Int(videoSize.width),
                              height: Int(videoSize.height))

        // 创建 PiP 控制器
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        pipController = AVPictureInPictureController(contentSource: source)
        pipController?.delegate = self

        // 激活音频会话（iOS 要求必须有活跃音频会话才能启动 PiP）
        activateAudioSession()

        // KVO 观察 isPictureInPicturePossible
        pipController?.observe(\AVPictureInPictureController.isPictureInPicturePossible,
                                options: [.new]) { [weak self] _, change in
            guard let self else { return }
            if let isPossible = change.newValue, isPossible {
                if self.pipStartRetries > 0 {
                    self.tryStartPiP()
                }
            }
        }

        isPiPReady = true
        hasEnqueuedFirstFrame = false
        print("[MDKPiP] PiP 初始化完成，视频尺寸：\(Int(videoSize.width))x\(Int(videoSize.height))")
    }

    /// 将 displayLayer 挂载到不可见的 UIWindow
    private func mountDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first

        guard let scene = windowScene else {
            print("[MDKPiP] 警告：无法获取 UIWindowScene，displayLayer 未挂载")
            return
        }

        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: -1)
        window.backgroundColor = .clear
        window.isHidden = false
        window.alpha = 0.01
        window.isUserInteractionEnabled = false

        let containerView = UIView(frame: CGRect(origin: .zero, size: videoSize))
        containerView.layer.addSublayer(layer)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(containerView)

        self.displayLayerWindow = window
        print("[MDKPiP] displayLayer 已挂载到不可见 UIWindow")
    }

    /// 启动画中画
    func startPiP() {
        guard isPipSupported else { return }

        if pipController == nil || !isPiPReady {
            print("[MDKPiP] PiP 控制器尚未就绪，等待首帧初始化")
            pipStartRetries = 1
            return
        }

        pipStartRetries = 0
        tryStartPiP()
    }

    private func tryStartPiP() {
        guard pipStartRetries < 10 else {
            print("[MDKPiP] 超过最大重试次数，放弃启动 PiP")
            pipStartRetries = 0
            return
        }

        guard let pipController else { return }

        if pipController.isPictureInPicturePossible {
            pipController.startPictureInPicture()
            pipStartRetries = 0
            print("[MDKPiP] 启动 PiP")
        } else {
            pipStartRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.tryStartPiP()
            }
        }
    }

    /// 停止画中画
    func stopPiP() {
        pipController?.stopPictureInPicture()
        pipStartRetries = 0
    }

    /// 清理 PiP 控制器（视频切换或引擎销毁时调用）
    func cleanupPiPController() {
        stopPiP()
        cleanupDisplayLayer()
        pipController = nil
        formatDescription = nil
        pixelBufferPool = nil
        videoSize = .zero
        isPiPReady = false
        hasEnqueuedFirstFrame = false
        frameCount = 0
    }

    /// 仅清理 displayLayer 和 window
    private func cleanupDisplayLayer() {
        displayLayer?.removeFromSuperlayer()
        displayLayer = nil
        if let window = displayLayerWindow {
            window.isHidden = true
            window.rootViewController = nil
            self.displayLayerWindow = nil
        }
    }

    // MARK: - 帧推送（从 MDK onFrame 回调调用）

    /// 将 CVPixelBuffer 推送到 displayLayer
    /// - Parameters:
    ///   - pixelBuffer: 从 MDK VideoFrame 获取的 CVPixelBuffer
    ///   - presentationTime: 帧的呈现时间
    /// nonisolated：允许从 MDK 后台解码线程调用，内部切到主线程执行。
    nonisolated func enqueueFrame(_ pixelBuffer: CVPixelBuffer,
                      presentationTime: CMTime) {
        Task { @MainActor [weak self] in
            self?.enqueueFrameInternal(pixelBuffer, presentationTime: presentationTime)
        }
    }

    private func enqueueFrameInternal(_ pixelBuffer: CVPixelBuffer,
                      presentationTime: CMTime) {
        guard isPiPReady, let displayLayer else { return }

        // 首帧时自动初始化 PiP 控制器（如果尚未初始化）
        if pipController == nil {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            initializePiP(videoSize: CGSize(width: width, height: height))
            guard pipController != nil, self.displayLayer != nil else { return }
        }

        // 首帧时创建 formatDescription
        if formatDescription == nil {
            var fmtDesc: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &fmtDesc
            )
            if status != noErr {
                print("[MDKPiP] formatDescription 创建失败：\(status)")
                return
            }
            formatDescription = fmtDesc
        }

        guard let formatDescription else { return }

        // 检查 displayLayer 是否准备好接收新数据
        guard displayLayer.isReadyForMoreMediaData else { return }

        // 更新 fps 估算
        updateFPS()

        // 创建 CMSampleBuffer
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(estimatedFPS)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        if status == noErr, let sampleBuffer {
            displayLayer.enqueue(sampleBuffer)

            if !hasEnqueuedFirstFrame {
                hasEnqueuedFirstFrame = true
                print("[MDKPiP] 首帧已推送，等待 isPictureInPicturePossible...")
                if pipStartRetries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        self?.tryStartPiP()
                    }
                }
            }
        }
    }

    // MARK: - 私有方法

    private func updateFPS() {
        frameCount += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFPSTime)
        if elapsed >= 1.0 {
            estimatedFPS = Double(frameCount) / elapsed
            frameCount = 0
            lastFPSTime = now
        }
    }

    private func createPixelBufferPool(width: Int, height: Int) {
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 4,
            kCVPixelBufferPoolMaximumBufferAgeKey as String: 0.5
        ]
        let bufferAttrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                 poolAttrs as CFDictionary,
                                 bufferAttrs as CFDictionary,
                                 &pixelBufferPool)
    }

    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: .mixWithOthers)
            try session.setActive(true)
            print("[MDKPiP] 音频会话激活成功")
        } catch {
            print("[MDKPiP] 音频会话激活失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension MDKPipManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPipActive = true
            print("[MDKPiP] 画中画已启动")
            NotificationCenter.default.post(
                name: .vboxPiPStatusChanged,
                object: true
            )
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPipActive = false
            self.pipStartRetries = 0
            print("[MDKPiP] 画中画已停止")
            NotificationCenter.default.post(
                name: .vboxPiPStatusChanged,
                object: false
            )
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPipActive = false
            self.pipStartRetries = 0
            print("[MDKPiP] 画中画启动失败: \(error.localizedDescription)")
            NotificationCenter.default.post(
                name: .vboxPiPStatusChanged,
                object: false
            )
        }
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            print("[MDKPiP] 画中画即将启动")
            NotificationCenter.default.post(
                name: .vboxMDKPiPWillStart,
                object: nil
            )
        }
    }

    nonisolated func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            print("[MDKPiP] 画中画即将停止")
            NotificationCenter.default.post(
                name: .vboxMDKPiPWillStop,
                object: nil
            )
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // PiP 停止时恢复全屏
        Task { @MainActor in
            print("[MDKPiP] 恢复全屏界面")
            NotificationCenter.default.post(
                name: .vboxPiPRestoreFullScreen,
                object: nil
            )
            completionHandler(true)
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension MDKPipManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool) {
        // 通知 MDK 引擎播放/暂停
        Task { @MainActor in
            print("[MDKPiP] PiP 请求\(playing ? "播放" : "暂停")")
            NotificationCenter.default.post(
                name: .vboxPiPTogglePlayPause,
                object: playing
            )
        }
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return false
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity,
                     duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void) {
        // 通知 MDK 引擎跳转
        Task { @MainActor in
            let seconds = CMTimeGetSeconds(skipInterval)
            print("[MDKPiP] PiP 请求跳转：\(seconds)秒")
            NotificationCenter.default.post(
                name: .vboxMDKPiPSkip,
                object: skipInterval
            )
        }
        completionHandler()
    }

    nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return false
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        Task { @MainActor in
            print("[MDKPiP] PiP 窗口尺寸变化：\(newRenderSize.width)x\(newRenderSize.height)")
        }
    }
}

// MARK: - PiP 通知名称（复用 PlayerViewsV2.swift 中已有的通知名称）
// vboxPiPStatusChanged / vboxPiPRestoreFullScreen / vboxPiPTogglePlayPause 已在 PlayerViewsV2.swift 中定义
// MDK PipManager 新增以下专用通知：

extension Notification.Name {
    /// PiP 即将启动（MDK专用）
    static let vboxMDKPiPWillStart = Notification.Name("vbox.mdk.pip.willStart")
    /// PiP 即将停止（MDK专用）
    static let vboxMDKPiPWillStop = Notification.Name("vbox.mdk.pip.willStop")
    /// PiP 跳转（MDK专用，CMTime: skipInterval）
    static let vboxMDKPiPSkip = Notification.Name("vbox.mdk.pip.skip")
}
