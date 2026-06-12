import Foundation
import UIKit
import Darwin

#if canImport(MPVKit)
import MPVKit
#endif

#if canImport(Libmpv)
import Libmpv
#endif

/// MPVKit 运行时探针结果。
/// 只检查动态库是否随包存在、是否能被系统 loader 打开。
/// 不创建 mpv_handle，不调用播放、渲染、解码 API。
struct MPVKitRuntimeProbeResult {
    let moduleStatus: String
    let bundleStatus: String
    let dynamicLoadStatus: String
    let isDynamicallyLoadable: Bool

    var summary: String {
        return "\(moduleStatus)，\(bundleStatus)，\(dynamicLoadStatus)"
    }
}

/// MPVKit/Libmpv 最小初始化探针结果。
/// 只做 mpv_create → 安全选项 → mpv_initialize → mpv_terminate_destroy。
/// 不加载媒体、不创建渲染层、不接正式播放器 UI。
struct MPVKitInitializationProbeResult {
    let moduleStatus: String
    let apiVersionStatus: String
    let createStatus: String
    let initializeStatus: String
    let isInitialized: Bool

    var summary: String {
        return "\(moduleStatus)，\(apiVersionStatus)，\(createStatus)，\(initializeStatus)"
    }
}

/// MPVKit/Libmpv 最小 loadfile 探针结果。
/// 只验证 mpv 能否接收并加载测试媒体，不创建渲染层、不接正式播放器 UI。
struct MPVKitLoadfileProbeResult {
    let moduleStatus: String
    let initializeStatus: String
    let commandStatus: String
    let eventStatus: String
    let isLoadfileAccepted: Bool
    let isMediaLoadObserved: Bool

    var summary: String {
        return "\(moduleStatus)，\(initializeStatus)，\(commandStatus)，\(eventStatus)"
    }
}

/// MPVKit/Libmpv 综合控制探针结果。
/// 只验证 loadfile 后的属性读取、暂停/恢复、seek、倍速命令，不创建渲染层。
struct MPVKitPlaybackControlProbeResult {
    let moduleStatus: String
    let loadStatus: String
    let propertyStatus: String
    let controlStatus: String
    let eventStatus: String
    let isControlPathReady: Bool

    var summary: String {
        return "\(moduleStatus)，\(loadStatus)，\(propertyStatus)，\(controlStatus)，\(eventStatus)"
    }
}

/// MPVKit 后端占位。
/// 后续接入 MPVKit.xcframework 时，只在这个文件里适配 MPVKit API。
final class MPVKitBackend: MPVBackend {
    let backendType: MPVBackendType = .mpvKit
    let name = "MPV"
    private(set) var state = PlayerEngineState()
    var onEvent: ((PlayerEngineEvent) -> Void)?

    #if canImport(Libmpv)
    private var handle: OpaquePointer?
    private var eventLoopWorkItem: DispatchWorkItem?
    private let eventQueue = DispatchQueue(label: "app.vbox.mpvkit.event-loop", qos: .userInitiated)
    private var isStopping = false
    #endif

    static let defaultLoadfileProbeURL = "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"

    deinit {
        teardown()
    }

    /// 软探针：仅检查 MPVKit 模块在编译期是否可见。
    /// 不创建 mpv_handle、不触发渲染回调，只用于验证 Link/Embed 是否成功。
    /// 3.150 step。后续真实 isAvailable 仍由 MPVIntegrationStatus 控制。
    static var moduleProbeResult: String {
        #if canImport(MPVKit)
        return "MPVKit-imported"
        #else
        return "MPVKit-missing"
        #endif
    }

    static var libmpvModuleProbeResult: String {
        #if canImport(Libmpv)
        return "Libmpv-imported"
        #else
        return "Libmpv-missing"
        #endif
    }

    /// 3.151 step。运行时加载探针。
    /// 该探针只验证 App 包内 MPVKit.framework/MPVKit 是否可被 dlopen。
    /// 不创建播放器实例，不进入正式播放链路。
    static var runtimeProbeResult: MPVKitRuntimeProbeResult {
        let moduleStatus = moduleProbeResult
        guard let frameworksURL = Bundle.main.privateFrameworksURL else {
            return MPVKitRuntimeProbeResult(
                moduleStatus: moduleStatus,
                bundleStatus: "Frameworks目录不可用",
                dynamicLoadStatus: "未尝试加载",
                isDynamicallyLoadable: false
            )
        }

        let binaryURL = frameworksURL.appendingPathComponent("MPVKit.framework/MPVKit")
        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            return MPVKitRuntimeProbeResult(
                moduleStatus: moduleStatus,
                bundleStatus: "MPVKit动态库未随包嵌入",
                dynamicLoadStatus: "未尝试加载",
                isDynamicallyLoadable: false
            )
        }

        guard let handle = dlopen(binaryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            let error = dlerror().map { String(cString: $0) } ?? "未知错误"
            return MPVKitRuntimeProbeResult(
                moduleStatus: moduleStatus,
                bundleStatus: "MPVKit动态库已随包嵌入",
                dynamicLoadStatus: "动态加载失败：\(error)",
                isDynamicallyLoadable: false
            )
        }

        dlclose(handle)
        return MPVKitRuntimeProbeResult(
            moduleStatus: moduleStatus,
            bundleStatus: "MPVKit动态库已随包嵌入",
            dynamicLoadStatus: "动态加载成功",
            isDynamicallyLoadable: true
        )
    }

    /// 3.158 step。最小内核初始化探针。
    /// 只验证 Libmpv C API 是否能创建并初始化最小 mpv handle。
    /// 不加载视频、不 attach view、不接正式播放链路。
    static let initializationProbeResult: MPVKitInitializationProbeResult = {
        #if canImport(Libmpv)
        setlocale(LC_NUMERIC, "C")

        let apiVersion = mpv_client_api_version()
        guard let handle = mpv_create() else {
            return MPVKitInitializationProbeResult(
                moduleStatus: libmpvModuleProbeResult,
                apiVersionStatus: "libmpv API版本：\(apiVersion)",
                createStatus: "mpv_create失败",
                initializeStatus: "未初始化",
                isInitialized: false
            )
        }

        _ = mpv_set_option_string(handle, "config", "no")
        _ = mpv_set_option_string(handle, "terminal", "no")
        _ = mpv_set_option_string(handle, "msg-level", "all=no")
        _ = mpv_set_option_string(handle, "vo", "null")
        _ = mpv_set_option_string(handle, "ao", "null")

        let initializeCode = mpv_initialize(handle)
        if initializeCode < 0 {
            mpv_destroy(handle)
            return MPVKitInitializationProbeResult(
                moduleStatus: libmpvModuleProbeResult,
                apiVersionStatus: "libmpv API版本：\(apiVersion)",
                createStatus: "mpv_create成功",
                initializeStatus: "mpv_initialize失败：\(initializeCode)",
                isInitialized: false
            )
        }

        mpv_terminate_destroy(handle)
        return MPVKitInitializationProbeResult(
            moduleStatus: libmpvModuleProbeResult,
            apiVersionStatus: "libmpv API版本：\(apiVersion)",
            createStatus: "mpv_create成功",
            initializeStatus: "mpv_initialize成功",
            isInitialized: true
        )
        #else
        return MPVKitInitializationProbeResult(
            moduleStatus: libmpvModuleProbeResult,
            apiVersionStatus: "libmpv API不可用",
            createStatus: "未创建",
            initializeStatus: "未初始化",
            isInitialized: false
        )
        #endif
    }()

    /// 3.161 step。最小 loadfile 探针。
    /// 使用 vo=null / ao=null，只验证媒体加载链路，不输出画面和声音。
    static func runLoadfileProbe(
        url: String = defaultLoadfileProbeURL,
        timeout: TimeInterval = 8
    ) -> MPVKitLoadfileProbeResult {
        #if canImport(Libmpv)
        setlocale(LC_NUMERIC, "C")

        guard let handle = mpv_create() else {
            return MPVKitLoadfileProbeResult(
                moduleStatus: libmpvModuleProbeResult,
                initializeStatus: "mpv_create失败",
                commandStatus: "未发送loadfile",
                eventStatus: "未等待事件",
                isLoadfileAccepted: false,
                isMediaLoadObserved: false
            )
        }

        _ = mpv_set_option_string(handle, "config", "no")
        _ = mpv_set_option_string(handle, "terminal", "no")
        _ = mpv_set_option_string(handle, "msg-level", "all=no")
        _ = mpv_set_option_string(handle, "vo", "null")
        _ = mpv_set_option_string(handle, "ao", "null")

        let initializeCode = mpv_initialize(handle)
        if initializeCode < 0 {
            mpv_destroy(handle)
            return MPVKitLoadfileProbeResult(
                moduleStatus: libmpvModuleProbeResult,
                initializeStatus: "mpv_initialize失败：\(initializeCode)",
                commandStatus: "未发送loadfile",
                eventStatus: "未等待事件",
                isLoadfileAccepted: false,
                isMediaLoadObserved: false
            )
        }

        let commandCode = sendLoadfileCommand(handle: handle, url: url)
        guard commandCode >= 0 else {
            mpv_terminate_destroy(handle)
            return MPVKitLoadfileProbeResult(
                moduleStatus: libmpvModuleProbeResult,
                initializeStatus: "mpv_initialize成功",
                commandStatus: "loadfile命令失败：\(commandCode)",
                eventStatus: "未等待事件",
                isLoadfileAccepted: false,
                isMediaLoadObserved: false
            )
        }

        let observation = waitForLoadfileEvents(handle: handle, timeout: timeout)
        mpv_terminate_destroy(handle)

        return MPVKitLoadfileProbeResult(
            moduleStatus: libmpvModuleProbeResult,
            initializeStatus: "mpv_initialize成功",
            commandStatus: "loadfile命令已接受",
            eventStatus: observation.status,
            isLoadfileAccepted: true,
            isMediaLoadObserved: observation.didObserveMediaLoad
        )
        #else
        return MPVKitLoadfileProbeResult(
            moduleStatus: libmpvModuleProbeResult,
            initializeStatus: "libmpv API不可用",
            commandStatus: "未发送loadfile",
            eventStatus: "未等待事件",
            isLoadfileAccepted: false,
            isMediaLoadObserved: false
        )
        #endif
    }

    /// 3.162 step。综合播放控制探针。
    /// 仍使用 vo=null / ao=null，不渲染、不接正式 PlayerEngine，只验证控制命令和状态读取链路。
    static func runPlaybackControlProbe(
        url: String = defaultLoadfileProbeURL,
        timeout: TimeInterval = 8
    ) -> MPVKitPlaybackControlProbeResult {
        #if canImport(Libmpv)
        setlocale(LC_NUMERIC, "C")

        guard let handle = mpv_create() else {
            return MPVKitPlaybackControlProbeResult(
                moduleStatus: libmpvModuleProbeResult,
                loadStatus: "mpv_create失败",
                propertyStatus: "未读取属性",
                controlStatus: "未发送控制命令",
                eventStatus: "未等待事件",
                isControlPathReady: false
            )
        }

        configureNullOutput(handle: handle)

        let initializeCode = mpv_initialize(handle)
        if initializeCode < 0 {
            mpv_destroy(handle)
            return MPVKitPlaybackControlProbeResult(
                moduleStatus: libmpvModuleProbeResult,
                loadStatus: "mpv_initialize失败：\(initializeCode)",
                propertyStatus: "未读取属性",
                controlStatus: "未发送控制命令",
                eventStatus: "未等待事件",
                isControlPathReady: false
            )
        }

        let commandCode = sendLoadfileCommand(handle: handle, url: url)
        guard commandCode >= 0 else {
            mpv_terminate_destroy(handle)
            return MPVKitPlaybackControlProbeResult(
                moduleStatus: libmpvModuleProbeResult,
                loadStatus: "loadfile失败：\(commandCode)",
                propertyStatus: "未读取属性",
                controlStatus: "未发送控制命令",
                eventStatus: "未等待事件",
                isControlPathReady: false
            )
        }

        let loadObservation = waitForLoadfileEvents(handle: handle, timeout: timeout)
        let firstSnapshot = propertySnapshot(handle: handle)

        let pauseCode = setStringProperty(handle: handle, name: "pause", value: "yes")
        let pauseValue = getStringProperty(handle: handle, name: "pause") ?? "unknown"
        let resumeCode = setStringProperty(handle: handle, name: "pause", value: "no")
        let speedCode = setStringProperty(handle: handle, name: "speed", value: "1.25")
        let speedValue = getStringProperty(handle: handle, name: "speed") ?? "unknown"
        let seekCode = sendSeekCommand(handle: handle, seconds: "5", mode: "relative")
        let postControlObservation = waitForAnyEvents(handle: handle, timeout: 1.5)
        let secondSnapshot = propertySnapshot(handle: handle)

        mpv_terminate_destroy(handle)

        let controlOK = pauseCode >= 0 && resumeCode >= 0 && speedCode >= 0 && seekCode >= 0
        let controlStatus = "pause:\(pauseCode)/\(pauseValue)，resume:\(resumeCode)，speed:\(speedCode)/\(speedValue)，seek:\(seekCode)"
        let propertyStatus = "初始[\(firstSnapshot)]，控制后[\(secondSnapshot)]"
        let eventStatus = "\(loadObservation.status)；后续\(postControlObservation)"

        return MPVKitPlaybackControlProbeResult(
            moduleStatus: libmpvModuleProbeResult,
            loadStatus: loadObservation.didObserveMediaLoad ? "媒体加载已观察" : "媒体加载事件不足",
            propertyStatus: propertyStatus,
            controlStatus: controlStatus,
            eventStatus: eventStatus,
            isControlPathReady: loadObservation.didObserveMediaLoad && controlOK
        )
        #else
        return MPVKitPlaybackControlProbeResult(
            moduleStatus: libmpvModuleProbeResult,
            loadStatus: "libmpv API不可用",
            propertyStatus: "未读取属性",
            controlStatus: "未发送控制命令",
            eventStatus: "未等待事件",
            isControlPathReady: false
        )
        #endif
    }

    #if canImport(Libmpv)
    private static func configureNullOutput(handle: OpaquePointer) {
        _ = mpv_set_option_string(handle, "config", "no")
        _ = mpv_set_option_string(handle, "terminal", "no")
        _ = mpv_set_option_string(handle, "msg-level", "all=no")
        _ = mpv_set_option_string(handle, "vo", "null")
        _ = mpv_set_option_string(handle, "ao", "null")
    }

    private static func sendLoadfileCommand(handle: OpaquePointer, url: String) -> Int32 {
        return "loadfile".withCString { loadfilePointer in
            url.withCString { urlPointer in
                "replace".withCString { replacePointer in
                    var command: [UnsafePointer<CChar>?] = [
                        loadfilePointer,
                        urlPointer,
                        replacePointer,
                        nil
                    ]
                    return command.withUnsafeMutableBufferPointer { buffer in
                        guard let baseAddress = buffer.baseAddress else { return -1 }
                        return mpv_command(handle, baseAddress)
                    }
                }
            }
        }
    }

    private static func sendSeekCommand(handle: OpaquePointer, seconds: String, mode: String) -> Int32 {
        return "seek".withCString { seekPointer in
            seconds.withCString { secondsPointer in
                mode.withCString { modePointer in
                    var command: [UnsafePointer<CChar>?] = [
                        seekPointer,
                        secondsPointer,
                        modePointer,
                        nil
                    ]
                    return command.withUnsafeMutableBufferPointer { buffer in
                        guard let baseAddress = buffer.baseAddress else { return -1 }
                        return mpv_command(handle, baseAddress)
                    }
                }
            }
        }
    }

    private static func setStringProperty(handle: OpaquePointer, name: String, value: String) -> Int32 {
        return name.withCString { namePointer in
            value.withCString { valuePointer in
                return mpv_set_property_string(handle, namePointer, valuePointer)
            }
        }
    }

    private static func getStringProperty(handle: OpaquePointer, name: String) -> String? {
        return name.withCString { namePointer in
            guard let rawValue = mpv_get_property_string(handle, namePointer) else {
                return nil
            }
            defer { mpv_free(UnsafeMutableRawPointer(rawValue)) }
            return String(cString: rawValue)
        }
    }

    private static func getDoubleProperty(handle: OpaquePointer, name: String) -> Double? {
        guard let rawValue = getStringProperty(handle: handle, name: name) else {
            return nil
        }
        return Double(rawValue)
    }

    private static func propertySnapshot(handle: OpaquePointer) -> String {
        let duration = getStringProperty(handle: handle, name: "duration") ?? "nil"
        let timePosition = getStringProperty(handle: handle, name: "time-pos") ?? "nil"
        let pause = getStringProperty(handle: handle, name: "pause") ?? "nil"
        return "duration=\(duration), time-pos=\(timePosition), pause=\(pause)"
    }

    private static func waitForLoadfileEvents(
        handle: OpaquePointer,
        timeout: TimeInterval
    ) -> (status: String, didObserveMediaLoad: Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        var eventNames: [String] = []
        var didObserveMediaLoad = false

        while Date() < deadline {
            guard let event = mpv_wait_event(handle, 0.1) else {
                continue
            }

            let eventName = String(cString: mpv_event_name(event.pointee.event_id))
            if eventName != "none" {
                eventNames.append(eventName)
            }

            if eventName == "file-loaded" || eventName == "playback-restart" {
                didObserveMediaLoad = true
                break
            }

            if eventName == "end-file" || eventName == "shutdown" {
                break
            }
        }

        if eventNames.isEmpty {
            return ("等待\(Int(timeout))秒未收到关键事件", false)
        }

        let uniqueEvents = Array(NSOrderedSet(array: eventNames)) as? [String] ?? eventNames
        return ("事件：\(uniqueEvents.prefix(6).joined(separator: " / "))", didObserveMediaLoad)
    }

    private static func waitForAnyEvents(handle: OpaquePointer, timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var eventNames: [String] = []

        while Date() < deadline {
            guard let event = mpv_wait_event(handle, 0.1) else {
                continue
            }

            let eventName = String(cString: mpv_event_name(event.pointee.event_id))
            if eventName != "none" {
                eventNames.append(eventName)
            }
        }

        if eventNames.isEmpty {
            return "未收到后续事件"
        }

        let uniqueEvents = Array(NSOrderedSet(array: eventNames)) as? [String] ?? eventNames
        return "事件：\(uniqueEvents.prefix(6).joined(separator: " / "))"
    }
    #endif

    static var isAvailable: Bool {
        // MPVKit.xcframework wrapper 已放入仓库，但在底层 Libmpv/FFmpeg 依赖补齐前，
        // 不主动 import/link，避免 App 启动时加载不完整动态库导致闪退。
        return MPVIntegrationStatus.isFrameworkLinked(for: .mpvKit)
    }

    func attach(to view: UIView) {
        // 3.163 合并版仍保持 vo=null / ao=null，不创建真实 MPVKit 渲染层。
    }

    func load(route: PlaybackRoute) {
        #if canImport(Libmpv)
        teardown()
        setlocale(LC_NUMERIC, "C")

        guard let newHandle = mpv_create() else {
            emitFailure("mpv_create失败")
            return
        }

        handle = newHandle
        isStopping = false
        Self.configureNullOutput(handle: newHandle)

        let initializeCode = mpv_initialize(newHandle)
        guard initializeCode >= 0 else {
            mpv_destroy(newHandle)
            handle = nil
            emitFailure("mpv_initialize失败：\(initializeCode)")
            return
        }

        state = PlayerEngineState(isBuffering: true)
        onEvent?(.buffering(true))
        onEvent?(.log("MPV最小内核加载线路：\(route.title)"))
        startEventLoop(handle: newHandle)

        let commandCode = Self.sendLoadfileCommand(handle: newHandle, url: route.url.absoluteString)
        if commandCode < 0 {
            emitFailure("loadfile命令失败：\(commandCode)")
        }
        #else
        let message = MPVIntegrationStatus.disabledReason(for: .mpvKit)
        state.errorMessage = message
        onEvent?(.failed(message))
        #endif
    }

    func play() {
        #if canImport(Libmpv)
        guard let handle else { return }
        let code = Self.setStringProperty(handle: handle, name: "pause", value: "no")
        if code >= 0 {
            state.isPlaying = true
        } else {
            emitFailure("MPV恢复播放失败：\(code)")
        }
        #endif
    }

    func pause() {
        #if canImport(Libmpv)
        guard let handle else { return }
        let code = Self.setStringProperty(handle: handle, name: "pause", value: "yes")
        if code >= 0 {
            state.isPlaying = false
        } else {
            emitFailure("MPV暂停失败：\(code)")
        }
        #endif
    }

    func stop() {
        #if canImport(Libmpv)
        guard let handle else {
            state = PlayerEngineState()
            return
        }

        _ = Self.sendStopCommand(handle: handle)
        state.isPlaying = false
        state.isBuffering = false
        state.currentTime = 0
        #else
        state = PlayerEngineState()
        #endif
    }

    func seek(to seconds: Double) {
        #if canImport(Libmpv)
        guard let handle else { return }
        let safeSeconds = max(0, seconds)
        let code = Self.sendSeekCommand(handle: handle, seconds: "\(safeSeconds)", mode: "absolute")
        if code < 0 {
            emitFailure("MPV seek失败：\(code)")
        }
        #endif
    }

    func setRate(_ rate: Double) {
        #if canImport(Libmpv)
        guard let handle else { return }
        let safeRate = min(max(rate, 0.25), 4)
        let code = Self.setStringProperty(handle: handle, name: "speed", value: "\(safeRate)")
        if code < 0 {
            emitFailure("MPV倍速设置失败：\(code)")
        }
        #endif
    }

    func setVolume(_ volume: Double) {
        #if canImport(Libmpv)
        guard let handle else { return }
        let safeVolume = min(max(volume, 0), 1) * 100
        let code = Self.setStringProperty(handle: handle, name: "volume", value: "\(safeVolume)")
        if code < 0 {
            emitFailure("MPV音量设置失败：\(code)")
        }
        #endif
    }

    func teardown() {
        #if canImport(Libmpv)
        isStopping = true
        eventLoopWorkItem?.cancel()
        eventLoopWorkItem = nil

        if let handle {
            mpv_terminate_destroy(handle)
            self.handle = nil
        }
        #endif
        state = PlayerEngineState()
    }

    #if canImport(Libmpv)
    private static func sendStopCommand(handle: OpaquePointer) -> Int32 {
        return "stop".withCString { stopPointer in
            var command: [UnsafePointer<CChar>?] = [
                stopPointer,
                nil
            ]
            return command.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return mpv_command(handle, baseAddress)
            }
        }
    }

    private func startEventLoop(handle: OpaquePointer) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.runEventLoop(handle: handle)
        }
        eventLoopWorkItem = workItem
        eventQueue.async(execute: workItem)
    }

    private func runEventLoop(handle: OpaquePointer) {
        var lastProgressEmit = Date.distantPast

        while !isStopping && self.handle == handle {
            guard let event = mpv_wait_event(handle, 0.1) else {
                continue
            }

            let eventName = String(cString: mpv_event_name(event.pointee.event_id))
            handleEvent(named: eventName, handle: handle)

            if Date().timeIntervalSince(lastProgressEmit) >= 0.5 {
                updateProgress(handle: handle)
                lastProgressEmit = Date()
            }

            if eventName == "shutdown" {
                break
            }
        }
    }

    private func handleEvent(named eventName: String, handle: OpaquePointer) {
        switch eventName {
        case "start-file":
            state.isBuffering = true
            onEvent?(.buffering(true))
        case "file-loaded", "playback-restart":
            state.isBuffering = false
            state.isPlaying = true
            updateProgress(handle: handle)
            onEvent?(.buffering(false))
            onEvent?(.ready)
        case "end-file":
            state.isPlaying = false
            state.isBuffering = false
            updateProgress(handle: handle)
            onEvent?(.ended)
        case "shutdown":
            state.isPlaying = false
            state.isBuffering = false
        case "none":
            break
        default:
            break
        }
    }

    private func updateProgress(handle: OpaquePointer) {
        let current = Self.getDoubleProperty(handle: handle, name: "time-pos") ?? state.currentTime
        let duration = Self.getDoubleProperty(handle: handle, name: "duration") ?? state.duration
        let safeCurrent = current.isFinite ? max(0, current) : state.currentTime
        let safeDuration = duration.isFinite ? max(0, duration) : state.duration

        state.currentTime = safeCurrent
        state.duration = safeDuration
        onEvent?(.progress(current: safeCurrent, duration: safeDuration))
    }

    private func emitFailure(_ message: String) {
        state.isBuffering = false
        state.isPlaying = false
        state.errorMessage = message
        onEvent?(.buffering(false))
        onEvent?(.failed(message))
    }
    #else
    private func emitFailure(_ message: String) {
        state.isBuffering = false
        state.isPlaying = false
        state.errorMessage = message
        onEvent?(.failed(message))
    }
    #endif
}
