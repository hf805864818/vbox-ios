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
            
            // 直接用简单的正则清理
            guard var rawText = String(data: data, encoding: .utf8) else {
                await setError("编码错误")
                return
            }
            
            print("[SubManager] 原始数据: \(rawText.count) 字符")
            
            // 去注释：用逐行过滤
            var lines = rawText.components(separatedBy: "\n")
            var cleanLines: [String] = []
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.hasPrefix("//") {
                    // 去掉行内注释
                    if let commentPos = line.range(of: "//") {
                        // 检查commentPos是否在字符串外
                        let beforeComment = String(line[..<commentPos.lowerBound])
                        if beforeComment.filter({ $0 == "\"" }).count % 2 == 0 {
                            cleanLines.append(String(line[..<commentPos.lowerBound]))
                        } else {
                            cleanLines.append(line)
                        }
                    } else {
                        cleanLines.append(line)
                    }
                }
            }
            rawText = cleanLines.joined(separator: "\n")
            
            // 找JSON起始
            if let start = rawText.firstIndex(of: "{") {
                rawText = String(rawText[start...])
            }
            
            print("[SubManager] 清理后: \(rawText.count) 字符")
            
            guard let jsonData = rawText.data(using: .utf8) else {
                await setError("编码错误")
                return
            }
            
            // 用更宽松的方式解析
            do {
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
                print("[SubManager] 加载成功: \(config.sites.count) 个站点")
            } catch let DecodingError.dataCorrupted(context) {
                let debug = context.debugDescription
                let codingPath = context.codingPath.map { $0.stringValue }.joined(separator: ".")
                await setError("JSON解析失败: \(debug)\n路径: \(codingPath)")
            } catch let DecodingError.keyNotFound(key, context) {
                await setError("缺少字段: \(key.stringValue)")
            } catch let DecodingError.typeMismatch(type, context) {
                let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
                await setError("类型不匹配: \(type) at \(path)")
            } catch let DecodingError.valueNotFound(type, context) {
                await setError("值为空: \(type)")
            } catch {
                await setError("解析失败: \(error.localizedDescription)")
            }
        } catch {
            await setError("加载失败: \(error.localizedDescription)")
        }
    }
    
    func removeURL(_ url: String) {
        configURLs.removeAll { $0 == url }
        defaults.set(configURLs, forKey: urlsKey)
    }
    
    private func loadCachedConfig() {
        guard let cachedData = defaults.data(forKey: cacheKey) else { return }
        do { self.config = try JSONDecoder().decode(SubscribeConfig.self, from: cachedData); isLoaded = true } catch { print("缓存解析失败: \(error)") }
    }
    
    private func cacheConfig(rawData: Data) { defaults.set(rawData, forKey: cacheKey) }
    
    @MainActor private func setError(_ msg: String) { errorMessage = msg; isLoading = false }
    
    var jsSites: [SiteConfig] { config?.sites.filter { $0.type == 3 } ?? [] }
    var apiSites: [SiteConfig] { config?.sites.filter { $0.type != 3 } ?? [] }
    var allSites: [SiteConfig] { config?.sites ?? [] }
}

enum JSONError: Error, LocalizedError {
    case invalidEncoding
    case invalidFormat
    var errorDescription: String? {
        switch self { case .invalidEncoding: return "编码格式错误"; case .invalidFormat: return "JSON格式错误" }
    }
}
