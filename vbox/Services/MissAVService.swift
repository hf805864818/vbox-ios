import Foundation
import WebKit

struct MissAVMenuSection: Identifiable {
    let id: String
    let title: String
    let icon: String
    let children: [MissAVMenuItem]
}

struct MissAVMenuItem: Identifiable {
    let id: String
    let title: String
    let path: String
}

struct MissAVPlayableSource {
    let url: String
    let headers: [String: String]
}

@MainActor
final class MissAVService: ObservableObject {
    static let shared = MissAVService()

    @Published var isLoading = false
    @Published var errorMessage: String?

    let baseURLs = ["https://missav.ws", "https://missav.com"]

    let sections: [MissAVMenuSection] = [
        MissAVMenuSection(id: "subtitle", title: "中文字幕", icon: "captions.bubble.fill", children: [
            MissAVMenuItem(id: "subtitle-main", title: "中文字幕", path: "/cn/chinese-subtitle")
        ]),
        MissAVMenuSection(id: "japan-av", title: "观看日本 AV", icon: "play.rectangle.fill", children: [
            MissAVMenuItem(id: "latest", title: "最新", path: "/cn"),
            MissAVMenuItem(id: "actress", title: "女优", path: "/cn/actresses"),
            MissAVMenuItem(id: "genres", title: "类型", path: "/cn/genres"),
            MissAVMenuItem(id: "makers", title: "片商", path: "/cn/makers")
        ]),
        MissAVMenuSection(id: "amateur", title: "素人", icon: "person.fill", children: [
            MissAVMenuItem(id: "amateur-main", title: "素人", path: "/cn/amateur")
        ]),
        MissAVMenuSection(id: "uncensored", title: "无码影片", icon: "eye.fill", children: [
            MissAVMenuItem(id: "uncensored-main", title: "无码影片", path: "/cn/uncensored"),
            MissAVMenuItem(id: "fc2", title: "FC2", path: "/cn/fc2")
        ]),
        MissAVMenuSection(id: "asia-av", title: "亚洲 AV", icon: "globe.asia.australia.fill", children: [
            MissAVMenuItem(id: "asia-main", title: "亚洲 AV", path: "/cn/asian")
        ])
    ]

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    func loadVideos(for item: MissAVMenuItem) async -> [VodItem] {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        if let html = await fetchHTML(path: item.path) {
            let parsed = parseVideoList(from: html)
            if !parsed.isEmpty { return parsed }
        }
        return fallbackMockVideos(for: item)
    }

    func resolvePlayableSource(for video: VodItem) async -> MissAVPlayableSource? {
        guard let detailURL = video.vodPlayUrl, !detailURL.isEmpty else { return nil }
        if let html = await fetchHTML(fullURL: detailURL),
           let source = parsePlayableSource(from: html, detailURL: detailURL) {
            return source
        }
        return nil
    }

    private func fetchHTML(path: String? = nil, fullURL: String? = nil) async -> String? {
        let candidates: [String]
        if let fullURL, !fullURL.isEmpty {
            candidates = [fullURL]
        } else if let path {
            candidates = baseURLs.map { $0 + path }
        } else {
            return nil
        }
        for urlString in candidates {
            if let html = await fetchHTMLViaSession(urlString: urlString) { return html }
            if let html = await fetchHTMLViaWebView(urlString: urlString) { return html }
        }
        return nil
    }

    private func fetchHTMLViaSession(urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(Self.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh-Hans;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue(baseURLs[0] + "/", forHTTPHeaderField: "Referer")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                return String(data: data, encoding: .utf8)
            }
        } catch {}
        return nil
    }

    private func fetchHTMLViaWebView(urlString: String) async -> String? {
        do {
            let result = try await BaiduWebViewBridge.shared.request(
                url: urlString,
                headers: [
                    "User-Agent": Self.mobileUserAgent,
                    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                    "Accept-Language": "zh-CN,zh-Hans;q=0.9,en;q=0.8",
                    "Referer": baseURLs[0] + "/"
                ],
                timeout: 12
            )
            return String(data: result.data, encoding: .utf8)
        } catch {}
        return nil
    }

    private func parseVideoList(from html: String) -> [VodItem] {
        let normalized = html
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\r", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "\\/", with: "/")

        var items: [VodItem] = []
        var seen = Set<String>()
        let blockPatterns = [
            "<a[^>]+href=\"([^\"]*?/cn/[^\"]+)\"[^>]*>(.*?)</a>",
            "<a[^>]+href=\"([^\"]*?/dm\\d+/[^\"]+)\"[^>]*>(.*?)</a>",
            "<a[^>]+href=\"([^\"]*?/video/[^\"]+)\"[^>]*>(.*?)</a>"
        ]

        for pattern in blockPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            let ns = normalized as NSString
            for match in regex.matches(in: normalized, range: NSRange(location: 0, length: ns.length)) {
                guard match.numberOfRanges >= 3 else { continue }
                let href = ns.substring(with: match.range(at: 1))
                let block = ns.substring(with: match.range(at: 2))
                let detail = absoluteURL(href)
                guard !seen.contains(detail) else { continue }
                let image = firstMatch(in: block, patterns: ["data-src=\"([^\"]+)\"", "src=\"([^\"]+)\"", "poster=\"([^\"]+)\""]) ?? ""
                let title = cleanTitle(firstMatch(in: block, patterns: ["title=\"([^\"]+)\"", "alt=\"([^\"]+)\"", "<h3[^>]*>(.*?)</h3>", "<span[^>]*class=\"[^\"]*title[^\"]*\"[^>]*>(.*?)</span>"]) ?? "")
                let finalTitle = title.isEmpty ? ((detail.components(separatedBy: "/").last ?? UUID().uuidString).replacingOccurrences(of: "-", with: " ")) : title
                let vodId = detail.components(separatedBy: "/").last ?? UUID().uuidString
                items.append(VodItem(vodId: vodId, vodName: finalTitle, vodPic: normalizeImageURL(image), vodRemarks: vodId.uppercased(), vodArea: "MissAV", vodContent: finalTitle, vodPlayFrom: "missav", vodPlayUrl: detail))
                seen.insert(detail)
                if items.count >= 40 { return items }
            }
        }

        let jsonLikePattern = "\"thumbnail\"\\s*:\\s*\"([^\"]+)\".*?\"title\"\\s*:\\s*\"([^\"]+)\".*?\"url\"\\s*:\\s*\"([^\"]+)\""
        if let regex = try? NSRegularExpression(pattern: jsonLikePattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let ns = normalized as NSString
            for match in regex.matches(in: normalized, range: NSRange(location: 0, length: ns.length)) {
                guard match.numberOfRanges >= 4 else { continue }
                let image = ns.substring(with: match.range(at: 1))
                let title = cleanTitle(ns.substring(with: match.range(at: 2)))
                let detail = absoluteURL(ns.substring(with: match.range(at: 3)))
                guard !seen.contains(detail), !title.isEmpty else { continue }
                let vodId = detail.components(separatedBy: "/").last ?? UUID().uuidString
                items.append(VodItem(vodId: vodId, vodName: title, vodPic: normalizeImageURL(image), vodRemarks: vodId.uppercased(), vodArea: "MissAV", vodContent: title, vodPlayFrom: "missav", vodPlayUrl: detail))
                seen.insert(detail)
                if items.count >= 40 { return items }
            }
        }
        return items
    }

    private func parsePlayableSource(from html: String, detailURL: String) -> MissAVPlayableSource? {
        let normalized = html
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\r", with: " ")
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "&quot;", with: "\"")
        let patterns = [
            "https?://[^\"'\\s]+\\.m3u8[^\"'\\s]*",
            "https?://[^\"'\\s]+\\.mp4[^\"'\\s]*",
            "file\"\\s*:\\s*\"(https?://[^\"]+)\"",
            "src\\s*=\\s*\"(https?://[^\"]+\\.(?:m3u8|mp4)[^\"]*)\"",
            "contentUrl\\s*:\\s*\"(https?://[^\"]+)\"",
            "video_url\\s*=\\s*\"(https?://[^\"]+)\""
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                let ns = normalized as NSString
                if let match = regex.firstMatch(in: normalized, range: NSRange(location: 0, length: ns.length)) {
                    let raw = ns.substring(with: match.range(at: match.numberOfRanges > 1 ? 1 : 0))
                    if raw.hasPrefix("http") { return MissAVPlayableSource(url: raw, headers: playbackHeaders(detailURL: detailURL)) }
                }
            }
        }
        if let iframe = firstMatch(in: normalized, patterns: ["<iframe[^>]+src=\"([^\"]+)\"", "embedUrl\\s*:\\s*\"([^\"]+)\""]) {
            return MissAVPlayableSource(url: absoluteURL(iframe), headers: playbackHeaders(detailURL: detailURL))
        }
        return nil
    }

    private func playbackHeaders(detailURL: String) -> [String: String] {
        ["User-Agent": Self.mobileUserAgent, "Accept": "*/*", "Accept-Language": "zh-CN,zh-Hans;q=0.9,en;q=0.8", "Referer": detailURL, "Origin": detailURL.components(separatedBy: "/").prefix(3).joined(separator: "/")]
    }

    private func firstMatch(in text: String, patterns: [String]) -> String? {
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                let ns = text as NSString
                if let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                    return ns.substring(with: match.range(at: match.numberOfRanges > 1 ? 1 : 0))
                }
            }
        }
        return nil
    }

    private func cleanTitle(_ text: String) -> String {
        stripHTML(text)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private func normalizeImageURL(_ text: String) -> String {
        if text.hasPrefix("http") { return text }
        if text.hasPrefix("//") { return "https:" + text }
        if text.hasPrefix("/") { return baseURLs[0] + text }
        return text
    }

    private func absoluteURL(_ href: String) -> String {
        if href.hasPrefix("http") { return href }
        if href.hasPrefix("//") { return "https:" + href }
        if href.hasPrefix("/") { return baseURLs[0] + href }
        return baseURLs[0] + "/" + href
    }

    private func fallbackMockVideos(for item: MissAVMenuItem) -> [VodItem] {
        let base = baseURLs[0]
        return (1...12).map { index in
            let title = "\(item.title) 示例影片 \(index)"
            return VodItem(vodId: "missav-\(item.id)-\(index)", vodName: title, vodPic: "https://placehold.co/480x270/111827/F9FAFB?text=MISSAV+\(index)", vodRemarks: "MISSAV", vodArea: "MissAV", vodContent: title, vodPlayFrom: "missav", vodPlayUrl: base + item.path + "/demo-\(index)")
        }
    }

    static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
}
