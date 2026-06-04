import Foundation

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
        configURLs = defaults.stringArray(forKey: urlsKey) ?? []
        loadCachedConfig()
    }
    
    func loadConfig(from urlString: String) async {
        await MainActor.run { isLoading = true; errorMessage = nil }
        
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
                await setError("服务器返回错误: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return
            }
            
            // 转为字符串
            guard var text = String(data: data, encoding: .utf8) else {
                await setError("编码错误")
                return
            }
            
            // 快速清理：去//行，去//后缀
            var lines = text.components(separatedBy: "\n")
            lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            // 去行尾注释（简单版-找不在字符串里的//）
            lines = lines.map { line in
                guard let range = line.range(of: "//") else { return line }
                let before = String(line[..<range.lowerBound])
                if before.filter({ $0 == "\"" }).count % 2 == 0 {
                    return before
                }
                return line
            }
            text = lines.joined(separator: "\n")
            
            // 找第一个{
            if let idx = text.firstIndex(of: "{") {
                text = String(text[idx...])
            }
            
            guard let jsonData = text.data(using: .utf8) else {
                await setError("编码错误")
                return
            }
            
            // 验证是否是有效JSON
            do {
                let _ = try JSONSerialization.jsonObject(with: jsonData)
            } catch {
                // 打印前200字符帮助debug
                let preview = text.prefix(200)
                await setError("无效JSON: \(error.localizedDescription)")
                return
            }
            
            // 解析为SubscribeConfig
            let config = try JSONDecoder().decode(SubscribeConfig.self, from: jsonData)
            
            await MainActor.run {
                self.config = config
                self.isLoaded = true
                self.isLoading = false
                if !self.configURLs.contains(urlString) {
                    self.configURLs.append(urlString)
                    self.defaults.set(self.configURLs, forKey: self.urlsKey)
                }
                self.cacheConfig(rawData: jsonData)
            }
            
        } catch {
            await setError("\(error.localizedDescription)")
        }
    }
    
    func removeURL(_ url: String) {
        configURLs.removeAll { $0 == url }
        defaults.set(configURLs, forKey: urlsKey)
    }
    
    private func loadCachedConfig() {
        guard let data = defaults.data(forKey: cacheKey) else { return }
        do { config = try JSONDecoder().decode(SubscribeConfig.self, from: data); isLoaded = true } catch {}
    }
    
    private func cacheConfig(rawData: Data) { defaults.set(rawData, forKey: cacheKey) }
    
    @MainActor private func setError(_ msg: String) { errorMessage = msg; isLoading = false }
    
    var jsSites: [SiteConfig] { config?.sites.filter { $0.type == 3 } ?? [] }
    var apiSites: [SiteConfig] { config?.sites.filter { $0.type != 3 } ?? [] }
    var allSites: [SiteConfig] { config?.sites ?? [] }
}
