import Foundation

/// 播放器内核类型。后续 UI 重构时只依赖这个枚举，不直接依赖 AVPlayer、VLC 或 MPV 实现。
enum PlayerEngineType: String, CaseIterable, Identifiable {
    case system
    case vlc
    case mpv

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return "系统"
        case .vlc:
            return "VLC"
        case .mpv:
            return "MPV"
        }
    }
}
