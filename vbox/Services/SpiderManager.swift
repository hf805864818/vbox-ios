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
    @Published var loadedSiteCount: Int = 0
    
    private let subManager = SubscriptionManager()
    private var engines: [String: QJSSpiderEngine] = [:]
    
    private init() {}
    
    func initialize() async {
        guard !isInitialized else { return }
        isInitialized = true
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
        isLoading = false
    }
    
    private func loadSitesFromSubscription() async {
        guard let config = subManager.config else {
            errorMessage = "订阅源配置为空"
            return
        }
        
        let allSites = config.sites
        loadedSiteCount = allSites.count
        
        if allSites.isEmpty {
            errorMessage = "订阅源中没有任何站点"
            return
        }
        
        print("[SpiderManager] 订阅源: \(allSites.count) 个站点")
        
        // TVBox站点的JS蜘蛛一般通过 api 或 ext 字段获取
        // api通常是内置蜘蛛名(csp_xxx)，ext可能是jar/JS URL
        // 现在我们只处理 ext 字段是HTTP URL的站点
        var loadedCount = 0
        for site in allSites {
            // 尝试 ext 字段作为JS脚本URL
            if let jsURL = site.ext, jsURL.hasPrefix("http"), !jsURL.isEmpty {
                do {
                    try await loadSiteEngine(site: site, jsURL: jsURL)
                    loadedCount += 1
                } catch {
                    print("[SpiderManager] \(site.name) 加载失败: \(error.localizedDescription)")
                }
            }
        }
        
        print("[SpiderManager] 成功加载 \(loadedCount)/\(allSites.count) 个站点引擎")
        
        await loadHomeData()
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
            print("[SpiderManager] ✅ \(site.name)")
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
        var all: [VodItem] = []
        for (_, engine) in engines {
            do { if let items = try engine.callSearchContent(keyword: keyword, pg: pg).list { all.append(contentsOf: items) } } catch { continue }
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
    }
    func removeSubscriptionURL(_ url: String) { subManager.removeURL(url) }
}
