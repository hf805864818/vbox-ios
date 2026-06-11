import Foundation

/// MPV framework 接入状态说明。
/// 当前已接入 MPVKit.xcframework wrapper，但真实播放逻辑仍在 MPVKitBackend 中保持占位。
enum MPVIntegrationStatus {
    static let mpvKitExpectedPath = "vbox/Libraries/MPV/MPVKit.xcframework"
    static let libmpvExpectedPath = "vbox/Libraries/MPV/libmpv.xcframework"

    static let preferredBackend: MPVBackendType = .mpvKit
    static let freedomBackend: MPVBackendType = .libmpv

    static let mpvKitDisplayName = "MPV"
    static let libmpvDisplayName = "自由度"

    static let requiresDeviceArm64 = true
    static let recommendsSimulatorArm64 = true

    static var isMPVKitFrameworkLinked: Bool {
        #if canImport(MPVKit)
        return true
        #else
        return false
        #endif
    }
}
