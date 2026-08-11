//
//  PythonWebViewBridge.swift
//  vbox
//
//  Python ↔ WKWebView 桥接 — 给 Python 环境提供浏览器级抓取能力
//
// 功能:
//   webview_fetch(url, js_code) → dict/list
//   - 用 WKWebView 加载 url (真实浏览器环境, 自动通过 TAC/指纹验证)
//   - 页面加载完成后执行 js_code 提取数据
//   - 返回 JS 执行结果 (JSON 解析后的 dict/list)
//
// 用途:
//   Python 蜘蛛脚本中遇到被反爬保护的 API (如 TAC 验证码) 时,
//   可调用 webview_fetch() 绕过, 从页面 DOM 中直接提取数据。
//
// 设计原则:
//   1. 不影响现有功能 — 纯新增能力, 脚本不调用就不执行
//   2. 单例 WebView — 复用实例, 避免频繁创建销毁
//   3. 串行请求 — 一次只处理一个, 避免 WebView 并发问题
//   4. 超时保护 — 最长 30 秒, 防止卡住 Python 调用
//   5. 主线程操作 WebView — 同步调用用 semaphore 等待
//
// 集成说明:
//   - 本文件需添加到 vbox iOS 项目中
//   - 配合 PythonWebViewBridge.m (ObjC) 一起使用
//   - ObjC 层将 webview_fetch 注册到 Python 全局命名空间
//

import Foundation
import WebKit

// MARK: - 结果类型

/// webview_fetch 执行结果 (ObjC 可见)
@objc class PythonWebViewResult: NSObject {
    @objc let success: Bool
    @objc let jsonString: String?    // 成功时: JSON 字符串
    @objc let errorMessage: String?  // 失败时: 错误描述

    init(success: Bool, jsonString: String?, errorMessage: String?) {
        self.success = success
        self.jsonString = jsonString
        self.errorMessage = errorMessage
        super.init()
    }
}

// MARK: - WKWebView 桥接管理器

/// Python ↔ WKWebView 桥接主类
///
/// 调用链路:
///   Python 脚本
///     → webview_fetch(url, js_code)   [Python 全局函数]
///     → PyWebView_Fetch()             [ObjC C 函数]
///     → PythonWebViewBridge.fetchSync [Swift]
///     → WKWebView.load()              [主线程]
///     → didFinish + evaluateJavaScript
///     → 返回 JSON 字符串
///
/// Python 脚本使用示例:
/// ```python
/// result = webview_fetch(
///     'https://film.symx.club/m/search?keyword=流浪',
///     '''
///     let items = document.querySelectorAll('.film-card');
///     return Array.from(items).map(el => ({
///         vod_id: el.dataset.id,
///         vod_name: el.querySelector('.title').innerText,
///         vod_pic: el.querySelector('img').src
///     }));
///     '''
/// )
/// for item in result:
///     print(item['vod_name'])
/// ```
@objc
final class PythonWebViewBridge: NSObject {

    /// 共享实例
    @objc static let shared = PythonWebViewBridge()

    // MARK: - 私有状态

    /// 复用的 WKWebView (懒加载, 主线程创建)
    private var webView: WKWebView?

    /// 当前请求的 JS 提取代码
    private var pendingJSCode: String = ""

    /// 当前请求的 completion handler
    private var currentCompletion: ((PythonWebViewResult) -> Void)?

    /// 超时定时器
    private var timeoutTimer: Timer?

    /// 默认超时时间 (秒)
    private let defaultTimeout: TimeInterval = 30

    /// 串行队列 — 多个 webview_fetch 请求排队执行
    /// 避免同时操作同一个 WKWebView 造成混乱
    private let workQueue = DispatchQueue(label: "com.vbox.python.webview.fetch", qos: .userInitiated)

    // MARK: - Init

    private override init() {
        super.init()
    }

    // MARK: - 公共 API (供 ObjC 调用)

    /// 同步执行 webview_fetch (在调用线程阻塞等待)
    ///
    /// - Parameters:
    ///   - url: 要加载的页面 URL
    ///   - jsCode: 页面加载完成后执行的 JS 提取代码
    ///   - timeoutSeconds: 超时时间 (秒), 0 表示使用默认 30 秒
    /// - Returns: PythonWebViewResult 对象
    @objc func fetchSync(_ url: String, jsCode: String, timeoutSeconds: Int) -> PythonWebViewResult {
        var result: PythonWebViewResult!
        let semaphore = DispatchSemaphore(value: 0)

        // 切到主线程发起 WebView 操作
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                result = PythonWebViewResult(
                    success: false,
                    jsonString: nil,
                    errorMessage: "PythonWebViewBridge 已释放"
                )
                semaphore.signal()
                return
            }

            self.startFetch(url: url, jsCode: jsCode, timeout: timeoutSeconds > 0 ? TimeInterval(timeoutSeconds) : self.defaultTimeout) { res in
                result = res
                semaphore.signal()
            }
        }

        // 阻塞等待完成 (额外加 5 秒总超时, 防止死锁)
        let totalWait = (timeoutSeconds > 0 ? timeoutSeconds : Int(defaultTimeout)) + 5
        if semaphore.wait(timeout: .now() + .seconds(totalWait)) == .timedOut {
            // 超时清理
            DispatchQueue.main.async { [weak self] in
                self?.forceCleanup()
            }
            result = PythonWebViewResult(
                success: false,
                jsonString: nil,
                errorMessage: "webview_fetch 总超时 (\(totalWait)s)"
            )
        }

        return result
    }

    // MARK: - 内部实现 (主线程)

    /// 开始抓取 (必须在主线程调用)
    private func startFetch(
        url: String,
        jsCode: String,
        timeout: TimeInterval,
        completion: @escaping (PythonWebViewResult) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))

        // 如果上一个请求还在进行, 先取消
        if currentCompletion != nil {
            forceCleanup()
        }

        // 验证 URL
        guard let urlObj = URL(string: url) else {
            completion(PythonWebViewResult(
                success: false,
                jsonString: nil,
                errorMessage: "无效 URL: \(url)"
            ))
            return
        }

        // 获取 WebView
        let webView = ensureWebView()

        // 保存状态
        pendingJSCode = jsCode
        currentCompletion = completion

        // 设置超时
        timeoutTimer?.invalidate()
        let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            self?.handleTimeout()
        }
        RunLoop.main.add(timer, forMode: .common)
        timeoutTimer = timer

        // 加载页面
        let request = URLRequest(
            url: urlObj,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        webView.load(request)
    }

    /// 获取或创建 WKWebView (主线程)
    private func ensureWebView() -> WKWebView {
        dispatchPrecondition(condition: .onQueue(.main))

        if let webView = webView {
            return webView
        }

        let config = WKWebViewConfiguration()
        config.preferences = WKPreferences()
        config.preferences.javaScriptEnabled = true
        if #available(iOS 14.0, *) {
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
        }
        config.userContentController = WKUserContentController()

        // 桌面 Chrome UA, 提高反爬通过率
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_5) AppleWebKit/537.36 " +
                        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        webView.customUserAgent = userAgent
        webView.navigationDelegate = self
        webView.isHidden = true

        // 添加到 keyWindow (虽然不可见, 但需要在视图层级中才能正常工作)
        if let window = UIApplication.shared.keyWindow {
            window.addSubview(webView)
        }

        self.webView = webView
        return webView
    }

    /// 页面加载完成后执行 JS 提取 (主线程)
    private func runExtractor() {
        dispatchPrecondition(condition: .onQueue(.main))

        guard let webView = webView else {
            completeWithError("WKWebView 已释放")
            return
        }

        let js = pendingJSCode
        guard !js.isEmpty else {
            completeWithError("JS 提取代码为空")
            return
        }

        // 包装 JS:
        // - 捕获异常
        // - 用 JSON.stringify 序列化返回值
        // - 返回格式: { success: true, data: ... } 或 { success: false, error: "..." }
        let wrappedJS = """
        (function(){try{var __r=(function(){\(js)})();try{return JSON.stringify({success:true,data:__r})}catch(e){return JSON.stringify({success:true,data:String(__r)})}}catch(e){return JSON.stringify({success:false,error:e.message||String(e)})}})();
        """

        webView.evaluateJavaScript(wrappedJS) { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                self.completeWithError("JS 执行失败: \(error.localizedDescription)")
                return
            }

            guard let jsonStr = result as? String else {
                self.completeWithError("JS 返回值类型错误: \(type(of: result))")
                return
            }

            // 解析包装层
            guard let data = jsonStr.data(using: .utf8),
                  let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.completeWithError("JS 结果解析失败: \(jsonStr.prefix(200))")
                return
            }

            if wrapper["success"] as? Bool == true {
                // 成功: 提取 data 并重新序列化为 JSON 字符串
                if let rawData = wrapper["data"] {
                    if JSONSerialization.isValidJSONObject(rawData),
                       let finalData = try? JSONSerialization.data(withJSONObject: rawData),
                       let finalStr = String(data: finalData, encoding: .utf8) {
                        self.completeWithSuccess(finalStr)
                    } else {
                        // data 不是合法 JSON 对象, 转字符串返回
                        let strVal = String(describing: rawData)
                        self.completeWithSuccess("\"\\(strVal)\"")
                    }
                } else {
                    self.completeWithSuccess("null")
                }
            } else {
                let err = wrapper["error"] as? String ?? "未知 JS 错误"
                self.completeWithError("JS 提取失败: \(err)")
            }
        }
    }

    // MARK: - 完成处理 (主线程)

    private func completeWithSuccess(_ jsonString: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let completion = currentCompletion
        cleanupState()
        completion?(PythonWebViewResult(success: true, jsonString: jsonString, errorMessage: nil))
    }

    private func completeWithError(_ message: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let completion = currentCompletion
        cleanupState()
        completion?(PythonWebViewResult(success: false, jsonString: nil, errorMessage: message))
    }

    private func handleTimeout() {
        completeWithError("页面加载超时")
    }

    private func forceCleanup() {
        dispatchPrecondition(condition: .onQueue(.main))
        webView?.stopLoading()
        let completion = currentCompletion
        cleanupState()
        completion?(PythonWebViewResult(success: false, jsonString: nil, errorMessage: "请求被取消"))
    }

    private func cleanupState() {
        dispatchPrecondition(condition: .onQueue(.main))
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        webView?.stopLoading()
        pendingJSCode = ""
        currentCompletion = nil
    }
}

// MARK: - WKNavigationDelegate

extension PythonWebViewBridge: WKNavigationDelegate {

    /// 页面加载完成
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 延迟执行 JS, 等前端框架 (Vue/React) 渲染完 DOM
        // 1.5 秒通常足够 SPA 首屏渲染
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            // 确认请求还在进行中 (没有超时或被取消)
            guard self.currentCompletion != nil else { return }
            self.runExtractor()
        }
    }

    /// 页面加载失败
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completeWithError("页面加载失败: \(error.localizedDescription)")
    }

    /// 网络请求阶段失败
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completeWithError("网络请求失败: \(error.localizedDescription)")
    }
}
