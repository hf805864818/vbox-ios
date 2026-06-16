import SwiftUI
import WebKit

// MARK: - Token获取WebView
struct TokenWebView: UIViewRepresentable {
    let onTokenDetected: (String, String) -> Void  // (type, tokenValue)
    @Binding var isLoading: Bool
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userScript = WKUserScript(
            source: """
            // 每2秒检查页面中是否有token信息
            setInterval(function() {
                // 检查cookie-butler页面常见的token显示格式
                var bodyText = document.body ? document.body.innerText : '';
                
                // 尝试匹配常见token格式
                var patterns = [
                    /(阿里云盘|阿里).*?[：:]([a-zA-Z0-9]{20,})/i,
                    /(夸克).*?[：:]([a-zA-Z0-9]{20,})/i,
                    /(115).*?[：:]([a-zA-Z0-9]{20,})/i,
                    /(百度).*?[：:]([a-zA-Z0-9]{20,})/i,
                    /(UC).*?[：:]([a-zA-Z0-9]{20,})/i,
                    /(RefreshToken|token).*?[：:]([a-zA-Z0-9]{20,})/i,
                    /Cookie.*?[：:]([a-zA-Z0-9%]{20,})/i,
                    /BDUSS.*?[：:]([a-zA-Z0-9]{20,})/i,
                ];
                
                for (var i = 0; i < patterns.length; i++) {
                    var match = bodyText.match(patterns[i]);
                    if (match) {
                        window.webkit.messageHandlers.tokenHandler.postMessage({
                            type: match[1].trim(),
                            value: match[2].trim()
                        });
                        return;
                    }
                }
                
                // 检查页面URL是否包含token参数
                var url = window.location.href;
                var urlMatch = url.match(/token=([^&]+)/);
                if (urlMatch) {
                    window.webkit.messageHandlers.tokenHandler.postMessage({
                        type: 'url_token',
                        value: decodeURIComponent(urlMatch[1])
                    });
                }
            }, 2000);
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        
        config.userContentController.addUserScript(userScript)
        config.userContentController.add(context.coordinator, name: "tokenHandler")
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15"
        
        if let url = URL(string: "https://cookie-butler.douer.me") {
            webView.load(URLRequest(url: url))
        }
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {}
    
    class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: TokenWebView
        
        init(_ parent: TokenWebView) {
            self.parent = parent
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "tokenHandler", let dict = message.body as? [String: String],
               let value = dict["value"], !value.isEmpty {
                let type = dict["type"] ?? ""
                // 映射中文网盘名到DriveType
                let mappedType: String
                if type.contains("阿里") || type.contains("ali") || type == "url_token" {
                    mappedType = "ali"
                } else if type.contains("夸克") || type.contains("quark") {
                    mappedType = "quark"
                } else if type.contains("115") || type.contains("one15") {
                    mappedType = "115"
                } else if type.contains("百度") || type.contains("baidu") {
                    mappedType = "baidu"
                } else if type.contains("UC") || type.contains("uc") {
                    mappedType = "uc"
                } else {
                    mappedType = "ali"
                }
                parent.onTokenDetected(mappedType, value)
            }
            parent.isLoading = false
        }
    }
}

// MARK: - 获取Token弹窗
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
                TokenWebView(onTokenDetected: { type, value in
                    detectedToken = (type, value)
                    // 自动添加到网盘管理器
                    if !autoAdded {
                        autoAdded = true
                        if let driveType = CloudDriveManager.DriveType(rawValue: type) {
                            cloudDriveManager.addToken(type: driveType, name: driveType.displayName, value: value)
                        }
                    }
                    // 调用回调函数自动填入
                    onTokenDetected?(type, value)
                }, isLoading: $isLoading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                if detectedToken == nil && isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在加载页面...")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                        Text("请扫码登录后，页面会自动检测Token并添加")
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
                        Text("类型: \(CloudDriveManager.DriveType(rawValue: token.type)?.displayName ?? token.type)")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                        Text("已自动添加到网盘列表")
                            .font(.system(size: 13))
                            .foregroundColor(.blue)
                    }
                    .padding(.bottom, 40)
                    .onAppear {
                        // 1.5秒后自动关闭
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

// MARK: - 统一网盘 WebView 授权兜底
struct CloudDriveWebAuthView: View {
    @Environment(\.dismiss) private var dismiss
    let driveType: CloudDriveManager.DriveType
    @State private var isLoading = true
    @State private var statusText = "请在官方页面完成登录或验证"
    @State private var saved = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                CloudDriveCookieWebView(
                    driveType: driveType,
                    isLoading: $isLoading,
                    statusText: $statusText,
                    onCredentialSaved: {
                        saved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            dismiss()
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 8) {
                    if isLoading {
                        ProgressView()
                    }
                    Text(saved ? "授权已保存" : statusText)
                        .font(.system(size: 13, weight: saved ? .semibold : .regular))
                        .foregroundColor(saved ? .green : .gray)
                        .multilineTextAlignment(.center)
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(Color.white)
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
}

struct CloudDriveCookieWebView: UIViewRepresentable {
    let driveType: CloudDriveManager.DriveType
    @Binding var isLoading: Bool
    @Binding var statusText: String
    var onCredentialSaved: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = userAgent

        injectExistingCookies(into: webView) {
            webView.load(URLRequest(url: startURL))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    private var startURL: URL {
        switch driveType {
        case .baidu:
            return URL(string: "https://pan.baidu.com/")!
        case .ali:
            // 阿里云盘开放平台 OAuth client_id 已失效，原生扫码不可用。
            // 使用 AList 官方工具页作为兜底入口，用户扫码后页面会展示 refresh_token。
            return URL(string: "https://alistgo.com/tool/aliyundrive/request.html")!
        case .quark:
            return URL(string: "https://pan.quark.cn/")!
        case .uc:
            return URL(string: "https://drive.uc.cn/")!
        case .one15:
            return URL(string: "https://115.com/")!
        }
    }

    private var userAgent: String {
        switch driveType {
        case .quark:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.54 Safari/537.36"
        case .uc:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/1.8.5 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/ucpan_other_ch"
        case .one15:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) 115Chrome/33.0.0.0 Safari/537.36"
        default:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15"
        }
    }

    private var cookieHosts: [String] {
        switch driveType {
        case .baidu: return ["pan.baidu.com", "passport.baidu.com", ".baidu.com"]
        case .ali: return ["aliyundrive.com", "alipan.com", ".aliyundrive.com", ".alipan.com"]
        case .quark: return ["pan.quark.cn", "drive-pc.quark.cn", ".quark.cn"]
        case .uc: return ["drive.uc.cn", "pc-api.uc.cn", ".uc.cn"]
        case .one15: return ["115.com", ".115.com"]
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
                let kv = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let eq = kv.firstIndex(of: "=") else { continue }
                let name = String(kv[..<eq])
                let value = String(kv[kv.index(after: eq)...])
                guard !name.isEmpty, !value.isEmpty else { continue }
                var properties: [HTTPCookiePropertyKey: Any] = [
                    .domain: host,
                    .path: "/",
                    .name: name,
                    .value: value,
                    .secure: "TRUE",
                    .expires: Date(timeIntervalSinceNow: 30 * 24 * 3600)
                ]
                if host.hasPrefix(".") { properties[.domain] = host }
                guard let httpCookie = HTTPCookie(properties: properties) else { continue }
                group.enter()
                store.setCookie(httpCookie) { group.leave() }
            }
        }
        group.notify(queue: .main) { completion() }
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: CloudDriveCookieWebView
        private var saved = false

        init(_ parent: CloudDriveCookieWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            inspectAliRefreshTokenIfNeeded(webView: webView)
            inspect(webView: webView)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if parent.driveType == .ali,
               let url = navigationAction.request.url,
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
               !code.isEmpty {
                saveAliCode(code)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        private func inspect(webView: WKWebView) {
            guard !saved else { return }
            if parent.driveType == .ali {
                // 阿里云盘：优先尝试从页面文本提取 refresh_token，同时提示用户
                inspectAliRefreshTokenIfNeeded(webView: webView)
                DispatchQueue.main.async {
                    if !self.saved {
                        self.parent.statusText = "请在页面完成扫码授权；出现 refresh_token 后会自动保存，也可复制后手动粘贴到输入框。"
                    }
                }
                return
            }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let filtered = cookies.filter { cookie in
                    self.parent.cookieHosts.contains { host in
                        if host.hasPrefix(".") { return cookie.domain.hasSuffix(String(host.dropFirst())) }
                        return cookie.domain == host || cookie.domain.hasSuffix(".\(host)")
                    }
                }
                let cookieString = CloudDriveAuthManager.cookieString(from: filtered)
                guard self.isEnough(cookieString) else {
                    DispatchQueue.main.async {
                        self.parent.statusText = "已打开官方页面，请完成登录/扫码后等待自动保存"
                    }
                    return
                }
                DispatchQueue.main.async {
                    let didSave = CloudDriveAuthManager.shared.saveWebViewCookie(type: self.parent.driveType, cookie: cookieString)
                    guard didSave else {
                        self.parent.statusText = "\(self.parent.driveType.displayName) 已登录页面，但未捕获到可播放所需的 BDUSS/STOKEN"
                        return
                    }
                    self.saved = true
                    self.parent.statusText = "已保存 \(self.parent.driveType.displayName) 授权"
                    self.parent.onCredentialSaved()
                }
            }
        }

        private func saveAliCode(_ code: String) {
            guard !saved else { return }
            saved = true
            parent.statusText = "已捕获阿里 OAuth code，正在换取 refresh_token..."
            Task {
                do {
                    try await CloudDriveAuthManager.shared.exchangeAliOAuthCode(code)
                    await MainActor.run {
                        self.parent.statusText = "阿里 OAuth 授权成功"
                        self.parent.onCredentialSaved()
                    }
                } catch {
                    await MainActor.run {
                        self.saved = false
                        self.parent.statusText = "阿里 OAuth 换 token 失败：\(error.localizedDescription)"
                    }
                }
            }
        }

        private func inspectAliRefreshTokenIfNeeded(webView: WKWebView) {
            guard parent.driveType == .ali, !saved else { return }
            // 尝试从页面文本提取 refresh_token
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] result, _ in
                guard let self,
                      let text = result as? String,
                      let token = self.extractAliRefreshToken(from: text) else { return }
                self.saveAliRefreshToken(token)
            }
            // 同时尝试从页面 input/textarea 元素中提取（AList 工具页可能把 token 放在表单里）
            let js = """
                (function() {
                    var inputs = document.querySelectorAll('input, textarea');
                    for (var i = 0; i < inputs.length; i++) {
                        var val = inputs[i].value || inputs[i].textContent || '';
                        if (val.length > 100 && val.indexOf('ey') === 0) return val;
                    }
                    return '';
                })();
                """
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self,
                      let text = result as? String,
                      !text.isEmpty else { return }
                self.saveAliRefreshToken(text)
            }
        }

        private func saveAliRefreshToken(_ token: String) {
            guard !saved else { return }
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 20 else { return }
            DispatchQueue.main.async {
                CloudDriveAuthManager.shared.saveManualCredential(type: .ali, name: "阿里网页登录", value: trimmed)
                self.saved = true
                self.parent.statusText = "已自动保存阿里 refresh_token"
                self.parent.onCredentialSaved()
            }
        }

        private func extractAliRefreshToken(from text: String) -> String? {
            let patterns = [
                #"refresh_token["'\s:=]+([A-Za-z0-9._\-]+)"#,
                #"Refresh Token\s*[:：]\s*([A-Za-z0-9._\-]+)"#,
                #"刷新令牌\s*[:：]\s*([A-Za-z0-9._\-]+)"#,
                #"token["'\s:=]+(ey[A-Za-z0-9._\-]+)"#,
                #"(eyJ[A-Za-z0-9._\-]{100,})"#
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
                return lower.contains("__pus=") || lower.contains("__kps=") || lower.contains("__puus=")
            case .uc:
                return lower.contains("uc") || lower.contains("__pus=") || lower.contains("__kps=")
            case .one15:
                return lower.contains("uid=") || lower.contains("cid=") || lower.contains("seid=")
            }
        }
    }
}
