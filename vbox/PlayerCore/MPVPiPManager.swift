import AVFoundation
import AVKit
import UIKit

#if canImport(Libmpv)
import Libmpv
#endif

/// MPV 画中画管理器。
/// 通过 AVSampleBufferDisplayLayer 帧桥接实现系统级画中画。
/// 数据管线：MPV OpenGL ES 渲染 → 离屏 FBO → glReadPixels → CVPixelBuffer
///           → CMSampleBuffer → AVSampleBufferDisplayLayer → AVPictureInPictureController
@MainActor
final class MPVPiPManager: NSObject {

    static let shared = MPVPiPManager()

    // MARK: - 公开状态

    private(set) var isPipActive = false
    private(set) var isPipSupported = false

    // MARK: - 私有属性

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?
    private var formatDescription: CMVideoFormatDescription?
    private var pixelBufferPool: CVPixelBufferPool?
    private var videoSize: CGSize = .zero

    // MARK: - 初始化

    private override init() {
        super.init()
        checkPiPAvailability()
    }

    /// 检查当前设备是否支持画中画
    private func checkPiPAvailability() {
        isPipSupported = AVPictureInPictureController.isPictureInPictureSupported()
    }

    // MARK: - PiP 生命周期

    /// 初始化 PiP（传入视频尺寸，如果为 .zero 则延迟到首帧时自动初始化）
    func initializePiP(videoSize: CGSize = .zero) {
        guard isPipSupported else { return }

        // 如果已初始化且尺寸未变，跳过
        if self.pipController != nil && (videoSize == .zero || self.videoSize == videoSize) {
            return
        }

        // 如果尺寸未知，等待首帧到达时初始化
        guard videoSize.width > 0, videoSize.height > 0 else { return }

        self.videoSize = videoSize

        // 创建 AVSampleBufferDisplayLayer
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = CGRect(origin: .zero, size: videoSize)
        layer.videoGravity = .resizeAspect
        self.displayLayer = layer

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
                                options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            if self.pipController?.isPictureInPicturePossible == true && !self.isPipActive {
                // 可以启动 PiP
            }
        }
    }

    /// 启动画中画
    func startPiP() {
        guard isPipSupported, let pipController else { return }

        if pipController.isPictureInPicturePossible {
            pipController.startPictureInPicture()
        } else {
            // 延迟重试（最多5次，每次0.5秒）
            schedulePiPStartRetry(retries: 5)
        }
    }

    /// 停止画中画
    func stopPiP() {
        pipController?.stopPictureInPicture()
    }

    /// 清理 PiP 控制器
    func cleanupPiPController() {
        stopPiP()
        pipController = nil
        displayLayer = nil
        formatDescription = nil
        pixelBufferPool = nil
        videoSize = .zero
    }

    // MARK: - 帧推送（从 MPVRenderContextPlayerCore 渲染回调调用）

    /// 将 CVPixelBuffer 推送到 displayLayer
    /// - Parameters:
    ///   - pixelBuffer: 从离屏 FBO glReadPixels 获取的 CVPixelBuffer
    ///   - presentationTime: 帧的呈现时间
    func enqueueFrame(_ pixelBuffer: CVPixelBuffer,
                      presentationTime: CMTime) {
        guard isPipActive, let displayLayer else { return }

        // 首帧时自动初始化 PiP 控制器（如果尚未初始化）
        if pipController == nil {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            initializePiP(videoSize: CGSize(width: width, height: height))
            guard pipController != nil, displayLayer != nil else { return }
        }

        // 首帧时创建 formatDescription
        if formatDescription == nil {
            var fmtDesc: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &fmtDesc
            )
            formatDescription = fmtDesc
        }

        guard let formatDescription else { return }

        // 检查 displayLayer 是否准备好接收新数据
        guard displayLayer.isReadyForMoreMediaData else { return }

        // 创建 CMSampleBuffer
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30), // 假设30fps
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        if let sampleBuffer {
            displayLayer.enqueue(sampleBuffer)
        }
    }

    // MARK: - 私有方法

    private func createPixelBufferPool(width: Int, height: Int) {
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3
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
            try AVAudioSession.sharedInstance().setCategory(.playback,
                                                           mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // 静默失败，不影响主播放流程
        }
    }

    private func schedulePiPStartRetry(retries: Int) {
        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if self.pipController?.isPictureInPicturePossible == true {
                self.pipController?.startPictureInPicture()
            } else {
                self.schedulePiPStartRetry(retries: retries - 1)
            }
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension MPVPiPManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            self?.isPipActive = true
            NotificationCenter.default.post(
                name: .vboxPiPStatusChanged,
                object: true
            )
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            self?.isPipActive = false
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
            self?.isPipActive = false
            NotificationCenter.default.post(
                name: .vboxPiPStatusChanged,
                object: false
            )
        }
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .vboxMPVPiPWillStart,
                object: nil
            )
        }
    }

    nonisolated func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .vboxMPVPiPWillStop,
                object: nil
            )
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension MPVPiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool) {
        // 通知 MPV 引擎播放/暂停（复用 PlayerViewsV2 已有通知）
        NotificationCenter.default.post(
            name: .vboxPiPTogglePlayPause,
            object: playing
        )
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController) -> Bool {
        // 查询 MPV 引擎播放状态
        // 通过通知同步，这里返回保守值
        return false
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // 返回正无穷范围，表示整个视频都可播放
        CMTimeRange(start: .negativeInfinity,
                     duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void) {
        // 通知 MPV 引擎跳转
        NotificationCenter.default.post(
            name: .vboxMPVPiPSkip,
            object: skipInterval
        )
        completionHandler()
    }

    nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController) -> Bool {
        // 允许后台音频播放
        return false
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        // PiP 窗口尺寸变化时的回调（iOS 16.0+）
    }
}

// MARK: - PiP 通知名称（MPV专用）
// vboxPiPStatusChanged / vboxPiPRestoreFullScreen / vboxPiPTogglePlayPause 已在 PlayerViewsV2.swift 中定义
// MPV PipManager 新增以下专用通知：

extension Notification.Name {
    /// PiP 即将启动（MPV专用）
    static let vboxMPVPiPWillStart = Notification.Name("vbox.mpv.pip.willStart")
    /// PiP 即将停止（MPV专用）
    static let vboxMPVPiPWillStop = Notification.Name("vbox.mpv.pip.willStop")
    /// PiP 跳转（MPV专用，CMTime: skipInterval）
    static let vboxMPVPiPSkip = Notification.Name("vbox.mpv.pip.skip")
}
