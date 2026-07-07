import Foundation
import WebKit

enum WKParserType {
    case jsParser(jsURL: String)
    case wasmParser(wasmURL: String)
}

class WKWebViewParser: NSObject {
    static let shared = WKWebViewParser()
    private var webView: WKWebView?
    private var completionBlock: ((String?) -> Void)?
    private var timeoutTimer: Timer?

    private override init() { super.init() }

    func parse(url: String, parserType: WKParserType, completion: @escaping (String?) -> Void) {
        // 清理旧的
        cleanup()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all

        let contentController = WKUserContentController()
        contentController.add(self, name: "parserHandler")
        config.userContentController = contentController

        webView = WKWebView(frame: .zero, configuration: config)
        completionBlock = completion

        // 15秒超时
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            self?.complete(with: nil)
        }

        let html: String
        switch parserType {
        case .jsParser(let jsURL):
            html = """
            <!DOCTYPE html><html><head><meta charset="utf-8"></head><body>
            <script src="\(jsURL)"></script>
            <script>
                try {
                    var result = '';
                    if (typeof parse === 'function') {
                        result = parse('\(url)');
                    } else if (typeof jiexi === 'function') {
                        result = jiexi('\(url)');
                    }
                    window.webkit.messageHandlers.parserHandler.postMessage(result);
                } catch(e) {
                    window.webkit.messageHandlers.parserHandler.postMessage('error:' + e.message);
                }
            </script>
            </body></html>
            """
        case .wasmParser(let wasmURL):
            html = """
            <!DOCTYPE html><html><head><meta charset="utf-8"></head><body>
            <script>
            fetch('\(wasmURL)')
                .then(r => r.arrayBuffer())
                .then(bytes => WebAssembly.instantiate(bytes))
                .then(results => {
                    var result = '';
                    if (typeof results.instance.exports.parse === 'function') {
                        result = results.instance.exports.parse('\(url)');
                    }
                    window.webkit.messageHandlers.parserHandler.postMessage(result);
                })
                .catch(e => window.webkit.messageHandlers.parserHandler.postMessage('error:' + e.message));
            </script>
            </body></html>
            """
        }

        webView?.loadHTMLString(html, baseURL: nil)
    }

    private func complete(with result: String?) {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        let block = completionBlock
        completionBlock = nil
        DispatchQueue.main.async { block?(result) }
    }

    private func cleanup() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        if let wv = webView {
            wv.stopLoading()
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "parserHandler")
            webView = nil
        }
    }
}

extension WKWebViewParser: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "parserHandler" {
            let body = message.body as? String ?? ""
            if body.hasPrefix("error:") {
                complete(with: nil)
            } else {
                complete(with: body)
            }
        }
    }
}
