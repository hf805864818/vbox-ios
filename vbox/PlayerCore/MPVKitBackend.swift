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
/// 只做 mpv_create → mpv_initialize → mpv_terminate_destroy。
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

/// MPVKit 后端占位。
/// 后续接入 MPVKit.xcframework 时，只在这个文件里适配 MPVKit API。
final class MPVKitBackend: MPVBackend {
    let backendType: MPVBackendType = .mpvKit
    let name = "MPV"
    private(set) var state = PlayerEngineState()
    var onEvent: ((PlayerEngineEvent) -> Void)?

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

    /// 3.152 step。最小内核初始化探针。
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

    static var isAvailable: Bool {
        // MPVKit.xcframework wrapper 已放入仓库，但在底层 Libmpv/FFmpeg 依赖补齐前，
        // 不主动 import/link，避免 App 启动时加载不完整动态库导致闪退。
        return MPVIntegrationStatus.isFrameworkLinked(for: .mpvKit)
    }

    func attach(to view: UIView) {
        // 第五步只预留后端结构，不创建真实 MPVKit 渲染层。
    }

    func load(route: PlaybackRoute) {
        let message = MPVIntegrationStatus.disabledReason(for: .mpvKit)
        state.errorMessage = message
        onEvent?(.failed(message))
    }

    func play() {}
    func pause() {}
    func stop() {}
    func seek(to seconds: Double) {}
    func setRate(_ rate: Double) {}
    func setVolume(_ volume: Double) {}
    func teardown() {
        state = PlayerEngineState()
    }
}
