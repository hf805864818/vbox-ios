import Foundation
import QuartzCore
import UIKit
import Metal
import CoreVideo
import AVFoundation

#if canImport(Libmpv)
import Libmpv

final class LibmpvMoltenVKRenderView: UIView {
    let metalLayer = MPVKitMetalLayer()
    private var gravityObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit {
        if let observer = gravityObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer.frame = bounds
        metalLayer.contentsScale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        metalLayer.drawableSize = CGSize(
            width: max(CGFloat(1), bounds.width * metalLayer.contentsScale),
            height: max(CGFloat(1), bounds.height * metalLayer.contentsScale)
        )
    }

    private func configure() {
        backgroundColor = .black
        isOpaque = true
        clipsToBounds = true
        metalLayer.frame = bounds
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false  // 必须为 false 才能读取像素
        metalLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(metalLayer)
        // 不在 configure() 中调用 applyVideoGravity：
        // applyVideoGravity 内部访问 LibmpvMoltenVKPlayerCore.shared，
        // 而单例初始化期间正在创建本视图，会导致 dispatch_once 递归死锁崩溃。
        // gravity 模式将在 attach() 完成后由 syncVideoGravity 或通知触发设置。
        gravityObserver = NotificationCenter.default.addObserver(
            forName: .vboxVideoGravityChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let mode = note.userInfo?["mode"] as? PlayerState.VideoGravityMode else { return }
            self?.applyVideoGravity(mode)
        }
    }

    private func applyVideoGravity(_ mode: PlayerState.VideoGravityMode) {
        // 通过 MPV 属性控制画面拉伸（运行时切换，必须用 mpv_set_property_string）
        // contentsGravity 对 CAMetalLayer 无效，因为 drawableSize == layer 尺寸
        LibmpvMoltenVKPlayerCore.shared.setMPVProperty("keepaspect", mode == .resize ? "no" : "yes")
        LibmpvMoltenVKPlayerCore.shared.setMPVProperty("panscan", mode == .aspectFill ? "1.0" : "0")
        print("[MPV-MoltenVK] 屏幕拉伸模式切换为：\(mode.rawValue)")
    }

    /// 由外部（attach 后）调用，同步初始 gravity 模式
    func syncVideoGravity(_ mode: PlayerState.VideoGravityMode) {
        applyVideoGravity(mode)
    }
}

final class LibmpvMoltenVKPlayerCore: NSObject {

    /// 全局共享实例，用于应用内小窗和全屏之间复用同一个 mpv 上下文
    static let shared = LibmpvMoltenVKPlayerCore()

    // MARK: - PiP 帧捕获属性

    /// PiP 帧捕获开关
    private var isPipCapturing = false
    /// 帧捕获定时器（DispatchSourceTimer，后台仍可触发）
    private var captureTimer: DispatchSourceTimer?
    /// 帧捕获计数器（节流用）
    private var frameCaptureCounter: Int = 0
    /// 帧捕获间隔（每 N 帧捕获一次）
    private let frameCaptureInterval: Int = 3
    /// 是否已打印首帧捕获日志（避免刷屏）
    private var hasLoggedFirstBlitFrame = false
    /// Metal 纹理缓存，用于 CVPixelBuffer <-> MTLTexture
    private var pipTextureCache: CVMetalTextureCache?
    /// Metal 命令队列
    private var pipCommandQueue: MTLCommandQueue?
    /// 上次捕获的 drawable 序列号，用于跳过重复帧（避免对同一帧多次 blit）
    private var lastCapturedSequence: Int = 0
    /// 后台任务标识，确保 App 进入后台后定时器仍能触发
    private var pipBackgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    /// 诊断日志计数器（每 30 次定时器回调输出一次状态）
    private var diagLogCounter: Int = 0

    enum PlaybackProfile: String {
        case hlsFast = "MoltenVK HLS极速"
        case hlsQuality = "MoltenVK HLS高清"
        case hlsFMP4 = "MoltenVK HLS-fMP4兼容"
        case mp4 = "MoltenVK普通文件"
        case mkvLarge = "MoltenVK MKV大文件"
        case httpStream = "MoltenVK HTTP流媒体"
        case generic = "MoltenVK通用"
    }

    var onLog: ((String) -> Void)?
    var onStateChange: ((PlayerEngineState) -> Void)?

    private(set) var state = PlayerEngineState()
    let renderView = LibmpvMoltenVKRenderView()
    private weak var containerView: UIView?
    private var mpv: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "app.vbox.libmpv.moltenvk-events", qos: .userInitiated)
    private var isShuttingDown = false

    /// 供悬浮窗使用的渲染视图
    var videoRenderView: UIView { renderView }

    /// 当前是否有活跃的 mpv 实例
    var hasActivePlayback: Bool { mpv != nil && !isShuttingDown }

    /// 当前播放状态（只读）
    var currentState: PlayerEngineState { state }

    deinit {
        teardown()
        captureTimer?.cancel()
    }

    // MARK: - PiP 帧捕获控制

    /// 启动 PiP 帧捕获（Metal 纹理 blit 模式）
    /// 使用 DispatchSourceTimer 替代 CADisplayLink，确保 App 进入后台后仍能持续推帧
    func startPiPCapture() {
        guard !isPipCapturing else { return }
        isPipCapturing = true
        frameCaptureCounter = 0
        diagLogCounter = 0

        if captureTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100))  // 10fps
            timer.setEventHandler { [weak self] in
                self?.captureFrameTick()
            }
            timer.resume()
            captureTimer = timer
        }

        // 申请后台任务，确保 App 进入后台后定时器仍能触发（audio 后台模式 + 额外保障）
        if pipBackgroundTaskId == .invalid {
            pipBackgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "MPVPiPCapture") { [weak self] in
                self?.endPiPBackgroundTask()
            }
        }

        log("[PiP] 帧捕获已启动（DispatchSourceTimer + Metal blit 模式），bgTask=\(pipBackgroundTaskId)")
    }

    /// 停止 PiP 帧捕获
    func stopPiPCapture() {
        isPipCapturing = false
        captureTimer?.cancel()
        captureTimer = nil
        frameCaptureCounter = 0
        lastCapturedSequence = 0
        hasLoggedFirstBlitFrame = false
        diagLogCounter = 0
        // 清理 Metal 纹理缓存，释放缓存的 CVMetalTexture 条目
        if let cache = pipTextureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
        endPiPBackgroundTask()
        log("[PiP] 帧捕获已停止")
    }

    /// 结束后台任务
    private func endPiPBackgroundTask() {
        if pipBackgroundTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(pipBackgroundTaskId)
            pipBackgroundTaskId = .invalid
        }
    }

    /// 强制捕获一帧（不依赖定时器，App 进入后台前调用）
    func forceCaptureFrame() {
        guard isPipCapturing, !isShuttingDown else { return }
        guard state.width > 0, state.height > 0 else { return }
        Task { @MainActor [weak self] in
            self?.captureFrameViaMetalBlit()
        }
    }

    /// 定时器回调：定期捕获帧
    private func captureFrameTick() {
        guard isPipCapturing, !isShuttingDown else { return }
        guard state.width > 0, state.height > 0 else { return }

        // 诊断日志：每 30 次回调（约 3 秒）输出一次 drawable 序列号，
        // 用于判断 MPV 在后台是否仍在渲染新帧
        diagLogCounter += 1
        if diagLogCounter >= 30 {
            diagLogCounter = 0
            let seq = renderView.metalLayer.drawableSequence
            let hasDrawable = renderView.metalLayer.lastDrawable != nil
            let isPlaying = state.isPlaying
            log("[PiP] 诊断：drawableSeq=\(seq), lastCaptured=\(lastCapturedSequence), hasDrawable=\(hasDrawable), isPlaying=\(isPlaying), isBg=\(UIApplication.shared.applicationState != .active)")
        }

        frameCaptureCounter += 1
        guard frameCaptureCounter >= frameCaptureInterval else { return }
        frameCaptureCounter = 0

        Task { @MainActor [weak self] in
            self?.captureFrameViaMetalBlit()
        }
    }

    /// 通过 Metal 纹理 blit 捕获当前帧，避免 CPU 截图和 CGImage 转换。
    /// 源：MPVKitMetalLayer 最近一次返回的 drawable texture
    /// 目标：CVPixelBuffer backed Metal texture（每帧从 pool 获取新缓冲，避免重用冲突）
    ///
    /// 关键设计：
    /// 1. 每帧从 pool 获取新的 CVPixelBuffer，不复用单个 buffer（避免 display layer
    ///    读取旧帧时被新帧 blit 覆写导致画面冻结）
    /// 2. commit 后立即 enqueue（不用 addCompletedHandler，因为后台 Metal 命令缓冲区
    ///    可能永远不完成，导致闭包泄漏 pixelBuffer、命令队列堆积、主线程阻塞）
    /// 3. drawableSequence 仅用于诊断日志，不跳过帧（后台时 MPV 可能不渲染新帧，
    ///    但仍需推送旧帧保持 PiP 画面存活）
    /// 4. 每帧创建新的 CVMetalTexture（因为 pixelBuffer 每帧不同，不能缓存 texture）
    @MainActor
    private func captureFrameViaMetalBlit() {
        // 延迟初始化 Metal 资源（在 @MainActor 中安全访问 renderView.metalLayer）
        if pipCommandQueue == nil || pipTextureCache == nil {
            let device = renderView.metalLayer.device ?? MTLCreateSystemDefaultDevice()
            if let device {
                pipCommandQueue = device.makeCommandQueue()
                var cache: CVMetalTextureCache?
                let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
                if status == kCVReturnSuccess {
                    pipTextureCache = cache
                }
            }
        }

        guard let pipTextureCache, let pipCommandQueue else { return }

        let metalLayer = renderView.metalLayer
        guard let sourceDrawable = metalLayer.lastDrawable else { return }
        let sourceTexture = sourceDrawable.texture

        let width = sourceTexture.width
        let height = sourceTexture.height
        guard width > 0, height > 0 else { return }

        // 每帧获取新的 pixelBuffer（从 pool 或手动创建），避免重用导致数据竞争
        guard let pixelBuffer = createPiPPixelBuffer(width: width, height: height) else { return }
        guard CVPixelBufferGetWidth(pixelBuffer) == width,
              CVPixelBufferGetHeight(pixelBuffer) == height else { return }

        // 为每个新的 pixelBuffer 创建 Metal 纹理（不能缓存，因为 buffer 每帧不同）
        var cvTexture: CVMetalTexture?
        let texStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            pipTextureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard texStatus == kCVReturnSuccess, let cvTexture else { return }
        guard let destinationTexture = CVMetalTextureGetTexture(cvTexture) else { return }

        guard let commandBuffer = pipCommandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            // 命令缓冲区创建失败（可能命令队列积压），跳过本帧
            return
        }

        let sourceSize = MTLSize(width: width, height: height, depth: 1)
        blitEncoder.copy(from: sourceTexture,
                         sourceSlice: 0,
                         sourceLevel: 0,
                         sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                         sourceSize: sourceSize,
                         to: destinationTexture,
                         destinationSlice: 0,
                         destinationLevel: 0,
                         destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blitEncoder.endEncoding()
        commandBuffer.commit()

        // 同步等待 blit 完成（确保 pixelBuffer 中的数据完整后再 enqueue）。
        // waitUntilCompleted 在主线程上会短暂阻塞，但 Metal blit 操作极快（<1ms），
        // 远比 addCompletedHandler 的异步回调安全可靠（后者在后台可能永远不触发）。
        commandBuffer.waitUntilCompleted()

        // blit 完成后立即入队，cvTexture 通过 withExtendedLifetime 保持存活直到 enqueue 完成
        let presentationTime = CMTime(value: Int64(state.currentTime * 1000), timescale: 1000)
        withExtendedLifetime(cvTexture) {
            MPVPiPManager.shared.enqueueFrame(pixelBuffer, presentationTime: presentationTime)
        }

        let currentSeq = metalLayer.drawableSequence
        lastCapturedSequence = currentSeq
        if !hasLoggedFirstBlitFrame {
            hasLoggedFirstBlitFrame = true
            log("[PiP] 首帧 Metal blit 已推送：\(width)x\(height)，drawableSeq=\(currentSeq)")
        }
    }

    /// 创建或获取 PiP 目标 CVPixelBuffer，优先使用 MPVPiPManager 的 pool
    @MainActor
    private func createPiPPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if let poolBuffer = MPVPiPManager.shared.createPixelBufferFromPool() {
            if CVPixelBufferGetWidth(poolBuffer) == width,
               CVPixelBufferGetHeight(poolBuffer) == height {
                return poolBuffer
            }
        }

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        return status == kCVReturnSuccess ? pixelBuffer : nil
    }

    // MARK: - 公开方法

    func attach(to view: UIView) {
        guard !isShuttingDown else { return }
        containerView = view
        if renderView.superview !== view {
            renderView.removeFromSuperview()
            renderView.frame = view.bounds
            renderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(renderView)
            view.layoutIfNeeded()
        }

        if renderView.metalLayer.device == nil {
            renderView.metalLayer.device = MTLCreateSystemDefaultDevice()
        }

        if renderView.metalLayer.drawableSize.width <= 1 || renderView.metalLayer.drawableSize.height <= 1 {
            renderView.metalLayer.drawableSize = CGSize(width: 2, height: 2)
        }

        if mpv == nil {
            setupMPV()
        }
    }

    func load(url: URL, headers: [String: String] = [:], profile explicitProfile: PlaybackProfile? = nil) {
        guard !isShuttingDown else { return }
        if mpv == nil {
            setupMPV()
        }

        guard mpv != nil else {
            fail("Libmpv-MoltenVK内核初始化失败")
            return
        }

        applyHTTPOptions(headers: headers)
        applyPlaybackOptions(for: url, profile: explicitProfile)
        command("loadfile", args: [url.absoluteString, "replace"])
        state.errorMessage = nil
        state.isEnded = false
        log("MoltenVK加载：\(url.absoluteString)")
        emitState()
    }

    func play() {
        guard !isShuttingDown else { return }
        setFlag(MPVKitProperty.pause, false)
        state.isPlaying = true
        state.isEnded = false
        emitState()
    }

    func pause() {
        guard !isShuttingDown else { return }
        setFlag(MPVKitProperty.pause, true)
        state.isPlaying = false
        emitState()
    }

    func stop() {
        guard !isShuttingDown else { return }
        command("stop", checkForErrors: false)
        state.isPlaying = false
        state.currentTime = 0
        emitState()
    }

    func seek(to seconds: Double) {
        guard !isShuttingDown else { return }
        command("seek", args: [String(seconds), "absolute"])
    }

    func togglePause() {
        guard !isShuttingDown else { return }
        command(state.isPlaying ? "set pause yes" : "set pause no")
    }

    func seekRelative(seconds: Double) {
        guard !isShuttingDown else { return }
        command("seek", args: [String(seconds), "relative"])
    }

    func setRate(_ rate: Double) {
        guard !isShuttingDown else { return }
        guard let handle = mpv else { return }
        var value = rate
        check(mpv_set_property(handle, "speed", MPV_FORMAT_DOUBLE, &value), context: "speed")
    }

    func setVolume(_ volume: Double) {
        guard !isShuttingDown else { return }
        guard let handle = mpv else { return }
        var value = min(max(volume, 0), 1) * 100
        check(mpv_set_property(handle, "volume", MPV_FORMAT_DOUBLE, &value), context: "volume")
    }

    func teardown() {
        guard !isShuttingDown || mpv != nil else { return }
        isShuttingDown = true
        onLog = nil
        onStateChange = nil

        // 停止帧捕获
        stopPiPCapture()

        if let handle = mpv {
            mpv_set_wakeup_callback(handle, nil, nil)
            eventQueue.sync {}
            command("stop", checkForErrors: false)
            mpv_terminate_destroy(handle)
            mpv = nil
        }
        renderView.removeFromSuperview()
        state = PlayerEngineState()
    }

    private func setupMPV() {
        guard mpv == nil, containerView != nil else { return }
        isShuttingDown = false
        guard let handle = mpv_create() else {
            fail("mpv_create失败")
            return
        }
        mpv = handle

        #if DEBUG
        check(mpv_request_log_messages(handle, "info"), context: "request_log_messages")
        #else
        check(mpv_request_log_messages(handle, "warn"), context: "request_log_messages")
        #endif

        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(renderView.metalLayer).toOpaque()))
        check(mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid), context: "wid")
        setOption("config", "no")
        setOption("terminal", "no")
        setOption("vo", "gpu-next")
        setOption("gpu-api", "vulkan")
        setOption("gpu-context", "moltenvk")
        setOption("hwdec", "videotoolbox")
        setOption("video-rotate", "no")
        setOption("cache", "yes")
        setOption("keep-open", "no")
        setOption("subs-match-os-language", "yes")
        setOption("subs-fallback", "yes")

        let code = mpv_initialize(handle)
        guard code >= 0 else {
            fail("mpv_initialize失败：\(String(cString: mpv_error_string(code)))")
            mpv_terminate_destroy(handle)
            mpv = nil
            return
        }

        observe(MPVKitProperty.timePos, format: MPV_FORMAT_DOUBLE)
        observe(MPVKitProperty.duration, format: MPV_FORMAT_DOUBLE)
        observe(MPVKitProperty.pause, format: MPV_FORMAT_FLAG)
        observe(MPVKitProperty.pausedForCache, format: MPV_FORMAT_FLAG)
        observe(MPVKitProperty.eofReached, format: MPV_FORMAT_FLAG)
        observe(MPVKitProperty.videoWidth, format: MPV_FORMAT_INT64)
        observe(MPVKitProperty.videoHeight, format: MPV_FORMAT_INT64)
        observe("core-idle", format: MPV_FORMAT_FLAG)
        observe("demuxer-cache-time", format: MPV_FORMAT_DOUBLE)
        observe("cache-buffering-state", format: MPV_FORMAT_DOUBLE)

        mpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            let player = Unmanaged<LibmpvMoltenVKPlayerCore>.fromOpaque(context).takeUnretainedValue()
            player.readEvents()
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))

        log("Libmpv-MoltenVK内核初始化完成")
    }

    private func readEvents() {
        eventQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isShuttingDown else { return }
            while let handle = self.mpv {
                if self.isShuttingDown { break }
                guard let event = mpv_wait_event(handle, 0) else { break }
                if event.pointee.event_id == MPV_EVENT_NONE { break }
                if self.isShuttingDown { break }
                self.handle(event: event.pointee)
            }
        }
    }

    private func handle(event: mpv_event) {
        guard !isShuttingDown else { return }
        switch event.event_id {
        case MPV_EVENT_FILE_LOADED:
            DispatchQueue.main.async { [weak self] in self?.log("file-loaded") }
        case MPV_EVENT_VIDEO_RECONFIG:
            DispatchQueue.main.async { [weak self] in self?.log("video-reconfig") }
        case MPV_EVENT_PLAYBACK_RESTART:
            DispatchQueue.main.async { [weak self] in self?.log("playback-restart") }
        case MPV_EVENT_END_FILE:
            let summary = endFileSummary(event: event)
            DispatchQueue.main.async { [weak self] in
                self?.state.isPlaying = false
                self?.log(summary)
                self?.emitState()
            }
        case MPV_EVENT_PROPERTY_CHANGE:
            handlePropertyChange(event: event)
        case MPV_EVENT_LOG_MESSAGE:
            guard let data = event.data else { return }
            let message = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(data))
            let prefix = message.pointee.prefix.map { String(cString: $0) } ?? "mpv"
            let level = message.pointee.level.map { String(cString: $0) } ?? "log"
            let text = message.pointee.text.map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            if !text.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.log("[\(prefix)] \(level): \(text)")
                }
            }
        default:
            if let name = mpv_event_name(event.event_id) {
                let eventName = String(cString: name)
                DispatchQueue.main.async { [weak self] in self?.log("event: \(eventName)") }
            }
        }
    }

    private func endFileSummary(event: mpv_event) -> String {
        guard let data = event.data,
              let endFile = UnsafePointer<mpv_event_end_file>(OpaquePointer(data))?.pointee else {
            return "end-file"
        }

        return "end-file reason=\(endFile.reason) error=\(endFile.error)"
    }

    private func handlePropertyChange(event: mpv_event) {
        guard !isShuttingDown else { return }
        guard let data = event.data else { return }
        let property = UnsafePointer<mpv_event_property>(OpaquePointer(data))?.pointee
        guard let property, let namePointer = property.name else { return }
        let name = String(cString: namePointer)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.isShuttingDown else { return }
            switch name {
            case MPVKitProperty.timePos:
                if let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
                    self.state.currentTime = value
                }
            case MPVKitProperty.duration:
                if let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
                    self.state.duration = value
                }
            case MPVKitProperty.pause:
                if let paused = self.readFlag(property.data) {
                    self.state.isPlaying = !paused
                }
            case MPVKitProperty.pausedForCache:
                if let buffering = self.readFlag(property.data) {
                    self.state.isBuffering = buffering
                }
            case MPVKitProperty.eofReached:
                if let ended = self.readFlag(property.data), ended {
                    self.state.isPlaying = false
                    self.state.isEnded = true
                }
            case MPVKitProperty.videoWidth:
                if let value = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee {
                    self.state.width = Int(value)
                }
            case MPVKitProperty.videoHeight:
                if let value = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee {
                    self.state.height = Int(value)
                }
            default:
                break
            }
            self.emitState()
        }
    }

    private func applyHTTPOptions(headers: [String: String]) {
        guard !headers.isEmpty else { return }
        if let userAgent = headers.first(where: { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame })?.value {
            setOption("user-agent", userAgent)
        }
        if let referer = headers.first(where: { $0.key.caseInsensitiveCompare("Referer") == .orderedSame || $0.key.caseInsensitiveCompare("Referrer") == .orderedSame })?.value {
            setOption("referrer", referer)
        }
        let headerFields = headers
            .filter { key, _ in
                key.caseInsensitiveCompare("User-Agent") != .orderedSame &&
                key.caseInsensitiveCompare("Referer") != .orderedSame &&
                key.caseInsensitiveCompare("Referrer") != .orderedSame
            }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ",")
        if !headerFields.isEmpty {
            setOption("http-header-fields", headerFields)
        }
    }

    private func applyPlaybackOptions(for url: URL, profile explicitProfile: PlaybackProfile?) {
        let profile = explicitProfile ?? inferredProfile(for: url)
        log("应用参数：\(profile.rawValue)")

        switch profile {
        case .hlsFast:
            setOption("cache", "yes")
            setOption("cache-secs", "1")
            setOption("demuxer-readahead-secs", "1")
            setOption("network-timeout", "8")
            setOption("hls-bitrate", "min")
            setOption("hwdec", "videotoolbox")
        case .hlsQuality:
            setOption("cache", "yes")
            setOption("cache-secs", "3")
            setOption("demuxer-readahead-secs", "2")
            setOption("network-timeout", "10")
            setOption("hls-bitrate", "max")
            setOption("hwdec", "videotoolbox")
        case .hlsFMP4:
            setOption("cache", "yes")
            setOption("cache-pause", "no")
            setOption("cache-pause-initial", "no")
            setOption("demuxer-cache-wait", "no")
            setOption("cache-secs", "1")
            setOption("demuxer-readahead-secs", "1")
            setOption("demuxer-max-bytes", "8MiB")
            setOption("demuxer-max-back-bytes", "1MiB")
            setOption("demuxer-lavf-analyzeduration", "0.5")
            setOption("demuxer-lavf-probesize", "262144")
            setOption("network-timeout", "12")
            setOption("hls-bitrate", "min")
            setOption("hwdec", "no")
        case .mkvLarge:
            setOption("cache", "yes")
            setOption("network-timeout", "15")
            setOption("hwdec", "videotoolbox")
        case .httpStream:
            // 百度/夸克等网盘HTTP流媒体专用：seek后快速恢复播放
            setOption("cache", "yes")
            setOption("cache-secs", "10")
            setOption("demuxer-readahead-secs", "5")
            setOption("demuxer-max-bytes", "64MiB")
            setOption("demuxer-max-back-bytes", "8MiB")
            setOption("cache-pause", "no")
            setOption("cache-pause-initial", "no")
            setOption("demuxer-cache-wait", "no")
            setOption("network-timeout", "15")
            setOption("hwdec", "videotoolbox")
        case .mp4, .generic:
            setOption("cache", "yes")
            setOption("cache-secs", "3")
            setOption("demuxer-readahead-secs", "1")
            setOption("demuxer-max-bytes", "32MiB")
            setOption("demuxer-max-back-bytes", "8MiB")
            setOption("network-timeout", "10")
            setOption("hwdec", "videotoolbox")
        }
    }

    private func inferredProfile(for url: URL) -> PlaybackProfile {
        let text = url.absoluteString.lowercased()
        let ext = url.pathExtension.lowercased()
        // 百度/夸克网盘HTTP流媒体（通过本地代理的baidu-stream/quark-stream）
        if text.contains("baidu-stream") || text.contains("quark-stream") { return .httpStream }
        if ext == "m3u8" { return .hlsFast }
        if ext == "mkv" { return .mkvLarge }
        if ext == "mp4" || ext == "m4v" || ext == "mov" { return .mp4 }
        return .generic
    }

    private func command(_ command: String, args: [String] = [], checkForErrors: Bool = true) {
        guard !isShuttingDown || command == "stop" else { return }
        guard let handle = mpv else { return }
        let values: [String?] = [command] + args + [nil]
        var cargs = values.map { value -> UnsafePointer<CChar>? in
            guard let value else { return nil }
            return UnsafePointer<CChar>(strdup(value))
        }
        defer {
            for pointer in cargs where pointer != nil {
                free(UnsafeMutablePointer(mutating: pointer!))
            }
        }
        let code = mpv_command(handle, &cargs)
        if checkForErrors {
            check(code, context: command)
        }
    }

    private func setOption(_ name: String, _ value: String) {
        guard !isShuttingDown else { return }
        guard let handle = mpv else { return }
        check(mpv_set_option_string(handle, name, value), context: name)
    }

    /// 运行时设置 MPV 属性（mpv_initialize 之后使用，setOption 仅在初始化前有效）
    func setMPVProperty(_ name: String, _ value: String) {
        guard !isShuttingDown else { return }
        guard let handle = mpv else { return }
        let result = mpv_set_property_string(handle, name, value)
        if result < 0 {
            log("[MPV] set_property(\(name)=\(value)) 失败：\(String(cString: mpv_error_string(result)))")
        }
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard !isShuttingDown else { return }
        guard let handle = mpv else { return }
        var data: Int32 = value ? 1 : 0
        check(mpv_set_property(handle, name, MPV_FORMAT_FLAG, &data), context: name)
    }

    private func observe(_ name: String, format: mpv_format) {
        guard !isShuttingDown else { return }
        guard let handle = mpv else { return }
        check(mpv_observe_property(handle, 0, name, format), context: "observe \(name)")
    }

    private func readFlag(_ pointer: UnsafeMutableRawPointer?) -> Bool? {
        guard let pointer else { return nil }
        return UnsafePointer<Int32>(OpaquePointer(pointer))?.pointee != 0
    }

    private func check(_ code: CInt, context: String) {
        if code < 0 {
            log("\(context)：\(String(cString: mpv_error_string(code)))")
        }
    }

    private func fail(_ message: String) {
        guard !isShuttingDown else { return }
        state.errorMessage = message
        log(message)
        emitState()
    }

    private func log(_ message: String) {
        onLog?(message)
    }

    private func emitState() {
        onStateChange?(state)
    }
}
#else
final class LibmpvMoltenVKPlayerCore {
    enum PlaybackProfile {
        case hlsFast
        case hlsQuality
        case hlsFMP4
        case mp4
        case mkvLarge
        case generic
    }
}
#endif
