import Foundation
import Combine

class SubscriptionManager: ObservableObject {
    @Published var config: SubscribeConfig?
    @Published var isLoaded = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var configURLs: [String] = []
    @Published var parses: [ParseConfig] = []  // 解析器列表
    @Published var activeURLIndex: Int = 0   // 当前激活的订阅源索引

    private let defaults = UserDefaults.standard
    private let urlsKey = "subscribed_config_urls"
    private let activeKey = "active_subscription_index"
    private let cacheKey = "cached_subscribe_config"

    init() {
        configURLs = defaults.stringArray(forKey: urlsKey) ?? []
        activeURLIndex = defaults.integer(forKey: activeKey)
        if activeURLIndex >= configURLs.count { activeURLIndex = 0 }
        loadCachedConfig()
    }

    /// 当前激活的订阅源 URL
    var activeURL: String? {
        guard activeURLIndex >= 0, activeURLIndex < configURLs.count else { return nil }
        return configURLs[activeURLIndex]
    }

    /// 切换到指定索引的订阅源
    func switchToSubscription(at index: Int) {
        guard index >= 0, index < configURLs.count, index != activeURLIndex else { return }
        activeURLIndex = index
        defaults.set(index, forKey: activeKey)
        // 清空当前配置，触发重新加载
        config = nil
        isLoaded = false
        parses = []
    }

    /// 删除指定订阅源
    func removeURL(_ url: String) {
        let wasActive = (activeURLIndex >= 0 && activeURLIndex < configURLs.count && configURLs[activeURLIndex] == url)
        configURLs.removeAll { $0 == url }
        defaults.set(configURLs, forKey: urlsKey)
        if activeURLIndex >= configURLs.count {
            activeURLIndex = max(0, configURLs.count - 1)
            defaults.set(activeURLIndex, forKey: activeKey)
        }
        // 如果删除的是当前激活的订阅源或所有订阅源已清空，重置缓存
        if wasActive || configURLs.isEmpty {
            config = nil
            isLoaded = false
        }
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
            // 先用标准浏览器 UA，部分站点需要特定 UA 才能返回 JSON
            let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            let appUA = "okhttp/4.9.3"
            request.setValue(desktopUA, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                await setError("服务器返回错误: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return
            }

            // 检查响应是否为 HTML，如果是则用 App UA 重试（菜妮丝等站点需要）
            var responseData = data
            if let checkStr = String(data: data, encoding: .utf8) {
                let trimmed = checkStr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trimmed.hasPrefix("<!doctype") || trimmed.hasPrefix("<html") {
                    print("[SubscriptionManager] 收到 HTML 响应，尝试 App UA 重试...")
                    var retryRequest = URLRequest(url: url)
                    retryRequest.timeoutInterval = 15
                    retryRequest.setValue(appUA, forHTTPHeaderField: "User-Agent")
                    if let retryData = try? await URLSession.shared.data(for: retryRequest),
                       let retryStr = String(data: retryData.0, encoding: .utf8) {
                        let retryTrimmed = retryStr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if !retryTrimmed.hasPrefix("<!doctype") && !retryTrimmed.hasPrefix("<html") {
                            responseData = retryData.0
                            print("[SubscriptionManager] ✅ App UA 重试成功")
                        } else {
                            print("[SubscriptionManager] App UA 仍然返回 HTML，放弃")
                        }
                    }
                }
            }

            // 转为字符串
            guard var text = String(data: responseData, encoding: .utf8) else {
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
            
            // 尝试标准格式解码
            var config: SubscribeConfig?
            do {
                config = try JSONDecoder().decode(SubscribeConfig.self, from: cleanData)
            } catch {
                // 标准格式失败，尝试 dynew.json 格式（apiyuan/zhanyuan）
                print("[SubscriptionManager] 标准格式解码失败，尝试 apiyuan 格式...")
            }

            // 如果标准格式没有 sites，尝试从 apiyuan/zhanyuan 转换
            var sites: [SiteConfig] = config?.sites ?? []
            if sites.isEmpty {
                // 从 apiyuan 转换
                if let apiyuan = jsonDict["apiyuan"] as? [[String: Any]] {
                    print("[SubscriptionManager] 从 apiyuan 转换 \(apiyuan.count) 个站点")
                    for item in apiyuan {
                        if let name = item["name"] as? String,
                           let searchUrl = item["searchurl"] as? String {
                            let key = "api_\(sites.count + 1)"
                            // 用完整 searchurl 作为 api，nativeSearch 会拼接 &wd= 参数
                            let api = searchUrl.hasSuffix("=") ? searchUrl : (searchUrl.hasSuffix("&") || searchUrl.hasSuffix("?") ? searchUrl : searchUrl + "&")
                            let site = SiteConfig(key: key, name: name, type: 1, api: api)
                            if !sites.contains(where: { $0.name == name }) {
                                sites.append(site)
                            }
                        }
                    }
                }
                // 从 zhanyuan 转换（完整配置存到 ext）
                if let zhanyuan = jsonDict["zhanyuan"] as? [[String: Any]] {
                    print("[SubscriptionManager] 从 zhanyuan 转换 \(zhanyuan.count) 个蜘蛛站")
                    for item in zhanyuan {
                        if let name = item["name"] as? String,
                           let searchUrl = item["searchUrl"] as? String {
                            let key = "zhan_\(sites.count + 1)"
                            // 把完整 zhanyuan 配置编码到 ext
                            if let extData = try? JSONSerialization.data(withJSONObject: item),
                               let extStr = String(data: extData, encoding: .utf8) {
                                let site = SiteConfig(key: key, name: name, type: 2, api: searchUrl, ext: extStr)
                                if !sites.contains(where: { $0.name == name }) {
                                    sites.append(site)
                                }
                            }
                        }
                    }
                }
                print("[SubscriptionManager] 转换后共有 \(sites.count) 个站点")
            }

            // 如果仍然没有站点，报错
            if sites.isEmpty {
                print("[SubscriptionManager] ❌ 未能解析出任何站点")
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = "该订阅源未包含任何可用站点"
                }
                return
            }

            // 如果没有 parses 配置，从 JSON 的 parses 字段提取
            let parses = jsonDict["parses"] as? [[String: Any]] ?? []
            var parseConfigs: [ParseConfig] = []
            for parse in parses {
                if let name = parse["name"] as? String,
                   let url = parse["url"] as? String {
                    let type = parse["type"] as? Int
                    parseConfigs.append(ParseConfig(name: name, url: url, type: type))
                }
            }

            // 用转换后的站点创建新 config
            let finalConfig = config ?? SubscribeConfig(sites: sites, spider: jsonDict["spider"] as? String, wallpaper: jsonDict["wallpaper"] as? String, lives: nil, flags: nil, banned: nil, parses: parseConfigs.isEmpty ? nil : parseConfigs)

            await MainActor.run {
                self.config = finalConfig
                self.parses = parseConfigs
                self.isLoaded = true
                self.isLoading = false
                if !self.configURLs.contains(urlString) {
                    self.configURLs.append(urlString)
                    self.defaults.set(self.configURLs, forKey: self.urlsKey)
                }
                self.cacheConfig(rawData: try! JSONEncoder().encode(finalConfig))
                print("[SubscriptionManager] ✅ 加载 \(sites.count) 个站点, \(parseConfigs.count) 个解析器")
            }

        } catch {
            await setError("\(error.localizedDescription)")
        }
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
