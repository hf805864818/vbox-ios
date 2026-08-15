//
//  MediaURLChecker.swift
//  vbox
//
//  媒体直链检测工具 — 判断 URL 是否可直接交给播放器播放。
//
//  作用：避免把网页播放页、官方平台页或解析页当成直链传给播放器。
//  共享使用方：
//  - FuliVideoBridgeView：判断剧集URL是否是直链，决定是否传 preParsedEpisodes
//  - PlayerViewsV2：playerContent 结果判断、福利兜底判断
//

import Foundation

enum MediaURLChecker {

    /// 判断 URL 是否像可直接交给播放器的媒体地址。
    static func isLikelyDirectMediaUrl(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowerUrl = trimmed.lowercased()
        guard isStandardPlayScheme(lowerUrl) else { return false }

        if let url = URL(string: trimmed) {
            let host = (url.host ?? "").lowercased()
            let path = url.path.lowercased()
            let ext = url.pathExtension.lowercased()

            if host == "127.0.0.1" || host == "localhost" {
                return true
            }

            let mediaExts = ["m3u8", "mp4", "flv", "m4v", "mov", "ts", "webm", "mkv", "avi", "m4s"]
            if mediaExts.contains(ext) { return true }

            if path.contains(".m3u8") || path.contains(".mp4") || path.contains(".flv") || path.contains(".ts") {
                return true
            }
        }

        let mediaMarkers = [
            ".m3u8", ".mp4", ".flv", ".m4v", ".mov", ".ts", ".webm", ".mkv", ".avi", ".m4s",
            "/m3u8", "m3u8?", "hls", "playlist", "streaming", "/stream", "/playurl"
        ]
        return mediaMarkers.contains { lowerUrl.contains($0) }
    }

    /// 判断是否是播放器支持的标准协议（http/https/file/rtmp/rtsp）
    static func isStandardPlayScheme(_ lowerUrl: String) -> Bool {
        return lowerUrl.hasPrefix("http://")
            || lowerUrl.hasPrefix("https://")
            || lowerUrl.hasPrefix("file://")
            || lowerUrl.hasPrefix("rtmp://")
            || lowerUrl.hasPrefix("rtsp://")
    }
}
