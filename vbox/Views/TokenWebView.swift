import SwiftUI
import WebKit

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
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent = userAgent
        context.coordinator.webView = webView

        // 注入已有 Cookie（如果有）
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
        case .pan123:
            return URL(string: "https://www.123pan.com/")!
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
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15"
        case .one15:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) 115Chrome/33.0.0.0 Safari/537.36"
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
        case .ali: return ["aliyundrive.com", "alipan.com", ".aliyundrive.com", ".alipan.com"]
        case .quark: return ["pan.quark.cn", "drive-pc.quark.cn", ".quark.cn"]
        case .uc: return ["drive.uc.cn", "pc-api.uc.cn", ".uc.cn"]
        case .one15: return ["115.com", ".115.com"]
        case .pan123: return ["123pan.com", ".123pan.com", "123684.com"]
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

        init(_ parent: TokenWebViewRepresentable) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 页面加载完成后，尝试提取 token
            extractToken(from: webView)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // 允许所有导航
            decisionHandler(.allow)
        }

        private func extractToken(from webView: WKWebView) {
            let store = webView.configuration.websiteDataStore.httpCookieStore
            store.getAllCookies { cookies in
                var cookieString = ""
                for cookie in cookies {
                    cookieString += "\(cookie.name)=\(cookie.value); "
                }
                
                // 尝试从页面内容提取 token
                webView.evaluateJavaScript("document.body.innerText") { result, error in
                    if let text = result as? String {
                        // 尝试匹配各种 token 格式
                        if let token = self.extractTokenFromText(text) {
                            DispatchQueue.main.async {
                                self.parent.token = token
                            }
                        }
                    }
                }
                
                // 如果 cookie 足够，也保存 cookie
                if self.isEnough(cookieString) {
                    DispatchQueue.main.async {
                        self.parent.token = cookieString.trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }

        private func extractTokenFromText(_ text: String) -> String? {
            // 匹配常见的 token 格式
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
                // 夸克：部分接口（如转存/下载）对 __puus 更敏感；仅有 __pus/__kps 时可能"能建vbox但转存失败"，表现为 vbox 空文件夹。
                // 因此提高"可用 Cookie"判定门槛：优先要求 __puus；否则至少同时具备 __pus + __kps。
                return lower.contains("__puus=") || (lower.contains("__pus=") && lower.contains("__kps="))
            case .uc:
                return lower.contains("uc") || lower.contains("__pus=") || lower.contains("__kps=")
            case .one15:
                return lower.contains("uid=") || lower.contains("cid=") || lower.contains("seid=")
            case .pan123:
                return lower.contains("token") || lower.contains("auth") || lower.contains("session")
            case .pan139:
                return lower.contains("session") || lower.contains("token") || lower.contains("cookie")
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

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                TokenWebView(driveType: driveType, token: .constant(""))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { isLoading = false }

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
