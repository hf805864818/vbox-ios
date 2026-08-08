import AVFoundation
import AVKit
import UIKit

/// 通用视图截图画中画管理器。
/// 用于 IJK / VLC / AliPlayer 等无法直接获取视频帧的引擎。
/// 数据管线：DispatchSourceTimer → UIGraphicsImageRenderer 截图 → CVPixelBuffer
///           → CMSampleBuffer → AVSampleBufferDisplayLayer → AVPictureInPictureController
///
/// 限制：App 进入后台后视图不再渲染，PiP 窗口会冻结在最后一帧。
/// 但相比 AVPlayer 回退方案（本地代理 URL 无法播放），至少能正确弹出 PiP 窗口。
@MainActor
final class ViewCapturePiPManager: NSObject {

    static let shared = ViewCapturePiPManager()

    // MARK: - 公开状态

    private(set) var isPipActive = false
    private(set) var isPipSupported = false
    private(set) var isPiPReady = false

    // MARK: - 私有属性

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var displayLayerWindow: UIWindow?
    private var pipController: AVPictureInPictureController?
    private var formatDescription: CMVideoFormatDescription?
    private var pixelBufferPool: CVPixelBufferPool?
    private var videoSize: CGSize = .zero
    private var hasEnqueuedFirstFrame = false
    private var pipStartRetries: Int = 0
    private var frameCount: Int = 0
    private var lastFPSTime: Date = Date()
    private var estimatedFPS: Double = 30
    /// KVO 观察者（必须强引用，否则会被释放导致回调失效）
    private var pipStatusObserver: NSKeyValueObservation?

    /// 截图定时器（DispatchSourceTimer，后台仍可触发）
    private var captureTimer: DispatchSourceTimer?
    /// 被截图的播放器视图
    private weak var sourceView: UIView?
    /// 是否正在截图
    private var isCapturing = false

    // MARK: - 初始化

    private override init() {
        super.init()
        checkPiPAvailability()
    }

    private func checkPiPAvailability() {
        if #available(iOS 15.0, *) {
            isPipSupported = AVPictureInPictureController.isPictureInPictureSupported()
        } else {
            isPipSupported = false
        }
    }

    // MARK: - PiP 生命周期

    /// 初始化 PiP（传入视频尺寸和源视图）
    func initializePiP(videoSize: CGSize, sourceView: UIView) {
        guard isPipSupported else { return }
        guard videoSize.width > 0, videoSize.height > 0 else { return }

        // 如果已初始化且尺寸未变，仅更新源视图
        if isPiPReady && self.videoSize == videoSize {
            self.sourceView = sourceView
            return
        }

        self.videoSize = videoSize
        self.sourceView = sourceView

        // 清理旧资源
        cleanupDisplayLayer()

        // 创建 AVSampleBufferDisplayLayer
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = CGRect(origin: .zero, size: videoSize)
        layer.videoGravity = .resizeAspect
        self.displayLayer = layer

        // 挂载到不可见的 UIWindow
        mountDisplayLayer(layer)

        // 创建 CVPixelBufferPool
        createPixelBufferPool(width: Int(videoSize.width),
                              height: Int(videoSize.height))

        // 创建 PiP 控制器
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        pipController = AVPictureInPictureController(contentSource: source)
        pipController?.delegate = self

        // 激活音频会话
        activateAudioSession()

        // KVO 观察 isPictureInPicturePossible（必须强引用观察者）
        pipStatusObserver = pipController?.observe(\AVPictureInPictureController.isPictureInPicturePossible,
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
        print("[ViewCapturePiP] PiP 初始化完成，视频尺寸：\(Int(videoSize.width))x\(Int(videoSize.height))")
    }

    /// 将 displayLayer 挂载到不可见的 UIWindow
    private func mountDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first

        guard let scene = windowScene else {
            print("[ViewCapturePiP] 警告：无法获取 UIWindowScene")
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
        print("[ViewCapturePiP] displayLayer 已挂载到不可见 UIWindow")
    }

    /// 启动画中画（传入源视图）
    func startPiP(sourceView: UIView) {
        guard isPipSupported else {
            print("[ViewCapturePiP] 当前设备不支持画中画")
            return
        }

        self.sourceView = sourceView

        // 先用源视图尺寸初始化（如果尚未初始化）
        if pipController == nil || !isPiPReady {
            guard sourceView.bounds.width > 0, sourceView.bounds.height > 0 else {
                print("[ViewCapturePiP] 源视图尺寸无效")
                return
            }
            initializePiP(videoSize: sourceView.bounds.size, sourceView: sourceView)
        }

        // 启动截图定时器
        startCaptureTimer()

        // 立即捕获一帧
        captureAndEnqueueFrame()

        pipStartRetries = 0
        tryStartPiP()
    }

    private func tryStartPiP() {
        guard pipStartRetries < 15 else {
            print("[ViewCapturePiP] 超过最大重试次数，放弃启动 PiP")
            pipStartRetries = 0
            return
        }

        guard let pipController else { return }

        if pipController.isPictureInPicturePossible {
            pipController.startPictureInPicture()
            pipStartRetries = 0
            print("[ViewCapturePiP] 启动 PiP")
        } else {
            pipStartRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.tryStartPiP()
            }
        }
    }

    /// 停止画中画
    func stopPiP() {
        stopCaptureTimer()
        pipController?.stopPictureInPicture()
        pipStartRetries = 0
    }

    /// 清理 PiP（引擎销毁或切集时调用）
    func cleanupPiP() {
        stopPiP()
        cleanupDisplayLayer()
        pipStatusObserver = nil
        pipController = nil
        formatDescription = nil
        pixelBufferPool = nil
        videoSize = .zero
        isPiPReady = false
        hasEnqueuedFirstFrame = false
        frameCount = 0
        sourceView = nil
    }

    private func cleanupDisplayLayer() {
        displayLayer?.removeFromSuperlayer()
        displayLayer = nil
        if let window = displayLayerWindow {
            window.isHidden = true
            window.rootViewController = nil
            self.displayLayerWindow = nil
        }
    }

    // MARK: - 截图帧捕获

    /// 启动截图定时器
    private func startCaptureTimer() {
        guard captureTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))  // 10fps
        timer.setEventHandler { [weak self] in
            self?.captureAndEnqueueFrame()
        }
        timer.resume()
        captureTimer = timer
        print("[ViewCapturePiP] 截图定时器已启动")
    }

    /// 停止截图定时器
    private func stopCaptureTimer() {
        captureTimer?.cancel()
        captureTimer = nil
        isCapturing = false
    }

    /// 截图并推送帧到 displayLayer
    private func captureAndEnqueueFrame() {
        guard isPiPReady, let displayLayer, let sourceView else { return }
        guard !isCapturing else { return }  // 防止重入

        // 视图尚未布局或尺寸为0时跳过
        let viewWidth = sourceView.bounds.width
        let viewHeight = sourceView.bounds.height
        guard viewWidth > 1, viewHeight > 1 else { return }

        isCapturing = true
        defer { isCapturing = false }

        // 使用 UIGraphicsImageRenderer 截图
        let renderer = UIGraphicsImageRenderer(size: sourceView.bounds.size)
        let image = renderer.image { ctx in
            sourceView.drawHierarchy(in: sourceView.bounds, afterScreenUpdates: false)
        }

        // 转换 UIImage → CVPixelBuffer
        guard let pixelBuffer = imageToPixelBuffer(image, size: sourceView.bounds.size) else { return }

        // 如果尺寸变化，重新初始化 formatDescription
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        let newSize = CGSize(width: bufferWidth, height: bufferHeight)

        // 视频尺寸变化时（如旋转），需要重新创建 formatDescription
        if let fmtDesc = formatDescription {
            let descWidth = CMVideoFormatDescriptionGetDimensions(fmtDesc).width
            let descHeight = CMVideoFormatDescriptionGetDimensions(fmtDesc).height
            if Int(descWidth) != bufferWidth || Int(descHeight) != bufferHeight {
                formatDescription = nil
                // 重新初始化 PiP 以更新 displayLayer 尺寸
                initializePiP(videoSize: newSize, sourceView: sourceView)
                guard pipController != nil, self.displayLayer != nil else { return }
            }
        }

        if pipController == nil {
            initializePiP(videoSize: newSize, sourceView: sourceView)
            guard pipController != nil, self.displayLayer != nil else { return }
        }

        // 首帧或尺寸变化后创建 formatDescription
        if formatDescription == nil {
            var fmtDesc: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &fmtDesc
            )
            if status != noErr {
                print("[ViewCapturePiP] formatDescription 创建失败：\(status)")
                return
            }
            formatDescription = fmtDesc
        }

        guard let formatDescription else { return }
        guard displayLayer.isReadyForMoreMediaData else { return }

        // 更新 FPS 估算
        updateFPS()

        // 创建 CMSampleBuffer
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(estimatedFPS)),
            presentationTimeStamp: CMTime(value: Int64(Date().timeIntervalSince1970 * 1000), timescale: 1000),
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
                print("[ViewCapturePiP] 首帧已推送，等待 isPictureInPicturePossible...")
                if pipStartRetries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        self?.tryStartPiP()
                    }
                }
            }
        }
    }

    // MARK: - 辅助方法

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
            kCVPixelBufferPoolMinimumBufferCountKey as String: 2,
            kCVPixelBufferPoolMaximumBufferAgeKey as String: 0.5
        ]
        let bufferAttrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferCGImageCompatibilityKey as String: true
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                 poolAttrs as CFDictionary,
                                 bufferAttrs as CFDictionary,
                                 &pixelBufferPool)
    }

    /// 将 UIImage 转换为 CVPixelBuffer
    private func imageToPixelBuffer(_ image: UIImage, size: CGSize) -> CVPixelBuffer? {
        let width = Int(size.width)
        let height = Int(size.height)

        // 优先从 pool 获取
        var pixelBuffer: CVPixelBuffer?
        if let pool = pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        }

        if pixelBuffer == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferCGImageCompatibilityKey as String: true
            ]
            CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                kCVPixelFormatType_32BGRA,
                                attrs as CFDictionary, &pixelBuffer)
        }

        guard let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        guard let cgImage = image.cgImage else { return nil }

        // CGContext 的坐标原点在左下角，需要翻转
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return pb
    }

    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: .mixWithOthers)
            try session.setActive(true)
            print("[ViewCapturePiP] 音频会话激活成功")
        } catch {
            print("[ViewCapturePiP] 音频会话激活失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension ViewCapturePiPManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPipActive = true
            print("[ViewCapturePiP] 画中画已启动")
            NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPipActive = false
            self.pipStartRetries = 0
            self.stopCaptureTimer()
            print("[ViewCapturePiP] 画中画已停止")
            NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: false)
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPipActive = false
            self.pipStartRetries = 0
            self.stopCaptureTimer()
            print("[ViewCapturePiP] 画中画启动失败: \(error.localizedDescription)")
            NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: false)
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension ViewCapturePiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool) {
        // 截图模式不支持播放/暂停控制，空实现即可
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return false
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void) {
        // 截图模式不支持跳转，直接回调
        completionHandler()
    }

    nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return false
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        // PiP 窗口尺寸变化时的回调（iOS 16.0+）
        Task { @MainActor in
            print("[ViewCapturePiP] PiP 窗口尺寸变化：\(newRenderSize.width)x\(newRenderSize.height)")
        }
    }
}
