import Foundation

/// 统一播放器事件。AVPlayer、VLC、MPV 的回调后续都转换成这些事件给控制层和 UI。
enum PlayerEngineEvent {
    case ready
    case buffering(Bool)
    case progress(current: Double, duration: Double)
    case ended
    case failed(String)
    case log(String)
}
