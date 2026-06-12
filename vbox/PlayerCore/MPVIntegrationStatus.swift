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
        return false
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
            return "当前构建未启用 MPVKit 或自由度内核。MPVKit 已识别 binary bundle 中的 Libmpv 和 FFmpeg 核心组件，但尚未安装到 MPVKitDependencies 并验证完整链接链路；自由度内核仍只预留 Freedom/libmpv.xcframework 路径。"
        }

        return MPVFrameworkManifests.manifest(for: backendType)?.unavailableReason
            ?? "当前构建未启用 \(backendType.displayName) 内核"
    }
}
