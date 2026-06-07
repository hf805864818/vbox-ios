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
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                TokenWebView(onTokenDetected: { type, value in
                    detectedToken = (type, value)
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
                        Text("类型: \(CloudDriveManager.DriveType(rawValue: token.type)?.displayName ?? token.type)")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                        Text("已自动填入，请保存")
                            .font(.system(size: 13))
                            .foregroundColor(.blue)
                    }
                    .padding(.bottom, 40)
                    .onAppear {
                        // 2秒后自动关闭
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
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
