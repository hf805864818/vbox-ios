import Foundation
import WebKit
import UIKit

/// 用 WKWebView JS XMLHttpRequest 发 HTTP 请求，绕开 URLSession TLS 指纹
/// 百度风控对 Safari/WebView 的 JA3 指纹更宽容
class BaiduWebViewBridge: NSObject {
    static let shared = BaiduWebViewBridge()
    
    private var webView: WKWebView!
    private var pendingRequests: [String: (Result<(Data, HTTPURLResponse?), Error>) -> Void] = [:]
    private var pendingNavigations: [String: (Result<Void, Error>) -> Void] = [:]
    private let queue = DispatchQueue(label: "baidu.webview.bridge")
    private var requestIdCounter = 0
    
    private var readyContinuations: [CheckedContinuation<Void, Never>] = []
    private var ready = false
    
    private override init() {
        super.init()
        // WKWebView 必须在主线程创建，使用 async 避免后台线程调用时死锁
        if Thread.isMainThread {
            self.setupWebView()
        } else {
            DispatchQueue.main.async {
                self.setupWebView()
            }
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
        config.websiteDataStore = .default()
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

    /// 注入账号 Cookie 到 WKWebView 的 CookieJar，让后续 disk/main 和 XHR 具备真实网页登录态。
    func seedCookies(_ cookie: String) async {
        let cookies = makeHTTPCookies(from: cookie)
        guard !cookies.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                let store = WKWebsiteDataStore.default().httpCookieStore
                let group = DispatchGroup()
                for item in cookies {
                    group.enter()
                    store.setCookie(item) {
                        group.leave()
                    }
                }
                group.notify(queue: .main) {
                    continuation.resume()
                }
            }
        }
    }

    /// 清理 WKWebView 中残留的百度 Cookie。切换百度账号后如果不清理，WebView 可能继续带旧账号
    /// BDUSS/STOKEN，导致抓到的 bdstoken 与当前扫码账号不匹配，私域接口返回 errno=-6。
    func clearBaiduCookies() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                let store = WKWebsiteDataStore.default().httpCookieStore
                store.getAllCookies { cookies in
                    let targets = cookies.filter { cookie in
                        let domain = cookie.domain.lowercased()
                        return domain.contains("baidu.com") || domain.contains("pcs.baidu.com")
                    }
                    guard !targets.isEmpty else {
                        continuation.resume()
                        return
                    }
                    let group = DispatchGroup()
                    for cookie in targets {
                        group.enter()
                        store.delete(cookie) {
                            group.leave()
                        }
                    }
                    group.notify(queue: .main) {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// 读取 WebView CookieJar 中的百度 Cookie。
    func currentCookieString() async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.main.async {
                WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                    let filtered = cookies.filter { cookie in
                        let domain = cookie.domain.lowercased()
                        return domain.contains("baidu.com") || domain.contains("pcs.baidu.com")
                    }
                    continuation.resume(returning: CloudDriveAuthManager.cookieString(from: filtered))
                }
            }
        }
    }

    /// 使用真实 WebView 导航加载页面，并从 HTML/JS/CookieJar 中提取 bdstoken。
    func loadPanPageForBdstoken(cookie: String, timeout: TimeInterval = 18, resetCookies: Bool = true) async throws -> (html: String, cookie: String, bdstoken: String?) {
        if resetCookies {
            await clearBaiduCookies()
        }
        await seedCookies(cookie)
        try await load(url: "https://pan.baidu.com/disk/main", timeout: timeout)
        let html = try await evaluateString("""
        (function() {
            return document.documentElement ? document.documentElement.outerHTML : document.body.innerHTML;
        })();
        """)
        let token = try await evaluateString("""
        (function() {
            try {
                if (window.locals && window.locals.get && window.locals.get('bdstoken')) return window.locals.get('bdstoken');
                if (window.yunData && window.yunData.MYBDSTOKEN) return window.yunData.MYBDSTOKEN;
                if (window.context && window.context.bdstoken) return window.context.bdstoken;
            } catch (e) {}
            var html = document.documentElement ? document.documentElement.outerHTML : '';
            var m = html.match(/[\"']bdstoken[\"']\\s*[:=]\\s*[\"']([^\"']+)[\"']/i) || html.match(/bdstoken=([A-Za-z0-9_\\-%.]+)/i);
            return m ? m[1] : '';
        })();
        """)
        let jarCookie = await currentCookieString()
        let mergedCookie = mergeCookieStrings([cookie, jarCookie])
        return (html, mergedCookie, token.isEmpty ? nil : token)
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

    private func load(url: String, timeout: TimeInterval) async throws {
        await waitReady()
        guard let target = URL(string: url) else { throw BridgeError.invalidResponse }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let wv = self.webView else {
                continuation.resume(throwing: BridgeError.notReady)
                return
            }
            self.requestIdCounter += 1
            let requestId = "nav_\(self.requestIdCounter)"
            queue.async { [weak self] in
                self?.pendingNavigations[requestId] = { result in
                    continuation.resume(with: result)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2) { [weak self] in
                self?.queue.async {
                    if let cb = self?.pendingNavigations.removeValue(forKey: requestId) {
                        cb(.failure(BridgeError.timeout))
                    }
                }
            }
            DispatchQueue.main.async {
                var request = URLRequest(url: target)
                request.timeoutInterval = timeout
                wv.load(request)
            }
        }
    }

    private func evaluateString(_ javascript: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            guard let wv = self.webView else {
                continuation.resume(throwing: BridgeError.notReady)
                return
            }
            DispatchQueue.main.async {
                wv.evaluateJavaScript(javascript) { value, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if let text = value as? String {
                        continuation.resume(returning: text)
                    } else if let number = value as? NSNumber {
                        continuation.resume(returning: number.stringValue)
                    } else {
                        continuation.resume(returning: "")
                    }
                }
            }
        }
    }

    private func makeHTTPCookies(from cookie: String) -> [HTTPCookie] {
        let domains = ["pan.baidu.com", ".baidu.com", "passport.baidu.com", "d.pcs.baidu.com"]
        var output: [HTTPCookie] = []
        var seen = Set<String>()
        for part in cookie.split(separator: ";") {
            let item = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = item.firstIndex(of: "=") else { continue }
            let name = String(item[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(item[item.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { continue }
            for domain in domains {
                let key = "\(domain)|\(name)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                if let httpCookie = HTTPCookie(properties: [
                    .domain: domain,
                    .path: "/",
                    .name: name,
                    .value: value,
                    .secure: "TRUE",
                    .expires: Date(timeIntervalSinceNow: 30 * 24 * 3600)
                ]) {
                    output.append(httpCookie)
                }
            }
        }
        return output
    }

    private func mergeCookieStrings(_ cookies: [String]) -> String {
        var values: [String: (name: String, value: String)] = [:]
        var order: [String] = []
        for cookie in cookies where !cookie.isEmpty {
            for part in cookie.split(separator: ";") {
                let item = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let eq = item.firstIndex(of: "=") else { continue }
                let name = String(item[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(item[item.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !value.isEmpty else { continue }
                let key = name.lowercased()
                if values[key] == nil { order.append(key) }
                values[key] = (name, value)
            }
        }
        return order.compactMap { key in
            guard let item = values[key] else { return nil }
            return "\(item.name)=\(item.value)"
        }.joined(separator: "; ")
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
            guard let self = self else { return }
            let navigationCallbacks = Array(self.pendingNavigations.values)
            self.pendingNavigations.removeAll()
            for cb in navigationCallbacks {
                cb(.success(()))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishPendingNavigations(with: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishPendingNavigations(with: error)
    }

    private func finishPendingNavigations(with error: Error) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let callbacks = Array(self.pendingNavigations.values)
            self.pendingNavigations.removeAll()
            for cb in callbacks {
                cb(.failure(error))
            }
        }
    }
}
// MARK: - WKScriptMessageHandler
extension BaiduWebViewBridge: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let id = dict["id"] as? String else { return }
        
        queue.async { [weak self] in
            guard let cb = self?.pendingRequests.removeValue(forKey: id) else { return }
            
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
        }
    }
}
