import Foundation
import Network

final class DoubanImageProxyServer {
    static let shared = DoubanImageProxyServer()

    private let queue = DispatchQueue(label: "com.vbox.douban-image-proxy")
    private let cache = NSCache<NSString, NSData>()
    private var listener: NWListener?
    private(set) var port: UInt16 = 18080

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
                        print("✅ 豆瓣封面本地代理已启动: http://127.0.0.1:\(self.port)")
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

    func proxiedURL(for rawURL: String?) -> URL? {
        guard let rawURL, !rawURL.isEmpty else { return nil }
        guard isAllowedDoubanImageURL(rawURL) else { return URL(string: rawURL) }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/douban-cover"
        components.queryItems = [
            URLQueryItem(name: "url", value: rawURL)
        ]
        return components.url
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
