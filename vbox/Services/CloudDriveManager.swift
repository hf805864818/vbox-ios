import Foundation
import Combine

struct DriveToken: Codable {
    let type: String
    let name: String
    let value: String
}

struct BaiduFileItem: Codable {
    let fsId: String
    let name: String
}

class CloudDriveManager: ObservableObject {

    static let shared = CloudDriveManager()
    private static let baiduPCSUserAgent = "Mozilla/5.0 (Linux; Android 12; HD1900 Build/SKQ1.211113.001) AppleWebKit/537.36 (KHTML, like Gecko)&channel=android_12_HD1900_bdnetdisktv_1025538l&version=1.21.1&network_type=wifi&app_id=250528&size=c1080_u1600"
    private static let baiduIBoxTransferDir = "/我的资源/iBox"

    enum DriveType: String, CaseIterable {
        case ali = "ali"
        case quark = "quark"
        case baidu = "baidu"
        case one15 = "115"
        case uc = "uc"

        var displayName: String {
            switch self {
            case .ali: return "阿里云盘"
            case .quark: return "夸克网盘"
            case .baidu: return "百度网盘"
            case .one15: return "115网盘"
            case .uc: return "UC网盘"
            }
        }

        var tokenLabel: String {
            switch self {
            case .ali: return "Refresh Token"
            case .quark: return "Cookie"
            case .baidu: return "完整 Cookie / BDUSS+STOKEN"
            case .one15: return "完整 Cookie / CID"
            case .uc: return "Cookie"
            }
        }
    }

    private let session: URLSession
    private let defaults = UserDefaults.standard
    private let tokenKey = "saved_drive_tokens"
    private let baiduPersistedPlayCacheKey = "baidu_play_result_cache_v1"
    private let baiduPersistedPlayItemCacheKey = "baidu_play_item_cache_v1"
    private let baiduIBoxPlayItemCacheKey = "baidu_ibox_play_item_cache_v1"
    private let baiduFileListCacheKey = "baidu_file_list_cache_v1"
    private let baiduShareContextCacheKey = "baidu_share_context_cache_v1"
    private let baiduVerifyCooldownKey = "baidu_verify_cooldown_v1"
    private let unifiedCloudPlayItemCacheKey = "cloud_play_item_cache_v1"
    private let baiduRouteDiagnosticsKey = "baidu_route_diagnostics_v1"
    private struct BaiduPlayCacheItem {
        let result: PlayResult
        let expiresAt: Date
    }
    private struct BaiduPersistedPlayCacheItem: Codable {
        let url: String
        let headers: [String: String]
        let expiresAt: Date
    }
    private struct BaiduPlayItem: Codable {
        let fsId: String
        let fileName: String
        let path: String
        let headers: [String: String]
        let compatibilityHint: String
        let updatedAt: Date
    }
    private struct BaiduIBoxPlayItem: Codable {
        let shareURL: String
        let fsId: String
        let fileName: String
        let path: String
        let dlinkURL: String?
        let headers: [String: String]
        let dlinkExpiresAt: Date?
        let compatibilityHint: String
        let preferredEngine: String
        let preparedAt: Date
        let updatedAt: Date
        let lastUsedAt: Date?
        let source: String
    }
    private struct BaiduFileListCacheItem: Codable {
        let files: [BaiduFileItem]
        let expiresAt: Date
    }
    private struct BaiduShareContext: Codable {
        let shareURL: String
        let surl: String
        let pwd: String?
        let shareid: String
        let shareUk: String
        let bdstoken: String?
        let cookie: String
        let files: [BaiduFileItem]
        let source: String
        let expiresAt: Date
    }
    struct BaiduPlaybackCacheSummary {
        let playResultCount: Int
        let expiredPlayResultCount: Int
        let playItemCount: Int
        let iBoxPlayItemCount: Int
        let validIBoxDlinkCount: Int
        let expiredIBoxDlinkCount: Int
        let fileListCount: Int
        let expiredFileListCount: Int
        let storageBytes: Int
        let lastUpdatedAt: Date?

        var totalCount: Int {
            playResultCount + playItemCount + iBoxPlayItemCount + fileListCount
        }
    }
    struct CloudPlayItem: Codable {
        let provider: String
        let sourceKey: String
        let shareURL: String
        let resourceId: String
        let fileName: String
        let ownPath: String?
        let playURL: String?
        let headers: [String: String]
        let expiresAt: Date?
        let compatibilityHint: String
        let preferredEngine: String
        let preparedAt: Date
        let updatedAt: Date
        let source: String
    }
    struct CloudPlayItemSummary {
        let totalCount: Int
        let validPlayURLCount: Int
        let expiredPlayURLCount: Int
        let storageBytes: Int
        let lastUpdatedAt: Date?
    }
    struct BaiduRouteDiagnostic: Codable, Identifiable {
        let id: UUID
        let time: Date
        let stage: String
        let status: String
        let detail: String
        let fsId: String?
        let fileName: String?
    }

    private var baiduPlayCache: [String: BaiduPlayCacheItem] = [:]
    private let baiduPlayCacheLock = NSLock()

    @Published private(set) var savedTokens: [DriveToken] = []

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        loadTokens()
    }

    static var onLog: ((String) -> Void)?

    private func baiduLog(_ msg: String) {
        print(msg)
        if let handler = CloudDriveManager.onLog {
            handler(msg)
        }
    }

    private func recordBaiduRouteDiagnostic(stage: String, status: String, detail: String, fsId: String? = nil, fileName: String? = nil) {
        var items = recentBaiduRouteDiagnostics()
        items.insert(
            BaiduRouteDiagnostic(
                id: UUID(),
                time: Date(),
                stage: stage,
                status: status,
                detail: detail,
                fsId: fsId,
                fileName: fileName
            ),
            at: 0
        )
        if items.count > 60 {
            items = Array(items.prefix(60))
        }
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: baiduRouteDiagnosticsKey)
        }
    }

    func recentBaiduRouteDiagnostics() -> [BaiduRouteDiagnostic] {
        guard let data = defaults.data(forKey: baiduRouteDiagnosticsKey),
              let items = try? JSONDecoder().decode([BaiduRouteDiagnostic].self, from: data) else {
            return []
        }
        return items
    }

    func clearBaiduRouteDiagnostics() {
        defaults.removeObject(forKey: baiduRouteDiagnosticsKey)
        baiduLog("[Baidu-Diag] 已清空路链诊断记录")
    }

    private func baiduPlayCacheKey(shareURL: String, fsId: String, bduss: String, pcsCookie: String) -> String {
        "\(shareURL)|\(fsId)|\(baiduStableHash(bduss))|\(baiduStableHash(pcsCookie))"
    }

    private func baiduMainRouteCacheKey(shareURL: String, fsId: String, bduss: String, pcsCookie: String) -> String {
        "main-route-v2|\(baiduPlayCacheKey(shareURL: shareURL, fsId: fsId, bduss: bduss, pcsCookie: pcsCookie))"
    }

    private func baiduFileListCacheKey(shareURL: String, bduss: String) -> String {
        "\(shareURL)|\(baiduStableHash(bduss))"
    }

    private func baiduShareContextKey(shareURL: String, cookie: String) -> String {
        "\(shareURL)|\(baiduStableHash(cookie))"
    }

    private func baiduCachedPlayResult(for key: String) -> PlayResult? {
        baiduPlayCacheLock.lock()
        if let item = baiduPlayCache[key] {
            if item.expiresAt > Date() {
                baiduPlayCacheLock.unlock()
                return item.result
            }
            baiduPlayCache.removeValue(forKey: key)
        }

        if let persisted = baiduLoadPersistedPlayCache()[key], persisted.expiresAt > Date() {
            let result = PlayResult(url: persisted.url, headers: persisted.headers, driveType: .baidu)
            baiduPlayCache[key] = BaiduPlayCacheItem(result: result, expiresAt: persisted.expiresAt)
            baiduPlayCacheLock.unlock()
            return result
        }

        baiduPlayCacheLock.unlock()
        return nil
    }

    private func baiduCachedFileList(for key: String) -> [BaiduFileItem]? {
        var cache = baiduLoadPersistedFileListCache()
        guard let item = cache[key] else { return nil }
        if item.expiresAt > Date(), !item.files.isEmpty {
            return item.files
        }
        cache.removeValue(forKey: key)
        baiduSavePersistedFileListCache(cache)
        return nil
    }

    private func baiduStoreFileList(_ files: [BaiduFileItem], for key: String, ttl: TimeInterval = 8 * 60 * 60) {
        guard !files.isEmpty else { return }
        var cache = baiduLoadPersistedFileListCache()
        cache[key] = BaiduFileListCacheItem(files: files, expiresAt: Date().addingTimeInterval(ttl))
        if cache.count > 80 {
            let now = Date()
            cache = cache.filter { $0.value.expiresAt > now }
        }
        baiduSavePersistedFileListCache(cache)
    }

    private func baiduCachedShareContext(for key: String) -> BaiduShareContext? {
        var cache = baiduLoadPersistedShareContextCache()
        guard let context = cache[key] else { return nil }
        if context.expiresAt > Date(), !context.shareid.isEmpty, !context.shareUk.isEmpty, !context.files.isEmpty {
            return context
        }
        cache.removeValue(forKey: key)
        baiduSavePersistedShareContextCache(cache)
        return nil
    }

    private func baiduStoreShareContext(
        shareURL: String,
        surl: String,
        pwd: String?,
        shareid: String,
        shareUk: String,
        bdstoken: String? = nil,
        cookie: String,
        files: [BaiduFileItem],
        source: String,
        key: String,
        ttl: TimeInterval = 8 * 60 * 60
    ) {
        guard !shareid.isEmpty, !shareUk.isEmpty, !files.isEmpty else { return }
        var cache = baiduLoadPersistedShareContextCache()
        cache[key] = BaiduShareContext(
            shareURL: shareURL,
            surl: surl,
            pwd: pwd,
            shareid: shareid,
            shareUk: shareUk,
            bdstoken: bdstoken,
            cookie: cookie,
            files: files,
            source: source,
            expiresAt: Date().addingTimeInterval(ttl)
        )
        if cache.count > 60 {
            let now = Date()
            cache = cache.filter { $0.value.expiresAt > now }
        }
        baiduSavePersistedShareContextCache(cache)
    }

    private func baiduLoadPersistedShareContextCache() -> [String: BaiduShareContext] {
        guard let data = defaults.data(forKey: baiduShareContextCacheKey),
              let cache = try? JSONDecoder().decode([String: BaiduShareContext].self, from: data) else {
            return [:]
        }
        return cache
    }

    private func baiduSavePersistedShareContextCache(_ cache: [String: BaiduShareContext]) {
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: baiduShareContextCacheKey)
        }
    }

    private func baiduVerifyCooldownCache() -> [String: Date] {
        guard let data = defaults.data(forKey: baiduVerifyCooldownKey),
              let cache = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return [:]
        }
        return cache
    }

    private func baiduIsVerifyCoolingDown(_ key: String) -> Bool {
        var cache = baiduVerifyCooldownCache()
        let now = Date()
        cache = cache.filter { $0.value > now }
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: baiduVerifyCooldownKey)
        }
        return (cache[key] ?? .distantPast) > now
    }

    private func baiduMarkVerifyCooldown(_ key: String, seconds: TimeInterval = 10 * 60) {
        var cache = baiduVerifyCooldownCache()
        cache[key] = Date().addingTimeInterval(seconds)
        if cache.count > 60 {
            let now = Date()
            cache = cache.filter { $0.value > now }
        }
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: baiduVerifyCooldownKey)
        }
    }

    private func baiduLoadPersistedFileListCache() -> [String: BaiduFileListCacheItem] {
        guard let data = defaults.data(forKey: baiduFileListCacheKey),
              let cache = try? JSONDecoder().decode([String: BaiduFileListCacheItem].self, from: data) else {
            return [:]
        }
        return cache
    }

    private func baiduSavePersistedFileListCache(_ cache: [String: BaiduFileListCacheItem]) {
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: baiduFileListCacheKey)
        }
    }

    private func baiduStorePlayResult(_ result: PlayResult, for key: String, ttl: TimeInterval = 6 * 60 * 60) {
        let expiresAt = Date().addingTimeInterval(ttl)
        baiduPlayCacheLock.lock()
        baiduPlayCache[key] = BaiduPlayCacheItem(result: result, expiresAt: expiresAt)
        if baiduPlayCache.count > 80 {
            let now = Date()
            baiduPlayCache = baiduPlayCache.filter { $0.value.expiresAt > now }
        }
        baiduPlayCacheLock.unlock()

        var persisted = baiduLoadPersistedPlayCache()
        persisted[key] = BaiduPersistedPlayCacheItem(url: result.url, headers: result.headers, expiresAt: expiresAt)
        let now = Date()
        persisted = persisted.filter { $0.value.expiresAt > now }
        if persisted.count > 80 {
            persisted = Dictionary(uniqueKeysWithValues: persisted.sorted { $0.value.expiresAt > $1.value.expiresAt }.prefix(80).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(persisted) {
            defaults.set(data, forKey: baiduPersistedPlayCacheKey)
        }
    }

    func invalidateBaiduPlaybackCache(shareURL: String, fsId: String, bduss: String, pcsCookie: String = "", reason: String = "手动刷新") {
        let cacheKey = baiduPlayCacheKey(shareURL: shareURL, fsId: fsId, bduss: bduss, pcsCookie: pcsCookie)
        let mainRouteKey = baiduMainRouteCacheKey(shareURL: shareURL, fsId: fsId, bduss: bduss, pcsCookie: pcsCookie)
        baiduPlayCacheLock.lock()
        baiduPlayCache.removeValue(forKey: cacheKey)
        baiduPlayCache.removeValue(forKey: mainRouteKey)
        baiduPlayCacheLock.unlock()

        var playCache = baiduLoadPersistedPlayCache()
        playCache.removeValue(forKey: cacheKey)
        playCache.removeValue(forKey: mainRouteKey)
        if let data = try? JSONEncoder().encode(playCache) {
            defaults.set(data, forKey: baiduPersistedPlayCacheKey)
        }

        var iboxCache = baiduLoadPersistedIBoxPlayItemCache()
        for key in [cacheKey, mainRouteKey] {
            guard let item = iboxCache[key] else {
                invalidateUnifiedCloudPlayItem(provider: .baidu, sourceKey: key, reason: "invalidated")
                continue
            }
            let invalidatedItem = BaiduIBoxPlayItem(
                shareURL: item.shareURL,
                fsId: item.fsId,
                fileName: item.fileName,
                path: item.path,
                dlinkURL: nil,
                headers: item.headers,
                dlinkExpiresAt: nil,
                compatibilityHint: item.compatibilityHint,
                preferredEngine: item.preferredEngine,
                preparedAt: item.preparedAt,
                updatedAt: Date(),
                lastUsedAt: item.lastUsedAt,
                source: "\(item.source)-invalidated"
            )
            iboxCache[key] = invalidatedItem
            mirrorBaiduIBoxPlayItemToUnified(invalidatedItem, sourceKey: key)
        }
        if let data = try? JSONEncoder().encode(iboxCache) {
            defaults.set(data, forKey: baiduIBoxPlayItemCacheKey)
        }

        baiduLog("[Baidu-Cache] 已清理播放缓存并保留 path：fsId=\(fsId), reason=\(reason)")
        recordBaiduRouteDiagnostic(stage: "播放缓存", status: "失效清理", detail: "已清理旧 dlink/播放缓存，保留 path，原因：\(reason)", fsId: fsId)
    }

    private func baiduCachedPlayItem(for key: String) -> BaiduPlayItem? {
        baiduLoadPersistedPlayItemCache()[key]
    }

    private func baiduStorePlayItem(_ item: BaiduPlayItem, for key: String) {
        var persisted = baiduLoadPersistedPlayItemCache()
        persisted[key] = item
        if persisted.count > 120 {
            persisted = Dictionary(uniqueKeysWithValues: persisted.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(120).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(persisted) {
            defaults.set(data, forKey: baiduPersistedPlayItemCacheKey)
        }
    }

    private func baiduCachedIBoxPlayItem(for key: String) -> BaiduIBoxPlayItem? {
        baiduLoadPersistedIBoxPlayItemCache()[key]
    }

    private func baiduStoreIBoxPlayItem(_ item: BaiduIBoxPlayItem, for key: String) {
        var persisted = baiduLoadPersistedIBoxPlayItemCache()
        persisted[key] = item
        if persisted.count > 160 {
            persisted = Dictionary(uniqueKeysWithValues: persisted.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(160).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(persisted) {
            defaults.set(data, forKey: baiduIBoxPlayItemCacheKey)
        }
        mirrorBaiduIBoxPlayItemToUnified(item, sourceKey: key)
    }

    private func baiduLoadPersistedPlayCache() -> [String: BaiduPersistedPlayCacheItem] {
        guard let data = defaults.data(forKey: baiduPersistedPlayCacheKey),
              let cache = try? JSONDecoder().decode([String: BaiduPersistedPlayCacheItem].self, from: data) else {
            return [:]
        }
        return cache
    }

    private func baiduLoadPersistedPlayItemCache() -> [String: BaiduPlayItem] {
        guard let data = defaults.data(forKey: baiduPersistedPlayItemCacheKey),
              let cache = try? JSONDecoder().decode([String: BaiduPlayItem].self, from: data) else {
            return [:]
        }
        return cache
    }

    private func baiduLoadPersistedIBoxPlayItemCache() -> [String: BaiduIBoxPlayItem] {
        guard let data = defaults.data(forKey: baiduIBoxPlayItemCacheKey),
              let cache = try? JSONDecoder().decode([String: BaiduIBoxPlayItem].self, from: data) else {
            return [:]
        }
        return cache
    }

    private func cloudPlayItemCacheKey(provider: DriveType, sourceKey: String) -> String {
        "\(provider.rawValue)|\(sourceKey)"
    }

    private func loadUnifiedCloudPlayItemCache() -> [String: CloudPlayItem] {
        guard let data = defaults.data(forKey: unifiedCloudPlayItemCacheKey),
              let cache = try? JSONDecoder().decode([String: CloudPlayItem].self, from: data) else {
            return [:]
        }
        return cache
    }

    private func saveUnifiedCloudPlayItemCache(_ cache: [String: CloudPlayItem]) {
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: unifiedCloudPlayItemCacheKey)
        }
    }

    private func storeUnifiedCloudPlayItem(_ item: CloudPlayItem, provider: DriveType, sourceKey: String) {
        var cache = loadUnifiedCloudPlayItemCache()
        cache[cloudPlayItemCacheKey(provider: provider, sourceKey: sourceKey)] = item
        if cache.count > 260 {
            cache = Dictionary(uniqueKeysWithValues: cache.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(260).map { ($0.key, $0.value) })
        }
        saveUnifiedCloudPlayItemCache(cache)
    }

    private func mirrorBaiduIBoxPlayItemToUnified(_ item: BaiduIBoxPlayItem, sourceKey: String) {
        storeUnifiedCloudPlayItem(
            CloudPlayItem(
                provider: DriveType.baidu.rawValue,
                sourceKey: sourceKey,
                shareURL: item.shareURL,
                resourceId: item.fsId,
                fileName: item.fileName,
                ownPath: item.path,
                playURL: item.dlinkURL,
                headers: item.headers,
                expiresAt: item.dlinkExpiresAt,
                compatibilityHint: item.compatibilityHint,
                preferredEngine: item.preferredEngine,
                preparedAt: item.preparedAt,
                updatedAt: item.updatedAt,
                source: item.source
            ),
            provider: .baidu,
            sourceKey: sourceKey
        )
    }

    private func invalidateUnifiedCloudPlayItem(provider: DriveType, sourceKey: String, reason: String) {
        var cache = loadUnifiedCloudPlayItemCache()
        let key = cloudPlayItemCacheKey(provider: provider, sourceKey: sourceKey)
        guard let item = cache[key] else { return }
        cache[key] = CloudPlayItem(
            provider: item.provider,
            sourceKey: item.sourceKey,
            shareURL: item.shareURL,
            resourceId: item.resourceId,
            fileName: item.fileName,
            ownPath: item.ownPath,
            playURL: nil,
            headers: item.headers,
            expiresAt: nil,
            compatibilityHint: item.compatibilityHint,
            preferredEngine: item.preferredEngine,
            preparedAt: item.preparedAt,
            updatedAt: Date(),
            source: "\(item.source)-\(reason)"
        )
        saveUnifiedCloudPlayItemCache(cache)
    }

    private func clearExpiredUnifiedCloudPlayItems(provider: DriveType) {
        let now = Date()
        var cache = loadUnifiedCloudPlayItemCache()
        var changed = false
        for (key, item) in cache where item.provider == provider.rawValue {
            guard let expiresAt = item.expiresAt, expiresAt <= now, item.playURL?.isEmpty == false else { continue }
            cache[key] = CloudPlayItem(
                provider: item.provider,
                sourceKey: item.sourceKey,
                shareURL: item.shareURL,
                resourceId: item.resourceId,
                fileName: item.fileName,
                ownPath: item.ownPath,
                playURL: nil,
                headers: item.headers,
                expiresAt: nil,
                compatibilityHint: item.compatibilityHint,
                preferredEngine: item.preferredEngine,
                preparedAt: item.preparedAt,
                updatedAt: now,
                source: "\(item.source)-expired-cleaned"
            )
            changed = true
        }
        if changed {
            saveUnifiedCloudPlayItemCache(cache)
        }
    }

    private func clearUnifiedCloudPlayItems(provider: DriveType) {
        var cache = loadUnifiedCloudPlayItemCache()
        cache = cache.filter { $0.value.provider != provider.rawValue }
        saveUnifiedCloudPlayItemCache(cache)
    }

    func cloudPlayItemSummary(for provider: DriveType) -> CloudPlayItemSummary {
        let now = Date()
        let cache = loadUnifiedCloudPlayItemCache().values.filter { $0.provider == provider.rawValue }
        let valid = cache.filter { ($0.expiresAt ?? .distantPast) > now && ($0.playURL?.isEmpty == false) }.count
        let expired = cache.filter { item in
            guard let expiresAt = item.expiresAt, item.playURL?.isEmpty == false else { return false }
            return expiresAt <= now
        }.count
        let storageBytes = defaults.data(forKey: unifiedCloudPlayItemCacheKey)?.count ?? 0
        return CloudPlayItemSummary(
            totalCount: cache.count,
            validPlayURLCount: valid,
            expiredPlayURLCount: expired,
            storageBytes: storageBytes,
            lastUpdatedAt: cache.map(\.updatedAt).max()
        )
    }

    func baiduPlaybackCacheSummary() -> BaiduPlaybackCacheSummary {
        let now = Date()
        let playCache = baiduLoadPersistedPlayCache()
        let playItems = baiduLoadPersistedPlayItemCache()
        let iBoxItems = baiduLoadPersistedIBoxPlayItemCache()
        let fileLists = baiduLoadPersistedFileListCache()

        let expiredPlay = playCache.values.filter { $0.expiresAt <= now }.count
        let expiredFileLists = fileLists.values.filter { $0.expiresAt <= now }.count
        let validIBoxDlinks = iBoxItems.values.filter { ($0.dlinkExpiresAt ?? .distantPast) > now && ($0.dlinkURL?.isEmpty == false) }.count
        let expiredIBoxDlinks = iBoxItems.values.filter { item in
            guard let expiresAt = item.dlinkExpiresAt, item.dlinkURL?.isEmpty == false else { return false }
            return expiresAt <= now
        }.count
        let dates = playCache.values.map(\.expiresAt)
            + playItems.values.map(\.updatedAt)
            + iBoxItems.values.map(\.updatedAt)
            + fileLists.values.map(\.expiresAt)
        let storageBytes = [
            baiduPersistedPlayCacheKey,
            baiduPersistedPlayItemCacheKey,
            baiduIBoxPlayItemCacheKey,
            baiduFileListCacheKey,
            baiduShareContextCacheKey,
            baiduVerifyCooldownKey
        ].reduce(0) { total, key in
            total + (defaults.data(forKey: key)?.count ?? 0)
        }

        return BaiduPlaybackCacheSummary(
            playResultCount: playCache.count,
            expiredPlayResultCount: expiredPlay,
            playItemCount: playItems.count,
            iBoxPlayItemCount: iBoxItems.count,
            validIBoxDlinkCount: validIBoxDlinks,
            expiredIBoxDlinkCount: expiredIBoxDlinks,
            fileListCount: fileLists.count,
            expiredFileListCount: expiredFileLists,
            storageBytes: storageBytes,
            lastUpdatedAt: dates.max()
        )
    }

    @discardableResult
    func clearExpiredBaiduPlaybackCaches() -> BaiduPlaybackCacheSummary {
        let now = Date()

        baiduPlayCacheLock.lock()
        baiduPlayCache = baiduPlayCache.filter { $0.value.expiresAt > now }
        baiduPlayCacheLock.unlock()

        var playCache = baiduLoadPersistedPlayCache().filter { $0.value.expiresAt > now }
        if let data = try? JSONEncoder().encode(playCache) {
            defaults.set(data, forKey: baiduPersistedPlayCacheKey)
        }

        var fileLists = baiduLoadPersistedFileListCache().filter { $0.value.expiresAt > now }
        baiduSavePersistedFileListCache(fileLists)

        let shareContexts = baiduLoadPersistedShareContextCache().filter { $0.value.expiresAt > now }
        baiduSavePersistedShareContextCache(shareContexts)

        let verifyCooldowns = baiduVerifyCooldownCache().filter { $0.value > now }
        if let data = try? JSONEncoder().encode(verifyCooldowns) {
            defaults.set(data, forKey: baiduVerifyCooldownKey)
        }

        var iBoxItems = baiduLoadPersistedIBoxPlayItemCache()
        for (key, item) in iBoxItems {
            guard let expiresAt = item.dlinkExpiresAt, expiresAt <= now else { continue }
            let cleanedItem = BaiduIBoxPlayItem(
                shareURL: item.shareURL,
                fsId: item.fsId,
                fileName: item.fileName,
                path: item.path,
                dlinkURL: nil,
                headers: item.headers,
                dlinkExpiresAt: nil,
                compatibilityHint: item.compatibilityHint,
                preferredEngine: item.preferredEngine,
                preparedAt: item.preparedAt,
                updatedAt: now,
                lastUsedAt: item.lastUsedAt,
                source: "\(item.source)-expired-cleaned"
            )
            iBoxItems[key] = cleanedItem
            mirrorBaiduIBoxPlayItemToUnified(cleanedItem, sourceKey: key)
        }
        if let data = try? JSONEncoder().encode(iBoxItems) {
            defaults.set(data, forKey: baiduIBoxPlayItemCacheKey)
        }
        clearExpiredUnifiedCloudPlayItems(provider: .baidu)

        playCache.removeAll(keepingCapacity: false)
        fileLists.removeAll(keepingCapacity: false)
        baiduLog("[Baidu-Cache] 已清理过期播放缓存，保留可复用 PlayItem/path")
        return baiduPlaybackCacheSummary()
    }

    @discardableResult
    func clearAllBaiduPlaybackCaches() -> BaiduPlaybackCacheSummary {
        baiduPlayCacheLock.lock()
        baiduPlayCache.removeAll()
        baiduPlayCacheLock.unlock()

        defaults.removeObject(forKey: baiduPersistedPlayCacheKey)
        defaults.removeObject(forKey: baiduPersistedPlayItemCacheKey)
        defaults.removeObject(forKey: baiduIBoxPlayItemCacheKey)
        defaults.removeObject(forKey: baiduFileListCacheKey)
        defaults.removeObject(forKey: baiduShareContextCacheKey)
        defaults.removeObject(forKey: baiduVerifyCooldownKey)
        clearUnifiedCloudPlayItems(provider: .baidu)

        baiduLog("[Baidu-Cache] 已清空全部百度播放缓存")
        return baiduPlaybackCacheSummary()
    }

    private func baiduCompatibilityHint(fileName: String) -> String {
        let lower = fileName.lowercased()
        let risky = ["mkv", "hevc", "h265", "x265", "10bit", "hdr", "高码率", "4k"]
        return risky.first(where: { lower.contains($0) }) ?? ""
    }

    private func baiduPreferredEngine(fileName: String) -> String {
        baiduCompatibilityHint(fileName: fileName).isEmpty ? "system" : "compatibility"
    }

    private func baiduStableHash(_ input: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    private func loadTokens() {
        if let data = defaults.data(forKey: tokenKey),
           let tokens = try? JSONDecoder().decode([DriveToken].self, from: data) {
            savedTokens = tokens
        }
    }

    private func saveTokens() {
        if let data = try? JSONEncoder().encode(savedTokens) {
            defaults.set(data, forKey: tokenKey)
        }
    }

    func addToken(type: DriveType, name: String, value: String) {
        savedTokens.removeAll { $0.type == type.rawValue && $0.name == name }
        savedTokens.append(DriveToken(type: type.rawValue, name: name, value: value))
        saveTokens()
        Task { @MainActor in
            CloudDriveAuthManager.shared.saveManualCredential(type: type, name: name, value: value)
        }
    }

    func addOrReplaceToken(type: DriveType, name: String, value: String) {
        if type == .baidu {
            // 百度仍保持 Web Cookie + PCS Cookie 的双 Token 设计。
            // 授权中心扫码/WebView 回写的是 BDUSS+STOKEN Web Cookie，不能误删/覆盖原有账号 Cookie 或可选 PCS Cookie。
            guard isBaiduAccountWebCookie(value) else {
                return
            }
            if savedTokens.contains(where: { $0.type == type.rawValue && $0.value == value }) {
                return
            }
            savedTokens.removeAll { $0.type == type.rawValue && $0.name == name }
        } else {
            savedTokens.removeAll { $0.type == type.rawValue }
        }
        savedTokens.append(DriveToken(type: type.rawValue, name: name, value: value))
        saveTokens()
    }

    @discardableResult
    func addOrReplaceBaiduPCSToken(name: String, value: String) -> Bool {
        let normalized = value
            .replacingOccurrences(of: "\n", with: "; ")
            .replacingOccurrences(of: "\r", with: "; ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isBaiduPCSCookie(normalized) else {
            baiduLog("[Baidu-Token] ⚠️ PCS Cookie 未包含 PANPSC/ptoken_bfess/ndut_fmt/nd_ftid，跳过保存")
            return false
        }

        savedTokens.removeAll { token in
            guard token.type == DriveType.baidu.rawValue else { return false }
            if token.name == name || token.value == normalized { return true }
            return isBaiduPCSToken(token) && token.name.hasPrefix("百度PCS-扫码")
        }
        savedTokens.append(DriveToken(type: DriveType.baidu.rawValue, name: name, value: normalized))
        saveTokens()
        baiduLog("[Baidu-Token] ✅ 已保存百度 PCS 高速 Cookie：\(name)")
        return true
    }

    func removeToken(at index: Int) {
        guard index >= 0, index < savedTokens.count else { return }
        savedTokens.remove(at: index)
        saveTokens()
    }

    private func ensureVboxFolder(drive: DriveType, token: String) async throws -> String {
        switch drive {
        case .quark:
            return try await quarkEnsureFolder(cookie: token)
        case .baidu:
            return try await baiduEnsureFolder(bduss: token)
        case .uc:
            return try await ucEnsureFolder(cookie: token)
        default:
            return ""
        }
    }

    private func scheduleCleanup(drive: DriveType, fileIds: [String], token: String, delay: TimeInterval = 180) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await cleanupFiles(drive: drive, fileIds: fileIds, token: token)
        }
    }

    private func cleanupFiles(drive: DriveType, fileIds: [String], token: String) async {
        print("[CloudDrive] 清理 \(drive.rawValue) 转存文件: \(fileIds.count) 个")
        switch drive {
        case .quark: await quarkDeleteFiles(fileIds: fileIds, cookie: token)
        case .baidu: await baiduDeleteFiles(fileIds: fileIds, bduss: token)
        case .uc: await ucDeleteFiles(fileIds: fileIds, cookie: token)
        default: break
        }
    }

    func tokens(for type: DriveType) -> [DriveToken] {
        var tokens = savedTokens.filter { $0.type == type.rawValue }
        if type == .baidu {
            tokens = tokens.filter { token in
                isBaiduPCSToken(token) || isBaiduAccountWebToken(token)
            }
        }
        if let value = CloudDriveAuthManager.shared.bestTokenValue(for: type), !value.isEmpty {
            let credential = CloudDriveAuthManager.shared.credential(for: type)
            let name = credential?.userName?.isEmpty == false ? credential!.userName! : "授权中心"
            if !tokens.contains(where: { $0.value == value }) {
                let authToken = DriveToken(type: type.rawValue, name: name, value: value)
                if type == .baidu {
                    // 百度 Worker 链路优先保持旧手动 Token 顺序，授权中心账号只作为兜底，避免改变原本可用 Worker Cookie。
                    tokens.append(authToken)
                } else {
                    tokens.insert(authToken, at: 0)
                }
            }
        }
        return tokens
    }

    func cleanupInvalidBaiduTokens() {
        let before = savedTokens.count
        savedTokens.removeAll { token in
            guard token.type == DriveType.baidu.rawValue else { return false }
            return !isBaiduPCSToken(token) && !isBaiduAccountWebToken(token)
        }
        if savedTokens.count != before {
            saveTokens()
        }
    }

    private func isBaiduPCSToken(_ token: DriveToken) -> Bool {
        let name = token.name.lowercased()
        if name.contains("pcs") || name.contains("下载") || name.contains("直链") || name.contains("locatedownload") {
            return true
        }
        return isBaiduPCSCookie(token.value)
    }

    private func isBaiduPCSCookie(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("panpsc=") || lower.contains("ptoken=") || lower.contains("ptoken_bfess=") || lower.contains("ndut_fmt=") || lower.contains("nd_ftid=")
    }

    private func isBaiduAccountWebCookie(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("bduss=") && lower.contains("stoken=")
    }

    private func isBaiduAccountWebToken(_ token: DriveToken) -> Bool {
        isBaiduAccountWebCookie(token.value)
    }

    func baiduTokenPair() -> (web: DriveToken, pcs: DriveToken?)? {
        let list = tokens(for: .baidu)
        guard !list.isEmpty else { return nil }

        guard let web = list.first(where: { isBaiduAccountWebToken($0) }) else {
            baiduLog("[Baidu-Token] ❌ 缺少百度 Web Cookie：需要同时包含 BDUSS 和 STOKEN，不能用 PCS Cookie 替代")
            return nil
        }
        let pcs = list.first(where: { isBaiduPCSToken($0) && $0.value != web.value })
            ?? list.first(where: { isBaiduPCSToken($0) })
        return (web, pcs)
    }

    static func detectDrive(from url: String) -> DriveType? {
        if url.contains("aliyundrive.com") || url.contains("alipan.com") { return .ali }
        if url.contains("pan.quark.cn") { return .quark }
        if url.contains("pan.baidu.com") { return .baidu }
        if url.contains("115.com") || url.contains("115cdn.com") { return .one15 }
        if url.contains("uc.cn") || url.contains("ucloud.cn") { return .uc }
        return nil
    }

    // MARK: - 阿里云盘

    func resolveAliPlayURL(shareURL: String, refreshToken: String) async throws -> PlayResult {
        print("[Ali] 开始解析: \(shareURL)")
        let tokenResult = try await aliRefreshAccessToken(refreshToken: refreshToken)
        let accessToken = tokenResult.accessToken

        let shareInfo = extractAliShareInfo(from: shareURL)
        guard !shareInfo.shareId.isEmpty else { throw DriveError.invalidShareURL }

        let shareToken = try await aliGetShareToken(
            shareId: shareInfo.shareId,
            sharePwd: shareInfo.sharePwd,
            token: accessToken
        )
        let file = try await aliFirstPlayableFile(
            shareId: shareInfo.shareId,
            parentFileId: "root",
            shareToken: shareToken,
            token: accessToken
        )
        print("[Ali] 选中资源：\(file.name), fileId=\(file.fileId)")

        let playInfo = try await aliGetVideoPreviewPlayInfo(fileId: file.fileId, shareToken: shareToken, token: accessToken)
        let taskList = playInfo.videoPreviewPlayInfo?.liveTranscodingTaskList ?? []
        let qualityOrder = ["QHD", "FHD", "HD", "SD", "LD"]
        let selectedURL = qualityOrder.compactMap { quality in
            taskList.first { ($0.templateId ?? "").uppercased().contains(quality) }?.url
        }.first ?? taskList.first(where: { ($0.url ?? "").isEmpty == false })?.url

        guard let playURL = selectedURL, !playURL.isEmpty else {
            throw DriveError.noPlayURL("阿里: 未获取到转码播放地址")
        }

        return PlayResult(
            url: playURL,
            headers: aliPlaybackHeaders(accessToken: accessToken, shareToken: shareToken),
            driveType: .ali,
            source: "share-token-preview"
        )
    }

    private func aliRefreshAccessToken(refreshToken: String) async throws -> AliTokenResponse {
        var request = URLRequest(url: URL(string: "https://auth.aliyundrive.com/v2/account/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(AliTokenResponse.self, from: data)
    }

    private func aliGetShareToken(shareId: String, sharePwd: String?, token: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.aliyundrive.com/v2/share_link/get_share_token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["share_id": shareId]
        if let sharePwd, !sharePwd.isEmpty { body["share_pwd"] = sharePwd }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = json["code"] as? String,
           code != "OK" {
            let message = json["message"] as? String ?? code
            throw DriveError.noPlayURL("阿里分享 token 获取失败：\(message)")
        }
        let result = try JSONDecoder().decode(AliShareTokenResponse.self, from: data)
        return result.shareToken
    }

    private struct AliShareFile {
        let fileId: String
        let name: String
        let type: String
        let category: String
    }

    private func aliGetShareFileList(shareId: String, parentFileId: String, shareToken: String, token: String) async throws -> [AliShareFile] {
        var request = URLRequest(url: URL(string: "https://api.aliyundrive.com/adrive/v3/file/list")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(shareToken, forHTTPHeaderField: "x-share-token")
        request.setValue("https://www.aliyundrive.com/", forHTTPHeaderField: "Referer")
        let body: [String: Any] = [
            "share_id": shareId,
            "parent_file_id": parentFileId,
            "limit": 100,
            "order_by": "name",
            "order_direction": "ASC"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: request)

        let respStr = String(data: data, encoding: .utf8) ?? ""
        print("[Ali] 文件列表响应: \(respStr.prefix(500))")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[Ali] ❌ 文件列表响应非JSON")
            throw DriveError.invalidResponse
        }

        guard let items = json["items"] as? [[String: Any]] else {
            if let code = json["code"] as? String, code != "OK" {
                let message = json["message"] as? String ?? "未知错误"
                print("[Ali] ❌ API错误: \(message)")
                throw DriveError.noPlayURL("阿里: \(message)")
            }
            print("[Ali] ❌ 文件列表为空")
            throw DriveError.noPlayURL("阿里: 分享为空或已失效")
        }

        return items.compactMap { item in
            let fileId = item["file_id"] as? String ?? ""
            let name = item["name"] as? String ?? item["file_name"] as? String ?? ""
            let type = item["type"] as? String ?? ""
            let category = item["category"] as? String ?? ""
            guard !fileId.isEmpty, !name.isEmpty else { return nil }
            return AliShareFile(fileId: fileId, name: name, type: type, category: category)
        }
    }

    private func aliFirstPlayableFile(shareId: String, parentFileId: String, shareToken: String, token: String) async throws -> AliShareFile {
        let files = try await aliGetShareFileList(
            shareId: shareId,
            parentFileId: parentFileId,
            shareToken: shareToken,
            token: token
        )
        if let playable = files.first(where: { aliIsPlayable(file: $0) }) {
            return playable
        }
        for folder in files where folder.type.lowercased() == "folder" {
            if let found = try? await aliFirstPlayableFile(
                shareId: shareId,
                parentFileId: folder.fileId,
                shareToken: shareToken,
                token: token
            ) {
                return found
            }
        }
        throw DriveError.noPlayURL("阿里: 分享内未找到可播放视频")
    }

    private func aliIsPlayable(file: AliShareFile) -> Bool {
        if file.category.lowercased() == "video" { return true }
        let lower = file.name.lowercased()
        return ["mp4", "mkv", "mov", "m3u8", "avi", "wmv", "flv", "ts", "m4v"].contains { lower.hasSuffix(".\($0)") }
    }

    private func aliGetVideoPreviewPlayInfo(fileId: String, shareToken: String, token: String) async throws -> AliVideoPreviewResponse {
        let url = URL(string: "https://api.aliyundrive.com/adrive/v2/file/get_video_preview_play_info")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(shareToken, forHTTPHeaderField: "x-share-token")
        request.setValue("https://www.aliyundrive.com/", forHTTPHeaderField: "Referer")
        let body: [String: Any] = [
            "file_id": fileId,
            "category": "live_transcoding"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)

        let respStr = String(data: data, encoding: .utf8) ?? ""
        print("[Ali] 播放信息响应: \(respStr.prefix(500))")

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let code = json["code"] as? String, code != "OK" {
                let message = json["message"] as? String ?? "获取播放地址失败"
                print("[Ali] ❌ API错误: \(message)")
                throw DriveError.noPlayURL("阿里: \(message)")
            }
        }

        do {
            let result = try JSONDecoder().decode(AliVideoPreviewResponse.self, from: data)

            guard let taskList = result.videoPreviewPlayInfo?.liveTranscodingTaskList, !taskList.isEmpty else {
                print("[Ali] ❌ 没有可用的转码任务列表")
                throw DriveError.noPlayURL("阿里: 该文件无视频播放地址")
            }

            let qualities = ["FHD", "HD", "SD", "LD"]
            for quality in qualities {
                if let task = taskList.first(where: { $0.templateId?.contains(quality) == true }), let url = task.url {
                    print("[Ali] ✅ 获取到播放地址 (\(quality))")
                    return result
                }
            }

            if taskList.first?.url != nil {
                print("[Ali] ✅ 获取到播放地址")
                return result
            }

            print("[Ali] ❌ 转码任务列表中没有有效的URL")
            throw DriveError.noPlayURL("阿里: 视频转码未完成")
        } catch {
            print("[Ali] ❌ JSON解码失败: \(error)")
            throw DriveError.invalidResponse
        }
    }

    private func extractAliShareInfo(from url: String) -> (shareId: String, sharePwd: String?) {
        var shareId = ""
        var sharePwd: String? = nil
        if let range = url.range(of: #"/s/([^/?#]+)"#, options: .regularExpression) {
            shareId = String(url[range]).replacingOccurrences(of: "/s/", with: "")
        } else {
            shareId = url.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let queryItems = URLComponents(string: url)?.queryItems ?? []
        sharePwd = queryItems.first(where: { ["pwd", "password", "share_pwd"].contains($0.name.lowercased()) })?.value
        if sharePwd == nil, let range = url.range(of: #"(提取码|密码)[:：\s]*([A-Za-z0-9]{4,8})"#, options: .regularExpression) {
            let matched = String(url[range])
            sharePwd = matched.components(separatedBy: CharacterSet(charactersIn: ":： ")).last
        }
        return (shareId, sharePwd)
    }

    private func aliPlaybackHeaders(accessToken: String, shareToken: String) -> [String: String] {
        [
            "Authorization": "Bearer \(accessToken)",
            "x-share-token": shareToken,
            "Referer": "https://www.aliyundrive.com/",
            "Origin": "https://www.aliyundrive.com",
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 AliApp(AYSD/6.0.0) Mobile/15E148",
            "Accept": "*/*",
            "Accept-Encoding": "identity"
        ]
    }

    // MARK: - 夸克网盘

    func resolveQuarkPlayURL(shareURL: String, cookie: String) async throws -> PlayResult {
        print("[Quark] 开始解析: \(shareURL)")
        let (pwdId, passcode) = quarkExtractShareInfo(shareURL: shareURL)
        print("[Quark] pwdId=\(pwdId), passcode=\(passcode.isEmpty ? "无" : "已传递")")
        guard !pwdId.isEmpty else {
            throw DriveError.invalidShareURL
        }

        var authCookie = cookie
        let folder = try await quarkEnsureFolderWithCookie(cookie: authCookie)
        authCookie = folder.cookie
        print("[Quark] folderId=\(folder.folderId.isEmpty ? "空" : folder.folderId), hasPUUS=\(authCookie.contains("__puus="))")

        let shareToken = try await quarkGetShareToken(pwdId: pwdId, passcode: passcode, cookie: authCookie)
        print("[Quark] stoken=\(shareToken.isEmpty ? "空" : "已获取")")

        let sourceFile = try await quarkFirstPlayableFile(pwdId: pwdId, stoken: shareToken, pdirFid: "0", cookie: authCookie)
        print("[Quark] 选中资源：\(sourceFile.fileName), fid=\(sourceFile.fid)")

        let fileIds = try await quarkSaveShare(
            pwdId: pwdId,
            stoken: shareToken,
            file: sourceFile,
            folderId: folder.folderId,
            cookie: authCookie
        )
        print("[Quark] 转存完成 fileIds=\(fileIds)")

        guard let fileId = fileIds.first else { throw DriveError.noPlayURL("夸克: 转存后未返回文件ID") }
        // 抓包里的实际播放主链路是：先调 v2/play 刷新 Video-Auth，再用 file/download 的 download_url 走 Range 播放。
        // v2/play 返回的 m3u8 只作为兜底，避免直接播放 m3u8 时分片未代理导致 403。
        var transcodeURL = ""
        do {
            let playInfo = try await quarkRefreshVideoAuth(fileId: fileId, cookie: authCookie)
            authCookie = playInfo.cookie
            transcodeURL = playInfo.playURL
            print("[Quark] v2/play 完成 hasVideoAuth=\(authCookie.contains("Video-Auth=")), transcodeURL=\(transcodeURL.isEmpty ? "空" : "已获取")")
        } catch {
            print("[Quark] ⚠️ v2/play 刷新 Video-Auth 失败，继续尝试 download_url: \(error.localizedDescription)")
        }

        let download = try await quarkGetDownloadURL(fileId: fileId, cookie: authCookie)
        let playURL: String
        let source: String
        if !download.url.isEmpty {
            playURL = download.url
            source = "download_url"
        } else if !transcodeURL.isEmpty {
            playURL = transcodeURL
            source = "v2-play-fallback"
        } else {
            throw DriveError.noPlayURL("夸克: download_url 和转码地址均为空")
        }
        let fallbackURL: String?
        let fallbackSource: String?
        if source == "download_url", !transcodeURL.isEmpty {
            fallbackURL = transcodeURL
            fallbackSource = "v2-play-m3u8"
        } else if source == "v2-play-fallback", !download.url.isEmpty {
            fallbackURL = download.url
            fallbackSource = "download_url"
        } else {
            fallbackURL = nil
            fallbackSource = nil
        }

        print("[Quark] ✅ 主线路 source=\(source), hasPUUS=\(authCookie.contains("__puus=")), hasVideoAuth=\(authCookie.contains("Video-Auth=")), host=\(URL(string: playURL)?.host ?? "unknown")")
        if let fallbackURL, let fallbackSource {
            print("[Quark] ✅ 兜底线路 source=\(fallbackSource), host=\(URL(string: fallbackURL)?.host ?? "unknown")")
        } else {
            print("[Quark] ⚠️ 兜底线路暂不可用，当前仅返回主线路")
        }

        scheduleCleanup(drive: .quark, fileIds: fileIds, token: authCookie, delay: 60 * 60)

        let playbackHeaders = quarkPlaybackHeaders(cookie: authCookie)

        return PlayResult(
            url: playURL,
            headers: playbackHeaders,
            driveType: .quark,
            source: source,
            fallbackURL: fallbackURL,
            fallbackHeaders: fallbackURL == nil ? nil : playbackHeaders,
            fallbackSource: fallbackSource
        )
    }

    private struct QuarkShareFile {
        let fid: String
        let fileName: String
        let shareFidToken: String
        let pdirFid: String
        let isDir: Bool
    }

    private func quarkExtractShareInfo(shareURL: String) -> (pwdId: String, passcode: String) {
        var pwdId = ""
        if let url = URL(string: shareURL) {
            let comps = url.path.split(separator: "/").map(String.init)
            if let sIndex = comps.firstIndex(of: "s"), comps.count > sIndex + 1 {
                pwdId = comps[sIndex + 1]
            } else if let last = comps.last, !last.isEmpty {
                pwdId = last
            }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let passcode = query.first(where: { ["pwd", "passcode", "password"].contains($0.name.lowercased()) })?.value ?? ""
            return (pwdId, passcode)
        }

        let cleaned = shareURL
            .replacingOccurrences(of: #".*/s/"#, with: "", options: .regularExpression)
            .components(separatedBy: "?")
            .first ?? shareURL
        pwdId = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        var passcode = ""
        if let range = shareURL.range(of: #"(pwd|passcode|password)=([^&]+)"#, options: .regularExpression) {
            let text = String(shareURL[range])
            passcode = text.components(separatedBy: "=").last ?? ""
        }
        return (pwdId, passcode)
    }

    private func quarkAPIURL(_ path: String, extra: [URLQueryItem] = []) -> URL {
        var components = URLComponents(string: "https://drive-pc.quark.cn\(path)")!
        components.queryItems = [
            URLQueryItem(name: "pr", value: "ucpro"),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "uc_param_str", value: "")
        ] + extra
        return components.url!
    }

    private func quarkSetCommonHeaders(_ request: inout URLRequest, cookie: String, referer: String = "https://pan.quark.cn/") {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch", forHTTPHeaderField: "User-Agent")
    }

    private func quarkShareReferer(pwdId: String) -> String {
        guard !pwdId.isEmpty else { return "https://pan.quark.cn/" }
        return "https://pan.quark.cn/s/\(pwdId)"
    }

    private func quarkStrictQueryEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func quarkAPIURLWithStrictQuery(_ path: String, queryItems: [URLQueryItem], strictQueryItems: [(String, String)]) -> URL {
        var components = URLComponents(string: "https://drive-pc.quark.cn\(path)")!
        components.queryItems = [
            URLQueryItem(name: "pr", value: "ucpro"),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "uc_param_str", value: "")
        ] + queryItems
        var query = components.percentEncodedQuery ?? ""
        for (name, value) in strictQueryItems {
            if !query.isEmpty { query += "&" }
            query += "\(quarkStrictQueryEncode(name))=\(quarkStrictQueryEncode(value))"
        }
        components.percentEncodedQuery = query
        return components.url!
    }

    private func quarkPlaybackHeaders(cookie: String) -> [String: String] {
        // 抓包显示 PC 客户端拉取 download_url 直链时用的就是 quark-cloud-drive 的 PC UA。
        // 切换为移动 UA 容易让签名链返回 403/未知错误，这里统一与 API 阶段保持一致。
        [
            "Cookie": cookie,
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch",
            "Referer": "https://pan.quark.cn/",
            "Origin": "https://pan.quark.cn",
            "Accept": "*/*",
            "Accept-Encoding": "identity"
        ]
    }

    private func quarkMergeSetCookie(from response: URLResponse, into cookie: String) -> String {
        guard let http = response as? HTTPURLResponse else { return cookie }
        var cookieDict = quarkCookieDictionary(from: cookie)
        var headerFields: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headerFields["\(key)"] = "\(value)"
        }
        let responseCookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: URL(string: "https://drive-pc.quark.cn")!)
        for item in responseCookies {
            cookieDict[item.name] = item.value
        }
        return quarkCookieString(from: cookieDict)
    }

    private func quarkCookieDictionary(from cookie: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in cookie.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    private func quarkCookieString(from dict: [String: String]) -> String {
        let preferred = ["__kps", "__puus", "ctoken", "__pus", "__ktd", "__kp", "__uid", "__sdid", "Video-Auth"]
        var used = Set<String>()
        var parts: [String] = []
        for key in preferred {
            if let value = dict[key], !value.isEmpty {
                parts.append("\(key)=\(value)")
                used.insert(key)
            }
        }
        for key in dict.keys.sorted() where !used.contains(key) {
            if let value = dict[key], !value.isEmpty {
                parts.append("\(key)=\(value)")
            }
        }
        return parts.joined(separator: "; ")
    }

    private func quarkGetShareToken(pwdId: String, passcode: String, cookie: String) async throws -> String {
        let url = quarkAPIURL("/1/clouddrive/share/sharepage/token", extra: [URLQueryItem(name: "__t", value: String(Int(Date().timeIntervalSince1970 * 1000)))])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        quarkSetCommonHeaders(&request, cookie: cookie, referer: quarkShareReferer(pwdId: pwdId))
        let body: [String: Any] = ["pwd_id": pwdId, "passcode": passcode]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
            throw DriveError.noPlayURL("夸克分享 token 获取失败：\(message)")
        }
        guard let dataObj = json["data"] as? [String: Any],
              let st = dataObj["stoken"] as? String,
              !st.isEmpty else {
            throw DriveError.noPlayURL("夸克未返回 stoken")
        }
        let hasPlus = st.contains("+")
        let hasSlash = st.contains("/")
        let hasEqual = st.contains("=")
        print("[Quark] stoken诊断 length=\(st.count), hasPlus=\(hasPlus), hasSlash=\(hasSlash), hasEqual=\(hasEqual)")
        return st
    }

    private func quarkEnsureFolder(cookie: String) async throws -> String {
        (try await quarkEnsureFolderWithCookie(cookie: cookie)).folderId
    }

    private func quarkEnsureFolderWithCookie(cookie: String) async throws -> (folderId: String, cookie: String) {
        if let visibleFolder = try? await quarkFindOrCreateVisibleFolder(cookie: cookie) {
            return visibleFolder
        }

        print("[Quark] ⚠️ 可见 vbox 目录不可用，回退 sharepage/dir 默认转存目录")
        let listURL = quarkAPIURL("/1/clouddrive/share/sharepage/dir", extra: [URLQueryItem(name: "aver", value: "1")])
        var req = URLRequest(url: listURL)
        req.httpMethod = "GET"
        quarkSetCommonHeaders(&req, cookie: cookie)
        let (data, response) = try await session.data(for: req)
        let mergedCookie = quarkMergeSetCookie(from: response, into: cookie)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataObj = json["data"] as? [String: Any],
           let fid = dataObj["pdir_fid"] as? String,
           !fid.isEmpty {
            return (fid, mergedCookie)
        }
        throw DriveError.noPlayURL("夸克：无法获取转存目录")
    }

    private func quarkFindOrCreateVisibleFolder(cookie: String) async throws -> (folderId: String, cookie: String) {
        if let folder = try await quarkFindVisibleFolder(cookie: cookie) {
            print("[Quark] 使用根目录 vbox 文件夹 fid=\(folder.folderId)")
            return folder
        }

        let createURL = quarkAPIURL("/1/clouddrive/file")
        var request = URLRequest(url: createURL)
        request.httpMethod = "POST"
        quarkSetCommonHeaders(&request, cookie: cookie)
        let body: [String: Any] = [
            "pdir_fid": "0",
            "file_name": "vbox",
            "dir": true,
            "dir_path": ""
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let mergedCookie = quarkMergeSetCookie(from: response, into: cookie)
        let preview = String(data: data.prefix(500), encoding: .utf8) ?? ""
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[Quark] ❌ 创建 vbox 目录响应非JSON: \(preview)")
            throw DriveError.invalidResponse
        }

        if let status = json["status"] as? Int, status != 200 {
            let message = json["message"] as? String ?? json["msg"] as? String ?? "状态码: \(status)"
            print("[Quark] ❌ 创建 vbox 目录失败: \(message), preview=\(preview)")
            throw DriveError.noPlayURL("夸克创建 vbox 目录失败：\(message)")
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? json["msg"] as? String ?? "错误码: \(code)"
            print("[Quark] ❌ 创建 vbox 目录失败: \(message), preview=\(preview)")
            throw DriveError.noPlayURL("夸克创建 vbox 目录失败：\(message)")
        }

        if let fid = quarkExtractFirstFid(from: json), !fid.isEmpty {
            print("[Quark] ✅ 已创建根目录 vbox 文件夹 fid=\(fid)")
            return (fid, mergedCookie)
        }

        if let folder = try await quarkFindVisibleFolder(cookie: mergedCookie) {
            print("[Quark] ✅ 创建后查找到 vbox 文件夹 fid=\(folder.folderId)")
            return folder
        }

        print("[Quark] ❌ 创建 vbox 目录成功但未返回 fid: \(preview)")
        throw DriveError.noPlayURL("夸克创建 vbox 目录后未返回 fid")
    }

    private func quarkFindVisibleFolder(cookie: String) async throws -> (folderId: String, cookie: String)? {
        let listURL = quarkAPIURL("/1/clouddrive/file/sort")
        var request = URLRequest(url: listURL)
        request.httpMethod = "POST"
        quarkSetCommonHeaders(&request, cookie: cookie)
        let body: [String: Any] = [
            "pdir_fid": "0",
            "sort_by": "file_name",
            "sort_order": "asc",
            "page": 1,
            "size": 100
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let mergedCookie = quarkMergeSetCookie(from: response, into: cookie)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let list = dataObj["list"] as? [[String: Any]] else {
            return nil
        }

        for item in list {
            let name = item["file_name"] as? String ?? item["name"] as? String ?? ""
            let isDir = (item["dir"] as? Bool) ?? ((item["file"] as? Bool) == false && (item["file_type"] as? Int) == 0)
            guard name == "vbox", isDir else { continue }
            if let fid = item["fid"] as? String, !fid.isEmpty { return (fid, mergedCookie) }
            if let fileId = item["file_id"] as? String, !fileId.isEmpty { return (fileId, mergedCookie) }
            if let fid = item["fid"] as? Int { return (String(fid), mergedCookie) }
            if let fileId = item["file_id"] as? Int { return (String(fileId), mergedCookie) }
        }

        return nil
    }

    private func quarkExtractFirstFid(from value: Any) -> String? {
        if let dict = value as? [String: Any] {
            for key in ["fid", "file_id", "pdir_fid"] {
                if let text = dict[key] as? String, !text.isEmpty { return text }
                if let number = dict[key] as? Int { return String(number) }
            }
            for item in dict.values {
                if let fid = quarkExtractFirstFid(from: item) { return fid }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let fid = quarkExtractFirstFid(from: item) { return fid }
            }
        }
        return nil
    }

    private func quarkDeleteFiles(fileIds: [String], cookie: String) async {
        guard !fileIds.isEmpty else { return }
        let url = quarkAPIURL("/1/clouddrive/file/delete")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        quarkSetCommonHeaders(&req, cookie: cookie)
        let body: [String: Any] = ["action_type": 2, "filelist": fileIds, "exclude_fids": []]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let _ = try? await session.data(for: req)
        print("[CloudDrive] ✅ 夸克已提交删除 \(fileIds.count) 个转存文件")
    }

    private func quarkFirstPlayableFile(pwdId: String, stoken: String, pdirFid: String, cookie: String) async throws -> QuarkShareFile {
        let files = try await quarkGetShareDetail(pwdId: pwdId, stoken: stoken, pdirFid: pdirFid, cookie: cookie)
        if let playable = files.first(where: { !$0.isDir && quarkIsPlayableFileName($0.fileName) }) {
            return playable
        }
        for dir in files where dir.isDir {
            if let found = try? await quarkFirstPlayableFile(pwdId: pwdId, stoken: stoken, pdirFid: dir.fid, cookie: cookie) {
                return found
            }
        }
        throw DriveError.noPlayURL("夸克分享内未找到可播放视频")
    }

    private func quarkGetShareDetail(pwdId: String, stoken: String, pdirFid: String, cookie: String) async throws -> [QuarkShareFile] {
        let url = quarkAPIURLWithStrictQuery("/1/clouddrive/share/sharepage/detail", queryItems: [
            URLQueryItem(name: "__t", value: String(Int(Date().timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "_fetch_banner", value: "1"),
            URLQueryItem(name: "_fetch_total", value: "1"),
            URLQueryItem(name: "_page", value: "1"),
            URLQueryItem(name: "_size", value: "100"),
            URLQueryItem(name: "_sort", value: "file_type:asc,file_name:asc"),
            URLQueryItem(name: "force", value: "0"),
            URLQueryItem(name: "pdir_fid", value: pdirFid),
            URLQueryItem(name: "pwd_id", value: pwdId)
        ], strictQueryItems: [("stoken", stoken)])
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        quarkSetCommonHeaders(&request, cookie: cookie, referer: quarkShareReferer(pwdId: pwdId))
        let stokenHasPlus = stoken.contains("+")
        let encodedPlus = url.absoluteString.contains("%2B")
        print("[Quark] detail请求诊断 pdirFid=\(pdirFid), stokenLength=\(stoken.count), stokenHasPlus=\(stokenHasPlus), encodedPlus=\(encodedPlus)")
        let (data, response) = try await session.data(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? ""
            print("[Quark] ❌ detail非JSON status=\(httpStatus), preview=\(preview)")
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? ""
            print("[Quark] ❌ detail失败 status=\(httpStatus), code=\(code), message=\(message), preview=\(preview)")
            throw DriveError.noPlayURL("夸克文件列表失败：\(message)")
        }
        guard let dataObj = json["data"] as? [String: Any],
              let list = dataObj["list"] as? [[String: Any]] else {
            throw DriveError.noPlayURL("夸克文件列表为空")
        }
        return list.compactMap { item in
            let fid = item["fid"] as? String ?? ""
            let name = item["file_name"] as? String ?? item["name"] as? String ?? ""
            let token = item["share_fid_token"] as? String ?? item["fid_token"] as? String ?? ""
            let isDir = (item["dir"] as? Bool) ?? ((item["file"] as? Bool) == false && (item["file_type"] as? Int) == 0)
            guard !fid.isEmpty, !name.isEmpty else { return nil }
            return QuarkShareFile(fid: fid, fileName: name, shareFidToken: token, pdirFid: pdirFid, isDir: isDir)
        }
    }

    private func quarkIsPlayableFileName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["mp4", "mkv", "mov", "m3u8", "avi", "wmv", "flv", "ts", "mp3", "m4a"].contains { lower.hasSuffix(".\($0)") }
    }

    private func quarkSaveShare(pwdId: String, stoken: String, file: QuarkShareFile, folderId: String, cookie: String) async throws -> [String] {
        let url = quarkAPIURL("/1/clouddrive/share/sharepage/save", extra: [URLQueryItem(name: "__t", value: String(Int(Date().timeIntervalSince1970 * 1000)))])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        quarkSetCommonHeaders(&request, cookie: cookie, referer: quarkShareReferer(pwdId: pwdId))
        let body: [String: Any] = [
            "fid_list": [file.fid],
            "fid_token_list": [file.shareFidToken],
            "to_pdir_fid": folderId,
            "pwd_id": pwdId,
            "stoken": stoken,
            "pdir_fid": file.pdirFid,
            "scene": "link"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)

        let respStr = String(data: data, encoding: .utf8) ?? ""
        print("[Quark] save响应: \(respStr.prefix(500))")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[Quark] ❌ 转存响应非JSON")
            throw DriveError.saveFailed
        }

        if let status = json["status"] as? Int, status != 200 {
            let message = json["message"] as? String ?? json["msg"] as? String ?? "状态码: \(status)"
            print("[Quark] ❌ 转存失败: \(message)")
            throw DriveError.noPlayURL("夸克转存失败: \(message)")
        }

        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? json["msg"] as? String ?? "错误码: \(code)"
            print("[Quark] ❌ 转存失败: \(message)")
            throw DriveError.noPlayURL("夸克转存失败: \(message)")
        }

        if let d = json["data"] as? [String: Any] {
            let taskResp = d["task_resp"] as? [String: Any]
            let taskData = taskResp?["data"] as? [String: Any]
            let saveAs = taskData?["save_as"] as? [String: Any]
            if let ids = saveAs?["save_as_top_fids"] as? [String], !ids.isEmpty {
                print("[Quark] ✅ 转存成功，save_as_top_fids: \(ids)")
                return ids
            }
            if let ids = saveAs?["save_as_select_top_fids"] as? [String], !ids.isEmpty {
                print("[Quark] ✅ 转存成功，save_as_select_top_fids: \(ids)")
                return ids
            }
            if let ids = d["file_ids"] as? [String], !ids.isEmpty {
                return ids
            }
            if let list = d["list"] as? [[String: Any]], !list.isEmpty {
                let ids = list.compactMap { $0["fid"] as? String ?? $0["file_id"] as? String }
                if !ids.isEmpty {
                    return ids
                }
            }
        }

        let recursiveIds = quarkExtractSavedFileIds(from: json, excluding: file.fid)
        if !recursiveIds.isEmpty {
            print("[Quark] ✅ 转存成功，递归提取 fid: \(recursiveIds)")
            return recursiveIds
        }

        if let existingId = await quarkFindSavedFileId(fileName: file.fileName, folderId: folderId, cookie: cookie) {
            print("[Quark] ✅ 转存目录已存在同名文件，使用 fid=\(existingId)")
            return [existingId]
        }

        throw DriveError.noPlayURL("夸克转存成功但未返回已转存 fid")
    }

    private func quarkExtractSavedFileIds(from value: Any, excluding sourceFid: String) -> [String] {
        var result: [String] = []

        func append(_ raw: Any, key: String) {
            let lowerKey = key.lowercased()
            guard lowerKey.contains("fid") || lowerKey.contains("file_id") else { return }
            guard !lowerKey.contains("token") else { return }
            if let text = raw as? String, !text.isEmpty, text != sourceFid {
                result.append(text)
            } else if let number = raw as? Int {
                let text = String(number)
                if text != sourceFid { result.append(text) }
            } else if let texts = raw as? [String] {
                result.append(contentsOf: texts.filter { !$0.isEmpty && $0 != sourceFid })
            } else if let numbers = raw as? [Int] {
                result.append(contentsOf: numbers.map(String.init).filter { $0 != sourceFid })
            }
        }

        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                for (key, item) in dict {
                    append(item, key: key)
                    walk(item)
                }
            } else if let array = node as? [Any] {
                for item in array { walk(item) }
            }
        }

        walk(value)
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    private func quarkFindSavedFileId(fileName: String, folderId: String, cookie: String) async -> String? {
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 800_000_000)
            }

            let url = quarkAPIURL("/1/clouddrive/file/sort")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            quarkSetCommonHeaders(&request, cookie: cookie)
            let body: [String: Any] = [
                "pdir_fid": folderId,
                "sort_by": "file_name",
                "sort_order": "asc",
                "page": 1,
                "size": 100
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            guard let (data, _) = try? await session.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any],
                  let list = dataObj["list"] as? [[String: Any]] else {
                continue
            }

            for item in list {
                let name = item["file_name"] as? String ?? item["name"] as? String ?? ""
                guard name == fileName else { continue }
                if let fid = item["fid"] as? String, !fid.isEmpty { return fid }
                if let fileId = item["file_id"] as? String, !fileId.isEmpty { return fileId }
                if let fid = item["fid"] as? Int { return String(fid) }
                if let fileId = item["file_id"] as? Int { return String(fileId) }
            }
        }
        return nil
    }

    private func quarkGetDownloadURL(fileId: String, cookie: String) async throws -> (url: String, fileName: String) {
        let url = quarkAPIURL("/1/clouddrive/file/download")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        quarkSetCommonHeaders(&request, cookie: cookie)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fids": [fileId]])
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
            throw DriveError.noPlayURL("夸克 download_url 获取失败：\(message)")
        }
        guard let list = json["data"] as? [[String: Any]],
              let first = list.first else {
            throw DriveError.noPlayURL("夸克未返回 download_url 数据")
        }
        let downloadURL = first["download_url"] as? String ?? ""
        let fileName = first["file_name"] as? String ?? ""
        return (downloadURL, fileName)
    }

    private func quarkGetPlayURL(fileId: String, cookie: String) async throws -> String {
        let info = try await quarkRefreshVideoAuth(fileId: fileId, cookie: cookie)
        return info.playURL
    }

    private func quarkRefreshVideoAuth(fileId: String, cookie: String) async throws -> (playURL: String, cookie: String) {
        let url = quarkAPIURL("/1/clouddrive/file/v2/play")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        quarkSetCommonHeaders(&request, cookie: cookie)
        let body: [String: Any] = [
            "fid": fileId,
            "resolutions": "normal,low,high,super,2k,4k",
            "supports": "fmp4,m3u8"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let mergedCookie = quarkMergeSetCookie(from: response, into: cookie)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
            throw DriveError.noPlayURL("夸克 v2/play 失败：\(message)")
        }
        if let dataObj = json["data"] as? [String: Any],
           let videos = dataObj["video_list"] as? [[String: Any]] {
            for item in videos {
                guard (item["accessable"] as? Bool) != false,
                      let info = item["video_info"] as? [String: Any],
                      let url = info["url"] as? String,
                      !url.isEmpty else { continue }
                return (url, mergedCookie)
            }
        }
        if let playURL = json["play_url"] as? String, !playURL.isEmpty {
            return (playURL, mergedCookie)
        }
        return ("", mergedCookie)
    }

    // MARK: - 夸克原生扫码登录（测试版）
    // 抓包显示 PC 客户端走 uop.quark.cn/cas/ajax 三步：
    //  1. getTokenForQrcodeLogin → 拿 token
    //  2. getServiceTicketByQrcodeToken（轮询，未扫返回 50004001）
    //  3. 拿到 service_ticket 后，请求 pan.quark.cn/account/info?st=... 让服务端 set-cookie

    struct QuarkQrLoginToken {
        let token: String
        let clientId: String   // 生成 token 时使用 386；轮询时 PC 抓包用 532，这里都保留
        let pollClientId: String
        let qrPayload: String   // 真实二维码内容，抓包为 su.quark.cn 跳转链接，不是 token 原文
    }

    enum QuarkQrPollResult {
        case pending
        case scanned       // 兼容字段，目前接口不区分
        case success(serviceTicket: String)
        case expired
        case failed(message: String)
    }

    struct QuarkQrLoginResult {
        let cookie: String                    // 拼好的 Cookie 字符串：__pus=...; __puus=...; ...
        let cookies: [String: String]         // 单独字段，便于调试展示
        let nickName: String?
        let avatarURL: String?
    }

    /// 第一步：生成扫码登录 token，并拼出抓包里的二维码跳转链接。
    func quarkCreateQrToken(clientId: String = "386", pollClientId: String = "532") async throws -> QuarkQrLoginToken {
        var components = URLComponents(string: "https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin")!
        components.queryItems = [
            URLQueryItem(name: "pr", value: "ucpro"),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "sys", value: "darwin"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "v", value: "1.2"),
            URLQueryItem(name: "request_id", value: UUID().uuidString.lowercased())
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.54 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DriveError.noPlayURL("夸克: 获取扫码 token HTTP 失败")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        let status = (json["status"] as? Int) ?? -1
        guard status == 2000000,
              let dataObj = json["data"] as? [String: Any],
              let members = dataObj["members"] as? [String: Any],
              let token = members["token"] as? String, !token.isEmpty else {
            let message = (json["message"] as? String) ?? "夸克扫码 token 接口异常"
            throw DriveError.noPlayURL("夸克: \(message)")
        }
        let qrPayload = quarkQRCodePayload(token: token, clientId: pollClientId)
        return QuarkQrLoginToken(token: token, clientId: clientId, pollClientId: pollClientId, qrPayload: qrPayload)
    }

    private func quarkQRCodePayload(token: String, clientId: String) -> String {
        var components = URLComponents(string: "https://su.quark.cn/4_eMHBJ")!
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "ssb", value: "weblogin"),
            URLQueryItem(name: "uc_param_str", value: ""),
            URLQueryItem(name: "uc_biz_str", value: "S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0")
        ]
        return components.url?.absoluteString ?? "https://su.quark.cn/4_eMHBJ?token=\(token)&client_id=\(clientId)&ssb=weblogin"
    }

    /// 第二步：轮询扫码状态。pending 表示用户还没扫码或还没确认；success 时返回 service_ticket。
    func quarkPollQrStatus(token: QuarkQrLoginToken) async throws -> QuarkQrPollResult {
        var components = URLComponents(string: "https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: token.pollClientId),
            URLQueryItem(name: "v", value: "1.2"),
            URLQueryItem(name: "request_id", value: UUID().uuidString.lowercased()),
            URLQueryItem(name: "token", value: token.token)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.54 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        let status = (json["status"] as? Int) ?? -1
        let message = (json["message"] as? String) ?? ""
        switch status {
        case 2000000:
            if let dataObj = json["data"] as? [String: Any],
               let members = dataObj["members"] as? [String: Any],
               let ticket = members["service_ticket"] as? String, !ticket.isEmpty {
                return .success(serviceTicket: ticket)
            }
            return .failed(message: "未返回 service_ticket")
        case 50004001:
            return .pending
        case 50004002, 50004003, 50004004:
            return .expired
        default:
            return .failed(message: "状态码 \(status) \(message)")
        }
    }

    /// 第三步：用 service_ticket 换取浏览器侧 Cookie。响应里的 set-cookie 就是登录态。
    func quarkExchangeServiceTicket(serviceTicket: String) async throws -> QuarkQrLoginResult {
        var components = URLComponents(string: "https://pan.quark.cn/account/info")!
        components.queryItems = [
            URLQueryItem(name: "st", value: serviceTicket),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "platform", value: "pc")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.54 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        // 使用一次性配置以拿到 set-cookie
        let oneShotConfig = URLSessionConfiguration.ephemeral
        oneShotConfig.httpCookieAcceptPolicy = .always
        oneShotConfig.httpShouldSetCookies = true
        let oneShotSession = URLSession(configuration: oneShotConfig)
        defer { oneShotSession.finishTasksAndInvalidate() }

        let (data, response) = try await oneShotSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DriveError.noPlayURL("夸克: account/info HTTP 失败")
        }

        // 解析 set-cookie 头（合并多行的几种 case）
        var cookieDict: [String: String] = [:]
        var stringHeaders: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            stringHeaders["\(key)"] = "\(value)"
        }
        let responseCookies = HTTPCookie.cookies(withResponseHeaderFields: stringHeaders, for: URL(string: "https://pan.quark.cn")!)
        for c in responseCookies { cookieDict[c.name] = c.value }

        if let storage = oneShotSession.configuration.httpCookieStorage,
           let cookies = storage.cookies(for: URL(string: "https://pan.quark.cn")!) {
            for c in cookies { cookieDict[c.name] = c.value }
        }
        // 兜底再从响应头里抓一遍
        let headers = http.allHeaderFields
        if let raw = headers["Set-Cookie"] as? String {
            for piece in raw.components(separatedBy: ", ") {
                if let kv = piece.components(separatedBy: ";").first,
                   let eq = kv.firstIndex(of: "=") {
                    let key = String(kv[..<eq]).trimmingCharacters(in: .whitespaces)
                    let value = String(kv[kv.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty && cookieDict[key] == nil { cookieDict[key] = value }
                }
            }
        }

        // 必备字段校验
        let mustHave = ["__kps", "__pus", "__uid"]
        for key in mustHave where (cookieDict[key] ?? "").isEmpty {
            throw DriveError.noPlayURL("夸克: 未拿到 \(key) Cookie，可能扫码授权失败")
        }

        // 解析昵称/头像（如果接口返回）
        var nick: String? = nil
        var avatar: String? = nil
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let dataObj = json["data"] as? [String: Any] {
                nick = (dataObj["nickname"] as? String) ?? (dataObj["nick_name"] as? String)
                avatar = (dataObj["avatarUri"] as? String) ?? (dataObj["avatar_uri"] as? String)
            }
            if nick == nil { nick = json["nickname"] as? String }
        }

        let cookieString = cookieDict.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        return QuarkQrLoginResult(cookie: cookieString, cookies: cookieDict, nickName: nick, avatarURL: avatar)
    }

    // MARK: - 百度网盘

    private func parseBaiduToken(_ raw: String) -> (cookie: String, bdussOnly: String) {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.lowercased().hasPrefix("cookie:") {
            input = String(input.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if input.range(of: #"BDUSS=([^;|]+)"#, options: .regularExpression) != nil {
            let normalizedCookie = input
                .replacingOccurrences(of: "\n", with: "; ")
                .replacingOccurrences(of: "\r", with: "; ")
                .replacingOccurrences(of: #"\s*;\s*"#, with: "; ", options: .regularExpression)
                .replacingOccurrences(of: #";+\s*$"#, with: "", options: .regularExpression)

            var bduss = ""
            if let r1 = normalizedCookie.range(of: #"BDUSS=([^;|]+)"#, options: .regularExpression),
               let eq = normalizedCookie[r1].firstIndex(of: "=") {
                bduss = String(normalizedCookie[normalizedCookie.index(after: eq)..<r1.upperBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if !bduss.isEmpty {
                // 完整 Cookie 模式：如果用户粘贴了 BDUSS/STOKEN/BAIDUID 等多字段，
                // 不再只截取 BDUSS/STOKEN，直接原样交给 iBox-style 本机路链使用。
                return (normalizedCookie, bduss)
            }
        }

        if input.contains("|") {
            let cleaned = input.replacingOccurrences(of: #"^BDUSS="#, with: "", options: .regularExpression)
            let parts = cleaned.components(separatedBy: "|")
            let bduss = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            var cookie = "BDUSS=\(bduss)"
            if parts.count >= 2 {
                let stoken = parts[1].replacingOccurrences(of: #"^STOKEN="#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                cookie += "; STOKEN=\(stoken)"
            }
            return (cookie, bduss)
        }

        let bduss = input.replacingOccurrences(of: "BDUSS=", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ("BDUSS=\(bduss)", bduss)
    }

    private func normalizeBaiduPCSCookie(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "; ")
            .replacingOccurrences(of: "\r", with: "; ")
            .replacingOccurrences(of: #"\s*;\s*"#, with: "; ", options: .regularExpression)
            .replacingOccurrences(of: #";+\s*$"#, with: "", options: .regularExpression)
    }

    func baiduGetFileList(shareURL: String, bduss: String) async throws -> [BaiduFileItem] {
        let parsed = parseBaiduToken(bduss)
        let cookie = parsed.cookie
        let cacheKey = baiduFileListCacheKey(shareURL: shareURL, bduss: bduss)

        if let cached = baiduCachedFileList(for: cacheKey) {
            baiduLog("[Baidu-iBox] ✅ 命中文件列表缓存：\(cached.count) 个文件")
            recordBaiduRouteDiagnostic(stage: "文件列表", status: "缓存命中", detail: "命中百度文件列表缓存：\(cached.count) 个文件")
            return cached
        }

        baiduLog("[Baidu-iBox] 文件列表走 iBox-style 本机路链：wap/init → verify → share/list")
        recordBaiduRouteDiagnostic(stage: "文件列表", status: "iBox开始", detail: "本机 /wap/init + share/list(web=5)，不走 Worker")
        let context = try await baiduExtractShareMeta(shareURL: shareURL, cookie: cookie, returnAll: true)
        let files = context.files
        baiduStoreFileList(files, for: cacheKey)
        recordBaiduRouteDiagnostic(stage: "文件列表", status: "iBox成功", detail: "share/list 返回 \(files.count) 个文件")
        return files
    }

    func resolveBaiduPlayURL(shareURL: String, bduss: String, pcsCookie: String = "") async throws -> PlayResult {
        try await resolveBaiduPlayURLInternal(shareURL: shareURL, bduss: bduss, pwd: nil, pcsCookie: pcsCookie)
    }

    func resolveBaiduPlayURL(shareURL: String, bduss: String, pwd: String?, pcsCookie: String = "") async throws -> PlayResult {
        try await resolveBaiduPlayURLInternal(shareURL: shareURL, bduss: bduss, pwd: pwd, pcsCookie: pcsCookie)
    }

    private func extractBaiduPwd(from shareURL: String) -> String? {
        if let match = try? NSRegularExpression(pattern: #"[?&]pwd=([^&]+)"#)
            .firstMatch(in: shareURL, range: NSRange(shareURL.startIndex..., in: shareURL)),
           let range = Range(match.range(at: 1), in: shareURL) {
            return String(shareURL[range])
        }
        let patterns = [
            #"提取码[:：\s]*([A-Za-z0-9]{4,8})"#,
            #"密码[:：\s]*([A-Za-z0-9]{4,8})"#,
            #"码[:：\s]*([A-Za-z0-9]{4,8})"#,
            #"[?&]pwd=([^&\s#]+)"#,
            #"[?&]password=([^&\s#]+)"#
        ]
        for pattern in patterns {
            if let match = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                .firstMatch(in: shareURL, range: NSRange(shareURL.startIndex..., in: shareURL)),
               let range = Range(match.range(at: 1), in: shareURL) {
                return String(shareURL[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func baiduExtractSurl(from shareURL: String) throws -> String {
        if let match = try? NSRegularExpression(pattern: #"/s/([^/?#]+)"#).firstMatch(in: shareURL, range: NSRange(shareURL.startIndex..., in: shareURL)),
           let range = Range(match.range(at: 1), in: shareURL) {
            return String(shareURL[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw DriveError.invalidShareURL
    }

    private func baiduShortSurl(_ surl: String) -> String {
        surl.hasPrefix("1") ? String(surl.dropFirst()) : surl
    }

    private func baiduResolveViaIBoxPlayItem(
        cacheKey: String,
        shareURL: String,
        fsId: String,
        fileName: String?,
        cookie: String,
        pcsCookie: String
    ) async throws -> PlayResult? {
        guard let item = baiduCachedIBoxPlayItem(for: cacheKey) else { return nil }
        let now = Date()

        if let expiresAt = item.dlinkExpiresAt,
           expiresAt > now.addingTimeInterval(5 * 60),
           let dlink = item.dlinkURL,
           !dlink.isEmpty {
            baiduLog("[Baidu-iBox] ✅ 命中已准备 dlink：fsId=\(fsId), source=\(item.source), engine=\(item.preferredEngine)")
            recordBaiduRouteDiagnostic(stage: "iBox", status: "dlink命中", detail: "命中已准备 dlink，source=\(item.source), engine=\(item.preferredEngine)", fsId: fsId, fileName: item.fileName)
            baiduStoreIBoxPlayItem(
                BaiduIBoxPlayItem(
                    shareURL: item.shareURL,
                    fsId: item.fsId,
                    fileName: item.fileName,
                    path: item.path,
                    dlinkURL: item.dlinkURL,
                    headers: item.headers,
                    dlinkExpiresAt: item.dlinkExpiresAt,
                    compatibilityHint: item.compatibilityHint,
                    preferredEngine: item.preferredEngine,
                    preparedAt: item.preparedAt,
                    updatedAt: now,
                    lastUsedAt: now,
                    source: item.source
                ),
                for: cacheKey
            )
            return PlayResult(url: dlink, headers: item.headers, driveType: .baidu)
        }

        guard !item.path.isEmpty else { return nil }
        baiduLog("[Baidu-iBox] ♻️ dlink 过期/缺失，用 PlayItem path 刷新：\(item.path)")
        recordBaiduRouteDiagnostic(stage: "iBox", status: "path刷新", detail: "dlink 过期/缺失，使用 path 刷新：\(item.path)", fsId: fsId, fileName: item.fileName)
        let mergedCookie = baiduMergeCookieStrings([
            item.headers.first { $0.key.lowercased() == "cookie" }?.value ?? "",
            cookie
        ])
        guard !mergedCookie.isEmpty else {
            baiduLog("[Baidu-iBox] ⚠️ path 刷新缺少 Cookie，转入 iBox 主路链重新验证/转存")
            recordBaiduRouteDiagnostic(stage: "iBox", status: "Cookie缺失", detail: "path 刷新缺少 Cookie，转入 iBox 主路链重新验证/转存", fsId: fsId, fileName: item.fileName)
            return nil
        }

        do {
            _ = try await baiduGetDLNADlinkOnDevice(filePath: item.path, cookie: mergedCookie, source: "ibox-mediainfo-probe")
            baiduLog("[Baidu-iBox] ✅ mediainfo 探测完成，继续 locatedownload")
        } catch {
            baiduLog("[Baidu-iBox] ⚠️ mediainfo 探测失败，继续 locatedownload：\(error.localizedDescription)")
            recordBaiduRouteDiagnostic(stage: "iBox", status: "mediainfo失败", detail: "path mediainfo 探测失败，继续 locatedownload：\(error.localizedDescription)", fsId: fsId, fileName: item.fileName)
        }
        let refreshed = try await baiduGetLocatedownloadOnDevice(filePath: item.path, cookie: mergedCookie)

        let finalFileName = item.fileName.isEmpty ? (fileName ?? item.path.split(separator: "/").last.map(String.init) ?? "") : item.fileName
        baiduStoreIBoxPlayItem(
            BaiduIBoxPlayItem(
                shareURL: shareURL,
                fsId: fsId,
                fileName: finalFileName,
                path: item.path,
                dlinkURL: refreshed.url,
                headers: refreshed.headers,
                dlinkExpiresAt: Date().addingTimeInterval(6 * 60 * 60),
                compatibilityHint: baiduCompatibilityHint(fileName: finalFileName),
                preferredEngine: baiduPreferredEngine(fileName: finalFileName),
                preparedAt: item.preparedAt,
                updatedAt: Date(),
                lastUsedAt: Date(),
                source: "ibox-path-refresh"
            ),
            for: cacheKey
        )
        baiduStorePlayResult(refreshed, for: cacheKey)
        baiduLog("[Baidu-iBox] ✅ path 刷新完成：\(item.path)")
        recordBaiduRouteDiagnostic(stage: "iBox", status: "path刷新成功", detail: "path 刷新完成：\(item.path)", fsId: fsId, fileName: finalFileName)
        return refreshed
    }

    private func baiduEnsureVboxFolderLocal(cookie: String) async throws {
        for folder in ["/我的资源", Self.baiduIBoxTransferDir] {
            var components = URLComponents(string: "https://pan.baidu.com/api/create")!
            components.queryItems = [
                URLQueryItem(name: "a", value: "commit"),
                URLQueryItem(name: "bdstoken", value: ""),
                URLQueryItem(name: "channel", value: "chunlei"),
                URLQueryItem(name: "web", value: "1"),
                URLQueryItem(name: "app_id", value: "250528"),
                URLQueryItem(name: "clienttype", value: "0")
            ]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "POST"
            request.timeoutInterval = 12
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            let encodedPath = folder.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? folder
            request.httpBody = "path=\(encodedPath)&isdir=1&block_list=[]".data(using: .utf8)

            let (data, _) = try await session.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errno = json["errno"] as? Int,
               errno == 0 || errno == -8 {
                continue
            }
            baiduLog("[Baidu-Local] ⚠️ \(folder) 创建响应：\(String(data: data.prefix(160), encoding: .utf8) ?? "")")
        }
    }

    private func baiduFindExistingVboxPath(fileName: String, cookie: String) async throws -> String? {
        var components = URLComponents(string: "https://pan.baidu.com/api/list")!
        components.queryItems = [
            URLQueryItem(name: "bdstoken", value: ""),
            URLQueryItem(name: "channel", value: "chunlei"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "clienttype", value: "0")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encodedDir = Self.baiduIBoxTransferDir.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? Self.baiduIBoxTransferDir
        request.httpBody = "dir=\(encodedDir)&order=time&desc=1&num=200&page=1".data(using: .utf8)

        let (data, _) = try await session.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["list"] as? [[String: Any]] else {
            return nil
        }

        let normalizedTarget = fileName.split(separator: "/").last.map(String.init) ?? fileName
        for item in list {
            let name = item["server_filename"] as? String
                ?? item["filename"] as? String
                ?? item["name"] as? String
                ?? ""
            if name == normalizedTarget {
                return item["path"] as? String ?? "\(Self.baiduIBoxTransferDir)/\(normalizedTarget)"
            }
        }
        return nil
    }

    private func baiduTransferFileOnDevice(
        shareid: String,
        shareUk: String,
        bdstoken: String,
        fsId: String,
        fileName: String,
        cookie: String
    ) async throws -> String {
        var components = URLComponents(string: "https://pan.baidu.com/share/transfer")!
        components.queryItems = [
            URLQueryItem(name: "shareid", value: shareid),
            URLQueryItem(name: "from", value: shareUk),
            URLQueryItem(name: "ondup", value: "newcopy"),
            URLQueryItem(name: "async", value: "1"),
            URLQueryItem(name: "channel", value: "chunlei"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "clienttype", value: "0"),
            URLQueryItem(name: "bdstoken", value: bdstoken)
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let transferPath = Self.baiduIBoxTransferDir.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? Self.baiduIBoxTransferDir
        request.httpBody = "fsidlist=[\(fsId)]&path=\(transferPath)".data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.noPlayURL("百度本机转存 HTTP \(status)")
        }

        let errno = json["errno"] as? Int ?? -1
        if errno != 0 {
            let msg = json["errmsg"] as? String ?? json["show_msg"] as? String ?? "errno=\(errno)"
            baiduLog("[Baidu-Local] ❌ 本机转存失败：\(msg)")
            throw DriveError.noPlayURL("百度本机转存失败：\(msg)")
        }

        if let extra = json["extra"] as? [String: Any],
           let list = extra["list"] as? [[String: Any]],
           let first = list.first,
           let to = first["to"] as? String,
           !to.isEmpty {
            return to
        }

        let normalizedName = fileName.split(separator: "/").last.map(String.init) ?? fileName
        return "\(Self.baiduIBoxTransferDir)/\(normalizedName)"
    }

    private func baiduCookieValue(_ cookie: String, named name: String) -> String? {
        let lowerName = name.lowercased()
        for part in cookie.split(separator: ";") {
            let item = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = item.firstIndex(of: "=") else { continue }
            let key = String(item[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(item[item.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if key == lowerName, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func baiduGetDLNADlinkOnDevice(filePath: String, cookie: String, source: String = "local-mediainfo") async throws -> PlayResult {
        var components = URLComponents(string: "https://pan.baidu.com/api/mediainfo")!
        components.queryItems = [
            URLQueryItem(name: "clienttype", value: "80"),
            URLQueryItem(name: "origin", value: "dlna")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(Self.baiduPCSUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encodedPath = filePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filePath
        request.httpBody = "path=\(encodedPath)&type=M3U8_FLV_264_480".data(using: .utf8)

        baiduLog("[Baidu-DLNA] 本机调用 mediainfo：path=\(filePath), hasBDUSS=\(cookie.lowercased().contains("bduss=")), hasSTOKEN=\(cookie.lowercased().contains("stoken=")), hasPANPSC=\(cookie.lowercased().contains("panpsc=")), hasPTOKEN=\(cookie.lowercased().contains("ptoken"))")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            let preview = String(data: data.prefix(240), encoding: .utf8) ?? ""
            baiduLog("[Baidu-DLNA] ❌ HTTP \(status)：\(preview)")
            throw DriveError.noPlayURL("百度 DLNA HTTP \(status)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(240), encoding: .utf8) ?? ""
            baiduLog("[Baidu-DLNA] ❌ 非 JSON 响应：\(preview)")
            throw DriveError.noPlayURL("百度 DLNA 返回非 JSON")
        }

        let info = json["info"] as? [String: Any]
        let dlink = info?["dlink"] as? String
            ?? json["dlink"] as? String
            ?? json["url"] as? String
        if let dlink, !dlink.isEmpty {
            let errno = json["errno"] as? Int ?? 0
            baiduLog("[Baidu-DLNA] ✅ mediainfo 返回 dlink：errno=\(errno), url=\(dlink.prefix(80))...")
            return baiduPlayResult(url: dlink, cookie: cookie, source: source)
        }

        let errno = json["errno"] as? Int ?? -1
        let msg = json["errmsg"] as? String ?? json["show_msg"] as? String ?? json["msg"] as? String ?? "errno=\(errno)"
        baiduLog("[Baidu-DLNA] ❌ 未返回 dlink：errno=\(errno), msg=\(msg), fields=\(json.keys.sorted().joined(separator: ","))")
        throw DriveError.noPlayURL("百度 DLNA 未返回 dlink：\(msg)")
    }

    private func baiduGetLocatedownloadOnDevice(filePath: String, cookie: String, source: String = "local-locatedownload") async throws -> PlayResult {
        var components = URLComponents(string: "https://d.pcs.baidu.com/rest/2.0/pcs/file")!
        components.queryItems = [
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "method", value: "locatedownload"),
            URLQueryItem(name: "check_blue", value: "1"),
            URLQueryItem(name: "path", value: filePath)
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(Self.baiduPCSUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://pan.baidu.com", forHTTPHeaderField: "Origin")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        baiduLog("[Baidu-LocalPCS] 本机调用 locatedownload：path=\(filePath), hasBDUSS=\(cookie.lowercased().contains("bduss=")), hasSTOKEN=\(cookie.lowercased().contains("stoken=")), hasPANPSC=\(cookie.lowercased().contains("panpsc=")), hasPTOKEN=\(cookie.lowercased().contains("ptoken"))")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        if (status == 200 || status == 206),
           let finalURL = http?.url?.absoluteString,
           finalURL != components.url!.absoluteString,
           !finalURL.contains("d.pcs.baidu.com/rest/2.0/pcs/file") {
            baiduLog("[Baidu-LocalPCS] ✅ locatedownload 302 后最终 CDN：\(finalURL.prefix(80))...")
            return baiduPlayResult(url: finalURL, cookie: cookie, source: source)
        }
        if (300..<400).contains(status),
           let location = http?.allHeaderFields["Location"] as? String,
           !location.isEmpty {
            baiduLog("[Baidu-LocalPCS] ✅ locatedownload 返回 Location：\(location.prefix(80))...")
            return baiduPlayResult(url: location, cookie: cookie, source: source)
        }
        guard status == 200 else {
            let preview = String(data: data.prefix(240), encoding: .utf8) ?? ""
            baiduLog("[Baidu-LocalPCS] ❌ HTTP \(status)：\(preview)")
            throw DriveError.noPlayURL("百度本机取链 HTTP \(status)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(240), encoding: .utf8) ?? ""
            baiduLog("[Baidu-LocalPCS] ❌ 非 JSON 响应：\(preview)")
            throw DriveError.noPlayURL("百度本机取链返回非 JSON")
        }

        if let errno = json["errno"] as? Int, errno != 0 {
            let msg = json["errmsg"] as? String ?? json["show_msg"] as? String ?? json["msg"] as? String ?? "errno=\(errno)"
            baiduLog("[Baidu-LocalPCS] ❌ errno=\(errno), msg=\(msg)")
            throw DriveError.noPlayURL("百度本机取链失败：\(msg)")
        }

        let urls = json["urls"] as? [[String: Any]]
        let locatedURL = urls?.first?["url"] as? String
            ?? json["url"] as? String
            ?? json["dlink"] as? String
        guard let locatedURL, !locatedURL.isEmpty else {
            baiduLog("[Baidu-LocalPCS] ❌ 未返回 urls/url 字段，字段=\(json.keys.sorted().joined(separator: ","))")
            throw DriveError.noPlayURL("百度本机取链未返回播放地址")
        }

        baiduLog("[Baidu-LocalPCS] ✅ 本机取链成功：\(locatedURL.prefix(80))...")
        return baiduPlayResult(url: locatedURL, cookie: cookie, source: source)
    }

    private func baiduPlayResult(url: String, cookie: String, source: String? = nil) -> PlayResult {
        PlayResult(
            url: url,
            headers: [
                "Cookie": cookie,
                "User-Agent": Self.baiduPCSUserAgent,
                "Referer": "https://pan.baidu.com/",
                "Origin": "https://pan.baidu.com"
            ],
            driveType: .baidu,
            source: source
        )
    }

    private func baiduMergeCookieStrings(_ cookies: [String]) -> String {
        var keys: [String] = []
        var values: [String: (name: String, value: String)] = [:]
        for cookie in cookies where !cookie.isEmpty {
            for part in cookie.replacingOccurrences(of: "\n", with: ";").split(separator: ";") {
                let item = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let eq = item.firstIndex(of: "=") else { continue }
                let name = String(item[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(item[item.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !value.isEmpty else { continue }
                let key = name.lowercased()
                if values[key] == nil { keys.append(key) }
                values[key] = (name, value)
            }
        }
        return keys.compactMap { key in
            guard let item = values[key] else { return nil }
            return "\(item.name)=\(item.value)"
        }.joined(separator: "; ")
    }

    private func baiduStableDeviceId() -> String {
        let key = "baidu_local_pcs_device_id"
        if let id = defaults.string(forKey: key), !id.isEmpty {
            return id
        }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        defaults.set(id, forKey: key)
        return id
    }

    private func resolveBaiduPlayURLInternal(shareURL: String, bduss: String, pwd: String?, pcsCookie: String = "") async throws -> PlayResult {
        let parsed = parseBaiduToken(bduss)
        let cookie = parsed.cookie
        let context = try await baiduExtractShareMeta(shareURL: shareURL, cookie: cookie, returnAll: true)
        guard let first = context.files.first, !first.fsId.isEmpty else {
            throw DriveError.noPlayURL("百度 iBox 路链未返回可播放文件")
        }
        return try await resolveBaiduPlayURLViaMainRoute(
            shareURL: shareURL,
            bduss: bduss,
            fsId: first.fsId,
            fileName: first.name,
            pcsCookie: pcsCookie
        )
    }

    func resolveBaiduPlayURL(shareURL: String, bduss: String, fsId: String, pcsCookie: String = "") async throws -> PlayResult {
        try await resolveBaiduPlayURLViaMainRoute(
            shareURL: shareURL,
            bduss: bduss,
            fsId: fsId,
            fileName: nil,
            pcsCookie: pcsCookie
        )
    }

    /// iBox-style 百度主播放链路：
    /// wap/init → verify → share/list → transfer → api/list → mediainfo/locatedownload。
    /// 失败时直接向调用方抛出错误，不再回落 Worker 或旧分享直链路。
    func resolveBaiduPlayURLViaMainRoute(
        shareURL: String,
        bduss: String,
        fsId: String,
        fileName hintFileName: String? = nil,
        pcsCookie: String = ""
    ) async throws -> PlayResult {
        let cacheKey = baiduMainRouteCacheKey(shareURL: shareURL, fsId: fsId, bduss: bduss, pcsCookie: pcsCookie)
        if let cached = baiduCachedPlayResult(for: cacheKey) {
            baiduLog("[Baidu-MainRoute] ✅ 命中主路链播放缓存：fsId=\(fsId)")
            recordBaiduRouteDiagnostic(stage: "主路链缓存", status: "命中", detail: "命中主路链 dlink 缓存", fsId: fsId, fileName: hintFileName)
            return cached
        }

        let parsed = parseBaiduToken(bduss)
        let webCookie = parsed.cookie
        let pcs = normalizeBaiduPCSCookie(pcsCookie)

        if let itemResult = try? await baiduResolveViaIBoxPlayItem(
            cacheKey: cacheKey,
            shareURL: shareURL,
            fsId: fsId,
            fileName: hintFileName,
            cookie: webCookie,
            pcsCookie: pcs
        ) {
            let result = PlayResult(
                url: itemResult.url,
                headers: itemResult.headers,
                driveType: .baidu,
                source: "baidu-main-playitem"
            )
            baiduStorePlayResult(result, for: cacheKey)
            return result
        }

        baiduLog("[Baidu-iBoxRoute] 开始 iBox-style 百度主路链：fsId=\(fsId), file=\(hintFileName ?? "未知")")
        recordBaiduRouteDiagnostic(stage: "iBox主路链", status: "开始", detail: "wap/init → verify → share/list → transfer → api/list → locatedownload → 本地代理", fsId: fsId, fileName: hintFileName)

        let pwd = extractBaiduPwd(from: shareURL)
        let context = try await baiduExtractShareMeta(shareURL: shareURL, cookie: webCookie, returnAll: true)
        let selected = context.files.first { $0.fsId == fsId }
            ?? context.files.first { $0.fsId.trimmingCharacters(in: .whitespacesAndNewlines) == fsId.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let selected else {
            recordBaiduRouteDiagnostic(stage: "主路链", status: "文件未找到", detail: "分享列表未找到目标 fsId，pwd=\((pwd ?? "").isEmpty ? "无" : "有")", fsId: fsId, fileName: hintFileName)
            throw DriveError.noPlayURL("主路链未找到目标文件")
        }

        let mergedCookie = baiduMergeCookieStrings([context.cookie, webCookie])
        guard !mergedCookie.isEmpty else {
            recordBaiduRouteDiagnostic(stage: "主路链", status: "Cookie缺失", detail: "无法合并 BDUSS/STOKEN Cookie", fsId: fsId, fileName: selected.name)
            throw DriveError.noPlayURL("主路链缺少百度 Cookie")
        }

        do {
            try await baiduEnsureVboxFolderLocal(cookie: mergedCookie)
            let existingPath = try await baiduFindExistingVboxPath(fileName: selected.name, cookie: mergedCookie)
            let filePath: String
            let sourcePrefix: String
            if let existingPath {
                filePath = existingPath
                sourcePrefix = "main-existing"
                baiduLog("[Baidu-iBoxRoute] ✅ \(Self.baiduIBoxTransferDir) 命中已转存文件：\(filePath)")
                recordBaiduRouteDiagnostic(stage: "iBox主路链", status: "path命中", detail: "命中 \(Self.baiduIBoxTransferDir) 已转存文件：\(filePath)", fsId: fsId, fileName: selected.name)
            } else {
                filePath = try await baiduTransferFileOnDevice(
                    shareid: context.shareid,
                    shareUk: context.shareUk,
                    bdstoken: context.bdstoken,
                    fsId: selected.fsId,
                    fileName: selected.name,
                    cookie: mergedCookie
                )
                sourcePrefix = "main-transfer"
                baiduLog("[Baidu-iBoxRoute] ✅ 本机转存完成：\(filePath)")
                recordBaiduRouteDiagnostic(stage: "iBox主路链", status: "转存成功", detail: "已转存到：\(filePath)", fsId: fsId, fileName: selected.name)
            }

            do {
                _ = try await baiduGetDLNADlinkOnDevice(filePath: filePath, cookie: mergedCookie, source: "\(sourcePrefix)-mediainfo-probe")
                baiduLog("[Baidu-iBoxRoute] ✅ mediainfo 探测完成，继续 locatedownload")
            } catch {
                baiduLog("[Baidu-iBoxRoute] ⚠️ mediainfo 探测失败，继续 locatedownload：\(error.localizedDescription)")
                recordBaiduRouteDiagnostic(stage: "iBox主路链", status: "mediainfo失败", detail: "继续 locatedownload：\(error.localizedDescription)", fsId: fsId, fileName: selected.name)
            }
            let rawResult = try await baiduGetLocatedownloadOnDevice(filePath: filePath, cookie: mergedCookie, source: "\(sourcePrefix)-locatedownload")
            let source = "\(sourcePrefix)-locatedownload"

            let result = PlayResult(
                url: rawResult.url,
                headers: rawResult.headers,
                driveType: .baidu,
                source: source
            )
            let playItem = BaiduIBoxPlayItem(
                shareURL: shareURL,
                fsId: fsId,
                fileName: selected.name,
                path: filePath,
                dlinkURL: result.url,
                headers: result.headers,
                dlinkExpiresAt: Date().addingTimeInterval(6 * 60 * 60),
                compatibilityHint: baiduCompatibilityHint(fileName: selected.name),
                preferredEngine: baiduPreferredEngine(fileName: selected.name),
                preparedAt: Date(),
                updatedAt: Date(),
                lastUsedAt: Date(),
                source: source
            )
            baiduStoreIBoxPlayItem(playItem, for: cacheKey)
            baiduStorePlayResult(result, for: cacheKey)
            recordBaiduRouteDiagnostic(stage: "iBox主路链", status: "成功", detail: "source=\(source)，engine=\(playItem.preferredEngine)", fsId: fsId, fileName: selected.name)
            baiduLog("[Baidu-iBoxRoute] ✅ iBox-style 原画地址获取成功：source=\(source), engine=\(playItem.preferredEngine)")
            return result
        } catch {
            baiduLog("[Baidu-iBoxRoute] ❌ iBox-style 转存/locatedownload 失败：\(error.localizedDescription)")
            recordBaiduRouteDiagnostic(stage: "iBox主路链", status: "失败", detail: error.localizedDescription, fsId: fsId, fileName: selected.name)
            throw error
        }
    }

    @discardableResult
    func prepareBaiduIBoxPlayItem(shareURL: String, bduss: String, fsId: String, pcsCookie: String = "") async throws -> PlayResult {
        baiduLog("[Baidu-iBox] 开始准备 PlayItem：fsId=\(fsId)")
        let result = try await resolveBaiduPlayURL(shareURL: shareURL, bduss: bduss, fsId: fsId, pcsCookie: pcsCookie)
        baiduLog("[Baidu-iBox] ✅ PlayItem 准备完成：fsId=\(fsId)")
        return result
    }

    private func baiduExtractShareMeta(shareURL: String, cookie: String, returnAll: Bool = false) async throws -> (shareid: String, shareUk: String, bdstoken: String, surl: String, cookie: String, files: [BaiduFileItem]) {
        baiduLog("[Baidu] 提取分享信息：\(shareURL)")

        let surl: String
        if let match = try? NSRegularExpression(pattern: #"/s/1([^/?]+)"#).firstMatch(in: shareURL, range: NSRange(shareURL.startIndex..., in: shareURL)),
           let r = Range(match.range(at: 1), in: shareURL) {
            surl = "1" + String(shareURL[r])
        } else if let match = try? NSRegularExpression(pattern: #"/s/([^/?]+)"#).firstMatch(in: shareURL, range: NSRange(shareURL.startIndex..., in: shareURL)),
                  let r = Range(match.range(at: 1), in: shareURL) {
            surl = String(shareURL[r])
        } else {
            baiduLog("[Baidu] ❌ 无法提取 surl")
            throw DriveError.invalidShareURL
        }

        let pwd: String?
        if let match = try? NSRegularExpression(pattern: #"[?&]pwd=([^&]+)"#).firstMatch(in: shareURL, range: NSRange(shareURL.startIndex..., in: shareURL)),
           let r = Range(match.range(at: 1), in: shareURL) {
            pwd = String(shareURL[r])
            baiduLog("[Baidu] 检测到提取码: \(pwd!)")
        } else {
            pwd = nil
        }

        let contextKey = baiduShareContextKey(shareURL: shareURL, cookie: cookie)
        let verifyCooldownKey = "\(contextKey)|\(surl)|\(pwd ?? "")"
        if let cached = baiduCachedShareContext(for: contextKey) {
            baiduLog("[Baidu-ShareContext] ✅ 命中分享上下文缓存：source=\(cached.source), files=\(cached.files.count)")
            recordBaiduRouteDiagnostic(stage: "分享上下文", status: "缓存命中", detail: "命中 ShareContext：source=\(cached.source), files=\(cached.files.count)")
            return (cached.shareid, cached.shareUk, cached.bdstoken ?? "", cached.surl, cached.cookie, cached.files)
        }

        do {
            let shortSurl = baiduShortSurl(surl)
            let webUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"
            let initURL = "https://pan.baidu.com/wap/init?surl=\(shortSurl)"
            var iBoxCookie = cookie
            var shareid = ""
            var shareUk = ""
            var randskForList = ""

            func stringValue(_ value: Any?) -> String {
                if let value = value as? String { return value }
                if let value = value as? Int { return String(value) }
                if let value = value as? Int64 { return String(value) }
                if let value = value as? NSNumber { return value.stringValue }
                return ""
            }

            func firstHTMLValue(_ html: String, patterns: [String]) -> String {
                for pattern in patterns {
                    if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                       let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                       match.numberOfRanges > 1,
                       let range = Range(match.range(at: 1), in: html) {
                        return String(html[range])
                    }
                }
                return ""
            }

            func parseFiles(_ rawList: [[String: Any]]) -> [BaiduFileItem] {
                rawList.compactMap { item in
                    let fsId = stringValue(item["fs_id"]).isEmpty ? stringValue(item["fsId"]) : stringValue(item["fs_id"])
                    let name = stringValue(item["server_filename"]).isEmpty
                        ? (stringValue(item["file_name"]).isEmpty ? stringValue(item["name"]) : stringValue(item["file_name"]))
                        : stringValue(item["server_filename"])
                    guard !fsId.isEmpty else { return nil }
                    return BaiduFileItem(fsId: fsId, name: name.isEmpty ? "未知文件" : name)
                }
            }

            baiduLog("[Baidu-iBoxRoute] ① GET /wap/init?surl=\(shortSurl)")
            guard let initURLObject = URL(string: initURL) else { throw DriveError.invalidShareURL }
            var initRequest = URLRequest(url: initURLObject)
            initRequest.timeoutInterval = 18
            initRequest.setValue(iBoxCookie, forHTTPHeaderField: "Cookie")
            initRequest.setValue(webUA, forHTTPHeaderField: "User-Agent")
            initRequest.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
            let (initData, initResponse) = try await session.data(for: initRequest)
            let initResp = initResponse as? HTTPURLResponse
            if let sc = initResp?.allHeaderFields["Set-Cookie"] as? String {
                iBoxCookie = baiduMergeCookieStrings([iBoxCookie, sc])
            }
            let initHTML = String(data: initData, encoding: .utf8) ?? String(data: initData, encoding: .ascii) ?? ""
            shareid = firstHTMLValue(initHTML, patterns: [
                #""shareid"\s*:\s*"?(\d+)"?"#,
                #""share_id"\s*:\s*"?(\d+)"?"#,
                #"shareid=(\d+)"#,
                #"data-shareid="(\d+)""#
            ])
            shareUk = firstHTMLValue(initHTML, patterns: [
                #""share_uk"\s*:\s*"?(\d+)"?"#,
                #""uk"\s*:\s*"?(\d+)"?"#,
                #"share_uk=(\d+)"#,
                #"data-uk="(\d+)""#
            ])
            let bdstoken = firstHTMLValue(initHTML, patterns: [
                #""bdstoken"\s*:\s*"([^"]+)""#,
                #"bdstoken=([A-Za-z0-9_-]+)"#
            ])

            if let pwd, !pwd.isEmpty {
                baiduLog("[Baidu-iBoxRoute] ② POST /share/verify?surl=\(shortSurl)")
                var allowed = CharacterSet.urlQueryAllowed
                allowed.remove(charactersIn: "&+=?#")
                let encodedPwd = pwd.addingPercentEncoding(withAllowedCharacters: allowed) ?? pwd
                let verifyURL = "https://pan.baidu.com/share/verify?surl=\(shortSurl)&t=\(Int(Date().timeIntervalSince1970 * 1000))&channel=chunlei&web=1&app_id=250528&clienttype=0&bdstoken="
                let verifyBody = "pwd=\(encodedPwd)&vcode=&vcode_str=&channel=chunlei&web=1&app_id=250528&clienttype=0&bdstoken="
                guard let verifyURLObject = URL(string: verifyURL) else { throw DriveError.invalidShareURL }
                var verifyRequest = URLRequest(url: verifyURLObject)
                verifyRequest.httpMethod = "POST"
                verifyRequest.timeoutInterval = 18
                verifyRequest.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
                verifyRequest.setValue(iBoxCookie, forHTTPHeaderField: "Cookie")
                verifyRequest.setValue(webUA, forHTTPHeaderField: "User-Agent")
                verifyRequest.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
                verifyRequest.setValue("https://pan.baidu.com", forHTTPHeaderField: "Origin")
                verifyRequest.setValue(initURL, forHTTPHeaderField: "Referer")
                verifyRequest.httpBody = verifyBody.data(using: .utf8)
                let (verifyData, _) = try await session.data(for: verifyRequest)
                guard let verifyJSON = try? JSONSerialization.jsonObject(with: verifyData) as? [String: Any],
                      let errno = verifyJSON["errno"] as? Int else {
                    let preview = String(data: verifyData.prefix(200), encoding: .utf8) ?? ""
                    throw DriveError.noPlayURL("百度 iBox 验证返回非 JSON：\(preview)")
                }
                if errno == -9 { throw DriveError.noPlayURL("百度网盘：提取码错误") }
                if errno == 4 { throw DriveError.noPlayURL("百度网盘：需要图形验证码") }
                guard errno == 0 else {
                    let msg = verifyJSON["errmsg"] as? String ?? verifyJSON["show_msg"] as? String ?? "errno=\(errno)"
                    throw DriveError.noPlayURL("百度 iBox 验证失败：\(msg)")
                }
                if let rawRandsk = verifyJSON["randsk"] as? String, !rawRandsk.isEmpty {
                    let decodedRandsk = rawRandsk.removingPercentEncoding ?? rawRandsk
                    randskForList = rawRandsk
                    iBoxCookie = baiduMergeCookieStrings([iBoxCookie, "BDCLND=\(rawRandsk); randsk=\(decodedRandsk)"])
                    baiduLog("[Baidu-iBoxRoute] ✅ verify 成功，已写入 BDCLND/randsk")
                }
            }

            baiduLog("[Baidu-iBoxRoute] ③ GET /share/list?web=5&shorturl=\(shortSurl)")
            var files: [BaiduFileItem] = []
            let encodedRandsk = randskForList.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? randskForList
            let randskQuery = encodedRandsk.isEmpty ? "" : "&randsk=\(encodedRandsk)"
            let listQueries = [
                "https://pan.baidu.com/share/list?shorturl=\(shortSurl)&root=1&web=5&channel=chunlei&app_id=250528&clienttype=0&dir=/\(randskQuery)"
            ]
            var lastListError = ""
            for listURL in listQueries {
                guard let listURLObject = URL(string: listURL) else { continue }
                var listRequest = URLRequest(url: listURLObject)
                listRequest.timeoutInterval = 18
                listRequest.setValue(iBoxCookie, forHTTPHeaderField: "Cookie")
                listRequest.setValue(webUA, forHTTPHeaderField: "User-Agent")
                listRequest.setValue(initURL, forHTTPHeaderField: "Referer")
                listRequest.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
                listRequest.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
                let (listData, _) = try await session.data(for: listRequest)
                guard let listJSON = try? JSONSerialization.jsonObject(with: listData) as? [String: Any] else {
                    lastListError = String(data: listData.prefix(200), encoding: .utf8) ?? "非 JSON"
                    continue
                }
                let listRoot = (listJSON["data"] as? [String: Any]) ?? listJSON
                if shareid.isEmpty { shareid = stringValue(listRoot["shareid"]).isEmpty ? stringValue(listRoot["share_id"]) : stringValue(listRoot["shareid"]) }
                if shareUk.isEmpty { shareUk = stringValue(listRoot["share_uk"]).isEmpty ? stringValue(listRoot["uk"]) : stringValue(listRoot["share_uk"]) }
                let errno = listJSON["errno"] as? Int ?? 0
                if errno != 0 {
                    lastListError = listJSON["errmsg"] as? String ?? listJSON["show_msg"] as? String ?? "errno=\(errno)"
                    continue
                }
                let rawList = listRoot["list"] as? [[String: Any]]
                    ?? listRoot["file_list"] as? [[String: Any]]
                    ?? listRoot["records"] as? [[String: Any]]
                    ?? []
                files = parseFiles(rawList)
                if !files.isEmpty { break }
                lastListError = "share/list 未返回文件"
            }

            guard !shareid.isEmpty, !shareUk.isEmpty else {
                throw DriveError.noPlayURL("百度 iBox 路链未拿到 shareid/uk")
            }
            guard !files.isEmpty else {
                throw DriveError.noPlayURL("百度 iBox share/list 未返回文件列表：\(lastListError)")
            }

            baiduStoreShareContext(
                shareURL: shareURL,
                surl: surl,
                pwd: pwd,
                shareid: shareid,
                shareUk: shareUk,
                bdstoken: bdstoken,
                cookie: iBoxCookie,
                files: files,
                source: "ibox-wap-share-list",
                key: contextKey
            )
            baiduLog("[Baidu-iBoxRoute] ✅ shareid=\(shareid), uk=\(shareUk), 文件=\(files.count)")
            return (shareid, shareUk, bdstoken, surl, iBoxCookie, files)
        } catch {
            baiduLog("[Baidu-iBoxRoute] ❌ /wap/init → share/list 失败：\(error.localizedDescription)")
            throw error
        }


    }

    private func baiduEnsureFolder(bduss: String) async throws -> String {
        let listURL = URL(string: "https://pan.baidu.com/api/list?dir=/&order=time&desc=1&num=100&page=1&bdstoken=&channel=chunlei&web=1&app_id=250528&clienttype=0")!
        var req = URLRequest(url: listURL)
        req.setValue("BDUSS=\(bduss)", forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        if let (data, _) = try? await session.data(for: req),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["list"] as? [[String: Any]] {
            for item in list {
                if let name = item["server_filename"] as? String, name == "vbox播放" { return "/vbox播放/" }
            }
        }
        let createURL = URL(string: "https://pan.baidu.com/api/create?a=commit&bdstoken=&channel=chunlei&web=1&app_id=250528&clienttype=0")!
        var createReq = URLRequest(url: createURL)
        createReq.httpMethod = "POST"
        createReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        createReq.setValue("BDUSS=\(bduss)", forHTTPHeaderField: "Cookie")
        createReq.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let params = "path=/vbox播放&isdir=1&block_list=[]"
        createReq.httpBody = params.data(using: .utf8)
        let _ = try? await session.data(for: createReq)
        return "/vbox播放/"
    }

    private func baiduDeleteFiles(fileIds: [String], bduss: String) async {
        guard !fileIds.isEmpty else { return }
        let url = URL(string: "https://pan.baidu.com/api/filemanager?a=delete&bdstoken=&channel=chunlei&web=1&app_id=250528&clienttype=0")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("BDUSS=\(bduss)", forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let params = "filelist=[\"\(fileIds.first!)\"]&path=/vbox播放/"
        req.httpBody = params.data(using: .utf8)
        let _ = try? await session.data(for: req)
        print("[CloudDrive] ✅ 百度已删除转存文件")
    }

    // MARK: - 115 网盘

    func resolve115PlayURL(shareURL: String, cid: String) async throws -> PlayResult {
        print("[115] 开始解析: \(shareURL)")
        let cookie = normalize115Cookie(cid)
        let (shareCode, receiveCode) = try await extract115ShareCode(from: shareURL)

        let snapResult = try await one15FirstPlayableFile(
            shareCode: shareCode,
            receiveCode: receiveCode,
            cid: "0",
            cookie: cookie
        )

        guard let pickCode = snapResult.pickCode else { throw DriveError.noPlayURL("115: snap 未返回 pick_code") }
        print("[115] 选中资源：\(snapResult.fileName ?? "未知文件"), pickCode=\(pickCode)")
        let downloadURL = try await one15GetDownloadURL(pickCode: pickCode, cookie: cookie)

        return PlayResult(
            url: downloadURL,
            headers: one15PlaybackHeaders(cookie: cookie),
            driveType: .one15,
            source: "share-snap-downurl"
        )
    }

    private func extract115ShareCode(from url: String) async throws -> (shareCode: String, receiveCode: String) {
        var shareCode = ""
        var receiveCode = ""

        if let range = url.range(of: #"/s/([^/?#]+)"#, options: .regularExpression) {
            shareCode = String(url[range]).replacingOccurrences(of: "/s/", with: "")
        }
        let queryItems = URLComponents(string: url)?.queryItems ?? []
        receiveCode = queryItems.first(where: { ["password", "pwd", "passcode"].contains($0.name.lowercased()) })?.value ?? ""
        if receiveCode.isEmpty, let range = url.range(of: #"(提取码|访问码|密码)[:：\s]*([A-Za-z0-9]{4,8})"#, options: .regularExpression) {
            let matched = String(url[range])
            receiveCode = matched.components(separatedBy: CharacterSet(charactersIn: ":： ")).last ?? ""
        }

        guard !shareCode.isEmpty else { throw DriveError.invalidShareURL }
        return (shareCode, receiveCode)
    }

    private struct One15SnapResult {
        let pickCode: String?
        let cid: String?
        let fileName: String?
        let isDir: Bool
    }

    private func one15FirstPlayableFile(shareCode: String, receiveCode: String, cid: String, cookie: String) async throws -> One15SnapResult {
        let list = try await one15Snap(shareCode: shareCode, receiveCode: receiveCode, cid: cid, cookie: cookie)
        if let playable = list.first(where: { !$0.isDir && one15IsPlayableFileName($0.fileName ?? "") }) {
            return playable
        }
        for dir in list where dir.isDir {
            guard let nextCid = dir.cid, !nextCid.isEmpty else { continue }
            if let found = try? await one15FirstPlayableFile(shareCode: shareCode, receiveCode: receiveCode, cid: nextCid, cookie: cookie) {
                return found
            }
        }
        throw DriveError.noPlayURL("115: 分享内未找到可播放视频")
    }

    private func one15Snap(shareCode: String, receiveCode: String, cid: String, cookie: String) async throws -> [One15SnapResult] {
        var components = URLComponents(string: "https://webapi.115.com/share/snap")!
        components.queryItems = [
            URLQueryItem(name: "share_code", value: shareCode),
            URLQueryItem(name: "receive_code", value: receiveCode),
            URLQueryItem(name: "cid", value: cid),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "100")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://115.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) 115Chrome/33.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let state = json["state"] as? Bool, state == false {
            let message = json["error"] as? String ?? json["message"] as? String ?? "115 snap 失败"
            throw DriveError.noPlayURL("115: \(message)")
        }
        guard let dataDict = json["data"] as? [String: Any] else { throw DriveError.invalidResponse }

        let rawList = (dataDict["list"] as? [[String: Any]])
            ?? (dataDict["data"] as? [[String: Any]])
            ?? []
        let result = rawList.compactMap { item -> One15SnapResult? in
            let name = item["n"] as? String
                ?? item["file_name"] as? String
                ?? item["name"] as? String
            let pick = item["pc"] as? String
                ?? item["pick_code"] as? String
                ?? item["pickcode"] as? String
            let itemCid = item["cid"] as? String
                ?? item["fid"] as? String
                ?? item["id"] as? String
                ?? (item["cid"] as? Int).map { String($0) }
            let isDir: Bool
            if let boolValue = item["is_dir"] as? Bool {
                isDir = boolValue
            } else if let fc = item["fc"] as? String, !fc.isEmpty {
                isDir = true
            } else if let category = item["file_category"] as? String {
                isDir = category == "0"
            } else {
                isDir = false
            }
            guard name != nil || pick != nil || itemCid != nil else { return nil }
            return One15SnapResult(pickCode: pick, cid: itemCid, fileName: name, isDir: isDir)
        }
        if !result.isEmpty {
            return result
        }

        if let pickCode = (dataDict["pick_code"] as? String) ?? (dataDict["pickcode"] as? String) {
            return [One15SnapResult(pickCode: pickCode, cid: dataDict["cid"] as? String, fileName: dataDict["file_name"] as? String, isDir: false)]
        }

        throw DriveError.noPlayURL("115: 分享列表为空")
    }

    private func one15GetDownloadURL(pickCode: String, cookie: String) async throws -> String {
        var components = URLComponents(string: "https://proapi.115.com/app/chrome/downurl")!
        components.queryItems = [URLQueryItem(name: "pickcode", value: pickCode)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://115.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) 115Chrome/33.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let state = json["state"] as? Bool, state == false {
            let message = json["error"] as? String ?? json["message"] as? String ?? "115 downurl 失败"
            throw DriveError.noPlayURL("115: \(message)")
        }

        if let dataObj = json["data"] as? [String: Any] {
            for (_, value) in dataObj {
                if let fileInfo = value as? [String: Any],
                   let url = one15ExtractURL(from: fileInfo) {
                    return url
                }
            }
        }
        if let url = one15ExtractURL(from: json) { return url }

        throw DriveError.noPlayURL("115: 未获取到下载地址")
    }

    private func one15ExtractURL(from value: Any) -> String? {
        if let text = value as? String, text.hasPrefix("http") {
            return text
        }
        if let dict = value as? [String: Any] {
            for key in ["url", "download_url", "dlink"] {
                if let text = dict[key] as? String, text.hasPrefix("http") { return text }
                if let nested = dict[key], let url = one15ExtractURL(from: nested) { return url }
            }
            for item in dict.values {
                if let url = one15ExtractURL(from: item) { return url }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let url = one15ExtractURL(from: item) { return url }
            }
        }
        return nil
    }

    private func normalize115Cookie(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("cookie:") {
            return String(trimmed.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if trimmed.contains("=") {
            return trimmed
        }
        return "CID=\(trimmed)"
    }

    private func one15PlaybackHeaders(cookie: String) -> [String: String] {
        [
            "Cookie": cookie,
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) 115Chrome/33.0.0.0 Safari/537.36",
            "Referer": "https://115.com/",
            "Origin": "https://115.com",
            "Accept": "*/*",
            "Accept-Encoding": "identity"
        ]
    }

    private func one15IsPlayableFileName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["mp4", "mkv", "mov", "m3u8", "avi", "wmv", "flv", "ts", "m4v"].contains { lower.hasSuffix(".\($0)") }
    }

    // MARK: - UC 网盘

    func resolveUCPlayURL(shareURL: String, cookie: String) async throws -> PlayResult {
        print("[UC] 开始解析: \(shareURL)")
        let (pwdId, passcode) = ucExtractShareInfo(from: shareURL)
        guard !pwdId.isEmpty else { throw DriveError.invalidShareURL }

        var authCookie = cookie
        let folder = try await ucEnsureFolderWithCookie(cookie: authCookie)
        authCookie = folder.cookie
        let stoken = try await ucGetShareToken(pwdId: pwdId, passcode: passcode, cookie: authCookie)
        let sourceFile = try await ucFirstPlayableFile(pwdId: pwdId, stoken: stoken, pdirFid: "0", cookie: authCookie)
        print("[UC] 选中资源：\(sourceFile.fileName), fid=\(sourceFile.fid)")

        let fileIds = try await ucSaveShare(pwdId: pwdId, stoken: stoken, file: sourceFile, folderId: folder.folderId, cookie: authCookie)
        guard let fileId = fileIds.first else { throw DriveError.noPlayURL("UC: 转存后未返回文件ID") }

        var transcodeURL = ""
        do {
            transcodeURL = try await ucGetPlayURL(fileId: fileId, cookie: authCookie)
        } catch {
            print("[UC] ⚠️ v2/play 失败，继续尝试 download_url：\(error.localizedDescription)")
        }
        let download = try await ucGetDownloadURL(fileId: fileId, cookie: authCookie)
        let playURL = download.isEmpty ? transcodeURL : download
        guard !playURL.isEmpty else { throw DriveError.noPlayURL("UC: download_url 和转码地址均为空") }

        scheduleCleanup(drive: .uc, fileIds: fileIds, token: authCookie, delay: 60 * 60)

        let headers = ucPlaybackHeaders(cookie: authCookie)
        return PlayResult(
            url: playURL,
            headers: headers,
            driveType: .uc,
            source: download.isEmpty ? "v2-play" : "download_url",
            fallbackURL: (!download.isEmpty && !transcodeURL.isEmpty) ? transcodeURL : nil,
            fallbackHeaders: (!download.isEmpty && !transcodeURL.isEmpty) ? headers : nil,
            fallbackSource: (!download.isEmpty && !transcodeURL.isEmpty) ? "v2-play-m3u8" : nil
        )
    }

    private struct UCShareFile {
        let fid: String
        let fileName: String
        let shareFidToken: String
        let pdirFid: String
        let isDir: Bool
    }

    private func ucExtractShareInfo(from url: String) -> (pwdId: String, passcode: String) {
        var pwdId = ""
        if let range = url.range(of: #"/s/([^/?#]+)"#, options: .regularExpression) {
            pwdId = String(url[range]).replacingOccurrences(of: "/s/", with: "")
        } else {
            pwdId = url.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let queryItems = URLComponents(string: url)?.queryItems ?? []
        let passcode = queryItems.first(where: { ["pwd", "passcode", "password"].contains($0.name.lowercased()) })?.value ?? ""
        return (pwdId, passcode)
    }

    private func ucAPIURL(_ path: String, extra: [URLQueryItem] = []) -> URL {
        var components = URLComponents(string: "https://pc-api.uc.cn\(path)")!
        components.queryItems = [
            URLQueryItem(name: "pr", value: "UCBrowser"),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "sys", value: "darwin"),
            URLQueryItem(name: "ve", value: "1.8.5")
        ] + extra
        return components.url!
    }

    private func ucSetCommonHeaders(_ request: inout URLRequest, cookie: String, referer: String = "https://drive.uc.cn/") {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://drive.uc.cn", forHTTPHeaderField: "Origin")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/1.8.5 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/ucpan_other_ch", forHTTPHeaderField: "User-Agent")
    }

    private func ucShareReferer(pwdId: String) -> String {
        "https://drive.uc.cn/s/\(pwdId)"
    }

    private func ucPlaybackHeaders(cookie: String) -> [String: String] {
        [
            "Cookie": cookie,
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/1.8.5 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/ucpan_other_ch",
            "Referer": "https://drive.uc.cn/",
            "Origin": "https://drive.uc.cn",
            "Accept": "*/*",
            "Accept-Encoding": "identity"
        ]
    }

    private func ucSaveShare(pwdId: String, stoken: String, file: UCShareFile, folderId: String, cookie: String) async throws -> [String] {
        let url = ucAPIURL("/1/clouddrive/share/sharepage/save", extra: [URLQueryItem(name: "__t", value: String(Int(Date().timeIntervalSince1970 * 1000)))])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        ucSetCommonHeaders(&request, cookie: cookie, referer: ucShareReferer(pwdId: pwdId))
        let body: [String: Any] = [
            "fid_list": [file.fid],
            "fid_token_list": [file.shareFidToken],
            "to_pdir_fid": folderId,
            "pwd_id": pwdId,
            "stoken": stoken,
            "pdir_fid": file.pdirFid,
            "scene": "link"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)

        let respStr = String(data: data, encoding: .utf8) ?? ""
        print("[UC] save 响应：\(respStr.prefix(800))")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.saveFailed
        }

        if let status = json["status"] as? Int, status != 200 {
            let message = json["message"] as? String ?? json["msg"] as? String ?? "状态码：\(status)"
            throw DriveError.noPlayURL("UC 转存失败：\(message)")
        }

        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? json["msg"] as? String ?? "错误码：\(code)"
            throw DriveError.noPlayURL("UC 转存失败：\(message)")
        }

        if let dataObj = json["data"] as? [String: Any] {
            let taskResp = dataObj["task_resp"] as? [String: Any]
            let taskData = taskResp?["data"] as? [String: Any]
            let saveAs = taskData?["save_as"] as? [String: Any]
            if let ids = saveAs?["save_as_top_fids"] as? [String], !ids.isEmpty { return ids }
            if let ids = saveAs?["save_as_select_top_fids"] as? [String], !ids.isEmpty { return ids }
            if let fileIds = dataObj["file_ids"] as? [String] { return fileIds }
            if let fileIds = dataObj["file_ids"] as? [Int] { return fileIds.map { String($0) } }
            if let list = dataObj["list"] as? [[String: Any]], !list.isEmpty {
                let ids = list.compactMap { $0["fid"] as? String ?? $0["file_id"] as? String }
                if !ids.isEmpty { return ids }
            }
        }

        let recursiveIds = quarkExtractSavedFileIds(from: json, excluding: file.fid)
        if !recursiveIds.isEmpty { return recursiveIds }

        throw DriveError.noPlayURL("UC 转存成功但未返回已转存 fid")
    }

    private func ucGetShareToken(pwdId: String, passcode: String, cookie: String) async throws -> String {
        let url = ucAPIURL("/1/clouddrive/share/sharepage/token", extra: [URLQueryItem(name: "__t", value: String(Int(Date().timeIntervalSince1970 * 1000)))])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        ucSetCommonHeaders(&request, cookie: cookie, referer: ucShareReferer(pwdId: pwdId))

        let body: [String: Any] = ["pwd_id": pwdId, "passcode": passcode]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
            throw DriveError.noPlayURL("UC 分享 token 获取失败：\(message)")
        }
        guard let dataObj = json["data"] as? [String: Any],
              let stoken = dataObj["stoken"] as? String,
              !stoken.isEmpty else {
            throw DriveError.noPlayURL("UC 未返回 stoken")
        }
        return stoken
    }

    private func ucEnsureFolder(cookie: String) async throws -> String {
        (try await ucEnsureFolderWithCookie(cookie: cookie)).folderId
    }

    private func ucEnsureFolderWithCookie(cookie: String) async throws -> (folderId: String, cookie: String) {
        let listURL = ucAPIURL("/1/clouddrive/file/sort")
        var req = URLRequest(url: listURL)
        req.httpMethod = "POST"
        ucSetCommonHeaders(&req, cookie: cookie)
        let body: [String: Any] = ["pdir_fid": "0", "sort_by": "file_name", "sort_order": "asc", "page": 1, "size": 100]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        if let (data, response) = try? await session.data(for: req),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["data"] as? [String: Any],
           let files = list["list"] as? [[String: Any]] {
            let mergedCookie = quarkMergeSetCookie(from: response, into: cookie)
            for f in files {
                if let name = f["file_name"] as? String, name == "vbox",
                   let fid = f["fid"] as? String { return (fid, mergedCookie) }
            }
        }
        let createURL = ucAPIURL("/1/clouddrive/file")
        var createReq = URLRequest(url: createURL)
        createReq.httpMethod = "POST"
        ucSetCommonHeaders(&createReq, cookie: cookie)
        let createBody: [String: Any] = ["pdir_fid": "0", "file_name": "vbox", "dir": true, "dir_path": ""]
        createReq.httpBody = try JSONSerialization.data(withJSONObject: createBody)
        if let (createData, response) = try? await session.data(for: createReq),
           let createJson = try? JSONSerialization.jsonObject(with: createData) as? [String: Any],
           let d = createJson["data"] as? [String: Any],
           let fid = d["fid"] as? String {
            return (fid, quarkMergeSetCookie(from: response, into: cookie))
        }
        return ("0", cookie)
    }

    private func ucDeleteFiles(fileIds: [String], cookie: String) async {
        guard !fileIds.isEmpty else { return }
        let url = ucAPIURL("/1/clouddrive/file/delete")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        ucSetCommonHeaders(&req, cookie: cookie)
        let body: [String: Any] = ["action_type": 2, "filelist": fileIds, "exclude_fids": []]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let _ = try? await session.data(for: req)
        print("[CloudDrive] ✅ UC 已删除 \(fileIds.count) 个转存文件")
    }

    private func ucFirstPlayableFile(pwdId: String, stoken: String, pdirFid: String, cookie: String) async throws -> UCShareFile {
        let files = try await ucGetShareDetail(pwdId: pwdId, stoken: stoken, pdirFid: pdirFid, cookie: cookie)
        if let playable = files.first(where: { !$0.isDir && quarkIsPlayableFileName($0.fileName) }) {
            return playable
        }
        for dir in files where dir.isDir {
            if let found = try? await ucFirstPlayableFile(pwdId: pwdId, stoken: stoken, pdirFid: dir.fid, cookie: cookie) {
                return found
            }
        }
        throw DriveError.noPlayURL("UC 分享内未找到可播放视频")
    }

    private func ucGetShareDetail(pwdId: String, stoken: String, pdirFid: String, cookie: String) async throws -> [UCShareFile] {
        let url = ucAPIURL("/1/clouddrive/share/sharepage/detail", extra: [
            URLQueryItem(name: "__t", value: String(Int(Date().timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "_fetch_banner", value: "1"),
            URLQueryItem(name: "_fetch_total", value: "1"),
            URLQueryItem(name: "_page", value: "1"),
            URLQueryItem(name: "_size", value: "100"),
            URLQueryItem(name: "_sort", value: "file_type:asc,file_name:asc"),
            URLQueryItem(name: "pdir_fid", value: pdirFid),
            URLQueryItem(name: "pwd_id", value: pwdId),
            URLQueryItem(name: "stoken", value: stoken)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        ucSetCommonHeaders(&request, cookie: cookie, referer: ucShareReferer(pwdId: pwdId))
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
            throw DriveError.noPlayURL("UC 文件列表失败：\(message)")
        }
        guard let dataObj = json["data"] as? [String: Any],
              let list = dataObj["list"] as? [[String: Any]] else {
            throw DriveError.noPlayURL("UC 文件列表为空")
        }
        return list.compactMap { item in
            let fid = item["fid"] as? String ?? ""
            let name = item["file_name"] as? String ?? item["name"] as? String ?? ""
            let token = item["share_fid_token"] as? String ?? item["fid_token"] as? String ?? ""
            let isDir = (item["dir"] as? Bool) ?? ((item["file"] as? Bool) == false && (item["file_type"] as? Int) == 0)
            guard !fid.isEmpty, !name.isEmpty else { return nil }
            return UCShareFile(fid: fid, fileName: name, shareFidToken: token, pdirFid: pdirFid, isDir: isDir)
        }
    }

    private func ucGetPlayURL(fileId: String, cookie: String) async throws -> String {
        var request = URLRequest(url: ucAPIURL("/1/clouddrive/file/v2/play"))
        request.httpMethod = "POST"
        ucSetCommonHeaders(&request, cookie: cookie)

        let body: [String: Any] = [
            "fid": fileId,
            "resolutions": "normal,low,high,super,2k,4k",
            "supports": "fmp4,m3u8"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let dataObj = json["data"] as? [String: Any],
           let videos = dataObj["video_list"] as? [[String: Any]] {
            for item in videos {
                guard (item["accessable"] as? Bool) != false,
                      let info = item["video_info"] as? [String: Any],
                      let url = info["url"] as? String,
                      !url.isEmpty else { continue }
                return url
            }
        }
        if let dataObj = json["data"] as? [String: Any],
           let playURL = dataObj["play_url"] as? String,
           !playURL.isEmpty {
            return playURL
        }
        if let playURL = json["play_url"] as? String, !playURL.isEmpty { return playURL }
        throw DriveError.noPlayURL("UC: 未返回播放地址")
    }

    private func ucGetDownloadURL(fileId: String, cookie: String) async throws -> String {
        var request = URLRequest(url: ucAPIURL("/1/clouddrive/file/download"))
        request.httpMethod = "POST"
        ucSetCommonHeaders(&request, cookie: cookie)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fids": [fileId]])
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
            throw DriveError.noPlayURL("UC download_url 获取失败：\(message)")
        }
        if let list = json["data"] as? [[String: Any]],
           let first = list.first,
           let url = first["download_url"] as? String {
            return url
        }
        return ""
    }

    // MARK: - 统一解析入口

    func resolvePlayURL(from shareURL: String) async throws -> PlayResult {
        let cleanURL = shareURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        print("[CloudDrive] resolvePlayURL 输入: \(cleanURL.prefix(80))")
        guard let driveType = Self.detectDrive(from: cleanURL) else {
            print("[CloudDrive] ❌ detectDrive 返回 nil")
            throw DriveError.invalidShareURL
        }
        print("[CloudDrive] ✅ detectDrive: \(driveType.rawValue)")

        let tokens = tokens(for: driveType)
        guard !tokens.isEmpty else {
            throw DriveError.tokenNotConfigured(driveType.displayName)
        }

        var lastError: Error?
        if driveType == .baidu, let pair = baiduTokenPair() {
            print("[CloudDrive] 🔄 尝试百度网盘 WebToken: \(pair.web.name)，PCSToken: \(pair.pcs?.name ?? "未配置")")
            return try await resolveBaiduPlayURL(
                shareURL: shareURL,
                bduss: pair.web.value,
                pcsCookie: pair.pcs?.value ?? ""
            )
        }

        for (index, token) in tokens.enumerated() {
            let label = tokens.count > 1 ? " [\(index + 1)/\(tokens.count)]" : ""
            print("[CloudDrive] 🔄 尝试 \(driveType.displayName) Token\(label): \(token.name)")
            do {
                let result: PlayResult
                switch driveType {
                case .ali:
                    result = try await resolveAliPlayURL(shareURL: shareURL, refreshToken: token.value)
                case .quark:
                    result = try await resolveQuarkPlayURL(shareURL: shareURL, cookie: token.value)
                case .baidu:
                    result = try await resolveBaiduPlayURL(shareURL: shareURL, bduss: token.value)
                case .one15:
                    result = try await resolve115PlayURL(shareURL: shareURL, cid: token.value)
                case .uc:
                    result = try await resolveUCPlayURL(shareURL: shareURL, cookie: token.value)
                }
                print("[CloudDrive] ✅ \(driveType.displayName) Token \"\(token.name)\" 成功")
                return result
            } catch {
                lastError = error
                print("[CloudDrive] ⚠️ \(driveType.displayName) Token \"\(token.name)\" 失败: \(error.localizedDescription)")
                if isLikelyAuthInvalid(error) {
                    CloudDriveAuthManager.shared.markInvalid(driveType, reason: error.localizedDescription)
                }
                continue
            }
        }

        let count = tokens.count
        print("[CloudDrive] ❌ 所有 \(count) 个 \(driveType.displayName) Token 均失败")
        throw lastError ?? DriveError.tokenNotConfigured(driveType.displayName)
    }

    private func isLikelyAuthInvalid(_ error: Error) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("401")
            || text.contains("403")
            || text.contains("未登录")
            || text.contains("登录")
            || text.contains("cookie")
            || text.contains("token")
            || text.contains("access_token")
            || text.contains("refresh_token")
            || text.contains("授权")
            || text.contains("失效")
            || text.contains("invalid")
            || text.contains("expired")
    }
}

// MARK: - 数据结构

struct PlayResult {
    let url: String
    let headers: [String: String]
    let driveType: DriveTypeAlias
    let source: String?
    let fallbackURL: String?
    let fallbackHeaders: [String: String]?
    let fallbackSource: String?

    init(
        url: String,
        headers: [String: String],
        driveType: DriveTypeAlias,
        source: String? = nil,
        fallbackURL: String? = nil,
        fallbackHeaders: [String: String]? = nil,
        fallbackSource: String? = nil
    ) {
        self.url = url
        self.headers = headers
        self.driveType = driveType
        self.source = source
        self.fallbackURL = fallbackURL
        self.fallbackHeaders = fallbackHeaders
        self.fallbackSource = fallbackSource
    }
}

enum DriveTypeAlias: String {
    case ali = "阿里云盘"
    case quark = "夸克"
    case baidu = "百度"
    case one15 = "115"
    case uc = "UC"
}

enum DriveError: LocalizedError {
    case noPlayURL(String)
    case invalidResponse
    case invalidShareURL
    case saveFailed
    case notImplemented
    case tokenNotConfigured(String)

    var errorDescription: String? {
        switch self {
        case .noPlayURL(let reason):
            return "无法获取播放地址：\(reason)"
        case .invalidResponse:
            return "服务器响应无效"
        case .invalidShareURL:
            return "无效的分享链接"
        case .saveFailed:
            return "转存失败"
        case .notImplemented:
            return "该网盘暂不支持"
        case .tokenNotConfigured(let name):
            return "未配置\(name) Token"
        }
    }
}

// MARK: - 阿里云盘 API 响应模型

private struct AliTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private struct AliShareTokenResponse: Codable {
    let shareToken: String

    enum CodingKeys: String, CodingKey {
        case shareToken = "share_token"
    }
}

private struct AliVideoPreviewResponse: Codable {
    let videoPreviewPlayInfo: AliVideoPreviewInfo?

    enum CodingKeys: String, CodingKey {
        case videoPreviewPlayInfo = "video_preview_play_info"
    }
}

private struct AliVideoPreviewInfo: Codable {
    let liveTranscodingTaskList: [AliTranscodeTask]?

    enum CodingKeys: String, CodingKey {
        case liveTranscodingTaskList = "live_transcoding_task_list"
    }
}

private struct AliTranscodeTask: Codable {
    let url: String?
    let templateId: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case url
        case templateId = "template_id"
        case status
    }
}

// MARK: - MD5 扩展
extension String {
    func md5() -> String {
        let messageData = self.data(using: .utf8)!
        var digestData = Data(count: Int(CC_MD5_DIGEST_LENGTH))
        
        _ = digestData.withUnsafeMutableBytes { digestBytes in
            messageData.withUnsafeBytes { messageBytes in
                CC_MD5(messageBytes.baseAddress, CC_LONG(messageData.count), digestBytes.baseAddress)
            }
        }
        
        return digestData.map { String(format: "%02hhx", $0) }.joined()
    }
}
