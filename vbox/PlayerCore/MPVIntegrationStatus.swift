import Foundation

/// MPV framework 接入状态说明。
/// 当前已放入 MPVKit.xcframework wrapper，并识别出 MPVKit binary bundle 中的核心依赖。
/// 在完整链接链路验证前，不主动 link/embed。
enum MPVIntegrationStatus {
    static let mpvKitExpectedPath = "vbox/Libraries/MPV/MPVKit.xcframework"
    static let mpvKitDependenciesPath = "vbox/Libraries/MPV/MPVKitDependencies"
    static let mpvKitLibmpvDependencyPath = "vbox/Libraries/MPV/MPVKitDependencies/Libmpv.xcframework"
    static let freedomLibmpvExpectedPath = "vbox/Libraries/MPV/Freedom/libmpv.xcframework"
    static let libmpvExpectedPath = freedomLibmpvExpectedPath

    static let preferredBackend: MPVBackendType = .mpvKit
    static let freedomBackend: MPVBackendType = .libmpv

    static let mpvKitDisplayName = "MPV"
    static let libmpvDisplayName = "自由度"

    static let requiresDeviceArm64 = true
    static let recommendsSimulatorArm64 = true

    static let manifests = MPVFrameworkManifests.all
    static let mpvKitManifest = MPVFrameworkManifests.mpvKit
    static let libmpvManifest = MPVFrameworkManifests.libmpv

    static var isMPVKitFrameworkLinked: Bool {
        return MPVKitBackend.initializationProbeResult.isInitialized
    }

    static var isLibMPVFrameworkLinked: Bool {
        return false
    }

    static var dependencySummary: String {
        manifests.map { $0.shortSummary }.joined(separator: "\n")
    }

    /// 3.150 step。链接验证分支用。
    /// 直接读取 MPVKitBackend 的编译期探针，告诉调试位 MPVKit 模块是否真的被 import 进来。
    /// 不调用任何 MPVKit/libmpv 运行时 API。
    static var moduleProbeResult: String {
        return MPVKitBackend.moduleProbeResult
    }

    /// 3.151 step。App 内可见的 MPVKit 运行时加载诊断。
    /// 只做动态库存在性和 dlopen 检查，不启用正式播放后端。
    static var runtimeProbeSummary: String {
        return MPVKitBackend.runtimeProbeResult.summary
    }

    static var isMPVKitRuntimeLoadable: Bool {
        return MPVKitBackend.runtimeProbeResult.isDynamicallyLoadable
    }

    /// 3.152 step。App 内可见的 MPVKit/Libmpv 最小初始化诊断。
    /// 只做 mpv_create / mpv_initialize / destroy，不启用正式播放后端。
    static var initializationProbeSummary: String {
        return MPVKitBackend.initializationProbeResult.summary
    }

    static var isMPVKitInitializationReady: Bool {
        return MPVKitBackend.initializationProbeResult.isInitialized
    }

    /// 3.161 step。手动触发的 MPV loadfile 探针。
    /// 只验证普通测试媒体能否进入 MPV 加载事件流，不接正式播放链路。
    static func runLoadfileProbe() -> MPVKitLoadfileProbeResult {
        return MPVKitBackend.runLoadfileProbe()
    }

    /// 3.162 step。手动触发的 MPV 综合控制探针。
    /// 验证 loadfile 后的属性读取、暂停/恢复、倍速和 seek 命令，不接正式播放链路。
    static func runPlaybackControlProbe() -> MPVKitPlaybackControlProbeResult {
        return MPVKitBackend.runPlaybackControlProbe()
    }

    /// 3.164 step。MPV 全量诊断入口，集中暴露日志、音频、视频、网络和生命周期探针。
    static func runLogSamplingProbe() -> MPVKitDiagnosticProbeResult {
        return MPVKitBackend.runLogSamplingProbe()
    }

    static func runAudioOutputProbe() -> MPVKitDiagnosticProbeResult {
        return MPVKitBackend.runAudioOutputProbe()
    }

    static func runVideoOutputCapabilityProbe() -> MPVKitDiagnosticProbeResult {
        return MPVKitBackend.runVideoOutputCapabilityProbe()
    }

    static func runNetworkPlaybackProbe() -> MPVKitDiagnosticProbeResult {
        return MPVKitBackend.runNetworkPlaybackProbe()
    }

    static func runLifecycleStressProbe() -> MPVKitDiagnosticProbeResult {
        return MPVKitBackend.runLifecycleStressProbe()
    }

    static func isFrameworkLinked(for backendType: MPVBackendType) -> Bool {
        switch backendType {
        case .automatic:
            return isMPVKitFrameworkLinked || isLibMPVFrameworkLinked
        case .mpvKit:
            return isMPVKitFrameworkLinked
        case .libmpv:
            return isLibMPVFrameworkLinked
        }
    }

    static func disabledReason(for backendType: MPVBackendType) -> String {
        if backendType == .automatic {
            return "当前构建未启用 MPVKit 或自由度内核。MPVKit 最小链路需要先通过 mpv_create / mpv_initialize；自由度内核仍只预留 Freedom/libmpv.xcframework 路径。"
        }

        return MPVFrameworkManifests.manifest(for: backendType)?.unavailableReason
            ?? "当前构建未启用 \(backendType.displayName) 内核"
    }
}
