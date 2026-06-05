import Foundation
import SwiftUI

/// 蜘蛛管理器 — 统一管理订阅源加载、蜘蛛引擎、数据获取
@MainActor
class SpiderManager: ObservableObject {
    
    static let shared = SpiderManager()
    
    @Published var categories: [VodCategory] = []
    @Published var homeVideos: [VodItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isInitialized = false
    @Published var subscribedSites: [String] = []
    @Published var savedURLs: [String] = []
    @Published var loadedSiteCount: Int = 0
    @Published var allSites: [SiteConfig] = []
    @Published var engineError: String?
    var enginesCount: Int { engines.count }
    
    private let subManager = SubscriptionManager()
    private var engines: [String: QJSSpiderEngine] = [:]
    
    private init() {
        savedURLs = subManager.configURLs
    }
    
    func initialize() async {
        guard !isInitialized else { return }
        isInitialized = true
        
        // 尝试加载 QuickJS 内置蜘蛛
        await loadBuiltinEngineIfNeeded()
        
        // 如果有已保存的订阅源，则加载
        if subManager.isLoaded {
            await loadSitesFromSubscription()
        }
        
        print("[SpiderManager] 初始化完成，引擎数: \(engines.count), 站点数: \(subManager.config?.sites.count ?? 0)")
    }
    
    /// 加载内置 QuickJS 蜘蛛引擎
    private func loadBuiltinEngineIfNeeded() async {
        guard engines["builtin"] == nil else { return }
        do {
            try await loadSpiderEngine(jsCode: getBuiltinSpiderJS())
            print("[SpiderManager] ✅ 内置蜘蛛加载成功")
        } catch {
            engineError = "蜘蛛加载失败: \(error.localizedDescription)"
            print("[SpiderManager] ❌ 内置蜘蛛加载失败: \(error.localizedDescription)")
        }
    }
    
    /// 获取内置蜘蛛 JS 代码（最简版）
    private func getBuiltinSpiderJS() -> String {
        return "var _spider = { homeContent: function() { return JSON.stringify({ class: [], list: [] }); }, searchContent: function(k, p) { return JSON.stringify({ list: [] }); }, detailContent: function(id) { return JSON.stringify({ list: [] }); }, playerContent: function(v,f,u) { return JSON.stringify({ parse: 0, url: u }); } }; globalThis.__JS_SPIDER__ = _spider;"
    }
    
    func loadSubscribeConfig(from url: String) async {
        isLoading = true
        errorMessage = nil
        await subManager.loadConfig(from: url)
        if let error = subManager.errorMessage {
            errorMessage = error
            isLoading = false
            return
        }
        await loadSitesFromSubscription()
        savedURLs = subManager.configURLs
        isLoading = false
    }
    
    private func loadSitesFromSubscription() async {
        guard let config = subManager.config else {
            errorMessage = "订阅源配置为空"
            return
        }
        
        self.allSites = config.sites
        loadedSiteCount = allSites.count
        
        // 1. 尝试从订阅源的 spider 字段加载 JS 蜘蛛
        var spiderLoaded = false
        if let spiderURL = config.spider, spiderURL.hasPrefix("http") {
            do {
                let rawData = try await downloadRawData(url: spiderURL)
                if let snippet = String(data: rawData, encoding: .utf8),
                   snippet.count > 100,
                   snippet.contains("function ") || snippet.contains("var ") || snippet.contains("let ") || snippet.contains("const ") {
                    try await loadSpiderEngine(jsCode: snippet)
                    spiderLoaded = true
                    print("[SpiderManager] ✅ 远程蜘蛛加载成功")
                } else {
                    print("[SpiderManager] spider URL 不是纯 JS（可能是 jar 包），使用内置蜘蛛")
                }
            } catch {
                print("[SpiderManager] spider URL 加载失败: \(error.localizedDescription)")
            }
        }
        
        // 2. 尝试加载每个站点的 ext 字段（如果是 JS 的话）
        for site in allSites where site.key != "builtin" {
            if let jsURL = site.ext, jsURL.hasPrefix("http"), !jsURL.isEmpty {
                do {
                    let rawData = try await downloadRawData(url: jsURL)
                    if let snippet = String(data: rawData, encoding: .utf8),
                       snippet.count > 200,
                       snippet.contains("function ") || snippet.contains("spider") {
                        try await loadSiteEngine(site: site, jsURL: jsURL)
                    }
                } catch { /* 静默跳过 */ }
            }
        }
        
        print("[SpiderManager] 蜘蛛引擎: \(spiderLoaded ? "✅" : "❌"), 引擎数: \(engines.count)")
        await loadHomeData()
    }
    
    /// 加载蜘蛛 JS 到引擎
    private func loadSpiderEngine(jsCode: String) async throws {
        let engine = QJSSpiderEngine()
        engine.onLog = { msg in
            print("[SpiderEngine] \(msg)")
            if msg.contains("❌") || msg.contains("异常") || msg.contains("失败") {
                Task { @MainActor in self.engineError = msg }
            }
        }
        try engine.loadScript(jsCode)
        if engine.registerSpider() {
            engines["builtin"] = engine
            if !subscribedSites.contains("builtin") {
                subscribedSites.append("builtin")
            }
            engineError = nil
        } else {
            let err = "蜘蛛注册失败: __JS_SPIDER__ 未找到"
            engineError = err
            throw QJSError(message: err)
        }
    }
    
    private func downloadRawData(url: String) async throws -> Data {
        guard let urlObj = URL(string: url) else {
            throw QJSError(message: "无效URL: \(url)")
        }
        let (data, _) = try await URLSession.shared.data(from: urlObj)
        return data
    }
    
    private func loadSiteEngine(site: SiteConfig, jsURL: String) async throws {
        let engine = QJSSpiderEngine()
        let jsCode = try await downloadScript(url: jsURL)
        try engine.loadScript(jsCode)
        if engine.registerSpider() {
            engines[site.key] = engine
            if !subscribedSites.contains(site.key) {
                subscribedSites.append(site.key)
            }
            print("[SpiderManager] ✅ ext站点: \(site.name)")
        }
    }
    
    private func downloadScript(url: String) async throws -> String {
        guard let urlObj = URL(string: url) else {
            throw QJSError(message: "无效脚本URL: \(url)")
        }
        let (data, _) = try await URLSession.shared.data(from: urlObj)
        guard let script = String(data: data, encoding: .utf8) else {
            throw QJSError(message: "脚本编码错误")
        }
        return script
    }
    
    func loadHomeData() async {
        guard !engines.isEmpty else {
            print("[SpiderManager] 没有引擎，无法加载首页")
            return
        }
        if let (_, engine) = engines.first {
            do {
                let result = try engine.callHomeContent()
                self.categories = result.class ?? []
                self.homeVideos = result.list ?? []
                print("[SpiderManager] 首页: \(homeVideos.count)视频 \(categories.count)分类")
            } catch {
                print("[SpiderManager] 首页失败: \(error.localizedDescription)")
            }
        }
    }
    
    func search(keyword: String, pg: Int = 1) async -> [VodItem] {
        // 先尝试加载内置蜘蛛
        if engines.isEmpty {
            await loadBuiltinEngineIfNeeded()
        }
        
        // 如果 QuickJS 引擎加载成功，用 QuickJS 搜索
        for (_, engine) in engines {
            do {
                if let items = try engine.callSearchContent(keyword: keyword, pg: pg).list {
                    return items
                }
            } catch {
                engineError = "搜索出错: \(error.localizedDescription)"
                print("[SpiderManager] QuickJS 搜索失败: \(error)")
            }
        }
        
        // QuickJS 失败或未加载，走纯 Swift 搜索
        return await nativeSearch(keyword: keyword)
    }
    
    func getDetail(ids: String) async -> VodItem? {
        for (_, engine) in engines {
            do { return try engine.callDetailContent(ids: ids).list?.first } catch { continue }
        }
        return nil
    }
    
    func getPlayerContent(vodId: String, flag: String = "play", url: String) async -> PlayerContentResult? {
        for (_, engine) in engines {
            do { return try engine.callPlayerContent(vodId: vodId, flag: flag, url: url) } catch { continue }
        }
        return nil
    }
    
    func getSavedSubscriptionURLs() -> [String] { subManager.configURLs }
    func saveSubscriptionURL(_ url: String) {
        subManager.configURLs.append(url)
        UserDefaults.standard.set(subManager.configURLs, forKey: "subscribed_config_urls")
        savedURLs = subManager.configURLs
    }
    func removeSubscriptionURL(_ url: String) {
        subManager.removeURL(url)
        savedURLs = subManager.configURLs
    }
    
    /// 纯 Swift 搜索实现 — 多源搜索 + 聚合
    func nativeSearch(keyword: String) async -> [VodItem] {
        var allResults: [VodItem] = []
        var seenIds = Set<String>()
        
        // 数据源1: vbox.ltd Worker 搜索接口
        let workerURL = "https://vbox.ltd/search?wd=\(keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword)"
        if let results = await searchWithAPI(url: workerURL) {
            for item in results {
                let id = item.vodId.isEmpty ? item.vodName : item.vodId
                if !seenIds.contains(id) {
                    seenIds.insert(id)
                    allResults.append(item)
                }
            }
        }
        
        // 数据源2: DPlayer 搜索接口 (备用)
        let dplayerURL = "https://dplayer.video/api/search?keyword=\(keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword)"
        if let results = await searchWithAPI(url: dplayerURL, fieldMap: ["vod_id": "id", "vod_name": "title", "vod_pic": "cover"]) {
            for item in results {
                let id = item.vodId.isEmpty ? item.vodName : item.vodId
                if !seenIds.contains(id) {
                    seenIds.insert(id)
                    allResults.append(item)
                }
            }
        }
        
        // 数据源3: 从已加载站点进行筛选搜索
        if !allSites.isEmpty {
            for site in allSites {
                guard let api = site.api, !api.isEmpty else { continue }
                let siteURL = api.replacingOccurrences(of: "{wd}", with: keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword)
                    .replacingOccurrences(of: "{keyword}", with: keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword)
                if let results = await searchWithAPI(url: siteURL) {
                    for item in results {
                        let id = item.vodId.isEmpty ? item.vodName : item.vodId
                        if !seenIds.contains(id), seenIds.count < 50 {
                            seenIds.insert(id)
                            allResults.append(item)
                        }
                    }
                }
            }
        }
        
        print("[SpiderManager] nativeSearch 获得 \(allResults.count) 个结果 (来自 \(seenIds.count) 个独立源)")
        return allResults
    }
    
    /// 通用 JSON 搜索接口调用
    private func searchWithAPI(url: String, fieldMap: [String: String] = [:]) async -> [VodItem]? {
        guard let urlObj = URL(string: url) else { return nil }
        var req = URLRequest(url: urlObj)
        req.timeoutInterval = 10
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            
            // 尝试多种 JSON 结构
            var list: [[String: Any]]? = nil
            
            // 结构1: { "list": [...] }
            if let l = json["list"] as? [[String: Any]] { list = l }
            // 结构2: { "data": { "list": [...] } }
            else if let dataObj = json["data"] as? [String: Any], let l = dataObj["list"] as? [[String: Any]] { list = l }
            // 结构3: { "videos": [...] }
            else if let l = json["videos"] as? [[String: Any]] { list = l }
            // 结构4: { "data": [...] }
            else if let l = json["data"] as? [[String: Any]] { list = l }
            // 结构5: { "results": [...] }
            else if let l = json["results"] as? [[String: Any]] { list = l }
            // 结构6: [ ... ] (直接数组)
            else if let l = json as? [[String: Any]] { list = l; return l.map { mapVodItem($0, fieldMap: fieldMap) } }
            
            guard let items = list else { return nil }
            return items.map { mapVodItem($0, fieldMap: fieldMap) }
        } catch {
            return nil
        }
    }
    
    private func mapVodItem(_ item: [String: Any], fieldMap: [String: String]) -> VodItem {
        let idField = fieldMap["vod_id"] ?? "vod_id"
        let nameField = fieldMap["vod_name"] ?? "vod_name"
        let picField = fieldMap["vod_pic"] ?? "vod_pic"
        return VodItem(
            vodId: String(describing: item[idField] ?? item["id"] ?? ""),
            vodName: (item[nameField] as? String) ?? (item["title"] as? String) ?? (item["name"] as? String) ?? "",
            vodPic: (item[picField] as? String) ?? (item["cover"] as? String) ?? (item["image"] as? String) ?? (item["pic"] as? String) ?? ""
        )
    }
}
