import Foundation

/// 通用 SSL 证书绕过 Delegate（用于福利 JS Spider 访问自签名证书服务器）
final class WelfareSSLBypassDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// JS HTTP 桥接 — 提供蜘蛛脚本中的同步 HTTP 请求能力
/// 蜘蛛脚本中的 http(url, options) 会调用到此桥接
class JSHTTPBridge {

    // 超时设置
    var timeout: TimeInterval = 15

    // SSL 绕过开关（福利 JS Spider 可能需要访问自签名证书服务器）
    var sslBypass: Bool = false

    // Cookie 存储
    private var cookieStore: [String: [String: String]] = [:]

    init() {}

    /// 创建 URLSession（根据 sslBypass 决定是否绕过 SSL 验证）
    private func createSession() -> URLSession {
        if sslBypass {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout + 10
            return URLSession(configuration: config, delegate: WelfareSSLBypassDelegate(), delegateQueue: nil)
        }
        return URLSession.shared
    }

    /// 同步 HTTP 请求（被JS引擎调用）
    /// - Parameters:
    ///   - url: 请求地址
    ///   - options: 请求选项（headers, data, method 等）
    /// - Returns: 包含响应内容的字典
    func syncRequest(url: String, options: [String: Any]) -> [String: Any] {

        var result: [String: Any] = [
            "ok": false,
            "status": 0,
            "content": "",
            "url": url,
            "headers": [:]
        ]

        guard let requestURL = URL(string: url) else {
            result["content"] = "无效URL"
            return result
        }

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseStatus: Int = 0
        var responseHeaders: [String: String] = [:]
        var errorMsg: String?

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = timeout

        // 解析 options
        let method = (options["method"] as? String)?.uppercased() ?? "GET"
        request.httpMethod = method

        // 设置请求头
        if let headers = options["headers"] as? [String: String] {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        // 默认 User-Agent
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
        }

        // 设置请求体 (POST)
        if let data = options["data"] as? String {
            request.httpBody = data.data(using: .utf8)
        }

        // 设置 Referer
        if let referer = options["referer"] as? String {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }

        // 执行请求（使用支持 SSL 绕过的 session）
        let session = createSession()
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                errorMsg = error.localizedDescription
            } else if let httpResponse = response as? HTTPURLResponse {
                responseStatus = httpResponse.statusCode

                // 提取响应头
                for (key, value) in httpResponse.allHeaderFields {
                    if let keyStr = key as? String, let valueStr = value as? String {
                        responseHeaders[keyStr] = valueStr
                    }
                }

                // 提取响应体
                if let data = data {
                    responseData = data
                }
            }
            semaphore.signal()
        }
        task.resume()
        // 添加超时保护：防止 URLSession 回调异常不触发时永久阻塞，
        // 超时时间 = 请求超时 + 5秒缓冲，正常请求不受影响
        let waitResult = semaphore.wait(timeout: .now() + timeout + 5)
        if waitResult == .timedOut {
            task.cancel()
            if sslBypass { session.invalidateAndCancel() }
            result["content"] = "请求超时"
            result["status"] = 0
            return result
        }

        // 清理临时 session（仅 SSL 绕过模式创建的独立 session 需要手动清理）
        if sslBypass { session.finishTasksAndInvalidate() }

        // 构建返回
        if let errorMsg = errorMsg {
            result["content"] = errorMsg
            result["status"] = responseStatus
            return result
        }

        result["ok"] = (responseStatus >= 200 && responseStatus < 300)
        result["status"] = responseStatus
        result["headers"] = responseHeaders

        if let data = responseData {
            // 尝试 UTF-8 解码
            if let text = String(data: data, encoding: .utf8) {
                result["content"] = text
            } else if let text = String(data: data, encoding: .utf8) {
                // GBK 编码尝试 — 可接入 gbk.js
                result["content"] = text
            } else {
                result["content"] = data.base64EncodedString()
            }
        }

        return result
    }
}
