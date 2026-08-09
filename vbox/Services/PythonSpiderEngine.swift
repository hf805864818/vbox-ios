//
//  PythonSpiderEngine.swift
//  vbox
//
//  Python Spider 引擎 — 实现 SpiderEngineProtocol，通过 PythonSpiderBridge 调用 CPython 解释器
//  可同时用于首页/搜索的普通蜘蛛和福利专区的远程蜘蛛。
//

import Foundation

// MARK: - 引擎错误

enum PythonSpiderError: LocalizedError {
    case execFailed(String)
    case invalidJSON(String)
    case notInitialized

    var errorDescription: String? {
        switch self {
        case .execFailed(let fn): return "Python Spider 方法 \(fn) 执行失败"
        case .invalidJSON(let fn): return "Python Spider 方法 \(fn) 返回非法 JSON"
        case .notInitialized: return "Python Spider 引擎未初始化"
        }
    }
}

// MARK: - Python Spider 引擎

final class PythonSpiderEngine: SpiderEngineProtocol {

    var onLog: ((String) -> Void)?

    private let scriptPath: String
    private let scriptName: String
    private let scriptKey: String
    private var _isSpiderReady = false
    
    var isSpiderReady: Bool { _isSpiderReady }

    // MARK: - Init

    /// 创建 Python Spider 引擎
    /// - Parameters:
    ///   - scriptPath: 本地 .py 脚本绝对路径
    ///   - key: Spider 唯一标识（用于日志）
    init(scriptPath: String, key: String) {
        self.scriptPath = scriptPath
        self.scriptName = URL(fileURLWithPath: scriptPath).lastPathComponent
        self.scriptKey = key

        onLog?("🐍 [\(scriptKey)] 初始化 Python Spider 引擎")

        // 初始化 Python 解释器（全局只执行一次）
        PythonSpiderBridge.initializePythonIfNeeded()

        // 注册 Spider（调 init()）
        registerSpiderInternal()
    }

    private func registerSpiderInternal() {
        let start = Date()
        let json = PythonSpiderBridge.callSpider(scriptPath, function: "init", args: "{}")
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)

        if json != nil {
            _isSpiderReady = true
            onLog?("✅ [\(scriptKey)] Python Spider 初始化完成 (\(elapsed)ms)")
        } else {
            onLog?("❌ [\(scriptKey)] Python Spider 初始化失败 (\(elapsed)ms)")
        }
    }

    // MARK: - SpiderEngineProtocol

    func loadScript(_ script: String) throws {
        // Python 脚本不需要额外加载（已在 init 中执行）
    }

    func loadLibrary(_ script: String) throws {
        // Python 库不需要预注入（通过 sys.path + import 加载）
    }

    func loadScriptFromURL(_ urlString: String) async throws {
        guard let url = URL(string: urlString) else {
            throw PythonSpiderError.execFailed("loadScriptFromURL: 无效 URL")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        try data.write(to: URL(fileURLWithPath: scriptPath), options: .atomic)

        // 重新注册
        _isSpiderReady = false
        registerSpiderInternal()
    }

    func registerSpider() throws {
        guard _isSpiderReady else {
            throw PythonSpiderError.notInitialized
        }
    }

    // MARK: - Spider Methods

    func callHomeContent() throws -> HomeContentResult {
        guard let json = call("homeContent", args: "{}"),
              let data = json.data(using: .utf8) else {
            throw PythonSpiderError.execFailed("homeContent")
        }
        return try decodeOrFallbackHome(from: data)
    }

    func callCategoryContent(tid: String, pg: Int, extend: String) throws -> CategoryContentResult {
        let args = #"{"tid":"\#(tid)","pg":"\#(pg)","extend":"\#(extend)"}"#
        guard let json = call("categoryContent", args: args),
              let data = json.data(using: .utf8) else {
            throw PythonSpiderError.execFailed("categoryContent")
        }
        do {
            return try JSONDecoder().decode(CategoryContentResult.self, from: data)
        } catch {
            throw PythonSpiderError.invalidJSON("categoryContent")
        }
    }

    func callDetailContent(ids: String) throws -> DetailContentResult {
        let idsJSON = #"["\#(ids)"]"#
        guard let json = call("detailContent", args: idsJSON),
              let data = json.data(using: .utf8) else {
            throw PythonSpiderError.execFailed("detailContent")
        }
        do {
            return try JSONDecoder().decode(DetailContentResult.self, from: data)
        } catch {
            throw PythonSpiderError.invalidJSON("detailContent")
        }
    }

    func callSearchContent(keyword: String, pg: Int) throws -> SearchContentResult {
        let args = #"{"key":"\#(keyword)","quick":false,"pg":"\#(pg)"}"#
        guard let json = call("searchContent", args: args),
              let data = json.data(using: .utf8) else {
            throw PythonSpiderError.execFailed("searchContent")
        }
        do {
            return try JSONDecoder().decode(SearchContentResult.self, from: data)
        } catch {
            throw PythonSpiderError.invalidJSON("searchContent")
        }
    }

    func callPlayerContent(vodId: String, flag: String, url: String) throws -> PlayerContentResult {
        let args = #"{"flag":"\#(flag)","id":"\#(url)"}"#
        guard let json = call("playerContent", args: args),
              let data = json.data(using: .utf8) else {
            throw PythonSpiderError.execFailed("playerContent")
        }
        do {
            return try JSONDecoder().decode(PlayerContentResult.self, from: data)
        } catch {
            throw PythonSpiderError.invalidJSON("playerContent")
        }
    }

    // MARK: - Private

    private func call(_ function: String, args: String) -> String? {
        let start = Date()
        let result = PythonSpiderBridge.callSpider(scriptPath, function: function, args: args)
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        if result != nil {
            onLog?("📞 [\(scriptKey)] \(function) → \(elapsed)ms")
        } else {
            onLog?("❌ [\(scriptKey)] \(function) 执行失败 (\(elapsed)ms)")
        }
        return result
    }

    /// 容错解码：如果标准解码失败，尝试用宽松的格式解析
    private func decodeOrFallbackHome(from data: Data) throws -> HomeContentResult {
        do {
            return try JSONDecoder().decode(HomeContentResult.self, from: data)
        } catch {
            // 部分 Python Spider 返回的 homeContent JSON 格式略有不同
            // 尝试作为通用 dict 解，然后手动提取
            guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PythonSpiderError.invalidJSON("homeContent")
            }

            let classItems: [VodCategory]
            if let cls = dict["class"] as? [[String: Any]] {
                classItems = cls.compactMap { item in
                    guard let typeId = item["type_id"] as? String,
                          let typeName = item["type_name"] as? String else { return nil }
                    return VodCategory(typeId: typeId, typeName: typeName)
                }
            } else if let cls = dict["classes"] as? [[String: Any]] {
                classItems = cls.compactMap { item in
                    guard let typeId = (item["type_id"] ?? item["id"]) as? String,
                          let typeName = (item["type_name"] ?? item["name"]) as? String else { return nil }
                    return VodCategory(typeId: typeId, typeName: typeName)
                }
            } else {
                classItems = []
            }

            let listItems: [VodItem]
            if let list = dict["list"] as? [[String: Any]] {
                listItems = list.compactMap { item in
                    guard let vodId = (item["vod_id"] ?? item["id"]) as? String,
                          let vodName = item["vod_name"] as? String ?? item["title"] as? String else { return nil }
                    return VodItem(
                        vodId: vodId,
                        vodName: vodName,
                        vodPic: item["vod_pic"] as? String ?? "",
                        vodRemarks: item["vod_remarks"] as? String
                    )
                }
            } else {
                listItems = []
            }

            return HomeContentResult(class: classItems, list: listItems)
        }
    }
}

// MARK: - 🆕 新增引擎类型

extension SpiderEngineType {
    static let python = SpiderEngineType(rawValue: "Python")
}

extension SpiderEngineType {
    var displayName: String {
        switch self {
        case .javaScriptCore: return "JSC (Apple)"
        case .quickJS: return "QuickJS"
        case .python: return "Python 🐍"
        default: return rawValue
        }
    }
}
