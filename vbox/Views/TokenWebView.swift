import SwiftUI
import WebKit
import UIKit

struct TokenWebView: View {
    let driveType: CloudDriveManager.DriveType
    @Binding var token: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            TokenWebViewRepresentable(driveType: driveType, token: $token)
                .navigationTitle("获取 \(driveType.displayName) Token")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}

struct TokenWebViewRepresentable: UIViewRepresentable {
    let driveType: CloudDriveManager.DriveType
    @Binding var token: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent = userAgent
        context.coordinator.webView = webView

        // 注入已有 Cookie（如果有）
        injectExistingCookies(into: webView) {
            webView.load(URLRequest(url: startURL))
        }

        // 启动定时轮询检测 Cookie（应对 AJAX 登录不刷新页面的情况）
        context.coordinator.startCookiePolling()

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    private var startURL: URL {
        switch driveType {
        case .baidu:
            return URL(string: "https://pan.baidu.com/")!
        case .ali:
            // 阿里云盘：优先使用原生 Passport 扫码，此 WebView 作为兜底。
            // 使用 AList 官方工具页，用户扫码后页面会展示 refresh_token，也可使用 alist.nn.ci 的 OAuth 回调。
            return URL(string: "https://alist.nn.ci/tool/aliyundrive/request")!
        case .quark:
            return URL(string: "https://pan.quark.cn/")!
        case .uc:
            return URL(string: "https://drive.uc.cn/")!
        case .one15:
            // 115网盘登录页面（强制使用扫码/账密登录入口）
            return URL(string: "https://115.com/?ct=login")!
        case .pan123:
            // 123云盘登录页面，优先使用移动端登录页
            return URL(string: "https://www.123pan.com/login")!
        case .pan139:
            return URL(string: "https://yun.139.com/")!
        case .pan189:
            return URL(string: "https://cloud.189.cn/")!
        }
    }

    private var userAgent: String {
        switch driveType {
        case .quark:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.54 Safari/537.36"
        case .uc:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/1.8.5 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/ucpan_other_ch"
        case .baidu:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        case .ali:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        case .one15:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 115Browser/27.0.3.4"
        case .pan123:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        case .pan139:
            return "Mozilla/5.0 (Linux; Android 10; SM-G960U) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
        case .pan189:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        }
    }

    private var cookieHosts: [String] {
        switch driveType {
        case .baidu: return ["pan.baidu.com", "passport.baidu.com", ".baidu.com"]
        case .ali: return ["aliyundrive.com", "alipan.com", ".aliyundrive.com", ".alipan.com", "passport.alipan.com", "auth.alipan.com", "api.alipan.com", "openapi.alipan.com"]
        case .quark: return ["pan.quark.cn", "drive-pc.quark.cn", ".quark.cn"]
        case .uc: return ["drive.uc.cn", "pc-api.uc.cn", ".uc.cn"]
        case .one15: return ["115.com", ".115.com"]
        case .pan123: return ["www.123pan.com", ".123pan.com", "123684.com", ".123684.com", "api.123pan.com", "openapi.123pan.com"]
        case .pan139: return ["yun.139.com", ".139.com", "caiyun.139.com"]
        case .pan189: return ["cloud.189.cn", ".189.cn", "api.189.cn"]
        }
    }

    private func injectExistingCookies(into webView: WKWebView, completion: @escaping () -> Void) {
        guard let credential = CloudDriveAuthManager.shared.credential(for: driveType),
              let cookie = credential.cookie,
              !cookie.isEmpty else {
            completion()
            return
        }

        let store = webView.configuration.websiteDataStore.httpCookieStore
        let pieces = cookie.components(separatedBy: ";")
        let group = DispatchGroup()
        for host in cookieHosts {
            for piece in pieces {
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let eqIndex = trimmed.firstIndex(of: "=") else { continue }
                let name = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                var properties: [HTTPCookiePropertyKey: Any] = [
                    .name: name,
                    .value: value,
                    .domain: host,
                    .path: "/"
                ]
                if let cookie = HTTPCookie(properties: properties) {
                    group.enter()
                    store.setCookie(cookie) { group.leave() }
                }
            }
        }
        group.notify(queue: .main) { completion() }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: TokenWebViewRepresentable
        weak var webView: WKWebView?
        private var cookieTimer: Timer?
        private var hasDetected = false

        init(_ parent: TokenWebViewRepresentable) {
            self.parent = parent
        }

        deinit {
            cookieTimer?.invalidate()
        }

        // MARK: - Cookie 轮询（应对 AJAX 登录不触发 didFinish 的情况）
        func startCookiePolling() {
            cookieTimer?.invalidate()
            cookieTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                guard let self = self, !self.hasDetected, let webView = self.webView else {
                    self?.cookieTimer?.invalidate()
                    return
                }
                self.extractToken(from: webView)
            }
        }

        // MARK: - WKNavigationDelegate
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            extractToken(from: webView)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
        }

        // MARK: - WKUIDelegate：处理 window.open / alert / confirm / prompt
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // UC 等网页登录可能通过 window.open 打开新窗口，直接在当前页加载
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            guard let rootVC = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else {
                completionHandler()
                return
            }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler() })
            rootVC.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            guard let rootVC = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else {
                completionHandler(false)
                return
            }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
            rootVC.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            guard let rootVC = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else {
                completionHandler(nil)
                return
            }
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
            rootVC.present(alert, animated: true)
        }

        // MARK: - Token / Cookie 提取
        private func extractToken(from webView: WKWebView) {
            guard !hasDetected else { return }
            let store = webView.configuration.websiteDataStore.httpCookieStore
            store.getAllCookies { [weak self] cookies in
                guard let self = self else { return }
                var cookieString = ""
                for cookie in cookies {
                    cookieString += "\(cookie.name)=\(cookie.value); "
                }

                // 尝试从页面内容提取 token
                webView.evaluateJavaScript("document.body.innerText") { result, error in
                    if let text = result as? String {
                        if let token = self.extractTokenFromText(text) {
                            DispatchQueue.main.async {
                                self.parent.token = token
                                self.hasDetected = true
                                self.cookieTimer?.invalidate()
                            }
                        }
                    }
                }

                // 如果 cookie 足够，也保存 cookie
                if self.isEnough(cookieString) {
                    DispatchQueue.main.async {
                        self.parent.token = cookieString.trimmingCharacters(in: .whitespaces)
                        self.hasDetected = true
                        self.cookieTimer?.invalidate()
                    }
                }
            }
        }

        private func extractTokenFromText(_ text: String) -> String? {
            let patterns = [
                "refresh_token[:：]\\s*([a-zA-Z0-9_-]+)",
                "token[:：]\\s*([a-zA-Z0-9_-]+)",
                "access_token[:：]\\s*([a-zA-Z0-9_-]+)"
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: text) else { continue }
                let token = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if token.count > 20 { return token }
            }
            return nil
        }

        private func isEnough(_ cookie: String) -> Bool {
            let lower = cookie.lowercased()
            switch parent.driveType {
            case .baidu:
                return lower.contains("bduss=") && lower.contains("stoken=")
            case .ali:
                return lower.contains("token") || lower.contains("login") || lower.contains("aliyun")
            case .quark:
                return lower.contains("__puus=") || (lower.contains("__pus=") && lower.contains("__kps="))
            case .uc:
                return lower.contains("__pus=") || lower.contains("__kps=") || lower.contains("__uid=") || (lower.contains("uc") && lower.count > 50)
            case .one15:
                return lower.contains("uid=") || lower.contains("cid=") || lower.contains("seid=") ||
                       lower.contains("user_id") || lower.contains("115") || lower.contains("passport")
            case .pan123:
                return lower.contains("authorization") || lower.contains("token") || lower.contains("auth") ||
                       lower.contains("session") || lower.contains("login") || lower.contains("userid") ||
                       lower.contains("uid=") || lower.contains("passport") || lower.contains("pan123") ||
                       lower.contains("123pan") || lower.contains("123_") || lower.contains("__uid")
            case .pan139:
                return lower.contains("ssotoken") || lower.contains("sso_token") || lower.contains("mcloud") || lower.contains("sessionid")
            case .pan189:
                return lower.contains("ssotoken") || lower.contains("session") || lower.contains("cookie")
            }
        }
    }
}

// MARK: - TokenFetcherView（通用网盘Token抓取页面）
struct TokenFetcherView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var cloudDriveManager: CloudDriveManager
    var onTokenDetected: ((String, String) -> Void)? = nil
    @State private var detectedToken: (type: String, value: String)? = nil
    @State private var isLoading = true
    @State private var autoAdded = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                TokenWebViewRepresentable(driveType: .ali, token: .constant(""))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { isLoading = false }

                if detectedToken == nil {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在加载页面...")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                        Text("请扫码登录后，页面会自动检测Token")
                            .font(.system(size: 12))
                            .foregroundColor(.gray.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .padding(.bottom, 40)
                } else if let token = detectedToken {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.green)
                        Text("成功获取 Token")
                            .font(.system(size: 16, weight: .semibold))
                        Text("已自动添加到网盘列表")
                            .font(.system(size: 13))
                            .foregroundColor(.blue)
                    }
                    .padding(.bottom, 40)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("获取Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Text("关闭").foregroundColor(Color(hex: "E11D48"))
                    }
                }
            }
        }
    }
}

// MARK: - CloudDriveWebAuthView（网盘授权页面）
struct CloudDriveWebAuthView: View {
    @Environment(\.dismiss) private var dismiss
    let driveType: CloudDriveManager.DriveType
    @State private var isLoading = true
    @State private var statusText = "请在官方页面完成登录或验证"
    @State private var saved = false
    @State private var detectedToken: String = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                TokenWebView(driveType: driveType, token: $detectedToken)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { isLoading = false }
                    .onChange(of: detectedToken) { newToken in
                        guard !newToken.isEmpty, !saved else { return }
                        saveDetectedCredential(token: newToken)
                    }

                VStack(spacing: 8) {
                    if isLoading && !saved {
                        ProgressView()
                    }
                    Text(saved ? "授权已保存" : statusText)
                        .font(.system(size: 13, weight: saved ? .semibold : .regular))
                        .foregroundColor(saved ? .green : .gray)
                        .multilineTextAlignment(.center)
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(Color(UIColor.systemBackground))
            }
            .navigationTitle("\(driveType.displayName) 授权")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(Color(hex: "E11D48"))
                }
            }
        }
    }

    private func saveDetectedCredential(token: String) {
        let credential = CloudDriveCredential(
            driveType: driveType.rawValue,
            authType: .webView,
            accessToken: nil,
            refreshToken: nil,
            cookie: token,
            driveId: nil,
            userId: nil,
            userName: nil,
            avatar: nil,
            expiresAt: nil,
            updatedAt: Date(),
            lastCheckedAt: Date(),
            state: .valid,
            statusMessage: "WebView 登录成功",
            extra: [:]
        )
        CloudDriveAuthManager.shared.saveCredential(credential)
        saved = true
        statusText = "授权已保存"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            dismiss()
        }
    }
}
