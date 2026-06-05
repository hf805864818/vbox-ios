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
        
        // 如果有已保存的订阅源，则加载
        if subManager.isLoaded {
            await loadSitesFromSubscription()
        }
        
        // QuickJS 引擎暂不强制加载，搜索时走 nativeSearch 兜底
        print("[SpiderManager] 初始化完成，站点数: \(subManager.config?.sites.count ?? 0)")
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
        
        // 2. QuickJS 引擎暂不在这里加载，搜索时走 nativeSearch 兜底
        // 后续接入稳定数据源后再启用蜘蛛引擎
        
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
        // 当 QuickJS 引擎没加载，直接走原生搜索
        if engines.isEmpty {
            print("[SpiderManager] QuickJS 引擎未加载，走纯 Swift 搜索")
            return await nativeSearch(keyword: keyword)
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
        return all.isEmpty ? await nativeSearch(keyword: keyword) : all
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
    
    /// 纯 Swift 搜索实现 — 走 vbox.ltd Worker 搜索接口
    func nativeSearch(keyword: String) async -> [VodItem] {
        let apiURL = "https://vbox.ltd/search?wd=\(keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword)"
        guard let url = URL(string: apiURL) else { return [] }
        
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["list"] as? [[String: Any]] {
                let results = list.map { item in
                    VodItem(
                        vodId: String(describing: item["vod_id"] ?? ""),
                        vodName: (item["vod_name"] as? String) ?? "",
                        vodPic: (item["vod_pic"] as? String) ?? ""
                    )
                }
                print("[SpiderManager] nativeSearch 从 Worker 获得 \(results.count) 个结果")
                return results
            }
        } catch {
            print("[SpiderManager] nativeSearch Worker 失败: \(error.localizedDescription)")
        }
        return []
    }
}
