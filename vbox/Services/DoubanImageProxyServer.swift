import Foundation
import Network
import Compression
import Security

extension Notification.Name {
    static let vboxBaiduStreamCacheProgress = Notification.Name("vbox.baidu.stream.cache.progress")
}

final class DoubanImageProxyServer {
    static let shared = DoubanImageProxyServer()

    private let proxyPrefix = "proxy://"
    private let queue = DispatchQueue(label: "com.vbox.douban-image-proxy")
    private let cache = NSCache<NSString, NSData>()
    private var listener: NWListener?
    private var streamItems: [String: StreamItem] = [:]
    let baiduStreamCache = BaiduStreamSegmentCache()
    private(set) var port: UInt16 = 18080

    private struct StreamItem {
        let url: URL
        let headers: [String: String]
        let provider: String
        let createdAt: Date
    }

    private static let baiduPCSUserAgent = "netdisk;1.4.2;22021211RC;android-android;12;JSbridge4.4.0;jointBridge;1.1.0;"

    private let allowedHosts: Set<String> = [
        "img1.doubanio.com",
        "img2.doubanio.com",
        "img3.doubanio.com",
        "img9.doubanio.com",
        "qnmob1.doubanio.com",
        "qnmob2.doubanio.com",
        "qnmob3.doubanio.com",
        "qnmob4.doubanio.com",
        "img1.douban.com",
        "img2.douban.com",
        "img3.douban.com",
        "img9.douban.com",
        "image.tmdb.org",
        "media.themoviedb.org"
    ]

    private init() {
        cache.countLimit = 300
        cache.totalCostLimit = 80 * 1024 * 1024
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }

            do {
                // 明确绑定到本地回环 IPv4，避免双栈下 AVPlayer 走 IPv6 解析失败导致连接被丢。
                let parameters = NWParameters.tcp
                parameters.requiredInterfaceType = .loopback
                if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                    ipOptions.version = .v4
                }
                let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: self.port)!)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        print("✅ 本地代理已启动: http://127.0.0.1:\(self.port)")
                    case .failed(let error):
                        print("❌ 豆瓣封面本地代理启动失败: \(error)")
                        self.listener?.cancel()
                        self.listener = nil
                    default:
                        break
                    }
                }
                listener.start(queue: self.queue)
                self.listener = listener
            } catch {
                print("❌ 豆瓣封面本地代理创建失败: \(error)")
            }
        }
    }

    func markedURLString(for rawURL: String?) -> String? {
        guard let targetURLString = targetURLString(from: rawURL), isAllowedDoubanImageURL(targetURLString) else {
            return rawURL
        }

        return proxyPrefix + targetURLString
    }

    func resolvedURL(for urlString: String?) -> URL? {
        guard let urlString, !urlString.isEmpty else { return nil }

        if urlString.hasPrefix(proxyPrefix) {
            return localProxyURL(for: String(urlString.dropFirst(proxyPrefix.count)))
        }

        return URL(string: urlString)
    }

    func proxiedURL(for rawURL: String?) -> URL? {
        guard let targetURLString = targetURLString(from: rawURL), isAllowedDoubanImageURL(targetURLString) else {
            return rawURL.flatMap(URL.init(string:))
        }

        return localProxyURL(for: targetURLString)
    }

    func proxiedStreamURL(for sourceURL: String, headers: [String: String], provider: String = "baidu") -> URL? {
        guard let targetURL = URL(string: sourceURL),
              isAllowedStreamURL(sourceURL) || provider == "sihu" || provider == "xcp" || provider == "mystery"
        else {
            return URL(string: sourceURL)
        }

        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        // 过期清理移到 async，避免阻塞主线程
        queue.async { self.cleanupExpiredStreams() }
        // 仅同步注册 stream item，确保 URL 返回后可立即被请求
        let item = StreamItem(
            url: targetURL,
            headers: headers,
            provider: provider,
            createdAt: Date()
        )
        queue.sync {
            self.streamItems[id] = item
        }
        let cookie = Self.headerValue(headers, "Cookie") ?? Self.headerValue(headers, "X-Baidu-Pcs-Cookie") ?? ""
        let lowerCookie = cookie.lowercased()
        print("✅ 注册本地视频代理[\(provider)]: id=\(id), host=\(targetURL.host ?? ""), hasCookie=\(!cookie.isEmpty), hasBDUSS=\(lowerCookie.contains("bduss=")), hasSTOKEN=\(lowerCookie.contains("stoken=")), hasPANPSC=\(lowerCookie.contains("panpsc=")), headerKeys=\(headers.keys.sorted().joined(separator: ","))")
        // 预热也移到 async
        queue.async { self.preheatStream(item: item, id: id) }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/\(provider)-stream"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url
    }

    func reportBaiduStreamProgress(localURL: URL?, currentTime: Double, duration: Double) {
        guard let localURL,
              localURL.host == "127.0.0.1",
              localURL.path.contains("baidu-stream"),
              currentTime.isFinite,
              duration.isFinite,
              duration > 0,
              let components = URLComponents(url: localURL, resolvingAgainstBaseURL: false),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value
        else { return }

        // 百度网盘HTTP连接有数据量/时间限制，当集分片预加载会加速触发连接重置
        // 当集预加载已禁用，仅保留下一集预加载（prefetchNextBaiduFile）
        // 此方法仍保留用于发送缓存进度通知
        queue.async { [weak self] in
            self?.baiduStreamCache.postProgress(id: id)
        }
    }

    func proxiedQuarkM3U8URL(for sourceURL: String, headers: [String: String]) -> URL? {
        guard let targetURL = URL(string: sourceURL),
              isAllowedQuarkM3U8URL(sourceURL)
        else {
            return URL(string: sourceURL)
        }

        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        // 过期清理移到 async，避免阻塞主线程
        queue.async { self.cleanupExpiredStreams() }
        let item = StreamItem(
            url: targetURL,
            headers: headers,
            provider: "quark-m3u8",
            createdAt: Date()
        )
        queue.sync {
            self.streamItems[id] = item
        }
        let cookie = Self.headerValue(headers, "Cookie") ?? ""
        print("✅ 注册夸克 m3u8 代理: id=\(id), host=\(targetURL.host ?? ""), hasCookie=\(!cookie.isEmpty), hasVideoAuth=\(cookie.contains("Video-Auth="))")

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/quark-m3u8"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url
    }

    // MARK: - 六速社区 m3u8 代理
    //
    // 六速社区 API 服务器使用自签名 SSL 证书，AVPlayer 无法直接加载。
    // 同时 m3u8 中 key URI 和 TS 分片路径可能是相对路径，需要重写为绝对路径
    // 或替换为本地代理 URL。此方法注册一个 m3u8 代理项，返回本地 HTTP URL。
    //
    // 与 Python Spider 的 localProxy 机制完全对应：
    // - m3u8 请求：下载 → 解压 → 修复 key URI → 返回修改后的 m3u8
    // - key/TS 请求：代理转发（SSL 绕过 + 自定义 header）
    func proxiedLusushequM3U8URL(for sourceURL: String, headers: [String: String]) -> URL? {
        guard let targetURL = URL(string: sourceURL) else {
            return URL(string: sourceURL)
        }

        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        queue.async { self.cleanupExpiredStreams() }
        let item = StreamItem(
            url: targetURL,
            headers: headers,
            provider: "lusushequ-m3u8",
            createdAt: Date()
        )
        queue.sync {
            self.streamItems[id] = item
        }
        print("✅ 注册六速社区 m3u8 代理: id=\(id), host=\(targetURL.host ?? "")")

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/lusushequ-m3u8"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url
    }

    private func localProxyURL(for targetURLString: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/douban-cover"
        components.queryItems = [
            URLQueryItem(name: "url", value: targetURLString)
        ]
        return components.url
    }

    private func targetURLString(from rawURL: String?) -> String? {
        guard let rawURL, !rawURL.isEmpty else { return nil }

        if rawURL.hasPrefix(proxyPrefix) {
            return String(rawURL.dropFirst(proxyPrefix.count))
        }

        return rawURL
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                print("豆瓣封面代理接收请求失败: \(error)")
                connection.cancel()
                return
            }

            guard let data, let requestText = String(data: data, encoding: .utf8) else {
                self.send(statusCode: 400, body: Data("Bad Request".utf8), contentType: "text/plain", on: connection)
                return
            }

            self.route(requestText, on: connection)
        }
    }

    private func route(_ requestText: String, on connection: NWConnection) {
        guard let requestLine = requestText.components(separatedBy: "\r\n").first else {
            send(statusCode: 400, body: Data("Bad Request".utf8), contentType: "text/plain", on: connection)
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(statusCode: 405, body: Data("Method Not Allowed".utf8), contentType: "text/plain", on: connection)
            return
        }

        let method = String(parts[0]).uppercased()
        // 仅放行 GET / HEAD：AVPlayer 在加载视频时常先发 HEAD 探测大小与可寻址性，
        // 之前直接 405 会触发 NSURLErrorNetworkConnectionLost / 加载失败。
        guard method == "GET" || method == "HEAD" else {
            send(statusCode: 405, body: Data("Method Not Allowed".utf8), contentType: "text/plain", on: connection)
            return
        }

        let pathAndQuery = String(parts[1])
        if pathAndQuery.hasPrefix("/baidu-stream")
            || pathAndQuery.hasPrefix("/quark-stream")
            || pathAndQuery.hasPrefix("/ali-stream")
            || pathAndQuery.hasPrefix("/uc-stream")
            || pathAndQuery.hasPrefix("/115-stream")
            || pathAndQuery.hasPrefix("/xunlei-stream")
            || pathAndQuery.hasPrefix("/sihu-stream")
            || pathAndQuery.hasPrefix("/xcp-stream")
            || pathAndQuery.hasPrefix("/mystery-stream") {
            routeStream(pathAndQuery, requestText: requestText, method: method, on: connection)
            return
        }
        if pathAndQuery.hasPrefix("/quark-m3u8") {
            routeQuarkM3U8(pathAndQuery, method: method, on: connection)
            return
        }
        if pathAndQuery.hasPrefix("/quark-segment") {
            routeQuarkSegment(pathAndQuery, requestText: requestText, method: method, on: connection)
            return
        }
        if pathAndQuery.hasPrefix("/lusushequ-m3u8") {
            routeLusushequM3U8(pathAndQuery, method: method, on: connection)
            return
        }
        if pathAndQuery.hasPrefix("/lusushequ-segment") {
            routeLusushequSegment(pathAndQuery, requestText: requestText, method: method, on: connection)
            return
        }
        if pathAndQuery.hasPrefix("/welfare-js-m3u8") {
            routeWelfareJSM3U8(pathAndQuery, method: method, on: connection)
            return
        }
        if pathAndQuery.hasPrefix("/welfare-js-segment") {
            routeWelfareJSSegment(pathAndQuery, requestText: requestText, method: method, on: connection)
            return
        }

        guard pathAndQuery.hasPrefix("/douban-cover"),
              let components = URLComponents(string: "http://127.0.0.1\(pathAndQuery)"),
              let rawURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
              isAllowedDoubanImageURL(rawURL),
              let targetURL = URL(string: rawURL)
        else {
            send(statusCode: 403, body: Data("Forbidden".utf8), contentType: "text/plain", on: connection)
            return
        }

        let cacheKey = rawURL as NSString
        if let cached = cache.object(forKey: cacheKey) {
            send(statusCode: 200, body: cached as Data, contentType: contentType(for: targetURL), on: connection)
            return
        }

        fetchImage(from: targetURL, cacheKey: cacheKey, on: connection)
    }

    private func routeQuarkM3U8(_ pathAndQuery: String, method: String, on connection: NWConnection) {
        guard let components = URLComponents(string: "http://127.0.0.1\(pathAndQuery)"),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let item = streamItems[id]
        else {
            print("❌ 夸克 m3u8 代理未找到注册项: \(pathAndQuery)")
            send(statusCode: 404, body: Data("M3U8 Not Found".utf8), contentType: "text/plain", on: connection)
            return
        }

        guard method == "GET" else {
            // HEAD 请求：返回 Content-Type 但不返回 Content-Length: 0
            // AVPlayer 看到 Content-Length: 0 会认为 m3u8 内容为空，不发后续 GET 请求
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        fetchQuarkM3U8(item: item, id: id, on: connection)
    }

    private func routeQuarkSegment(_ pathAndQuery: String, requestText: String, method: String, on connection: NWConnection) {
        guard let components = URLComponents(string: "http://127.0.0.1\(pathAndQuery)"),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let rawURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let parentItem = streamItems[id],
              isAllowedQuarkM3U8URL(rawURL),
              let targetURL = URL(string: rawURL)
        else {
            print("❌ 夸克分片代理参数无效: \(pathAndQuery)")
            send(statusCode: 403, body: Data("Forbidden Segment".utf8), contentType: "text/plain", on: connection)
            return
        }

        let requestHeaders = parseRequestHeaders(requestText)
        let incomingRange = requestHeaders["range"]
        let item = StreamItem(
            url: targetURL,
            headers: parentItem.headers,
            provider: "quark-segment",
            createdAt: Date()
        )
        print("📥 夸克分片代理收到请求: id=\(id), range=\(incomingRange ?? "无"), host=\(targetURL.host ?? "")")
        fetchStream(item: item, id: id, method: method, incomingRange: incomingRange, on: connection)
    }

    // MARK: - 六速社区 m3u8 代理

    private func routeLusushequM3U8(_ pathAndQuery: String, method: String, on connection: NWConnection) {
        guard let components = URLComponents(string: "http://127.0.0.1\(pathAndQuery)"),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let item = streamItems[id]
        else {
            print("❌ 六速社区 m3u8 代理未找到注册项: \(pathAndQuery)")
            send(statusCode: 404, body: Data("M3U8 Not Found".utf8), contentType: "text/plain", on: connection)
            return
        }

        guard method == "GET" else {
            // HEAD 请求：返回 Content-Type 但不返回 Content-Length: 0
            // AVPlayer 看到 Content-Length: 0 会认为 m3u8 内容为空，不发后续 GET 请求
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        fetchLusushequM3U8(item: item, id: id, on: connection)
    }

    private func routeLusushequSegment(_ pathAndQuery: String, requestText: String, method: String, on connection: NWConnection) {
        guard let components = URLComponents(string: "http://127.0.0.1\(pathAndQuery)"),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let rawURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let parentItem = streamItems[id],
              let targetURL = URL(string: rawURL)
        else {
            print("❌ 六速社区分片代理参数无效: \(pathAndQuery)")
            send(statusCode: 403, body: Data("Forbidden Segment".utf8), contentType: "text/plain", on: connection)
            return
        }

        let requestHeaders = parseRequestHeaders(requestText)
        let incomingRange = requestHeaders["range"]
        let segItem = StreamItem(
            url: targetURL,
            headers: parentItem.headers,
            provider: "lusushequ-segment",
            createdAt: Date()
        )
        print("📥 六速社区分片代理收到请求: id=\(id), range=\(incomingRange ?? "无"), host=\(targetURL.host ?? "")")
        fetchLusushequStream(item: segItem, id: id, method: method, incomingRange: incomingRange, on: connection)
    }

    /// 下载六速社区 m3u8（SSL 绕过 + 自动解压），重写 key URI 和 TS 路径为本地代理 URL
    private func fetchLusushequM3U8(item: StreamItem, id: String, on connection: NWConnection) {
        fetchLusushequM3U8FromURL(item: item, id: id, url: item.url, attemptCDNFallback: true, on: connection)
    }

    private func fetchLusushequM3U8FromURL(item: StreamItem, id: String, url: URL, attemptCDNFallback: Bool, on connection: NWConnection) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.httpMethod = "GET"
        for (key, value) in item.headers {
            let lower = key.lowercased()
            if lower == "host" || lower == "content-length" || lower == "connection" || lower == "accept-encoding" { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }
        // 不手动设置 Accept-Encoding，让 URLSession 自动处理 gzip/deflate/br 解压
        // 测试发现：服务器始终返回 gzip 压缩的 m3u8（无论 Accept-Encoding 值是什么）
        // 手动设置 Accept-Encoding 会导致 URLSession 不自动解压，
        // 而 gunzip 函数使用 COMPRESSION_ZLIB 无法处理 gzip 格式头部（RFC 1952）
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        // 使用带 SSL 绕过的 session（六速社区服务器使用自签名证书）
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let sslSession = URLSession(configuration: config, delegate: LusushequSSLDelegate(), delegateQueue: nil)

        let startedAt = Date()
        sslSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self else {
                connection.cancel()
                sslSession.invalidateAndCancel()
                return
            }

            if let error {
                print("❌ 六速社区 m3u8 拉取失败: id=\(id), err=\(error.localizedDescription)")
                // 尝试 cdnId 降级
                if attemptCDNFallback, self.tryCDNFallback(item: item, id: id, url: url, on: connection) {
                    sslSession.invalidateAndCancel()
                    return
                }
                self.sendNoStore(statusCode: 502, body: Data("Bad M3U8 Gateway".utf8), contentType: "text/plain", on: connection)
                sslSession.invalidateAndCancel()
                return
            }

            let httpResp = response as? HTTPURLResponse
            let status = httpResp?.statusCode ?? 200
            let contentEncoding = (httpResp?.value(forHTTPHeaderField: "Content-Encoding") ?? "").lowercased()

            guard let data else {
                print("❌ 六速社区 m3u8 内容为空: id=\(id), status=\(status)")
                if attemptCDNFallback, self.tryCDNFallback(item: item, id: id, url: url, on: connection) {
                    sslSession.invalidateAndCancel()
                    return
                }
                self.sendNoStore(statusCode: 502, body: Data("Empty M3U8".utf8), contentType: "text/plain", on: connection)
                sslSession.invalidateAndCancel()
                return
            }

            // 解压 m3u8 数据：URLSession 通常已自动解压，但作为兜底也手动处理 gzip
            let text = self.decompressM3U8Text(data: data, contentEncoding: contentEncoding)

            guard let text, !text.isEmpty else {
                print("❌ 六速社区 m3u8 解码失败: id=\(id), status=\(status), encoding=\(contentEncoding), bytes=\(data.count), head=\(data.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " "))")
                if attemptCDNFallback, self.tryCDNFallback(item: item, id: id, url: url, on: connection) {
                    sslSession.invalidateAndCancel()
                    return
                }
                self.sendNoStore(statusCode: 502, body: Data("Decode M3U8 Failed".utf8), contentType: "text/plain", on: connection)
                sslSession.invalidateAndCancel()
                return
            }

            // 验证是合法的 m3u8
            guard text.contains("#EXTM3U") else {
                print("❌ 六速社区 m3u8 内容无效（非 EXTM3U）: id=\(id), status=\(status), prefix=\(text.prefix(80))")
                if attemptCDNFallback, self.tryCDNFallback(item: item, id: id, url: url, on: connection) {
                    sslSession.invalidateAndCancel()
                    return
                }
                self.sendNoStore(statusCode: 502, body: Data("Invalid M3U8".utf8), contentType: "text/plain", on: connection)
                sslSession.invalidateAndCancel()
                return
            }

            // 使用最终 URL（重定向后）作为 base，避免相对路径解析错误
            let finalURL = httpResp?.url ?? url
            let rewritten = self.rewriteLusushequM3U8(text, baseURL: finalURL, id: id)
            let cost = Int(Date().timeIntervalSince(startedAt) * 1000)
            print("✅ 六速社区 m3u8 已重写: id=\(id), status=\(status), cost=\(cost)ms, bytes=\(rewritten.count), finalHost=\(finalURL.host ?? "")")
            self.sendNoStore(statusCode: 200, body: Data(rewritten.utf8), contentType: "application/vnd.apple.mpegurl", on: connection)
            sslSession.invalidateAndCancel()
        }.resume()
    }

    /// 尝试 cdnId 降级：cdnId=3 失败时尝试 cdnId=1 和 cdnId=2
    /// 与 Python Spider 的 _fetch_m3u8_text 降级逻辑一致
    private func tryCDNFallback(item: StreamItem, id: String, url: URL, on connection: NWConnection) -> Bool {
        let urlStr = url.absoluteString
        guard urlStr.contains("cdnId=") else { return false }

        // 提取当前 cdnId
        guard let regex = try? NSRegularExpression(pattern: "cdnId=(\\d+)"),
              let match = regex.firstMatch(in: urlStr, range: NSRange(urlStr.startIndex..., in: urlStr)),
              let range = Range(match.range(at: 1), in: urlStr) else {
            return false
        }
        let currentCDN = String(urlStr[range])
        print("⚠️ 六速社区 m3u8 当前 cdnId=\(currentCDN) 失败，尝试降级")

        for cdnId in [3, 1, 2] {
            let cdnStr = String(cdnId)
            if cdnStr == currentCDN { continue }
            let altUrl = urlStr.replacingOccurrences(
                of: "cdnId=\\d+",
                with: "cdnId=\(cdnStr)",
                options: .regularExpression
            )
            guard let altURL = URL(string: altUrl) else { continue }
            print("🔄 六速社区 m3u8 降级尝试 cdnId=\(cdnStr): \(altUrl.prefix(100))")
            fetchLusushequM3U8FromURL(item: item, id: id, url: altURL, attemptCDNFallback: false, on: connection)
            return true
        }
        return false
    }

    /// 解压 m3u8 数据为文本
    /// URLSession 在不手动设置 Accept-Encoding 时会自动解压 gzip/deflate/br，
    /// 此方法作为兜底，处理 URLSession 未自动解压的情况。
    private func decompressM3U8Text(data: Data, contentEncoding: String) -> String? {
        // 1. 尝试直接 UTF-8 解码（URLSession 已自动解压或明文响应）
        if let text = String(data: data, encoding: .utf8) {
            if text.contains("#EXTM3U") {
                return text
            }
        }

        // 2. 检测 gzip 魔数 (1f 8b) 并尝试解压
        if data.count >= 2, data[0] == 0x1f, data[1] == 0x8b {
            if let decompressed = Self.gunzip(data),
               let text = String(data: decompressed, encoding: .utf8) {
                print("📦 六速社区 m3u8 gzip 手动解压成功: \(data.count) → \(decompressed.count) bytes")
                return text
            }
        }

        // 3. Brotli 解压（服务器对部分 CDN 线路强制返回 br 压缩）
        if contentEncoding == "br" {
            if let decompressed = Self.debrotli(data),
               let text = String(data: decompressed, encoding: .utf8) {
                print("📦 六速社区 m3u8 Brotli 手动解压成功: \(data.count) → \(decompressed.count) bytes")
                return text
            }
        }

        // 4. 基于 Content-Encoding 尝试 zlib 解压
        if contentEncoding == "gzip" || contentEncoding == "deflate" {
            if let decompressed = Self.gunzip(data),
               let text = String(data: decompressed, encoding: .utf8) {
                return text
            }
        }

        // 5. 最后尝试直接解码（可能是非标准编码的文本）
        return String(data: data, encoding: .utf8)
    }

    /// 使用 Compression 框架解压 gzip 数据
    /// COMPRESSION_ZLIB 只能处理 raw deflate（RFC 1951），不能处理 gzip 格式头部（RFC 1952）
    /// 需要先剥离 gzip 头部，再对 raw deflate 数据进行解压
    private static func gunzip(_ data: Data) -> Data? {
        // 1. 剥离 gzip 头部
        // gzip 格式：magic(2) + method(1) + flags(1) + mtime(4) + xfl(1) + os(1) = 10 字节固定头
        // flags 各位含义：bit0=FTEXT, bit1=FHCRC, bit2=FEXTRA, bit3=FNAME, bit4=FCOMMENT
        guard data.count >= 10 else { return nil }
        guard data[0] == 0x1f, data[1] == 0x8b else { return nil }
        guard data[2] == 0x08 else { return nil } // 只支持 deflate 压缩方法

        let flags = data[3]
        var offset = 10 // 固定头部大小

        // FEXTRA：额外字段
        if (flags & 0x04) != 0 {
            guard offset + 2 <= data.count else { return nil }
            let extraLen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + extraLen
            guard offset <= data.count else { return nil }
        }

        // FNAME：原始文件名（null 结尾）
        if (flags & 0x08) != 0 {
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1 // 跳过 null
            guard offset <= data.count else { return nil }
        }

        // FCOMMENT：注释（null 结尾）
        if (flags & 0x10) != 0 {
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1 // 跳过 null
            guard offset <= data.count else { return nil }
        }

        // FHCRC：头部 CRC-16（2 字节）
        if (flags & 0x02) != 0 {
            offset += 2
            guard offset <= data.count else { return nil }
        }

        // 2. 剥离尾部 CRC-32 和原始大小（各 4 字节）
        let deflateEnd = data.count - 4 - 4
        guard offset < deflateEnd else { return nil }
        let deflateData = data.subdata(in: offset..<deflateEnd)

        // 3. 用 COMPRESSION_ZLIB 解压 raw deflate 数据
        let capacity = max(deflateData.count * 20, 131072)
        var buffer = Data(count: capacity)
        let result = buffer.withUnsafeMutableBytes { destPtr -> Int in
            deflateData.withUnsafeBytes { srcPtr -> Int in
                guard let destBase = destPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let srcBase = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_decode_buffer(
                    destBase, capacity,
                    srcBase, deflateData.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard result > 0 else { return nil }
        return buffer.prefix(result)
    }

    /// 使用 Compression 框架解压 Brotli 数据
    /// iOS 13+ 支持 COMPRESSION_BROTLI 算法
    private static func debrotli(_ data: Data) -> Data? {
        let capacity = max(data.count * 20, 131072)
        var buffer = Data(count: capacity)
        let result = buffer.withUnsafeMutableBytes { destPtr -> Int in
            data.withUnsafeBytes { srcPtr -> Int in
                guard let destBase = destPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let srcBase = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_decode_buffer(
                    destBase, capacity,
                    srcBase, data.count,
                    nil, COMPRESSION_BROTLI
                )
            }
        }
        guard result > 0 else { return nil }
        return buffer.prefix(result)
    }

    /// 重写六速社区 m3u8：仅将 key URI 从根相对路径转为绝对路径
    ///
    /// 与 Python Spider 的 _proxy_m3u8 逻辑完全一致：
    /// - 只修复 #EXT-X-KEY 行中的 URI，将根相对路径（/api/v2/...）转为绝对路径（https://host/api/v2/...）
    /// - TS 分片路径不改写，播放器直接从 CDN 获取（所有主机 SSL 证书有效，不需要代理）
    ///
    /// 之前的实现将 key 和 TS 都改写为本地代理 URL，导致：
    /// 1. 所有请求经过本地代理，增加延迟和故障点
    /// 2. 代理服务器的 gunzip 无法正确解压 gzip 格式
    /// 3. 代理转发 TS 分片可能出现流处理问题
    private func rewriteLusushequM3U8(_ text: String, baseURL: URL, id: String) -> String {
        // 计算 base 用于解析相对路径
        let finalURLString = baseURL.absoluteString
        let scheme = baseURL.scheme ?? "https"
        let host = baseURL.host ?? ""
        let port = baseURL.port.map { ":\($0)" } ?? ""
        let schemeHostPort = "\(scheme)://\(host)\(port)"

        let pathOnly = finalURLString.components(separatedBy: "?")[0]
        let basePath: String
        if let lastSlash = pathOnly.lastIndex(of: "/") {
            basePath = String(pathOnly[..<lastSlash]) + "/"
        } else {
            basePath = schemeHostPort + "/"
        }

        // 逐行处理：只修复 #EXT-X-KEY 中的 URI，其他行原样保留
        return text.components(separatedBy: .newlines).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("#EXT-X-KEY"), trimmed.contains("URI=\"") else {
                return line
            }
            return rewriteLusushequKeyURI(in: line, schemeHostPort: schemeHostPort, basePath: basePath)
        }.joined(separator: "\n")
    }

    /// 将 #EXT-X-KEY 行中的 URI 从相对路径转为绝对路径
    private func rewriteLusushequKeyURI(in line: String, schemeHostPort: String, basePath: String) -> String {
        var result = line
        let pattern = #"URI="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
        let matches = regex.matches(in: result, range: nsRange).reversed()
        for match in matches {
            guard match.numberOfRanges >= 2,
                  let uriRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range(at: 0), in: result) else { continue }
            let uri = String(result[uriRange])
            // 已经是绝对路径，不需要处理
            if uri.hasPrefix("http://") || uri.hasPrefix("https://") { continue }
            // 根相对路径 → 绝对路径
            let absolute: String
            if uri.hasPrefix("/") {
                absolute = schemeHostPort + uri
            } else {
                absolute = basePath + uri
            }
            result.replaceSubrange(fullRange, with: "URI=\"\(absolute)\"")
        }
        return result
    }

    /// 代理六速社区 key/TS 请求（SSL 绕过 + 自定义 header）
    private func fetchLusushequStream(item: StreamItem, id: String, method: String, incomingRange: String?, on connection: NWConnection) {
        var request = URLRequest(url: item.url)
        request.timeoutInterval = 30
        request.httpMethod = method
        for (key, value) in item.headers {
            let lower = key.lowercased()
            if lower == "host" || lower == "content-length" || lower == "connection" || lower == "accept-encoding" { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        // 不手动设置 Accept-Encoding，让 URLSession 自动处理解压
        if let range = normalizedRange(incomingRange) {
            request.setValue(range, forHTTPHeaderField: "Range")
        }

        print("📡 六速社区分片代理上游请求: method=\(method), id=\(id), range=\(request.value(forHTTPHeaderField: "Range") ?? "无"), host=\(item.url.host ?? "")")

        LusushequStreamForwarder(
            id: id,
            connection: connection
        ).start(request: request)
    }

    // MARK: - 通用福利 JS Spider m3u8 代理
    //
    // 为通过远程 JS 脚本加载的福利平台提供 m3u8 代理服务。
    // 与六速社区专用代理功能相同，但使用通用 SSL 绕过 Delegate，
    // 适用于任何需要 SSL 绕过的福利 JS Spider 平台。

    /// HTTP/1.1 下载（用于 JSHTTPBridge 回退，解决 HTTP/2 PROTOCOL_ERROR）
    static func downloadHTTP11(url: URL, headers: [String: String], timeout: TimeInterval = 15,
                               completion: @escaping (Data?, Int, [String: String], Error?) -> Void) {
        let downloader = WelfareHTTP11Downloader(id: "jsbridge", timeout: timeout)
        downloader.download(url: url, headers: headers, completion: completion)
    }

    func proxiedWelfareJSM3U8URL(for sourceURL: String, headers: [String: String]) -> URL? {
        guard let targetURL = URL(string: sourceURL) else {
            return URL(string: sourceURL)
        }

        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        queue.async { self.cleanupExpiredStreams() }
        let item = StreamItem(
            url: targetURL,
            headers: headers,
            provider: "welfare-js-m3u8",
            createdAt: Date()
        )
        queue.sync {
            self.streamItems[id] = item
        }
        print("✅ 注册福利JS m3u8 代理: id=\(id), host=\(targetURL.host ?? "")")

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/welfare-js-m3u8"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url
    }

    private func routeWelfareJSM3U8(_ pathAndQuery: String, method: String, on connection: NWConnection) {
        guard let components = URLComponents(string: "http://127.0.0.1\(pathAndQuery)"),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let item = streamItems[id]
        else {
            print("❌ 福利JS m3u8 代理未找到注册项: \(pathAndQuery)")
            send(statusCode: 404, body: Data("M3U8 Not Found".utf8), contentType: "text/plain", on: connection)
            return
        }

        guard method == "GET" else {
            // HEAD 请求：返回 Content-Type 但不返回 Content-Length: 0
            // AVPlayer 看到 Content-Length: 0 会认为 m3u8 内容为空，不发后续 GET 请求
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        fetchWelfareJSM3U8(item: item, id: id, on: connection)
    }

    private func routeWelfareJSSegment(_ pathAndQuery: String, requestText: String, method: String, on connection: NWConnection) {
        guard let components = URLComponents(string: "http://127.0.0.1\(pathAndQuery)"),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let rawURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let parentItem = streamItems[id],
              let targetURL = URL(string: rawURL)
        else {
            print("❌ 福利JS分片代理参数无效: \(pathAndQuery)")
            send(statusCode: 403, body: Data("Forbidden Segment".utf8), contentType: "text/plain", on: connection)
            return
        }

        let requestHeaders = parseRequestHeaders(requestText)
        let incomingRange = requestHeaders["range"]
        let segItem = StreamItem(
            url: targetURL,
            headers: parentItem.headers,
            provider: "welfare-js-segment",
            createdAt: Date()
        )
        print("📥 福利JS分片代理收到请求: id=\(id), range=\(incomingRange ?? "无"), host=\(targetURL.host ?? "")")
        fetchWelfareJSStream(item: segItem, id: id, method: method, incomingRange: incomingRange, on: connection)
    }

    /// 下载福利 JS Spider m3u8（SSL 绕过 + 自动解压），重写 key URI 和 TS 路径为本地代理 URL
    private func fetchWelfareJSM3U8(item: StreamItem, id: String, on connection: NWConnection) {
        var request = URLRequest(url: item.url)
        request.timeoutInterval = 20
        request.httpMethod = "GET"
        for (key, value) in item.headers {
            let lower = key.lowercased()
            if lower == "host" || lower == "content-length" || lower == "connection" || lower == "accept-encoding" { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let sslSession = URLSession(configuration: config, delegate: WelfareSSLBypassDelegate(), delegateQueue: nil)

        let startedAt = Date()
        sslSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self else {
                connection.cancel()
                sslSession.invalidateAndCancel()
                return
            }

            if let error {
                print("❌ 福利JS m3u8 拉取失败(URLSession): id=\(id), err=\(error.localizedDescription)")
                // 尝试 HTTP/1.1 回退（解决部分 CDN HTTP/2 PROTOCOL_ERROR）
                sslSession.invalidateAndCancel()
                self.fetchWelfareJSM3U8ViaHTTP11(item: item, id: id, on: connection)
                return
            }

            let httpResp = response as? HTTPURLResponse
            let status = httpResp?.statusCode ?? 200
            let contentEncoding = (httpResp?.value(forHTTPHeaderField: "Content-Encoding") ?? "").lowercased()

            guard let data else {
                print("❌ 福利JS m3u8 内容为空: id=\(id), status=\(status)")
                self.sendNoStore(statusCode: 502, body: Data("Empty M3U8".utf8), contentType: "text/plain", on: connection)
                sslSession.invalidateAndCancel()
                return
            }

            let text = self.decompressM3U8Text(data: data, contentEncoding: contentEncoding)

            guard let text, !text.isEmpty else {
                print("❌ 福利JS m3u8 解码失败: id=\(id), status=\(status), encoding=\(contentEncoding), bytes=\(data.count)")
                self.sendNoStore(statusCode: 502, body: Data("Decode M3U8 Failed".utf8), contentType: "text/plain", on: connection)
                sslSession.invalidateAndCancel()
                return
            }

            guard text.contains("#EXTM3U") else {
                print("❌ 福利JS m3u8 内容无效（非 EXTM3U）: id=\(id), status=\(status), prefix=\(text.prefix(80))")
                self.sendNoStore(statusCode: 502, body: Data("Invalid M3U8".utf8), contentType: "text/plain", on: connection)
                sslSession.invalidateAndCancel()
                return
            }

            let finalURL = httpResp?.url ?? item.url
            let rewritten = self.rewriteWelfareJSM3U8(text, baseURL: finalURL, id: id)
            let cost = Int(Date().timeIntervalSince(startedAt) * 1000)
            print("✅ 福利JS m3u8 已重写: id=\(id), status=\(status), cost=\(cost)ms, bytes=\(rewritten.count), finalHost=\(finalURL.host ?? "")")
            self.sendNoStore(statusCode: 200, body: Data(rewritten.utf8), contentType: "application/vnd.apple.mpegurl", on: connection)
            sslSession.invalidateAndCancel()
        }.resume()
    }

    /// HTTP/1.1 回退：当 URLSession 因 HTTP/2 PROTOCOL_ERROR 失败时，使用 NWConnection 强制 HTTP/1.1
    private func fetchWelfareJSM3U8ViaHTTP11(item: StreamItem, id: String, on connection: NWConnection) {
        print("🔄 福利JS m3u8 尝试 HTTP/1.1 回退: id=\(id), url=\(item.url.absoluteString)")
        let downloader = WelfareHTTP11Downloader(id: id, timeout: 20)
        downloader.download(url: item.url, headers: item.headers) { [weak self] data, status, headers, error in
            guard let self = self else { return }

            if let error = error {
                print("❌ 福利JS m3u8 HTTP/1.1 回退也失败: id=\(id), err=\(error.localizedDescription)")
                self.sendNoStore(statusCode: 502, body: Data("Bad M3U8 Gateway".utf8), contentType: "text/plain", on: connection)
                return
            }

            guard let data = data, !data.isEmpty else {
                print("❌ 福利JS m3u8 HTTP/1.1 内容为空: id=\(id), status=\(status)")
                self.sendNoStore(statusCode: 502, body: Data("Empty M3U8".utf8), contentType: "text/plain", on: connection)
                return
            }

            let contentEncoding = headers["content-encoding"] ?? ""
            let text = self.decompressM3U8Text(data: data, contentEncoding: contentEncoding)

            guard let text = text, !text.isEmpty, text.contains("#EXTM3U") else {
                print("❌ 福利JS m3u8 HTTP/1.1 内容无效: id=\(id), status=\(status), prefix=\(text?.prefix(80) ?? "")")
                self.sendNoStore(statusCode: 502, body: Data("Invalid M3U8".utf8), contentType: "text/plain", on: connection)
                return
            }

            let rewritten = self.rewriteWelfareJSM3U8(text, baseURL: item.url, id: id)
            print("✅ 福利JS m3u8 HTTP/1.1 已重写: id=\(id), status=\(status), bytes=\(rewritten.count)")
            self.sendNoStore(statusCode: 200, body: Data(rewritten.utf8), contentType: "application/vnd.apple.mpegurl", on: connection)
        }
    }

    /// 重写福利 JS Spider m3u8：将 key URI 和 TS 分片路径替换为本地代理 URL
    private func rewriteWelfareJSM3U8(_ text: String, baseURL: URL, id: String) -> String {
        let finalURLString = baseURL.absoluteString
        let scheme = baseURL.scheme ?? "https"
        let host = baseURL.host ?? ""
        let port = baseURL.port.map { ":\($0)" } ?? ""
        let schemeHostPort = "\(scheme)://\(host)\(port)"

        let pathOnly = finalURLString.components(separatedBy: "?")[0]
        let basePath: String
        if let lastSlash = pathOnly.lastIndex(of: "/") {
            basePath = String(pathOnly[..<lastSlash]) + "/"
        } else {
            basePath = schemeHostPort + "/"
        }

        return text.components(separatedBy: .newlines).map { line in
            rewriteWelfareJSM3U8Line(line, schemeHostPort: schemeHostPort, basePath: basePath, id: id)
        }.joined(separator: "\n")
    }

    private func rewriteWelfareJSM3U8Line(_ line: String, schemeHostPort: String, basePath: String, id: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return line }

        if line.hasPrefix("#EXT-X-KEY") {
            return rewriteWelfareJSURIAttributes(in: line, schemeHostPort: schemeHostPort, basePath: basePath, id: id)
        }

        if !line.hasPrefix("#") {
            return localWelfareJSSegmentURL(for: trimmed, schemeHostPort: schemeHostPort, basePath: basePath, id: id) ?? line
        }

        return line
    }

    private func rewriteWelfareJSURIAttributes(in line: String, schemeHostPort: String, basePath: String, id: String) -> String {
        var result = line
        let pattern = #"URI="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
        let matches = regex.matches(in: result, range: nsRange).reversed()
        for match in matches {
            guard match.numberOfRanges >= 2,
                  let uriRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range(at: 0), in: result) else { continue }
            let uri = String(result[uriRange])
            guard let local = localWelfareJSSegmentURL(for: uri, schemeHostPort: schemeHostPort, basePath: basePath, id: id) else { continue }
            result.replaceSubrange(fullRange, with: "URI=\"\(local)\"")
        }
        return result
    }

    private func localWelfareJSSegmentURL(for raw: String, schemeHostPort: String, basePath: String, id: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let absolute: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            absolute = trimmed
        } else if trimmed.hasPrefix("/") {
            absolute = schemeHostPort + trimmed
        } else {
            absolute = basePath + trimmed
        }

        guard URL(string: absolute) != nil else { return nil }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/welfare-js-segment"
        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "url", value: absolute)
        ]
        return components.url?.absoluteString
    }

    /// 代理福利 JS Spider key/TS 请求（SSL 绕过 + 自定义 header）
    private func fetchWelfareJSStream(item: StreamItem, id: String, method: String, incomingRange: String?, on connection: NWConnection) {
        var request = URLRequest(url: item.url)
        request.timeoutInterval = 30
        request.httpMethod = method
        for (key, value) in item.headers {
            let lower = key.lowercased()
            if lower == "host" || lower == "content-length" || lower == "connection" { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range = normalizedRange(incomingRange) {
            request.setValue(range, forHTTPHeaderField: "Range")
        }

        print("📡 福利JS分片代理上游请求: method=\(method), id=\(id), range=\(request.value(forHTTPHeaderField: "Range") ?? "无"), host=\(item.url.host ?? "")")

        WelfareJSStreamForwarder(
            id: id,
            connection: connection
        ).start(request: request)
    }

    private func routeStream(_ pathAndQuery: String, requestText: String, method: String, on connection: NWConnection) {
        guard let components = URLComponents(string: "http://127.0.0.1\(pathAndQuery)"),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value
        else {
            print("❌ 本地视频代理请求缺少 id: \(pathAndQuery)")
            send(statusCode: 404, body: Data("Stream Not Found".utf8), contentType: "text/plain", on: connection)
            return
        }

        guard let item = streamItems[id] else {
            print("❌ 本地视频代理未找到注册项: id=\(id), active=\(streamItems.count)")
            send(statusCode: 404, body: Data("Stream Not Found".utf8), contentType: "text/plain", on: connection)
            return
        }

        let requestHeaders = parseRequestHeaders(requestText)
        let incomingRange = requestHeaders["range"]
        print("📥 本地视频代理收到请求[\(item.provider)]: method=\(method), id=\(id), range=\(incomingRange ?? "无"), path=\(pathAndQuery)")
        if item.provider == "baidu", method == "GET" {
            let range = normalizedRange(incomingRange)
            if let cached = baiduStreamCache.cachedResponse(id: id, requestedRange: range) {
                print("💾 百度分片缓存命中: id=\(id), range=\(range ?? "无"), bytes=\(cached.body.count)")
                sendStream(statusCode: 206, headers: cached.headers, body: cached.body, on: connection)
                baiduStreamCache.postProgress(id: id)
                return
            }
        }
        fetchStream(item: item, id: id, method: method, incomingRange: incomingRange, on: connection)
    }

    private func streamRequest(for item: StreamItem, method: String, incomingRange: String?) -> URLRequest {
        var request = URLRequest(url: item.url)
        request.timeoutInterval = 30
        request.httpMethod = method

        for (key, value) in item.headers {
            let lower = key.lowercased()
            if lower == "host" || lower == "content-length" || lower == "connection" || lower.hasPrefix("x-vbox-") { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }

        if item.provider.hasPrefix("quark") {
            // 与 quarkPlaybackHeaders 保持一致：使用 PC quark-cloud-drive UA。
            // download_url 签名链对 UA 敏感，UA 不一致会触发 403/连接被风控中断。
            if request.value(forHTTPHeaderField: "User-Agent") == nil {
                request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch", forHTTPHeaderField: "User-Agent")
            }
            if request.value(forHTTPHeaderField: "Referer") == nil {
                request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
            }
            if request.value(forHTTPHeaderField: "Origin") == nil {
                request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
            }
            // identity 避免上游返回 gzip 后被中间层错误处理；分片直链本身就是字节流，不需要再压缩。
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        } else if item.provider == "ali" {
            if request.value(forHTTPHeaderField: "User-Agent") == nil {
                request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 AliApp(AYSD/6.0.0) Mobile/15E148", forHTTPHeaderField: "User-Agent")
            }
            if request.value(forHTTPHeaderField: "Referer") == nil {
                request.setValue("https://www.aliyundrive.com/", forHTTPHeaderField: "Referer")
            }
            if request.value(forHTTPHeaderField: "Origin") == nil {
                request.setValue("https://www.aliyundrive.com", forHTTPHeaderField: "Origin")
            }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        } else if item.provider == "uc" {
            if request.value(forHTTPHeaderField: "User-Agent") == nil {
                request.setValue("Mozilla/5.0 (Linux; Android 12; HD1900 Build/SKQ1.211113.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/97.0.4692.98 Mobile Safari/537.36", forHTTPHeaderField: "User-Agent")
            }
            if request.value(forHTTPHeaderField: "Referer") == nil {
                request.setValue("https://drive.uc.cn/", forHTTPHeaderField: "Referer")
            }
            if request.value(forHTTPHeaderField: "Origin") == nil {
                request.setValue("https://drive.uc.cn", forHTTPHeaderField: "Origin")
            }
        } else if item.provider == "115" {
            if request.value(forHTTPHeaderField: "User-Agent") == nil {
                request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            }
            if request.value(forHTTPHeaderField: "Referer") == nil {
                request.setValue("https://115.com/", forHTTPHeaderField: "Referer")
            }
            if request.value(forHTTPHeaderField: "Origin") == nil {
                request.setValue("https://115.com", forHTTPHeaderField: "Origin")
            }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        } else if item.provider == "xunlei" {
            if request.value(forHTTPHeaderField: "User-Agent") == nil {
                request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/67.0.3396.99 Safari/537.36", forHTTPHeaderField: "User-Agent")
            }
            if request.value(forHTTPHeaderField: "Referer") == nil {
                request.setValue("https://pan.xunlei.com/", forHTTPHeaderField: "Referer")
            }
            if request.value(forHTTPHeaderField: "Origin") == nil {
                request.setValue("https://pan.xunlei.com", forHTTPHeaderField: "Origin")
            }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        } else {
            if request.value(forHTTPHeaderField: "User-Agent") == nil {
                request.setValue(Self.baiduPCSUserAgent, forHTTPHeaderField: "User-Agent")
            }
            if request.value(forHTTPHeaderField: "Referer") == nil {
                request.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
            }
            if request.value(forHTTPHeaderField: "Origin") == nil {
                request.setValue("https://pan.baidu.com", forHTTPHeaderField: "Origin")
            }
        }
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        if let range = normalizedRange(incomingRange) {
            request.setValue(range, forHTTPHeaderField: "Range")
        }

        return request
    }

    private func fetchStream(item: StreamItem, id: String, method: String, incomingRange: String?, on connection: NWConnection) {
        let request = streamRequest(for: item, method: method, incomingRange: incomingRange)
        print("📡 本地视频代理上游请求[\(item.provider)]: method=\(method), id=\(id), range=\(request.value(forHTTPHeaderField: "Range") ?? "无"), host=\(item.url.host ?? ""), hasCookie=\(request.value(forHTTPHeaderField: "Cookie") != nil || request.value(forHTTPHeaderField: "X-Baidu-Pcs-Cookie") != nil), hasVideoAuth=\((request.value(forHTTPHeaderField: "Cookie") ?? "").contains("Video-Auth=")), hasUA=\(request.value(forHTTPHeaderField: "User-Agent") != nil), referer=\(request.value(forHTTPHeaderField: "Referer") ?? "无")")

        let cacheSink: ((HTTPURLResponse, Data) -> Void)?
        if item.provider == "baidu", method == "GET", let range = request.value(forHTTPHeaderField: "Range") {
            cacheSink = { [weak self] response, body in
                self?.baiduStreamCache.store(
                    id: id,
                    requestedRange: range,
                    response: response,
                    body: body
                )
            }
        } else {
            cacheSink = nil
        }

        StreamForwarder(
            provider: item.provider,
            id: id,
            connection: connection,
            cacheSink: cacheSink
        ).start(request: request)
    }

    private func preheatStream(item: StreamItem, id: String) {
        guard item.provider == "baidu" else { return }
        var request = URLRequest(url: item.url)
        request.timeoutInterval = 12
        for (key, value) in item.headers {
            let lower = key.lowercased()
            if lower == "host" || lower == "content-length" || lower == "connection" { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }
        if item.provider == "quark" {
            if request.value(forHTTPHeaderField: "User-Agent") == nil {
                request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch", forHTTPHeaderField: "User-Agent")
            }
            if request.value(forHTTPHeaderField: "Referer") == nil {
                request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
            }
            if request.value(forHTTPHeaderField: "Origin") == nil {
                request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
            }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        } else {
            if request.value(forHTTPHeaderField: "User-Agent") == nil {
                request.setValue(Self.baiduPCSUserAgent, forHTTPHeaderField: "User-Agent")
            }
            if request.value(forHTTPHeaderField: "Referer") == nil {
                request.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
            }
            if request.value(forHTTPHeaderField: "Origin") == nil {
                request.setValue("https://pan.baidu.com", forHTTPHeaderField: "Origin")
            }
        }
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")

        let startedAt = Date()
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                print("♨️ 本地视频代理预热失败[\(item.provider)]: id=\(id), err=\(error.localizedDescription)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let cost = Int(Date().timeIntervalSince(startedAt) * 1000)
            let bytes = data?.count ?? 0
            print("♨️ 本地视频代理预热完成[\(item.provider)]: id=\(id), status=\(status), cost=\(cost)ms, bytes=\(bytes)")
        }.resume()
    }

    private func normalizedRange(_ raw: String?) -> String? {
        guard let raw, raw.lowercased().hasPrefix("bytes=") else {
            return "bytes=0-8388607"
        }

        let text = raw.replacingOccurrences(of: "bytes=", with: "")
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard let startText = parts.first,
              let start = Int(startText)
        else {
            return raw
        }

        if parts.count > 1, let end = Int(parts[1]) {
            return "bytes=\(start)-\(end)"
        }

        let end = start + 8 * 1024 * 1024 - 1
        return "bytes=\(start)-\(end)"
    }

    private func parseRequestHeaders(_ requestText: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = requestText.components(separatedBy: "\r\n")
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = line[..<idx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespacesAndNewlines)
            result[key] = value
        }
        return result
    }

    private func fetchQuarkM3U8(item: StreamItem, id: String, on connection: NWConnection) {
        var request = URLRequest(url: item.url)
        request.timeoutInterval = 20
        request.httpMethod = "GET"
        for (key, value) in item.headers {
            let lower = key.lowercased()
            if lower == "host" || lower == "content-length" || lower == "connection" || lower.hasPrefix("x-vbox-") { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch", forHTTPHeaderField: "User-Agent")
        }
        if request.value(forHTTPHeaderField: "Referer") == nil {
            request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        }
        if request.value(forHTTPHeaderField: "Origin") == nil {
            request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        }
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let startedAt = Date()
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let error {
                print("❌ 夸克 m3u8 拉取失败: id=\(id), err=\(error.localizedDescription)")
                self.sendNoStore(statusCode: 502, body: Data("Bad M3U8 Gateway".utf8), contentType: "text/plain", on: connection)
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard let data, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                print("❌ 夸克 m3u8 内容为空: id=\(id), status=\(status)")
                self.sendNoStore(statusCode: 502, body: Data("Empty M3U8".utf8), contentType: "text/plain", on: connection)
                return
            }

            let rewritten = self.rewriteQuarkM3U8(text, baseURL: item.url, id: id)
            let cost = Int(Date().timeIntervalSince(startedAt) * 1000)
            print("✅ 夸克 m3u8 已重写: id=\(id), status=\(status), cost=\(cost)ms, bytes=\(data.count)")
            self.sendNoStore(statusCode: status, body: Data(rewritten.utf8), contentType: "application/vnd.apple.mpegurl", on: connection)
        }.resume()
    }

    private func rewriteQuarkM3U8(_ text: String, baseURL: URL, id: String) -> String {
        text.components(separatedBy: .newlines).map { line in
            rewriteQuarkM3U8Line(line, baseURL: baseURL, id: id)
        }.joined(separator: "\n")
    }

    private func rewriteQuarkM3U8Line(_ line: String, baseURL: URL, id: String) -> String {
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return line }

        if line.hasPrefix("#") {
            return rewriteQuarkM3U8URIAttributes(in: line, baseURL: baseURL, id: id)
        }

        guard let absolute = absoluteQuarkURL(from: line, baseURL: baseURL) else { return line }
        return localQuarkSegmentURL(for: absolute, id: id) ?? line
    }

    private func rewriteQuarkM3U8URIAttributes(in line: String, baseURL: URL, id: String) -> String {
        var result = line
        let pattern = #"URI="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
        let matches = regex.matches(in: result, range: nsRange).reversed()
        for match in matches {
            guard match.numberOfRanges >= 2,
                  let uriRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range(at: 0), in: result) else { continue }
            let uri = String(result[uriRange])
            guard let absolute = absoluteQuarkURL(from: uri, baseURL: baseURL),
                  let local = localQuarkSegmentURL(for: absolute, id: id) else { continue }
            result.replaceSubrange(fullRange, with: "URI=\"\(local)\"")
        }
        return result
    }

    private func absoluteQuarkURL(from raw: String, baseURL: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
              isAllowedQuarkM3U8URL(url.absoluteString) else { return nil }
        return url
    }

    private func localQuarkSegmentURL(for url: URL, id: String) -> String? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/quark-segment"
        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "url", value: url.absoluteString)
        ]
        return components.url?.absoluteString
    }

    private func fetchImage(from url: URL, cacheKey: NSString, on connection: NWConnection) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("https://movie.douban.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                print("豆瓣封面代理下载失败: \(error.localizedDescription)")
                self.send(statusCode: 502, body: Data("Bad Gateway".utf8), contentType: "text/plain", on: connection)
                return
            }

            guard let data, !data.isEmpty else {
                self.send(statusCode: 502, body: Data("Empty Image".utf8), contentType: "text/plain", on: connection)
                return
            }

            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 200
            let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? self.contentType(for: url)

            if (200..<300).contains(statusCode) {
                self.cache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
            } else {
                print("豆瓣封面代理返回状态码: \(statusCode), url: \(url.absoluteString)")
            }

            self.send(statusCode: statusCode, body: data, contentType: contentType, on: connection)
        }.resume()
    }

    private func send(statusCode: Int, body: Data, contentType: String, on connection: NWConnection) {
        let reason = Self.reasonPhrase(for: statusCode)
        // 使用简单字符串拼接，避免 Swift 多行字符串在 """ 前空行产生额外 \n
        // 多行字符串的空行会导致 body 前多一个 \n 字节，造成 Content-Length 不匹配
        // 和 m3u8 内容以 \n 开头而非 #EXTM3U，AVPlayer 无法识别
        let header = "HTTP/1.1 \(statusCode) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: public, max-age=86400\r\nConnection: close\r\n\r\n"

        var response = Data(header.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendNoStore(statusCode: Int, body: Data, contentType: String, on connection: NWConnection) {
        let reason = Self.reasonPhrase(for: statusCode)
        // 使用简单字符串拼接，避免 Swift 多行字符串在 """ 前空行产生额外 \n
        // 多行字符串的空行会导致 body 前多一个 \n 字节，造成 Content-Length 不匹配
        // 和 m3u8 内容以 \n 开头而非 #EXTM3U，AVPlayer 无法识别
        let header = "HTTP/1.1 \(statusCode) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"

        var response = Data(header.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendStream(statusCode: Int, headers: [AnyHashable: Any], body: Data, on connection: NWConnection) {
        let reason = Self.reasonPhrase(for: statusCode)
        let contentType = (headers["Content-Type"] as? String)
            ?? (headers["content-type"] as? String)
            ?? "application/octet-stream"
        let contentRange = (headers["Content-Range"] as? String)
            ?? (headers["content-range"] as? String)
        let acceptRanges = (headers["Accept-Ranges"] as? String)
            ?? (headers["accept-ranges"] as? String)
            ?? "bytes"

        // 使用简单字符串拼接，避免 Swift 多行字符串在 """ 前空行产生额外 \n
        // 多行字符串的空行会导致 header 前多一个 \n 字节，造成 HTTP 响应格式错误
        var header = "HTTP/1.1 \(statusCode) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nAccept-Ranges: \(acceptRanges)\r\nCache-Control: no-store\r\nConnection: close\r\n"

        if let contentRange {
            header += "Content-Range: \(contentRange)\r\n"
        }

        header += "\r\n"

        var response = Data(header.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    fileprivate static func streamResponseHeader(statusCode: Int, headers: [AnyHashable: Any]) -> Data {
        let reason = Self.reasonPhrase(for: statusCode)
        let contentType = headerValue(headers, "Content-Type") ?? "application/octet-stream"
        let contentRange = headerValue(headers, "Content-Range")
        let acceptRanges = headerValue(headers, "Accept-Ranges") ?? "bytes"
        let contentLength = headerValue(headers, "Content-Length")

        // 使用简单字符串拼接，避免 Swift 多行字符串在 """ 前空行产生额外 \n
        // 多行字符串的空行会导致 header 前多一个 \n 字节，造成 HTTP 响应格式错误
        var header = "HTTP/1.1 \(statusCode) \(reason)\r\nContent-Type: \(contentType)\r\nAccept-Ranges: \(acceptRanges)\r\nCache-Control: no-store\r\nConnection: close\r\n"

        if let contentLength {
            header += "Content-Length: \(contentLength)\r\n"
        }
        if let contentRange {
            header += "Content-Range: \(contentRange)\r\n"
        }

        header += "\r\n"
        return Data(header.utf8)
    }

    fileprivate static func headerValue(_ headers: [AnyHashable: Any], _ name: String) -> String? {
        if let direct = headers[name] as? String {
            return direct
        }
        let lower = name.lowercased()
        for (key, value) in headers {
            if String(describing: key).lowercased() == lower {
                return String(describing: value)
            }
        }
        return nil
    }

    private static func hasHeader(_ headers: [String: String], named name: String) -> Bool {
        let lower = name.lowercased()
        return headers.contains { $0.key.lowercased() == lower && !$0.value.isEmpty }
    }

    private func isAllowedDoubanImageURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              ["http", "https"].contains(scheme)
        else {
            return false
        }

        return allowedHosts.contains(host)
    }

    private func isAllowedStreamURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              ["http", "https"].contains(scheme)
        else {
            return false
        }

        return host.contains("baidupcs.com")
            || host == "d.pcs.baidu.com"
            || isQuarkPlaybackHost(host)
            || isAliPlaybackHost(host)
            || isUCPlaybackHost(host)
            || is115PlaybackHost(host)
            || isXunleiPlaybackHost(host)
    }

    private func isAllowedQuarkM3U8URL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              ["http", "https"].contains(scheme)
        else {
            return false
        }

        guard host == "quark.cn" || host.hasSuffix(".quark.cn") else { return false }
        let excluded: Set<String> = [
            "pan.quark.cn",
            "uop.quark.cn",
            "su.quark.cn",
            "www.quark.cn"
        ]
        return !excluded.contains(host)
    }

    /// 夸克 download_url 实际跳转后域名波动较大，已经观察到的有 *.drive.quark.cn、*.dl.quark.cn、
    /// *.cdn.quark.cn、pcs-*.quark.cn、video-*.quark.cn 等。这里只要落在 *.quark.cn 都允许走代理，
    /// 避免回退直连导致 AVPlayer 拿不到 Cookie/UA 时 403。
    private func isQuarkPlaybackHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "quark.cn" || lower.hasSuffix(".quark.cn") {
            // 排除 API/页面域名，避免误把网页域转代理
            let excluded: Set<String> = [
                "pan.quark.cn",
                "drive-pc.quark.cn",
                "drive-h.quark.cn",
                "drive-m.quark.cn",
                "uop.quark.cn",
                "su.quark.cn",
                "www.quark.cn"
            ]
            if excluded.contains(lower) { return false }
            return true
        }
        return false
    }

    private func isAliPlaybackHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower.contains("aliyundrive.com") || lower.contains("alipan.com") || lower.contains("aliyunpds.com") {
            return true
        }
        return lower.hasSuffix(".aliyuncs.com") || lower.contains("aliyun")
    }

    private func isUCPlaybackHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "uc.cn" || lower.hasSuffix(".uc.cn") {
            let excluded: Set<String> = [
                "drive.uc.cn",
                "pc-api.uc.cn",
                "www.uc.cn"
            ]
            return !excluded.contains(lower)
        }
        return lower.contains("ucdl") || lower.contains("ucloud")
    }

    private func is115PlaybackHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "115.com"
            || lower.hasSuffix(".115.com")
            || lower.contains("115cdn.com")
            || lower.contains("anxia.com")
            || lower.contains("cdnfhnup")
            || lower.contains("fhnqqso")
    }

    /// 迅雷云盘播放/下载地址域名匹配
    /// 迅雷 CDN 域名包括 *.xunlei.com、*.fntx.* 等
    private func isXunleiPlaybackHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower.hasSuffix(".xunlei.com") || lower == "xunlei.com" {
            // 排除 API/页面域名，避免误把网页域转代理
            let excluded: Set<String> = [
                "pan.xunlei.com",
                "i.xunlei.com",
                "x-api-pan.xunlei.com",
                "xluser-ssl.xunlei.com",
                "www.xunlei.com"
            ]
            return !excluded.contains(lower)
        }
        return lower.contains("fntx")
            || lower.contains("xlgateway")
            || lower.hasSuffix(".xunlei.cn")
    }

    private func cleanupExpiredStreams() {
        let deadline = Date().addingTimeInterval(-30 * 60)
        let expiredIds = streamItems
            .filter { $0.value.createdAt <= deadline }
            .map(\.key)
        streamItems = streamItems.filter { $0.value.createdAt > deadline }
        expiredIds.forEach { baiduStreamCache.remove(id: $0) }
        baiduStreamCache.cleanupExpiredCaches(olderThan: 24 * 60 * 60)
    }

    private func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png":
            return "image/png"
        case "webp":
            return "image/webp"
        case "gif":
            return "image/gif"
        default:
            return "image/jpeg"
        }
    }

    fileprivate static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 206:
            return "Partial Content"
        case 301:
            return "Moved Permanently"
        case 302:
            return "Found"
        case 400:
            return "Bad Request"
        case 403:
            return "Forbidden"
        case 404:
            return "Not Found"
        case 405:
            return "Method Not Allowed"
        case 416:
            return "Range Not Satisfiable"
        case 502:
            return "Bad Gateway"
        default:
            return "HTTP Status"
        }
    }
}

private final class StreamForwarder: NSObject, URLSessionDataDelegate {
    private let provider: String
    private let id: String
    private let connection: NWConnection
    private let callbackQueue = OperationQueue()
    private var session: URLSession?
    private var responseStarted = false
    private var statusCode = 0
    private var receivedBytes = 0
    private var preview = Data()
    private var shouldPreviewBody = false
    private var upstreamHeaders: [String: String] = [:]
    private var startTime = Date()
    private var firstByteLogged = false
    private let cacheSink: ((HTTPURLResponse, Data) -> Void)?
    private var cacheBody = Data()
    private var httpResponse: HTTPURLResponse?

    init(
        provider: String,
        id: String,
        connection: NWConnection,
        cacheSink: ((HTTPURLResponse, Data) -> Void)? = nil
    ) {
        self.provider = provider
        self.id = id
        self.connection = connection
        self.cacheSink = cacheSink
        self.callbackQueue.maxConcurrentOperationCount = 1
        super.init()
    }

    func start(request: URLRequest) {
        startTime = Date()
        upstreamHeaders = request.allHTTPHeaderFields ?? [:]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: callbackQueue)
        self.session = session
        session.dataTask(with: request).resume()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirected = request
        for (key, value) in upstreamHeaders {
            let lower = key.lowercased()
            if lower == "host" || lower == "content-length" || lower == "connection" { continue }
            redirected.setValue(value, forHTTPHeaderField: key)
        }
        let location = response.value(forHTTPHeaderField: "Location") ?? redirected.url?.absoluteString ?? "无"
        print("↪️ 本地视频代理上游重定向[\(provider)]: id=\(id), status=\(response.statusCode), location=\(location), keepCookie=\(upstreamHeaders.keys.contains { $0.lowercased() == "cookie" })")
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            print("❌ 本地视频代理上游响应无效[\(provider)]: id=\(id)")
            sendErrorAndClose(statusCode: 502, message: "Invalid Upstream Response")
            completionHandler(.cancel)
            return
        }

        statusCode = http.statusCode
        httpResponse = http
        let headers = http.allHeaderFields
        let contentType = DoubanImageProxyServer.headerValue(headers, "Content-Type") ?? "无"
        let contentLength = DoubanImageProxyServer.headerValue(headers, "Content-Length") ?? "\(response.expectedContentLength)"
        let contentRange = DoubanImageProxyServer.headerValue(headers, "Content-Range") ?? "无"
        let location = DoubanImageProxyServer.headerValue(headers, "Location") ?? "无"
        shouldPreviewBody = statusCode >= 400 || contentType.lowercased().contains("text/html") || contentType.lowercased().contains("json")

        print("📥 本地视频代理上游响应[\(provider)]: id=\(id), status=\(statusCode), cost=\(elapsedMS())ms, contentType=\(contentType), contentLength=\(contentLength), contentRange=\(contentRange), location=\(location)")

        let responseHeader = DoubanImageProxyServer.streamResponseHeader(statusCode: statusCode, headers: headers)
        responseStarted = true
        connection.send(content: responseHeader, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { error in
            if let error {
                print("❌ 本地视频代理响应头发送失败[\(self.provider)]: id=\(self.id), error=\(error)")
            } else {
                print("📤 本地视频代理已返回响应头[\(self.provider)]: id=\(self.id), status=\(self.statusCode)")
            }
        })
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedBytes += data.count
        if !firstByteLogged {
            firstByteLogged = true
            let prefix = data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            print("🚀 本地视频代理首包[\(provider)]: id=\(id), cost=\(elapsedMS())ms, bytes=\(data.count), head=\(prefix)")
        }
        if shouldPreviewBody && preview.count < 512 {
            preview.append(data.prefix(max(0, 512 - preview.count)))
        }
        if cacheSink != nil, cacheBody.count < 18 * 1024 * 1024 {
            cacheBody.append(data)
        }

        connection.send(content: data, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { error in
            if let error {
                print("❌ 本地视频代理数据发送失败[\(self.provider)]: id=\(self.id), error=\(error)")
            }
        })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            session.invalidateAndCancel()
            self.session = nil
        }

        if let error {
            print("❌ 本地视频代理拉流失败[\(provider)]: id=\(id), error=\(error.localizedDescription), receivedBytes=\(receivedBytes)")
            if !responseStarted {
                sendErrorAndClose(statusCode: 502, message: "Bad Gateway")
                return
            }
        }

        if shouldPreviewBody, !preview.isEmpty, let text = String(data: preview, encoding: .utf8) {
            print("⚠️ 本地视频代理上游错误体预览[\(provider)]: id=\(id), preview=\(text.prefix(240))")
        }

        print("✅ 本地视频代理转发完成[\(provider)]: id=\(id), status=\(statusCode), cost=\(elapsedMS())ms, bytes=\(receivedBytes)")
        if error == nil, let httpResponse, let cacheSink, (200..<300).contains(statusCode), cacheBody.count == receivedBytes {
            cacheSink(httpResponse, cacheBody)
        }
        connection.send(content: nil, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
            self.connection.cancel()
        })
    }

    private func tryHTTP11Fallback() {
        guard let url = fallbackURL else {
            sendErrorAndClose(statusCode: 502, message: "Bad Gateway")
            return
        }
        print("🔄 福利JS分片代理尝试 HTTP/1.1 回退: id=\(id), url=\(url.absoluteString)")
        WelfareHTTP11StreamForwarder(id: id, connection: connection).start(
            url: url, headers: fallbackHeaders, method: fallbackMethod, range: fallbackRange
        )
    }

    private func elapsedMS() -> Int {
        Int(Date().timeIntervalSince(startTime) * 1000)
    }

    private func sendErrorAndClose(statusCode: Int, message: String) {
        let body = Data(message.utf8)
        // 使用简单字符串拼接，避免 Swift 多行字符串在 """ 前空行产生额外 \n
        // 之前的多行字符串在 \r 后有空行再接 """，导致 body 前多一个 \n 字节
        let header = "HTTP/1.1 \(statusCode) \(DoubanImageProxyServer.reasonPhrase(for: statusCode))\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"

        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            self.connection.cancel()
        })
    }
}

// MARK: - 六速社区流转发器（SSL 绕过）
//
// 与 StreamForwarder 功能类似，但使用 LusushequSSLDelegate 绕过自签名证书。
// 专门用于六速社区的 key 和 TS 分片代理转发。

private final class LusushequStreamForwarder: NSObject, URLSessionDataDelegate {
    private let id: String
    private let connection: NWConnection
    private let callbackQueue = OperationQueue()
    private var session: URLSession?
    private var responseStarted = false
    private var statusCode = 0
    private var receivedBytes = 0
    private var startTime = Date()
    private var firstByteLogged = false

    init(id: String, connection: NWConnection) {
        self.id = id
        self.connection = connection
        self.callbackQueue.maxConcurrentOperationCount = 1
        super.init()
    }

    func start(request: URLRequest) {
        startTime = Date()

        // 保存请求信息用于 HTTP/1.1 回退
        fallbackURL = request.url
        fallbackMethod = request.httpMethod ?? "GET"
        fallbackRange = request.value(forHTTPHeaderField: "Range")
        if let allHeaders = request.allHTTPHeaderFields {
            for (key, value) in allHeaders {
                let lower = key.lowercased()
                if lower == "host" || lower == "connection" || lower == "accept-encoding" { continue }
                fallbackHeaders[key] = value
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 使用带 SSL 绕过的 session
        let session = URLSession(configuration: configuration, delegate: LusushequSSLDelegate(), delegateQueue: callbackQueue)
        self.session = session
        session.dataTask(with: request).resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            print("❌ 六速社区分片代理上游响应无效: id=\(id)")
            sendErrorAndClose(statusCode: 502, message: "Invalid Upstream Response")
            completionHandler(.cancel)
            return
        }

        statusCode = http.statusCode
        let headers = http.allHeaderFields
        let contentType = DoubanImageProxyServer.headerValue(headers, "Content-Type") ?? "application/octet-stream"
        let contentLength = DoubanImageProxyServer.headerValue(headers, "Content-Length") ?? "\(response.expectedContentLength)"
        let contentRange = DoubanImageProxyServer.headerValue(headers, "Content-Range") ?? "无"

        print("📥 六速社区分片代理上游响应: id=\(id), status=\(statusCode), cost=\(elapsedMS())ms, contentType=\(contentType), contentLength=\(contentLength), contentRange=\(contentRange)")

        let responseHeader = DoubanImageProxyServer.streamResponseHeader(statusCode: statusCode, headers: headers)
        responseStarted = true
        connection.send(content: responseHeader, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { error in
            if let error {
                print("❌ 六速社区分片代理响应头发送失败: id=\(self.id), error=\(error)")
            }
        })
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedBytes += data.count
        if !firstByteLogged {
            firstByteLogged = true
            print("🚀 六速社区分片代理首包: id=\(id), cost=\(elapsedMS())ms, bytes=\(data.count)")
        }

        connection.send(content: data, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { error in
            if let error {
                print("❌ 六速社区分片代理数据发送失败: id=\(self.id), error=\(error)")
            }
        })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            session.invalidateAndCancel()
            self.session = nil
        }

        if let error {
            print("❌ 六速社区分片代理拉流失败: id=\(id), error=\(error.localizedDescription), receivedBytes=\(receivedBytes)")
            if !responseStarted {
                sendErrorAndClose(statusCode: 502, message: "Bad Gateway")
                return
            }
        }

        print("✅ 六速社区分片代理转发完成: id=\(id), status=\(statusCode), cost=\(elapsedMS())ms, bytes=\(receivedBytes)")
        connection.send(content: nil, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
            self.connection.cancel()
        })
    }

    private func elapsedMS() -> Int {
        Int(Date().timeIntervalSince(startTime) * 1000)
    }

    private func sendErrorAndClose(statusCode: Int, message: String) {
        let body = Data(message.utf8)
        // 使用简单字符串拼接，避免 Swift 多行字符串在 """ 前空行产生额外 \n
        let header = "HTTP/1.1 \(statusCode) \(DoubanImageProxyServer.reasonPhrase(for: statusCode))\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"

        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            self.connection.cancel()
        })
    }
}

/// 通用福利 JS Spider 分片转发器（SSL 绕过）
/// 与 LusushequStreamForwarder 功能相同，但使用通用 WelfareSSLBypassDelegate
private final class WelfareJSStreamForwarder: NSObject, URLSessionDataDelegate {
    private let id: String
    private let connection: NWConnection
    private let callbackQueue = OperationQueue()
    private var session: URLSession?
    private var responseStarted = false
    private var statusCode = 0
    private var receivedBytes = 0
    private var startTime = Date()
    private var firstByteLogged = false

    // 保存原始请求信息，用于 HTTP/1.1 回退
    private var fallbackURL: URL?
    private var fallbackHeaders: [String: String] = [:]
    private var fallbackMethod: String = "GET"
    private var fallbackRange: String?

    init(id: String, connection: NWConnection) {
        self.id = id
        self.connection = connection
        self.callbackQueue.maxConcurrentOperationCount = 1
        super.init()
    }

    func start(request: URLRequest) {
        startTime = Date()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: WelfareSSLBypassDelegate(), delegateQueue: callbackQueue)
        self.session = session
        session.dataTask(with: request).resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            print("❌ 福利JS分片代理上游响应无效: id=\(id)")
            sendErrorAndClose(statusCode: 502, message: "Invalid Upstream Response")
            completionHandler(.cancel)
            return
        }

        statusCode = http.statusCode
        let headers = http.allHeaderFields
        let contentType = DoubanImageProxyServer.headerValue(headers, "Content-Type") ?? "application/octet-stream"
        let contentLength = DoubanImageProxyServer.headerValue(headers, "Content-Length") ?? "\(response.expectedContentLength)"
        let contentRange = DoubanImageProxyServer.headerValue(headers, "Content-Range") ?? "无"

        print("📥 福利JS分片代理上游响应: id=\(id), status=\(statusCode), cost=\(elapsedMS())ms, contentType=\(contentType), contentLength=\(contentLength), contentRange=\(contentRange)")

        let responseHeader = DoubanImageProxyServer.streamResponseHeader(statusCode: statusCode, headers: headers)
        responseStarted = true
        connection.send(content: responseHeader, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { error in
            if let error {
                print("❌ 福利JS分片代理响应头发送失败: id=\(self.id), error=\(error)")
            }
        })
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedBytes += data.count
        if !firstByteLogged {
            firstByteLogged = true
            print("🚀 福利JS分片代理首包: id=\(id), cost=\(elapsedMS())ms, bytes=\(data.count)")
        }

        connection.send(content: data, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { error in
            if let error {
                print("❌ 福利JS分片代理数据发送失败: id=\(self.id), error=\(error)")
            }
        })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            session.invalidateAndCancel()
            self.session = nil
        }

        if let error {
            print("❌ 福利JS分片代理拉流失败(URLSession): id=\(id), error=\(error.localizedDescription), receivedBytes=\(receivedBytes)")
            if !responseStarted {
                // 尝试 HTTP/1.1 回退（解决部分 CDN HTTP/2 PROTOCOL_ERROR）
                tryHTTP11Fallback()
                return
            }
        }

        print("✅ 福利JS分片代理转发完成: id=\(id), status=\(statusCode), cost=\(elapsedMS())ms, bytes=\(receivedBytes)")
        connection.send(content: nil, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
            self.connection.cancel()
        })
    }

    private func elapsedMS() -> Int {
        Int(Date().timeIntervalSince(startTime) * 1000)
    }

    private func sendErrorAndClose(statusCode: Int, message: String) {
        let body = Data(message.utf8)
        // 使用简单字符串拼接，避免 Swift 多行字符串在 """ 前空行产生额外 \n
        let header = "HTTP/1.1 \(statusCode) \(DoubanImageProxyServer.reasonPhrase(for: statusCode))\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"

        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            self.connection.cancel()
        })
    }
}

// MARK: - HTTP/1.1 强制客户端 (解决部分 CDN HTTP/2 PROTOCOL_ERROR)

/// 使用 NWConnection 强制 HTTP/1.1 的下载器
/// 通过 ALPN 只通告 "http/1.1" 来避免 HTTP/2 协议协商
private final class WelfareHTTP11Downloader {

    private var connection: NWConnection?
    private var allData = Data()
    private var headerParsed = false
    private var headerBuffer = Data()
    private var statusCode = 0
    private var responseHeaders: [String: String] = [:]
    private var redirectCount = 0
    private let maxRedirects = 5
    private var timeoutWork: DispatchWorkItem?

    let id: String
    let timeout: TimeInterval

    init(id: String, timeout: TimeInterval = 20) {
        self.id = id
        self.timeout = timeout
    }

    func download(url: URL, headers: [String: String],
                  completion: @escaping (Data?, Int, [String: String], Error?) -> Void) {
        connectAndFetch(url: url, headers: headers, completion: completion)
    }

    private func connectAndFetch(url: URL, headers: [String: String],
                                 completion: @escaping (Data?, Int, [String: String], Error?) -> Void) {
        allData = Data()
        headerParsed = false
        headerBuffer = Data()
        statusCode = 0
        responseHeaders = [:]

        guard let host = url.host else {
            completion(nil, 0, [:], NSError(domain: "WelfareHTTP11", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无效URL"]))
            return
        }

        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let isTLS = url.scheme == "https"

        var path = url.path
        if let query = url.query, !query.isEmpty { path += "?\(query)" }
        if path.isEmpty { path = "/" }

        var request = "GET \(path) HTTP/1.1\r\n"
        request += "Host: \(host)"
        if let p = url.port, (isTLS && p != 443) || (!isTLS && p != 80) {
            request += ":\(p)"
        }
        request += "\r\n"

        for (key, value) in headers {
            let lower = key.lowercased()
            if lower == "host" || lower == "connection" || lower == "accept-encoding" || lower == "transfer-encoding" { continue }
            request += "\(key): \(value)\r\n"
        }
        request += "Accept: */*\r\n"
        request += "Accept-Encoding: identity\r\n"
        request += "Connection: close\r\n\r\n"

        let params: NWParameters
        if isTLS {
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_add_tls_application_protocol(tlsOptions.securityProtocolOptions, "http/1.1")
            sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions,
                { _, _, complete in complete(true) }, DispatchQueue.global())
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.connectionTimeout = Int(timeout)
            params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        } else {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.connectionTimeout = Int(timeout)
            params = NWParameters(tcp: tcpOptions)
        }

        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
        self.connection = conn

        let work = DispatchWorkItem { [weak self] in
            print("⏱️ HTTP11下载超时: id=\(self?.id ?? "")")
            self?.connection?.cancel()
        }
        timeoutWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 5, execute: work)

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                print("🔗 HTTP11连接就绪: id=\(self.id), host=\(host):\(port)")
                self.sendRequest(request, url: url, headers: headers, completion: completion)
            case .failed(let error):
                self.timeoutWork?.cancel()
                print("❌ HTTP11连接失败: id=\(self.id), err=\(error.localizedDescription)")
                completion(nil, 0, [:], error)
            case .cancelled:
                self.timeoutWork?.cancel()
                if self.statusCode == 0 {
                    completion(nil, 0, [:], NSError(domain: "WelfareHTTP11", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "连接已取消或超时"]))
                }
            default:
                break
            }
        }

        conn.start(queue: .global())
    }

    private func sendRequest(_ request: String, url: URL, headers: [String: String],
                             completion: @escaping (Data?, Int, [String: String], Error?) -> Void) {
        connection?.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.cleanup()
                completion(nil, 0, [:], error)
            } else {
                self.receiveData(url: url, headers: headers, completion: completion)
            }
        })
    }

    private func receiveData(url: URL, headers: [String: String],
                             completion: @escaping (Data?, Int, [String: String], Error?) -> Void) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                self.cleanup()
                if self.headerParsed {
                    self.finish(completion: completion)
                } else {
                    completion(nil, 0, [:], error)
                }
                return
            }

            if let data = data, !data.isEmpty {
                if !self.headerParsed {
                    self.headerBuffer.append(data)
                    if let bodyData = self.tryParseHeaders() {
                        self.headerParsed = true

                        if [301, 302, 303, 307, 308].contains(self.statusCode),
                           let location = self.responseHeaders["location"] {
                            self.redirectCount += 1
                            self.cleanup()
                            if self.redirectCount <= self.maxRedirects,
                               let redirectURL = self.resolveRedirect(location, from: url) {
                                print("🔄 HTTP11重定向: \(self.statusCode) -> \(redirectURL.absoluteString)")
                                self.connectAndFetch(url: redirectURL, headers: headers, completion: completion)
                                return
                            }
                        }

                        if !bodyData.isEmpty {
                            self.allData.append(bodyData)
                        }
                    }
                } else {
                    self.allData.append(data)
                }
            }

            if isComplete {
                self.cleanup()
                self.finish(completion: completion)
            } else {
                self.receiveData(url: url, headers: headers, completion: completion)
            }
        }
    }

    private func tryParseHeaders() -> Data? {
        guard let text = String(data: headerBuffer, encoding: .isoLatin1) else { return nil }
        guard let headerEnd = text.range(of: "\r\n\r\n") else { return nil }

        let headerText = String(text[..<headerEnd.lowerBound])
        let bodyStart = String(text[headerEnd.upperBound...])
        let bodyData = bodyStart.data(using: .isoLatin1) ?? Data()

        let lines = headerText.components(separatedBy: "\r\n")
        if let firstLine = lines.first {
            let parts = firstLine.components(separatedBy: " ")
            if parts.count >= 2 {
                statusCode = Int(parts[1]) ?? 0
            }
        }

        for i in 1..<lines.count {
            let line = lines[i]
            if let colonRange = line.range(of: ":") {
                let key = String(line[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let value = String(line[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                responseHeaders[key.lowercased()] = value
            }
        }

        return bodyData
    }

    private func resolveRedirect(_ location: String, from url: URL) -> URL? {
        if location.hasPrefix("http://") || location.hasPrefix("https://") {
            return URL(string: location)
        }
        if location.hasPrefix("/") {
            var components = URLComponents()
            components.scheme = url.scheme
            components.host = url.host
            components.port = url.port
            components.path = location
            return components.url
        }
        return URL(string: url.deletingLastPathComponent().appendingPathComponent(location).absoluteString)
    }

    private func finish(completion: @escaping (Data?, Int, [String: String], Error?) -> Void) {
        if responseHeaders["transfer-encoding"]?.lowercased().contains("chunked") == true {
            allData = Self.dechunk(allData)
        }
        print("✅ HTTP11下载完成: id=\(id), status=\(statusCode), bytes=\(allData.count)")
        completion(allData, statusCode, responseHeaders, nil)
    }

    private static func dechunk(_ data: Data) -> Data {
        var result = Data()
        let bytes = [UInt8](data)
        var pos = 0

        while pos < bytes.count {
            var lineEnd = pos
            while lineEnd < bytes.count - 1 && !(bytes[lineEnd] == 0x0D && bytes[lineEnd + 1] == 0x0A) {
                lineEnd += 1
            }
            if lineEnd >= bytes.count - 1 { break }

            let sizeStr = String(bytes: bytes[pos..<lineEnd], encoding: .ascii) ?? "0"
            let chunkSize = Int(sizeStr.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces), radix: 16) ?? 0
            pos = lineEnd + 2

            if chunkSize == 0 { break }

            let take = min(chunkSize, bytes.count - pos)
            result.append(contentsOf: bytes[pos..<(pos + take)])
            pos += take + 2
        }

        return result
    }

    private func cleanup() {
        timeoutWork?.cancel()
        timeoutWork = nil
        connection?.cancel()
        connection = nil
    }

    func cancel() { cleanup() }
}

/// 使用 NWConnection 强制 HTTP/1.1 的流式转发器
/// 用于 TS 分片等大文件的流式代理
private final class WelfareHTTP11StreamForwarder {

    private let id: String
    private let clientConnection: NWConnection
    private var upstreamConnection: NWConnection?
    private var headerParsed = false
    private var headerBuffer = Data()
    private var statusCode = 0
    private var responseHeaders: [String: String] = [:]
    private var responseStarted = false
    private var receivedBytes = 0
    private var startTime = Date()
    private var firstByteLogged = false
    private var isChunked = false
    private var chunkBuffer = Data()
    private var chunkState: Int = -1
    private var chunkRemaining: Int = 0
    private var redirectCount = 0
    private var timeoutWork: DispatchWorkItem?

    init(id: String, connection: NWConnection) {
        self.id = id
        self.clientConnection = connection
    }

    func start(url: URL, headers: [String: String], method: String, range: String?) {
        startTime = Date()
        connectAndStream(url: url, headers: headers, method: method, range: range)
    }

    private func connectAndStream(url: URL, headers: [String: String], method: String, range: String?) {
        headerParsed = false
        headerBuffer = Data()
        statusCode = 0
        responseHeaders = [:]
        responseStarted = false
        isChunked = false
        chunkBuffer = Data()
        chunkState = -1
        chunkRemaining = 0

        guard let host = url.host else {
            sendErrorAndClose(statusCode: 502, message: "Invalid URL")
            return
        }

        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let isTLS = url.scheme == "https"

        var path = url.path
        if let query = url.query, !query.isEmpty { path += "?\(query)" }
        if path.isEmpty { path = "/" }

        var request = "\(method) \(path) HTTP/1.1\r\n"
        request += "Host: \(host)"
        if let p = url.port, (isTLS && p != 443) || (!isTLS && p != 80) {
            request += ":\(p)"
        }
        request += "\r\n"

        for (key, value) in headers {
            let lower = key.lowercased()
            if lower == "host" || lower == "connection" || lower == "accept-encoding" || lower == "transfer-encoding" || lower == "range" { continue }
            request += "\(key): \(value)\r\n"
        }
        request += "Accept: */*\r\n"
        request += "Accept-Encoding: identity\r\n"
        if let range = range {
            request += "Range: \(range)\r\n"
        }
        request += "Connection: close\r\n\r\n"

        let params: NWParameters
        if isTLS {
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_add_tls_application_protocol(tlsOptions.securityProtocolOptions, "http/1.1")
            sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions,
                { _, _, complete in complete(true) }, DispatchQueue.global())
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.connectionTimeout = 15
            params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        } else {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.connectionTimeout = 15
            params = NWParameters(tcp: tcpOptions)
        }

        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
        self.upstreamConnection = conn

        let work = DispatchWorkItem { [weak self] in
            print("⏱️ HTTP11流超时: id=\(self?.id ?? "")")
            self?.upstreamConnection?.cancel()
        }
        timeoutWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: work)

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                print("🔗 HTTP11流连接就绪: id=\(self.id), host=\(host):\(port)")
                self.sendRequest(request, url: url, headers: headers, method: method, range: range)
            case .failed(let error):
                self.timeoutWork?.cancel()
                print("❌ HTTP11流连接失败: id=\(self.id), err=\(error.localizedDescription)")
                if !self.responseStarted {
                    self.sendErrorAndClose(statusCode: 502, message: "Bad Gateway: \(error.localizedDescription)")
                }
            case .cancelled:
                self.timeoutWork?.cancel()
                if !self.responseStarted {
                    self.sendErrorAndClose(statusCode: 502, message: "Connection Cancelled")
                }
            default:
                break
            }
        }

        conn.start(queue: .global())
    }

    private func sendRequest(_ request: String, url: URL, headers: [String: String], method: String, range: String?) {
        upstreamConnection?.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.cleanup()
                if !self.responseStarted {
                    self.sendErrorAndClose(statusCode: 502, message: "Send Failed: \(error.localizedDescription)")
                }
            } else {
                self.receiveData(url: url, headers: headers, method: method, range: range)
            }
        })
    }

    private func receiveData(url: URL, headers: [String: String], method: String, range: String?) {
        upstreamConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                self.cleanup()
                if self.responseStarted {
                    print("✅ HTTP11流完成(中断): id=\(self.id), bytes=\(self.receivedBytes), err=\(error.localizedDescription)")
                    self.clientConnection.send(content: nil, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
                        self.clientConnection.cancel()
                    })
                } else {
                    self.sendErrorAndClose(statusCode: 502, message: "Receive Failed: \(error.localizedDescription)")
                }
                return
            }

            if let data = data, !data.isEmpty {
                if !self.headerParsed {
                    self.headerBuffer.append(data)
                    if let bodyData = self.tryParseHeaders() {
                        self.headerParsed = true

                        if [301, 302, 303, 307, 308].contains(self.statusCode),
                           let location = self.responseHeaders["location"] {
                            self.redirectCount += 1
                            self.cleanup()
                            if self.redirectCount <= 5,
                               let redirectURL = self.resolveRedirect(location, from: url) {
                                print("🔄 HTTP11流重定向: \(self.statusCode) -> \(redirectURL.absoluteString)")
                                self.connectAndStream(url: redirectURL, headers: headers, method: method, range: range)
                                return
                            }
                        }

                        self.sendResponseHeader()

                        if !bodyData.isEmpty {
                            self.processBodyData(bodyData)
                        }
                    }
                } else {
                    self.processBodyData(data)
                }
            }

            if isComplete {
                self.cleanup()
                print("✅ HTTP11流转发完成: id=\(self.id), status=\(self.statusCode), bytes=\(self.receivedBytes), cost=\(self.elapsedMS())ms")
                self.clientConnection.send(content: nil, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
                    self.clientConnection.cancel()
                })
            } else {
                self.receiveData(url: url, headers: headers, method: method, range: range)
            }
        }
    }

    private func tryParseHeaders() -> Data? {
        guard let text = String(data: headerBuffer, encoding: .isoLatin1) else { return nil }
        guard let headerEnd = text.range(of: "\r\n\r\n") else { return nil }

        let headerText = String(text[..<headerEnd.lowerBound])
        let bodyStart = String(text[headerEnd.upperBound...])
        let bodyData = bodyStart.data(using: .isoLatin1) ?? Data()

        let lines = headerText.components(separatedBy: "\r\n")
        if let firstLine = lines.first {
            let parts = firstLine.components(separatedBy: " ")
            if parts.count >= 2 {
                statusCode = Int(parts[1]) ?? 0
            }
        }

        for i in 1..<lines.count {
            let line = lines[i]
            if let colonRange = line.range(of: ":") {
                let key = String(line[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let value = String(line[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                responseHeaders[key.lowercased()] = value
            }
        }

        isChunked = responseHeaders["transfer-encoding"]?.lowercased().contains("chunked") ?? false

        return bodyData
    }

    private func sendResponseHeader() {
        let contentType = responseHeaders["content-type"] ?? "application/octet-stream"
        let contentLength = responseHeaders["content-length"]
        let contentRange = responseHeaders["content-range"]
        let acceptRanges = responseHeaders["accept-ranges"] ?? "bytes"
        let reason = DoubanImageProxyServer.reasonPhrase(for: statusCode)

        var header = "HTTP/1.1 \(statusCode) \(reason)\r\nContent-Type: \(contentType)\r\nAccept-Ranges: \(acceptRanges)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        if let contentLength = contentLength {
            header += "Content-Length: \(contentLength)\r\n"
        }
        if let contentRange = contentRange {
            header += "Content-Range: \(contentRange)\r\n"
        }
        header += "\r\n"

        responseStarted = true
        clientConnection.send(content: Data(header.utf8), contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { error in
            if let error = error {
                print("❌ HTTP11流响应头发送失败: id=\(self.id), error=\(error)")
            }
        })
    }

    private func processBodyData(_ data: Data) {
        if isChunked {
            chunkBuffer.append(data)
            processChunked()
        } else {
            forwardToClient(data)
        }
    }

    private func processChunked() {
        let bytes = [UInt8](chunkBuffer)
        var pos = 0
        var consumed = 0

        while pos < bytes.count {
            if chunkState == -1 {
                var lineEnd = pos
                while lineEnd < bytes.count - 1 && !(bytes[lineEnd] == 0x0D && bytes[lineEnd + 1] == 0x0A) {
                    lineEnd += 1
                }
                if lineEnd >= bytes.count - 1 { break }

                let sizeStr = String(bytes: bytes[pos..<lineEnd], encoding: .ascii) ?? "0"
                let chunkSize = Int(sizeStr.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces), radix: 16) ?? 0
                pos = lineEnd + 2

                if chunkSize == 0 {
                    chunkBuffer = Data()
                    return
                }

                chunkState = 0
                chunkRemaining = chunkSize
            }

            if chunkState >= 0 {
                let take = min(chunkRemaining, bytes.count - pos)
                if take > 0 {
                    forwardToClient(Data(bytes[pos..<(pos + take)]))
                }
                pos += take
                chunkRemaining -= take
                consumed = pos

                if chunkRemaining == 0 {
                    if pos + 2 <= bytes.count {
                        pos += 2
                        consumed = pos
                    }
                    chunkState = -1
                } else {
                    break
                }
            }
        }

        if consumed > 0 && consumed < chunkBuffer.count {
            chunkBuffer = chunkBuffer.subdata(in: consumed..<chunkBuffer.count)
        } else if consumed >= chunkBuffer.count {
            chunkBuffer = Data()
        }
    }

    private func forwardToClient(_ data: Data) {
        receivedBytes += data.count
        if !firstByteLogged {
            firstByteLogged = true
            print("🚀 HTTP11流首包: id=\(id), cost=\(elapsedMS())ms, bytes=\(data.count)")
        }
        clientConnection.send(content: data, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { error in
            if let error = error {
                print("❌ HTTP11流数据发送失败: id=\(self.id), error=\(error)")
            }
        })
    }

    private func resolveRedirect(_ location: String, from url: URL) -> URL? {
        if location.hasPrefix("http://") || location.hasPrefix("https://") {
            return URL(string: location)
        }
        if location.hasPrefix("/") {
            var components = URLComponents()
            components.scheme = url.scheme
            components.host = url.host
            components.port = url.port
            components.path = location
            return components.url
        }
        return URL(string: url.deletingLastPathComponent().appendingPathComponent(location).absoluteString)
    }

    private func cleanup() {
        timeoutWork?.cancel()
        timeoutWork = nil
        upstreamConnection?.cancel()
        upstreamConnection = nil
    }

    private func elapsedMS() -> Int {
        Int(Date().timeIntervalSince(startTime) * 1000)
    }

    private func sendErrorAndClose(statusCode: Int, message: String) {
        let body = Data(message.utf8)
        let header = "HTTP/1.1 \(statusCode) \(DoubanImageProxyServer.reasonPhrase(for: statusCode))\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        clientConnection.send(content: response, completion: .contentProcessed { _ in
            self.clientConnection.cancel()
        })
    }
}

final class BaiduStreamSegmentCache {
    private struct Segment {
        let start: Int64
        let end: Int64
        let url: URL
        let modifiedAt: Date
        var length: Int64 { max(0, end - start + 1) }
    }

    struct CachedResponse {
        let headers: [AnyHashable: Any]
        let body: Data
    }

    private let maxVideoBytes: Int64 = 1_610_612_736 // 1.5 GiB
    private let defaultSegmentBytes: Int64 = 8 * 1024 * 1024
    private let largeSegmentBytes: Int64 = 16 * 1024 * 1024
    private let lock = NSLock()
    private var totalBytesById: [String: Int64] = [:]
    private var lastPreloadAt: [String: Date] = [:]
    private var activePreloads = Set<String>()
    private let rootURL: URL
    /// 预加载暂停标志：seek或播放缓冲不足时设为true，阻止新的预加载请求
    private var preloadPaused = false
    /// 当前正在进行的预加载URLSessionTask，用于取消
    private var activePreloadTask: URLSessionDataTask?
    /// 预加载task标识，用于闭包内匹配清理
    private var activePreloadTaskIdentifier: Int = 0

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        rootURL = caches.appendingPathComponent("vbox-baidu-stream-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        cleanupExpiredCaches(olderThan: 24 * 60 * 60)
    }

    func cachedResponse(id: String, requestedRange: String?) -> CachedResponse? {
        guard let request = Self.parseByteRange(requestedRange) else { return nil }
        let segments = scanSegments(id: id)
        guard let segment = segments.first(where: { $0.start <= request.start && $0.end >= request.end }),
              let data = try? Data(contentsOf: segment.url)
        else { return nil }

        let localStart = Int(request.start - segment.start)
        let localEnd = Int(request.end - segment.start)
        guard localStart >= 0, localEnd < data.count, localStart <= localEnd else { return nil }

        let body = data.subdata(in: localStart..<(localEnd + 1))
        let total = totalBytes(for: id) ?? max(segment.end + 1, request.end + 1)
        return CachedResponse(
            headers: [
                "Content-Type": "application/octet-stream",
                "Content-Length": "\(body.count)",
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes \(request.start)-\(request.end)/\(total)"
            ],
            body: body
        )
    }

    func store(id: String, requestedRange: String, response: HTTPURLResponse, body: Data) {
        guard !body.isEmpty, body.count <= Int(largeSegmentBytes + 2 * 1024 * 1024) else { return }
        let parsedResponse = Self.parseContentRange(response.value(forHTTPHeaderField: "Content-Range"))
        let requested = Self.parseByteRange(requestedRange)
        let start = parsedResponse?.start ?? requested?.start ?? 0
        let end = parsedResponse?.end ?? (start + Int64(body.count) - 1)
        let total = parsedResponse?.total
        guard end >= start, Int64(body.count) == end - start + 1 else { return }

        if let total {
            lock.lock()
            totalBytesById[id] = total
            lock.unlock()
        }

        let dir = directoryURL(for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(start)-\(end).part")
        do {
            try body.write(to: url, options: .atomic)
            pruneIfNeeded(id: id)
            postProgress(id: id)
            print("💾 百度分片缓存写入: id=\(id), range=\(start)-\(end), bytes=\(body.count), total=\(total.map { String($0) } ?? "未知")")
        } catch {
            print("⚠️ 百度分片缓存写入失败: id=\(id), error=\(error.localizedDescription)")
        }
    }

    func preloadAhead(
        id: String,
        currentTime: Double,
        duration: Double,
        requestBuilder: @escaping (String) -> URLRequest?
    ) {
        // 预加载已暂停时不执行（seek中或播放缓冲不足）
        lock.lock()
        let paused = preloadPaused
        lock.unlock()
        if paused { return }

        guard let total = totalBytes(for: id), total > 0 else { return }
        let now = Date()
        lock.lock()
        let shouldSkip = activePreloads.contains(id) || now.timeIntervalSince(lastPreloadAt[id] ?? .distantPast) < 4
        if !shouldSkip {
            activePreloads.insert(id)
            lastPreloadAt[id] = now
        }
        lock.unlock()
        guard !shouldSkip else { return }

        let bytesPerSecond = Double(total) / max(duration, 1)
        let currentByte = max(0, min(Int64(currentTime * bytesPerSecond), total - 1))
        let segmentSize = total >= 1_073_741_824 ? largeSegmentBytes : defaultSegmentBytes
        let start = (currentByte / segmentSize) * segmentSize
        // 预加载时长从600秒(10分钟)优化为60秒，减少带宽和内存占用
        let preloadSeconds: Double = 60
        let target = min(total - 1, currentByte + Int64(preloadSeconds * bytesPerSecond))

        fetchPreloadSegment(
            id: id,
            start: start,
            target: target,
            total: total,
            segmentSize: segmentSize,
            maxSegments: 12,
            requestBuilder: requestBuilder
        )
    }

    func postProgress(id: String) {
        let ranges = scanSegments(id: id)
            .sorted { $0.start < $1.start }
            .map { ["start": $0.start, "end": $0.end] }
        let cachedBytes = ranges.reduce(Int64(0)) { acc, item in
            guard let start = item["start"], let end = item["end"] else { return acc }
            return acc + max(0, end - start + 1)
        }
        NotificationCenter.default.post(
            name: .vboxBaiduStreamCacheProgress,
            object: nil,
            userInfo: [
                "id": id,
                "ranges": ranges,
                "totalBytes": totalBytes(for: id) ?? 0,
                "cachedBytes": cachedBytes,
                "maxBytes": maxVideoBytes
            ]
        )
    }

    func remove(id: String) {
        lock.lock()
        activePreloads.remove(id)
        totalBytesById.removeValue(forKey: id)
        lastPreloadAt.removeValue(forKey: id)
        lock.unlock()
        try? FileManager.default.removeItem(at: directoryURL(for: id))
    }

    func cleanupExpiredCaches(olderThan seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(-seconds)
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for dir in dirs {
            let modified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < deadline {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    private func fetchPreloadSegment(
        id: String,
        start: Int64,
        target: Int64,
        total: Int64,
        segmentSize: Int64,
        maxSegments: Int,
        requestBuilder: @escaping (String) -> URLRequest?
    ) {
        // 每个分片下载前检查暂停状态
        lock.lock()
        let paused = preloadPaused
        lock.unlock()
        guard !paused else {
            finishPreload(id: id)
            return
        }

        guard start <= target, maxSegments > 0, usedBytes(id: id) < maxVideoBytes else {
            finishPreload(id: id)
            return
        }

        let end = min(total - 1, start + segmentSize - 1)
        let range = "bytes=\(start)-\(end)"
        if cachedResponse(id: id, requestedRange: range) != nil {
            fetchPreloadSegment(id: id, start: end + 1, target: target, total: total, segmentSize: segmentSize, maxSegments: maxSegments - 1, requestBuilder: requestBuilder)
            return
        }
        guard let request = requestBuilder(range) else {
            finishPreload(id: id)
            return
        }

        let taskIdentifier = Int.random(in: 1...Int.max)
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            // 清理task引用（通过identifier匹配）
            self.lock.lock()
            if self.activePreloadTaskIdentifier == taskIdentifier {
                self.activePreloadTask = nil
                self.activePreloadTaskIdentifier = 0
            }
            self.lock.unlock()
            if let error {
                print("⚠️ 百度后台分片预加载失败: id=\(id), range=\(range), error=\(error.localizedDescription)")
                self.finishPreload(id: id)
                return
            }
            if let http = response as? HTTPURLResponse, let data, (200..<300).contains(http.statusCode) {
                self.store(id: id, requestedRange: range, response: http, body: data)
                self.fetchPreloadSegment(id: id, start: end + 1, target: target, total: total, segmentSize: segmentSize, maxSegments: maxSegments - 1, requestBuilder: requestBuilder)
            } else {
                self.finishPreload(id: id)
            }
        }
        lock.lock()
        activePreloadTask = task
        activePreloadTaskIdentifier = taskIdentifier
        lock.unlock()
        task.resume()
    }

    private func finishPreload(id: String) {
        lock.lock()
        activePreloads.remove(id)
        lock.unlock()
    }

    /// 暂停预加载（seek操作或播放缓冲不足时调用）
    func pausePreload() {
        lock.lock()
        preloadPaused = true
        let task = activePreloadTask
        activePreloadTask = nil
        activePreloadTaskIdentifier = 0
        activePreloads.removeAll()
        lock.unlock()
        task?.cancel()
        print("⏸️ 百度预加载已暂停（seek/缓冲不足）")
    }

    /// 恢复预加载（seek完成或播放缓冲恢复后调用）
    func resumePreload() {
        lock.lock()
        preloadPaused = false
        lock.unlock()
        print("▶️ 百度预加载已恢复")
    }

    /// 预加载是否处于暂停状态
    func isPreloadPaused() -> Bool {
        lock.lock()
        let paused = preloadPaused
        lock.unlock()
        return paused
    }

    private func totalBytes(for id: String) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return totalBytesById[id]
    }

    private func directoryURL(for id: String) -> URL {
        let safe = id.replacingOccurrences(of: #"[^A-Za-z0-9_-]"#, with: "_", options: .regularExpression)
        return rootURL.appendingPathComponent(safe, isDirectory: true)
    }

    private func scanSegments(id: String) -> [Segment] {
        let dir = directoryURL(for: id)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files.compactMap { url in
            guard url.pathExtension == "part" else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            let parts = name.split(separator: "-")
            guard parts.count == 2, let start = Int64(parts[0]), let end = Int64(parts[1]) else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return Segment(start: start, end: end, url: url, modifiedAt: modified)
        }
    }

    private func usedBytes(id: String) -> Int64 {
        scanSegments(id: id).reduce(Int64(0)) { $0 + $1.length }
    }

    private func pruneIfNeeded(id: String) {
        var segments = scanSegments(id: id)
        var used = segments.reduce(Int64(0)) { $0 + $1.length }
        guard used > maxVideoBytes else { return }

        segments.sort { $0.modifiedAt < $1.modifiedAt }
        for segment in segments where used > maxVideoBytes {
            try? FileManager.default.removeItem(at: segment.url)
            used -= segment.length
        }
    }

    private static func parseByteRange(_ raw: String?) -> (start: Int64, end: Int64)? {
        guard let raw else { return nil }
        let text = raw
            .replacingOccurrences(of: "bytes=", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let start = Int64(parts[0]),
              let end = Int64(parts[1]),
              end >= start else { return nil }
        return (start, end)
    }

    private static func parseContentRange(_ raw: String?) -> (start: Int64, end: Int64, total: Int64?)? {
        guard let raw else { return nil }
        let pattern = #"bytes\s+(\d+)-(\d+)/(\d+|\*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: nsRange),
              match.numberOfRanges >= 4,
              let startRange = Range(match.range(at: 1), in: raw),
              let endRange = Range(match.range(at: 2), in: raw),
              let start = Int64(raw[startRange]),
              let end = Int64(raw[endRange]) else { return nil }
        let total: Int64?
        if let totalRange = Range(match.range(at: 3), in: raw) {
            total = Int64(raw[totalRange])
        } else {
            total = nil
        }
        return (start, end, total)
    }
}
