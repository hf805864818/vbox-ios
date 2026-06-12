import Foundation

/// MPV framework 接入状态说明。
/// 当前已放入 MPVKit.xcframework wrapper，但在底层依赖补齐前不主动 link/embed。
enum MPVIntegrationStatus {
    static let mpvKitExpectedPath = "vbox/Libraries/MPV/MPVKit.xcframework"
    static let libmpvExpectedPath = "vbox/Libraries/MPV/libmpv.xcframework"

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
            return "当前构建未启用 MPVKit 或自由度内核。MPVKit 已保留 wrapper 文件，但仍需补齐底层 Libmpv/FFmpeg 依赖；自由度内核仍等待 libmpv.xcframework 产物。"
        }

        return MPVFrameworkManifests.manifest(for: backendType)?.unavailableReason
            ?? "当前构建未启用 \(backendType.displayName) 内核"
    }
}
