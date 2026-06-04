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
    
    private let subManager = SubscriptionManager()
    private var engines: [String: QJSSpiderEngine] = [:]
    private let fileManager = FileManager.default
    private let jsCacheDir = "vbox_js_cache"
    
    private init() {}
    
    /// 初始化引擎
    func initialize() async {
        guard !isInitialized else { return }
        isInitialized = true
        onLog("蜘蛛管理器初始化")
        
        // 检查是否有已缓存的订阅源配置
        if subManager.isLoaded {
            await loadSitesFromSubscription()
        }
    }
    
    /// 加载订阅源
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
    
    /// 从订阅源加载站点
    private func loadSitesFromSubscription() async {
        guard let config = subManager.config else { return }
        
        for site in config.sites where site.type == 3 {
            if let extURL = site.ext, !extURL.isEmpty {
                do {
                    try await loadSiteEngine(site: site, jsURL: extURL)
                } catch {
                    onLog("站点 \(site.name) 引擎加载失败: \(error.localizedDescription)")
                }
            }
        }
        
        // 尝试加载首页数据
        await loadHomeData()
    }
    
    /// 加载单个站点的JS引擎
    private func loadSiteEngine(site: SiteConfig, jsURL: String) async throws {
        let engine = QJSSpiderEngine()
        engine.onLog = { [weak self] msg in
            print("[\(site.key)] \(msg)")
        }
        
        // 下载JS脚本
        let jsCode = try await downloadScript(url: jsURL)
        
        // 加载到引擎
        try engine.loadScript(jsCode)
        
        // 注册蜘蛛
        if engine.registerSpider() {
            engines[site.key] = engine
            if !subscribedSites.contains(site.key) {
                subscribedSites.append(site.key)
            }
            onLog("✅ 站点 \(site.name) 引擎就绪")
        } else {
            onLog("⚠️ 站点 \(site.name) 注册蜘蛛失败")
        }
    }
    
    /// 下载JS脚本
    private func downloadScript(url: String) async throws -> String {
        guard let urlObj = URL(string: url) else {
            throw QJSError(message: "无效的脚本URL: \(url)")
        }
        
        let (data, _) = try await URLSession.shared.data(from: urlObj)
        guard let script = String(data: data, encoding: .utf8) else {
            throw QJSError(message: "脚本编码错误: \(url)")
        }
        
        return script
    }
    
    // MARK: - 数据获取
    
    /// 加载首页数据（从所有已加载引擎获取）
    func loadHomeData() async {
        guard !engines.isEmpty else {
            onLog("没有已加载的引擎，无法获取首页数据")
            return
        }
        
        // 取第一个引擎的首页数据
        if let (_, engine) = engines.first {
            do {
                let result = try engine.callHomeContent()
                self.categories = result.class ?? []
                self.homeVideos = result.list ?? []
                onLog("✅ 加载首页数据: \(homeVideos.count) 个视频, \(categories.count) 个分类")
            } catch {
                onLog("⚠️ 首页加载失败: \(error.localizedDescription)")
            }
        }
    }
    
    /// 搜索
    func search(keyword: String, pg: Int = 1) async -> [VodItem] {
        var allResults: [VodItem] = []
        
        for (_, engine) in engines {
            do {
                let result = try engine.callSearchContent(keyword: keyword, pg: pg)
                if let items = result.list {
                    allResults.append(contentsOf: items)
                }
            } catch {
                onLog("搜索失败: \(error.localizedDescription)")
            }
        }
        
        return allResults
    }
    
    /// 获取详情
    func getDetail(ids: String) async -> VodItem? {
        for (_, engine) in engines {
            do {
                let result = try engine.callDetailContent(ids: ids)
                return result.list?.first
            } catch {
                continue
            }
        }
        return nil
    }
    
    /// 获取播放地址
    func getPlayerContent(vodId: String, flag: String = "play", url: String) async -> PlayerContentResult? {
        for (_, engine) in engines {
            do {
                return try engine.callPlayerContent(vodId: vodId, flag: flag, url: url)
            } catch {
                continue
            }
        }
        return nil
    }
    
    /// 获取已保存的订阅源URL列表
    func getSavedSubscriptionURLs() -> [String] {
        return subManager.configURLs
    }
    
    /// 保存订阅源URL
    func saveSubscriptionURL(_ url: String) {
        subManager.configURLs.append(url)
        UserDefaults.standard.set(subManager.configURLs, forKey: "subscribed_config_urls")
    }
    
    /// 删除订阅源URL
    func removeSubscriptionURL(_ url: String) {
        subManager.removeURL(url)
    }
    
    // MARK: - 工具
    
    private func onLog(_ msg: String) {
        print("[SpiderManager] \(msg)")
    }
}
