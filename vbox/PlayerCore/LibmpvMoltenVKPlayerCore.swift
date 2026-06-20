import Foundation
import QuartzCore
import UIKit
import Metal
import AVFoundation

#if canImport(Libmpv)
import Libmpv

final class LibmpvMoltenVKRenderView: UIView {
    let metalLayer = MPVKitMetalLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
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
        metalLayer.framebufferOnly = false
        metalLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(metalLayer)
    }
}

final class LibmpvMoltenVKPlayerCore {
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
    private let renderView = LibmpvMoltenVKRenderView()
    private weak var containerView: UIView?
    private var mpv: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "app.vbox.libmpv.moltenvk-events", qos: .userInitiated)
    private var isShuttingDown = false

    // MARK: - PiP 帧捕获属性

    /// PiP 帧捕获是否激活
    private var isPipCapturing = false
    /// 帧捕获定时器
    private var frameCaptureTimer: DispatchSourceTimer?
    /// 帧捕获计数器（节流用）
    private var frameCaptureCounter: Int = 0
    /// 帧捕获间隔（每 N 次定时器触发捕获一次）
    private let frameCaptureInterval: Int = 2
    /// Metal 设备
    private var metalDevice: MTLDevice?
    /// Metal 命令队列
    private var commandQueue: MTLCommandQueue?

    deinit {
        teardown()
    }

    func attach(to view: UIView) {
        guard !isShuttingDown else { return }
        containerView = view
        if renderView.superview !== view {
            renderView.removeFromSuperview()
            renderView.frame = view.bounds
            renderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(renderView)
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
        log("MoltenVK加载：\(url.absoluteString)")
        emitState()
    }

    func play() {
        guard !isShuttingDown else { return }
        setFlag(MPVKitProperty.pause, false)
        state.isPlaying = true
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
        stopFrameCapture()
        onLog = nil
        onStateChange = nil
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

        // 初始化 Metal 设备（用于 PiP 帧捕获）
        metalDevice = renderView.metalLayer.device ?? MTLCreateSystemDefaultDevice()
        commandQueue = metalDevice?.makeCommandQueue()

        // 监听 PiP 状态变化通知
        NotificationCenter.default.addObserver(
            forName: .vboxPiPStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let isActive = notification.object as? Bool {
                self?.pipStatusChanged(isActive)
            }
        }

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

    // MARK: - PiP 帧捕获（Metal → CVPixelBuffer）

    private func pipStatusChanged(_ isActive: Bool) {
        if isActive {
            startFrameCapture()
        } else {
            stopFrameCapture()
        }
    }

    private func startFrameCapture() {
        guard !isPipCapturing else { return }
        guard state.width > 0, state.height > 0 else { return }
        isPipCapturing = true
        frameCaptureCounter = 0

        // 每 ~33ms 触发一次（约 30fps），实际每 frameCaptureInterval 次才捕获
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "app.vbox.pip-capture", qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            self?.captureCurrentFrame()
        }
        timer.resume()
        frameCaptureTimer = timer

        log("PiP帧捕获已启动：\(state.width)x\(state.height)")
    }

    private func stopFrameCapture() {
        guard isPipCapturing else { return }
        isPipCapturing = false
        frameCaptureTimer?.cancel()
        frameCaptureTimer = nil
        log("PiP帧捕获已停止")
    }

    private func captureCurrentFrame() {
        guard isPipCapturing else { return }
        guard let metalDevice, let commandQueue else { return }

        // 帧节流
        frameCaptureCounter += 1
        guard frameCaptureCounter >= frameCaptureInterval else { return }
        frameCaptureCounter = 0

        let videoWidth = state.width
        let videoHeight = state.height
        guard videoWidth > 0, videoHeight > 0 else { return }

        // 从 Metal layer 读取当前 drawable 的纹理
        guard let currentDrawable = renderView.metalLayer.drawable(at: CACurrentMediaTime()) else { return }
        let sourceTexture = currentDrawable.texture

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // 创建 CVPixelBuffer
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: videoWidth,
            kCVPixelBufferHeightKey as String: videoHeight,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, videoWidth, videoHeight,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)

        guard let pb = pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(pb, [])
        guard let destAddress = CVPixelBufferGetBaseAddress(pb) else {
            CVPixelBufferUnlockBaseAddress(pb, [])
            return
        }
        let destBytesPerRow = CVPixelBufferGetBytesPerRow(pb)

        // Metal 纹理 → CPU 内存
        if sourceTexture.pixelFormat == .bgra8Unorm {
            // 格式匹配，直接复制
            let blitEncoder = commandBuffer.makeBlitCommandEncoder()!
            blitEncoder.synchronize(resource: sourceTexture)
            blitEncoder.endEncoding()

            commandBuffer.addCompletedHandler { _ in
                let srcBytesPerRow = sourceTexture.width * 4
                let region = MTLRegionMake2D(0, 0, min(sourceTexture.width, videoWidth), min(sourceTexture.height, videoHeight))
                sourceTexture.getBytes(destAddress, bytesPerRow: destBytesPerRow, from: region, mipmapLevel: 0)
                CVPixelBufferUnlockBaseAddress(pb, [])

                let presentationTime = CMTime(value: Int64(self.state.currentTime * 1000), timescale: 1000)
                Task { @MainActor in
                    MPVPiPManager.shared.enqueueFrame(pb, presentationTime: presentationTime)
                }
            }
            commandBuffer.commit()
        } else {
            // 格式不匹配，需要 shader 转换 — 简单跳过
            CVPixelBufferUnlockBaseAddress(pb, [])
        }
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
