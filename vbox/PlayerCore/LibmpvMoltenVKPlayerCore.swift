import Foundation
import QuartzCore
import UIKit
import Metal
import CoreVideo
import AVFoundation
import GLKit
import OpenGLES

#if canImport(Libmpv)
import Libmpv

// MARK: - 播放器核心

/// 使用 GLKView + OpenGL ES + mpv_render_context 渲染 MPV 视频。
/// 关键变更：从 CAMetalLayer（wid 模式）切换到 mpv_render_context（OpenGL ES），
/// 以获得对渲染时机的完全控制——后台时可通过定时器主动调用 mpv_render_context_render()
/// 渲染新帧到离屏 FBO，解决画中画画面冻结问题。
final class LibmpvMoltenVKPlayerCore: NSObject {

    /// 全局共享实例，用于应用内小窗和全屏之间复用同一个 mpv 上下文
    static let shared = LibmpvMoltenVKPlayerCore()

    // MARK: - PiP 帧捕获属性（OpenGL ES 离屏 FBO 模式）

    /// PiP 帧捕获开关
    private var isPipCapturing = false
    /// 帧捕获定时器（DispatchSourceTimer，后台仍可触发）
    private var captureTimer: DispatchSourceTimer?
    /// 帧捕获计数器（节流用）
    private var frameCaptureCounter: Int = 0
    /// 帧捕获间隔（每 N 次定时器回调捕获一次）
    private let frameCaptureInterval: Int = 2
    /// 是否已打印首帧捕获日志（避免刷屏）
    private var hasLoggedFirstCaptureFrame = false
    /// 后台任务标识，确保 App 进入后台后定时器仍能触发
    private var pipBackgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    /// 诊断日志计数器
    private var diagLogCounter: Int = 0

    // MARK: - 离屏 FBO 属性

    /// 离屏 FBO ID（用于 PiP 后台帧捕获）
    private var offscreenFBO: GLuint = 0
    /// 离屏 FBO 关联的颜色 Renderbuffer
    private var offscreenColorBuffer: GLuint = 0
    /// 离屏 FBO 关联的深度 Renderbuffer
    private var offscreenDepthBuffer: GLuint = 0
    /// 离屏 FBO 的尺寸（视频原始尺寸）
    private var offscreenSize: CGSize = .zero
    /// 离屏 FBO 是否已就绪
    private var isOffscreenReady = false

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

    /// time-pos 回调节流：MPV 播放时 time-pos 每秒触发 30-60 次，
    /// 每次 emitState() 都会触发 SwiftUI @Published 属性变更和视图重算，
    /// 导致 wakeups 超限（>150/秒）被系统杀进程。
    /// 节流到每 200ms（5 次/秒）emit 一次，进度条刷新足够流畅。
    private var lastTimePosEmitAt: Date = .distantPast
    private let timePosEmitInterval: TimeInterval = 0.2

    /// EAGLContext，OpenGL ES 渲染上下文（lazy，首次访问时创建）
    private lazy var eaglContext: EAGLContext? = {
        EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2)
    }()

    /// GLKView 渲染视图（lazy，依赖 eaglContext）
    /// 修复: 不再使用 eaglContext! 强制解包，避免从 MDK(Metal) 切换到 MPV(OpenGL ES) 时上下文冲突导致闪退
    private var _renderView: GLKView?
    private var renderView: GLKView {
        if _renderView == nil {
            guard let ctx = eaglContext else {
                // EAGLContext 创建失败（设备不支持或上下文冲突），返回空视图避免崩溃
                let fallback = GLKView()
                fallback.backgroundColor = .black
                _renderView = fallback
                return fallback
            }
            let view = GLKView(frame: .zero, context: ctx)
            view.backgroundColor = .black
            view.isOpaque = true
            view.clipsToBounds = true
            view.enableSetNeedsDisplay = true
            _renderView = view
        }
        return _renderView!
    }

    /// 画面拉伸模式观察者
    private var gravityObserver: NSObjectProtocol?

    private weak var containerView: UIView?
    private var mpv: OpaquePointer?
    /// mpv_render_context，用于主动控制渲染（替代 wid 模式）
    private var renderContext: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "app.vbox.libmpv.moltenvk-events", qos: .userInitiated)
    private var isShuttingDown = false
    /// 防止 teardown 尚未完成时 attach 重入导致 mpv_create 闪退
    private let attachLock = NSLock()

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

    /// 启动 PiP 帧捕获（OpenGL ES 离屏 FBO 模式）
    /// 使用 DispatchSourceTimer + mpv_render_context_render()，确保 App 进入后台后
    /// 仍能主动渲染新帧到离屏 FBO 并推送到 PiP displayLayer。
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

        // 申请后台任务，确保 App 进入后台后定时器仍能触发
        if pipBackgroundTaskId == .invalid {
            pipBackgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "MPVPiPCapture") { [weak self] in
                self?.endPiPBackgroundTask()
            }
        }

        log("[PiP] 帧捕获已启动（DispatchSourceTimer + OpenGL ES 离屏 FBO 模式），bgTask=\(pipBackgroundTaskId)")
    }

    /// 停止 PiP 帧捕获
    func stopPiPCapture() {
        isPipCapturing = false
        captureTimer?.cancel()
        captureTimer = nil
        frameCaptureCounter = 0
        hasLoggedFirstCaptureFrame = false
        diagLogCounter = 0
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
            self?.captureFrameViaOffscreenFBO()
        }
    }

    /// 定时器回调：定期通过离屏 FBO 捕获帧
    private func captureFrameTick() {
        guard isPipCapturing, !isShuttingDown else { return }
        guard state.width > 0, state.height > 0 else { return }

        // P0 修复：播放暂停时跳过帧捕获，避免主线程阻塞导致返回 App 时卡死。
        // 当用户在 PiP 窗口按暂停按钮 → vboxPiPTogglePlayPause 通知
        // → playerState.togglePlayback() → core.pause() → state.isPlaying = false
        // 此时 captureTimer 仍在运行但不再捕获帧，画面停留在最后一帧。
        // 用户按播放按钮后 state.isPlaying 恢复为 true，帧捕获自动恢复。
        guard state.isPlaying else { return }

        // 诊断日志：每 30 次回调（约 3 秒）输出一次状态
        diagLogCounter += 1
        if diagLogCounter >= 30 {
            diagLogCounter = 0
            let isPlaying = state.isPlaying
            let isBg = UIApplication.shared.applicationState != .active
            log("[PiP] 诊断：isPlaying=\(isPlaying), isBg=\(isBg), offscreenReady=\(isOffscreenReady), videoSize=\(state.width)x\(state.height)")
        }

        frameCaptureCounter += 1
        guard frameCaptureCounter >= frameCaptureInterval else { return }
        frameCaptureCounter = 0

        Task { @MainActor [weak self] in
            self?.captureFrameViaOffscreenFBO()
        }
    }

    /// 通过 OpenGL ES 离屏 FBO 捕获当前帧。
    ///
    /// 核心原理：
    /// 1. 使用 mpv_render_context_render() 将 MPV 当前帧渲染到离屏 FBO
    ///    —— 这不依赖 CADisplayLink，在后台仍可正常工作
    /// 2. 使用 glReadPixels 读取 FBO 像素数据
    /// 3. 转换为 CVPixelBuffer 并推送到 MPVPiPManager 的 displayLayer
    ///
    /// 与之前 Metal blit 方案的区别：
    /// - Metal blit 读取 CAMetalLayer.lastDrawable，后台时 display link 暂停导致
    ///   lastDrawable 永远是同一帧 → 画面冻结
    /// - 本方案主动调用 mpv_render_context_render()，强制 MPV 渲染新帧到 FBO，
    ///   不受 display link 影响 → 后台也能获得实时画面
    @MainActor
    private func captureFrameViaOffscreenFBO() {
        guard let renderContext, let eaglContext else { return }
        guard !isShuttingDown else { return }

        let videoWidth = state.width
        let videoHeight = state.height
        guard videoWidth > 0, videoHeight > 0 else { return }

        // 在主线程上设置 EAGLContext 为当前上下文
        let prevContext = EAGLContext.current()
        if prevContext !== eaglContext {
            EAGLContext.setCurrent(eaglContext)
        }

        defer {
            if prevContext !== eaglContext {
                EAGLContext.setCurrent(prevContext)
            }
        }

        let captureSize = CGSize(width: videoWidth, height: videoHeight)

        // 视频尺寸变化时重建离屏 FBO
        if offscreenSize != captureSize || !isOffscreenReady {
            setupOffscreenFBO(width: videoWidth, height: videoHeight)
        }

        guard isOffscreenReady, offscreenFBO > 0 else { return }

        // 保存当前 FBO
        var originalFBO: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &originalFBO)

        // 绑定离屏 FBO
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), offscreenFBO)

        // 使用 mpv_render_context_render() 渲染到离屏 FBO
        // 这是关键步骤：主动调用 render，不依赖 display link
        var flipY: CInt = 1
        var fboStruct = mpv_opengl_fbo(
            fbo: Int32(offscreenFBO),
            w: Int32(videoWidth),
            h: Int32(videoHeight),
            internal_format: 0
        )
        withUnsafeMutablePointer(to: &fboStruct) { fboPointer in
            withUnsafeMutablePointer(to: &flipY) { flipPointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                mpv_render_context_render(renderContext, &params)
            }
        }

        // 读取像素数据
        let bytesPerRow = videoWidth * 4
        let totalBytes = bytesPerRow * videoHeight
        let pixelData = UnsafeMutablePointer<UInt8>.allocate(capacity: totalBytes)

        glReadPixels(GLint(0), GLint(0),
                     GLsizei(videoWidth), GLsizei(videoHeight),
                     GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE),
                     pixelData)

        // 恢复原始 FBO
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLenum(originalFBO))

        // 检查 OpenGL 错误
        let glError = glGetError()
        if glError != GLenum(GL_NO_ERROR) {
            pixelData.deallocate()
            log("[PiP] glReadPixels 错误：\(glError)")
            return
        }

        // 获取 CVPixelBuffer 并拷贝像素数据（同步执行，避免 pixelData 生命周期问题）
        let currentTime = state.currentTime

        guard let pixelBuffer = MPVPiPManager.shared.createPixelBufferFromPool() else {
            pixelData.deallocate()
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            pixelData.deallocate()
        }

        guard let destBaseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return
        }

        let destBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // glReadPixels 从底部向上读取，需要垂直翻转并逐行拷贝
        for y in 0..<videoHeight {
            let srcRow = pixelData.advanced(by: y * bytesPerRow)
            let dstRow = destBaseAddress.advanced(by: (videoHeight - 1 - y) * destBytesPerRow)
            memcpy(dstRow, srcRow, min(bytesPerRow, destBytesPerRow))
        }

        let presentationTime = CMTime(
            value: Int64(currentTime * 1000),
            timescale: 1000
        )

        MPVPiPManager.shared.enqueueFrame(pixelBuffer, presentationTime: presentationTime)

        if !hasLoggedFirstCaptureFrame {
            hasLoggedFirstCaptureFrame = true
            log("[PiP] 首帧离屏 FBO 已推送：\(videoWidth)x\(videoHeight)")
        }
    }

    /// 创建离屏 FBO 和关联的 Renderbuffer
    private func setupOffscreenFBO(width: Int, height: Int) {
        guard let eaglContext else { return }
        EAGLContext.setCurrent(eaglContext)

        // 先清理旧的
        cleanupOffscreenFBO()

        let w = GLsizei(width)
        let h = GLsizei(height)

        // 创建 FBO
        glGenFramebuffers(1, &offscreenFBO)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), offscreenFBO)

        // 创建颜色 Renderbuffer
        glGenRenderbuffers(1, &offscreenColorBuffer)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), offscreenColorBuffer)
        glRenderbufferStorage(GLenum(GL_RENDERBUFFER), GLenum(GL_RGBA8_OES), w, h)
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER),
                                   GLenum(GL_COLOR_ATTACHMENT0),
                                   GLenum(GL_RENDERBUFFER),
                                   offscreenColorBuffer)

        // 创建深度 Renderbuffer
        glGenRenderbuffers(1, &offscreenDepthBuffer)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), offscreenDepthBuffer)
        glRenderbufferStorage(GLenum(GL_RENDERBUFFER), GLenum(GL_DEPTH_COMPONENT16), w, h)
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER),
                                   GLenum(GL_DEPTH_ATTACHMENT),
                                   GLenum(GL_RENDERBUFFER),
                                   offscreenDepthBuffer)

        // 检查 FBO 完整性
        let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        if status == GLenum(GL_FRAMEBUFFER_COMPLETE) {
            offscreenSize = CGSize(width: width, height: height)
            isOffscreenReady = true
            log("[PiP] 离屏FBO创建成功：\(width)x\(height)")
        } else {
            log("[PiP] 离屏FBO创建失败，状态：\(status)")
            isOffscreenReady = false
        }

        // 解绑
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), 0)
    }

    /// 清理离屏 FBO 资源
    private func cleanupOffscreenFBO() {
        guard offscreenFBO > 0 else { return }
        if let eaglContext {
            EAGLContext.setCurrent(eaglContext)
        }
        if offscreenColorBuffer > 0 {
            glDeleteRenderbuffers(1, &offscreenColorBuffer)
            offscreenColorBuffer = 0
        }
        if offscreenDepthBuffer > 0 {
            glDeleteRenderbuffers(1, &offscreenDepthBuffer)
            offscreenDepthBuffer = 0
        }
        glDeleteFramebuffers(1, &offscreenFBO)
        offscreenFBO = 0
        isOffscreenReady = false
        offscreenSize = .zero
    }

    // MARK: - 公开方法

    func attach(to view: UIView) {
        guard !isShuttingDown else { return }
        // 修复: 防止 teardown 尚未完成时 attach 重入导致 mpv_create 闪退
        attachLock.lock()
        defer { attachLock.unlock() }
        containerView = view
        if renderView.superview !== view {
            renderView.removeFromSuperview()
            renderView.frame = view.bounds
            renderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(renderView)
            view.layoutIfNeeded()
        }

        // 配置 GLKView（eaglContext 已通过 lazy 属性创建）
        guard let ctx = eaglContext else {
            fail("EAGLContext创建失败")
            return
        }
        renderView.context = ctx
        renderView.delegate = self
        EAGLContext.setCurrent(ctx)

        // 注册画面拉伸模式观察者（首次 attach 时注册）
        if gravityObserver == nil {
            gravityObserver = NotificationCenter.default.addObserver(
                forName: .vboxVideoGravityChanged,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let mode = note.userInfo?["mode"] as? PlayerState.VideoGravityMode else { return }
                self?.setMPVProperty("keepaspect", mode == .resize ? "no" : "yes")
                self?.setMPVProperty("panscan", mode == .aspectFill ? "1.0" : "0")
            }
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

        // 清理离屏 FBO
        cleanupOffscreenFBO()

        // 移除画面拉伸模式观察者
        if let observer = gravityObserver {
            NotificationCenter.default.removeObserver(observer)
            gravityObserver = nil
        }

        // 清理 render context
        if let renderContext {
            mpv_render_context_free(renderContext)
            self.renderContext = nil
        }

        if let handle = mpv {
            mpv_set_wakeup_callback(handle, nil, nil)
            eventQueue.sync {}
            command("stop", checkForErrors: false)
            mpv_terminate_destroy(handle)
            mpv = nil
        }

        renderView.delegate = nil
        renderView.removeFromSuperview()

        // 注意：不将 eaglContext 设为 nil。
        // lazy var 设为 nil 后不会重新触发初始化器，导致重新 attach 时 context 为 nil。
        // EAGLContext 可跨多个 MPV 会话复用。
        if EAGLContext.current() === eaglContext {
            EAGLContext.setCurrent(nil)
        }

        state = PlayerEngineState()

        // 修复: 延迟重置 isShuttingDown，确保 mpv_terminate_destroy 和事件循环完全停止。
        // 否则切换内核时新 attach 可能在旧 teardown 还在进行中被调用，
        // guard !isShuttingDown 直接 return，导致 mpv 未创建但上层认为已初始化。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isShuttingDown = false
        }
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

        // 关键变更：使用 vo=libmpv + mpv_render_context 替代 wid 模式
        // wid 模式下 MPV 通过内部 display link 驱动渲染，后台时 display link 暂停
        // 导致画中画画面冻结。使用 render context 模式后，我们可以通过定时器
        // 主动调用 mpv_render_context_render() 渲染新帧，不受 display link 影响。
        setOption("config", "no")
        setOption("terminal", "no")
        setOption("vo", "libmpv")
        setOption("gpu-api", "opengl")
        setOption("opengl-es", "yes")
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

        // 创建 mpv_render_context（OpenGL ES）
        guard createRenderContext(handle: handle) else {
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

        log("Libmpv-MoltenVK内核初始化完成（render context 模式）")
    }

    /// 创建 OpenGL ES render context
    private func createRenderContext(handle: OpaquePointer) -> Bool {
        guard renderContext == nil else { return true }
        guard let ctx = eaglContext else {
            fail("EAGLContext未创建")
            return false
        }
        EAGLContext.setCurrent(ctx)

        var advancedControl: CInt = 1
        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name else { return nil }
                return dlsym(UnsafeMutableRawPointer(bitPattern: -2), String(cString: name))
            },
            get_proc_address_ctx: nil
        )

        let code = MPV_RENDER_API_TYPE_OPENGL.withCString { apiType in
            withUnsafeMutablePointer(to: &initParams) { initParamsPointer in
                withUnsafeMutablePointer(to: &advancedControl) { advancedControlPointer in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: apiType)),
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initParamsPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: UnsafeMutableRawPointer(advancedControlPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                    ]
                    return mpv_render_context_create(&renderContext, handle, &params)
                }
            }
        }
        guard code >= 0, renderContext != nil else {
            fail("mpv_render_context_create失败：\(String(cString: mpv_error_string(code)))")
            return false
        }

        // 设置渲染更新回调：MPV 有新帧时触发 GLKView 重绘
        mpv_render_context_set_update_callback(renderContext, { context in
            guard let context else { return }
            let player = Unmanaged<LibmpvMoltenVKPlayerCore>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                player.renderView.setNeedsDisplay()
            }
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))

        return true
    }

    /// GLKView 渲染回调：通过 mpv_render_context_render() 渲染到 GLKView 的 framebuffer
    private func renderToGLKView() {
        guard let renderContext, let eaglContext else { return }
        EAGLContext.setCurrent(eaglContext)

        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &framebuffer)

        let scale = renderView.window?.screen.nativeScale ?? UIScreen.main.nativeScale
        let width = max(1, Int32(renderView.bounds.width * scale))
        let height = max(1, Int32(renderView.bounds.height * scale))
        var flipY: CInt = 1
        var fbo = mpv_opengl_fbo(fbo: Int32(framebuffer), w: width, h: height, internal_format: 0)
        withUnsafeMutablePointer(to: &fbo) { fboPointer in
            withUnsafeMutablePointer(to: &flipY) { flipPointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                mpv_render_context_render(renderContext, &params)
            }
        }
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
                // 节流：time-pos 高频回调（30-60次/秒），仅每 200ms emit 一次，
                // 避免 SwiftUI 视图重算导致 wakeups 超限闪退。
                let now = Date()
                if now.timeIntervalSince(self.lastTimePosEmitAt) >= self.timePosEmitInterval {
                    self.lastTimePosEmitAt = now
                    self.emitState()
                }
            case MPVKitProperty.duration:
                if let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
                    self.state.duration = value
                }
                self.lastTimePosEmitAt = Date()
                self.emitState()
            case MPVKitProperty.pause:
                if let paused = self.readFlag(property.data) {
                    self.state.isPlaying = !paused
                }
                self.lastTimePosEmitAt = Date()
                self.emitState()
            case MPVKitProperty.pausedForCache:
                if let buffering = self.readFlag(property.data) {
                    self.state.isBuffering = buffering
                }
                self.lastTimePosEmitAt = Date()
                self.emitState()
            case MPVKitProperty.eofReached:
                if let ended = self.readFlag(property.data), ended {
                    self.state.isPlaying = false
                    self.state.isEnded = true
                }
                self.lastTimePosEmitAt = Date()
                self.emitState()
            case MPVKitProperty.videoWidth:
                if let value = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee {
                    self.state.width = Int(value)
                }
                self.emitState()
            case MPVKitProperty.videoHeight:
                if let value = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee {
                    self.state.height = Int(value)
                }
                self.emitState()
            default:
                // 未使用的属性（demuxer-cache-time、cache-buffering-state 等）
                // 不更新 state 也不 emitState，避免无意义的 SwiftUI 重算
                break
            }
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

// MARK: - GLKViewDelegate

extension LibmpvMoltenVKPlayerCore: GLKViewDelegate {
    func glkView(_ view: GLKView, drawIn rect: CGRect) {
        renderToGLKView()
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
        case httpStream
        case generic
    }
}
#endif
