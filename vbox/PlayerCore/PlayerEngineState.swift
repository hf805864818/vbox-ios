import Foundation

/// 统一播放状态。后期 UI 重构只绑定这一层状态，避免 UI 直接读 AVPlayer/VLC/MPV 的内部对象。
struct PlayerEngineState {
    var isPlaying: Bool
    var isBuffering: Bool
    var isEnded: Bool
    var currentTime: Double
    var duration: Double
    var bufferedTime: Double
    var width: Int
    var height: Int
    var errorMessage: String?

    init(
        isPlaying: Bool = false,
        isBuffering: Bool = false,
        isEnded: Bool = false,
        currentTime: Double = 0,
        duration: Double = 0,
        bufferedTime: Double = 0,
        width: Int = 0,
        height: Int = 0,
        errorMessage: String? = nil
    ) {
        self.isPlaying = isPlaying
        self.isBuffering = isBuffering
        self.isEnded = isEnded
        self.currentTime = currentTime
        self.duration = duration
        self.bufferedTime = bufferedTime
        self.width = width
        self.height = height
        self.errorMessage = errorMessage
    }
}
