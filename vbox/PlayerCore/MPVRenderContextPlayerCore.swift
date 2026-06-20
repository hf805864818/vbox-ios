import Foundation
import GLKit
import OpenGLES
import UIKit
import AVFoundation

#if canImport(Libmpv)
import Libmpv

final class MPVRenderContextPlayerCore: NSObject {

    // MARK: - 离屏 FBO 帧捕获属性（PiP 用）

    /// 离屏 FBO ID
    private var offscreenFBO: GLuint = 0
    /// 离屏 FBO 关联的颜色 Renderbuffer
    private var offscreenColorBuffer: GLuint = 0
    /// 离屏 FBO 关联的深度 Renderbuffer
    private var offscreenDepthBuffer: GLuint = 0
    /// 离屏 FBO 的尺寸（视频原始尺寸，非屏幕缩放尺寸）
    private var offscreenSize: CGSize = .zero
    /// PiP 帧捕获是否已初始化
    private var isFrameCaptureReady = false
    /// 帧计数器（用于节流，避免每帧都捕获）
    private var frameCaptureCounter: Int = 0
    /// PiP 帧捕获间隔（每 N 帧捕获一次，降低 CPU 开销）
    private let frameCaptureInterval: Int = 2
    enum PlaybackProfile: String {
        case hlsFast = "RenderContext HLS极速"
        case hlsQuality = "RenderContext HLS高清"
        case hlsFMP4 = "RenderContext HLS-fMP4兼容"
        case mp4 = "RenderContext普通文件"
        case mkvLarge = "RenderContext MKV大文件"
        case generic = "RenderContext通用"

        var family: String {
            switch self {
            case .hlsFast, .hlsQuality, .hlsFMP4:
                return "hls"
            case .mp4:
                return "mp4"
            case .mkvLarge:
                return "mkv"
            case .generic:
                return "generic"
            }
        }
    }

    var onLog: ((String) -> Void)?
    var onStateChange: ((PlayerEngineState) -> Void)?

    private(set) var state = PlayerEngineState()
    private weak var glView: GLKView?
    private var eaglContext: EAGLContext?
    private var mpv: OpaquePointer?
    private var renderContext: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "app.vbox.mpv.render-context-events", qos: .userInitiated)

    deinit {
        teardown()
    }

    func attach(to view: GLKView) {
        glView = view
        view.delegate = self
        view.enableSetNeedsDisplay = true
        view.isOpaque = true
        view.backgroundColor = .black

        if eaglContext == nil {
            eaglContext = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2)
        }

        if let eaglContext {
            view.context = eaglContext
            EAGLContext.setCurrent(eaglContext)
        }

        if mpv == nil {
            setupMPV()
        }
    }

    func resetForNewLoad() {
        command("stop", checkForErrors: false)
        clearCurrentDrawable()
        state = PlayerEngineState()
        emitState()
        DispatchQueue.main.async { [weak self] in
            self?.glView?.setNeedsDisplay()
        }
    }

    func rebuildForNewLoad() {
        command("stop", checkForErrors: false)
        clearCurrentDrawable()
        if let renderContext {
            mpv_render_context_free(renderContext)
            self.renderContext = nil
        }
        if let handle = mpv {
            mpv_terminate_destroy(handle)
            mpv = nil
        }
        if EAGLContext.current() === eaglContext {
            EAGLContext.setCurrent(nil)
        }
        eaglContext = nil
        state = PlayerEngineState()
        emitState()
        if let glView {
            attach(to: glView)
        } else {
            setupMPV()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.glView?.delegate = self
            self.glView?.setNeedsDisplay()
        }
    }

    func load(url: URL, headers: [String: String] = [:], profile: PlaybackProfile? = nil) {
        if mpv == nil {
            setupMPV()
        }

        guard mpv != nil else {
            fail("RenderContext内核初始化失败")
            return
        }

        applyHTTPOptions(headers: headers)
        applyPlaybackOptions(for: url, profile: profile)
        command("loadfile", args: [url.absoluteString, "replace"])
        state.errorMessage = nil
        log("RenderContext加载：\(url.absoluteString)")
        emitState()
    }

    func play() {
        setFlag(MPVKitProperty.pause, false)
        state.isPlaying = true
        emitState()
    }

    func pause() {
        setFlag(MPVKitProperty.pause, true)
        state.isPlaying = false
        emitState()
    }

    func stop() {
        command("stop", checkForErrors: false)
        state.isPlaying = false
        state.currentTime = 0
        emitState()
    }

    func teardown() {
        clearCurrentDrawable()
        cleanupOffscreenFBO()
        if let renderContext {
            mpv_render_context_free(renderContext)
            self.renderContext = nil
        }
        if let handle = mpv {
            mpv_terminate_destroy(handle)
            mpv = nil
        }
        if EAGLContext.current() === eaglContext {
            EAGLContext.setCurrent(nil)
        }
        eaglContext = nil
        glView?.delegate = nil
        state = PlayerEngineState()
        emitState()
    }

    private func setupMPV() {
        guard mpv == nil else { return }
        guard eaglContext != nil else {
            fail("EAGLContext未创建")
            return
        }
        guard let handle = mpv_create() else {
            fail("mpv_create失败")
            return
        }
        mpv = handle

        #if DEBUG
        check(mpv_request_log_messages(handle, "warn"), context: "request_log_messages")
        #else
        check(mpv_request_log_messages(handle, "error"), context: "request_log_messages")
        #endif

        setOption("vo", "libmpv")
        setOption("gpu-api", "opengl")
        setOption("opengl-es", "yes")
        setOption("hwdec", "no")
        setOption("video-rotate", "no")
        setOption("cache", "yes")
        setOption("keep-open", "no")
        setOption("subs-match-os-language", "yes")
        setOption("subs-fallback", "yes")

        let initCode = mpv_initialize(handle)
        guard initCode >= 0 else {
            fail("mpv_initialize失败：\(String(cString: mpv_error_string(initCode)))")
            mpv_terminate_destroy(handle)
            mpv = nil
            return
        }

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
            let player = Unmanaged<MPVRenderContextPlayerCore>.fromOpaque(context).takeUnretainedValue()
            player.readEvents()
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))

        log("RenderContext内核初始化完成")
    }

    private func createRenderContext(handle: OpaquePointer) -> Bool {
        guard renderContext == nil else { return true }
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

        mpv_render_context_set_update_callback(renderContext, { context in
            guard let context else { return }
            let player = Unmanaged<MPVRenderContextPlayerCore>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                player.glView?.setNeedsDisplay()
            }
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        return true
    }

    private func render() {
        guard let renderContext, let glView, let eaglContext else { return }
        EAGLContext.setCurrent(eaglContext)

        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &framebuffer)

        let scale = glView.window?.screen.nativeScale ?? UIScreen.main.nativeScale
        let width = max(1, Int32(glView.bounds.width * scale))
        let height = max(1, Int32(glView.bounds.height * scale))
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

        // PiP 帧捕获：渲染到离屏 FBO 后读取像素
        captureFrameForPiP(videoWidth: state.width, videoHeight: state.height)
    }

    private func clearCurrentDrawable() {
        guard let glView, let eaglContext else { return }
        EAGLContext.setCurrent(eaglContext)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        glView.setNeedsDisplay()
    }

    // MARK: - 离屏 FBO 帧捕获（PiP 用）

    /// 捕获当前帧用于 PiP 推送
    private func captureFrameForPiP(videoWidth: Int, videoHeight: Int) {
        // 仅在 PiP 激活时才捕获
        guard MPVPiPManager.shared.isPipActive else { return }
        guard videoWidth > 0, videoHeight > 0 else { return }

        // 帧节流：每 frameCaptureInterval 帧捕获一次
        frameCaptureCounter += 1
        guard frameCaptureCounter >= frameCaptureInterval else { return }
        frameCaptureCounter = 0

        let captureSize = CGSize(width: videoWidth, height: videoHeight)

        // 视频尺寸变化时重建离屏 FBO
        if offscreenSize != captureSize || !isFrameCaptureReady {
            setupOffscreenFBO(width: videoWidth, height: videoHeight)
        }

        guard isFrameCaptureReady, offscreenFBO > 0 else { return }

        // 保存当前 FBO
        var originalFBO: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &originalFBO)

        // 绑定离屏 FBO
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), offscreenFBO)

        // 再次渲染到离屏 FBO
        guard let renderContext else {
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLenum(originalFBO))
            return
        }
        var flipY: CInt = 1
        var offscreenFBOStruct = mpv_opengl_fbo(
            fbo: Int32(offscreenFBO),
            w: Int32(videoWidth),
            h: Int32(videoHeight),
            internal_format: 0
        )
        withUnsafeMutablePointer(to: &offscreenFBOStruct) { fboPointer in
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
        defer { pixelData.deallocate() }

        glReadPixels(GLint(0), GLint(0),
                     GLsizei(videoWidth), GLsizei(videoHeight),
                     GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE),
                     pixelData)

        // 恢复原始 FBO
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLenum(originalFBO))

        // 将像素数据写入 CVPixelBuffer 并推送给 PiP 管理器
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault,
            Int(videoWidth),
            Int(videoHeight),
            kCVPixelFormatType_32BGRA,
            pixelData,
            bytesPerRow,
            nil, nil, nil,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return }

        // glReadPixels 从底部向上读取，需要垂直翻转
        flipPixelBufferVertically(&pb, width: videoWidth, height: videoHeight)

        let presentationTime = CMTime(
            value: Int64(state.currentTime * 1000),
            timescale: 1000
        )

        Task { @MainActor in
            MPVPiPManager.shared.enqueueFrame(pb, presentationTime: presentationTime)
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
            isFrameCaptureReady = true
            log("离屏FBO创建成功：\(width)x\(height)")
        } else {
            log("离屏FBO创建失败，状态：\(status)")
            isFrameCaptureReady = false
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
        isFrameCaptureReady = false
        offscreenSize = .zero
    }

    /// 垂直翻转 CVPixelBuffer（glReadPixels 从底部向上读取）
    private func flipPixelBufferVertically(_ pixelBuffer: inout CVPixelBuffer,
                                            width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rowBytes = width * 4

        var tempRow = [UInt8](repeating: 0, count: rowBytes)

        for y in 0..<(height / 2) {
            let topRow = baseAddress.advanced(by: y * bytesPerRow)
            let bottomRow = baseAddress.advanced(by: (height - 1 - y) * bytesPerRow)

            tempRow.withUnsafeMutableBufferPointer { tempPtr in
                memcpy(tempPtr.baseAddress, topRow, rowBytes)
                memcpy(topRow, bottomRow, rowBytes)
                memcpy(bottomRow, tempPtr.baseAddress, rowBytes)
            }
        }
    }

    private func readEvents() {
        eventQueue.async { [weak self] in
            guard let self else { return }
            while let handle = self.mpv {
                guard let event = mpv_wait_event(handle, 0) else { break }
                if event.pointee.event_id == MPV_EVENT_NONE { break }
                self.handle(event: event.pointee)
            }
        }
    }

    private func handle(event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_FILE_LOADED:
            DispatchQueue.main.async { [weak self] in
                self?.log("file-loaded")
                self?.glView?.setNeedsDisplay()
            }
        case MPV_EVENT_VIDEO_RECONFIG:
            DispatchQueue.main.async { [weak self] in
                self?.log("video-reconfig")
                self?.glView?.setNeedsDisplay()
            }
        case MPV_EVENT_PLAYBACK_RESTART:
            DispatchQueue.main.async { [weak self] in
                self?.log("playback-restart")
                self?.glView?.setNeedsDisplay()
            }
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
            break
        }
    }

    private func handlePropertyChange(event: mpv_event) {
        guard let data = event.data else { return }
        let property = UnsafePointer<mpv_event_property>(OpaquePointer(data))?.pointee
        guard let property, let namePointer = property.name else { return }
        let name = String(cString: namePointer)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
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

    private func endFileSummary(event: mpv_event) -> String {
        guard let data = event.data,
              let endFile = UnsafePointer<mpv_event_end_file>(OpaquePointer(data))?.pointee else {
            return "end-file"
        }
        return "end-file reason=\(endFile.reason) error=\(endFile.error)"
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
            applyHLSFastProfile()
        case .hlsQuality:
            applyHLSQualityProfile()
        case .hlsFMP4:
            applyHLSFMP4Profile()
        case .mkvLarge:
            applyMKVBaselineProfile()
        case .mp4, .generic:
            applyGenericProfile()
        }
    }

    private func applyHLSFastProfile() {
        setOption("cache", "yes")
        setOption("cache-secs", "1")
        setOption("demuxer-readahead-secs", "1")
        setOption("network-timeout", "8")
        setOption("hls-bitrate", "min")
        setOption("hwdec", "no")
    }

    private func applyHLSQualityProfile() {
        setOption("cache", "yes")
        setOption("cache-secs", "3")
        setOption("demuxer-readahead-secs", "2")
        setOption("network-timeout", "10")
        setOption("hls-bitrate", "max")
        setOption("hwdec", "no")
    }

    private func applyHLSFMP4Profile() {
        setOption("cache", "yes")
        setOption("cache-secs", "1")
        setOption("demuxer-readahead-secs", "1")
        setOption("demuxer-lavf-analyzeduration", "0.5")
        setOption("demuxer-lavf-probesize", "262144")
        setOption("network-timeout", "12")
        setOption("hls-bitrate", "min")
        setOption("hwdec", "no")
    }

    private func applyMKVBaselineProfile() {
        setOption("cache", "yes")
        setOption("network-timeout", "15")
        setOption("hwdec", "no")
    }

    private func applyGenericProfile() {
        setOption("cache", "yes")
        setOption("cache-secs", "3")
        setOption("demuxer-readahead-secs", "1")
        setOption("demuxer-max-bytes", "32MiB")
        setOption("demuxer-max-back-bytes", "8MiB")
        setOption("network-timeout", "10")
        setOption("hwdec", "no")
    }

    private func inferredProfile(for url: URL) -> PlaybackProfile {
        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" {
            return .hlsFast
        }
        if ext == "mkv" {
            return .mkvLarge
        }
        if ext == "mp4" || ext == "m4v" || ext == "mov" {
            return .mp4
        }
        return .generic
    }

    private func command(_ command: String, args: [String] = [], checkForErrors: Bool = true) {
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
        guard let handle = mpv else { return }
        check(mpv_set_option_string(handle, name, value), context: name)
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let handle = mpv else { return }
        var data: Int32 = value ? 1 : 0
        check(mpv_set_property(handle, name, MPV_FORMAT_FLAG, &data), context: name)
    }

    private func observe(_ name: String, format: mpv_format) {
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

extension MPVRenderContextPlayerCore: GLKViewDelegate {
    func glkView(_ view: GLKView, drawIn rect: CGRect) {
        render()
    }
}
#endif
