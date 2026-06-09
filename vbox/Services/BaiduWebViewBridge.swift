import Foundation
import WebKit

/// 用 WKWebView JS XMLHttpRequest 发 HTTP 请求，绕开 URLSession TLS 指纹
/// 百度风控对 Safari/WebView 的 JA3 指纹更宽容
class BaiduWebViewBridge: NSObject {
    static let shared = BaiduWebViewBridge()
    
    private var webView: WKWebView!
    private var pendingRequests: [String: (Result<(Data, HTTPURLResponse?), Error>) -> Void] = [:]
    private let queue = DispatchQueue(label: "baidu.webview.bridge")
    private var requestIdCounter = 0
    
    private var readyContinuations: [CheckedContinuation<Void, Never>] = []
    private var ready = false
    
    private override init() {
        super.init()
        DispatchQueue.main.sync {
            self.setupWebView()
        }
    }
    
    /// 等待 WebView JS 环境就绪
    private func waitReady() async {
        if ready { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                if self?.ready == true {
                    continuation.resume()
                } else {
                    self?.readyContinuations.append(continuation)
                }
            }
        }
    }
    
    private func setupWebView() {
        let config = WKWebViewConfiguration()
        let userController = config.userContentController
        userController.add(self, name: "bridgeResponse")
        
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"
        wv.navigationDelegate = self
        
        // 加载空白页，完成后通知就绪
        wv.loadHTMLString("<html><body></body></html>", baseURL: URL(string: "https://pan.baidu.com"))
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            window.addSubview(wv)
        }
        
        self.webView = wv
    }
    
    /// 通过 WebView JS XMLHttpRequest 发请求（不用 async/await，避免 evaluateJavaScript 不支持）
    func request(
        url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: String? = nil,
        timeout: TimeInterval = 15
    ) async throws -> (data: Data, response: HTTPURLResponse?) {
        
        await waitReady()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse?), Error>) in
            guard let wv = self.webView else {
                continuation.resume(throwing: BridgeError.notReady)
                return
            }
            
            self.requestIdCounter += 1
            let requestId = "req_\(self.requestIdCounter)"
            
            // 构造 JS 回调 — 用 XMLHttpRequest（同步回调，不依赖 async/await）
            var jsHeaders = "{"
            var first = true
            for (key, val) in headers {
                let ek = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let ev = val.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                if !first { jsHeaders += "," }
                jsHeaders += "\"\(ek)\":\"\(ev)\""
                first = false
            }
            jsHeaders += "}"
            
            let jsBody = body?.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") ?? ""
            
            let js = """
            (function() {
                var xhr = new XMLHttpRequest();
                xhr.open('\(method)', '\(url)', true);
                var hdrs = \(jsHeaders);
                for (var k in hdrs) { xhr.setRequestHeader(k, hdrs[k]); }
                xhr.timeout = \(Int(timeout * 1000));
                xhr.onload = function() {
                    var allHeaders = {};
                    var raw = xhr.getAllResponseHeaders().split('\\r\\n');
                    for (var i = 0; i < raw.length; i++) {
                        var idx = raw[i].indexOf(': ');
                        if (idx > 0) allHeaders[raw[i].substring(0, idx)] = raw[i].substring(idx + 2);
                    }
                    window.webkit.messageHandlers.bridgeResponse.postMessage({
                        id: '\(requestId)',
                        success: true,
                        status: xhr.status,
                        headers: allHeaders,
                        body: xhr.responseText
                    });
                };
                xhr.onerror = function() {
                    window.webkit.messageHandlers.bridgeResponse.postMessage({
                        id: '\(requestId)',
                        success: false,
                        error: 'xhr.onerror'
                    });
                };
                xhr.ontimeout = function() {
                    window.webkit.messageHandlers.bridgeResponse.postMessage({
                        id: '\(requestId)',
                        success: false,
                        error: 'timeout'
                    });
                };
                xhr.send('\(jsBody)');
            })();
            """
            
            self.queue.async { [weak self] in
                self?.pendingRequests[requestId] = { result in
                    continuation.resume(with: result)
                }
            }
            
            // 超时兜底
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2) { [weak self] in
                self?.queue.async {
                    if let cb = self?.pendingRequests.removeValue(forKey: requestId) {
                        cb(.failure(BridgeError.timeout))
                    }
                }
            }
            
            DispatchQueue.main.async {
                wv.evaluateJavaScript(js) { _, error in
                    if let error = error {
                        self.queue.async { [weak self] in
                            self?.pendingRequests.removeValue(forKey: requestId)
                            continuation.resume(throwing: error)
                        }
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

// MARK: - WKNavigationDelegate
extension BaiduWebViewBridge: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        queue.async { [weak self] in
            self?.ready = true
            let conts = self?.readyContinuations ?? []
            self?.readyContinuations = []
            for c in conts { c.resume() }
        }
    }
}

// MARK: - WKScriptMessageHandler
extension BaiduWebViewBridge: WKScriptMessageHandlerWithReply {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, completionHandler: @escaping () -> Void) {
        guard let dict = message.body as? [String: Any],
              let id = dict["id"] as? String else { completionHandler(); return }
        
        queue.async { [weak self] in
            guard let cb = self?.pendingRequests.removeValue(forKey: id) else { completionHandler(); return }
            
            if let success = dict["success"] as? Bool, success,
               let body = dict["body"] as? String {
                let data = Data(body.utf8)
                let statusCode = dict["status"] as? Int ?? 200
                var response: HTTPURLResponse? = nil
                if let url = URL(string: "https://pan.baidu.com") {
                    response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: dict["headers"] as? [String: String])
                }
                cb(.success((data, response)))
            } else if let error = dict["error"] as? String {
                cb(.failure(BridgeError.fetchFailed(error)))
            } else {
                cb(.failure(BridgeError.invalidResponse))
            }
            completionHandler()
        }
    }
}
