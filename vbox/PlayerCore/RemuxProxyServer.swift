import Foundation
import Network
import UIKit

// MARK: - 转封装代理服务器

/// 独立的转封装代理服务器，运行在 127.0.0.1:18081。
///
/// **与主代理 (18080) 完全隔离**，不影响现有网盘播放功能。
///
/// 数据流：
/// ```
/// AVPlayer 请求 http://127.0.0.1:18081/remux?id=xxx
///     → 查找注册的上游 URL
///     → URLSession 流式拉取上游数据
///     → StreamRemuxer 实时转封装为 fMP4（通过 onSegmentReady 流式输出）
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
    /// 后台任务标识，确保 App 进入后台后转封装代理的上游下载能继续进行
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    /// 当前活跃的流式下载任务数，用于管理后台任务生命周期
    private var activeStreamCount: Int = 0

    // MARK: - 数据结构

    private struct RemuxStreamItem {
        let url: URL
        let headers: [String: String]
        let provider: String
        let createdAt: Date
        var sourceFormat: StreamRemuxer.SourceFormat = .unknown
        /// 是否已经检测过格式（通过前几字节魔数）
        var formatDetected: Bool = false
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
        endBackgroundTaskIfNeeded()
        print("[RemuxProxy] 服务器已停止")
    }

    // MARK: - 流注册

    /// 注册一个待转封装的上游流
    /// - Returns: 本地代理 URL，AVPlayer 直接播放此 URL
    func registerStream(url: URL, headers: [String: String] = [:], provider: String = "generic") -> URL? {
        if !isRunning {
            start()
            guard listener != nil else {
                print("[RemuxProxy] 服务器未启动，无法注册流")
                return nil
            }
            print("[RemuxProxy] 服务器启动中，先注册流等待 AVPlayer 请求")
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

        // 启动流式转封装
        beginStreamDownload(id: id, item: item, on: connection)
    }

    // MARK: - 流式下载与转封装

    /// 启动流式下载并实时转封装（MKV/FLV → fMP4）或透传（MP4）
    private func beginStreamDownload(id: String, item: RemuxStreamItem, on connection: NWConnection) {
        var request = URLRequest(url: item.url)
        for (key, value) in item.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // 启动后台任务保活
        beginBackgroundTaskIfNeeded()

        let remuxer = StreamRemuxer()
        var headerSent = false
        var isPassthrough = false // MP4/unknown 直接透传

        let delegate = RemuxStreamDelegate(
            queue: queue,
            onDataReceived: { data in
                // 响应头还没发的话先发
                if !headerSent {
                    headerSent = true
                    let header = self.buildHTTPHeader(
                        statusCode: 200,
                        contentType: "video/mp4",
                        contentLength: nil
                    )
                    connection.send(content: header.data(using: .utf8), completion: .contentProcessed { _ in })
                }

                // 如果已经确定是透传模式（MP4/unknown），直接转发数据
                if isPassthrough {
                    connection.send(content: data, completion: .contentProcessed { _ in })
                    return
                }

                // 喂给转封装器
                remuxer.processBytes(data)

                // 检测是否为 MP4 或 unknown，如果是则切换到透传模式
                let fmt = remuxer.sourceFormat
                if fmt == .mp4 || fmt == .unknown {
                    isPassthrough = true
                    // 已经 processBytes 的数据可能没被透传出去
                    // 对于 MP4，handleMP4Passthrough 只设置了 isComplete，没有保存数据
                    // 所以我们需要把已接收的数据重新发一遍
                    // 但这会导致重复发送……
                    // 简化处理：因为 MP4 检测只需要前 12 字节（ftyp box）
                    // 我们把已收到的这部分数据也发出去
                    connection.send(content: data, completion: .contentProcessed { _ in })
                }
            },
            onComplete: { [weak self] in
                guard let self else { return }
                if !isPassthrough {
                    // 转封装模式：finalize 兜底
                    let finalResult = remuxer.finalize()
                    for segment in finalResult.mediaSegments {
                        connection.send(content: segment, completion: .contentProcessed { _ in })
                    }
                }
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                self.endStreamBackgroundTask()
            },
            onError: { [weak self] error in
                print("[RemuxProxy] 流式下载失败: \(error?.localizedDescription ?? "unknown")")
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                self?.endStreamBackgroundTask()
            }
        )

        // 设置转封装回调：init segment 和 media segment 就绪时立即发送
        remuxer.onInitSegmentReady = { initData in
            delegate.queue.async {
                connection.send(content: initData, completion: .contentProcessed { _ in })
            }
        }
        remuxer.onSegmentReady = { segmentData in
            delegate.queue.async {
                connection.send(content: segmentData, completion: .contentProcessed { _ in })
            }
        }

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.networkServiceType = .video
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()

        // 绑定 delegate 到 task，防止被释放
        delegate.associatedTask = task
        objc_setAssociatedObject(task, &RemuxProxyServer.associatedDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private static var associatedDelegateKey: UInt8 = 0

    // MARK: - 后台任务管理

    private func beginBackgroundTaskIfNeeded() {
        queue.async { [weak self] in
            guard let self else { return }
            self.activeStreamCount += 1
            guard self.backgroundTaskId == .invalid else { return }

            self.backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "RemuxProxyDownload") { [weak self] in
                // 后台时间耗尽，清理
                guard let self else { return }
                if self.backgroundTaskId != .invalid {
                    UIApplication.shared.endBackgroundTask(self.backgroundTaskId)
                    self.backgroundTaskId = .invalid
                }
            }
            print("[RemuxProxy] 开始后台任务，活跃流数=\(self.activeStreamCount)")
        }
    }

    private func endStreamBackgroundTask() {
        queue.async { [weak self] in
            guard let self else { return }
            self.activeStreamCount = max(0, self.activeStreamCount - 1)
            if self.activeStreamCount == 0, self.backgroundTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(self.backgroundTaskId)
                self.backgroundTaskId = .invalid
                print("[RemuxProxy] 结束后台任务")
            }
        }
    }

    // 兼容旧方法引用（如果有的话）
    private func endBackgroundTaskIfNeeded() {
        endStreamBackgroundTask()
    }

    // MARK: - HTTP 响应构建

    /// 构建 HTTP 响应头。
    /// 注意：fMP4 流式播放不需要 Accept-Ranges，AVPlayer 按流式/直播模式处理即可。
    private func buildHTTPHeader(statusCode: Int, contentType: String, contentLength: Int?) -> String {
        var header = "HTTP/1.1 \(statusCode) \(statusText(statusCode))\r\n"
        header += "Content-Type: \(contentType)\r\n"
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

// MARK: - 流式下载代理

/// URLSession 流式下载代理，负责接收上游数据并交给转封装器处理。
///
/// 所有回调都派发到 RemuxProxyServer 的串行队列上，保证线程安全。
final class RemuxStreamDelegate: NSObject, URLSessionDataDelegate {

    let queue: DispatchQueue
    private var onDataReceived: ((Data) -> Void)?
    private var onComplete: (() -> Void)?
    private var onError: ((Error?) -> Void)?

    weak var associatedTask: URLSessionDataTask?

    init(
        queue: DispatchQueue,
        onDataReceived: @escaping (Data) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error?) -> Void
    ) {
        self.queue = queue
        self.onDataReceived = onDataReceived
        self.onComplete = onComplete
        self.onError = onError
        super.init()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.onDataReceived?(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async { [weak self] in
            guard let self else { return }
            if let error {
                self.onError?(error)
            } else {
                self.onComplete?()
            }
            // 清理
            self.onDataReceived = nil
            self.onComplete = nil
            self.onError = nil
            session.finishTasksAndInvalidate()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.allow)
    }
}
