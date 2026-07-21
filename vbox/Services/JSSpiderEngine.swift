import Foundation
import JavaScriptCore

/// JavaScriptCore 异常
struct JSError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// JS引擎桥接层 — 管理 JavaScriptCore 上下文，加载蜘蛛脚本，调用蜘蛛API
class JSSpiderEngine {

    // MARK: - 属性
    private let context: JSContext
    private let httpBridge: JSHTTPBridge

    var onLog: ((String) -> Void)?

    // MARK: - 初始化
    init() {
        self.context = JSContext()
        self.httpBridge = JSHTTPBridge()
        setupContext()
    }

    /// 配置 JSContext 的桥接
    private func setupContext() {
        // 异常捕获
        context.exceptionHandler = { [weak self] _, exception in
            let msg = exception?.toString() ?? "未知JS错误"
            self?.onLog?("❌ JS异常: \(msg)")
        }

        // 桥接 console.log / console.error
        let console: @convention(block) (String) -> Void = { [weak self] msg in
            self?.onLog?("📗 \(msg)")
        }
        context.setObject(unsafeBitCast(console, to: AnyObject.self),
                         forKeyedSubscript: "__consoleLog" as NSString)
        context.evaluateScript("""
        console = {
            log: function(...args) { __consoleLog(args.join(' ')); },
            error: function(...args) { __consoleLog('ERROR: ' + args.join(' ')); }
        };
        """)

        // 桥接 print() — 蜘蛛脚本常用
        let printFunc: @convention(block) (String) -> Void = { [weak self] msg in
            self?.onLog?("🖨️ \(msg)")
        }
        context.setObject(unsafeBitCast(printFunc, to: AnyObject.self),
                         forKeyedSubscript: "print" as NSString)

        // 桥接 http() — 蜘蛛脚本的网络请求
        let httpFunc: @convention(block) (String, [String: Any]) -> [String: Any] = { [weak self] url, options in
            guard let self = self else { return ["ok": false, "status": 500, "content": "引擎已释放"] }
            return self.httpBridge.syncRequest(url: url, options: options)
        }
        context.setObject(unsafeBitCast(httpFunc, to: AnyObject.self),
                         forKeyedSubscript: "_http" as NSString)

        // 注册全局 http 和 req 函数
        context.evaluateScript("""
        var http = function(url, options) {
            if (!options) options = {};
            options.async = false;
            return _http(url, options);
        };
        var req = http;
        """)

        // 桥接 XMLHttpRequest (简化版)
        let xhrOpen: @convention(block) (String, String, Bool) -> Void = { method, url, async in
            // 简单模式，忽略async
        }
        context.setObject(unsafeBitCast(xhrOpen, to: AnyObject.self),
                         forKeyedSubscript: "__xhrOpen" as NSString)

        onLog?("✅ JS引擎上下文初始化完成")
    }

    // MARK: - 加载蜘蛛脚本

    /// 加载蜘蛛脚本字符串
    func loadScript(_ script: String) throws {
        let result = context.evaluateScript(script)
        if let exception = context.exception {
            throw JSError(message: "加载脚本失败: \(exception.toString() ?? "未知错误")")
        }
        onLog?("✅ 蜘蛛脚本加载完成 (\(script.count) 字符)")
    }

    /// 从 Bundle 加载蜘蛛脚本
    func loadScriptFromBundle(fileName: String, ext: String = "js") throws {
        guard let path = Bundle.main.path(forResource: fileName, ofType: ext),
              let script = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw JSError(message: "找不到脚本文件: \(fileName).\(ext)")
        }
        try loadScript(script)
    }

    /// 从远程URL加载蜘蛛脚本
    func loadScriptFromURL(_ urlString: String) async throws {
        guard let url = URL(string: urlString) else {
            throw JSError(message: "无效的URL: \(urlString)")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let script = String(data: data, encoding: .utf8) else {
            throw JSError(message: "无法解码脚本: \(urlString)")
        }
        try loadScript(script)
    }

    /// 加载引擎库（模板.js/cat.js等标准库）
    func loadLibrary(_ script: String) throws {
        // 库脚本用 evaluateScript 但不检查 spider 注册
        context.evaluateScript(script)
        if let exception = context.exception {
            throw JSError(message: "加载库失败: \(exception.toString() ?? "未知错误")")
        }
    }

    // MARK: - 注册蜘蛛

    /// 检查并注册 __JS_SPIDER__
    var isSpiderReady: Bool {
        let exists = context.evaluateScript("typeof globalThis.__JS_SPIDER__ !== 'undefined'")
        return exists?.toBool() ?? false
    }

    /// 注册蜘蛛对象到 globalThis
    func registerSpider() throws {
        let script = """
        if (typeof globalThis.__JS_SPIDER__ === 'undefined') {
            if (typeof spider !== 'undefined') {
                if (typeof spider.__jsEvalReturn === 'function') {
                    globalThis.__JS_SPIDER__ = spider.__jsEvalReturn();
                } else if (typeof spider.default === 'function') {
                    globalThis.__JS_SPIDER__ = spider.default();
                } else {
                    globalThis.__JS_SPIDER__ = spider;
                }
                if (globalThis.__JS_SPIDER__) {
                    globalThis.__JS_SPIDER__.is_cat = true;
                }
            }
        }
        typeof globalThis.__JS_SPIDER__ !== 'undefined';
        """
        let result = context.evaluateScript(script)
        if result?.toBool() != true {
            throw JSError(message: "无法注册蜘蛛: 没有找到 spider 对象")
        }
        onLog?("✅ 蜘蛛已注册到 globalThis.__JS_SPIDER__")
    }

    // MARK: - 调用蜘蛛API

    /// 调用 spider.init(config)
    func callInit(config: [String: Any]) -> Bool {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: config),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            return false
        }
        let script = "globalThis.__JS_SPIDER__.init(\(jsonStr))"
        let result = context.evaluateScript(script)
        return result?.toBool() ?? false
    }

    /// 通用调用：自动判断返回值是字符串还是对象，避免双重 JSON 编码
    private func callSpiderMethod<T: Decodable>(_ methodName: String, args: [String] = [], as type: T.Type) throws -> T {
        let escapedArgs = args.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" }.joined(separator: ", ")
        let rawScript = "globalThis.__JS_SPIDER__.\(methodName)(\(escapedArgs))"
        let rawResult = context.evaluateScript(rawScript)

        let jsonString: String
        if let result = rawResult {
            if result.isString {
                // 返回值已经是 JSON 字符串，直接使用
                jsonString = result.toString()
            } else if result.isObject || result.isArray {
                // 返回值是对象/数组，需要 stringify
                let stringifyScript = "JSON.stringify(\(rawScript))"
                guard let str = context.evaluateScript(stringifyScript)?.toString() else {
                    throw JSError(message: "\(methodName) 返回无效")
                }
                jsonString = str
            } else {
                throw JSError(message: "\(methodName) 返回类型无效")
            }
        } else {
            throw JSError(message: "\(methodName) 返回无效")
        }

        guard let data = jsonString.data(using: .utf8) else {
            throw JSError(message: "\(methodName) 返回无效")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// 调用 spider.homeContent()
    func callHomeContent() throws -> HomeContentResult {
        try callSpiderMethod("homeContent", as: HomeContentResult.self)
    }

    /// 调用 spider.categoryContent(tid, pg, extend)
    func callCategoryContent(tid: String, pg: Int, extend: String = "{}") throws -> CategoryContentResult {
        try callSpiderMethod("categoryContent", args: [tid, String(pg), extend], as: CategoryContentResult.self)
    }

    /// 调用 spider.detailContent(ids)
    func callDetailContent(ids: String) throws -> DetailContentResult {
        try callSpiderMethod("detailContent", args: [ids], as: DetailContentResult.self)
    }

    /// 调用 spider.searchContent(keyword, pg)
    func callSearchContent(keyword: String, pg: Int = 1) throws -> SearchContentResult {
        try callSpiderMethod("searchContent", args: [keyword, String(pg)], as: SearchContentResult.self)
    }

    /// 调用 spider.playerContent(vod_id, flag, url)
    func callPlayerContent(vodId: String, flag: String, url: String) throws -> PlayerContentResult {
        try callSpiderMethod("playerContent", args: [vodId, flag, url], as: PlayerContentResult.self)
    }

    // MARK: - 通用调用

    /// 调用任意蜘蛛方法（返回原始JS值，用于调试）
    func callRawFunction(_ script: String) -> JSValue? {
        return context.evaluateScript(script)
    }
}
