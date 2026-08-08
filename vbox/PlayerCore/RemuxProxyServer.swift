import Foundation
import Network

// MARK: - 转封装代理服务器

/// 独立的转封装代理服务器，运行在 127.0.0.1:18081。
///
/// **与主代理 (18080) 完全隔离**，不影响现有网盘播放功能。
///
/// 数据流：
/// ```
/// AVPlayer 请求 http://127.0.0.1:18081/remux?id=xxx
///     → 查找注册的上游 URL
///     → URLSession 拉取上游数据
///     → StreamRemuxer 实时转封装为 fMP4
///     → 流式返回给 AVPlayer
/// ```
///
/// **使用方式**：
/// 1. `start()` 启动服务器
/// 2. `registerStream(url:headers:provider:)` 注册上游流
/// 3. AVPlayer 播放返回的本地 URL
/// 4. `unregisterStream(id:)` 或 `stop()` 清理
///
/// **支持格式**：
/// - MP4 → 直接透传（无需转封装）
/// - MKV → 转封装为 fMP4
/// - FLV → 转封装为 fMP4
/// - WebM → 转封装为 fMP4（仅 H.264/H.265）
final class RemuxProxyServer {

    static let shared = RemuxProxyServer()

    // MARK: - 公开属性

    private(set) var port: UInt16 = 18081
    private(set) var isRunning = false

    // MARK: - 私有属性

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.vbox.remux-proxy", qos: .userInitiated)
    private var streamItems: [String: RemuxStreamItem] = [:]
    private let lock = NSLock()

    // MARK: - 数据结构

    private struct RemuxStreamItem {
        let url: URL
        let headers: [String: String]
        let provider: String
        let createdAt: Date
        var initSegment: Data?
        var mediaSegments: [Data] = []
        var isComplete: Bool = false
        var sourceFormat: StreamRemuxer.SourceFormat = .unknown
    }

    // MARK: - 初始化

    private init() {}

    // MARK: - 服务器生命周期

    func start() {
        guard !isRunning else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ipOptions.version = .v4
            }

            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("✅ [RemuxProxy] 转封装代理已启动: http://127.0.0.1:\(self?.port ?? 0)")
                    self?.isRunning = true
                case .failed(let error):
                    print("❌ [RemuxProxy] 启动失败: \(error)")
                    self?.listener?.cancel()
                    self?.listener = nil
                    self?.isRunning = false
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            print("❌ [RemuxProxy] 创建 listener 失败: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        lock.lock()
        streamItems.removeAll()
        lock.unlock()
        print("[RemuxProxy] 服务器已停止")
    }

    // MARK: - 流注册

    /// 注册一个待转封装的上游流
    /// - Returns: 本地代理 URL，AVPlayer 直接播放此 URL
    func registerStream(url: URL, headers: [String: String] = [:], provider: String = "generic") -> URL? {
        guard isRunning else {
            print("[RemuxProxy] 服务器未启动，无法注册流")
            return nil
        }

        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let item = RemuxStreamItem(
            url: url,
            headers: headers,
            provider: provider,
            createdAt: Date()
        )

        lock.lock()
        streamItems[id] = item
        lock.unlock()

        print("[RemuxProxy] 注册流: id=\(id), provider=\(provider), host=\(url.host ?? "")")

        // 异步预热：下载前 2MB 检测格式并生成初始化段
        queue.async { [weak self] in
            self?.preheatStream(id: id)
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/remux"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url
    }

    func unregisterStream(id: String) {
        lock.lock()
        streamItems.removeValue(forKey: id)
        lock.unlock()
    }

    // MARK: - 连接处理

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            self.handleRequest(data, on: connection)
        }
    }

    private func handleRequest(_ requestData: Data, on connection: NWConnection) {
        guard let requestText = String(data: requestData, encoding: .utf8) else {
            sendError(400, "Bad Request", on: connection)
            return
        }

        let lines = requestText.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            sendError(400, "Bad Request", on: connection)
            return
        }

        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendError(400, "Bad Request", on: connection)
            return
        }

        let method = parts[0].uppercased()
        guard method == "GET" || method == "HEAD" else {
            sendError(405, "Method Not Allowed", on: connection)
            return
        }

        let pathAndQuery = parts[1]
        guard pathAndQuery.hasPrefix("/remux"),
              let components = URLComponents(string: "http://127.0.0.1\(pathAndQuery)"),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value
        else {
            sendError(404, "Not Found", on: connection)
            return
        }

        lock.lock()
        let item = streamItems[id]
        lock.unlock()

        guard let item else {
            sendError(404, "Stream Not Found", on: connection)
            return
        }

        if method == "HEAD" {
            sendHeadResponse(on: connection)
            return
        }

        streamRemuxedContent(id: id, item: item, on: connection)
    }

    // MARK: - 预热

    private func preheatStream(id: String) {
        lock.lock()
        guard var item = streamItems[id] else {
            lock.unlock()
            return
        }
        lock.unlock()

        let preheatSize = 2 * 1024 * 1024
        var request = URLRequest(url: item.url)
        request.setValue("bytes=0-\(preheatSize - 1)", forHTTPHeaderField: "Range")
        for (key, value) in item.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var responseData = Data()

        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { responseData = data }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 10)

        guard !responseData.isEmpty else {
            print("[RemuxProxy] 预热失败: id=\(id)")
            return
        }

        let format = StreamRemuxer.detectFormat(from: responseData)

        if format == .mp4 {
            lock.lock()
            streamItems[id]?.sourceFormat = .mp4
            streamItems[id]?.isComplete = true
            streamItems[id]?.mediaSegments = [responseData]
            lock.unlock()
            print("[RemuxProxy] 检测为 MP4 格式，直接透传: id=\(id)")
            return
        }

        if format == .unknown {
            print("[RemuxProxy] 无法识别格式，将尝试透传: id=\(id)")
            lock.lock()
            streamItems[id]?.sourceFormat = .unknown
            streamItems[id]?.isComplete = true
            streamItems[id]?.mediaSegments = [responseData]
            lock.unlock()
            return
        }

        let remuxer = StreamRemuxer()
        remuxer.processBytes(responseData)

        let result = remuxer.finalize()

        lock.lock()
        streamItems[id]?.sourceFormat = format
        streamItems[id]?.initSegment = result.initSegment
        streamItems[id]?.mediaSegments = result.mediaSegments
        if result.mediaSegments.isEmpty {
            streamItems[id]?.isComplete = true
        }
        lock.unlock()

        print("[RemuxProxy] 预热完成: id=\(id), format=\(format), initSeg=\(result.initSegment.count)B, mediaSegs=\(result.mediaSegments.count)")
    }

    // MARK: - 流式返回

    private func streamRemuxedContent(id: String, item: RemuxStreamItem, on connection: NWConnection) {
        if item.sourceFormat == .mp4 || item.sourceFormat == .unknown {
            streamRawContent(id: id, item: item, on: connection)
            return
        }

        if let initSeg = item.initSegment, !initSeg.isEmpty {
            let initHeader = buildHTTPHeader(
                statusCode: 200,
                contentType: "video/mp4",
                contentLength: nil
            )
            connection.send(content: initHeader.data(using: .utf8), completion: .contentProcessed { _ in })
            connection.send(content: initSeg, completion: .contentProcessed { _ in })
        }

        for segment in item.mediaSegments {
            connection.send(content: segment, completion: .contentProcessed { _ in })
        }

        if item.isComplete {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            return
        }

        fetchAndRemuxRemaining(id: id, item: item, on: connection)
    }

    private func streamRawContent(id: String, item: RemuxStreamItem, on connection: NWConnection) {
        let header = buildHTTPHeader(statusCode: 200, contentType: "video/mp4", contentLength: nil)
        connection.send(content: header.data(using: .utf8), completion: .contentProcessed { _ in })

        for segment in item.mediaSegments {
            connection.send(content: segment, completion: .contentProcessed { _ in })
        }

        if item.isComplete {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        } else {
            fetchRemaining(id: id, item: item, on: connection)
        }
    }

    private func fetchAndRemuxRemaining(id: String, item: RemuxStreamItem, on connection: NWConnection) {
        let offset = 2 * 1024 * 1024
        var request = URLRequest(url: item.url)
        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        for (key, value) in item.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self, let data, error == nil else {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                return
            }

            let remuxer = StreamRemuxer()
            remuxer.processBytes(data)
            let result = remuxer.finalize()

            for segment in result.mediaSegments {
                connection.send(content: segment, completion: .contentProcessed { _ in })
            }

            self.lock.lock()
            self.streamItems[id]?.isComplete = true
            self.lock.unlock()

            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        }
        task.resume()
    }

    private func fetchRemaining(id: String, item: RemuxStreamItem, on connection: NWConnection) {
        let offset = 2 * 1024 * 1024
        var request = URLRequest(url: item.url)
        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        for (key, value) in item.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self, let data, error == nil else {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                return
            }

            connection.send(content: data, completion: .contentProcessed { _ in })

            self.lock.lock()
            self.streamItems[id]?.isComplete = true
            self.lock.unlock()

            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        }
        task.resume()
    }

    // MARK: - HTTP 响应构建

    private func buildHTTPHeader(statusCode: Int, contentType: String, contentLength: Int?) -> String {
        var header = "HTTP/1.1 \(statusCode) \(statusText(statusCode))\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Accept-Ranges: bytes\r\n"
        header += "Cache-Control: no-store, no-cache\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        if let length = contentLength {
            header += "Content-Length: \(length)\r\n"
        }
        header += "Connection: close\r\n\r\n"
        return header
    }

    private func sendHeadResponse(on connection: NWConnection) {
        let header = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: video/mp4\r\n" +
            "Accept-Ranges: bytes\r\n" +
            "Cache-Control: no-store\r\n" +
            "Connection: close\r\n\r\n"
        connection.send(content: header.data(using: .utf8), completion: .contentProcessed { _ in })
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func sendError(_ statusCode: Int, _ message: String, on connection: NWConnection) {
        let body = "{\"error\": \"\(message)\"}"
        let header = "HTTP/1.1 \(statusCode) \(statusText(statusCode))\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(body.utf8.count)\r\n" +
            "Connection: close\r\n\r\n"
        connection.send(content: header.data(using: .utf8), completion: .contentProcessed { _ in })
        connection.send(content: body.data(using: .utf8), completion: .contentProcessed { _ in })
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "Error"
        }
    }
}