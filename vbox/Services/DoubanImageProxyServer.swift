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
                let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: self.port)!)
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
            self.streamItems[id] = StreamItem(
                url: targetURL,
                headers: headers,
                provider: provider,
                createdAt: Date()
            )
            print("✅ 注册本地视频代理[\(provider)]: \(id), host=\(targetURL.host ?? "")")
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
        guard parts.count >= 2, parts[0] == "GET" else {
            send(statusCode: 405, body: Data("Method Not Allowed".utf8), contentType: "text/plain", on: connection)
            return
        }

        let pathAndQuery = String(parts[1])
        if pathAndQuery.hasPrefix("/baidu-stream") {
            routeStream(pathAndQuery, requestText: requestText, on: connection)
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

    private func routeStream(_ pathAndQuery: String, requestText: String, on connection: NWConnection) {
        guard let components = URLComponents(string: "http://127.0.0.1\(pathAndQuery)"),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let item = streamItems[id]
        else {
            send(statusCode: 404, body: Data("Stream Not Found".utf8), contentType: "text/plain", on: connection)
            return
        }

        let requestHeaders = parseRequestHeaders(requestText)
        let incomingRange = requestHeaders["range"]
        fetchStream(item: item, incomingRange: incomingRange, on: connection)
    }

    private func fetchStream(item: StreamItem, incomingRange: String?, on connection: NWConnection) {
        var request = URLRequest(url: item.url)
        request.timeoutInterval = 30

        for (key, value) in item.headers {
            let lower = key.lowercased()
            if lower == "host" || lower == "content-length" || lower == "connection" { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }

        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("netdisk;P2SP;2.2.101.236;netdisk;12.24.6;PHW110;android-android;12;JSbridge4.4.0;jointBridge;1.1.0;", forHTTPHeaderField: "User-Agent")
        }
        if request.value(forHTTPHeaderField: "Referer") == nil {
            request.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
        }
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        if let range = normalizedRange(incomingRange) {
            request.setValue(range, forHTTPHeaderField: "Range")
        }

        print("📡 本地视频代理请求[\(item.provider)]: range=\(request.value(forHTTPHeaderField: "Range") ?? "无"), host=\(item.url.host ?? "")")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                print("❌ 本地视频代理拉流失败: \(error.localizedDescription)")
                self.send(statusCode: 502, body: Data("Bad Gateway".utf8), contentType: "text/plain", on: connection)
                return
            }

            guard let data else {
                self.send(statusCode: 502, body: Data("Empty Stream".utf8), contentType: "text/plain", on: connection)
                return
            }

            let http = response as? HTTPURLResponse
            let statusCode = http?.statusCode ?? 200
            let headers = http?.allHeaderFields ?? [:]
            print("📥 本地视频代理响应: status=\(statusCode), bytes=\(data.count), range=\(http?.value(forHTTPHeaderField: "Content-Range") ?? "无")")
            self.sendStream(statusCode: statusCode, headers: headers, body: data, on: connection)
        }.resume()
    }

    private func normalizedRange(_ raw: String?) -> String? {
        guard let raw, raw.lowercased().hasPrefix("bytes=") else {
            return "bytes=0-2097151"
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

        let end = start + 2 * 1024 * 1024 - 1
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
        let reason = reasonPhrase(for: statusCode)
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
        let reason = reasonPhrase(for: statusCode)
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

        return host.contains("baidupcs.com") || host == "d.pcs.baidu.com"
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

    private func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 400:
            return "Bad Request"
        case 403:
            return "Forbidden"
        case 405:
            return "Method Not Allowed"
        case 502:
            return "Bad Gateway"
        default:
            return "OK"
        }
    }
}
