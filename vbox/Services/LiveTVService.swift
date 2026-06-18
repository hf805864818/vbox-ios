import Foundation
import SwiftUI

// MARK: - 直播频道模型
struct LiveChannel: Identifiable, Codable {
    let id: String
    let name: String
    let tid: String
    let channelId: String
    let token: String
    let logo: String?
    /// 多线路播放地址列表（解析后填充）
    var sources: [String]

    /// 构建播放页面URL
    var playURL: String {
        return "http://m.iptv807.com/?act=play&token=\(token)&tid=\(tid)&id=\(channelId)"
    }

    /// 构建M3U8直链（通过解析播放页获取）
    var m3u8URL: String? {
        return LiveTVService.shared.m3u8Cache[id]
    }

    /// 线路数量
    var routeCount: Int {
        return max(1, sources.count)
    }

    /// 获取指定线路的播放地址
    func routeURL(index: Int) -> String? {
        if !sources.isEmpty {
            let idx = min(index, sources.count - 1)
            return sources[idx]
        }
        return m3u8URL
    }
}

// MARK: - 直播分类
struct LiveCategory: Identifiable {
    let id: String
    let name: String
    let tid: String
    let icon: String

    var tintColor: Color {
        switch id {
        case "itv": return Color.blue
        case "ty": return Color.green
        case "ys": return Color.red
        case "ws": return Color.orange
        case "gt": return Color.purple
        case "movie": return Color.pink
        case "migu": return Color.cyan
        case "fjitv", "hlitv": return Color.teal
        case "ipv6": return Color.indigo
        default: return Color.gray
        }
    }

    var backgroundColor: Color { tintColor }
}

// MARK: - 直播服务
class LiveTVService: ObservableObject {
    static let shared = LiveTVService()
    
    private let baseURL = "http://m.iptv807.com"
    private let session: URLSession
    
    /// M3U8缓存 [channelId: m3u8URL]
    var m3u8Cache: [String: String] = [:]
    
    /// 分类列表
    let categories: [LiveCategory] = [
        LiveCategory(id: "itv", name: "综合", tid: "itv", icon: "tv"),
        LiveCategory(id: "ty", name: "体育", tid: "ty", icon: "sportscourt"),
        LiveCategory(id: "ys", name: "央视", tid: "ys", icon: "antenna.radiowaves.left.and.right"),
        LiveCategory(id: "ws", name: "卫视", tid: "ws", icon: "tv.inset.filled"),
        LiveCategory(id: "gt", name: "港澳台", tid: "gt", icon: "globe.asia.australia"),
        LiveCategory(id: "other", name: "其他", tid: "other", icon: "ellipsis.circle"),
        LiveCategory(id: "movie", name: "电影", tid: "movie", icon: "film"),
        LiveCategory(id: "migu", name: "咪咕", tid: "migu", icon: "play.circle"),
        LiveCategory(id: "fjitv", name: "福建IPTV", tid: "fjitv", icon: "network"),
        LiveCategory(id: "hlitv", name: "黑龙江IPTV", tid: "hlitv", icon: "network"),
        LiveCategory(id: "ipv6", name: "IPv6", tid: "ipv6", icon: "wifi")
    ]
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9"
        ]
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - 获取分类频道列表
    func fetchChannels(tid: String) async -> [LiveChannel] {
        guard let url = URL(string: "\(baseURL)/?tid=\(tid)") else { return [] }
        
        do {
            let (data, _) = try await session.data(from: url)
            guard let html = String(data: data, encoding: .utf8) else { return [] }
            return parseChannels(from: html, tid: tid)
        } catch {
            print("[LiveTV] 获取频道失败: \(error)")
            return []
        }
    }
    
    // MARK: - 解析频道列表（从HTML中提取）
    private func parseChannels(from html: String, tid: String) -> [LiveChannel] {
        var channels: [LiveChannel] = []
        
        // 匹配模式: <a href="https://m.iptv807.com/?act=play&token=xxx&tid=ys&id=1">CCTV1综合</a>
        let pattern = #"<a\s+href="https?://m\.iptv807\.com/\?act=play&token=([^"]+)&tid=([^"]+)&id=([^"]+)"[^>]*>([^<]+)</a>"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let matches = regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
        
        for match in matches {
            guard match.numberOfRanges >= 5 else { continue }
            
            let token = String(html[Range(match.range(at: 1), in: html)!])
            let matchTid = String(html[Range(match.range(at: 2), in: html)!])
            let channelId = String(html[Range(match.range(at: 3), in: html)!])
            let name = String(html[Range(match.range(at: 4), in: html)!])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            // 只取当前分类的频道
            guard matchTid == tid else { continue }
            
            let channel = LiveChannel(
                id: "\(tid)_\(channelId)",
                name: name,
                tid: tid,
                channelId: channelId,
                token: token,
                logo: nil,
                sources: []
            )
            channels.append(channel)
        }
        
        return channels
    }
    
    // MARK: - 解析M3U8播放地址
    func resolveM3U8(channel: LiveChannel) async -> String? {
        // 先查缓存
        if let cached = m3u8Cache[channel.id] { return cached }

        guard let url = URL(string: channel.playURL) else { return nil }

        do {
            let (data, _) = try await session.data(from: url)
            guard let html = String(data: data, encoding: .utf8) else { return nil }

            // 提取所有匹配的URL作为多线路
            var allSources: [String] = []
            let patterns = [
                #"src\s*=\s*["']([^"']+\.m3u8[^"']*)["']"#,
                #"url\s*[:=]\s*["']([^"']+\.m3u8[^"']*)["']"#,
                #"(https?://[^\s"'<>]+\.m3u8[^\s"'<>]*)"#,
                #"var\s+url\s*=\s*["']([^"']+)["']"#,
                #"player\s*\(\s*["']([^"']+)["']"#
            ]

            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    let matches = regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
                    for match in matches {
                        guard match.numberOfRanges >= 2,
                              let range = Range(match.range(at: 1), in: html) else { continue }
                        var m3u8 = String(html[range])
                        // 处理相对路径
                        if m3u8.hasPrefix("//") { m3u8 = "https:" + m3u8 }
                        else if m3u8.hasPrefix("/") { m3u8 = baseURL + m3u8 }
                        else if !m3u8.hasPrefix("http") { m3u8 = baseURL + "/" + m3u8 }
                        if m3u8.contains(".m3u8") && !allSources.contains(m3u8) {
                            allSources.append(m3u8)
                        }
                    }
                }
            }

            // 如果都没找到，尝试iframe
            let iframePattern = #"<iframe[^>]+src=["']([^"']+)["']"#
            if let regex = try? NSRegularExpression(pattern: iframePattern, options: []),
               let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
               match.numberOfRanges >= 2,
               let range = Range(match.range(at: 1), in: html) {
                let iframeSrc = String(html[range])
                if iframeSrc.contains(".m3u8") && !allSources.contains(iframeSrc) {
                    allSources.append(iframeSrc)
                }
            }

            // 缓存第一个线路
            if let first = allSources.first {
                m3u8Cache[channel.id] = first
                return first
            }
            return nil
        } catch {
            print("[LiveTV] 解析M3U8失败: \(error)")
            return nil
        }
    }

    // MARK: - 解析频道所有可用线路
    func resolveAllSources(channel: LiveChannel) async -> [String] {
        // 先查缓存
        if let cached = m3u8Cache[channel.id], !cached.isEmpty {
            // 如果只有一个缓存，直接返回
            return [cached]
        }

        guard let url = URL(string: channel.playURL) else { return [] }

        do {
            let (data, _) = try await session.data(from: url)
            guard let html = String(data: data, encoding: .utf8) else { return [] }

            var allSources: [String] = []
            let patterns = [
                #"src\s*=\s*["']([^"']+\.m3u8[^"']*)["']"#,
                #"url\s*[:=]\s*["']([^"']+\.m3u8[^"']*)["']"#,
                #"(https?://[^\s"'<>]+\.m3u8[^\s"'<>]*)"#,
                #"var\s+url\s*=\s*["']([^"']+)["']"#,
                #"player\s*\(\s*["']([^"']+)["']"#
            ]

            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    let matches = regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
                    for match in matches {
                        guard match.numberOfRanges >= 2,
                              let range = Range(match.range(at: 1), in: html) else { continue }
                        var m3u8 = String(html[range])
                        if m3u8.hasPrefix("//") { m3u8 = "https:" + m3u8 }
                        else if m3u8.hasPrefix("/") { m3u8 = baseURL + m3u8 }
                        else if !m3u8.hasPrefix("http") { m3u8 = baseURL + "/" + m3u8 }
                        if m3u8.contains(".m3u8") && !allSources.contains(m3u8) {
                            allSources.append(m3u8)
                        }
                    }
                }
            }

            // 缓存第一个
            if let first = allSources.first {
                m3u8Cache[channel.id] = first
            }
            return allSources
        } catch {
            print("[LiveTV] 解析线路失败: \(error)")
            return []
        }
    }
    
    // MARK: - 获取回看节目单
    func fetchEPG(channel: LiveChannel, day: String) async -> [(time: String, title: String)] {
        guard let url = URL(string: "\(baseURL)/?act=play&playtype=lookback&day=\(day)&token=\(channel.token)&tid=\(channel.tid)&id=\(channel.channelId)") else { return [] }
        
        do {
            let (data, _) = try await session.data(from: url)
            guard let html = String(data: data, encoding: .utf8) else { return [] }
            return parseEPG(from: html)
        } catch {
            return []
        }
    }
    
    private func parseEPG(from html: String) -> [(time: String, title: String)] {
        var programs: [(time: String, title: String)] = []
        
        // 匹配节目单: [00:17 今日说法回看]
        let pattern = #"\[(\d{2}:\d{2})\s+([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let matches = regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
        
        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let time = String(html[Range(match.range(at: 1), in: html)!])
            let title = String(html[Range(match.range(at: 2), in: html)!])
                .replacingOccurrences(of: "回看", with: "")
                .trimmingCharacters(in: .whitespaces)
            programs.append((time: time, title: title))
        }
        
        return programs
    }
    
    // MARK: - 清空缓存
    func clearCache() {
        m3u8Cache.removeAll()
    }
}
