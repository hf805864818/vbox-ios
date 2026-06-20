import Foundation

/// 播放器内核类型。后续 UI 重构时只依赖这个枚举，不直接依赖 AVPlayer、VLC 或 MPV 实现。
enum PlayerEngineType: String, CaseIterable, Identifiable {
    case system
    case vlc
    case mpvKit
    case libmpv
    case mdk

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return "系统"
        case .vlc:
            return "VLC"
        case .mpvKit:
            return "MPV"
        case .libmpv:
            return "自由度"
        case .mdk:
            return "MDK"
        }
    }

    /// 当前引擎是否支持系统级画中画
    var supportsPiP: Bool {
        switch self {
        case .system:
            return true   // AVPlayerLayer 原生 PiP
        case .mdk:
            return true   // AVSampleBufferDisplayLayer 帧桥接 PiP
        case .mpvKit, .libmpv:
            return false  // TODO: Phase 2 实现帧桥接后改为 true
        case .vlc:
            return false  // VLC 不支持帧桥接 PiP
        }
    }
}
