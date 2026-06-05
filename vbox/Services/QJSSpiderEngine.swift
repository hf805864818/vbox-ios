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
        // 注册 http() 到 JS 全局
        if let ctx = ctx {
            QJSBridge_registerHTTP(ctx)
        }
        onLog?("✅ QuickJS 引擎初始化完成")
    }
    
    deinit {
        if let ctx = ctx { QJSBridge_freeContext(ctx) }
        if let rt = rt { QJSBridge_freeRuntime(rt) }
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
        if result?.contains("Error") == true || result?.contains("exception") == true {
            throw QJSError(message: "脚本加载失败: \(result ?? "未知错误")")
        }
        onLog?("✅ 脚本加载完成 (\(script.count) 字符)")
    }
    
    /// 注册蜘蛛
    func registerSpider() -> Bool {
        let result = evaluateJS("""
        if (typeof globalThis === 'undefined') { var globalThis = this; }
        if (typeof globalThis.__JS_SPIDER__ !== 'undefined') { 'true'; } else { 'false'; }
        """)
        return result?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
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
}

struct QJSError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
