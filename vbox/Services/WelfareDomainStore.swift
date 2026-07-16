import Foundation

// MARK: - 福利平台域名自定义存储

/// 用户可自定义每个福利平台的域名列表，替换失效的旧域名。
/// 存储格式：{ "平台名": ["https://新域名1", "https://新域名2"] }
/// 支持多域名轮询
class WelfareDomainStore: ObservableObject {
    static let shared = WelfareDomainStore()

    private let key = "welfare_custom_domains_v2"

    @Published var customDomains: [String: [String]] = [:]

    init() {
        load()
    }

    /// 获取某个平台的所有自定义域名
    func domains(for platformName: String) -> [String] {
        customDomains[platformName] ?? []
    }

    /// 添加一个域名到平台
    func addDomain(for platformName: String, _ domain: String) {
        let trimmed = domain.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var list = customDomains[platformName] ?? []
        if !list.contains(trimmed) {
            list.append(trimmed)
            customDomains[platformName] = list
            objectWillChange.send()
            save()
        }
    }

    /// 直接设置平台域名列表
    func setDomains(_ domains: [String], for platformName: String) {
        let trimmed = domains.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        customDomains[platformName] = trimmed
        objectWillChange.send()
        save()
    }

    /// 删除某个平台的指定域名
    func removeDomain(for platformName: String, _ domain: String) {
        guard var list = customDomains[platformName] else { return }
        list.removeAll { $0 == domain }
        if list.isEmpty {
            customDomains.removeValue(forKey: platformName)
        } else {
            customDomains[platformName] = list
        }
        objectWillChange.send()
        save()
    }

    /// 清除某个平台的所有自定义域名
    func clearDomains(for platformName: String) {
        customDomains.removeValue(forKey: platformName)
        objectWillChange.send()
        save()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let dict = try? JSONDecoder().decode([String: [String]].self, from: data) {
            customDomains = dict
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(customDomains) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}