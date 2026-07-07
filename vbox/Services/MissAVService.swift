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

    /// 动态 baseURL：优先从 WelfareCrawlerConfig 的自定义域名读取
    private var activeBaseURLs: [String] {
        if let custom = WelfareCrawlerConfig.config(for: "missav")?.effectiveBaseURL,
           !custom.isEmpty,
           custom != "https://missav.ws" {
            var urls = [custom]
            for fallback in defaultBaseURLs where fallback != custom {
                urls.append(fallback)
            }
            return urls
        }
        return defaultBaseURLs
    }

    private let defaultBaseURLs = ["https://missav.ws", "https://missav.com"]

    private var primaryBaseURL: String { activeBaseURLs.first ?? "https://missav.ws" }

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

    // MARK: - 公共接口

    func loadVideos(for item: MissAVMenuItem) async -> [VodItem] {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // 优先用 WebView 渲染（MissAV 大量内容靠 JS 动态加载）
        if let html = await fetchHTMLViaWebView(path: item.path) {
            let parsed = parseVideoList(from: html)
            if !parsed.isEmpty {
                print("[MissAVService] WebView解析成功: \(item.path) → \(parsed.count)条")
                return parsed
            }
            print("[MissAVService] WebView解析为空: \(item.path)")
        }

        // 回退到 URLSession
        if let html = await fetchHTMLViaSession(path: item.path) {
            let parsed = parseVideoList(from: html)
            if !parsed.isEmpty {
                print("[MissAVService] Session解析成功: \(item.path) → \(parsed.count)条")
                return parsed
            }
            print("[MissAVService] Session解析为空: \(item.path)")
        }

        print("[MissAVService] 所有方式均失败: \(item.path)")
        errorMessage = "无法加载 \(item.title)，请检查网络或切换域名"
        return []
    }

    /// 从 WelfareCrawlerService 调用的接口
    func loadVideosForSection(keyword: String, pageKind: WelfarePageKind, sectionName: String = "") async -> [VodItem] {
        let effectiveKeyword = keyword.isEmpty ? sectionName : keyword
        let item: MissAVMenuItem
        switch pageKind {
        case .video, .home:
            item = MissAVMenuItem(id: "latest", title: "最新", path: "/cn")
        case .actor:
            item = MissAVMenuItem(id: "actress", title: "女优", path: "/cn/actresses")
        case .classify:
            let kw = effectiveKeyword.lowercased()
            if kw.contains("有码") || kw.contains("censored") {
                item = MissAVMenuItem(id: "genres", title: "类型", path: "/cn/genres")
            } else if kw.contains("无码") || kw.contains("uncensored") {
                item = MissAVMenuItem(id: "uncensored-main", title: "无码影片", path: "/cn/uncensored")
            } else if kw.contains("欧美") || kw.contains("western") {
                item = MissAVMenuItem(id: "asia-main", title: "亚洲 AV", path: "/cn/asian")
            } else if kw.contains("中文") || kw.contains("chinese") {
                item = MissAVMenuItem(id: "subtitle-main", title: "中文字幕", path: "/cn/chinese-subtitle")
            } else {
                item = MissAVMenuItem(id: "genres", title: "类型", path: "/cn/genres")
            }
        case .search:
            return []
        default:
            item = MissAVMenuItem(id: "latest", title: "最新", path: "/cn")
        }
        return await loadVideos(for: item)
    }

    func resolvePlayableSource(for video: VodItem) async -> MissAVPlayableSource? {
        guard let detailURL = video.vodPlayUrl, !detailURL.isEmpty else { return nil }
        if let html = await fetchHTMLViaWebView(fullURL: detailURL),
           let source = parsePlayableSource(from: html, detailURL: detailURL) {
            return source
        }
        if let html = await fetchHTMLViaSession(fullURL: detailURL),
           let source = parsePlayableSource(from: html, detailURL: detailURL) {
            return source
        }
        return nil
    }

    // MARK: - URL 构建

    /// 智能拼接 URL：如果 baseURL 已包含目标 path，避免重复拼接
    private func buildURLs(path: String) -> [String] {
        activeBaseURLs.map { base in
            if base.hasSuffix(path) || base.hasSuffix(path + "/") {
                return base
            }
            if base.hasSuffix("/cn") && path.hasPrefix("/cn/") {
                return base + String(path.dropFirst(3))
            }
            if base.hasSuffix("/") && path.hasPrefix("/") {
                return base + String(path.dropFirst())
            }
            return base + path
        }
    }

    // MARK: - 网络请求

    private func fetchHTMLViaSession(path: String? = nil, fullURL: String? = nil) async -> String? {
        let candidates: [String]
        if let fullURL, !fullURL.isEmpty {
            candidates = [fullURL]
        } else if let path {
            candidates = buildURLs(path: path)
        } else {
            return nil
        }
        for urlString in candidates {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.setValue(Self.mobileUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("zh-CN,zh-Hans;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
            request.setValue(primaryBaseURL + "/", forHTTPHeaderField: "Referer")
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                    let html = String(data: data, encoding: .utf8) ?? ""
                    if !html.isEmpty {
                        print("[MissAVService] Session获取成功: \(urlString) (\(html.count)字节)")
                        return html
                    }
                }
            } catch {
                print("[MissAVService] Session请求失败: \(urlString) \(error.localizedDescription)")
            }
        }
        return nil
    }

    private func fetchHTMLViaWebView(path: String? = nil, fullURL: String? = nil) async -> String? {
        let candidates: [String]
        if let fullURL, !fullURL.isEmpty {
            candidates = [fullURL]
        } else if let path {
            candidates = buildURLs(path: path)
        } else {
            return nil
        }
        for urlString in candidates {
            // 优先使用 WKWebView 导航加载（绕过 Cloudflare XHR 检测）
            if let html = await fetchHTMLViaWebViewNavigation(urlString: urlString) {
                if !html.isEmpty {
                    print("[MissAVService] WebView导航获取成功: \(urlString) (\(html.count)字节)")
                    return html
                }
            }
            // 回退到原有的 XHR 方式
            do {
                let result = try await BaiduWebViewBridge.shared.request(
                    url: urlString,
                    headers: [
                        "User-Agent": Self.mobileUserAgent,
                        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                        "Accept-Language": "zh-CN,zh-Hans;q=0.9,en;q=0.8",
                        "Referer": primaryBaseURL + "/"
                    ],
                    timeout: 15
                )
                let html = String(data: result.data, encoding: .utf8) ?? ""
                if !html.isEmpty {
                    print("[MissAVService] WebView(XHR)获取成功: \(urlString) (\(html.count)字节)")
                    return html
                }
            } catch {
                print("[MissAVService] WebView(XHR)请求失败: \(urlString) \(error.localizedDescription)")
            }
        }
        return nil
    }

    /// 通过 WKWebView 导航加载页面获取 HTML（绕过 Cloudflare XHR 检测）
    private func fetchHTMLViaWebViewNavigation(urlString: String) async -> String? {
        print("[MissAVService] WebView导航请求: \(urlString)")
        
        let html = await withCheckedContinuation { continuation in
            MissAVNavigationLoader.loadHTML(
                urlString: urlString,
                userAgent: Self.mobileUserAgent,
                timeout: 20
            ) { result in
                continuation.resume(returning: result)
            }
        }
        
        if let html = html, !html.isEmpty {
            print("[MissAVService] WebView导航获取成功: \(urlString) (\(html.count)字节)")
        } else {
            print("[MissAVService] WebView导航获取失败或为空: \(urlString)")
        }
        return html
    }

    // MARK: - HTML 解析

    private func parseVideoList(from html: String) -> [VodItem] {
        let normalized = html
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\r", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "\\/", with: "/")

        var items: [VodItem] = []
        var seen = Set<String>()

        let titlePatterns = [
            #"title=["']([^"']{3,})["']"#,
            #"alt=["']([^"']{3,})["']"#,
            #"<span[^>]*class="[^"]*(?:title|name|text)[^"]*"[^>]*>([^<]{3,})</span>"#,
            #"<h[3-6][^>]*>([^<]{3,})</h[3-6]>"#,
            #"<div[^>]*class="[^"]*(?:title|name|text)[^"]*"[^>]*>([^<]{3,})</div>"#,
        ]

        // 策略1: 视频卡片区块提取
        let cardPatterns = [
            #"<div[^>]*data-(?:video-)?id[^>]*>(.*?)</div>"#,
            #"<(?:div|a|li)[^>]*class="[^"]*(?:video|item|card|thumbnail|vod|film)[^"]*"[^>]*>(.*?)</(?:div|a|li)>"#,
            #"<a[^>]*href="([^"]*(?:/cn/|/dm\d+/|/video/)[^"]*)"[^>]*>(.{20,500}?)</a>"#,
        ]

        for cardPattern in cardPatterns {
            guard let regex = try? NSRegularExpression(pattern: cardPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            let ns = normalized as NSString
            let range = NSRange(location: 0, length: ns.length)
            for match in regex.matches(in: normalized, range: range).prefix(50) {
                let block: String
                let href: String?
                if match.numberOfRanges >= 3 {
                    href = ns.substring(with: match.range(at: 1))
                    block = ns.substring(with: match.range(at: 2))
                } else if match.numberOfRanges >= 2 {
                    href = nil
                    block = ns.substring(with: match.range(at: 1))
                } else { continue }

                let detailURL: String
                if let h = href {
                    detailURL = absoluteURL(h)
                } else {
                    let h = firstMatch(in: block, patterns: [#"href="([^"]*(?:/cn/|/dm\d+/|/video/)[^"]*)""#])
                    detailURL = h.map { absoluteURL($0) } ?? ""
                    if detailURL.isEmpty { continue }
                }

                guard !seen.contains(detailURL) else { continue }
                seen.insert(detailURL)

                let image = firstMatch(in: block, patterns: [
                    #"data-src=["']([^"']+)["']"#,
                    #"src=["']([^"']+\.(?:jpg|jpeg|png|webp|gif)[^"']*)["']"#,
                    #"data-original=["']([^"']+)["']"#,
                    #"data-lazy-src=["']([^"']+)["']"#,
                    #"poster=["']([^"']+)["']"#,
                    #"https?://[^"'\s]+\.(?:jpg|jpeg|png|webp)[^"'\s]*"#,
                ]) ?? ""

                let title = cleanTitle(firstMatch(in: block, patterns: titlePatterns) ?? "")
                let finalTitle: String
                if title.isEmpty {
                    let lastPath = detailURL.components(separatedBy: "/").last ?? ""
                    finalTitle = lastPath.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: "-")
                } else {
                    finalTitle = title
                }

                let vodId = detailURL.components(separatedBy: "/").last?.replacingOccurrences(of: "-", with: "_") ?? UUID().uuidString
                items.append(VodItem(
                    vodId: vodId, vodName: finalTitle, vodPic: normalizeImageURL(image),
                    vodRemarks: "[福利]\(vodId.uppercased())", vodArea: "MissAV",
                    vodContent: finalTitle, vodPlayFrom: "missav", vodPlayUrl: detailURL
                ))
                if items.count >= 40 { return items }
            }
            if !items.isEmpty { break }
        }

        // 策略2: 全页链接扫描
        if items.isEmpty {
            print("[MissAVService] 卡片模式无结果，全页扫描")
            let blockPatterns = [
                #"<a[^>]*href="([^"]*(?:/cn/[^"]+|/dm\d+/[^"]+|/video/[^"]+))"[^>]*>(.{10,400}?)</a>"#,
                #"<a[^>]*href="([^"]*(?:/v/[^"]+))"[^>]*>(.{10,400}?)</a>"#,
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
                    seen.insert(detail)

                    let image = firstMatch(in: block, patterns: [
                        #"data-src=["']([^"']+)["']"#,
                        #"src=["']([^"']+(?:jpg|jpeg|png|webp)[^"']*)["']"#,
                        #"https?://[^"'\s]+\.(?:jpg|jpeg|png|webp)[^"'\s]*"#,
                    ]) ?? ""

                    let title = cleanTitle(firstMatch(in: block, patterns: titlePatterns) ?? "")
                    let finalTitle: String
                    if title.isEmpty {
                        let lastPath = detail.components(separatedBy: "/").last ?? ""
                        finalTitle = lastPath.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: "-")
                    } else {
                        finalTitle = title
                    }

                    let vodId = detail.components(separatedBy: "/").last?.replacingOccurrences(of: "-", with: "_") ?? UUID().uuidString
                    items.append(VodItem(
                        vodId: vodId, vodName: finalTitle, vodPic: normalizeImageURL(image),
                        vodRemarks: "[福利]\(vodId.uppercased())", vodArea: "MissAV",
                        vodContent: finalTitle, vodPlayFrom: "missav", vodPlayUrl: detail
                    ))
                    if items.count >= 40 { break }
                }
                if !items.isEmpty { break }
            }
        }

        // 策略3: JSON内嵌数据
        if items.isEmpty {
            let jsonPatterns = [
                #""thumbnail"\s*:\s*"([^"]+)".*?"title"\s*:\s*"([^"]+)".*?"url"\s*:\s*"([^"]+)""#,
                #""image"\s*:\s*"([^"]+)".*?"title"\s*:\s*"([^"]+)".*?"link"\s*:\s*"([^"]+)""#,
                #""img"\s*:\s*"([^"]+)".*?"name"\s*:\s*"([^"]+)".*?"href"\s*:\s*"([^"]+)""#,
                #"src:\s*"([^"]+)".*?title:\s*"([^"]+)".*?url:\s*"([^"]+)""#,
            ]
            for jsonPattern in jsonPatterns {
                guard let regex = try? NSRegularExpression(pattern: jsonPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
                let ns = normalized as NSString
                for match in regex.matches(in: normalized, range: NSRange(location: 0, length: ns.length)) {
                    guard match.numberOfRanges >= 4 else { continue }
                    let image = ns.substring(with: match.range(at: 1))
                    let title = cleanTitle(ns.substring(with: match.range(at: 2)))
                    let detail = absoluteURL(ns.substring(with: match.range(at: 3)))
                    guard !seen.contains(detail), !title.isEmpty else { continue }
                    seen.insert(detail)
                    let vodId = detail.components(separatedBy: "/").last ?? UUID().uuidString
                    items.append(VodItem(vodId: vodId, vodName: title, vodPic: normalizeImageURL(image), vodRemarks: "[福利]\(vodId.uppercased())", vodArea: "MissAV", vodContent: title, vodPlayFrom: "missav", vodPlayUrl: detail))
                    if items.count >= 40 { break }
                }
                if !items.isEmpty { break }
            }
        }

        print("[MissAVService] parseVideoList: 共解析到 \(items.count) 条")
        if items.isEmpty {
            let preview = String(html.prefix(300)).replacingOccurrences(of: "\n", with: " ")
            print("[MissAVService] HTML预览(300): \(preview)")
        }
        return items
    }

    // MARK: - 播放源解析

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

    // MARK: - 辅助

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
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private func normalizeImageURL(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http") { return trimmed }
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        if trimmed.hasPrefix("/") { return primaryBaseURL + trimmed }
        return trimmed
    }

    private func absoluteURL(_ href: String) -> String {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http") { return trimmed }
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        if trimmed.hasPrefix("/") { return primaryBaseURL + trimmed }
        return primaryBaseURL + "/" + trimmed
    }

    static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
}

// MARK: - MissAV WebView Navigation Delegate

final class MissAVWebViewDelegate: NSObject, WKNavigationDelegate {
    let completion: (String?) -> Void
    weak var webView: WKWebView?
    
    init(webView: WKWebView, completion: @escaping (String?) -> Void) {
        self.webView = webView
        self.completion = completion
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("""
            (function() {
                return document.documentElement ? document.documentElement.outerHTML : (document.body ? document.body.innerHTML : '');
            })();
        """) { [weak self] result, error in
            guard let self = self else { return }
            if let error = error {
                print("[MissAVService] WebView导航获取HTML失败: \(error.localizedDescription)")
                self.completion(nil)
                return
            }
            if let html = result as? String, !html.isEmpty {
                self.completion(html)
            } else {
                self.completion(nil)
            }
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[MissAVService] WebView导航加载失败: \(error.localizedDescription)")
        completion(nil)
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("[MissAVService] WebView导航预加载失败: \(error.localizedDescription)")
        completion(nil)
    }
}

final class MissAVNavigationLoader {
    static func loadHTML(urlString: String, userAgent: String, timeout: TimeInterval, completion: @escaping (String?) -> Void) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = userAgent
        var isCompleted = false
        let lock = DispatchSemaphore(value: 1)
        
        func complete(_ html: String?) {
            guard lock.wait(timeout: .now()) == .success else { return }
            defer { lock.signal() }
            guard !isCompleted else { return }
            isCompleted = true
            DispatchQueue.main.async {
                webView.stopLoading()
                webView.removeFromSuperview()
            }
            completion(html)
        }
        
        let delegate = MissAVWebViewDelegate(webView: webView) { html in
            complete(html)
        }
        webView.navigationDelegate = delegate
        
        var request = URLRequest(url: URL(string: urlString)!)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://missav.ws/", forHTTPHeaderField: "Referer")
        
        webView.load(request)
        
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2) {
            complete(nil)
        }
    }
}
