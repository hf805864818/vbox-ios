import Foundation

class SubscriptionManager: ObservableObject {
    @Published var config: SubscribeConfig?
    @Published var isLoaded = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var configURLs: [String] = []
    @Published var parses: [ParseConfig] = []  // 解析器列表
    
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
            
            // 清理注释和非 JSON 前缀
            var lines = text.components(separatedBy: "\n")
            lines = lines.filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // 过滤整行注释，但要小心不要过滤了 http:// 之类的行
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") {
                    return false
                }
                return true
            }
            text = lines.joined(separator: "\n")
            
            // 找第一个 { 或 [
            if let brace = text.firstIndex(where: { $0 == "{" || $0 == "[" }) {
                text = String(text[brace...])
            }
            
            // 检测是否是 HTML（而非 JSON）
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("<!doctype") || trimmed.lowercased().hasPrefix("<html") || trimmed.lowercased().hasPrefix("<!") {
                await setError("该地址返回的是网页，不是JSON配置")
                return
            }
            
            guard let jsonData = text.data(using: .utf8) else {
                await setError("编码错误")
                return
            }
            
            // 尝试解析，先 strict=true 再 strict=false
            var parsedJSON: [String: Any]?
            do {
                if let jsonObj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    parsedJSON = jsonObj
                }
            } catch {
                // strict=false 允许控制字符
                if let jsonObj = try? JSONSerialization.jsonObject(with: jsonData, options: .fragmentsAllowed) as? [String: Any] {
                    parsedJSON = jsonObj
                } else {
                    let preview = String(text.prefix(200))
                    print("[SubscriptionManager] JSON 解析失败, 前200字符: \(preview)")
                    await setError("无效JSON: \(error.localizedDescription)")
                    return
                }
            }
            
            guard let jsonDict = parsedJSON else {
                await setError("无效JSON格式")
                return
            }
            
            // 重新编码为干净 JSON 再用 JSONDecoder 解码
            let cleanData = try JSONSerialization.data(withJSONObject: jsonDict)
            let config = try JSONDecoder().decode(SubscribeConfig.self, from: cleanData)
            
            // 提取解析器配置
            let parses = jsonDict["parses"] as? [[String: Any]] ?? []
            var parseConfigs: [ParseConfig] = []
            for parse in parses {
                if let name = parse["name"] as? String,
                   let url = parse["url"] as? String {
                    let type = parse["type"] as? Int
                    parseConfigs.append(ParseConfig(name: name, url: url, type: type))
                }
            }
            
            await MainActor.run {
                self.config = config
                self.parses = parseConfigs
                self.isLoaded = true
                self.isLoading = false
                if !self.configURLs.contains(urlString) {
                    self.configURLs.append(urlString)
                    self.defaults.set(self.configURLs, forKey: self.urlsKey)
                }
                self.cacheConfig(rawData: jsonData)
                print("[SubscriptionManager] ✅ 加载 \(parseConfigs.count) 个解析器")
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
