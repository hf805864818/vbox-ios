import Foundation

/// 订阅源管理器 — 负责加载/解析/缓存 TVBox 订阅源 JSON
/// 兼容 TVBox 标准格式和 CatVOD 扩展格式
class SubscriptionManager: ObservableObject {
    
    @Published var config: SubscribeConfig?
    @Published var isLoaded = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var configURLs: [String] = []
    
    private let defaults = UserDefaults.standard
    private let urlsKey = "subscribed_config_urls"
    private let cacheKey = "cached_subscribe_config"
    
    init() {
        // 加载已保存的 URL 列表
        configURLs = defaults.stringArray(forKey: urlsKey) ?? []
        // 加载缓存配置
        loadCachedConfig()
    }
    
    // MARK: - 加载订阅源
    
    func loadConfig(from urlString: String) async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }
        
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            await setError("无效的URL")
            return
        }
        
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                await setError("服务器返回错误")
                return
            }
            
            let rawJSON = try parseJSON(from: data)
            let config = try JSONDecoder().decode(SubscribeConfig.self, from: rawJSON)
            
            await MainActor.run {
                self.config = config
                self.isLoaded = true
                self.isLoading = false
                
                // 保存 URL
                if !self.configURLs.contains(urlString) {
                    self.configURLs.append(urlString)
                    self.defaults.set(self.configURLs, forKey: self.urlsKey)
                }
                
                // 缓存配置
                self.cacheConfig(rawData: data)
            }
            
            print("✅ 加载订阅源成功: \(config.sites.count) 个站点")
            
        } catch let error as DecodingError {
            await setError("JSON解析失败: \(error.localizedDescription)")
        } catch {
            await setError("加载失败: \(error.localizedDescription)")
        }
    }
    
    /// 移除订阅源 URL
    func removeURL(_ url: String) {
        configURLs.removeAll { $0 == url }
        defaults.set(configURLs, forKey: urlsKey)
    }
    
    // MARK: - 辅助方法
    
    private func parseJSON(from data: Data) throws -> Data {
        // TVBox 订阅源 JSON 格式标准
        // 可能是直接的 JSON，也可能是包含 Unicode escapes 的
        return data
    }
    
    private func loadCachedConfig() {
        guard let cachedData = defaults.data(forKey: cacheKey) else { return }
        do {
            let config = try JSONDecoder().decode(SubscribeConfig.self, from: cachedData)
            self.config = config
            self.isLoaded = true
        } catch {
            print("缓存配置解析失败: \(error)")
        }
    }
    
    private func cacheConfig(rawData: Data) {
        defaults.set(rawData, forKey: cacheKey)
    }
    
    @MainActor
    private func setError(_ msg: String) {
        errorMessage = msg
        isLoading = false
        print("❌ 订阅源加载失败: \(msg)")
    }
    
    // MARK: - 获取站点列表
    
    /// JS 类型站点（需要蜘蛛引擎）
    var jsSites: [SiteConfig] {
        config?.sites.filter { $0.type == 3 } ?? []
    }
    
    /// JSON/XML 类型站点（直接 HTTP 调用）
    var apiSites: [SiteConfig] {
        config?.sites.filter { $0.type != 3 } ?? []
    }
    
    var allSites: [SiteConfig] {
        config?.sites ?? []
    }
}
