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

    /// 按响应头、页面 meta 和常见中文编码兜底解码网页内容。
    private func decodeText(_ data: Data, headers: [String: String]) -> String {
        if let charset = responseCharset(from: headers),
           let encoding = stringEncoding(for: charset),
           let text = String(data: data, encoding: encoding) {
            return text
        }

        if let utf8 = String(data: data, encoding: .utf8) {
            let metaCharset = detectMetaCharset(in: utf8)
            if let charset = metaCharset,
               charset.lowercased() != "utf-8",
               let encoding = stringEncoding(for: charset),
               let redecoded = String(data: data, encoding: encoding) {
                return redecoded
            }
            return utf8
        }

        let sample = String(data: data.prefix(4096), encoding: .ascii) ?? ""
        if let charset = detectMetaCharset(in: sample),
           let encoding = stringEncoding(for: charset),
           let text = String(data: data, encoding: encoding) {
            return text
        }

        let fallbackEncodings: [String.Encoding] = [.gbk, .gb2312, .big5, .isoLatin1]
        for encoding in fallbackEncodings {
            if let text = String(data: data, encoding: encoding), !text.isEmpty {
                return text
            }
        }

        return data.base64EncodedString()
    }

    private func responseCharset(from headers: [String: String]) -> String? {
        for (key, value) in headers where key.lowercased() == "content-type" {
            return value
                .components(separatedBy: ";")
                .compactMap { part -> String? in
                    let pair = part.components(separatedBy: "=")
                    guard pair.count == 2,
                          pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "charset" else {
                        return nil
                    }
                    return pair[1].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
                .first
        }
        return nil
    }

    private func detectMetaCharset(in text: String) -> String? {
        let pattern = #"(?i)<meta[^>]+charset=["']?\s*([a-zA-Z0-9_\-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private func stringEncoding(for charset: String) -> String.Encoding? {
        switch charset.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "utf-8", "utf8":
            return .utf8
        case "gbk", "gb2312", "gb-2312", "gb18030", "gb-18030", "gb18030-2000":
            return .gbk
        case "big5", "big-5":
            return .big5
        case "iso-8859-1", "latin1", "latin-1":
            return .isoLatin1
        default:
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            return String.Encoding(rawValue: nsEncoding)
        }
    }

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
            // 尝试 HTTP/1.1 回退（解决部分服务器 HTTP/2 PROTOCOL_ERROR）
            if method == "GET", let fallbackResult = tryHTTP11Fallback(url: requestURL, request: request) {
                return fallbackResult
            }
            result["content"] = errorMsg
            result["status"] = responseStatus
            return result
        }

        result["ok"] = (responseStatus >= 200 && responseStatus < 300)
        result["status"] = responseStatus
        result["headers"] = responseHeaders

        if let data = responseData {
            result["content"] = decodeText(data, headers: responseHeaders)
        }

        return result
    }

    /// HTTP/1.1 回退：当 URLSession 因 HTTP/2 PROTOCOL_ERROR 失败时，使用 NWConnection 强制 HTTP/1.1
    private func tryHTTP11Fallback(url: URL, request: URLRequest) -> [String: Any]? {
        var headers: [String: String] = [:]
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = key.lowercased()
            if lower == "host" || lower == "connection" || lower == "accept-encoding" { continue }
            headers[key] = value
        }

        let semaphore = DispatchSemaphore(value: 0)
        var fallbackResult: [String: Any]? = nil

        DoubanImageProxyServer.downloadHTTP11(url: url, headers: headers, timeout: timeout) { [weak self] data, status, respHeaders, error in
            if let error = error {
                print("[JSHTTPBridge] HTTP/1.1 回退也失败: \(error.localizedDescription)")
                fallbackResult = nil
            } else if let data = data {
                let content = self?.decodeText(data, headers: respHeaders) ?? ""
                fallbackResult = [
                    "ok": status >= 200 && status < 300,
                    "status": status,
                    "content": content,
                    "url": url.absoluteString,
                    "headers": respHeaders
                ] as [String: Any]
                print("[JSHTTPBridge] HTTP/1.1 回退成功: status=\(status), bytes=\(data.count)")
            }
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout + 5)
        if waitResult == .timedOut {
            print("[JSHTTPBridge] HTTP/1.1 回退超时")
            return nil
        }

        return fallbackResult
    }
}
