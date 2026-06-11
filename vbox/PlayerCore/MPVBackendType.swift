import Foundation

/// MPV 后端类型。
/// UI 命名约定：MPVKit 显示为“MPV”，libmpv 显示为“自由度”。
enum MPVBackendType: String, CaseIterable, Identifiable {
    case automatic
    case mpvKit
    case libmpv

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic:
            return "自动"
        case .mpvKit:
            return "MPV"
        case .libmpv:
            return "自由度"
        }
    }
}
