import Foundation

/// 蜘蛛仓库 — 管理多站点的蜘蛛引擎，支持订阅源配置
class SpiderRepository {
    
    // 蜘蛛引擎实例（每个JS站点一个引擎）
    private var engines: [String: JSSpiderEngine] = [:]
    
    // 注册的站点列表
    private(set) var sites: [SiteConfig] = []
    
    var onLog: ((String) -> Void)?
    
    init() {}
    
    // MARK: - 订阅源管理
    
    /// 加载订阅源配置（TVBox JSON格式）
    func loadSubscribeConfig(from urlString: String) async throws {
        guard let url = URL(string: urlString) else {
            throw JSError(message: "无效订阅URL: \(urlString)")
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        let config = try JSONDecoder().subscribeConfig(from: data)
        
        self.sites = config.sites
        onLog?("✅ 加载订阅源: \(config.sites.count) 个站点")
        
        // 初始化JS类型的站点引擎
        for site in config.sites where site.type == 3 {
            if let extURL = site.ext, !extURL.isEmpty {
                try await initSiteEngine(siteKey: site.key, jsURL: extURL)
            }
        }
    }
    
    /// 从本地JSON字符串加载订阅源配置
    func loadSubscribeConfigFromJSON(_ jsonString: String) throws {
        guard let data = jsonString.data(using: .utf8) else {
            throw JSError(message: "JSON编码失败")
        }
        let config = try JSONDecoder().subscribeConfig(from: data)
        self.sites = config.sites
        onLog?("✅ 加载订阅源: \(config.sites.count) 个站点")
    }
    
    /// 初始化一个JS站点的引擎
    private func initSiteEngine(siteKey: String, jsURL: String) async throws {
        let engine = JSSpiderEngine()
        engine.onLog = { [weak self] msg in
            self?.onLog?("[\(siteKey)] \(msg)")
        }
        
        // 加载JS蜘蛛脚本
        try await engine.loadScriptFromURL(jsURL)
        
        // 注册蜘蛛
        try engine.registerSpider()
        
        engines[siteKey] = engine
        onLog?("✅ 站点引擎初始化: \(siteKey)")
    }
    
    /// 手动注册一个引擎（用于测试蜘蛛.js）
    func registerEngine(siteKey: String, engine: JSSpiderEngine) {
        engines[siteKey] = engine
        sites.append(SiteConfig(
            key: siteKey,
            name: siteKey,
            type: 3,
            api: nil,
            searchable: 2,
            quickSearch: 0,
            filterable: 0,
            ext: nil,
            playerType: nil
        ))
    }
    
    // MARK: - 搜索
    
    /// 全站搜索（并行搜索所有JS站点）
    func searchAll(keyword: String, pg: Int = 1) async -> [(siteKey: String, results: [VodItem])] {
        var allResults: [(String, [VodItem])] = []
        
        await withTaskGroup(of: (String, [VodItem])?.self) { group in
            for (siteKey, engine) in engines {
                group.addTask {
                    do {
                        let result = try engine.callSearchContent(keyword: keyword, pg: pg)
                        return (siteKey, result.list ?? [])
                    } catch {
                        return (siteKey, [])
                    }
                }
            }
            
            for await outcome in group {
                if let (key, items) = outcome {
                    allResults.append((key, items))
                }
            }
        }
        
        return allResults
    }
    
    // MARK: - 站点操作
    
    func getEngine(for siteKey: String) -> JSSpiderEngine? {
        return engines[siteKey]
    }
    
    func getSite(byKey key: String) -> SiteConfig? {
        return sites.first { $0.key == key }
    }
}

// MARK: - JSONDecoder 扩展
extension JSONDecoder {
    func subscribeConfig(from data: Data) throws -> SubscribeConfig {
        return try decode(SubscribeConfig.self, from: data)
    }
}
