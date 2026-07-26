import Foundation

/// QuickJS 蜘蛛引擎 — 真正的 TVBox 蜘蛛执行环境
class QJSSpiderEngine {

    private var rt: UnsafeMutableRawPointer?
    private var ctx: UnsafeMutableRawPointer?

    var onLog: ((String) -> Void)?

    init() {
        rt = QJSBridge_createRuntime()
        if let rt = rt {
            ctx = QJSBridge_createContext(rt)
        }
        setupBridge()
        // 注册 http() 和 crypto 到 JS 全局
        if let ctx = ctx {
            QJSBridge_registerHTTP(ctx)
            QJSBridge_registerCrypto(ctx)
        }
        onLog?("✅ QuickJS 引擎初始化完成")
    }

    deinit {
        // QuickJS 的标准清理顺序：
        // 1. JS_FreeContext(ctx) — 释放 context 及其所有 JS 对象（global_obj 等）
        //    JS_FreeContext 内部会：
        //    - 释放 global_obj 和 global_var_obj（级联释放所有属性）
        //    - 从 runtime 的 context_list 中移除
        //    - 从 gc_obj_list 中移除
        // 2. JS_FreeRuntime(rt) — 释放 runtime，内部会运行 JS_RunGC 并
        //    断言 gc_obj_list 为空（assert(list_empty(&rt->gc_obj_list))）
        //
        // 注意：必须先释放 context 再释放 runtime，否则 runtime 的 gc_obj_list
        // 中仍有 context 的对象，导致 JS_FreeRuntime 断言失败
        if let ctx = ctx {
            QJSBridge_freeContext(ctx)
        }
        if let rt = rt {
            QJSBridge_freeRuntime(rt)
        }
        // 将指针置空，防止意外使用
        ctx = nil
        rt = nil
    }

    private func setupBridge() {
        // 注册 print 和 console.log
        _ = evaluateJS("""
        var console = { log: function(msg) {}, error: function(msg) {} };
        var print = function(msg) {};
        """)
    }

    /// 执行 JS 代码
    func evaluateJS(_ script: String) -> String? {
        guard let ctx = ctx else { return nil }
        let cStr = (script as NSString).utf8String!

        guard let result = QJSBridge_eval(ctx, cStr) else { return nil }
        let swiftResult = String(cString: result)
        QJSBridge_freeString(ctx, result)
        return swiftResult
    }

    /// 加载 JS 脚本
    func loadScript(_ script: String) throws {
        let result = evaluateJS(script)
        // 检查是否有 JS 异常
        if let result = result, !result.isEmpty {
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Error") || trimmed.hasPrefix("TypeError") || trimmed.hasPrefix("ReferenceError") || trimmed.hasPrefix("SyntaxError") {
                onLog?("❌ JS异常: \(trimmed)")
                throw QJSError(message: "JS异常: \(trimmed)")
            }
        }
        onLog?("✅ 脚本加载完成 (\(script.count) 字符)")
    }

    /// 注册蜘蛛 — 直接在 evaluateJS 中检测 __JS_SPIDER__ 是否存在
    func registerSpider() -> Bool {
        let result = evaluateJS("typeof globalThis.__JS_SPIDER__")
        let founded = (result == "object" || result == "\"object\"" || result?.contains("object") == true)
        if founded {
            onLog?("✅ 蜘蛛注册成功")
        } else {
            onLog?("❌ 蜘蛛注册失败: __JS_SPIDER__ 类型=\(result ?? "nil")")
        }
        return founded
    }

    /// 调用蜘蛛 API
    func callSpiderAPI(_ apiName: String, args: [String] = []) throws -> String {
        let escapedArgs = args.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" }.joined(separator: ", ")
        let script = "globalThis.__JS_SPIDER__.\(apiName)(\(escapedArgs))"
        guard let result = evaluateJS(script) else {
            throw QJSError(message: "调用 \(apiName) 失败")
        }
        return result
    }

    /// 首页推荐
    func callHomeContent() throws -> HomeContentResult {
        let json = try callSpiderAPI("homeContent")
        guard let data = json.data(using: .utf8) else {
            throw QJSError(message: "homeContent 返回数据解析失败")
        }
        return try JSONDecoder().decode(HomeContentResult.self, from: data)
    }

    /// 搜索
    func callSearchContent(keyword: String, pg: Int = 1) throws -> SearchContentResult {
        let json = try callSpiderAPI("searchContent", args: [keyword, "\(pg)"])
        guard let data = json.data(using: .utf8) else {
            throw QJSError(message: "searchContent 返回数据解析失败")
        }
        return try JSONDecoder().decode(SearchContentResult.self, from: data)
    }

    /// 详情
    func callDetailContent(ids: String) throws -> DetailContentResult {
        let json = try callSpiderAPI("detailContent", args: [ids])
        guard let data = json.data(using: .utf8) else {
            throw QJSError(message: "detailContent 返回数据解析失败")
        }
        return try JSONDecoder().decode(DetailContentResult.self, from: data)
    }

    /// 播放解析
    func callPlayerContent(vodId: String, flag: String, url: String) throws -> PlayerContentResult {
        let json = try callSpiderAPI("playerContent", args: [vodId, flag, url])
        guard let data = json.data(using: .utf8) else {
            throw QJSError(message: "playerContent 返回数据解析失败")
        }
        return try JSONDecoder().decode(PlayerContentResult.self, from: data)
    }

    /// 分类内容
    func callCategoryContent(tid: String, pg: Int = 1, extend: String = "{}") throws -> CategoryContentResult {
        let json = try callSpiderAPI("categoryContent", args: [tid, "\(pg)", extend])
        guard let data = json.data(using: .utf8) else {
            throw QJSError(message: "categoryContent 返回数据解析失败")
        }
        return try JSONDecoder().decode(CategoryContentResult.self, from: data)
    }
}

struct QJSError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
