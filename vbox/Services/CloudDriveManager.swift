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
    private static let baiduPCSUserAgent = "netdisk;1.4.2;22021211RC;android-android;12;JSbridge4.4.0;jointBridge;1.1.0;"

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
            case .baidu: return "完整 Cookie / BDUSS|STOKEN"
            case .one15: return "CID"
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

    private func baiduFileListCacheKey(shareURL: String, bduss: String) -> String {
        "\(shareURL)|\(baiduStableHash(bduss))"
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
        baiduPlayCacheLock.lock()
        baiduPlayCache.removeValue(forKey: cacheKey)
        baiduPlayCacheLock.unlock()

        var playCache = baiduLoadPersistedPlayCache()
        playCache.removeValue(forKey: cacheKey)
        if let data = try? JSONEncoder().encode(playCache) {
            defaults.set(data, forKey: baiduPersistedPlayCacheKey)
        }

        var iboxCache = baiduLoadPersistedIBoxPlayItemCache()
        if let item = iboxCache[cacheKey] {
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
            iboxCache[cacheKey] = invalidatedItem
            if let data = try? JSONEncoder().encode(iboxCache) {
                defaults.set(data, forKey: baiduIBoxPlayItemCacheKey)
            }
            mirrorBaiduIBoxPlayItemToUnified(invalidatedItem, sourceKey: cacheKey)
        } else {
            invalidateUnifiedCloudPlayItem(provider: .baidu, sourceKey: cacheKey, reason: "invalidated")
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
            baiduFileListCacheKey
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
        savedTokens.filter { $0.type == type.rawValue }
    }

    private func isBaiduPCSToken(_ token: DriveToken) -> Bool {
        let name = token.name.lowercased()
        let value = token.value.lowercased()
        if name.contains("pcs") || name.contains("下载") || name.contains("直链") || name.contains("locatedownload") {
            return true
        }
        return value.contains("panpsc=") || value.contains("ptoken_bfess=") || value.contains("ndut_fmt=") || value.contains("nd_ftid=")
    }

    func baiduTokenPair() -> (web: DriveToken, pcs: DriveToken?)? {
        let list = tokens(for: .baidu)
        guard !list.isEmpty else { return nil }

        let pcs = list.first(where: { isBaiduPCSToken($0) })
        let web = list.first(where: { !isBaiduPCSToken($0) }) ?? list[0]
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
        let tokenResult = try await aliRefreshAccessToken(refreshToken: refreshToken)
        let accessToken = tokenResult.accessToken

        let shareId = extractAliShareId(from: shareURL)
        let shareToken = try await aliGetShareToken(shareId: shareId, token: accessToken)
        let fileId = try await aliGetShareFileList(shareId: shareId, shareToken: shareToken, token: accessToken)

        let playInfo = try await aliGetVideoPreviewPlayInfo(fileId: fileId, token: accessToken)

        guard let playURL = playInfo.videoPreviewPlayInfo?.liveTranscodingTaskList?.first?.url else {
            throw DriveError.noPlayURL("阿里: 未获取到转码播放地址")
        }

        return PlayResult(
            url: playURL,
            headers: ["Authorization": accessToken, "Referer": "https://www.aliyundrive.com/"],
            driveType: .ali
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

    private func aliGetShareToken(shareId: String, token: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.aliyundrive.com/adrive/v3/share_file/get_share_token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["share_id": shareId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        let result = try JSONDecoder().decode(AliShareTokenResponse.self, from: data)
        return result.shareToken
    }

    private func aliGetShareFileList(shareId: String, shareToken: String, token: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.aliyundrive.com/adrive/v2/file/get_share_link_file_list")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "share_id": shareId,
            "share_token": shareToken,
            "parent_file_id": "root",
            "limit": 20,
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

        guard let first = items.first else {
            print("[Ali] ❌ 文件列表为空数组")
            throw DriveError.noPlayURL("阿里: 分享中没有文件")
        }

        if let fid = first["file_id"] as? String {
            print("[Ali] ✅ 获取到file_id: \(fid)")
            return fid
        } else if let fid = first["file_id"] as? Int {
            print("[Ali] ✅ 获取到file_id(Int): \(fid)")
            return String(fid)
        }

        print("[Ali] ❌ 无法从文件项中提取file_id")
        throw DriveError.noPlayURL("阿里: 无法获取文件ID")
    }

    private func aliGetVideoPreviewPlayInfo(fileId: String, token: String) async throws -> AliVideoPreviewResponse {
        let url = URL(string: "https://api.aliyundrive.com/adrive/v2/file/get_video_preview_play_info")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "Authorization")
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

    private func extractAliShareId(from url: String) -> String {
        let pattern = #"/s/([^/?]+)"#
        if let range = url.range(of: pattern, options: .regularExpression) {
            let matched = String(url[range])
            return matched.replacingOccurrences(of: "/s/", with: "")
        }
        return url
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
        print("[Quark] ✅ 播放地址 source=\(source), hasPUUS=\(authCookie.contains("__puus=")), hasVideoAuth=\(authCookie.contains("Video-Auth=")), host=\(URL(string: playURL)?.host ?? "unknown")")

        scheduleCleanup(drive: .quark, fileIds: fileIds, token: authCookie, delay: 20 * 60)

        return PlayResult(
            url: playURL,
            headers: quarkPlaybackHeaders(cookie: authCookie),
            driveType: .quark
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

    private func quarkSetCommonHeaders(_ request: inout URLRequest, cookie: String) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch", forHTTPHeaderField: "User-Agent")
    }

    private func quarkPlaybackHeaders(cookie: String) -> [String: String] {
        [
            "Cookie": cookie,
            "User-Agent": "Mozilla/5.0 (Linux; Android 12; HD1900 Build/SKQ1.211113.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/97.0.4692.98 Mobile Safari/537.36",
            "Referer": "https://pan.quark.cn/",
            "X-Device-Id": "2f49b7e148714010b615bfba561ae679",
            "Accept": "*/*"
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
        quarkSetCommonHeaders(&request, cookie: cookie)
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
        return st
    }

    private func quarkEnsureFolder(cookie: String) async throws -> String {
        (try await quarkEnsureFolderWithCookie(cookie: cookie)).folderId
    }

    private func quarkEnsureFolderWithCookie(cookie: String) async throws -> (folderId: String, cookie: String) {
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
        let url = quarkAPIURL("/1/clouddrive/share/sharepage/detail", extra: [
            URLQueryItem(name: "__t", value: String(Int(Date().timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "_fetch_banner", value: "1"),
            URLQueryItem(name: "_fetch_total", value: "1"),
            URLQueryItem(name: "_page", value: "1"),
            URLQueryItem(name: "_size", value: "100"),
            URLQueryItem(name: "_sort", value: "file_type:asc,file_name:asc"),
            URLQueryItem(name: "force", value: "0"),
            URLQueryItem(name: "pdir_fid", value: pdirFid),
            URLQueryItem(name: "pwd_id", value: pwdId),
            URLQueryItem(name: "stoken", value: stoken)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        quarkSetCommonHeaders(&request, cookie: cookie)
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
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
        quarkSetCommonHeaders(&request, cookie: cookie)
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

        throw DriveError.noPlayURL("夸克转存成功但未返回已转存 fid")
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
                // 完整 Cookie 模式：如果用户粘贴了 BDUSS/STOKEN/BAIDUID/PANPSC 等多字段，
                // 不再只截取 BDUSS/STOKEN，直接原样交给 Worker 使用。
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

    func baiduGetFileList(shareURL: String, bduss: String) async throws -> [BaiduFileItem] {
        let parsed = parseBaiduToken(bduss)
        let cookie = parsed.cookie
        let cacheKey = baiduFileListCacheKey(shareURL: shareURL, bduss: bduss)

        if let cached = baiduCachedFileList(for: cacheKey) {
            baiduLog("[Baidu-iBox] ✅ 命中文件列表缓存：\(cached.count) 个文件")
            recordBaiduRouteDiagnostic(stage: "文件列表", status: "缓存命中", detail: "命中百度文件列表缓存：\(cached.count) 个文件")
            return cached
        }

        if let files = try? await baiduGetFileListViaWorker(shareURL: shareURL, pwd: extractBaiduPwd(from: shareURL), cookie: cookie) {
            baiduStoreFileList(files, for: cacheKey)
            recordBaiduRouteDiagnostic(stage: "文件列表", status: "Worker成功", detail: "Worker 返回 \(files.count) 个文件")
            return files
        }

        baiduLog("[Baidu-Worker] ⚠️ 文件列表代理失败，回退直连解析")
        recordBaiduRouteDiagnostic(stage: "文件列表", status: "Worker失败", detail: "文件列表代理失败，回退本机直连解析")
        let context = try await baiduExtractShareMeta(shareURL: shareURL, cookie: cookie, returnAll: true)
        baiduStoreFileList(context.files, for: cacheKey)
        recordBaiduRouteDiagnostic(stage: "文件列表", status: "本机成功", detail: "本机解析返回 \(context.files.count) 个文件")
        return context.files
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
        return nil
    }

    /// 通过 Cloudflare Worker 代理解析文件列表，避免直连百度分享页提取码验证卡死
    private func baiduGetFileListViaWorker(shareURL: String, pwd: String?, cookie: String) async throws -> [BaiduFileItem] {
        baiduLog("[Baidu-Worker] 代理解析文件列表... Cookie=\(cookie.isEmpty ? "无" : "已传递")")

        let response = try await BaiduProxyClient.shared.parseShareLink(
            url: shareURL,
            pwd: pwd ?? "",
            cookie: cookie
        )

        guard let success = response["success"] as? Bool, success else {
            let err = response["error"] as? String ?? "未知错误"
            baiduLog("[Baidu-Worker] ❌ 文件列表解析失败：\(err)")
            throw DriveError.noPlayURL("Worker 代理解析失败：\(err)")
        }

        let data = (response["data"] as? [String: Any]) ?? response
        let rawFiles = data["files"] as? [[String: Any]]
            ?? data["file_list"] as? [[String: Any]]
            ?? data["list"] as? [[String: Any]]
            ?? []

        let files: [BaiduFileItem] = rawFiles.compactMap { item in
            let fsId = item["fs_id"] as? String
                ?? item["fsId"] as? String
                ?? (item["fs_id"] as? NSNumber)?.stringValue
                ?? (item["fsId"] as? NSNumber)?.stringValue
                ?? ""
            let path = item["path"] as? String
            let name = path
                ?? item["file_name"] as? String
                ?? item["server_filename"] as? String
                ?? item["name"] as? String
                ?? "未知文件"
            guard !fsId.isEmpty else { return nil }
            return BaiduFileItem(fsId: fsId, name: name)
        }

        guard !files.isEmpty else {
            baiduLog("[Baidu-Worker] ❌ 未解析到文件列表")
            throw DriveError.noPlayURL("Worker 代理未返回文件列表")
        }

        baiduLog("[Baidu-Worker] ✅ 文件列表：\(files.count) 个")
        return files
    }

    /// 【新增】通过 Cloudflare Worker 代理获取播放地址
    private func baiduResolveViaWorker(shareURL: String, pwd: String?, fsId: String? = nil, cookie: String = "", pcsCookie: String = "", cacheKey: String? = nil) async throws -> PlayResult {
        baiduLog("[Baidu-Worker] 调用 Cloudflare Worker 代理... fsId=\((fsId ?? "").isEmpty ? "自动" : fsId!), pwd=\((pwd ?? "").isEmpty ? "无" : "已传递"), WebCookie=\(cookie.isEmpty ? "无" : "已传递"), PCSCookie=\(pcsCookie.isEmpty ? "无" : "已传递")")

        let response = try await BaiduProxyClient.shared.getPlayURL(
            shareURL: shareURL,
            pwd: pwd ?? "",
            fsId: fsId ?? "",
            cookie: cookie,
            pcsCookie: pcsCookie
        )
        baiduLog("[Baidu-Worker] 收到播放响应，字段：\(response.keys.sorted().joined(separator: ","))")

        guard let success = response["success"] as? Bool, success else {
            let err = response["error"] as? String ?? "未知错误"
            baiduLog("[Baidu-Worker] ❌ 失败：\(err)")
            throw DriveError.noPlayURL("Worker 代理：\(err)")
        }

        let data = (response["data"] as? [String: Any]) ?? response
        let playURLKeys = ["url", "dlink", "play_url", "playURL", "download_url", "downloadURL"]
        var rawPlayURL: String?
        for key in playURLKeys {
            if let value = data[key] as? String, !value.isEmpty {
                rawPlayURL = value
                break
            }
        }
        if rawPlayURL == nil {
            for key in playURLKeys {
                if let value = response[key] as? String, !value.isEmpty {
                    rawPlayURL = value
                    break
                }
            }
        }

        guard var playURL = rawPlayURL, !playURL.isEmpty else {
            let returnedFields = data.keys.sorted().joined(separator: ",")
            baiduLog("[Baidu-Worker] ❌ 未返回播放地址，data字段：\(returnedFields)")
            throw DriveError.noPlayURL("Worker 代理未返回播放地址，返回字段：\(returnedFields)")
        }

        if playURL.hasPrefix("//") {
            playURL = "https:" + playURL
        }

        var headers = (data["headers"] as? [String: String])
            ?? (response["headers"] as? [String: String])
            ?? [:]
        if headers["User-Agent"] == nil {
            headers["User-Agent"] = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        }
        if headers["Referer"] == nil {
            headers["Referer"] = "https://pan.baidu.com/"
        }

        baiduLog("[Baidu-Worker] ✅ 成功获取播放地址：\(playURL.prefix(80))...")
        recordBaiduRouteDiagnostic(stage: "Worker取链", status: "成功", detail: "Worker 返回播放地址", fsId: fsId)

        let workerPath = data["path"] as? String
        let workerFileName = data["file_name"] as? String
            ?? data["server_filename"] as? String
            ?? data["name"] as? String
            ?? ""
        let inferredPath = baiduInferOwnFilePath(workerURL: playURL, workerPath: workerPath, fileName: workerFileName)
        if let cacheKey,
           let path = inferredPath,
           !(fsId ?? "").isEmpty {
            baiduStorePlayItem(
                BaiduPlayItem(
                    fsId: fsId ?? "",
                    fileName: workerFileName,
                    path: path,
                    headers: headers,
                    compatibilityHint: baiduCompatibilityHint(fileName: workerFileName),
                    updatedAt: Date()
                ),
                for: cacheKey
            )
            baiduLog("[Baidu-PlayItem] ✅ 缓存 path=\(path), hint=\(baiduCompatibilityHint(fileName: workerFileName))")
        }

        if let localResult = try? await baiduResolveDLNAOnDevice(
            workerURL: playURL,
            workerPath: workerPath,
            fileName: workerFileName,
            webCookie: cookie,
            pcsCookie: pcsCookie,
            workerHeaders: headers
        ) {
            recordBaiduRouteDiagnostic(stage: "本机取链", status: "成功", detail: "Worker 返回 path 后，本机刷新 dlink 成功", fsId: fsId, fileName: workerFileName)
            if let cacheKey, let path = inferredPath, !(fsId ?? "").isEmpty {
                let fileNameForCache = workerFileName.isEmpty ? (path.split(separator: "/").last.map(String.init) ?? "") : workerFileName
                baiduStoreIBoxPlayItem(
                    BaiduIBoxPlayItem(
                        shareURL: shareURL,
                        fsId: fsId ?? "",
                        fileName: fileNameForCache,
                        path: path,
                        dlinkURL: localResult.url,
                        headers: localResult.headers,
                        dlinkExpiresAt: Date().addingTimeInterval(6 * 60 * 60),
                        compatibilityHint: baiduCompatibilityHint(fileName: fileNameForCache),
                        preferredEngine: baiduPreferredEngine(fileName: fileNameForCache),
                        preparedAt: Date(),
                        updatedAt: Date(),
                        lastUsedAt: Date(),
                        source: "worker+local-dlna"
                    ),
                    for: cacheKey
                )
                baiduLog("[Baidu-iBox] ✅ PlayItem 已准备：path=\(path), engine=\(baiduPreferredEngine(fileName: fileNameForCache))")
            }
            return localResult
        }

        baiduLog("[Baidu-LocalPCS] ⚠️ 本机 DLNA/locatedownload 未成功，暂用 Worker 返回地址")
        recordBaiduRouteDiagnostic(stage: "本机取链", status: "失败兜底", detail: "本机刷新 dlink 失败，使用 Worker 地址兜底", fsId: fsId, fileName: workerFileName)
        if let cacheKey, let path = inferredPath, !(fsId ?? "").isEmpty {
            let fileNameForCache = workerFileName.isEmpty ? (path.split(separator: "/").last.map(String.init) ?? "") : workerFileName
            baiduStoreIBoxPlayItem(
                BaiduIBoxPlayItem(
                    shareURL: shareURL,
                    fsId: fsId ?? "",
                    fileName: fileNameForCache,
                    path: path,
                    dlinkURL: playURL,
                    headers: headers,
                    dlinkExpiresAt: Date().addingTimeInterval(2 * 60 * 60),
                    compatibilityHint: baiduCompatibilityHint(fileName: fileNameForCache),
                    preferredEngine: baiduPreferredEngine(fileName: fileNameForCache),
                    preparedAt: Date(),
                    updatedAt: Date(),
                    lastUsedAt: Date(),
                    source: "worker-fallback"
                ),
                for: cacheKey
            )
            baiduLog("[Baidu-iBox] ⚠️ 已保存 Worker 兜底 PlayItem：path=\(path)")
        }
        return PlayResult(url: playURL, headers: headers, driveType: .baidu)
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
            item.headers.first { $0.key.lowercased() == "x-baidu-pcs-cookie" }?.value ?? "",
            cookie,
            pcsCookie
        ])
        guard !mergedCookie.isEmpty else {
            baiduLog("[Baidu-iBox] ⚠️ path 刷新缺少 Cookie，回退 Worker")
            recordBaiduRouteDiagnostic(stage: "iBox", status: "Cookie缺失", detail: "path 刷新缺少 Cookie，回退 Worker", fsId: fsId, fileName: item.fileName)
            return nil
        }

        let refreshed: PlayResult
        do {
            refreshed = try await baiduGetDLNADlinkOnDevice(filePath: item.path, cookie: mergedCookie)
        } catch {
            baiduLog("[Baidu-iBox] ⚠️ DLNA 刷新失败，尝试 locatedownload：\(error.localizedDescription)")
            recordBaiduRouteDiagnostic(stage: "iBox", status: "mediainfo失败", detail: "path mediainfo 失败，尝试 locatedownload：\(error.localizedDescription)", fsId: fsId, fileName: item.fileName)
            refreshed = try await baiduGetLocatedownloadOnDevice(filePath: item.path, cookie: mergedCookie)
        }

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

    private func baiduResolveDLNAOnDevice(
        workerURL: String,
        workerPath: String?,
        fileName: String?,
        webCookie: String,
        pcsCookie: String,
        workerHeaders: [String: String]
    ) async throws -> PlayResult {
        guard let filePath = baiduInferOwnFilePath(workerURL: workerURL, workerPath: workerPath, fileName: fileName) else {
            baiduLog("[Baidu-LocalPCS] ⚠️ 无法从 Worker 地址推断自己网盘文件路径")
            throw DriveError.noPlayURL("无法推断百度转存路径")
        }

        let cookie = baiduMergeCookieStrings([
            workerHeaders.first { $0.key.lowercased() == "cookie" }?.value ?? "",
            workerHeaders.first { $0.key.lowercased() == "x-baidu-pcs-cookie" }?.value ?? "",
            webCookie,
            pcsCookie
        ])
        guard !cookie.isEmpty else {
            baiduLog("[Baidu-LocalPCS] ⚠️ 本机取链缺少 Cookie")
            throw DriveError.noPlayURL("百度本机取链缺少 Cookie")
        }

        do {
            return try await baiduGetDLNADlinkOnDevice(filePath: filePath, cookie: cookie)
        } catch {
            baiduLog("[Baidu-DLNA] ⚠️ mediainfo 取 dlink 失败，兜底 locatedownload：\(error.localizedDescription)")
            return try await baiduGetLocatedownloadOnDevice(filePath: filePath, cookie: cookie)
        }
    }

    private func baiduResolveOnDevice(
        shareURL: String,
        pwd: String?,
        fsId: String,
        webCookie: String,
        pcsCookie: String
    ) async throws -> PlayResult {
        baiduLog("[Baidu-Local] 本机播放链路开始：fsId=\(fsId), pwd=\((pwd ?? "").isEmpty ? "无" : "已传递")")
        let context = try await baiduExtractShareMeta(shareURL: shareURL, cookie: webCookie, returnAll: true)
        let selected = context.files.first { $0.fsId == fsId }
            ?? context.files.first { $0.fsId.trimmingCharacters(in: .whitespacesAndNewlines) == fsId.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let selected else {
            baiduLog("[Baidu-Local] ❌ 本机文件列表未找到 fsId=\(fsId)")
            throw DriveError.noPlayURL("本机文件列表未找到目标文件")
        }

        let mergedCookie = baiduMergeCookieStrings([context.cookie, webCookie, pcsCookie])
        try await baiduEnsureVboxFolderLocal(cookie: mergedCookie)
        let existingPath = try await baiduFindExistingVboxPath(fileName: selected.name, cookie: mergedCookie)
        let filePath: String
        if let existingPath {
            filePath = existingPath
            baiduLog("[Baidu-Local] ✅ /vbox 命中已转存文件：\(filePath)")
        } else {
            filePath = try await baiduTransferFileOnDevice(
                shareid: context.shareid,
                shareUk: context.shareUk,
                fsId: selected.fsId,
                fileName: selected.name,
                cookie: mergedCookie
            )
            baiduLog("[Baidu-Local] ✅ 本机转存完成：\(filePath)")
        }

        do {
            return try await baiduGetDLNADlinkOnDevice(filePath: filePath, cookie: mergedCookie)
        } catch {
            baiduLog("[Baidu-DLNA] ⚠️ 本机 mediainfo 失败，兜底 locatedownload：\(error.localizedDescription)")
            return try await baiduGetLocatedownloadOnDevice(filePath: filePath, cookie: mergedCookie)
        }
    }

    private func baiduEnsureVboxFolderLocal(cookie: String) async throws {
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
        request.httpBody = "path=/vbox&isdir=1&block_list=[]".data(using: .utf8)

        let (data, _) = try await session.data(for: request)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errno = json["errno"] as? Int,
           errno == 0 || errno == -8 {
            return
        }
        baiduLog("[Baidu-Local] ⚠️ /vbox 创建响应：\(String(data: data.prefix(160), encoding: .utf8) ?? "")")
    }

    private func baiduFindExistingVboxPath(fileName: String, cookie: String) async throws -> String? {
        var components = URLComponents(string: "https://pan.baidu.com/api/list")!
        components.queryItems = [
            URLQueryItem(name: "dir", value: "/vbox"),
            URLQueryItem(name: "order", value: "time"),
            URLQueryItem(name: "desc", value: "1"),
            URLQueryItem(name: "num", value: "200"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "bdstoken", value: ""),
            URLQueryItem(name: "channel", value: "chunlei"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "clienttype", value: "0")
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 12
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

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
                return item["path"] as? String ?? "/vbox/\(normalizedTarget)"
            }
        }
        return nil
    }

    private func baiduTransferFileOnDevice(
        shareid: String,
        shareUk: String,
        fsId: String,
        fileName: String,
        cookie: String
    ) async throws -> String {
        var components = URLComponents(string: "https://pan.baidu.com/share/transfer")!
        components.queryItems = [
            URLQueryItem(name: "shareid", value: shareid),
            URLQueryItem(name: "from", value: shareUk),
            URLQueryItem(name: "sekey", value: baiduCookieValue(cookie, named: "randsk") ?? baiduCookieValue(cookie, named: "BDCLND") ?? ""),
            URLQueryItem(name: "ondup", value: "newcopy"),
            URLQueryItem(name: "async", value: "1"),
            URLQueryItem(name: "channel", value: "chunlei"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "clienttype", value: "0")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.httpBody = "fsidlist=[\(fsId)]&path=/vbox".data(using: .utf8)

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
        return "/vbox/\(normalizedName)"
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

    private func baiduGetDLNADlinkOnDevice(filePath: String, cookie: String) async throws -> PlayResult {
        let deviceId = baiduStableDeviceId()
        var components = URLComponents(string: "https://pan.baidu.com/api/mediainfo")!
        components.queryItems = [
            URLQueryItem(name: "clienttype", value: "80"),
            URLQueryItem(name: "origin", value: "dlna"),
            URLQueryItem(name: "path", value: filePath),
            URLQueryItem(name: "type", value: "M3U8_FLV_264_480")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(Self.baiduPCSUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

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
            return baiduPlayResult(url: dlink, cookie: cookie)
        }

        let errno = json["errno"] as? Int ?? -1
        let msg = json["errmsg"] as? String ?? json["show_msg"] as? String ?? json["msg"] as? String ?? "errno=\(errno)"
        baiduLog("[Baidu-DLNA] ❌ 未返回 dlink：errno=\(errno), msg=\(msg), fields=\(json.keys.sorted().joined(separator: ","))")
        throw DriveError.noPlayURL("百度 DLNA 未返回 dlink：\(msg)")
    }

    private func baiduGetLocatedownloadOnDevice(filePath: String, cookie: String) async throws -> PlayResult {
        let deviceId = baiduStableDeviceId()
        var components = URLComponents(string: "https://d.pcs.baidu.com/rest/2.0/pcs/file")!
        components.queryItems = [
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "method", value: "locatedownload"),
            URLQueryItem(name: "check_blue", value: "1"),
            URLQueryItem(name: "path", value: filePath),
            URLQueryItem(name: "version", value: "2.2.101.236"),
            URLQueryItem(name: "clienttype", value: "17"),
            URLQueryItem(name: "time", value: String(Int(Date().timeIntervalSince1970))),
            URLQueryItem(name: "rand", value: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()),
            URLQueryItem(name: "devuid", value: deviceId),
            URLQueryItem(name: "channel", value: "0"),
            URLQueryItem(name: "version_app", value: "12.24.6"),
            URLQueryItem(name: "apn_id", value: "1_0"),
            URLQueryItem(name: "freeisp", value: "0"),
            URLQueryItem(name: "queryfree", value: "0"),
            URLQueryItem(name: "cuid", value: deviceId),
            URLQueryItem(name: "network_type", value: "WIFI"),
            URLQueryItem(name: "deviceid", value: String(abs(deviceId.hashValue)))
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(Self.baiduPCSUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://pan.baidu.com", forHTTPHeaderField: "Origin")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        baiduLog("[Baidu-LocalPCS] 本机调用 locatedownload：path=\(filePath), hasBDUSS=\(cookie.lowercased().contains("bduss=")), hasSTOKEN=\(cookie.lowercased().contains("stoken=")), hasPANPSC=\(cookie.lowercased().contains("panpsc=")), hasPTOKEN=\(cookie.lowercased().contains("ptoken"))")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
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
        return baiduPlayResult(url: locatedURL, cookie: cookie)
    }

    private func baiduPlayResult(url: String, cookie: String) -> PlayResult {
        PlayResult(
            url: url,
            headers: [
                "Cookie": cookie,
                "X-Baidu-Pcs-Cookie": cookie,
                "User-Agent": Self.baiduPCSUserAgent,
                "Referer": "https://pan.baidu.com/",
                "Origin": "https://pan.baidu.com",
                "X-Device-ID": baiduStableDeviceId()
            ],
            driveType: .baidu
        )
    }

    private func baiduInferOwnFilePath(workerURL: String, workerPath: String?, fileName: String?) -> String? {
        if let path = workerPath, path.hasPrefix("/vbox") || path.hasPrefix("/0000temp") || path.hasPrefix("/vbox播放") {
            return path
        }

        guard let components = URLComponents(string: workerURL) else { return nil }
        var fpath = components.queryItems?.first(where: { $0.name == "fpath" })?.value ?? ""
        var fin = components.queryItems?.first(where: { $0.name == "fin" })?.value ?? ""
        fpath = fpath.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? fpath
        fin = fin.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? fin
        fpath = fpath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !fpath.isEmpty, !fin.isEmpty {
            return "/\(fpath)/\(fin)"
        }

        let fallbackName = fileName
            ?? workerPath?.split(separator: "/").last.map(String.init)
        if let fallbackName, !fallbackName.isEmpty {
            return "/vbox/\(fallbackName)"
        }

        return nil
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
        let pwdForWorker = pwd ?? extractBaiduPwd(from: shareURL)
        let parsed = parseBaiduToken(bduss)
        let cookie = parsed.cookie
        let parsedPcs = parseBaiduToken(pcsCookie)
        let pcs = pcsCookie.isEmpty ? "" : parsedPcs.cookie

        do {
            return try await baiduResolveViaWorker(shareURL: shareURL, pwd: pwdForWorker, cookie: cookie, pcsCookie: pcs)
        } catch {
            baiduLog("[Baidu-Worker] ⚠️ 自动文件播放失败，改用 Worker 文件列表选择第一个视频：\(error.localizedDescription)")
            let files = try await baiduGetFileListViaWorker(shareURL: shareURL, pwd: pwdForWorker, cookie: cookie)
            guard let first = files.first, !first.fsId.isEmpty else {
                throw DriveError.noPlayURL("Worker 代理未返回可播放文件")
            }
            return try await baiduResolveViaWorker(shareURL: shareURL, pwd: pwdForWorker, fsId: first.fsId, cookie: cookie, pcsCookie: pcs)
        }
    }

    func resolveBaiduPlayURL(shareURL: String, bduss: String, fsId: String, pcsCookie: String = "") async throws -> PlayResult {
        let cacheKey = baiduPlayCacheKey(shareURL: shareURL, fsId: fsId, bduss: bduss, pcsCookie: pcsCookie)
        if let cached = baiduCachedPlayResult(for: cacheKey) {
            baiduLog("[Baidu-Cache] ✅ 命中播放地址缓存 fsId=\(fsId)")
            recordBaiduRouteDiagnostic(stage: "播放缓存", status: "命中", detail: "命中播放地址缓存", fsId: fsId)
            return cached
        }

        let pwdForWorker = extractBaiduPwd(from: shareURL)
        let parsed = parseBaiduToken(bduss)
        let cookie = parsed.cookie
        let parsedPcs = parseBaiduToken(pcsCookie)
        let pcs = pcsCookie.isEmpty ? "" : parsedPcs.cookie

        if let iboxResult = try? await baiduResolveViaIBoxPlayItem(
            cacheKey: cacheKey,
            shareURL: shareURL,
            fsId: fsId,
            fileName: baiduCachedPlayItem(for: cacheKey)?.fileName,
            cookie: cookie,
            pcsCookie: pcs
        ) {
            baiduStorePlayResult(iboxResult, for: cacheKey)
            return iboxResult
        }

        if let item = baiduCachedPlayItem(for: cacheKey), !item.path.isEmpty {
            do {
                baiduLog("[Baidu-PlayItem] ✅ 命中 path 缓存，直接 mediainfo：\(item.path), hint=\(item.compatibilityHint)")
                recordBaiduRouteDiagnostic(stage: "PlayItem", status: "path命中", detail: "命中旧 PlayItem path，开始刷新：\(item.path)", fsId: fsId, fileName: item.fileName)
                let mergedCookie = baiduMergeCookieStrings([
                    item.headers.first { $0.key.lowercased() == "cookie" }?.value ?? "",
                    item.headers.first { $0.key.lowercased() == "x-baidu-pcs-cookie" }?.value ?? "",
                    cookie,
                    pcs
                ])
                let result: PlayResult
                do {
                    result = try await baiduGetDLNADlinkOnDevice(filePath: item.path, cookie: mergedCookie)
                } catch {
                    baiduLog("[Baidu-PlayItem] ⚠️ path mediainfo 失败，尝试 locatedownload：\(error.localizedDescription)")
                    recordBaiduRouteDiagnostic(stage: "PlayItem", status: "mediainfo失败", detail: "旧 path mediainfo 失败，尝试 locatedownload：\(error.localizedDescription)", fsId: fsId, fileName: item.fileName)
                    result = try await baiduGetLocatedownloadOnDevice(filePath: item.path, cookie: mergedCookie)
                }
                baiduStoreIBoxPlayItem(
                    BaiduIBoxPlayItem(
                        shareURL: shareURL,
                        fsId: fsId,
                        fileName: item.fileName,
                        path: item.path,
                        dlinkURL: result.url,
                        headers: result.headers,
                        dlinkExpiresAt: Date().addingTimeInterval(6 * 60 * 60),
                        compatibilityHint: item.compatibilityHint,
                        preferredEngine: baiduPreferredEngine(fileName: item.fileName),
                        preparedAt: item.updatedAt,
                        updatedAt: Date(),
                        lastUsedAt: Date(),
                        source: "legacy-playitem-path-refresh"
                    ),
                    for: cacheKey
                )
                baiduLog("[Baidu-iBox] ✅ 旧 PlayItem 已通过 path 刷新并升级为 iBox PlayItem")
                recordBaiduRouteDiagnostic(stage: "PlayItem", status: "path刷新成功", detail: "旧 PlayItem 已刷新并升级为 iBox", fsId: fsId, fileName: item.fileName)
                baiduStorePlayResult(result, for: cacheKey)
                return result
            } catch {
                baiduLog("[Baidu-PlayItem] ⚠️ path 缓存刷新失败，回退 Worker：\(error.localizedDescription)")
                recordBaiduRouteDiagnostic(stage: "PlayItem", status: "path刷新失败", detail: "旧 path 刷新失败，回退 Worker：\(error.localizedDescription)", fsId: fsId, fileName: item.fileName)
            }
        }

        do {
            let result = try await baiduResolveViaWorker(shareURL: shareURL, pwd: pwdForWorker, fsId: fsId, cookie: cookie, pcsCookie: pcs, cacheKey: cacheKey)
            baiduStorePlayResult(result, for: cacheKey)
            return result
        } catch {
            baiduLog("[Baidu-Worker] ❌ 指定文件播放代理失败：\(error.localizedDescription)")
            recordBaiduRouteDiagnostic(stage: "Worker取链", status: "失败", detail: "指定文件 Worker 播放失败：\(error.localizedDescription)", fsId: fsId)
            throw DriveError.noPlayURL("Worker 代理播放失败：\(error.localizedDescription)")
        }
    }

    @discardableResult
    func prepareBaiduIBoxPlayItem(shareURL: String, bduss: String, fsId: String, pcsCookie: String = "") async throws -> PlayResult {
        baiduLog("[Baidu-iBox] 开始准备 PlayItem：fsId=\(fsId)")
        let result = try await resolveBaiduPlayURL(shareURL: shareURL, bduss: bduss, fsId: fsId, pcsCookie: pcsCookie)
        baiduLog("[Baidu-iBox] ✅ PlayItem 准备完成：fsId=\(fsId)")
        return result
    }

    private func baiduExtractShareMeta(shareURL: String, cookie: String, returnAll: Bool = false) async throws -> (shareid: String, shareUk: String, surl: String, cookie: String, files: [BaiduFileItem]) {
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

        let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        var currentCookie = cookie

        guard let pageURL = URL(string: shareURL) else { throw DriveError.invalidShareURL }
        var req = URLRequest(url: pageURL)
        req.setValue(currentCookie, forHTTPHeaderField: "Cookie")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        baiduLog("[Baidu] 请求原始链接...")
        let (data, response) = try await session.data(for: req)
        guard let httpResp = response as? HTTPURLResponse else { throw DriveError.invalidResponse }

        if httpResp.statusCode != 200 {
            baiduLog("[Baidu] ❌ 返回状态码: \(httpResp.statusCode)")
            if httpResp.statusCode == 404 {
                throw DriveError.noPlayURL("百度网盘：分享链接不存在或已失效")
            }
            throw DriveError.noPlayURL("百度网盘：请求失败(\(httpResp.statusCode))")
        }

        if let sc = httpResp.allHeaderFields["Set-Cookie"] as? String { currentCookie += "; " + sc
        } else if let scs = httpResp.allHeaderFields["Set-Cookie"] as? [String] { currentCookie += "; " + scs.joined(separator: "; ") }

        guard var html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            baiduLog("[Baidu] ❌ 无法解码")
            throw DriveError.noPlayURL("百度网盘：服务器返回异常数据")
        }

        var shareid = ""
        var shareUk = ""
        var files: [BaiduFileItem] = []

        if let pwd = pwd, (html.contains("请输入提取码") || html.contains("accessCode")) {
            baiduLog("[Baidu] 需要验证提取码...")
            baiduLog("[Baidu] Cookie 片段: \(String(currentCookie.prefix(100)))...")

            var vidShareid = ""
            var vidUk = ""
            var vidFsId = ""
            var vidFileName = "未知文件"

            for pattern in ["\"shareid\"\\s*:\\s*\"?(\\d+)\"?", "\"share_id\"\\s*:\\s*\"?(\\d+)\"?", "shareid=(\\d+)", "data-shareid=\"(\\d+)\""] {
                if let r = try? NSRegularExpression(pattern: pattern).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   let rr = Range(r.range(at: 1), in: html) { vidShareid = String(html[rr]); break }
            }
            for pattern in ["\"share_uk\"\\s*:\\s*\"?(\\d+)\"?", "\"uk\"\\s*:\\s*\"?(\\d+)\"?"] {
                if let r = try? NSRegularExpression(pattern: pattern).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   let rr = Range(r.range(at: 1), in: html) { vidUk = String(html[rr]); break }
            }
            if let r = try? NSRegularExpression(pattern: "\"fs_id\"\\s*:\\s*\"?(\\d+)\"?").firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let rr = Range(r.range(at: 1), in: html) { vidFsId = String(html[rr]) }
            if let r = try? NSRegularExpression(pattern: "\"server_filename\"\\s*:\\s*\"([^\"]+)\"").firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let rr = Range(r.range(at: 1), in: html) { vidFileName = String(html[rr]) }

            baiduLog("[Baidu] 从初始HTML提取: shareid=\(vidShareid), uk=\(vidUk), fsId=\(vidFsId), file=\(vidFileName)")

            let verifyURLString = "https://pan.baidu.com/share/verify?surl=\(surl)&t=\(Int(Date().timeIntervalSince1970 * 1000))&channel=chunlei&web=1&app_id=250528&clienttype=0"
            let verifyBodyString = "pwd=\(pwd)&vcode=&vcode_str=&channel=chunlei&web=1&app_id=250528&clienttype=0"

            var randsk = ""
            var verifyRetryCount = 0
            var verifyOK = false
            verifyLoop: while verifyRetryCount < 3 {
                let (vData, _) = try await BaiduWebViewBridge.shared.request(
                    url: verifyURLString,
                    method: "POST",
                    headers: [
                        "Content-Type": "application/x-www-form-urlencoded",
                        "Cookie": currentCookie,
                        "User-Agent": ua,
                        "X-Requested-With": "XMLHttpRequest",
                        "Origin": "https://pan.baidu.com",
                        "Referer": "https://pan.baidu.com/s/1\(surl)",
                    ],
                    body: verifyBodyString,
                    timeout: 15
                )
                baiduLog("[Baidu-WK] 验证响应：\(String(data: vData, encoding: .utf8) ?? "nil")")

                guard let vJson = try? JSONSerialization.jsonObject(with: vData) as? [String: Any],
                      let errno = vJson["errno"] as? Int else {
                    baiduLog("[Baidu] ❌ 验证响应解析失败")
                    throw DriveError.invalidResponse
                }

                if let r = vJson["randsk"] as? String { randsk = r }

                if errno == 0 { verifyOK = true; break verifyLoop }
                else if errno == -9 { throw DriveError.noPlayURL("百度网盘：提取码错误") }
                else if errno == 4 { throw DriveError.noPlayURL("百度网盘：需要图形验证码") }
                else if errno == 105 {
                    baiduLog("[Baidu] ⚠️ 本机提取码校验触发风控(errno=105)，快速回退 Worker")
                    throw DriveError.noPlayURL("百度本机校验触发风控")
                } else {
                    let em = vJson["errmsg"] as? String ?? "errno=\(errno)"
                    baiduLog("[Baidu] ❌ 验证失败：\(em)")
                    throw DriveError.noPlayURL("百度网盘：验证失败 (\(em))")
                }
            }

            if verifyOK {
                baiduLog("[Baidu] ✅ 提取码验证成功")
                if !randsk.isEmpty {
                    currentCookie += "; randsk=\(randsk)"
                    baiduLog("[Baidu] 已提取 randsk")
                }
                let (data2, _) = try await BaiduWebViewBridge.shared.request(
                    url: pageURL.absoluteString,
                    method: "GET",
                    headers: [
                        "Cookie": currentCookie,
                        "User-Agent": ua,
                    ],
                    timeout: 15
                )
                guard let newHtml = String(data: data2, encoding: .utf8) ?? String(data: data2, encoding: .ascii) else {
                    throw DriveError.invalidResponse
                }
                html = newHtml
                baiduLog("[Baidu] ✅ 重新请求分享页成功")
            } else {
                baiduLog("[Baidu] ⚠️ verify 失败，尝试获取文件信息...")

                if !vidShareid.isEmpty && !vidUk.isEmpty && !vidFsId.isEmpty {
                    baiduLog("[Baidu] 使用 HTML 初始提取的参数")
                    shareid = vidShareid
                    shareUk = vidUk
                    files = [BaiduFileItem(fsId: vidFsId, name: vidFileName)]
                    baiduLog("[Baidu] ✅ 使用 HTML 提取参数")
                } else if !vidShareid.isEmpty && !vidUk.isEmpty {
                    baiduLog("[Baidu] 尝试 WAP 绕过验证...")
                    do {
                        let (fsId, name) = try await baiduBypassVerify(shareid: vidShareid, uk: vidUk, surl: surl, cookie: currentCookie)
                        files = [BaiduFileItem(fsId: fsId, name: name)]
                        shareid = vidShareid
                        shareUk = vidUk
                        baiduLog("[Baidu] ✅ WAP 绕过成功")
                    } catch {
                        baiduLog("[Baidu] ❌ WAP 绕过失败")
                        throw DriveError.noPlayURL("百度网盘：验证失败")
                    }
                } else {
                    baiduLog("[Baidu] ❌ 无法提取 shareid/uk")
                    throw DriveError.noPlayURL("百度网盘：验证失败")
                }
            }
        }

        if files.isEmpty {
            if let yunDataRange = html.range(of: "window.yunData="),
               let jsonStart = html[yunDataRange.upperBound...].range(of: "{"),
               let jsonEnd = html[yunDataRange.upperBound...].range(of: "};") {
                let jStart = html.distance(from: html.startIndex, to: jsonStart.lowerBound)
                let jEnd = html.distance(from: html.startIndex, to: jsonEnd.lowerBound)
                if let jData = String(html[html.index(html.startIndex, offsetBy: jStart)..<html.index(html.startIndex, offsetBy: jEnd + 1)]).data(using: .utf8),
                   let yunData = try? JSONSerialization.jsonObject(with: jData) as? [String: Any] {
                    if let sid = yunData["shareid"] as? String { shareid = sid
                    } else if let sid = yunData["shareid"] as? Int { shareid = String(sid) }
                    if let uk = yunData["share_uk"] as? String { shareUk = uk
                    } else if let uk = yunData["share_uk"] as? Int { shareUk = String(uk)
                    } else if let uk = yunData["uk"] as? String { shareUk = uk
                    } else if let uk = yunData["uk"] as? Int { shareUk = String(uk) }
                }
            }

            if let yunDataRange = html.range(of: "window.yunData="),
               let jsonStart = html[yunDataRange.upperBound...].range(of: "{"),
               let jsonEnd = html[yunDataRange.upperBound...].range(of: "};") {
                let jStart = html.distance(from: html.startIndex, to: jsonStart.lowerBound)
                let jEnd = html.distance(from: html.startIndex, to: jsonEnd.lowerBound)
                if let jData = String(html[html.index(html.startIndex, offsetBy: jStart)..<html.index(html.startIndex, offsetBy: jEnd + 1)]).data(using: .utf8),
                   let yunData = try? JSONSerialization.jsonObject(with: jData) as? [String: Any],
                   let fileList = yunData["file_list"] as? [[String: Any]], !fileList.isEmpty {
                    for item in fileList {
                        var fsId = ""
                        if let fid = item["fs_id"] as? String { fsId = fid
                        } else if let fid = item["fs_id"] as? Int64 { fsId = String(fid)
                        } else if let fid = item["fs_id"] as? Int { fsId = String(fid) }
                        let fileName = item["server_filename"] as? String ?? "未知"
                        if !fsId.isEmpty { files.append(BaiduFileItem(fsId: fsId, name: fileName)) }
                    }
                    baiduLog("[Baidu] yunData 文件列表")
                }
            }

            if files.isEmpty {
                if let fidRegex = try? NSRegularExpression(pattern: #""fs_id":\s*(\d+)"#),
                   let nameRegex = try? NSRegularExpression(pattern: #""server_filename":\s*"([^"]+)""#) {
                    let fidMatches = fidRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                    let nameMatches = nameRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                    for i in 0..<fidMatches.count {
                        if let fidR = Range(fidMatches[i].range(at: 1), in: html) {
                            let fsId = String(html[fidR])
                            var fileName = "文件\(i+1)"
                            if i < nameMatches.count, let nameR = Range(nameMatches[i].range(at: 1), in: html) {
                                fileName = String(html[nameR])
                            }
                            files.append(BaiduFileItem(fsId: fsId, name: fileName))
                        }
                    }
                    if !files.isEmpty {
                        baiduLog("[Baidu] 正则提取到 \(files.count) 个文件")
                    }
                }
            }
        }

        if shareid.isEmpty || shareUk.isEmpty {
            baiduLog("[Baidu] ❌ 无法提取 shareid 或 shareUk")
            if pwd != nil {
                throw DriveError.noPlayURL("百度网盘：需要提取码")
            } else {
                throw DriveError.noPlayURL("百度网盘：无法获取分享信息")
            }
        }
        if files.isEmpty {
            baiduLog("[Baidu] ❌ 无法提取文件列表")
            throw DriveError.noPlayURL("百度网盘：未从分享页提取到文件 ID")
        }

        baiduLog("[Baidu] ✅ shareid=\(shareid), shareUk=\(shareUk), 文件=\(files[0].name)")
        return (shareid, shareUk, surl, currentCookie, files)
    }

    private func baiduTransferFile(shareid: String, surl: String, shareUk: String, fsId: String, cookie: String) async throws -> [String] {
        let url = URL(string: "https://pan.baidu.com/share/transfer")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let params = "shareid=\(shareid)&from=\(surl)&share_uk=\(shareUk)&sekey=&pwd=&fsidlist=[\(fsId)]&path=/vbox播放/"
        request.httpBody = params.data(using: .utf8)
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.noPlayURL("百度: 转存接口返回非JSON")
        }
        guard let errno = json["errno"] as? Int, errno == 0 else {
            let errno = json["errno"] as? Int ?? -1
            let errmsg = json["errmsg"] as? String ?? json["show_msg"] as? String ?? "未知错误"
            baiduLog("[Baidu] ❌ 转存失败")
            if errno == 112 {
                throw DriveError.noPlayURL("百度: 转存需要登录验证")
            } else if errno == -9 || errno == 10 {
                throw DriveError.noPlayURL("百度: 分享文件可能需要提取码")
            }
            throw DriveError.saveFailed
        }
        return [fsId]
    }

    private func baiduBypassVerify(shareid: String, uk: String, surl: String, cookie: String) async throws -> (fsId: String, name: String) {
        baiduLog("[Baidu-Bypass] 尝试绕过验证...")

        let shareURL = "https://pan.baidu.com/s/\(surl)"
        
        do {
            let response = try await BaiduProxyClient.shared.parseShareLink(
                url: shareURL,
                pwd: "",
                cookie: cookie
            )
            if let success = response["success"] as? Bool, success,
               let data = response["data"] as? [String: Any],
               let files = data["files"] as? [[String: Any]], !files.isEmpty,
               let fsId = files[0]["fs_id"] as? String, !fsId.isEmpty,
               let fileName = files[0]["server_filename"] as? String {
                baiduLog("[Baidu-Bypass] ✅ Cloudflare Worker 代理成功")
                return (fsId, fileName)
            }
        } catch {
            baiduLog("[Baidu-Bypass] ⚠️ Cloudflare Worker 代理失败: \(error.localizedDescription)")
        }

        let userAgents = [
            "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
            "Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Mobile Safari/537.36",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Edge/120.0.0.0",
        ]

        let strategies: [(String, () async throws -> (String, String))] = [
            ("webview bridge", { try await self.bypassStrategyWebView(shareid: shareid, uk: uk, surl: surl, cookie: cookie) }),
            ("WAP wxlist", { try await self.bypassStrategyWapWxlist(shareid: shareid, uk: uk, surl: surl, cookie: cookie, ua: userAgents.randomElement()!) }),
            ("WAP shareinfo", { try await self.bypassStrategyWapShareInfo(shareid: shareid, uk: uk, surl: surl, cookie: cookie, ua: userAgents.randomElement()!) }),
            ("web page parse", { try await self.bypassStrategyWebPage(shareid: shareid, uk: uk, surl: surl, cookie: cookie, ua: userAgents.randomElement()!) }),
            ("share/list", { try await self.bypassStrategyShareList(shareid: shareid, uk: uk, surl: surl, cookie: cookie, ua: userAgents.randomElement()!) }),
        ]

        for (name, strategy) in strategies {
            do {
                baiduLog("[Baidu-Bypass] 尝试策略: \(name)")
                let (fsId, fileName) = try await strategy()
                if !fsId.isEmpty {
                    baiduLog("[Baidu-Bypass] ✅ \(name) 成功")
                    return (fsId, fileName)
                }
            } catch {
                baiduLog("[Baidu-Bypass] ❌ \(name) 失败: \(error.localizedDescription)")
                try await Task.sleep(nanoseconds: UInt64(Int.random(in: 1000...3000)) * 1_000_000)
            }
        }

        throw DriveError.noPlayURL("百度网盘：所有绕过策略均失败")
    }

    private func bypassStrategyWapWxlist(shareid: String, uk: String, surl: String, cookie: String, ua: String) async throws -> (String, String) {
        let url = URL(string: "https://pan.baidu.com/wap/share/wxlist?shareid=\(shareid)&uk=\(uk)&surl=\(surl)&dir=%2F")!
        var req = URLRequest(url: url)
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://pan.baidu.com", forHTTPHeaderField: "Referer")
        req.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        let (data, _) = try await session.data(for: req)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errno = json["errno"] as? Int, errno == 0,
           let list = json["list"] as? [[String: Any]], let first = list.first {
            return Self.extractFileInfo(first)
        }
        throw DriveError.noPlayURL("WAP wxlist 失败")
    }

    private func bypassStrategyShareList(shareid: String, uk: String, surl: String, cookie: String, ua: String) async throws -> (String, String) {
        var components = URLComponents(string: "https://pan.baidu.com/share/list")!
        components.queryItems = [
            URLQueryItem(name: "shareid", value: shareid),
            URLQueryItem(name: "uk", value: uk),
            URLQueryItem(name: "surl", value: surl),
            URLQueryItem(name: "dir", value: "/"),
            URLQueryItem(name: "order", value: "time"),
            URLQueryItem(name: "desc", value: "1"),
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "channel", value: "chunlei"),
            URLQueryItem(name: "clienttype", value: "0"),
            URLQueryItem(name: "web", value: "1"),
        ]
        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://pan.baidu.com/s/1\(surl)", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 15

        let (data, _) = try await session.data(for: req)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errno = json["errno"] as? Int, errno == 0,
           let list = json["list"] as? [[String: Any]], let first = list.first {
            return Self.extractFileInfo(first)
        }
        throw DriveError.noPlayURL("share/list 失败")
    }

    private func bypassStrategyWapShareInfo(shareid: String, uk: String, surl: String, cookie: String, ua: String) async throws -> (String, String) {
        let url = URL(string: "https://pan.baidu.com/wap/share/info?shareid=\(shareid)&uk=\(uk)&surl=\(surl)")!
        var req = URLRequest(url: url)
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://pan.baidu.com", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 15

        let (data, _) = try await session.data(for: req)
        let html = String(data: data, encoding: .utf8) ?? ""

        for pattern in ["\"fs_id\"\\s*:\\s*\"?(\\d+)\"?", "fs_id=(\\d+)", "\"fs_id\"\\s*:\\s*(\\d+)"] {
            if let r = try? NSRegularExpression(pattern: pattern).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let rr = Range(r.range(at: 1), in: html) {
                let fsId = String(html[rr])
                var name = "未知"
                if let rn = try? NSRegularExpression(pattern: "\"server_filename\"\\s*:\\s*\"([^\"]+)\"").firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   let rrN = Range(rn.range(at: 1), in: html) { name = String(html[rrN]) }
                return (fsId, name)
            }
        }
        throw DriveError.noPlayURL("WAP shareinfo 失败")
    }

    private func bypassStrategyWebPage(shareid: String, uk: String, surl: String, cookie: String, ua: String) async throws -> (String, String) {
        let url = URL(string: "https://pan.baidu.com/s/1\(surl)")!
        var req = URLRequest(url: url)
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://pan.baidu.com", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 20

        let (data, _) = try await session.data(for: req)
        let html = String(data: data, encoding: .utf8) ?? ""

        if let match = html.range(of: #"window\.yunData\s*=\s*\{[\s\S]*?\};"#, options: .caseInsensitive),
           let jsonStr = html[match].split(separator: "=").last?.trimmingCharacters(in: .whitespacesAndNewlines).dropLast() {
            if let jsonData = String(jsonStr).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let list = json["file_list"] as? [[String: Any]], let first = list.first {
                return Self.extractFileInfo(first)
            }
        }

        for pattern in ["\"fs_id\"\\s*:\\s*\"?(\\d+)\"?", "fs_id=(\\d+)", "\"fs_id\"\\s*:\\s*(\\d+)"] {
            if let r = try? NSRegularExpression(pattern: pattern).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let rr = Range(r.range(at: 1), in: html) {
                let fsId = String(html[rr])
                var name = "未知"
                if let rn = try? NSRegularExpression(pattern: "\"server_filename\"\\s*:\\s*\"([^\"]+)\"").firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   let rrN = Range(rn.range(at: 1), in: html) { name = String(html[rrN]) }
                return (fsId, name)
            }
        }
        throw DriveError.noPlayURL("web page parse 失败")
    }

    private func bypassStrategyWebView(shareid: String, uk: String, surl: String, cookie: String) async throws -> (String, String) {
        baiduLog("[Baidu-Bypass] 尝试 WebView Bridge...")
        let shareURL = "https://pan.baidu.com/s/1\(surl)"

        let (data, _) = try await BaiduWebViewBridge.shared.request(
            url: shareURL,
            method: "GET",
            headers: [
                "Cookie": cookie,
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "Referer": "https://pan.baidu.com/",
            ],
            timeout: 25
        )

        let html = String(data: data, encoding: .utf8) ?? ""

        if let match = html.range(of: #"window\.yunData\s*=\s*\{[\s\S]*?\};"#, options: .caseInsensitive),
           let jsonStr = html[match].split(separator: "=").last?.trimmingCharacters(in: .whitespacesAndNewlines).dropLast() {
            if let jsonData = String(jsonStr).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let list = json["file_list"] as? [[String: Any]], let first = list.first {
                return Self.extractFileInfo(first)
            }
        }

        for pattern in ["\"fs_id\"\\s*:\\s*\"?(\\d+)\"?", "fs_id=(\\d+)", "\"fs_id\"\\s*:\\s*(\\d+)"] {
            if let r = try? NSRegularExpression(pattern: pattern).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let rr = Range(r.range(at: 1), in: html) {
                let fsId = String(html[rr])
                var name = "未知"
                if let rn = try? NSRegularExpression(pattern: "\"server_filename\"\\s*:\\s*\"([^\"]+)\"").firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   let rrN = Range(rn.range(at: 1), in: html) { name = String(html[rrN]) }
                return (fsId, name)
            }
        }
        throw DriveError.noPlayURL("webview bridge 失败")
    }

    private static func extractFileInfo(_ item: [String: Any]) -> (String, String) {
        var fsId = ""
        if let fid = item["fs_id"] as? String { fsId = fid }
        else if let fid = item["fs_id"] as? Int64 { fsId = String(fid) }
        else if let fid = item["fs_id"] as? Int { fsId = String(fid) }
        let name = item["server_filename"] as? String ?? item["filename"] as? String ?? "未知"
        return (fsId, name)
    }

    private func baiduGetPCSPlayURL(fileName: String, cookie: String) async throws -> PlayResult {
        let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        let filePath = "/vbox播放/\(encodedName)"

        var components = URLComponents(string: "https://d.pcs.baidu.com/rest/2.0/pcs/file")!
        components.queryItems = [
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "method", value: "locatedownload"),
            URLQueryItem(name: "check_blue", value: "1"),
            URLQueryItem(name: "path", value: filePath),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.noPlayURL("百度：PCS 接口返回非 JSON")
        }

        if let errno = json["errno"] as? Int, errno != 0 {
            baiduLog("[Baidu] ❌ PCS 错误")
            throw DriveError.noPlayURL("百度：获取播放地址失败")
        }

        guard let urls = json["urls"] as? [[String: Any]],
              let firstURL = urls.first,
              let playURL = firstURL["url"] as? String else {
            if let url = json["url"] as? String {
                return PlayResult(
                    url: url,
                    headers: [
                        "Cookie": cookie,
                        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                        "Referer": "https://pan.baidu.com/",
                    ],
                    driveType: .baidu
                )
            }
            throw DriveError.noPlayURL("百度：PCS 未返回播放地址")
        }

        return PlayResult(
            url: playURL,
            headers: [
                "Cookie": cookie,
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                "Referer": "https://pan.baidu.com/",
            ],
            driveType: .baidu
        )
    }

    /// 【新增】使用 get_video_info API 获取 m3u8 播放地址
    private func baiduGetVideoInfoPlayURL(shareid: String, shareUk: String, fsId: String, cookie: String) async throws -> PlayResult {
        baiduLog("[Baidu-VideoInfo] 调用 get_video_info API...")

        let timestamp = Int(Date().timeIntervalSince1970)
        let sign = generateBaiduSign(shareid: shareid, shareUk: shareUk, fsId: fsId, timestamp: timestamp)

        var components = URLComponents(string: "https://pan.baidu.com/api/get_video_info")!
        components.queryItems = [
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "channel", value: "chunlei"),
            URLQueryItem(name: "clienttype", value: "0"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "sign", value: sign),
            URLQueryItem(name: "timestamp", value: String(timestamp)),
            URLQueryItem(name: "shareid", value: shareid),
            URLQueryItem(name: "share_uk", value: shareUk),
            URLQueryItem(name: "fsid", value: fsId),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.baidu.com/s/1\(shareid)", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }

        if let errno = json["errno"] as? Int, errno != 0 {
            let errmsg = json["errmsg"] as? String ?? "错误码：\(errno)"
            baiduLog("[Baidu-VideoInfo] ❌ errno=\(errno), \(errmsg)")
            throw DriveError.noPlayURL("百度：\(errmsg)")
        }

        if let videoInfo = json["video_info"] as? [String: Any] {
            if let m3u8Url = videoInfo["m3u8_url"] as? String, !m3u8Url.isEmpty {
                baiduLog("[Baidu-VideoInfo] ✅ 获取到 m3u8 地址")
                return PlayResult(
                    url: m3u8Url,
                    headers: [
                        "Cookie": cookie,
                        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                        "Referer": "https://pan.baidu.com/",
                    ],
                    driveType: .baidu
                )
            }
            if let mp4Url = videoInfo["mp4_url"] as? String, !mp4Url.isEmpty {
                baiduLog("[Baidu-VideoInfo] ✅ 获取到 mp4 地址")
                return PlayResult(
                    url: mp4Url,
                    headers: [
                        "Cookie": cookie,
                        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                        "Referer": "https://pan.baidu.com/",
                    ],
                    driveType: .baidu
                )
            }
        }

        throw DriveError.noPlayURL("百度：get_video_info 未返回播放地址")
    }

    /// 生成百度网盘 API 签名
    private func generateBaiduSign(shareid: String, shareUk: String, fsId: String, timestamp: Int) -> String {
        let rawString = "\(shareid)-\(shareUk)-\(fsId)-\(timestamp)"
        return rawString.md5()
    }

    private func baiduGetDirectLink(shareid: String, shareUk: String, fsId: String, fileName: String, cookie: String) async throws -> PlayResult {
        baiduLog("[Baidu-Direct] 调用 sharedownload API...")

        let timestamp = Int(Date().timeIntervalSince1970)
        let sign = generateBaiduSign(shareid: shareid, shareUk: shareUk, fsId: fsId, timestamp: timestamp)

        var components = URLComponents(string: "https://pan.baidu.com/api/sharedownload")!
        components.queryItems = [
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "channel", value: "chunlei"),
            URLQueryItem(name: "clienttype", value: "0"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "sign", value: sign),
            URLQueryItem(name: "timestamp", value: String(timestamp)),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.baidu.com/s/1\(shareid)", forHTTPHeaderField: "Referer")

        let bodyParams = "encodings=1&fsidlist=[\(fsId)]&primaryid=\(shareid)&uk=\(shareUk)"
        request.httpBody = bodyParams.data(using: .utf8)

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }

        if let errno = json["errno"] as? Int {
            if errno != 0 {
                let errmsg = json["errmsg"] as? String ?? "错误码：\(errno)"
                baiduLog("[Baidu-Direct] ❌ errno=\(errno), \(errmsg)")
                throw DriveError.noPlayURL("百度：\(errmsg)")
            }
        }

        guard let list = json["list"] as? [[String: Any]],
              let firstFile = list.first,
              let dlink = firstFile["dlink"] as? String else {
            throw DriveError.noPlayURL("百度：sharedownload 未返回下载链接")
        }

        let decodedDlink = dlink.replacingOccurrences(of: "\\/", with: "/")

        return PlayResult(
            url: decodedDlink,
            headers: [
                "Cookie": cookie,
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                "Referer": "https://pan.baidu.com/",
            ],
            driveType: .baidu
        )
    }

    /// 【新增】通过 WebView 提取视频播放地址（兜底方案）
    private func baiduExtractVideoFromWebView(shareURL: String, cookie: String) async throws -> PlayResult {
        baiduLog("[Baidu-WebView] 尝试通过 WebView 提取视频地址...")

        let (data, _) = try await BaiduWebViewBridge.shared.request(
            url: shareURL,
            method: "GET",
            headers: [
                "Cookie": cookie,
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                "Referer": "https://pan.baidu.com/",
            ],
            timeout: 20
        )

        guard let html = String(data: data, encoding: .utf8) else {
            throw DriveError.invalidResponse
        }

        let patterns = [
            #"videoUrl.*?["']([^"']+\.m3u8[^"']*)["']"#,
            #"playUrl.*?["']([^"']+\.m3u8[^"']*)["']"#,
            #"url.*?["']([^"']+\.m3u8[^"']*)["']"#,
            #"src.*?["']([^"']+\.m3u8[^"']*)["']"#,
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let m3u8Url = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                baiduLog("[Baidu-WebView] ✅ 提取到 m3u8 地址")
                return PlayResult(
                    url: m3u8Url,
                    headers: [
                        "Cookie": cookie,
                        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                        "Referer": "https://pan.baidu.com/",
                    ],
                    driveType: .baidu
                )
            }
        }

        throw DriveError.noPlayURL("百度：WebView 未提取到播放地址")
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
        let (shareCode, receiveCode) = try await extract115ShareCode(from: shareURL)

        let snapResult = try await one15Snap(shareCode: shareCode, receiveCode: receiveCode, cid: cid)

        guard let fileId = snapResult.fileId else { throw DriveError.noPlayURL("115: snap未返回文件ID") }
        let downloadURL = try await one15GetDownloadURL(fileId: fileId, cid: cid)

        return PlayResult(
            url: downloadURL,
            headers: ["Cookie": "CID=\(cid)", "User-Agent": "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36"],
            driveType: .one15
        )
    }

    private func extract115ShareCode(from url: String) async throws -> (shareCode: String, receiveCode: String) {
        var shareCode = ""
        var receiveCode = ""

        if let range = url.range(of: #"/s/([^/?]+)"#, options: .regularExpression) {
            shareCode = String(url[range]).replacingOccurrences(of: "/s/", with: "")
        }
        if let range = url.range(of: #"password=([^&]+)"#, options: .regularExpression) {
            receiveCode = String(url[range]).replacingOccurrences(of: "password=", with: "")
        }

        guard !shareCode.isEmpty else { throw DriveError.invalidShareURL }
        return (shareCode, receiveCode)
    }

    private struct One15SnapResult {
        let fileId: String?
        let fileName: String?
    }

    private func one15Snap(shareCode: String, receiveCode: String, cid: String) async throws -> One15SnapResult {
        var components = URLComponents(string: "https://webapi.115.com/share/snap")!
        components.queryItems = [
            URLQueryItem(name: "share_code", value: shareCode),
            URLQueryItem(name: "receive_code", value: receiveCode),
            URLQueryItem(name: "cid", value: "0"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "20")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("CID=\(cid)", forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = json["state"] as? Bool, state == true,
              let dataDict = json["data"] as? [String: Any] else {
            throw DriveError.invalidResponse
        }

        var fileId: String?
        if let list = dataDict["list"] as? [[String: Any]], let first = list.first {
            fileId = String(describing: first["file_id"] ?? first["id"] ?? "")
        } else if let pickCode = dataDict["pick_code"] as? String {
            fileId = pickCode
        }

        return One15SnapResult(fileId: fileId, fileName: dataDict["file_name"] as? String)
    }

    private func one15GetDownloadURL(fileId: String, cid: String) async throws -> String {
        var components = URLComponents(string: "https://proapi.115.com/app/chrome/downurl")!
        components.queryItems = [URLQueryItem(name: "pickcode", value: fileId)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("CID=\(cid)", forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = json["state"] as? Bool, state == true else {
            throw DriveError.invalidResponse
        }

        if let dataObj = json["data"] as? [String: Any] {
            for (_, value) in dataObj {
                if let fileInfo = value as? [String: Any],
                   let url = fileInfo["url"] as? String {
                    return url
                }
            }
        }

        throw DriveError.noPlayURL("115: 未获取到下载地址")
    }

    // MARK: - UC 网盘

    func resolveUCPlayURL(shareURL: String, cookie: String) async throws -> PlayResult {
        let shareId = extractUCShareId(from: shareURL)

        let folderId = try await ucEnsureFolder(cookie: cookie)

        let fileIds = try await ucSaveShare(shareId: shareId, folderId: folderId, cookie: cookie)

        guard let fileId = fileIds.first else { throw DriveError.noPlayURL("UC: 转存后未返回文件ID") }
        let playURL = try await ucGetPlayURL(fileId: fileId, cookie: cookie)

        scheduleCleanup(drive: .uc, fileIds: fileIds, token: cookie, delay: 180)

        return PlayResult(
            url: playURL,
            headers: ["Cookie": cookie, "Referer": "https://drive.uc.cn/", "User-Agent": "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36"],
            driveType: .uc
        )
    }

    private func extractUCShareId(from url: String) -> String {
        if let range = url.range(of: #"/s/([^/?]+)"#, options: .regularExpression) {
            return String(url[range]).replacingOccurrences(of: "/s/", with: "")
        }
        return url
    }

    private func ucSaveShare(shareId: String, folderId: String, cookie: String) async throws -> [String] {
        let shareToken = try await ucGetShareToken(shareId: shareId, cookie: cookie)

        var request = URLRequest(url: URL(string: "https://drive.uc.cn/1/clouddrive/share/sharepage/save")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        var body: [String: Any] = [
            "share_id": shareId,
            "to_pdir_fid": folderId
        ]
        if !shareToken.isEmpty { body["share_token"] = shareToken }
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
            if let list = dataObj["list"] as? [[String: Any]], let first = list.first {
                if let fid = first["fid"] as? String { return [fid] }
                else if let fid = first["fid"] as? Int { return [String(fid)] }
                else if let fileId = first["file_id"] as? String { return [fileId] }
                else if let fileId = first["file_id"] as? Int { return [String(fileId)] }
            }
            if let fileIds = dataObj["file_ids"] as? [String] { return fileIds }
            if let fileIds = dataObj["file_ids"] as? [Int] { return fileIds.map { String($0) } }
        }

        return [shareId]
    }

    private func ucGetShareToken(shareId: String, cookie: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://drive.uc.cn/1/clouddrive/share/sharepage/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = ["share_id": shareId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let stoken = dataObj["stoken"] as? String else {
            return ""
        }
        return stoken
    }

    private func ucEnsureFolder(cookie: String) async throws -> String {
        let listURL = URL(string: "https://drive.uc.cn/1/clouddrive/file/sort")!
        var req = URLRequest(url: listURL)
        req.httpMethod = "POST"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = ["pdir_fid": "", "sort_by": "file_name", "sort_order": "asc", "page": 1, "size": 100]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        if let (data, _) = try? await session.data(for: req),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["data"] as? [String: Any],
           let files = list["list"] as? [[String: Any]] {
            for f in files {
                if let name = f["file_name"] as? String, name == "vbox播放",
                   let fid = f["fid"] as? String { return fid }
            }
        }
        let createURL = URL(string: "https://drive.uc.cn/1/clouddrive/file")!
        var createReq = URLRequest(url: createURL)
        createReq.httpMethod = "POST"
        createReq.setValue(cookie, forHTTPHeaderField: "Cookie")
        createReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createReq.setValue("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let createBody: [String: Any] = ["pdir_fid": "", "file_name": "vbox播放", "dir": true, "dir_path": ""]
        createReq.httpBody = try JSONSerialization.data(withJSONObject: createBody)
        if let (createData, _) = try? await session.data(for: createReq),
           let createJson = try? JSONSerialization.jsonObject(with: createData) as? [String: Any],
           let d = createJson["data"] as? [String: Any],
           let fid = d["fid"] as? String { return fid }
        return ""
    }

    private func ucDeleteFiles(fileIds: [String], cookie: String) async {
        guard !fileIds.isEmpty else { return }
        let url = URL(string: "https://drive.uc.cn/1/clouddrive/file/trash")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = ["file_ids": fileIds, "trash": true]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let _ = try? await session.data(for: req)
        print("[CloudDrive] ✅ UC 已删除 \(fileIds.count) 个转存文件")
    }

    private func ucGetPlayURL(fileId: String, cookie: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://drive.uc.cn/1/clouddrive/file/v2/play")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = ["file_id": fileId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let playURL = dataObj["play_url"] as? String else {
            throw DriveError.noPlayURL("UC: 未返回播放地址")
        }
        return playURL
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
                continue
            }
        }

        let count = tokens.count
        print("[CloudDrive] ❌ 所有 \(count) 个 \(driveType.displayName) Token 均失败")
        throw lastError ?? DriveError.tokenNotConfigured(driveType.displayName)
    }
}

// MARK: - 数据结构

struct PlayResult {
    let url: String
    let headers: [String: String]
    let driveType: DriveTypeAlias
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
