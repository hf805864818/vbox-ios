import UIKit

/// 统一播放器内核协议。后续 AVPlayer、VLC、MPV 都实现这一套接口。
/// 当前阶段只建立抽象，不替换现有播放流程。
protocol PlayerEngine: AnyObject {
    var type: PlayerEngineType { get }
    var name: String { get }
    var state: PlayerEngineState { get }
    var onEvent: ((PlayerEngineEvent) -> Void)? { get set }

    func attach(to view: UIView)
    func load(route: PlaybackRoute)
    func play()
    func pause()
    func stop()
    func seek(to seconds: Double)
    func setRate(_ rate: Double)
    func setVolume(_ volume: Double)
    func teardown()
}
