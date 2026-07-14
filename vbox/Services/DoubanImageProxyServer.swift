import Foundation
import Network

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
        queue.sync {
            self.cleanupExpiredStreams()
            let item = StreamItem(
                url: targetURL,
                headers: headers,
                provider: "quark-m3u8",
                createdAt: Date()
            )
            self.streamItems[id] = item
            let cookie = Self.headerValue(headers, "Cookie") ?? ""
            print("✅ 注册夸克 m3u8 代理: id=\(id), host=\(targetURL.host ?? ""), hasCookie=\(!cookie.isEmpty), hasVideoAuth=\(cookie.contains("Video-Auth="))")
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/quark-m3u8"
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
            sendNoStore(statusCode: 200, body: Data(), contentType: "application/vnd.apple.mpegurl", on: connection)
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
                request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) 115Chrome/33.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            }
            if request.value(forHTTPHeaderField: "Referer") == nil {
                request.setValue("https://115.com/", forHTTPHeaderField: "Referer")
            }
            if request.value(forHTTPHeaderField: "Origin") == nil {
                request.setValue("https://115.com", forHTTPHeaderField: "Origin")
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

    private func sendNoStore(statusCode: Int, body: Data, contentType: String, on connection: NWConnection) {
        let reason = Self.reasonPhrase(for: statusCode)
        let header = """
        HTTP/1.1 \(statusCode) \(reason)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
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
            || isAliPlaybackHost(host)
            || isUCPlaybackHost(host)
            || is115PlaybackHost(host)
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
