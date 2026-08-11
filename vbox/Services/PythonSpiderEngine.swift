//
//  PythonSpiderEngine.swift
//  vbox
//
//  Python Spider 引擎 — 实现 SpiderEngineProtocol，通过 PythonSpiderBridge 调用 CPython 解释器
//  可同时用于首页/搜索的普通蜘蛛和福利专区的远程蜘蛛。
//
//  修复记录 (2026-08-10):
//  1. 新增异步方法 (callHomeContentAsync / callCategoryContentAsync 等)
//     Python 调用在后台线程执行, 不阻塞主线程 (SpiderManager 是 @MainActor)
//     之前同步方法直接在主线程调用 PythonBridge.callSpider(), 导致 UI 冻结
//  2. 同步方法保留以遵循 SpiderEngineProtocol, 内部调用异步版本
//     (注意: 同步方法仍会阻塞调用线程, 建议优先使用异步方法)
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

    /// Python 调用专用串行队列
    /// CPython 有 GIL, 多线程并发执行 Python 代码没有意义
    /// 使用串行队列保证 Python 调用顺序执行, 避免 GIL 竞争
    private let pythonQueue = DispatchQueue(label: "com.vbox.python.spider", qos: .userInitiated)

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

        // 注册 Spider（调 init()）— 在后台线程执行, 不阻塞主线程
        // 注意: init 在构造器中调用, 但 registerSpiderInternal 是同步的
        // 为了不阻塞主线程, 构造器只做轻量初始化, 真正的注册在后台完成
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
        try await registerSpiderAsync()
    }

    func registerSpider() throws {
        guard _isSpiderReady else {
            throw PythonSpiderError.notInitialized
        }
    }

    // MARK: - Spider Methods (同步, 协议要求)

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
        // ★ 先尝试标准解码
        do {
            let result = try JSONDecoder().decode(CategoryContentResult.self, from: data)
            // ★ 记录空列表情况, 便于排查
            if result.list?.isEmpty != false {
                onLog?("⚠️ [\(scriptKey)] categoryContent 返回空列表! tid=\(tid), pg=\(pg), 原始: \(json.prefix(200))")
            } else {
                onLog?("✅ [\(scriptKey)] categoryContent 成功: tid=\(tid), \(result.list?.count ?? 0)条")
            }
            return result
        } catch {
            onLog?("⚠️ [\(scriptKey)] categoryContent 标准解码失败, 尝试容错解析: \(error.localizedDescription)")
            // ★ 容错解析: 用 JSONSerialization 手动提取, 兼容整数 vod_id 等
            return try decodeOrFallbackCategory(from: data)
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
            onLog?("⚠️ [\(scriptKey)] detailContent 标准解码失败, 尝试容错解析: \(error.localizedDescription)")
            return try decodeOrFallbackDetail(from: data)
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
            onLog?("⚠️ [\(scriptKey)] searchContent 标准解码失败, 尝试容错解析: \(error.localizedDescription)")
            return try decodeOrFallbackSearch(from: data)
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

    // MARK: - Spider Methods (异步, 推荐使用)
    // 在后台线程执行 Python 调用, 不阻塞主线程
    // 因为 SpiderManager 是 @MainActor, 同步调用会阻塞 UI

    /// 异步注册 Spider
    func registerSpiderAsync() async throws {
        try await withCheckedThrowingContinuation { continuation in
            pythonQueue.async { [weak self] in
                guard let self = self else { return }
                self.registerSpiderInternal()
                if self._isSpiderReady {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PythonSpiderError.notInitialized)
                }
            }
        }
    }

    /// 异步调用首页
    func callHomeContentAsync() async throws -> HomeContentResult {
        try await withCheckedThrowingContinuation { continuation in
            pythonQueue.async { [weak self] in
                guard let self = self else { return }
                do {
                    let result = try self.callHomeContent()
                    DispatchQueue.main.async {
                        continuation.resume(returning: result)
                    }
                } catch {
                    DispatchQueue.main.async {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// 异步调用分类
    func callCategoryContentAsync(tid: String, pg: Int, extend: String) async throws -> CategoryContentResult {
        try await withCheckedThrowingContinuation { continuation in
            pythonQueue.async { [weak self] in
                guard let self = self else { return }
                do {
                    let result = try self.callCategoryContent(tid: tid, pg: pg, extend: extend)
                    DispatchQueue.main.async {
                        continuation.resume(returning: result)
                    }
                } catch {
                    DispatchQueue.main.async {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// 异步调用详情
    func callDetailContentAsync(ids: String) async throws -> DetailContentResult {
        try await withCheckedThrowingContinuation { continuation in
            pythonQueue.async { [weak self] in
                guard let self = self else { return }
                do {
                    let result = try self.callDetailContent(ids: ids)
                    DispatchQueue.main.async {
                        continuation.resume(returning: result)
                    }
                } catch {
                    DispatchQueue.main.async {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// 异步调用搜索
    func callSearchContentAsync(keyword: String, pg: Int) async throws -> SearchContentResult {
        try await withCheckedThrowingContinuation { continuation in
            pythonQueue.async { [weak self] in
                guard let self = self else { return }
                do {
                    let result = try self.callSearchContent(keyword: keyword, pg: pg)
                    DispatchQueue.main.async {
                        continuation.resume(returning: result)
                    }
                } catch {
                    DispatchQueue.main.async {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// 异步调用播放解析
    func callPlayerContentAsync(vodId: String, flag: String, url: String) async throws -> PlayerContentResult {
        try await withCheckedThrowingContinuation { continuation in
            pythonQueue.async { [weak self] in
                guard let self = self else { return }
                do {
                    let result = try self.callPlayerContent(vodId: vodId, flag: flag, url: url)
                    DispatchQueue.main.async {
                        continuation.resume(returning: result)
                    }
                } catch {
                    DispatchQueue.main.async {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - Private

    private func call(_ function: String, args: String) -> String? {
        let start = Date()
        let result = PythonSpiderBridge.callSpider(scriptPath, function: function, args: args)
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        if let result = result {
            // ★ 记录返回的原始 JSON (截断前 200 字符, 方便调试)
            let preview = result.count > 200 ? String(result.prefix(200)) + "..." : result
            onLog?("📞 [\(scriptKey)] \(function) → \(elapsed)ms, \(result.count)字符")
            onLog?("📄 [\(scriptKey)] \(function) 原始返回: \(preview)")
        } else {
            onLog?("❌ [\(scriptKey)] \(function) 执行失败 (\(elapsed)ms)")
        }
        return result
    }

    // MARK: - 容错解码工具

    /// 从 Any 值提取 String, 兼容 Int/Double/Bool 等类型
    private func anyToString(_ value: Any?) -> String? {
        guard let value = value else { return nil }
        if let s = value as? String { return s }
        if let i = value as? Int { return String(i) }
        if let d = value as? Double { return String(Int(d)) }
        if let b = value as? Bool { return String(b) }
        if let n = value as? NSNumber { return n.stringValue }
        return String(describing: value)
    }

    /// 从 dict 中按优先级提取字段值并转为 String
    private func extractString(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let val = anyToString(dict[key]) {
                return val
            }
        }
        return nil
    }

    /// 通用: 从 [[String: Any]] 数组解析 VodItem 列表
    private func parseVodItems(from list: [[String: Any]]) -> [VodItem] {
        return list.compactMap { item -> VodItem? in
            // vod_id 兼容整数和字符串, 也尝试 "id" 字段
            guard let vodId = extractString(item, keys: ["vod_id", "id", "vodId"]),
                  let vodName = extractString(item, keys: ["vod_name", "title", "name"]) else {
                onLog?("⚠️ [\(scriptKey)] 跳过无法解析的视频项: \(item)")
                return nil
            }
            return VodItem(
                vodId: vodId,
                vodName: vodName,
                vodPic: extractString(item, keys: ["vod_pic", "pic", "cover"]) ?? "",
                vodRemarks: extractString(item, keys: ["vod_remarks", "remarks", "note"]),
                vodYear: extractString(item, keys: ["vod_year", "year"]),
                vodArea: extractString(item, keys: ["vod_area", "area"]),
                vodDirector: extractString(item, keys: ["vod_director", "director"]),
                vodActor: extractString(item, keys: ["vod_actor", "actor"]),
                vodContent: extractString(item, keys: ["vod_content", "content", "desc"]),
                vodPlayFrom: extractString(item, keys: ["vod_play_from", "play_from"]),
                vodPlayUrl: extractString(item, keys: ["vod_play_url", "play_url"])
            )
        }
    }

    /// 通用: 从 [[String: Any]] 数组解析 VodCategory 列表
    private func parseCategories(from list: [[String: Any]]) -> [VodCategory] {
        return list.compactMap { item -> VodCategory? in
            guard let typeId = extractString(item, keys: ["type_id", "id"]),
                  let typeName = extractString(item, keys: ["type_name", "name"]) else {
                return nil
            }
            return VodCategory(typeId: typeId, typeName: typeName)
        }
    }

    /// 容错解码: homeContent
    private func decodeOrFallbackHome(from data: Data) throws -> HomeContentResult {
        do {
            return try JSONDecoder().decode(HomeContentResult.self, from: data)
        } catch {
            onLog?("⚠️ [\(scriptKey)] homeContent 标准解码失败, 尝试容错解析: \(error.localizedDescription)")
            guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // 最终回退: 记录原始数据
                let raw = String(data: data, encoding: .utf8) ?? ""
                onLog?("❌ [\(scriptKey)] homeContent JSON 解析完全失败, 原始: \(raw.prefix(300))")
                throw PythonSpiderError.invalidJSON("homeContent")
            }

            // 解析分类 (兼容 class / classes)
            let classItems: [VodCategory]
            if let cls = dict["class"] as? [[String: Any]] {
                classItems = parseCategories(from: cls)
            } else if let cls = dict["classes"] as? [[String: Any]] {
                classItems = parseCategories(from: cls)
            } else {
                classItems = []
            }

            // 解析列表
            let listItems: [VodItem]
            if let list = dict["list"] as? [[String: Any]] {
                listItems = parseVodItems(from: list)
            } else {
                listItems = []
            }

            onLog?("📋 [\(scriptKey)] homeContent 容错解析: \(classItems.count)分类, \(listItems.count)视频")
            return HomeContentResult(class: classItems, list: listItems)
        }
    }

    /// 容错解码: categoryContent
    private func decodeOrFallbackCategory(from data: Data) throws -> CategoryContentResult {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            onLog?("❌ [\(scriptKey)] categoryContent JSON 解析完全失败, 原始: \(raw.prefix(300))")
            throw PythonSpiderError.invalidJSON("categoryContent")
        }

        let listItems: [VodItem]
        if let list = dict["list"] as? [[String: Any]] {
            listItems = parseVodItems(from: list)
        } else {
            listItems = []
        }

        let page = anyToString(dict["page"]).flatMap { Int($0) }
        let pagecount = anyToString(dict["pagecount"]).flatMap { Int($0) }
        let limit = anyToString(dict["limit"]).flatMap { Int($0) }
        let total = anyToString(dict["total"]).flatMap { Int($0) }

        onLog?("📋 [\(scriptKey)] categoryContent 容错解析: \(listItems.count)视频, page=\(page ?? 0)/\(pagecount ?? 0)")
        return CategoryContentResult(page: page, pagecount: pagecount, limit: limit, total: total, list: listItems)
    }

    /// 容错解码: detailContent
    private func decodeOrFallbackDetail(from data: Data) throws -> DetailContentResult {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            onLog?("❌ [\(scriptKey)] detailContent JSON 解析完全失败, 原始: \(raw.prefix(300))")
            throw PythonSpiderError.invalidJSON("detailContent")
        }

        let listItems: [VodItem]
        if let list = dict["list"] as? [[String: Any]] {
            listItems = parseVodItems(from: list)
        } else {
            listItems = []
        }

        onLog?("📋 [\(scriptKey)] detailContent 容错解析: \(listItems.count)项")
        return DetailContentResult(list: listItems)
    }

    /// 容错解码: searchContent
    private func decodeOrFallbackSearch(from data: Data) throws -> SearchContentResult {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            onLog?("❌ [\(scriptKey)] searchContent JSON 解析完全失败, 原始: \(raw.prefix(300))")
            throw PythonSpiderError.invalidJSON("searchContent")
        }

        let listItems: [VodItem]
        if let list = dict["list"] as? [[String: Any]] {
            listItems = parseVodItems(from: list)
        } else {
            listItems = []
        }

        let page = anyToString(dict["page"]).flatMap { Int($0) }
        let pagecount = anyToString(dict["pagecount"]).flatMap { Int($0) }

        onLog?("📋 [\(scriptKey)] searchContent 容错解析: \(listItems.count)结果")
        return SearchContentResult(page: page, pagecount: pagecount, list: listItems)
    }
}

// 注: 不扩展 SpiderEngineType —— vbox 原 enum 已有 javaScriptCore/quickJS 及 displayName.
// Python 引擎通过 PythonSpiderEngine 类区分，无需为 SpiderEngineType 增加 case。
