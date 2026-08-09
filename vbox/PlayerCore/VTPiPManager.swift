//
//  VTPiPManager.swift
//  vbox
//
//  VideoToolbox 硬解码画中画管理器。
//  直接从源流下载数据，通过 StreamRemuxer 提取原始视频帧，
//  再用 VideoToolbox 硬件解码，最后送入 AVSampleBufferDisplayLayer 显示 PiP。
//
//  核心优势：App 进入后台后仍能继续硬解码，PiP 窗口不会冻结。
//
//  数据流：
//  源流 → URLSession → StreamRemuxer → 原始视频帧 → VTDecoderSession
//         → CVPixelBuffer → CMSampleBuffer → AVSampleBufferDisplayLayer
//         → AVPictureInPictureController → PiP 小窗口
//
//  注意：此模块完全独立于主播放链路，不影响任何网盘资源播放。
//

import AVFoundation
import AVKit
import UIKit
import VideoToolbox

// MARK: - 通知

extension Notification.Name {
    /// VideoToolbox PiP 状态变化
    static let vboxVTPiPStatusChanged = Notification.Name("vbox.vtpip.status")
    /// VideoToolbox PiP 失败
    static let vboxVTPiPFailed = Notification.Name("vbox.vtpip.failed")
}

@MainActor
final class VTPiPManager: NSObject {

    static let shared = VTPiPManager()

    // MARK: - 公开状态

    private(set) var isPipActive = false
    private(set) var isPipSupported = false

    // MARK: - 私有属性 - PiP 显示层（主线程）

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var displayLayerWindow: UIWindow?
    private var pipController: AVPictureInPictureController?
    private var pipStatusObserver: NSKeyValueObservation?
    private var pipStartRetries: Int = 0
    private var hasEnqueuedFirstFrame = false
    private var videoSize: CGSize = .zero

    // MARK: - 私有属性 - 解码管线状态（processingQueue 上访问）

    /// 解码管线状态，所有读写都在 processingQueue 上进行
    private struct PipelineState {
        var remuxer: StreamRemuxer?
        var decoderSession: VTDecoderSession?
        var downloadTask: URLSessionDataTask?
        var downloadDelegate: VTPiPStreamDelegate?
        var downloadSession: URLSession?

        /// 解码器是否已开始初始化（防止重复调用 setupDecoderAndDisplayLayer）
        var decoderSetupStarted = false
        /// 是否已收到第一个关键帧
        var firstKeyframeReceived = false
        /// 起始时间戳（用于计算相对时间）
        var basePresentationTime: CMTime = .zero
        /// 已解码帧计数（用于粗略估计显示速率）
        var decodedFrameCount: Int64 = 0
        /// 待显示帧数（超过阈值则丢帧）
        var pendingFrameCount = 0
        /// 是否正在运行
        var isRunning = false
        /// 目标起始时间（毫秒），从主播放器当前播放位置开始
        var targetStartTimeMs: UInt64 = 0
        /// 是否已越过目标时间（找到目标时间后的第一个关键帧后开始解码）
        var hasPassedTargetTime = false
        /// 下载阶段：header=下载头部解析元数据, seek=Range跳到目标位置, streaming=正常播放
        var downloadPhase: DownloadPhase = .header
        /// 头部已下载字节数
        var headerBytesDownloaded: Int64 = 0
    }

    /// 下载阶段
    private enum DownloadPhase {
        case header      // 下载文件头部，解析 codec/分辨率等元数据
        case seeking     // 跳到目标位置（Range 请求）
        case streaming   // 正常流式播放
    }

    private var pipelineState = PipelineState()
    private let processingQueue = DispatchQueue(label: "com.vbox.vtpip.processing", qos: .userInitiated)

    // MARK: - 其他属性

    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

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

    // MARK: - 公开方法 - PiP 生命周期

    /// 启动 VideoToolbox PiP
    /// - Parameters:
    ///   - url: 视频源流 URL
    ///   - headers: 请求头
    ///   - startTime: 起始播放时间（秒），用于从当前观看位置开始，保证音画同步
    ///   - provider: 资源提供者标识
    func startPiP(url: URL, headers: [String: String], startTime: TimeInterval, provider: String) {
        guard isPipSupported else {
            print("[VTPiP] 当前设备不支持画中画")
            return
        }

        if isPipActive {
            stopPiP()
        }

        print("[VTPiP] 启动 VideoToolbox PiP，URL: \(url.absoluteString.prefix(80))..., startTime: \(startTime)s")

        // 激活音频会话（PiP 必须有活跃音频会话）
        activateAudioSession()

        // 启动后台任务
        startBackgroundTask()

        // 在 processingQueue 上初始化管线
        processingQueue.async { [weak self] in
            guard let self else { return }

            // 初始化转封装器
            let remuxer = StreamRemuxer()
            self.pipelineState.remuxer = remuxer
            self.pipelineState.isRunning = true
            self.pipelineState.decoderSetupStarted = false
            self.pipelineState.firstKeyframeReceived = false
            self.pipelineState.decodedFrameCount = 0
            self.pipelineState.pendingFrameCount = 0
            self.pipelineState.targetStartTimeMs = UInt64(max(0, startTime) * 1000)
            self.pipelineState.hasPassedTargetTime = startTime <= 0 // 如果从0开始，直接进入解码

            // 设置视频帧回调（在 processingQueue 上调用）
            remuxer.onVideoFrameReady = { [weak self] frameInfo in
                self?.handleVideoFrameOnPipelineQueue(frameInfo)
            }

            // 启动下载（带 Range 请求跳到目标时间附近）
            self.startDownloadOnPipelineQueue(url: url, headers: headers, startTime: startTime, remuxer: remuxer)
        }
    }

    /// 停止 PiP
    func stopPiP() {
        print("[VTPiP] 停止 VideoToolbox PiP")

        // 结束后台任务
        if backgroundTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
            backgroundTaskId = .invalid
        }

        // 在 processingQueue 上清理解码管线
        processingQueue.sync {
            pipelineState.downloadTask?.cancel()
            pipelineState.downloadTask = nil
            pipelineState.downloadDelegate = nil
            pipelineState.downloadSession?.invalidateAndCancel()
            pipelineState.downloadSession = nil
            pipelineState.decoderSession?.invalidate()
            pipelineState.decoderSession = nil
            pipelineState.remuxer = nil
            pipelineState.isRunning = false
            pipelineState.decoderSetupStarted = false
            pipelineState.firstKeyframeReceived = false
            pipelineState.pendingFrameCount = 0
            pipelineState.decodedFrameCount = 0
            pipelineState.targetStartTimeMs = 0
            pipelineState.hasPassedTargetTime = false
            pipelineState.downloadPhase = .header
            pipelineState.headerBytesDownloaded = 0
        }

        // 主线程清理 UI 相关资源
        pipController?.stopPictureInPicture()
        cleanupDisplayLayer()

        isPipActive = false
        hasEnqueuedFirstFrame = false
        videoSize = .zero
    }

    // MARK: - 私有方法 - 下载（processingQueue 上调用）

    private func startDownloadOnPipelineQueue(url: URL, headers: [String: String], startTime: TimeInterval, remuxer: StreamRemuxer) {
        dispatchPrecondition(condition: .onQueue(processingQueue))

        // 如果 startTime 很小（< 5秒），直接从头开始下载，不走两阶段
        if startTime < 5.0 {
            pipelineState.downloadPhase = .streaming
            pipelineState.hasPassedTargetTime = startTime <= 0
            print("[VTPiP] 从头开始播放（\(startTime)s），直接流式下载")
            startStreamingDownload(url: url, headers: headers, rangeStart: nil, remuxer: remuxer)
            return
        }

        // 两阶段下载：
        // Phase 1: 先下载文件头部（前 512KB），让 StreamRemuxer 解析出 codec/分辨率等元数据
        // Phase 2: 用 Range 请求跳到目标位置附近，继续下载和解码
        pipelineState.downloadPhase = .header
        pipelineState.headerBytesDownloaded = 0
        print("[VTPiP] 第一阶段：下载头部解析元数据（目标时间: \(startTime)s）")
        startHeaderDownload(url: url, headers: headers, remuxer: remuxer)
    }

    /// 启动头部下载（第一阶段：只下前 512KB 用于解析元数据）
    private func startHeaderDownload(url: URL, headers: [String: String], remuxer: StreamRemuxer) {
        dispatchPrecondition(condition: .onQueue(processingQueue))

        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // 只请求前 512KB，足够包含 MKV header + tracks + 第一个 cluster
        request.setValue("bytes=0-524287", forHTTPHeaderField: "Range")

        let delegate = VTPiPStreamDelegate(
            queue: processingQueue,
            onDataReceived: { [weak self] data in
                guard let self else { return }
                guard self.pipelineState.isRunning else { return }
                guard self.pipelineState.downloadPhase == .header else { return }

                self.pipelineState.headerBytesDownloaded += Int64(data.count)

                // 喂给转封装器解析头部
                remuxer.processBytes(data)

                // 检查是否已经解析出视频信息
                if !self.pipelineState.decoderSetupStarted,
                   remuxer.sourceFormat != .unknown,
                   remuxer.videoWidth > 0,
                   remuxer.videoHeight > 0 {
                    self.pipelineState.decoderSetupStarted = true
                    self.setupDecoderAndDisplayLayerOnMain(remuxer: remuxer)
                }
            },
            onComplete: { [weak self] in
                guard let self else { return }
                guard self.pipelineState.downloadPhase == .header else { return }
                print("[VTPiP] 头部下载完成，进入第二阶段：跳到目标位置")

                // 头部下载完成，取消当前任务，启动第二阶段 Range 下载
                self.pipelineState.downloadTask?.cancel()
                self.pipelineState.downloadTask = nil
                self.pipelineState.downloadDelegate = nil

                // 启动第二阶段：从目标位置附近开始
                self.startSeekPhaseDownload(url: url, headers: headers, remuxer: remuxer)
            },
            onError: { [weak self] error in
                guard let self else { return }
                guard self.pipelineState.downloadPhase == .header else { return }

                // 如果是取消（我们主动取消的），不算错误
                if let nsError = error as NSError?, nsError.code == -999 {
                    return
                }

                print("[VTPiP] 头部下载失败: \(error?.localizedDescription ?? "unknown")")
                self.pipelineState.isRunning = false
                Task { @MainActor in
                    self.handlePiPError()
                }
            }
        )

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.networkServiceType = .video
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        pipelineState.downloadSession = session
        let task = session.dataTask(with: request)
        task.resume()

        pipelineState.downloadTask = task
        pipelineState.downloadDelegate = delegate

        delegate.associatedTask = task
        objc_setAssociatedObject(task, &VTPiPManager.associatedDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// 启动 seek 阶段下载（第二阶段：用 Range 跳到目标位置附近）
    private func startSeekPhaseDownload(url: URL, headers: [String: String], remuxer: StreamRemuxer) {
        dispatchPrecondition(condition: .onQueue(processingQueue))

        let targetMs = pipelineState.targetStartTimeMs
        // 粗略估算字节位置：假设平均码率 2 Mbps = 250 KB/s
        // 往前多留 20 秒余量，确保目标时间点落在请求范围内
        let startTimeSec = TimeInterval(targetMs) / 1000.0
        let estimatedBytePosition = max(0, Int64(startTimeSec - 20) * 250 * 1024)

        pipelineState.downloadPhase = .seeking
        print("[VTPiP] 第二阶段：Range 跳到 ~\(estimatedBytePosition / 1024 / 1024)MB（目标: \(startTimeSec)s）")

        startStreamingDownload(url: url, headers: headers, rangeStart: estimatedBytePosition, remuxer: remuxer)
    }

    /// 启动流式下载（可带或不带 Range）
    private func startStreamingDownload(url: URL, headers: [String: String], rangeStart: Int64?, remuxer: StreamRemuxer) {
        dispatchPrecondition(condition: .onQueue(processingQueue))

        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let rangeStart = rangeStart, rangeStart > 0 {
            request.setValue("bytes=\(rangeStart)-", forHTTPHeaderField: "Range")
        }

        let delegate = VTPiPStreamDelegate(
            queue: processingQueue,
            onDataReceived: { [weak self] data in
                guard let self else { return }
                guard self.pipelineState.isRunning else { return }

                // 如果正在 seek 阶段，进入 streaming 阶段
                if self.pipelineState.downloadPhase == .seeking {
                    self.pipelineState.downloadPhase = .streaming
                }

                // 喂给转封装器
                remuxer.processBytes(data)

                // 检查是否已经解析出视频信息（兜底：如果头部阶段没解析出来）
                if !self.pipelineState.decoderSetupStarted,
                   remuxer.sourceFormat != .unknown,
                   remuxer.videoWidth > 0,
                   remuxer.videoHeight > 0 {
                    self.pipelineState.decoderSetupStarted = true
                    self.setupDecoderAndDisplayLayerOnMain(remuxer: remuxer)
                }
            },
            onComplete: { [weak self] in
                guard let self else { return }
                print("[VTPiP] 下载完成")
                _ = remuxer.finalize()
                if let decoder = self.pipelineState.decoderSession {
                    decoder.finishDecoding()
                }
            },
            onError: { [weak self] error in
                guard let self else { return }
                print("[VTPiP] 下载失败: \(error?.localizedDescription ?? "unknown")")
                self.pipelineState.isRunning = false
                Task { @MainActor in
                    self.handlePiPError()
                }
            }
        )

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.networkServiceType = .video
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        pipelineState.downloadSession = session
        let task = session.dataTask(with: request)
        task.resume()

        pipelineState.downloadTask = task
        pipelineState.downloadDelegate = delegate

        delegate.associatedTask = task
        objc_setAssociatedObject(task, &VTPiPManager.associatedDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private static var associatedDelegateKey: UInt8 = 0

    // MARK: - 私有方法 - 视频帧处理（processingQueue 上调用）

    private func handleVideoFrameOnPipelineQueue(_ frameInfo: StreamRemuxer.VideoFrameInfo) {
        dispatchPrecondition(condition: .onQueue(processingQueue))

        guard pipelineState.isRunning else { return }
        guard let decoder = pipelineState.decoderSession else {
            // 解码器还没初始化好，丢弃帧
            return
        }

        // 阶段 1：等待越过目标时间
        if !pipelineState.hasPassedTargetTime {
            // 如果这帧的 PTS 还没到目标时间，跳过
            if frameInfo.presentationTimeMs < pipelineState.targetStartTimeMs {
                return
            }
            // 到了目标时间后，等待第一个关键帧再开始解码
            if !frameInfo.isKeyframe {
                return
            }
            // 找到目标时间后的第一个关键帧，开始解码
            pipelineState.hasPassedTargetTime = true
            pipelineState.firstKeyframeReceived = true
            print("[VTPiP] 找到目标时间后的第一个关键帧（\(frameInfo.presentationTimeMs)ms），开始解码")
        }

        // 阶段 2：正常解码（已经越过目标时间）
        // 拥塞控制：如果待显示帧太多，丢弃非关键帧
        if pipelineState.pendingFrameCount > 30 && !frameInfo.isKeyframe {
            return
        }

        let pts = CMTime(value: Int64(frameInfo.presentationTimeMs), timescale: 1000)

        // 记录第一帧（目标时间后的第一帧）时间戳作为基准
        if pipelineState.decodedFrameCount == 0 {
            pipelineState.basePresentationTime = pts
        }

        // 计算相对时间戳（从 0 开始）
        let relativePts = CMTimeSubtract(pts, pipelineState.basePresentationTime)

        pipelineState.pendingFrameCount += 1

        // 送入解码器
        decoder.decodeFrame(
            frameInfo.data,
            presentationTimeStamp: relativePts,
            isKeyframe: frameInfo.isKeyframe
        )
    }

    // MARK: - 私有方法 - 初始化解码器和显示层

    private func setupDecoderAndDisplayLayerOnMain(remuxer: StreamRemuxer) {
        let width = remuxer.videoWidth
        let height = remuxer.videoHeight
        let codecType = remuxer.videoCodecTypeValue
        let extradata = remuxer.videoExtradataValue

        guard width > 0, height > 0 else { return }

        Task { @MainActor in
            self.setupDecoderAndDisplayLayer(
                width: width,
                height: height,
                codecType: CMVideoCodecType(codecType),
                extradata: extradata
            )
        }
    }

    private func setupDecoderAndDisplayLayer(
        width: Int,
        height: Int,
        codecType: CMVideoCodecType,
        extradata: Data?
    ) {
        videoSize = CGSize(width: width, height: height)
        print("[VTPiP] 视频信息: \(width)x\(height), codec: \(codecType)")

        // 清理旧资源
        cleanupDisplayLayer()

        // 创建解码会话（在 processingQueue 上设置 delegate）
        processingQueue.async { [weak self] in
            guard let self else { return }

            let decoder = VTDecoderSession()
            // delegate 回调会切换到主线程
            decoder.delegate = self

            do {
                try decoder.setup(
                    codecType: codecType,
                    extradata: extradata,
                    width: width,
                    height: height
                )
                self.pipelineState.decoderSession = decoder
                print("[VTPiP] VideoToolbox 解码会话创建成功")
            } catch {
                print("[VTPiP] VideoToolbox 解码会话创建失败: \(error)")
                self.pipelineState.isRunning = false
                Task { @MainActor in
                    self.handlePiPError()
                }
            }
        }

        // 创建 AVSampleBufferDisplayLayer
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = CGRect(origin: .zero, size: videoSize)
        layer.videoGravity = .resizeAspect
        self.displayLayer = layer

        // 挂载到不可见的 UIWindow
        mountDisplayLayer(layer)

        // 创建 PiP 控制器
        if #available(iOS 15.0, *) {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: layer,
                playbackDelegate: self
            )
            pipController = AVPictureInPictureController(contentSource: source)
            pipController?.delegate = self

            // KVO 观察 isPictureInPicturePossible
            pipStatusObserver = pipController?.observe(\AVPictureInPictureController.isPictureInPicturePossible,
                                    options: [.new]) { [weak self] _, change in
                guard let self else { return }
                Task { @MainActor in
                    if let isPossible = change.newValue, isPossible {
                        if self.pipStartRetries > 0 {
                            self.tryStartPiP()
                        }
                    }
                }
            }
        }

        hasEnqueuedFirstFrame = false
        print("[VTPiP] PiP 显示层初始化完成，等待首帧解码...")
    }

    /// 将 displayLayer 挂载到不可见的 UIWindow
    private func mountDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first

        guard let scene = windowScene else {
            print("[VTPiP] 警告：无法获取 UIWindowScene")
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
        print("[VTPiP] displayLayer 已挂载到不可见 UIWindow")
    }

    /// 清理显示层
    private func cleanupDisplayLayer() {
        displayLayer?.flushAndRemoveImage()
        displayLayer = nil
        displayLayerWindow = nil
        pipController = nil
        pipStatusObserver = nil
        pipStartRetries = 0
    }

    /// 尝试启动 PiP
    private func tryStartPiP() {
        guard let pipController = pipController else { return }

        if pipController.isPictureInPicturePossible {
            pipController.startPictureInPicture()
            pipStartRetries = 0
        } else {
            pipStartRetries += 1
            if pipStartRetries < 15 {
                // 延迟重试，等待第一帧渲染
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.tryStartPiP()
                }
            } else {
                print("[VTPiP] PiP 启动失败：isPictureInPicturePossible 始终为 false")
                handlePiPError()
            }
        }
    }

    /// 处理 PiP 错误（通知外部降级）
    private func handlePiPError() {
        print("[VTPiP] PiP 出错，停止播放")
        stopPiP()

        // 发送错误通知，由上层决定是否降级到其他方案
        NotificationCenter.default.post(name: .vboxVTPiPFailed, object: nil)
    }

    /// 激活音频会话（PiP 必须有音频会话才能启动）
    /// 注意：只激活，不停用 - 音频会话由主播放器统一管理
    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            print("[VTPiP] 音频会话已激活")
        } catch {
            print("[VTPiP] 音频会话激活失败: \(error)")
        }
    }

    // MARK: - 后台任务管理

    private func startBackgroundTask() {
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "VTPiPManager") { [weak self] in
            guard let self else { return }
            if self.backgroundTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(self.backgroundTaskId)
                self.backgroundTaskId = .invalid
            }
        }
        print("[VTPiP] 后台任务已启动")
    }
}

// MARK: - VTDecoderSessionDelegate

extension VTPiPManager: VTDecoderSessionDelegate {
    nonisolated func decoderSession(_ session: VTDecoderSession, didOutputFrame pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        Task { @MainActor in
            guard let displayLayer = self.displayLayer else { return }

            // 将 CVPixelBuffer 包装成 CMSampleBuffer
            guard let sampleBuffer = createSampleBuffer(from: pixelBuffer, presentationTimeStamp: presentationTimeStamp) else {
                return
            }

            // 送入显示层
            if displayLayer.isReadyForMoreMediaData {
                displayLayer.enqueue(sampleBuffer)
            }

            // 更新 pendingFrameCount（递减）
            self.processingQueue.async { [weak self] in
                guard let self else { return }
                if self.pipelineState.pendingFrameCount > 0 {
                    self.pipelineState.pendingFrameCount -= 1
                }
                self.pipelineState.decodedFrameCount += 1
            }

            // 第一帧后尝试启动 PiP
            if !hasEnqueuedFirstFrame {
                hasEnqueuedFirstFrame = true
                print("[VTPiP] 首帧已解码并推送，尝试启动 PiP...")
                tryStartPiP()
            }
        }
    }

    nonisolated func decoderSession(_ session: VTDecoderSession, didFailWithError error: Error) {
        print("[VTPiP] 解码错误: \(error.localizedDescription)")
        Task { @MainActor in
            // 单帧解码错误不一定要终止整个 PiP，这里先打印日志
            // 如果连续出错再考虑终止
            print("[VTPiP] 解码帧错误，继续尝试...")
        }
    }

    /// 将 CVPixelBuffer 包装为 CMSampleBuffer
    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) -> CMSampleBuffer? {
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30), // 估算帧间隔
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )

        // 根据 pixelBuffer 创建 format description
        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )

        guard status == noErr, let format = formatDesc else {
            return nil
        }

        let createStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        guard createStatus == noErr, let buffer = sampleBuffer else {
            return nil
        }

        return buffer
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension VTPiPManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPipActive = true
            print("[VTPiP] 画中画已启动")
            NotificationCenter.default.post(name: .vboxVTPiPStatusChanged, object: true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPipActive = false
            print("[VTPiP] 画中画已停止")
            NotificationCenter.default.post(name: .vboxVTPiPStatusChanged, object: false)
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error) {
        print("[VTPiP] 画中画启动失败: \(error.localizedDescription)")
        Task { @MainActor in
            self.handlePiPError()
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

@available(iOS 15.0, *)
extension VTPiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool) {
        // 播放/暂停控制：流式播放忽略，由主播放器控制
        print("[VTPiP] PiP 播放状态变更: \(playing)")
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // 返回一个较大的时间范围（模拟直播/流式播放）
        return CMTimeRange(start: .zero, duration: CMTime(value: 3600 * 24, timescale: 1))
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return false // 始终播放
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        // PiP 窗口尺寸变化
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipBy skipInterval: CMTime) async {
        // 快进/快退：流式播放不支持，忽略
        print("[VTPiP] PiP skipBy 请求: \(skipInterval.seconds)s，流式播放不支持")
    }
}

// MARK: - 下载代理

/// VTPiP 专用的 URLSession 流式下载代理
private final class VTPiPStreamDelegate: NSObject, URLSessionDataDelegate {
    let queue: DispatchQueue
    let onDataReceived: (Data) -> Void
    let onComplete: () -> Void
    let onError: (Error?) -> Void

    weak var associatedTask: URLSessionDataTask?

    init(queue: DispatchQueue,
         onDataReceived: @escaping (Data) -> Void,
         onComplete: @escaping () -> Void,
         onError: @escaping (Error?) -> Void) {
        self.queue = queue
        self.onDataReceived = onDataReceived
        self.onComplete = onComplete
        self.onError = onError
        super.init()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async { [weak self] in
            self?.onDataReceived(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async { [weak self] in
            if let error = error {
                self?.onError(error)
            } else {
                self?.onComplete()
            }
        }
    }
}
