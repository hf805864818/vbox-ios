import Foundation

// MARK: - 福利平台代理配置存储
/// 支持 URL 转发代理格式：https://proxy.example.com/?token=xxx&url=
/// 也支持标准 HTTP 代理格式
class WelfareProxyStore: ObservableObject {
    static let shared = WelfareProxyStore()

    private let proxyURLKey = "welfare_proxy_url_v1"
    private let proxyEnabledPlatformsKey = "welfare_proxy_enabled_platforms_v1"

    /// 代理 URL（支持 URL 转发格式，如 https://vbox.ltd/?token=199114&url=）
    @Published var proxyURL: String = ""

    /// 各平台代理开关状态 [平台名: 是否启用]
    @Published var enabledPlatforms: [String: Bool] = [:]

    init() {
        load()
    }

    // MARK: - 代理 URL 管理

    /// 设置代理 URL
    func setProxyURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        proxyURL = trimmed
        save()
    }

    /// 清除代理 URL
    func clearProxyURL() {
        proxyURL = ""
        // 清除所有平台的代理开关
        enabledPlatforms.removeAll()
        save()
    }

    /// 检查代理 URL 是否有效
    var hasValidProxy: Bool {
        !proxyURL.isEmpty && proxyURL.hasPrefix("http")
    }

    // MARK: - 平台代理开关

    /// 检查某个平台是否启用了代理
    func isProxyEnabled(for platformName: String) -> Bool {
        guard hasValidProxy else { return false }
        return enabledPlatforms[platformName] ?? false
    }

    /// 设置平台代理开关
    func setProxyEnabled(_ enabled: Bool, for platformName: String) {
        enabledPlatforms[platformName] = enabled
        save()
    }

    /// 切换平台代理开关
    func toggleProxy(for platformName: String) {
        let current = isProxyEnabled(for: platformName)
        setProxyEnabled(!current, for: platformName)
    }

    // MARK: - 代理 URL 构建

    /// 根据原始 URL 构建代理 URL
    /// - Parameter originalURL: 原始请求 URL
    /// - Parameter platformName: 平台名称（用于检查是否启用代理）
    /// - Returns: 如果平台启用了代理且代理有效，返回代理后的 URL；否则返回原始 URL
    func proxiedURL(_ originalURL: String, for platformName: String) -> String {
        guard isProxyEnabled(for: platformName), !originalURL.isEmpty else {
            return originalURL
        }
        return buildProxiedURL(originalURL)
    }

    /// 构建代理 URL（不检查平台开关，直接使用代理）
    func buildProxiedURL(_ originalURL: String) -> String {
        guard !proxyURL.isEmpty else { return originalURL }

        // URL 转发代理格式：https://proxy.example.com/?token=xxx&url=
        // 将原始 URL 拼接到代理 URL 后面
        if proxyURL.contains("?") {
            // 已有查询参数，追加 url= 参数
            if proxyURL.hasSuffix("&") || proxyURL.hasSuffix("?") {
                return proxyURL + originalURL
            } else {
                return proxyURL + "&url=" + (originalURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? originalURL)
            }
        } else {
            // 没有查询参数，添加 ?url=
            return proxyURL + "?url=" + (originalURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? originalURL)
        }
    }

    // MARK: - 存储

    private func load() {
        let defaults = UserDefaults.standard
        proxyURL = defaults.string(forKey: proxyURLKey) ?? ""
        if let data = defaults.data(forKey: proxyEnabledPlatformsKey),
           let dict = try? JSONDecoder().decode([String: Bool].self, from: data) {
            enabledPlatforms = dict
        }
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(proxyURL, forKey: proxyURLKey)
        if let data = try? JSONEncoder().encode(enabledPlatforms) {
            defaults.set(data, forKey: proxyEnabledPlatformsKey)
        }
    }
}
