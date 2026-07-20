import Foundation
import Combine

// MARK: - 远程默认源管理器

enum RemoteSourceConfigKeys {
    static let remoteDefaultSourceEnabled = "remote_default_source_enabled"
    static let bundleSourcesEnabled = "bundle_sources_enabled"
    static let defaultManifestURL = "remote_default_manifest_url"
    static let lastConfigVersion = "remote_default_last_config_version"
    static let lastSyncTime = "remote_default_last_sync_time"
    static let lastSyncError = "remote_default_last_sync_error"
}

/// 远程默认源管理器
///
/// 负责从公开仓库读取 manifest.json，并把 API 源、网盘源、JS/站源、解析器等远程配置缓存到 Documents。
/// 说明：
/// - 远程默认源只管理 App 官方默认源，不覆盖用户添加的订阅源、自定义源、自定义解析器和网盘授权。
/// - Bundle 内置源总开关只控制 ibox_sources.json、video_sources.json、default_subscribe.json、builtinFallbackSites。
/// - 福利平台入口不做远程源控制；福利平台域名可后续通过 domain_overrides.json 覆盖。
@MainActor
final class RemoteSourceConfigManager: ObservableObject {
    static let shared = RemoteSourceConfigManager()

    enum LoadState: Equatable {
        case idle
        case loading
        case loadedRemote(version: String)
        case loadedCache(version: String)
        case failed(message: String)

        var displayText: String {
            switch self {
            case .idle:
                return "未同步"
            case .loading:
                return "同步中"
            case .loadedRemote(let version):
                return "远程配置 \(version)"
            case .loadedCache(let version):
                return "缓存配置 \(version)"
            case .failed(let message):
                return "失败：\(message)"
            }
        }
    }

    static let defaultManifestURL = "https://vbox-ai.github.io/api/sources/manifest.json"
    static let fallbackManifestURL = "https://raw.githubusercontent.com/vbox-Ai/api/main/sources/manifest.json"

    @Published var remoteDefaultSourceEnabled: Bool {
        didSet { UserDefaults.standard.set(remoteDefaultSourceEnabled, forKey: RemoteSourceConfigKeys.remoteDefaultSourceEnabled) }
    }

    @Published var bundleSourcesEnabled: Bool {
        didSet { UserDefaults.standard.set(bundleSourcesEnabled, forKey: RemoteSourceConfigKeys.bundleSourcesEnabled) }
    }

    @Published var defaultManifestURL: String {
        didSet { UserDefaults.standard.set(defaultManifestURL, forKey: RemoteSourceConfigKeys.defaultManifestURL) }
    }

    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var lastConfigVersion: String
    @Published private(set) var lastSyncTime: Date?
    @Published private(set) var lastSyncError: String?

    private let fileManager = FileManager.default
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private init() {
        remoteDefaultSourceEnabled = UserDefaults.standard.object(forKey: RemoteSourceConfigKeys.remoteDefaultSourceEnabled) as? Bool ?? true
        bundleSourcesEnabled = UserDefaults.standard.object(forKey: RemoteSourceConfigKeys.bundleSourcesEnabled) as? Bool ?? false
        defaultManifestURL = UserDefaults.standard.string(forKey: RemoteSourceConfigKeys.defaultManifestURL) ?? Self.defaultManifestURL
        lastConfigVersion = UserDefaults.standard.string(forKey: RemoteSourceConfigKeys.lastConfigVersion) ?? ""
        lastSyncTime = UserDefaults.standard.object(forKey: RemoteSourceConfigKeys.lastSyncTime) as? Date
        lastSyncError = UserDefaults.standard.string(forKey: RemoteSourceConfigKeys.lastSyncError)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    }

    // MARK: - Public

    func syncIfNeeded(force: Bool = false) async {
        guard remoteDefaultSourceEnabled else {
            loadCachedManifestState()
            print("[RemoteSource] 远程默认源已关闭，跳过同步")
            return
        }

        if !force, !shouldRefresh() {
            loadCachedManifestState()
            return
        }

        await syncNow()
    }

    func syncNow() async {
        guard remoteDefaultSourceEnabled else {
            loadCachedManifestState()
            return
        }

        loadState = .loading
        do {
            let manifestData = try await fetchManifestData()
            let manifest = try decoder.decode(RemoteSourceManifest.self, from: manifestData)
            try validate(manifest: manifest)

            let urls = manifest.files
            try await downloadIfPresent(urls.apiSources, to: .apiSources)
            try await downloadIfPresent(urls.cloudSources, to: .cloudSources)
            try await downloadIfPresent(urls.spiderSources, to: .spiderSources)
            try await downloadIfPresent(urls.domainOverrides, to: .domainOverrides)
            try await downloadIfPresent(urls.parsers, to: .parsers)
            try await downloadIfPresent(urls.disabledSources, to: .disabledSources)

            try write(manifestData, to: .manifest)
            updateSuccess(version: manifest.configVersion)
            print("[RemoteSource] 同步完成 version=\(manifest.configVersion)")
        } catch {
            updateFailure(error.localizedDescription)
            loadCachedManifestState()
            print("[RemoteSource] 同步失败: \(error.localizedDescription)")
        }
    }

    private func fetchManifestData() async throws -> Data {
        do {
            guard let manifestURL = URL(string: defaultManifestURL) else {
                throw RemoteSourceError.invalidURL(defaultManifestURL)
            }
            print("[RemoteSource] 开始同步 manifest: \(defaultManifestURL)")
            return try await fetchData(from: manifestURL)
        } catch {
            guard defaultManifestURL != Self.fallbackManifestURL,
                  let fallbackURL = URL(string: Self.fallbackManifestURL) else {
                throw error
            }
            print("[RemoteSource] 默认 manifest 失败，尝试兜底地址: \(Self.fallbackManifestURL)")
            return try await fetchData(from: fallbackURL)
        }
    }

    func clearCache() {
        do {
            if fileManager.fileExists(atPath: cacheDirectory.path) {
                try fileManager.removeItem(at: cacheDirectory)
            }
            lastConfigVersion = ""
            lastSyncTime = nil
            lastSyncError = nil
            UserDefaults.standard.removeObject(forKey: RemoteSourceConfigKeys.lastConfigVersion)
            UserDefaults.standard.removeObject(forKey: RemoteSourceConfigKeys.lastSyncTime)
            UserDefaults.standard.removeObject(forKey: RemoteSourceConfigKeys.lastSyncError)
            loadState = .idle
            print("[RemoteSource] 已清除远程源缓存")
        } catch {
            updateFailure("清除缓存失败：\(error.localizedDescription)")
        }
    }

    func cachedAPIConfig() -> SubscribeConfig? {
        decodeCached(SubscribeConfig.self, from: .apiSources)
    }

    func cachedAPISites() -> [SiteConfig] {
        cachedAPIConfig()?.sites ?? []
    }

    func cachedCloudSitesData() -> Data? {
        read(.cloudSources)
    }

    func cachedParsers() -> [ParseConfig] {
        guard let wrapper = decodeCached(ParserWrapper.self, from: .parsers) else { return [] }
        return wrapper.parses
    }

    func cachedDisabledHosts() -> [String] {
        guard let wrapper = decodeCached(DisabledSourcesWrapper.self, from: .disabledSources) else { return [] }
        return wrapper.disabledHosts ?? []
    }

    func cachedDisabledKeys() -> [String] {
        guard let wrapper = decodeCached(DisabledSourcesWrapper.self, from: .disabledSources) else { return [] }
        return wrapper.disabledKeys ?? []
    }

    func cachedDomainOverrides() -> [DomainOverride] {
        guard let wrapper = decodeCached(DomainOverridesWrapper.self, from: .domainOverrides) else { return [] }
        return wrapper.overrides ?? []
    }

    /// 检查某个 host 是否在禁用列表中
    func isHostDisabled(_ host: String) -> Bool {
        let hosts = cachedDisabledHosts()
        if hosts.contains(host) { return true }
        // 忽略 scheme 差异做 host 匹配（http vs https）
        guard let hostURL = URL(string: host),
              let hostName = hostURL.host else { return false }
        return hosts.contains { disabled in
            guard let disabledURL = URL(string: disabled) else { return false }
            return disabledURL.host == hostName && (disabledURL.port ?? (disabledURL.scheme == "https" ? 443 : 80)) == (hostURL.port ?? (hostURL.scheme == "https" ? 443 : 80))
        }
    }

    /// 对 URL 字符串应用域名覆盖
    func applyDomainOverrides(to urlString: String) -> String {
        let overrides = cachedDomainOverrides()
        guard !overrides.isEmpty else { return urlString }
        var result = urlString
        for override in overrides {
            guard let from = override.from, let to = override.to, !from.isEmpty, !to.isEmpty else { continue }
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result
    }

    // MARK: - Paths

    private enum CacheFile: String {
        case manifest = "manifest.json"
        case apiSources = "api_sources.json"
        case cloudSources = "cloud_sources.json"
        case spiderSources = "spider_sources.json"
        case domainOverrides = "domain_overrides.json"
        case parsers = "parsers.json"
        case disabledSources = "disabled_sources.json"
    }

    private var cacheDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("remote_sources", isDirectory: true)
    }

    private func url(for file: CacheFile) -> URL {
        cacheDirectory.appendingPathComponent(file.rawValue)
    }

    private func ensureCacheDirectory() throws {
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - IO

    private func fetchData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw RemoteSourceError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }

    private func downloadIfPresent(_ urlString: String?, to file: CacheFile) async throws {
        guard let urlString, !urlString.isEmpty else { return }
        guard let url = URL(string: urlString) else { throw RemoteSourceError.invalidURL(urlString) }
        let data = try await fetchData(from: url)
        try validateJSON(data, file: file)
        try write(data, to: file)
        print("[RemoteSource] 下载 \(file.rawValue) 成功")
    }

    private func write(_ data: Data, to file: CacheFile) throws {
        try ensureCacheDirectory()
        try data.write(to: url(for: file), options: .atomic)
    }

    private func read(_ file: CacheFile) -> Data? {
        let fileURL = url(for: file)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    private func decodeCached<T: Decodable>(_ type: T.Type, from file: CacheFile) -> T? {
        guard let data = read(file) else { return nil }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            print("[RemoteSource] 缓存 \(file.rawValue) 解码失败: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - State

    private func shouldRefresh() -> Bool {
        guard let lastSyncTime else { return true }
        guard let manifest = decodeCached(RemoteSourceManifest.self, from: .manifest) else { return true }
        let ttl = TimeInterval(manifest.ttlSeconds ?? 21600)
        return Date().timeIntervalSince(lastSyncTime) >= ttl || manifest.forceRefresh == true
    }

    private func loadCachedManifestState() {
        if let manifest = decodeCached(RemoteSourceManifest.self, from: .manifest) {
            loadState = .loadedCache(version: manifest.configVersion)
            lastConfigVersion = manifest.configVersion
        } else if let lastSyncError {
            loadState = .failed(message: lastSyncError)
        } else {
            loadState = .idle
        }
    }

    private func updateSuccess(version: String) {
        lastConfigVersion = version
        lastSyncTime = Date()
        lastSyncError = nil
        UserDefaults.standard.set(version, forKey: RemoteSourceConfigKeys.lastConfigVersion)
        UserDefaults.standard.set(lastSyncTime, forKey: RemoteSourceConfigKeys.lastSyncTime)
        UserDefaults.standard.removeObject(forKey: RemoteSourceConfigKeys.lastSyncError)
        loadState = .loadedRemote(version: version)
    }

    private func updateFailure(_ message: String) {
        lastSyncError = message
        UserDefaults.standard.set(message, forKey: RemoteSourceConfigKeys.lastSyncError)
    }

    // MARK: - Validation

    private func validate(manifest: RemoteSourceManifest) throws {
        guard manifest.schemaVersion >= 1 else {
            throw RemoteSourceError.invalidManifest("schemaVersion 必须 >= 1")
        }
        guard !manifest.configVersion.isEmpty else {
            throw RemoteSourceError.invalidManifest("configVersion 不能为空")
        }
    }

    private func validateJSON(_ data: Data, file: CacheFile) throws {
        switch file {
        case .apiSources, .spiderSources:
            _ = try decoder.decode(SubscribeConfig.self, from: data)
        case .cloudSources:
            _ = try decoder.decode(CloudSitesRemoteWrapper.self, from: data)
        case .parsers:
            _ = try decoder.decode(ParserWrapper.self, from: data)
        case .manifest:
            _ = try decoder.decode(RemoteSourceManifest.self, from: data)
        case .domainOverrides:
            _ = try decoder.decode(DomainOverridesWrapper.self, from: data)
        case .disabledSources:
            _ = try decoder.decode(DisabledSourcesWrapper.self, from: data)
        }
    }
}

// MARK: - Codable Models

private struct RemoteSourceManifest: Codable {
    let schemaVersion: Int
    let configVersion: String
    let minAppVersion: String?
    let updatedAt: String?
    let ttlSeconds: Int?
    let files: RemoteSourceFiles
    let disabledKeys: [String]?
    let forceRefresh: Bool?
}

private struct RemoteSourceFiles: Codable {
    let apiSources: String?
    let cloudSources: String?
    let spiderSources: String?
    let domainOverrides: String?
    let parsers: String?
    let disabledSources: String?
}

private struct CloudSitesRemoteWrapper: Codable {
    let cloudSites: [SpiderManager.CloudSiteConfig]
}

private struct ParserWrapper: Codable {
    let parses: [ParseConfig]
}

private struct DisabledSourcesWrapper: Codable {
    let disabledKeys: [String]?
    let disabledHosts: [String]?
}

private struct DomainOverridesWrapper: Codable {
    let overrides: [DomainOverride]?
}

struct DomainOverride: Codable {
    let from: String?
    let to: String?
    let description: String?
}

private enum RemoteSourceError: LocalizedError {
    case invalidURL(String)
    case httpError(Int)
    case invalidManifest(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "URL 无效：\(url)"
        case .httpError(let code):
            return "HTTP 状态异常：\(code)"
        case .invalidManifest(let message):
            return "manifest 无效：\(message)"
        }
    }
}
