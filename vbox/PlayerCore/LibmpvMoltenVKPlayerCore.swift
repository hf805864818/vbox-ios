import Foundation
import QuartzCore
import UIKit

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
        case generic = "MoltenVK通用"
    }

    var onLog: ((String) -> Void)?
    var onStateChange: ((PlayerEngineState) -> Void)?

    private(set) var state = PlayerEngineState()
    private let renderView = LibmpvMoltenVKRenderView()
    private weak var containerView: UIView?
    private var mpv: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "app.vbox.libmpv.moltenvk-events", qos: .userInitiated)

    deinit {
        teardown()
    }

    func attach(to view: UIView) {
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

    func seek(to seconds: Double) {
        command("seek", args: [String(seconds), "absolute"])
    }

    func setRate(_ rate: Double) {
        guard let handle = mpv else { return }
        var value = rate
        check(mpv_set_property(handle, "speed", MPV_FORMAT_DOUBLE, &value), context: "speed")
    }

    func setVolume(_ volume: Double) {
        guard let handle = mpv else { return }
        var value = min(max(volume, 0), 1) * 100
        check(mpv_set_property(handle, "volume", MPV_FORMAT_DOUBLE, &value), context: "volume")
    }

    func teardown() {
        command("stop", checkForErrors: false)
        if let handle = mpv {
            mpv_terminate_destroy(handle)
            mpv = nil
        }
        renderView.removeFromSuperview()
        state = PlayerEngineState()
        emitState()
    }

    private func setupMPV() {
        guard mpv == nil, containerView != nil else { return }
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
        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" { return .hlsFast }
        if ext == "mkv" { return .mkvLarge }
        if ext == "mp4" || ext == "m4v" || ext == "mov" { return .mp4 }
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
