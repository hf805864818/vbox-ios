import Foundation

/// MPV framework 接入状态说明。
/// 这里只记录预期路径和命名约定，不直接链接不存在的 framework。
enum MPVIntegrationStatus {
    static let mpvKitExpectedPath = "vbox/Libraries/MPV/MPVKit.xcframework"
    static let libmpvExpectedPath = "vbox/Libraries/MPV/libmpv.xcframework"

    static let preferredBackend: MPVBackendType = .mpvKit
    static let freedomBackend: MPVBackendType = .libmpv

    static let mpvKitDisplayName = "MPV"
    static let libmpvDisplayName = "自由度"

    static let requiresDeviceArm64 = true
    static let recommendsSimulatorArm64 = true
}
