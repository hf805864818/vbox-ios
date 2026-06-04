import Foundation

/// 订阅源管理器 — 负责加载/解析/缓存 TVBox 订阅源 JSON
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
            
            let cleanData = try cleanJSONData(data)
            let config = try JSONDecoder().decode(SubscribeConfig.self, from: cleanData)
            
            await MainActor.run {
                self.config = config
                self.isLoaded = true
                self.isLoading = false
                
                if !self.configURLs.contains(urlString) {
                    self.configURLs.append(urlString)
                    self.defaults.set(self.configURLs, forKey: self.urlsKey)
                }
                self.cacheConfig(rawData: cleanData)
            }
            
            print("✅ 加载订阅源成功: \(config.sites.count) 个站点")
            
        } catch let error as DecodingError {
            await setError("JSON解析失败: \(error.localizedDescription)")
        } catch {
            await setError("加载失败: \(error.localizedDescription)")
        }
    }
    
    func removeURL(_ url: String) {
        configURLs.removeAll { $0 == url }
        defaults.set(configURLs, forKey: urlsKey)
    }
    
    /// 清理JSON数据：去掉单行注释、提取标准JSON
    private func cleanJSONData(_ data: Data) throws -> Data {
        guard var text = String(data: data, encoding: .utf8) else {
            throw JSONError.invalidEncoding
        }
        
        // 1. 逐行处理，去掉以//开头的行
        var lines = text.components(separatedBy: "\n")
        lines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//")
        }
        text = lines.joined(separator: "\n")
        
        // 2. 找第一个{或[，去掉前面所有内容
        if let start = text.firstIndex(of: "{") {
            text = String(text[start...])
        } else if let start = text.firstIndex(of: "[") {
            text = String(text[start...])
        } else {
            throw JSONError.invalidFormat
        }
        
        // 3. 去掉行内注释(//)，但保留字符串内的
        var result = ""
        var inString = false
        var escape = false
        var i = text.startIndex
        
        while i < text.endIndex {
            let char = text[i]
            
            if escape {
                result.append(char)
                escape = false
                i = text.index(after: i)
                continue
            }
            
            if char == "\\" && inString {
                escape = true
                result.append(char)
                i = text.index(after: i)
                continue
            }
            
            if char == "\"" {
                inString = !inString
                result.append(char)
                i = text.index(after: i)
                continue
            }
            
            if char == "/" && !inString {
                let next = text.index(after: i)
                if next < text.endIndex && text[next] == "/" {
                    // 跳过到行尾
                    while i < text.endIndex && text[i] != "\n" {
                        i = text.index(after: i)
                    }
                    if i < text.endIndex {
                        result.append(text[i]) // 保留换行
                    }
                    i = text.index(after: i)
                    continue
                }
            }
            
            result.append(char)
            i = text.index(after: i)
        }
        
        guard let cleanData = result.data(using: .utf8) else {
            throw JSONError.invalidEncoding
        }
        
        return cleanData
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
    }
    
    var jsSites: [SiteConfig] { config?.sites.filter { $0.type == 3 } ?? [] }
    var apiSites: [SiteConfig] { config?.sites.filter { $0.type != 3 } ?? [] }
    var allSites: [SiteConfig] { config?.sites ?? [] }
}

enum JSONError: Error, LocalizedError {
    case invalidEncoding
    case invalidFormat
    var errorDescription: String? {
        switch self {
        case .invalidEncoding: return "编码格式错误"
        case .invalidFormat: return "JSON格式错误"
        }
    }
}
