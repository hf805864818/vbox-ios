import Foundation

// MARK: - 福利平台域名自定义存储

/// 用户可自定义每个福利平台的域名，替换失效的旧域名。
/// 存储格式：{ "平台名": "https://新域名" }
class WelfareDomainStore: ObservableObject {
    static let shared = WelfareDomainStore()

    private let key = "welfare_custom_domains"

    @Published var customDomains: [String: String] = [:]

    init() {
        load()
    }

    /// 获取某个平台的自定义域名，没有则返回 nil
    func domain(for platformName: String) -> String? {
        customDomains[platformName]
    }

    /// 设置某个平台的自定义域名，设为 nil 则恢复默认
    func setDomain(for platformName: String, _ domain: String?) {
        if let d = domain, !d.trimmingCharacters(in: .whitespaces).isEmpty {
            customDomains[platformName] = d.trimmingCharacters(in: .whitespaces)
        } else {
            customDomains.removeValue(forKey: platformName)
        }
        save()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            customDomains = dict
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(customDomains) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}