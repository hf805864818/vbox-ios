import Foundation
import Network

final class DoubanImageProxyServer {
    static let shared = DoubanImageProxyServer()

    private let proxyPrefix = "proxy://"
    private let queue = DispatchQueue(label: "com.vbox.douban-image-proxy")
    private let cache = NSCache<NSString, NSData>()
    private var listener: NWListener?
    private var streamItems: [String: StreamItem] = [:]
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
        "img1.douban.com",
        "img2.douban.com",
        "img3.douban.com",
        "img9.douban.com"
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
              isAllowedStreamURL(sourceURL)
        else {
            return URL(string: sourceURL)
        }

        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        queue.sync {
            self.cleanupExpiredStreams()
            let item = StreamItem(
                url: targetURL,
                headers: headers,
                provider: provider,
                createdAt: Date()
            )
            self.streamItems[id] = item
            let cookie = Self.headerValue(headers, "Cookie") ?? Self.headerValue(headers, "X-Baidu-Pcs-Cookie") ?? ""
            let lowerCookie = cookie.lowercased()
            print("✅ 注册本地视频代理[\(provider)]: id=\(id), host=\(targetURL.host ?? ""), hasCookie=\(!cookie.isEmpty), hasBDUSS=\(lowerCookie.contains("bduss=")), hasSTOKEN=\(lowerCookie.contains("stoken=")), hasPANPSC=\(lowerCookie.contains("panpsc=")), headerKeys=\(headers.keys.sorted().joined(separator: ","))")
            self.preheatStream(item: item, id: id)
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/\(provider)-stream"
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
        if pathAndQuery.hasPrefix("/baidu-stream") || pathAndQuery.hasPrefix("/quark-stream") {
            routeStream(pathAndQuery, requestText: requestText, method: method, on: connection)
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
        fetchStream(item: item, id: id, method: method, incomingRange: incomingRange, on: connection)
    }

    private func fetchStream(item: StreamItem, id: String, method: String, incomingRange: String?, on connection: NWConnection) {
        var request = URLRequest(url: item.url)
        request.timeoutInterval = 30
        request.httpMethod = method

        for (key, value) in item.headers {
            let lower = key.lowercased()
            if lower == "host" || lower == "content-length" || lower == "connection" { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }

        if item.provider == "quark" {
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

        print("📡 本地视频代理上游请求[\(item.provider)]: method=\(method), id=\(id), range=\(request.value(forHTTPHeaderField: "Range") ?? "无"), host=\(item.url.host ?? ""), hasCookie=\(request.value(forHTTPHeaderField: "Cookie") != nil || request.value(forHTTPHeaderField: "X-Baidu-Pcs-Cookie") != nil), hasVideoAuth=\((request.value(forHTTPHeaderField: "Cookie") ?? "").contains("Video-Auth=")), hasUA=\(request.value(forHTTPHeaderField: "User-Agent") != nil), referer=\(request.value(forHTTPHeaderField: "Referer") ?? "无")")

        StreamForwarder(
            provider: item.provider,
            id: id,
            connection: connection
        ).start(request: request)
    }

    private func preheatStream(item: StreamItem, id: String) {
        guard item.provider == "baidu" || item.provider == "quark" else { return }
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
        let header = """
        HTTP/1.1 \(statusCode) \(reason)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Cache-Control: public, max-age=86400\r
        Connection: close\r
        \r

        """

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

        var header = """
        HTTP/1.1 \(statusCode) \(reason)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Accept-Ranges: \(acceptRanges)\r
        Cache-Control: no-store\r
        Connection: close\r
        """

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

        var header = """
        HTTP/1.1 \(statusCode) \(reason)\r
        Content-Type: \(contentType)\r
        Accept-Ranges: \(acceptRanges)\r
        Cache-Control: no-store\r
        Connection: close\r
        """

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

    private func cleanupExpiredStreams() {
        let deadline = Date().addingTimeInterval(-30 * 60)
        streamItems = streamItems.filter { $0.value.createdAt > deadline }
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

    init(provider: String, id: String, connection: NWConnection) {
        self.provider = provider
        self.id = id
        self.connection = connection
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
        connection.send(content: nil, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
            self.connection.cancel()
        })
    }

    private func elapsedMS() -> Int {
        Int(Date().timeIntervalSince(startTime) * 1000)
    }

    private func sendErrorAndClose(statusCode: Int, message: String) {
        let body = Data(message.utf8)
        let header = """
        HTTP/1.1 \(statusCode) \(DoubanImageProxyServer.reasonPhrase(for: statusCode))\r
        Content-Type: text/plain\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """

        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            self.connection.cancel()
        })
    }
}
