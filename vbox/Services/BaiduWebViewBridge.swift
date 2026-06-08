import Foundation
import WebKit

/// 用 WKWebView 发 HTTP 请求，绕开 URLSession 的 TLS 指纹
/// 百度风控对 Safari/WebView 的 JA3 指纹更宽容
class BaiduWebViewBridge: NSObject {
    static let shared = BaiduWebViewBridge()
    
    private var webView: WKWebView?
    private var pendingRequests: [String: (Result<Data, Error>) -> Void] = [:]
    private let queue = DispatchQueue(label: "baidu.webview.bridge")
    private var requestIdCounter = 0
    
    private override init() {
        super.init()
        setupWebView()
    }
    
    private func setupWebView() {
        let config = WKWebViewConfiguration()
        let userController = config.userContentController
        
        // 注入消息回调
        userController.add(self, name: "bridgeResponse")
        
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"
        webView.isHidden = true
        
        // 加载一个空白页初始化 JS 环境
        webView.loadHTMLString("<html><body></body></html>", baseURL: URL(string: "https://pan.baidu.com"))
        
        // 把 WebView 加到 key window 确保存活
        DispatchQueue.main.async {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first {
                window.addSubview(webView)
                webView.frame = CGRect(x: -1, y: -1, width: 1, height: 1)
            }
        }
        
        self.webView = webView
    }
    
    /// 通过 WebView JS fetch 发请求
    func request(
        url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: String? = nil,
        timeout: TimeInterval = 15
    ) async throws -> (data: Data, response: HTTPURLResponse?) {
        
        guard let webView = webView else {
            throw BridgeError.notReady
        }
        
        requestIdCounter += 1
        let requestId = "req_\(requestIdCounter)"
        
        // 构造 JS fetch 代码
        var headersJSON = "{"
        for (i, (key, val)) in headers.enumerated() {
            let escapedKey = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let escapedVal = val.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            headersJSON += "\"\(escapedKey)\":\"\(escapedVal)\""
            if i < headers.count - 1 { headersJSON += "," }
        }
        headersJSON += "}"
        
        var fetchOpts = "method:'\(method)',headers:\(headersJSON)"
        if let body = body {
            let escapedBody = body.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            fetchOpts += ",body:'\(escapedBody)'"
        }
        
        let js = """
        (async function() {
            try {
                var resp = await fetch('\(url)', {\(fetchOpts)});
                var body = await resp.text();
                var headers = {};
                resp.headers.forEach(function(v, k) { headers[k] = v; });
                window.webkit.messageHandlers.bridgeResponse.postMessage({
                    id: '\(requestId)',
                    success: true,
                    status: resp.status,
                    statusText: resp.statusText,
                    headers: headers,
                    body: body
                });
            } catch(e) {
                window.webkit.messageHandlers.bridgeResponse.postMessage({
                    id: '\(requestId)',
                    success: false,
                    error: e.message || String(e)
                });
            }
        })();
        """
        
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                self?.pendingRequests[requestId] = { result in
                    continuation.resume(with: result)
                }
            }
            
            webView.evaluateJavaScript(js) { _, error in
                if let error = error {
                    self.queue.async { [weak self] in
                        self?.pendingRequests.removeValue(forKey: requestId)
                        continuation.resume(throwing: error)
                    }
                }
            }
            
            // 超时
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.queue.async {
                    if let cb = self?.pendingRequests.removeValue(forKey: requestId) {
                        cb(.failure(BridgeError.timeout))
                    }
                }
            }
        }
    }
    
    enum BridgeError: Error {
        case notReady
        case timeout
        case fetchFailed(String)
        case invalidResponse
    }
}

// 改为 `@MainActor` 包装 —— 原来不需要，WKWebView 必须在主线程调用
extension BaiduWebViewBridge: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let id = dict["id"] as? String else { return }
        
        queue.async { [weak self] in
            guard let cb = self?.pendingRequests.removeValue(forKey: id) else { return }
            
            if let success = dict["success"] as? Bool, success,
               let body = dict["body"] as? String {
                let data = Data(body.utf8)
                let status = dict["status"] as? Int ?? 200
                cb(.success(data))
            } else if let error = dict["error"] as? String {
                cb(.failure(BridgeError.fetchFailed(error)))
            } else {
                cb(.failure(BridgeError.invalidResponse))
            }
        }
    }
}
