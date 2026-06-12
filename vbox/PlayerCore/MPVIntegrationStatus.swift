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

    static var isMPVKitFrameworkLinked: Bool {
        return false
    }
}
