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
    var enginesCount: Int { engines.count }
    
    private let subManager = SubscriptionManager()
    private var engines: [String: QJSSpiderEngine] = [:]
    
    private init() {
        savedURLs = subManager.configURLs
    }
    
    func initialize() async {
        guard !isInitialized else { return }
        isInitialized = true
        
        // 始终先加载内置蜘蛛，确保搜索和首页立即可用
        do {
            try await loadSpiderEngine(jsCode: getBuiltinSpiderJS())
            print("[SpiderManager] ✅ 内置蜘蛛启动加载成功")
            // 试加载首页
            await loadHomeData()
        } catch {
            print("[SpiderManager] ❌ 内置蜘蛛启动加载失败: \(error.localizedDescription)")
            errorMessage = "蜘蛛引擎加载失败: \(error.localizedDescription)"
        }
        
        // 如果有已保存的订阅源，则加载
        if subManager.isLoaded {
            await loadSitesFromSubscription()
        }
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
        
        // 2. 如果还没有内置蜘蛛，使用内置蜘蛛
        if engines["builtin"] == nil, !spiderLoaded {
            print("[SpiderManager] 使用内置蜘蛛引擎")
            let builtinSite = SiteConfig(key: "builtin", name: "内置搜索", type: 3, api: "builtin", ext: nil)
            self.allSites.insert(builtinSite, at: 0)
            loadedSiteCount = allSites.count
            do {
                try await loadSpiderEngine(jsCode: getBuiltinSpiderJS())
                spiderLoaded = true
                print("[SpiderManager] ✅ 内置蜘蛛加载成功")
            } catch {
                print("[SpiderManager] ❌ 内置蜘蛛加载失败: \(error.localizedDescription)")
                errorMessage = "蜘蛛加载失败"
            }
        }
        
        // 3. 尝试加载每个站点的 ext 字段（如果是 JS 的话）
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
        engine.onLog = { msg in print("[SpiderEngine] \(msg)") }
        try engine.loadScript(jsCode)
        if engine.registerSpider() {
            engines["builtin"] = engine
            if !subscribedSites.contains("builtin") {
                subscribedSites.append("builtin")
            }
        } else {
            throw QJSError(message: "蜘蛛注册失败")
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
        // 如果引擎为空，尝试实时加载内置蜘蛛（最多重试3次）
        if engines.isEmpty {
            for attempt in 1...3 {
                do {
                    try await loadSpiderEngine(jsCode: getBuiltinSpiderJS())
                    if let engine = engines["builtin"] {
                        // 验证引擎真的能用
                        if let result = try? engine.callHomeContent(), (result.list?.count ?? 0) > 0 {
                            print("[SpiderManager] 搜索时第\(attempt)次加载内置蜘蛛成功，首页\(result.list?.count ?? 0)个视频")
                            break
                        }
                    }
                    print("[SpiderManager] 搜索时第\(attempt)次加载蜘蛛引擎但验证失败，重试...")
                    engines.removeValue(forKey: "builtin")
                } catch {
                    print("[SpiderManager] 搜索时第\(attempt)次加载内置蜘蛛失败: \(error.localizedDescription)")
                    engines.removeValue(forKey: "builtin")
                }
            }
        }
        
        if engines.isEmpty {
            print("[SpiderManager] 引擎全部加载失败，返回空结果")
            return []
        }
        
        var all: [VodItem] = []
        for (_, engine) in engines {
            do {
                if let items = try engine.callSearchContent(keyword: keyword, pg: pg).list {
                    all.append(contentsOf: items)
                }
            } catch {
                print("[SpiderManager] 搜索引擎错误: \(error.localizedDescription)")
                continue
            }
        }
        return all
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
    
    /// 内置蜘蛛 JS 代码
    private func getBuiltinSpiderJS() -> String {
        return "var _spider = { homeContent: function() { return JSON.stringify({ class: [{ type_id: '1', type_name: '电影' }], list: [] }); }, searchContent: function(k, p) { var r = JSON.parse(http('https://json.im30.app/vod/?ac=videolist&wd='+encodeURIComponent(k)+'&pg='+(p||1), '{}')); var l = r && r.list ? r.list.map(function(i) { return { vod_id: String(i.vod_id||''), vod_name: i.vod_name||'', vod_pic: i.vod_pic||'' }; }) : []; return JSON.stringify({ list: l }); }, detailContent: function(id) { return JSON.stringify({ list: [] }); }, playerContent: function(vid,f,url) { return JSON.stringify({ parse: 0, url: url, header: {} }); } }; globalThis.__JS_SPIDER__ = _spider; globalThis.__JS_SPIDER__.is_cat = true;"
    }
}
