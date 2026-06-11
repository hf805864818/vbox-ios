import Foundation

/// 播放线路类型，和播放器内核解耦。
/// 例如夸克可以同时提供原画 download_url 和流畅 v2/play m3u8 两条线路。
enum PlaybackRouteType: String {
    case originalDownload
    case smoothM3U8
    case direct
    case localProxy
}

struct PlaybackRoute {
    let type: PlaybackRouteType
    let url: URL
    let headers: [String: String]
    let title: String
    let priority: Int

    init(
        type: PlaybackRouteType,
        url: URL,
        headers: [String: String] = [:],
        title: String,
        priority: Int = 0
    ) {
        self.type = type
        self.url = url
        self.headers = headers
        self.title = title
        self.priority = priority
    }
}
